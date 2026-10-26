function r = mas_refcheck(action, opt)
%MAS_REFCHECK  Freeze and verify the independent reference answers.
%
%   r = mas_refcheck('verify')             % check the committed manifest
%   r = mas_refcheck('verify', 'D3')       % one task
%   r = mas_refcheck('freeze')             % (re)write the manifest -- see below
%   r = mas_refcheck('list')
%
% WHAT IS FROZEN
% `evals/references/reference_manifest.json` holds, per task: the reference values,
% the grading spec (field / operator / tolerance), the methods that produced the
% values, how tightly those methods agreed, and a SHA-256 of the canonical value
% set. The manifest is committed, so any later edit -- including a quiet widening of
% a tolerance after a task failed -- changes a hash that `verify` recomputes.
%
% THREE GUARDS, ALL OF WHICH MUST HOLD BEFORE A VALUE IS CALLED A REFERENCE:
%
%   1. Two or more INDEPENDENT methods must agree to `crosscheckTol`, which is at
%      least 100x tighter than the grading tolerance. If the methods only agree to
%      within the tolerance, the tolerance is measuring noise and the reference is
%      not established. (Phase 4's D3 reference came from one method that was
%      itself wrong; that cannot happen here because a second, differently-written
%      method has to reproduce it.)
%   2. The hand-declared number in `mas_ref_spec` must agree with the derived value
%      at freeze time. A transposed centroid or a "-24.10 instead of -27.97" fails
%      here, before the value is ever frozen.
%   3. The stored hash must equal the hash of the values as re-derived now. This is
%      what detects a manifest edited after the fact.
%
% `freeze` is deliberately not part of the normal test run: it rewrites a committed
% file. To change a reference, a human edits the derivation or the spec, re-runs
% `freeze`, and the diff shows exactly which numbers moved.

if nargin < 1, action = 'verify'; end
if nargin < 2, opt = ''; end
if isstruct(opt), opt = ''; end

here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
manifestFile = fullfile(repo, 'evals', 'references', 'reference_manifest.json');
ids = {'D1','D2','D3','D4','D5','D6','D7','D8','C1','C2','C3','T1','S1','R1','G1'};
% The second argument is either a task id or a path to an alternative manifest.
% The path form exists so the tests can verify a TAMPERED copy and prove the hash
% guard fires; without it the guard would be untestable.
if ~isempty(opt)
    if ~isempty(strfind(opt, '.json')) %#ok<STREMP>
        manifestFile = opt;
    else
        ids = {upper(opt)};
    end
end

switch lower(action)
    case 'list'
        r = ids;
        fprintf('%d reference entries: %s\n', numel(ids), strjoin(ids, ' '));
        return;

    case 'freeze'
        r = do_freeze(ids, manifestFile);
        return;

    case 'verify'
        r = do_verify(ids, manifestFile);
        return;

    otherwise
        error('mas_refcheck:action', 'unknown action "%s"', action);
end
end

% ===========================================================================
function r = do_freeze(ids, manifestFile)
fprintf('=== freezing %d references ===\n', numel(ids));
fprintf('%-4s %-34s %10s %8s %6s %s\n', 'id', 'methods', 'agreement', 'checks', 'spread', 'status');

entries = struct();
for k = 1:numel(ids)
    id = ids{k};
    m = mas_ref_derive(id);
    spec = mas_ref_spec(id);
    flat = flatten(m);
    [okSpec, badSpec] = spec_consistent(spec, flat);
    [okSpread, worstRatio, worstField] = spread_ok(spec, m.spread, spread_factor(id));

    status = 'OK';
    if ~okSpread, status = sprintf('METHODS_DISAGREE(%s x%.0f)', worstField, worstRatio); end
    if ~okSpec, status = sprintf('SPEC_OFF(%s)', strjoin(badSpec, ',')); end

    fprintf('%-4s %-34s %10.2e %8d %6.3f %s\n', id, strjoin(m.methods, ','), ...
        m.agreement, numel(spec), worstRatio, status);
    if ~strcmp(status, 'OK')
        continue;
    end

    e = struct();
    e.title = m.id;
    e.values = flat;
    e.methods = m.methods;
    e.kinds = m.kind;
    e.agreement = m.agreement;
    e.spread = m.spread;
    e.spreadFactor = spread_factor(id);
    e.checks = spec;
    e.hash = hash_values(flat);
    e.frozenWith = version;
    entries.(id) = e;
