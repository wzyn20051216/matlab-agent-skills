function R = mas_delivery_check(result, spec, varargin)
%MAS_DELIVERY_CHECK  Check a delivered result against a versioned contract
%without letting format errors masquerade as math errors (or the reverse).
%
%   R = mas_delivery_check(resultFile, spec)
%   R = mas_delivery_check(resultStruct, spec, 'outFile', f, 'referenceManifest', m)
%
% The problem this solves: a result can carry the right number and the wrong
% schema, or the right schema and a wrong number. A single boolean cannot say
% which happened, and it invites "fixing" a wrong verdict until the schema
% accepts it. This function reports the two independently and never writes to
% the result.
%
% CONTRACT (spec)
%   schema             'mas-delivery-contract/1'
%   profile            'mas-result/1-legacy' (default) | 'mas-result/2'
%   taskId             required by profile 2
%   expectedVerdict    optional; compared, never coerced
%   fields             struct array of {name, op, ref, tol} (same vocabulary
%                      as benchmark answers) or {name, unit, required}
%   requiredFields     optional cellstr; defaults to field names
%   units              optional struct mapping field name -> unit
%   enums              optional struct mapping field name -> cellstr allowed
%   budget             struct with required/maxToolCalls/maxWallSeconds
%
% RESULT PROFILES
%   'mas-result/1-legacy'  requires `verdict` in the legal enum and `fields`
%                          as a struct; no schema/taskId/units. This is the
%                          Phase 5.6 shape, kept so history can be replayed.
%   'mas-result/2'        additionally requires schema='mas-result/2',
%                          taskId matching the contract, and a units map for
%                          every contract field that declares a unit.
%
% OUTPUT (schema mas-delivery-check/1)
%   format, required, units, enums, verdict, math, budget, reference,
%   separation, overall, errors. `math` calls mas_grade; `reference` calls
%   mas_refcheck. No numeric comparison is reimplemented here.
%
% LEGAL STATES
%   UNKNOWN and UNDETERMINED are legal verdict values and legal field values.
%   They are not schema errors. They are also not a pass: if a verdict is
%   required and the delivery says UNDETERMINED, the verdict dimension is FAIL
%   against a PASS/FAIL expectation and UNRECORDED against an UNDETERMINED
%   expectation is impossible (the value is recorded). Missing is UNRECORDED.

if nargin < 2
    error('mas_delivery_check:input', 'result and spec are required');
end
opt = struct('outFile', '', 'referenceManifest', '', 'verbose', true);
for k = 1:2:numel(varargin)
    switch lower(varargin{k})
        case 'outfile', opt.outFile = char(varargin{k+1});
        case 'referencemanifest', opt.referenceManifest = char(varargin{k+1});
        case 'verbose', opt.verbose = logical(varargin{k+1});
        otherwise, error('mas_delivery_check:option', 'unknown option "%s"', varargin{k});
    end
end

R = struct();
R.schema = 'mas-delivery-check/1';
R.checkedAt = datestr(now, 31);
R.source = '<struct>';
R.taskId = '';
R.profile = '';
R.readOnly = true;
R.verdictCoerced = false;
R.errors = empty_errors();
% Dimensions are pre-set so an early ERROR path can still be reported and
% written out. An unset field here used to make the summary line itself throw,
% replacing the real cause (missing result) with "unrecognized field".
R.format = struct('status', 'NOT_RUN', 'errors', empty_errors());
R.required = struct('status', 'NOT_RUN', 'errors', empty_errors());
R.enums = struct('status', 'NOT_RUN', 'errors', empty_errors());
R.units = struct('status', 'NOT_RUN', 'errors', empty_errors());
R.verdict = struct('status', 'NOT_RUN', 'errors', empty_errors());
R.math = struct('status', 'NOT_RUN', 'errors', empty_errors());
R.budget = struct('status', 'NOT_RUN', 'errors', empty_errors());
R.reference = struct('status', 'NOT_RUN', 'errors', empty_errors());

if ischar(result) || isstring(result)
    R.source = char(result);
    if ~isfile(R.source)
        R.errors = add_error(R.errors, 'RESULT_MISSING', R.source, 'result file not found', 'error');
        R.overall = 'ERROR';
        R = finish(R, opt);
        return;
    end
    try
        r = jsondecode(fileread(R.source));
    catch ME
        R.errors = add_error(R.errors, 'RESULT_UNREADABLE', R.source, ME.message, 'error');
        R.overall = 'ERROR';
        R = finish(R, opt);
        return;
    end
