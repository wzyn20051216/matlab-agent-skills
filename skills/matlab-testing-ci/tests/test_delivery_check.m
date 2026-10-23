function res = test_delivery_check(verbose)
%TEST_DELIVERY_CHECK  Format and engineering math must fail independently.
%
%   res = test_delivery_check()
%
% The cases below are chosen so that every combination that was previously
% collapsed into one boolean appears at least once:
%   * right numbers, wrong schema          -> format FAIL, math PASS
%   * right schema, wrong numbers          -> format PASS, math FAIL
%   * wrong verdict with a valid schema    -> verdict FAIL, never coerced
%   * legal UNKNOWN / UNDETERMINED         -> not a schema error
%   * missing field / non-finite value     -> UNDETERMINED, not a pass
%   * legacy result without units          -> units UNRECORDED, not "not required"
%   * tampered reference manifest          -> reference FAIL, math untouched

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
addpath(fullfile(fileparts(here), 'scripts'));

tmp = fullfile(tempdir, sprintf('mas_delivery_%s', datestr(now, 'yyyymmddHHMMSSFFF')));
if ~isfolder(tmp), mkdir(tmp); end
cleaner = onCleanup(@() cleanup_dir(tmp)); %#ok<NASGU>

spec = struct();
spec.schema = 'mas-delivery-contract/1';
spec.profile = 'mas-result/2';
spec.taskId = 'P57-DLV-1';
spec.expectedVerdict = 'PASS';
spec.fields = struct( ...
    'name', {'settlingTime', 'overshoot', 'mode'}, ...
    'op', {'abs', 'abs', 'exact'}, ...
    'ref', {4.0, 16.3, 'stable'}, ...
    'tol', {0.05, 0.2, 0}, ...
    'unit', {'s', '%', ''});
spec.requiredFields = {'settlingTime', 'overshoot', 'mode'};
spec.units = struct('settlingTime', 's', 'overshoot', '%');
spec.enums = struct('verdict', {{'PASS', 'FAIL', 'UNDETERMINED', 'UNKNOWN'}});
spec.budget = struct('required', true, 'maxToolCalls', 8, 'maxWallSeconds', 120);

r = struct();
r.schema = 'mas-result/2';
r.taskId = 'P57-DLV-1';
r.verdict = 'PASS';
r.fields = struct('settlingTime', 4.02, 'overshoot', 16.25, 'mode', 'stable');
r.units = struct('settlingTime', 's', 'overshoot', '%');
r.budget = struct('toolCalls', 5, 'wallSeconds', 41);

nP = 0; nT = 0; fails = {};
if verbose, fprintf('=== delivery contract tests ===\n'); end

% ---- 1. a fully valid delivery --------------------------------------------
A = run_check(r, spec, {}, false);
chk_has(A.schema, 'mas-delivery-check/1', 'output schema');
chk(A.overall, 'PASS', 'valid delivery passes');
chk(A.format.status, 'PASS', 'format accepted');
chk(A.required.status, 'PASS', 'required fields present');
chk(A.units.status, 'PASS', 'units match');
chk(A.verdict.status, 'PASS', 'verdict matches');
chk(A.math.status, 'PASS', 'math within tolerance');
chk(A.budget.status, 'PASS', 'budget honoured');
chk(A.reference.status, 'NOT_REQUIRED', 'reference not requested');
chk(A.readOnly, true, 'checker declares itself read-only');
chk(A.verdictCoerced, false, 'checker never coerces');
chk(isempty(A.errors), true, 'no errors on a clean delivery');
chk(~A.separation.numericValidFormatInvalid && ~A.separation.formatValidNumericInvalid, ...
    true, 'no separation hint when both pass');
chk(A.math.engine, 'mas_grade', 'math delegates to mas_grade');
chk(isfield(A.math.grade, 'correct') && isfield(A.math.grade, 'meets'), true, ...
    'mas_grade keeps ran/correct/meets separate');

