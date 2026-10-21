function r = mas_table_audit(T, rules, opts)
%MAS_TABLE_AUDIT  Clean a table with a ROW-ACCOUNTED audit trail.
%
%   r = mas_table_audit(T, struct('missing','drop','duplicates','drop', ...
%                                 'outliers',struct('method','iqr','factor',1.5)))
%
%   r.clean     the cleaned table
%   r.audit     one row per rule: rule, nBefore, nAfter, nDropped, nFilled
%   r.dropped   table of the removed rows PLUS the rule that removed each one
%   r.balanced  nRowsIn - nDropped == nRowsOut, and every dropped row has a reason
%   r.flags     rows that were kept but marked (flagged outliers, imputed values)
%
% WHY THIS IS NOT `rmmissing` PLUS A ONE-LINE PRINT
% The requirement is "no silent loss of important data", and the way that fails in
% practice is not a crash, it is arithmetic that does not add up. Three rules that
% each drop their own rows will double-count a row that qualifies for two, and the
% report then says "40 in, 30 out, dropped 3 + 4 + 4 = 11" -- which reads fine and
% is wrong by one.
%
% So every row gets ONE verdict, assigned by the first rule that matches, and the
% balance is checked explicitly:
%
%     nRowsIn == nRowsOut + nDropped        (must hold exactly)
%
% If it does not, `balanced` is false and the caller must not report a pass.
%
% ORDER MATTERS AND IS FIXED: missing -> duplicates -> outliers. A row with a NaN
% that is also a duplicate is counted once, under "missing". Changing the order
% changes the counts, which is why the order is part of the contract and is printed
% in the audit.
%
% MIXED TYPES
% Non-numeric, non-string columns are reported but never silently dropped: a table
% with a cell or categorical column is fine, it just cannot be screened for
% outliers. `audit.typeWarnings` lists what was skipped and why.

if nargin < 2 || isempty(rules), rules = struct(); end
if nargin < 3, opts = struct(); end
rules = dflt(rules, struct('missing', 'drop', 'missingFill', NaN, ...
    'duplicates', 'drop', 'dupKeys', {{}}, ...
    'outliers', struct('method', 'iqr', 'factor', 1.5, 'action', 'flag', ...
                       'columns', {{}})));
opts = dflt(opts, struct('verbose', false));
% The outlier sub-struct needs merging SEPARATELY. dflt() only fills top-level
% fields, so a caller who passes outliers.method without outliers.columns gets a
% struct missing that field and the first access throws -- which is exactly what
% happened on the first run of cd_t1_clean.
rules.outliers = dflt(rules.outliers, struct('method', 'iqr', 'factor', 1.5, ...
    'action', 'flag', 'columns', {{}}));

if ~istable(T)
    error('mas_table_audit:type', 'input must be a table (got %s)', class(T));
end
nIn = height(T);
n = nIn;
reason = strings(n, 1);            % "" = kept
reason(:) = "";

% ---------- rule 1: missing ------------------------------------------------
nMissBefore = n;
missMask = false(n, 1);
for k = 1:width(T)
    v = T{:, k};
    if isnumeric(v)
        missMask = missMask | isnan(v);
    elseif isstring(v) || iscellstr(v)
        s = string(v);
        missMask = missMask | (s == "" | ismissing(s));
    elseif iscategorical(v)
        missMask = missMask | ismissing(v);
    end
end
nMissing = nnz(missMask);
nFilled = 0;
if strcmpi(rules.missing, 'drop')
    reason(missMask) = "missing";
elseif strcmpi(rules.missing, 'fill')
    T = fill_missing(T, rules.missingFill);
    nFilled = nMissing;
elseif ~strcmpi(rules.missing, 'keep')
    error('mas_table_audit:rule', 'missing rule must be drop/fill/keep');
end
A = mk('missing', nMissBefore, n, nMissing*(strcmpi(rules.missing,'drop')), nFilled);

% ---------- rule 2: duplicates --------------------------------------------
keep1 = reason == "";
if ~isempty(rules.dupKeys)
    sub = T(:, rules.dupKeys);
else
    sub = T;
end
dupMask = false(n, 1);
seen = containers.Map('KeyType', 'char', 'ValueType', 'logical');
for k = 1:n
    if ~keep1(k), continue; end
    key = row_key(sub, k);
    if isKey(seen, key)
        dupMask(k) = true;
    else
        seen(key) = true;
    end
end
nDup = nnz(dupMask);
if strcmpi(rules.duplicates, 'drop')
    reason(dupMask) = "duplicate";
elseif ~strcmpi(rules.duplicates, 'keep')
    error('mas_table_audit:rule', 'duplicates rule must be drop/keep');
end
A(end+1) = mk('duplicates', nnz(keep1), n, nDup*strcmpi(rules.duplicates,'drop'), 0);

% ---------- rule 3: outliers ----------------------------------------------
numCols = {};
for k = 1:width(T)
    if isnumeric(T{:, k}), numCols{end+1} = T.Properties.VariableNames{k}; end %#ok<AGROW>
end
if ~isempty(rules.outliers.columns)
    numCols = intersect(numCols, rules.outliers.columns, 'stable');