elseif isstruct(result)
    r = result;
else
    error('mas_delivery_check:input', 'result must be a path or a struct');
end

if ischar(spec) || isstring(spec)
    try
        spec = jsondecode(fileread(char(spec)));
    catch ME
        R.errors = add_error(R.errors, 'CONTRACT_UNREADABLE', char(spec), ME.message, 'error');
        R.overall = 'ERROR';
        R = finish(R, opt);
        return;
    end
end
if ~isstruct(spec)
    error('mas_delivery_check:contract', 'spec must be a struct or a JSON file');
end

R.profile = char(getf(spec, 'profile', 'mas-result/1-legacy'));
R.taskId = char(getf(spec, 'taskId', ''));
R.declaredVerdict = char(getf(spec, 'expectedVerdict', ''));

R.format = check_format(r, spec, R.profile);
R.required = check_required(r, spec);
R.enums = check_enums(r, spec);
R.units = check_units(r, spec, R.profile);
R.verdict = check_verdict(r, spec);
R.math = check_math(r, spec);
R.budget = check_budget(r, spec);

if isempty(opt.referenceManifest)
    R.reference = struct('status', 'NOT_REQUIRED', ...
        'detail', 'no reference manifest supplied', 'errors', empty_errors());
else
    R.reference = check_reference(opt.referenceManifest);
end

R.separation = separation(R);
R.errors = [R.format.errors(:); R.required.errors(:); R.enums.errors(:); ...
            R.units.errors(:); R.verdict.errors(:); R.math.errors(:); ...
            R.budget.errors(:); R.reference.errors(:)];
R.overall = overall(R);
R = finish(R, opt);
end

% ===========================================================================
function R = finish(R, opt)
if ~isempty(opt.outFile)
    fid = fopen(opt.outFile, 'w');
    if fid < 0, error('mas_delivery_check:write', 'cannot write %s', opt.outFile); end
    fwrite(fid, jsonencode(R, 'PrettyPrint', true), 'char');
    fclose(fid);
end
if opt.verbose
    fprintf('delivery %s: format %s | units %s | verdict %s | math %s | overall %s\n', ...
        ternary(isempty(R.taskId), R.source, R.taskId), R.format.status, R.units.status, ...
        R.verdict.status, R.math.status, R.overall);
end
end

function s = overall(R)
sts = {R.format.status, R.required.status, R.enums.status, R.units.status, ...
       R.verdict.status, R.math.status, R.budget.status, R.reference.status};
if any(strcmp(sts, 'FAIL'))
    s = 'FAIL';
elseif any(strcmp(sts, 'UNRECORDED')) || any(strcmp(sts, 'UNDETERMINED'))
    s = 'UNDETERMINED';
else
    s = 'PASS';
end
end

function S = separation(R)
formatOK = strcmp(R.format.status, 'PASS') && strcmp(R.required.status, 'PASS') && ...
    strcmp(R.enums.status, 'PASS') && (strcmp(R.units.status, 'PASS') || ...
    strcmp(R.units.status, 'NOT_REQUIRED'));
mathOK = strcmp(R.math.status, 'PASS');
mathBad = strcmp(R.math.status, 'FAIL');
S = struct();
S.numericValidFormatInvalid = mathOK && ~formatOK;
S.formatValidNumericInvalid = formatOK && mathBad;
if S.numericValidFormatInvalid
    S.hint = 'numbers pass their independent references but the delivery contract does not; fix the format, not the number';
elseif S.formatValidNumericInvalid
    S.hint = 'the delivery contract is valid but the engineering numbers do not meet the references; a schema-compliant wrong answer is still wrong';
else
    S.hint = '';
end
end

% ===========================================================================
function F = check_format(r, spec, profile)
F = struct('status', 'PASS', 'schemaVersion', char(getf(r, 'schema', 'legacy/none')), ...
    'errors', empty_errors());
if strcmp(profile, 'mas-result/2')
    if ~isfield(r, 'schema') || ~strcmp(char(r.schema), 'mas-result/2')
        F.errors = add_error(F.errors, 'SCHEMA_VERSION', 'schema', ...
            'expected "mas-result/2"', 'error');
    end
    want = char(getf(spec, 'taskId', ''));
    got = char(getf(r, 'taskId', ''));
    if isempty(got)
        F.errors = add_error(F.errors, 'TASK_ID_MISSING', 'taskId', ...
            'profile 2 requires taskId', 'error');
    elseif ~isempty(want) && ~strcmp(got, want)
        F.errors = add_error(F.errors, 'TASK_ID_MISMATCH', 'taskId', ...
            sprintf('"%s" vs contract "%s"', got, want), 'error');
    end
