function res = phase52_heldout_run()
%PHASE52_HELDOUT_RUN  Measure every held-out case and grade it against the
%   frozen reference. The reference JSON is read; it is never regenerated here.
%
%   A hash mismatch fails the case even if every number matches, because a
%   tolerance edited after the fact is exactly what freezing is meant to stop.

here = fileparts(mfilename('fullpath'));
refFile = fullfile(here, 'heldout_reference.json');
if ~isfile(refFile)
    error('phase52:heldout:noReference', 'run phase52_heldout_freeze first');
end
M = jsondecode(fileread(refFile));
ids = fieldnames(M.entries);
fprintf('=== Phase 5.2 held-out (%s, frozen %s) ===\n', M.schema, M.frozenAt);
fprintf('%-4s %-38s %-8s %s\n', 'id', 'domain', 'verdict', 'detail');

R = struct('id', {}, 'domain', {}, 'pass', {}, 'hashOK', {}, ...
    'checks', {}, 'measured', {}, 'error', {});
for k = 1:numel(ids)
    id = ids{k};
    e = M.entries.(id);
    hashOK = strcmp(phase52_hash(e.values, e.checks), e.hash);
    try
        v = phase52_heldout_measure(id);
        [ok, detail, checks] = grade(v, e.checks);
        err = '';
    catch ME
        v = struct(); ok = false; checks = struct([]);
        detail = [ME.identifier ' :: ' ME.message];
        err = detail;
    end
    pass = ok && hashOK;
    if ~hashOK
        detail = ['HASH_CHANGED; ' detail];
    end
    R(end+1) = struct('id', id, 'domain', e.domain, 'pass', pass, ...
        'hashOK', hashOK, 'checks', checks, 'measured', v, 'error', err); %#ok<AGROW>
    fprintf('%-4s %-38s %-8s %s\n', id, e.domain, tern(pass, 'PASS', 'FAIL'), detail);
end

nP = nnz([R.pass]);
res = struct('level', 'phase52-heldout', 'nPass', nP, 'nTotal', numel(R), ...
    'cases', R, 'matlabVersion', version, 'timestamp', datestr(now, 31), ...
    'reference', refFile);
fprintf('\n---- %d / %d held-out cases passed ----\n', nP, numel(R));

outDir = fullfile(fileparts(fileparts(fileparts(here))), 'artifacts', 'phase52');
if ~isfolder(outDir), mkdir(outDir); end
fid = fopen(fullfile(outDir, 'heldout_results.json'), 'w');
fwrite(fid, jsonencode(res), 'char');
fclose(fid);
end

% ---------------------------------------------------------------------------
function [ok, detail, C] = grade(v, checks)
C = struct('field', {}, 'pass', {}, 'detail', {});
params = {};
for k = 1:numel(checks)
    c = checks(k);
    if ~isfield(v, c.field)
        p = false; d = 'measured field missing';
    else
        [p, d] = one(v.(c.field), c.ref, c.op, c.tol);
    end
    C(end+1) = struct('field', c.field, 'pass', p, 'detail', d); %#ok<AGROW>
    if ~p, params{end+1} = sprintf('%s: %s', c.field, d); end %#ok<AGROW>
end
ok = all([C.pass]);
if ok
    detail = sprintf('%d/%d checks', numel(C), numel(C));
else
    detail = strjoin(params, '; ');
end
end

function [ok, d] = one(a, b, op, tol)
switch lower(op)
    case 'str'
        ok = strcmp(char(string(a)), char(string(b)));
        d = sprintf('got %s, want %s', char(string(a)), char(string(b)));
    case 'true'
        ok = islogical(a) || isnumeric(a);
        ok = ok && logical(a) == true;
        d = sprintf('got %s', mat2str(a));
    case 'false'
        ok = (islogical(a) || isnumeric(a)) && logical(a) == false;
        d = sprintf('got %s', mat2str(a));
    case 'le'
        ok = isnumeric(a) && isscalar(a) && isfinite(a) && a <= b;
        d = sprintf('got %.12g, want <= %.12g', a, b);
    case 'absdiff'
        ok = isnumeric(a) && isscalar(a) && isfinite(a) && abs(a - b) <= tol;
        d = sprintf('got %.12g, want %.12g (tol %g)', a, b, tol);
    case 'reldiff'
        ok = isnumeric(a) && isscalar(a) && isfinite(a) && ...
            abs(a - b)/max(1, abs(b)) <= tol;
        d = sprintf('got %.12g, want %.12g (rel %g)', a, b, tol);
    case 'maxabsdiff'
        ok = isnumeric(a) && isnumeric(b) && isequal(size(a(:)), size(b(:))) && ...
            all(isfinite(a(:))) && max(abs(a(:) - b(:))) <= tol;
        if isnumeric(a) && isnumeric(b) && isequal(size(a(:)), size(b(:)))
            d = sprintf('maxdiff %.3g (tol %g)', max(abs(a(:) - b(:))), tol);
        else
            d = 'size mismatch or non-numeric';
        end
    otherwise
        ok = false; d = ['unknown op ' op];
end
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