% ---- 2. wrong verdict: FAIL against a FAIL expectation ---------------------
r2 = r; r2.verdict = 'FAIL';
f2 = fullfile(tmp, 'result_wrong_verdict.json');
w(f2, jsonencode(r2));
raw2 = fileread(f2);
rep2 = fullfile(tmp, 'report_wrong_verdict.json');
A = run_check(f2, spec, {'outFile', rep2}, false);
chk(A.verdict.status, 'FAIL', 'wrong verdict fails the verdict dimension');
chk(A.verdict.actual, 'FAIL', 'actual verdict is reported as delivered');
chk(A.verdict.expected, 'PASS', 'expected verdict is reported');
chk(has_error(A, 'VERDICT_WRONG'), true, 'wrong verdict is a structured error');
chk(A.math.status, 'PASS', 'math still passes: numbers are not the problem');
% A wrong verdict is neither a format error nor a math error. The separation
% flags cover exactly those two axes, so both stay false and the verdict has
% its own dimension and its own error code.
chk(A.separation.numericValidFormatInvalid, false, ...
    'verdict failure is not mislabelled as a format error');
chk(A.separation.formatValidNumericInvalid, false, ...
    'verdict failure is not mislabelled as a math error');
chk(strcmp(fileread(f2), raw2), true, 'result file is never rewritten');
chk(A.verdictCoerced, false, 'wrong verdict is not rewritten to match');
P = jsondecode(fileread(rep2));
chk(P.schema, 'mas-delivery-check/1', 'report file carries the output schema');

% ---- 3. correct numbers, invalid schema -----------------------------------
r3 = rmfield(r, {'schema', 'taskId', 'units'});
A = run_check(r3, spec, {}, false);
chk(A.format.status, 'FAIL', 'missing schema/taskId fails the format dimension');
chk(has_error(A, 'SCHEMA_VERSION'), true, 'schema version error recorded');
chk(has_error(A, 'TASK_ID_MISSING'), true, 'task id error recorded');
chk(A.units.status, 'FAIL', 'missing units map fails the units dimension');
chk(has_error(A, 'UNITS_MISSING'), true, 'units error recorded');
chk(A.math.status, 'PASS', 'math passes although the schema does not');
chk(A.separation.numericValidFormatInvalid, true, 'hint separates math from format');
chk_has(A.separation.hint, 'fix the format, not the number', 'format hint text');
chk(A.overall, 'FAIL', 'invalid schema fails the delivery overall');

% ---- 4. a required field is absent ---------------------------------------
r4 = r; r4.fields = rmfield(r.fields, 'overshoot');
A = run_check(r4, spec, {}, false);
chk(A.required.status, 'FAIL', 'missing required field fails');
chk(has_error(A, 'REQUIRED_FIELD_MISSING'), true, 'structured missing-field error');
chk(A.math.status, 'UNDETERMINED', 'absent field leaves math undetermined');
chk(A.overall, 'FAIL', 'missing required field fails overall');

% ---- 5. UNKNOWN / UNDETERMINED are legal states --------------------------
spec5 = spec; spec5.expectedVerdict = 'UNDETERMINED';
spec5.fields(3).ref = 'UNKNOWN';
r5 = r; r5.verdict = 'UNDETERMINED'; r5.fields.mode = 'UNKNOWN';
A = run_check(r5, spec5, {}, false);
chk(A.verdict.status, 'PASS', 'UNDETERMINED matches an UNDETERMINED expectation');
chk(A.math.status, 'PASS', 'UNKNOWN matches an UNKNOWN reference exactly');
chk(A.enums.status, 'PASS', 'legal states are not enum errors');
chk(A.overall, 'PASS', 'legal unknown states can still pass');
r5b = r5; r5b.verdict = 'UNKNOWN';
A = run_check(r5b, spec5, {}, false);
chk(A.verdict.status, 'FAIL', 'a legal but different verdict still fails');
chk(A.enums.status, 'PASS', 'that failure is not a schema error');

% ---- 6. an illegal enum value -------------------------------------------
r6 = r; r6.verdict = 'MAYBE';
A = run_check(r6, spec, {}, false);
chk(A.enums.status, 'FAIL', 'illegal enum value fails the enum dimension');
chk(has_error(A, 'ENUM_VALUE'), true, 'enum error recorded');
chk(A.verdict.status, 'FAIL', 'illegal verdict fails the verdict dimension');
chk(has_error(A, 'VERDICT_ILLEGAL'), true, 'illegal verdict recorded');
chk(A.overall, 'FAIL', 'illegal enum fails overall');

