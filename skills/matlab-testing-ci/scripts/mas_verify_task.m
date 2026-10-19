function r = mas_verify_task(id, values, manifestFile)
%MAS_VERIFY_TASK  Grade a task's reported values against the FROZEN reference.
%
%   r = mas_verify_task('D3', out.values)
%   r.status   % PASS | FAIL | UNDETERMINED
%   r.perCheck struct array: field, got, ref, op, tol, pass, why
%
% WHY A SEPARATE VERIFIER
% A task that decides its own PASS is not being tested, it is being asked. The
% Phase 4 cross-domain tasks returned `out.status` computed from their own internal
% comparison; when the internal reference was wrong (D3, analog formula) the task
% agreed with itself and reported PASS on a number that was 3.9 dB off. Nothing in
% that loop could have caught it.
%
% Here the task only reports NUMBERS. Grading happens in this function, from the
% committed manifest, and never looks at the task's own verdict. If a task returns a
% field that is missing from the spec, that field is ignored; if a required field is
% missing from the task, the verdict is UNDETERMINED -- not PASS.
%
% UNDETERMINED exists for the same reason it exists in mas_grade: "we did not
% measure it" and "it is wrong" are different outcomes and must not collapse.

if nargin < 3 || isempty(manifestFile)
    here = fileparts(mfilename('fullpath'));
    repo = fileparts(fileparts(fileparts(here)));
    manifestFile = fullfile(repo, 'evals', 'references', 'reference_manifest.json');
end

r = struct('id', upper(id), 'status', 'UNDETERMINED', 'perCheck', ...
    struct('field', {}, 'got', {}, 'ref', {}, 'op', {}, 'tol', {}, 'pass', {}, 'why', {}), ...
    'detail', '', 'refHash', '', 'manifestFrozenAt', '');

if ~isfile(manifestFile)
    r.detail = 'reference manifest missing';
    return;
end
M = jsondecode(fileread(manifestFile));
if ~isfield(M.entries, upper(id))
    r.detail = sprintf('no frozen reference for "%s"', upper(id));
    return;
end
e = M.entries.(upper(id));
r.refHash = e.hash;
r.manifestFrozenAt = M.frozenAt;

nPass = 0; nMiss = 0;
for k = 1:numel(e.checks)
    c = e.checks(k);
    f = c.field;
    if isfield(values, f)
        got = values.(f);
    else
        % A missing field is not a failure of the value, it is missing evidence.
        r.perCheck(end+1) = struct('field', f, 'got', NaN, 'ref', c.ref, ...
            'op', c.op, 'tol', c.tol, 'pass', NaN, 'why', [c.why ' -- NOT REPORTED']);
        nMiss = nMiss + 1;
        continue;
    end
    ok = compare(got, c.ref, c.op, c.tol);
    r.perCheck(end+1) = struct('field', f, 'got', got, 'ref', c.ref, ...
        'op', c.op, 'tol', c.tol, 'pass', ok, 'why', c.why);
    nPass = nPass + ok;
end

if isempty(e.checks)
    r.status = 'UNDETERMINED';
    r.detail = 'reference exists but no grading spec was frozen';
elseif nMiss > 0
    r.status = 'UNDETERMINED';
    r.detail = sprintf('%d/%d checks passed, %d field(s) not reported', ...
        nPass, numel(e.checks), nMiss);
elseif nPass == numel(e.checks)
    r.status = 'PASS';
    r.detail = sprintf('%d/%d checks matched the frozen reference (%s)', ...
        nPass, numel(e.checks), e.hash(1:12));
else
    r.status = 'FAIL';
    bad = {};
    for k = 1:numel(r.perCheck)
        if isequal(r.perCheck(k).pass, false)
            bad{end+1} = sprintf('%s got %.6g want %.6g', r.perCheck(k).field, ...
                r.perCheck(k).got, r.perCheck(k).ref); %#ok<AGROW>
        end
    end
    r.detail = strjoin(bad, '; ');
end
end

% ---------------------------------------------------------------------------
function ok = compare(got, ref, op, tol)
ok = false;
if ~isnumeric(got) && ~islogical(got), return; end
switch lower(op)
    case 'absdiff',    ok = abs(got - ref) <= tol;
    case 'reldiff',    ok = abs(got - ref) <= tol*max(1, abs(ref));
    case 'maxabsdiff'
        if numel(got) ~= numel(ref), ok = false; return; end
        ok = max(abs(got(:) - ref(:))) <= tol;
    case 'le',         ok = got <= ref;
    case 'ge',         ok = got >= ref;
    case 'true',       ok = logical(got);
    case 'false',      ok = ~logical(got);
    otherwise,         ok = false;
end
end