elseif strcmp(profile, 'mas-result/1-legacy')
    % The legacy shape has no schema or taskId; absence is not an error. It is
    % recorded as legacy/none so a reader can see the contract was not versioned.
else
    F.errors = add_error(F.errors, 'PROFILE_UNKNOWN', 'profile', ...
        sprintf('unknown profile "%s"', profile), 'error');
end
if ~isfield(r, 'verdict')
    F.errors = add_error(F.errors, 'VERDICT_MISSING', 'verdict', ...
        'verdict is a required top-level key', 'error');
end
if ~isfield(r, 'fields') || ~isstruct(r.fields)
    F.errors = add_error(F.errors, 'FIELDS_INVALID', 'fields', ...
        'fields must be an object', 'error');
end
F.status = status_from(F.errors);
end

function Q = check_required(r, spec)
Q = struct('status', 'PASS', 'nRequired', 0, 'missing', {{}}, 'errors', empty_errors());
names = required_names(spec);
Q.nRequired = numel(names);
if isempty(names)
    Q.status = 'NOT_REQUIRED';
    return;
end
if ~isfield(r, 'fields') || ~isstruct(r.fields)
    Q.errors = add_error(Q.errors, 'FIELDS_MISSING', 'fields', ...
        'required fields cannot be checked without a fields object', 'error');
else
    for k = 1:numel(names)
        key = matlab.lang.makeValidName(names{k});
        if ~isfield(r.fields, key)
            Q.missing{end+1} = names{k}; %#ok<AGROW>
            Q.errors = add_error(Q.errors, 'REQUIRED_FIELD_MISSING', ...
                ['fields.' names{k}], 'required field is absent', 'error');
        end
    end
end
Q.status = status_from(Q.errors);
end

function E = check_enums(r, spec)
E = struct('status', 'PASS', 'checked', {{}}, 'errors', empty_errors());
legal = {'PASS', 'FAIL', 'UNDETERMINED', 'UNKNOWN'};
if isfield(spec, 'enums') && isstruct(spec.enums)
    fn = fieldnames(spec.enums);
    for k = 1:numel(fn)
        allowed = as_cellstr(spec.enums.(fn{k}));
        val = getf(r, fn{k}, '__missing__');
        E.checked{end+1} = fn{k}; %#ok<AGROW>
        if strcmp(val, '__missing__')
            E.errors = add_error(E.errors, 'ENUM_MISSING', fn{k}, ...
                'enum field is absent', 'error');
        elseif ~any(strcmp(char(val), allowed))
            E.errors = add_error(E.errors, 'ENUM_VALUE', fn{k}, ...
                sprintf('"%s" not in {%s}', char(val), strjoin(allowed, ', ')), 'error');
        end
    end
else
    E.checked = {'verdict'};
    if isfield(r, 'verdict') && ~any(strcmp(char(r.verdict), legal))
        E.errors = add_error(E.errors, 'ENUM_VALUE', 'verdict', ...
            sprintf('"%s" not in {%s}', char(r.verdict), strjoin(legal, ', ')), 'error');
    end
end
E.status = status_from(E.errors);
end

function U = check_units(r, spec, profile)
U = struct('status', 'PASS', 'required', {{}}, 'declared', {{}}, 'errors', empty_errors());
[names, units] = contract_units(spec);
if isempty(names)
    U.status = 'NOT_REQUIRED';
    U.detail = 'contract declares no units';
    return;
end
U.required = names;
if isfield(r, 'units') && isstruct(r.units)
    U.declared = fieldnames(r.units);
elseif strcmp(profile, 'mas-result/1-legacy')
    % A legacy result carries no units map. The contract names units, so unit
    % consistency cannot be established -- that is UNRECORDED, not NOT_REQUIRED.
    % Calling it "not required" would quietly pass a dimension nobody checked.
    U.status = 'UNRECORDED';
    U.detail = 'legacy result has no units map; unit consistency is unknown';
    return;
else
    U.errors = add_error(U.errors, 'UNITS_MISSING', 'units', ...
        'units object is required when the contract declares units', 'error');
    U.status = status_from(U.errors);
    return;