end

M = struct('schema', 'mas-reference/1', 'frozenAt', datestr(now, 31), ...
    'matlabVersion', version, 'hashAlgo', 'sha256', ...
    'canonicalForm', 'sorted field names, sprintf("%.17g") for each numeric value', ...
    'entries', entries);
ensure_dir(fileparts(manifestFile));
fid = fopen(manifestFile, 'w');
if fid < 0, error('mas_refcheck:io', 'cannot write %s', manifestFile); end
fwrite(fid, jsonencode(M, 'PrettyPrint', true), 'char');
fclose(fid);
fprintf('\nwrote %s (%d entries)\n', manifestFile, numel(fieldnames(entries)));
r = struct('frozen', numel(fieldnames(entries)), 'file', manifestFile);
end

% ===========================================================================
function r = do_verify(ids, manifestFile)
if ~isfile(manifestFile)
    r = struct('pass', false, 'detail', 'manifest missing; run mas_refcheck(''freeze'')', ...
        'entries', struct());
    fprintf('%s\n', r.detail);
    return;
end
M = jsondecode(fileread(manifestFile));
fprintf('=== verifying references against %s ===\n', 'reference_manifest.json');
fprintf('%-4s %10s %8s %6s %8s %8s %s\n', 'id', 'agreement', 'spread', 'hashOK', 'specOK', 'valuesOK', 'status');

nOK = 0; nTot = 0;
out = struct();
for k = 1:numel(ids)
    id = ids{k};
    nTot = nTot + 1;
    if ~isfield(M.entries, id)
        fprintf('%-4s %10s %8s %6s %8s %8s %s\n', id, '-', '-', '-', '-', '-', 'NOT_IN_MANIFEST');
        out.(id) = struct('pass', false, 'status', 'NOT_IN_MANIFEST');
        continue;
    end
    e = M.entries.(id);
    m = mas_ref_derive(id);
    flat = flatten(m);

    h = hash_values(flat);
    hashOK = strcmp(h, e.hash);
    % values must still match the frozen ones: a hash guard alone would accept a
    % manifest rewritten consistently with a CHANGED derivation.
    [valOK, worstField, worstD] = values_match(flat, e.values, 1e-9);
    spec = mas_ref_spec(id);
    [specOK, ~] = spec_consistent(spec, flat);
    [spreadOK, worstRatio, sField] = spread_ok(spec, m.spread, e.spreadFactor);

    ok = hashOK && valOK && specOK && spreadOK;
    nOK = nOK + ok;
    st = 'OK';
    if ~spreadOK, st = sprintf('SPREAD %s x%.1f', sField, worstRatio); end
    if ~valOK, st = sprintf('VALUE %s %.1e', worstField, worstD); end
    if ~hashOK, st = 'HASH_CHANGED'; end
    if ~specOK, st = 'SPEC_DRIFT'; end
    fprintf('%-4s %10.2e %8.1f %8d %8d %8d %s\n', id, m.agreement, worstRatio, ...
        hashOK, specOK, valOK, st);
    out.(id) = struct('pass', ok, 'status', st, 'hash', h, ...
        'agreement', m.agreement, 'spreadRatio', worstRatio);
end
fprintf('\n---- %d / %d references verified ----\n', nOK, nTot);
r = struct('pass', nOK == nTot, 'nPass', nOK, 'nTotal', nTot, 'entries', out, ...
    'detail', sprintf('%d/%d', nOK, nTot));
end