end
outMask = false(n, 1);
outInfo = struct('column', {}, 'row', {}, 'value', {}, 'bound', {});
for c = 1:numel(numCols)
    v = T{:, numCols{c}};
    [lo, hi] = bounds_of(v, rules.outliers);
    bad = (v < lo) | (v > hi);
    bad = bad & (reason == "");
    idx = find(bad);
    for q = 1:numel(idx)
        outInfo(end+1) = struct('column', numCols{c}, 'row', idx(q), ...
            'value', v(idx(q)), 'bound', [lo hi]); %#ok<AGROW>
    end
    outMask = outMask | bad;
end
nOut = nnz(outMask);
if strcmpi(rules.outliers.action, 'remove')
    reason(outMask) = "outlier";
end
A(end+1) = mk('outliers', nnz(keep1), n, nOut*strcmpi(rules.outliers.action,'remove'), 0);

% ---------- apply ----------------------------------------------------------
drop = reason ~= "";
clean = T(~drop, :);
dropped = [T(drop, :), table(reason(drop), 'VariableNames', {'audit_reason'})];
flags = table(find(outMask & ~drop), 'VariableNames', {'audit_row'});

nOutRows = height(clean);
nDropped = nnz(drop);
balanced = (nIn == nOutRows + nDropped) && all(strlength(reason(drop)) > 0);

% mixed-type warnings: a column that is neither numeric nor text cannot be screened
tw = {};
for k = 1:width(T)
    v = T{:, k};
    if ~isnumeric(v) && ~isstring(v) && ~iscellstr(v) && ~iscategorical(v) && ~islogical(v)
        tw{end+1} = sprintf('%s (%s): not screened', T.Properties.VariableNames{k}, class(v)); %#ok<AGROW>
    end
end

r = struct();
r.clean = clean;
r.audit = A;
r.dropped = dropped;
r.dropMask = drop;
r.flags = flags;
r.outlierDetail = outInfo;
r.nRowsIn = nIn;
r.nRowsOut = nOutRows;
r.nDropped = nDropped;
r.balanced = balanced;
r.typeWarnings = tw;
r.rules = rules;
% Built with a plain loop: the one-line compose()/strjoin() version threw on a
% struct-array to string conversion, and a diagnostic string is not worth that.
parts = cell(1, numel(A));
for k = 1:numel(A)
    parts{k} = sprintf('%s %d', A(k).rule, A(k).nDropped);
end
r.detail = sprintf('%d in -> %d out, %d dropped (%s), balance %s', ...
    nIn, nOutRows, nDropped, strjoin(parts, ', '), tern(balanced, 'OK', 'BROKEN'));

if opts.verbose
    fprintf('%-12s %8s %8s %8s %8s\n', 'rule', 'before', 'after', 'dropped', 'filled');
    for k = 1:numel(A)
        fprintf('%-12s %8d %8d %8d %8d\n', A(k).rule, A(k).nBefore, A(k).nAfter, ...
            A(k).nDropped, A(k).nFilled);
    end
    fprintf('%s\n', r.detail);
    for k = 1:numel(tw)
        fprintf('  warning: %s\n', tw{k});
    end
end
end

% ---------------------------------------------------------------------------
function a = mk(rule, before, after, dropped, filled)
a = struct('rule', rule, 'nBefore', before, 'nAfter', after, ...
    'nDropped', dropped, 'nFilled', filled);
end

% ---------------------------------------------------------------------------
function [lo, hi] = bounds_of(v, o)
v = v(isfinite(v));
if isempty(v)
    lo = -Inf; hi = Inf; return;
end
switch lower(o.method)
    case 'iqr'
        q = quantile(v, [0.25 0.75]);
        iqr = q(2) - q(1);
        lo = q(1) - o.factor*iqr;
        hi = q(2) + o.factor*iqr;
    case 'zscore'
        m = mean(v); s = std(v);
        if s == 0, s = eps; end
        lo = m - o.factor*s;
        hi = m + o.factor*s;
    case 'mad'
        m = median(v);
        mad_ = median(abs(v - m));
        lo = m - o.factor*1.4826*mad_;
        hi = m + o.factor*1.4826*mad_;
    otherwise
        error('mas_table_audit:outlier', 'unknown outlier method "%s"', o.method);
end
end

% ---------------------------------------------------------------------------
function T = fill_missing(T, val)
for k = 1:width(T)
    v = T{:, k};
    if isnumeric(v)
        if isscalar(val) && ~isnan(val), fill = val;
        else, fill = mean(v(isfinite(v)), 'omitnan'); end
        if isnan(fill), fill = 0; end
        v(isnan(v)) = fill;
        T{:, k} = v;
    elseif isstring(v)
        v(ismissing(v)) = string(val);
        T{:, k} = v;
    end
end
end

% ---------------------------------------------------------------------------
function key = row_key(T, k)
% A stable text key for one row. num2str with 17 digits so that 1.0000001 and
% 1.0 are not treated as duplicates.
parts = cell(1, width(T));
for c = 1:width(T)
    v = T{k, c};
    if isnumeric(v)
        if isnan(v), parts{c} = 'NaN';
        else, parts{c} = sprintf('%.17g', double(v)); end
    else
        parts{c} = char(string(v));
    end
end
key = strjoin(parts, '|');
end

function o = dflt(o, d)
f = fieldnames(d);
for k = 1:numel(f)
    if ~isfield(o, f{k}), o.(f{k}) = d.(f{k}); end
end
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