end
for k = 1:numel(names)
    key = matlab.lang.makeValidName(names{k});
    if ~isfield(r.units, key)
        U.errors = add_error(U.errors, 'UNIT_MISSING', ['units.' names{k}], ...
            sprintf('required unit "%s"', units{k}), 'error');
    elseif ~strcmp(strtrim(char(r.units.(key))), units{k})
        U.errors = add_error(U.errors, 'UNIT_MISMATCH', ['units.' names{k}], ...
            sprintf('"%s" vs contract "%s"', char(r.units.(key)), units{k}), 'error');
    end
end
for k = 1:numel(U.declared)
    if ~any(strcmp(U.declared{k}, cellfun(@matlab.lang.makeValidName, names, 'UniformOutput', false)))
        U.errors = add_error(U.errors, 'UNIT_UNKNOWN', ['units.' U.declared{k}], ...
            'unit declared for a field the contract does not name', 'warning');
    end
end
U.status = status_from(U.errors);
end

function V = check_verdict(r, spec)
V = struct('status', 'NOT_REQUIRED', 'actual', '', 'expected', '', ...
    'legal', true, 'coerced', false, 'errors', empty_errors());
expected = char(getf(spec, 'expectedVerdict', ''));
if isempty(expected)
    V.detail = 'contract declares no expected verdict';
    return;
end
V.expected = expected;
actual = getf(r, 'verdict', '');
if isempty(actual)
    V.status = 'UNRECORDED';
    V.detail = 'verdict is missing; absence is not a pass';
    return;
end
V.actual = char(actual);
legal = {'PASS', 'FAIL', 'UNDETERMINED', 'UNKNOWN'};
V.legal = any(strcmp(V.actual, legal));
if ~V.legal
    V.status = 'FAIL';
    V.errors = add_error(V.errors, 'VERDICT_ILLEGAL', 'verdict', ...
        sprintf('"%s" is not a legal state', V.actual), 'error');
elseif strcmp(V.actual, expected)
    V.status = 'PASS';
else
    V.status = 'FAIL';
    V.errors = add_error(V.errors, 'VERDICT_WRONG', 'verdict', ...
        sprintf('"%s" vs expected "%s"; the checker never rewrites a verdict', ...
        V.actual, expected), 'error');
end
V.coerced = false;
end

function M = check_math(r, spec)
M = struct('status', 'NOT_REQUIRED', 'engine', 'mas_grade', 'grade', struct(), ...
    'checks', struct('id', {}, 'kind', {}, 'ok', {}, 'detail', {}), ...
    'errors', empty_errors());
[fields, ~] = contract_fields(spec);
if isempty(fields)
    return;
end
checks = struct('id', {}, 'executed', {}, 'kind', {}, 'value', {}, ...
    'reference', {}, 'tol', {}, 'limit', {}, 'cmp', {}, 'reason', {});
exactBad = false;
nExact = 0;
unrecorded = false;
for k = 1:numel(fields)
    f = fields{k};
    nm = char(getf(f, 'name', sprintf('field%d', k)));
    key = matlab.lang.makeValidName(nm);
    ref = getf(f, 'ref', []);
    op = lower(char(getf(f, 'op', 'exact')));
    tol = getf(f, 'tol', 0);
    if isempty(ref)
        continue;
    end
    if ~isfield(r, 'fields') || ~isfield(r.fields, key)
        unrecorded = true;
        M.checks(end+1) = struct('id', nm, 'kind', 'missing', 'ok', false, ...
            'detail', 'field absent; cannot evaluate'); %#ok<AGROW>
        continue;
    end
    value = r.fields.(key);
    if ischar(ref) || isstring(ref)
        ok = ischar(value) && strcmp(char(value), char(ref));
        exactBad = exactBad || ~ok;
        nExact = nExact + 1;
        M.checks(end+1) = struct('id', nm, 'kind', 'exact', 'ok', ok, ...
            'detail', ternary(ok, 'exact match', sprintf('"%s" vs "%s"', ...
            char(value), char(ref)))); %#ok<AGROW>
        if ~ok
            M.errors = add_error(M.errors, 'MATH_MISMATCH', ['fields.' nm], ...
                sprintf('"%s" vs "%s"', char(value), char(ref)), 'error');
        end
        continue;
    end
    if ~isnumeric(value) || isempty(value) || ~isscalar(value) || ~isfinite(value)
        unrecorded = true;
        M.checks(end+1) = struct('id', nm, 'kind', 'nonfinite', 'ok', false, ...
            'detail', 'value is empty/non-numeric/non-finite'); %#ok<AGROW>
        continue;
    end
    c = struct('id', nm, 'executed', true, 'kind', 'numeric', 'value', double(value), ...
        'reference', double(ref), 'tol', [], 'limit', [], 'cmp', '', 'reason', '');
    switch op
        case 'rel'
            c.tol = struct('rel', double(tol));
        case {'abs', 'maxabsdiff', 'exact'}
            c.tol = double(tol);
        case 'min'
            c.kind = 'domain';
            c.limit = double(ref) - double(tol);
            c.cmp = 'ge';
        case 'max'
            c.kind = 'domain';
            c.limit = double(ref) + double(tol);
            c.cmp = 'le';
        otherwise
            unrecorded = true;
            M.checks(end+1) = struct('id', nm, 'kind', 'op', 'ok', false, ...
                'detail', sprintf('unknown op "%s"', op)); %#ok<AGROW>
            continue;
    end
    checks(end+1) = c; %#ok<AGROW>
