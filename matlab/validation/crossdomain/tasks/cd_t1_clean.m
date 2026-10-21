function out = cd_t1_clean()
%CD_T1_CLEAN  Data analysis: clean a table with KNOWN defects and account for every row.
%
% REFERENCE (id T1)
%   The fixture is BUILT with exactly 3 NaNs, 2 duplicate rows and 2 outliers, in
%   disjoint rows, so the answer is 40 - 3 - 2 - 2 = 33 rows out and 3/2/2 counted.
%   Secondary source: the conservation identity nIn == nOut + nDropped, which holds
%   for any rule set and catches double-counting.
%
% The table also carries a text column, so a cleaning routine that quietly converts
% it or drops it is flagged by the type warnings rather than by luck.

cd_setup();

rng(3);
n = 40;
x = round(sin((1:n).'/3), 3);
g = repmat(["A"; "B"], n/2, 1);
T = table((1:n).', x, g, 'VariableNames', {'id', 'x', 'group'});

nat = [5 12 27];        % missing
T.x(nat) = NaN;
% duplicates of rows 1 and 10, placed later so "keep the first" has something to do
T.x(20) = T.x(10); T.group(20) = T.group(10);
T.x(33) = T.x(1);  T.group(33) = T.group(1);
outr = [8 35];          % outliers
T.x(outr) = 500;

rules = struct('missing', 'drop', 'duplicates', 'drop', ...
    'dupKeys', {{'x', 'group'}}, ...
    'outliers', struct('method', 'iqr', 'factor', 1.5, 'action', 'remove'));
r = mas_table_audit(T, rules);

counts = struct();
for k = 1:numel(r.audit)
    counts.(r.audit(k).rule) = r.audit(k).nDropped;
end

out.values = struct('nRowsIn', r.nRowsIn, 'nRowsOut', r.nRowsOut, ...
    'nMissing', getfield_def(counts, 'missing'), ...
    'nDuplicate', getfield_def(counts, 'duplicates'), ...
    'nOutlier', getfield_def(counts, 'outliers'), ...
    'balanced', double(r.balanced), 'nTextColsKept', sum(strcmp(varfun(@class, r.clean, ...
        'OutputFormat', 'cell'), 'string')));
out.reference = struct('note', 'fixture built with 3 NaN, 2 duplicates, 2 outliers');
out.status = tern(r.balanced && r.nRowsOut == 33, 'PASS', 'FAIL');
out.detail = r.detail;
end

function v = getfield_def(s, f)
if isfield(s, f), v = s.(f); else, v = 0; end
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