% ---- 7. units ------------------------------------------------------------
r7 = r; r7.units.settlingTime = 'ms';
A = run_check(r7, spec, {}, false);
chk(A.units.status, 'FAIL', 'unit mismatch fails the units dimension');
chk(has_error(A, 'UNIT_MISMATCH'), true, 'unit mismatch recorded');
chk(A.math.status, 'PASS', 'unit mismatch does not invent a math failure');
chk(A.overall, 'FAIL', 'unit mismatch fails overall');
r7b = r; r7b.units.mass = 'kg';
A = run_check(r7b, spec, {}, false);
chk(A.units.status, 'PASS', 'unknown extra unit is a warning, not a failure');
chk(has_error(A, 'UNIT_UNKNOWN'), true, 'unknown unit warning recorded');
chk(A.overall, 'PASS', 'warning does not fail the delivery');

% ---- 8. right schema, wrong number --------------------------------------
r8 = r; r8.fields.settlingTime = 4.5;
A = run_check(r8, spec, {}, false);
chk(A.format.status, 'PASS', 'schema stays valid');
chk(A.math.status, 'FAIL', 'out-of-tolerance number fails math');
chk(has_error(A, 'MATH_MISMATCH'), true, 'math mismatch recorded');
chk(A.separation.formatValidNumericInvalid, true, ...
    'separation flags schema-valid / numbers-invalid');
chk_has(A.separation.hint, 'still wrong', 'math hint text');
chk(A.overall, 'FAIL', 'wrong number fails overall');

% ---- 9. non-finite evidence is not a pass -------------------------------
r9 = r; r9.fields.overshoot = NaN;
A = run_check(r9, spec, {}, false);
chk(A.math.status, 'UNDETERMINED', 'NaN leaves math undetermined');
chk(A.overall, 'UNDETERMINED', 'undetermined math makes the delivery undetermined');

% ---- 10. budget ---------------------------------------------------------
r10 = r; r10.budget.toolCalls = 12;
A = run_check(r10, spec, {}, false);
chk(A.budget.status, 'FAIL', 'budget overflow fails');
chk(has_error(A, 'BUDGET_EXCEEDED'), true, 'budget overflow recorded');
chk(A.overall, 'FAIL', 'budget overflow fails overall');
r10b = rmfield(r, 'budget');
A = run_check(r10b, spec, {}, false);
chk(A.budget.status, 'UNRECORDED', 'unrecorded usage is not a pass');
chk(A.overall, 'UNDETERMINED', 'unrecorded budget makes the delivery undetermined');

% ---- 11. unreadable / missing results -----------------------------------
f11 = fullfile(tmp, 'broken.json');
w(f11, '{ this is not json');
A = run_check(f11, spec, {}, false);
chk(A.overall, 'ERROR', 'unreadable result is an ERROR');
chk(has_error(A, 'RESULT_UNREADABLE'), true, 'unreadable result recorded');
A = run_check(fullfile(tmp, 'does_not_exist.json'), spec, {}, false);
chk(A.overall, 'ERROR', 'missing result is an ERROR');
chk(has_error(A, 'RESULT_MISSING'), true, 'missing result recorded');

% ---- 12. legacy profile: honest about what it cannot prove --------------
spec12 = spec; spec12.profile = 'mas-result/1-legacy';
r12 = struct('verdict', 'PASS', 'fields', ...
    struct('settlingTime', 4.0, 'overshoot', 16.3, 'mode', 'stable'));
A = run_check(r12, spec12, {}, false);
chk(A.format.status, 'PASS', 'legacy shape passes the legacy format rules');
chk(A.format.schemaVersion, 'legacy/none', 'legacy shape is labelled');
chk(A.units.status, 'UNRECORDED', 'legacy result cannot prove unit consistency');
chk(A.overall, 'UNDETERMINED', 'legacy delivery is honest about the gap');

% ---- 13. unknown profile -------------------------------------------------
spec13 = spec; spec13.profile = 'mas-result/9';
A = run_check(r, spec13, {}, false);
chk(A.format.status, 'FAIL', 'unknown profile fails the format dimension');
chk(has_error(A, 'PROFILE_UNKNOWN'), true, 'unknown profile recorded');

% ---- 14. task identity ---------------------------------------------------
r14 = r; r14.taskId = 'P57-DLV-OTHER';
A = run_check(r14, spec, {}, false);
chk(A.format.status, 'FAIL', 'wrong task id fails the format dimension');
chk(has_error(A, 'TASK_ID_MISMATCH'), true, 'task id mismatch recorded');