end

if ~isempty(checks)
    try
        g = mas_grade(checks);
        M.grade = g;
    catch ME
        M.status = 'UNDETERMINED';
        M.errors = add_error(M.errors, 'MAS_GRADE_ERROR', 'math', ME.message, 'error');
        return;
    end
    for k = 1:numel(checks)
        if strcmp(checks(k).kind, 'numeric')
            % Reconstruct per-check detail from mas_grade's failures for the
            % report; mas_grade remains the single numeric judge.
            ok = ~any(contains(g.failures, [checks(k).id ':']));
        else
            ok = true;
            for q = 1:numel(g.failures)
                if startsWith(g.failures{q}, [checks(k).id ':']) && ...
                        ~contains(g.failures{q}, 'not executed')
                    ok = false;
                end
            end
        end
        M.checks(end+1) = struct('id', checks(k).id, 'kind', checks(k).kind, ...
            'ok', ok, 'detail', ternary(ok, 'within tolerance', 'see mas_grade.failures')); %#ok<AGROW>
    end
    if isequal(g.correct, false) || isequal(g.meets, false)
        M.status = 'FAIL';
    elseif unrecorded
        M.status = 'UNDETERMINED';
    else
        M.status = 'PASS';
    end
elseif unrecorded
    M.status = 'UNDETERMINED';
elseif nExact > 0
    M.status = ternary(exactBad, 'FAIL', 'PASS');
else
    M.status = 'NOT_REQUIRED';
end
if exactBad
    M.status = 'FAIL';
end
if strcmp(M.status, 'FAIL') && ~isempty(M.grade) && isstruct(M.grade) && ...
        isfield(M.grade, 'failures')
    for k = 1:numel(M.grade.failures)
        M.errors = add_error(M.errors, 'MATH_MISMATCH', 'math', ...
            M.grade.failures{k}, 'error');
    end
end
end

function B = check_budget(r, spec)
B = struct('status', 'NOT_REQUIRED', 'limits', struct(), 'usage', struct(), ...
    'errors', empty_errors());
b = getf(spec, 'budget', struct());
if ~isstruct(b) || ~logical(getf(b, 'required', false))
    B.detail = 'contract declares no budget';
    return;
end
B.limits = b;
if ~isfield(b, 'maxToolCalls') && ~isfield(b, 'maxWallSeconds')
    B.status = 'UNRECORDED';
    B.errors = add_error(B.errors, 'BUDGET_UNSPECIFIED', 'budget', ...
        'a budget is required but the contract declares no limit', 'error');
    B.detail = 'see errors';
    return;
end
if ~isfield(r, 'budget') || ~isstruct(r.budget)
    B.status = 'UNRECORDED';
    B.detail = 'budget was required but the result records no usage';
    return;
end
usage = r.budget;
B.usage = usage;
if isfield(b, 'maxToolCalls')
    if ~isfield(usage, 'toolCalls') || ~isnumeric(usage.toolCalls) || ...
            ~isscalar(usage.toolCalls) || ~isfinite(usage.toolCalls) || usage.toolCalls < 0
        B.errors = add_error(B.errors, 'BUDGET_UNRECORDED', 'budget.toolCalls', ...
            'toolCalls is missing or invalid', 'error');
    elseif usage.toolCalls > b.maxToolCalls
        B.errors = add_error(B.errors, 'BUDGET_EXCEEDED', 'budget.toolCalls', ...
            sprintf('%g > %g', usage.toolCalls, b.maxToolCalls), 'error');
    end