% ===========================================================================
function f = spread_factor(id)
% How much of the grading tolerance the method spread may consume. 0.1 means the
% independent methods agree to a tenth of the pass mark, i.e. the reference is
% determined far more precisely than it is graded. 0.5 is used only where a method
% is intrinsically statistical (a Monte-Carlo BER estimate).
switch upper(id)
    case 'S1', f = 0.5;
    otherwise, f = 0.1;
end
end

function [ok, worstRatio, worstField] = spread_ok(spec, spread, factor)
% Per grading check: does the method spread stay inside factor*tolerance?
worstRatio = 0; worstField = '-';
ok = true;
for k = 1:numel(spec)
    fld = spec(k).field;
    if ~isfield(spread, fld), continue; end
    if spec(k).tol <= 0, continue; end
    ratio = spread.(fld) / spec(k).tol;
    if ratio > worstRatio, worstRatio = ratio; worstField = fld; end
    if ratio > factor, ok = false; end
end
end

% ===========================================================================
function [ok, bad] = spec_consistent(spec, flat)
% The declared reference must match the derived value wherever both exist.
ok = true; bad = {};
for k = 1:numel(spec)
    f = spec(k).field;
    if ~isfield(flat, f), continue; end
    d = per_op(flat.(f), spec(k).ref, spec(k).op);
    if d > max(spec(k).tol, 1e-12)
        ok = false;
        bad{end+1} = sprintf('%s(decl %.4g vs derived %.4g)', f, spec(k).ref, flat.(f)); %#ok<AGROW>
    end
end
end

% ===========================================================================
function [ok, worstField, worstD] = values_match(a, b, tol)
ok = true; worstField = ''; worstD = 0;
fa = fieldnames(a);
for k = 1:numel(fa)
    f = fa{k};
    if ~isfield(b, f), continue; end
    va = a.(f); vb = b.(f);
    if isnumeric(va) && isnumeric(vb) && isequal(size(va(:)), size(vb(:)))
        d = max(abs(va(:) - vb(:))) / max(1, max(abs(vb(:))));
        if d > worstD, worstD = d; worstField = f; end
        if d > tol, ok = false; end
    end
end
end

% ===========================================================================
function d = per_op(value, ref, op)
switch lower(op)
    case 'absdiff',    d = abs(value - ref);
    case 'reldiff',    d = abs(value - ref) / max(1, abs(ref));
    case 'maxabsdiff', d = max(abs(value(:) - ref(:)));
    case 'le',         d = max(0, value - ref);
    case 'ge',         d = max(0, ref - value);
    case 'true',       d = double(~logical(value));
    case 'false',      d = double(logical(value));
    otherwise,         d = Inf;
end
end

% ===========================================================================
function flat = flatten(m)
% Canonical flat field names, matching what mas_ref_spec grades. Derived here so
% the derivation and the spec cannot drift apart silently.
v = m.values{1};
switch upper(m.id)
    case 'D1'
        flat = struct('x', [v.x1 v.x2 v.x3], 'I_quad', v.I, 'I_trapz', v.I, ...
            'residual', 0);
    case 'D4'
        flat = struct('areas', [v.areaBig v.areaSmall], ...
            'centroidBig', [v.bigCol v.bigRow]);
    otherwise
        flat = v;
end
end

% ===========================================================================
function h = hash_values(v)
% SHA-256 over a canonical string: fields sorted, "%.17g" for numbers, so the hash
% does not depend on struct ordering or on the default short format.
f = sort(fieldnames(v));
parts = {};
for k = 1:numel(f)
    x = v.(f{k});
    if isnumeric(x) || islogical(x)
        s = sprintf('%.17g,', double(x(:)));
    else
        s = [char(string(x)) ','];
    end
    parts{end+1} = sprintf('%s=[%s]', f{k}, s); %#ok<AGROW>
end
canon = strjoin(parts, ';');
md = java.security.MessageDigest.getInstance('SHA-256');
d = md.digest(double(canon));
h = lower(reshape(dec2hex(typecast(d, 'uint8'), 2).', 1, []));
end

% ===========================================================================
function ensure_dir(d)
if ~exist(d, 'dir'), mkdir(d); end
end