% ---- 15. exact string mismatch ------------------------------------------
r15 = r; r15.fields.mode = 'unstable';
A = run_check(r15, spec, {}, false);
chk(A.math.status, 'FAIL', 'exact string mismatch fails math');
chk(has_error(A, 'MATH_MISMATCH'), true, 'exact mismatch recorded');
chk(A.overall, 'FAIL', 'exact mismatch fails overall');

% ---- 16. a tampered reference manifest ----------------------------------
% Only the D3 entry is copied, so verification re-derives one reference
% instead of fifteen. The hash is zeroed: values still match the derivation,
% which isolates the hash guard from the value guard.
repo = fileparts(fileparts(fileparts(here)));
realManifest = fullfile(repo, 'evals', 'references', 'reference_manifest.json');
RM = jsondecode(fileread(realManifest));
d3 = RM.entries.D3;
d3.hash = repmat('0', 1, numel(char(d3.hash)));
fake = struct('schema', 'mas-reference/1', 'entries', struct('D3', d3));
f16 = fullfile(tmp, 'tampered_manifest.json');
w(f16, jsonencode(fake));
A = run_check(r, spec, {'referenceManifest', f16}, false);
chk(A.reference.status, 'FAIL', 'tampered manifest fails the reference dimension');
chk(has_error(A, 'REFERENCE_MISMATCH'), true, 'reference mismatch recorded');
chk(A.math.status, 'PASS', 'reference failure does not contaminate math');
chk(A.overall, 'FAIL', 'tampered reference fails overall');

% ---- 17. the versioned schema file agrees with the checker --------------
schemaFile = fullfile(repo, 'schemas', 'mas-result-2.schema.json');
chk(isfile(schemaFile), true, 'versioned result schema exists');
J = jsondecode(fileread(schemaFile));
chk(J.properties.schema.const, 'mas-result/2', 'schema pins the version string');
chk(isequal(sort(J.properties.verdict.enum(:))', ...
    sort({'PASS', 'FAIL', 'UNDETERMINED', 'UNKNOWN'})), true, ...
    'schema enum matches the legal verdict states');
req = J.required(:)';
chk(all(ismember({'schema', 'taskId', 'verdict', 'fields'}, req)), true, ...
    'schema requires the fields the checker enforces');
chk(J.properties.fields.type, 'object', 'schema requires fields to be an object');

res = struct('nPass', nP, 'nTotal', nT, 'pass', nP == nT, 'failures', {fails});
if verbose
    fprintf('\n---- %d / %d delivery contract cases passed ----\n', nP, nT);
    for k = 1:numel(fails)
        fprintf('  FAILED: %s\n', fails{k});
    end
end
if ~isempty(fails)
    error('test_delivery_check:case', '%d/%d cases failed: %s', ...
        numel(fails), nT, strjoin(fails, '; '));
end

    function A = run_check(result, sp, opts, v)
        A = mas_delivery_check(result, sp, opts{:}, 'verbose', v);
    end

    function chk(got, want, label)
        nT = nT + 1;
        if ischar(want)
            ok = ischar(got) && strcmp(got, want);
        else
            ok = isequal(got, want);
        end
        nP = nP + ok;
        if verbose
            fprintf('  [%s] %s\n', tern(ok, 'PASS', 'FAIL'), label);
        end
        if ~ok
            fails{end+1} = sprintf('%s (got %s, want %s)', label, tostr(got), tostr(want));
        end
    end

    function chk_has(hay, needle, label)
        nT = nT + 1;
        ok = ischar(hay) && ~isempty(strfind(hay, needle)); %#ok<STREMP>
        nP = nP + ok;
        if verbose
            fprintf('  [%s] %s\n', tern(ok, 'PASS', 'FAIL'), label);
        end
        if ~ok
            fails{end+1} = sprintf('%s (got "%s", want substring "%s")', ...
                label, hay, needle);
        end
    end
end

% ===========================================================================
function ok = has_error(R, code)
ok = any(strcmp({R.errors.code}, code));
end

function w(p, s)
d = fileparts(p);
if ~isfolder(d), mkdir(d); end
fid = fopen(p, 'w');
if fid < 0, error('test_delivery_check:write', 'cannot write %s', p); end
fwrite(fid, s, 'char'); fclose(fid);
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end

function s = tostr(v)
if ischar(v), s = v;
elseif islogical(v) && isscalar(v), s = mat2str(v);
elseif isnumeric(v) && isscalar(v), s = num2str(v);
else, s = class(v);
end
end

function cleanup_dir(p)
if isfolder(p), rmdir(p, 's'); end
end