end
if isfield(b, 'maxWallSeconds')
    if ~isfield(usage, 'wallSeconds') || ~isnumeric(usage.wallSeconds) || ...
            ~isscalar(usage.wallSeconds) || ~isfinite(usage.wallSeconds) || usage.wallSeconds < 0
        B.errors = add_error(B.errors, 'BUDGET_UNRECORDED', 'budget.wallSeconds', ...
            'wallSeconds is missing or invalid', 'error');
    elseif usage.wallSeconds > b.maxWallSeconds
        B.errors = add_error(B.errors, 'BUDGET_EXCEEDED', 'budget.wallSeconds', ...
            sprintf('%g > %g', usage.wallSeconds, b.maxWallSeconds), 'error');
    end
end
% An exceeded limit outranks a missing measurement: one is a fact about the
% run, the other is a gap in the record, and the stricter label must win.
if any(strcmp({B.errors.code}, 'BUDGET_EXCEEDED'))
    B.status = 'FAIL';
elseif any(strcmp({B.errors.code}, 'BUDGET_UNRECORDED'))
    B.status = 'UNRECORDED';
else
    B.status = 'PASS';
end
B.detail = ternary(strcmp(B.status, 'PASS'), 'within budget', 'see errors');
end

function F = check_reference(manifestFile)
F = struct('status', 'NOT_REQUIRED', 'detail', '', 'result', struct(), ...
    'errors', empty_errors());
try
    rr = mas_refcheck('verify', manifestFile);
    F.result = rr;
    if logical(rr.pass)
        F.status = 'PASS';
        F.detail = rr.detail;
    else
        F.status = 'FAIL';
        F.detail = rr.detail;
        F.errors = add_error(F.errors, 'REFERENCE_MISMATCH', manifestFile, ...
            rr.detail, 'error');
    end
catch ME
    F.status = 'FAIL';
    F.detail = ME.message;
    F.errors = add_error(F.errors, 'REFERENCE_ERROR', manifestFile, ME.message, 'error');
end
end

% ===========================================================================
function [names, units] = contract_units(spec)
names = {}; units = {};
if isfield(spec, 'units') && isstruct(spec.units)
    fn = fieldnames(spec.units);
    for k = 1:numel(fn)
        u = char(spec.units.(fn{k}));
        if ~isempty(strtrim(u))
            names{end+1} = fn{k}; %#ok<AGROW>
            units{end+1} = strtrim(u); %#ok<AGROW>
        end
    end
end
[fields, ~] = contract_fields(spec);
for k = 1:numel(fields)
    u = char(getf(fields{k}, 'unit', ''));
    nm = char(getf(fields{k}, 'name', ''));
    if ~isempty(u) && ~isempty(nm) && ~any(strcmp(names, nm))
        names{end+1} = nm; %#ok<AGROW>
        units{end+1} = strtrim(u); %#ok<AGROW>
    end
end
end

function [fields, names] = contract_fields(spec)
fields = {}; names = {};
if isfield(spec, 'fields')
    x = spec.fields;
    if isstruct(x), fields = num2cell(x(:));
    elseif iscell(x), fields = x(:);
    end
end
for k = 1:numel(fields)
    if isfield(fields{k}, 'name')
        names{end+1} = char(fields{k}.name); %#ok<AGROW>
    end
end
end

function names = required_names(spec)
names = {};
if isfield(spec, 'requiredFields'), names = as_cellstr(spec.requiredFields); end
[~, fn] = contract_fields(spec);
for k = 1:numel(fn)
    if ~any(strcmp(names, fn{k})), names{end+1} = fn{k}; end %#ok<AGROW>
end
end

function c = as_cellstr(x)
if isempty(x), c = {};
elseif ischar(x) || isstring(x), c = cellstr(x);
elseif iscell(x), c = cellfun(@char, x, 'UniformOutput', false);
else, c = {};
end
c = reshape(c, 1, []);
end

function s = status_from(errors)
s = 'PASS';
for k = 1:numel(errors)
    if strcmp(errors(k).severity, 'error'), s = 'FAIL'; return; end
end
end

function e = empty_errors()
e = struct('code', {}, 'path', {}, 'message', {}, 'severity', {});
end

function e = add_error(e, code, path, message, severity)
e(end+1) = struct('code', code, 'path', path, 'message', message, 'severity', severity);
end

function v = getf(s, name, dflt)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name)), v = s.(name); else, v = dflt; end
end

function out = ternary(cond, a, b)
if cond, out = a; else, out = b; end
end
