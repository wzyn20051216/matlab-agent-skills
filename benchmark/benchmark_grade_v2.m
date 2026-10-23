function G = benchmark_grade_v2(resultsDir, tasksFile, answersFile, manifestFile, scoringFile, outFile, varargin)
%BENCHMARK_GRADE_V2  Conditional scoring: route/tool are graded only when required.
%
%   G = benchmark_grade_v2(resultsDir, tasksFile, answersFile, manifestFile, ...
%                          scoringFile, outFile)
%   G = benchmark_grade_v2(..., outFile, 'agentRuns', n, 'arm', 'R1')
%
% Why a second protocol exists: v1 required routeOk && toolOk for every task.
% In Phase 5.6 the prompts deliberately asked for neither routing nor a tool
% declaration, and arm R1 had no Skills at all, so v1 reported 0/3 for every
% arm. That was a criterion mismatch, not an arm failure. v2 scores:
%
% SIX INDEPENDENT DIMENSIONS (reported separately per task and in aggregate):
%   1 mathematicalCorrectness   declared fields within their tolerances
%   2 engineeringVerdictCorrect expected verdict actually delivered
%   3 outputSchemaValid         versioned shape, task identity, legal enums
%   4 workflowCompliance        executed + route + tool, each only if required
%   5 withinBudget              declared budget honoured, missing usage = gap
%   6 deliveryValid             no false accept, no runner error, result present
%
% Internal detail dimensions (`executed`, `route`, `tool`, `fields`, `schema`,
% `budget`, `integrity`) remain in every row so a reader can see which
% sub-criterion drove a dimension.
%
% A requirement that applies but was not recorded is UNRECORDED and makes the
% task UNDETERMINED. It is never converted to PASS. A definite FAIL outranks
% an UNRECORDED gap: a wrong answer stays failed even when some other
% evidence is missing. A requirement that cannot apply to the arm (R1 has no
% Skills) is NOT_APPLICABLE_ARM and is excluded from the denominator, while
% still being printed. v1 files and reports are never read back as pass
% evidence and are never modified here.

if nargin < 6 || isempty(outFile)
    outFile = fullfile(resultsDir, 'grade_v2.json');
end
agentRuns = 0;
armName = '';
for k = 1:2:numel(varargin)
    switch lower(varargin{k})
        case 'agentruns'
            agentRuns = varargin{k+1};
        case 'arm'
            armName = char(varargin{k+1});
        otherwise
            error('benchmark_grade_v2:option', 'unknown option "%s"', varargin{k});
    end
end
if isempty(armName)
    [~, leaf] = fileparts(strip_trailing_sep(resultsDir));
    if startsWith(leaf, 'arm_'), armName = leaf(5:end); end
end

M = jsondecode(fileread(manifestFile));
if ~strcmp(char(M.tasksSha256), sha256_file(tasksFile))
    error('benchmark_grade_v2:tamper', 'tasks file changed after freeze');
end
if ~strcmp(char(M.answersSha256), sha256_file(answersFile))
    error('benchmark_grade_v2:tamper', 'answers file changed after freeze');
end
S = jsondecode(fileread(scoringFile));
if ~isfield(S, 'schema') || ~strcmp(char(S.schema), 'mas-benchmark-scoring/2')
    error('benchmark_grade_v2:scoring', 'scoring file schema must be mas-benchmark-scoring/2');
end

TF = jsondecode(fileread(tasksFile));
AF = jsondecode(fileread(answersFile));
T = TF.tasks; if isstruct(T), T = num2cell(T(:)); end
A = AF.tasks; if isstruct(A), A = num2cell(A(:)); end
amap = containers.Map('KeyType', 'char', 'ValueType', 'any');
for k = 1:numel(A), amap(char(A{k}.id)) = A{k}; end

arm = resolve_arm(S, armName);
rows = cell(1, numel(T));
for k = 1:numel(T)
    task = T{k}; id = char(task.id);
    req = resolve_requirements(S, id);
    rows{k} = grade_one(resultsDir, task, amap(id), req, arm);
end
R = [rows{:}];

G = struct();
G.schema = 'mas-benchmark-grade/2';
G.protocol = 'mas-benchmark-scoring/2';
G.gradedAt = datestr(now, 31);
G.resultsDir = resultsDir;
G.arm = arm.name;
G.armCapabilities = struct('hasSkills', arm.hasSkills, 'hasTools', arm.hasTools, ...
    'declaredBy', arm.declaredBy);
G.scoringFile = scoringFile;
G.scoringSha256 = sha256_file(scoringFile);
G.manifestSha256 = sha256_file(manifestFile);
G.agentRuns = agentRuns;
if agentRuns > 0
    G.baseline = 'independent agent episode (natural-language prompt, Skill loading, MATLAB MCP)';
    G.agentLevel = 'TESTED (partial holdout)';
else
    G.baseline = 'tool-level scripted policy (NOT an Agent benchmark)';
    G.agentLevel = 'NOT TESTED';
end
if isfield(S, 'replayOf')
    G.replay = struct('of', char(S.replayOf), 'kind', 'retrospective replay', ...
        'note', ['scored from stored results under protocol v2; not a new ' ...
                 'experiment and not comparable to v1 pass counts']);
else
    G.replay = struct('of', '', 'kind', 'prospective', 'note', '');
end
G.nTasks = numel(R);
G.nExecuted = nnz(strcmp({R.executed}, 'PASS'));
G.nMissing = nnz(strcmp({R.executed}, 'MISSING'));
G.nError = nnz(strcmp({R.executed}, 'ERROR'));
G.nPass = nnz(strcmp({R.overall}, 'PASS'));
G.nFail = nnz(strcmp({R.overall}, 'FAIL'));
G.nUndetermined = nnz(strcmp({R.overall}, 'UNDETERMINED'));
G.passAll = G.nPass == G.nTasks;
G.perDomain = group_counts(R, 'domain');
G.perKind = group_counts(R, 'kind');
G.dimensionNames = required_dimension_names();
G.dimensions = summarize_dimensions(R, G.dimensionNames, 'required');
G.detailDimensions = summarize_dimensions(R, detail_dimension_names(), 'dims');
G.rows = R;

fid = fopen(outFile, 'w');
if fid < 0, error('benchmark_grade_v2:write', 'cannot write %s', outFile); end
fwrite(fid, jsonencode(G, 'PrettyPrint', true), 'char'); fclose(fid);

fprintf('%-10s %-8s %-9s %-12s %-12s %-13s %s\n', ...
    'task', 'domain', 'kind', 'expected', 'actual', 'overall', 'criteria');
for k = 1:numel(R)
    fprintf('%-10s %-8s %-9s %-12s %-12s %-13s %s\n', R(k).taskId, R(k).domain, ...
        R(k).kind, R(k).expectedVerdict, R(k).actualVerdict, R(k).overall, R(k).note);
end
fprintf('\n%d/%d tasks PASS | executed %d | missing %d | error %d | fail %d | undetermined %d\n', ...
    G.nPass, G.nTasks, G.nExecuted, G.nMissing, G.nError, G.nFail, G.nUndetermined);
fprintf('arm %s: hasSkills=%d hasTools=%d\n', G.arm, arm.hasSkills, arm.hasTools);
fprintf('  math %s | verdict %s | schema %s | workflow %s | budget %s | delivery %s\n', ...
    dim_label(G.dimensions, 'mathematicalCorrectness'), ...
    dim_label(G.dimensions, 'engineeringVerdictCorrect'), ...
    dim_label(G.dimensions, 'outputSchemaValid'), ...
    dim_label(G.dimensions, 'workflowCompliance'), ...
    dim_label(G.dimensions, 'withinBudget'), ...
    dim_label(G.dimensions, 'deliveryValid'));
fprintf('  detail: route %s | tool %s | fields %s | integrity %s\n', ...
    dim_label(G.detailDimensions, 'route'), dim_label(G.detailDimensions, 'tool'), ...
    dim_label(G.detailDimensions, 'fields'), ...
    dim_label(G.detailDimensions, 'integrity'));
fprintf('grade v2 written to %s\n', outFile);
end

% ===========================================================================
function arm = resolve_arm(S, armName)
arm = struct('name', armName, 'hasSkills', true, 'hasTools', true, ...
    'declaredBy', 'default');
if isempty(armName), return; end
key = matlab.lang.makeValidName(armName);
if isfield(S, 'arms') && isfield(S.arms, key)
    a = S.arms.(key);
    arm.hasSkills = logical(getf(a, 'hasSkills', true));
    arm.hasTools = logical(getf(a, 'hasTools', true));
    arm.declaredBy = 'scoring file';
elseif isfield(S, 'requireArmDeclaration') && logical(S.requireArmDeclaration)
    error('benchmark_grade_v2:scoring', ...
        'arm "%s" is not declared in the scoring file', armName);
end
end

function req = resolve_requirements(S, id)
req = struct('routeRequired', true, 'toolRequired', true, ...
    'routeReason', 'default: routing required', 'toolReason', 'default: tool required', ...
    'schemaProfile', 'mas-result/1-legacy', 'budget', struct('required', false));
if isfield(S, 'defaults')
    req.routeRequired = logical(getf(S.defaults, 'routeRequired', true));
    req.toolRequired = logical(getf(S.defaults, 'toolRequired', true));
    req.schemaProfile = char(getf(S.defaults, 'schemaProfile', req.schemaProfile));
    req.budget = getf(S.defaults, 'budget', req.budget);
end
if isfield(S, 'tasks') && isfield(S.tasks, matlab.lang.makeValidName(id))
    t = S.tasks.(matlab.lang.makeValidName(id));
    req.routeRequired = logical(getf(t, 'routeRequired', req.routeRequired));
    req.toolRequired = logical(getf(t, 'toolRequired', req.toolRequired));
    req.routeReason = char(getf(t, 'routeReason', 'task declaration'));
    req.toolReason = char(getf(t, 'toolReason', 'task declaration'));
    req.schemaProfile = char(getf(t, 'schemaProfile', req.schemaProfile));
    req.budget = getf(t, 'budget', req.budget);
end
end

function row = grade_one(resultsDir, task, ans, req, arm)
id = char(task.id);
row = struct('taskId', id, 'domain', char(task.domain), 'kind', char(task.kind), ...
    'expectedSkill', char(ans.skill), 'actualSkill', '', ...
    'expectedTool', char(ans.tool), 'actualTool', '', ...
    'expectedVerdict', char(ans.verdict), 'actualVerdict', 'MISSING', ...
    'executed', 'MISSING', 'overall', 'MISSING', 'note', '', ...
    'routeRequired', req.routeRequired && arm.hasSkills, ...
    'toolRequired', req.toolRequired && arm.hasTools, ...
    'dims', struct('name', {}, 'status', {}, 'detail', {}), ...
    'required', struct('name', {}, 'status', {}, 'detail', {}), ...
    'fieldResults', struct('name', {}, 'ok', {}, 'detail', {}));

rf = fullfile(resultsDir, sprintf('result_%s.json', id));
if ~isfile(rf)
    row.dims = [dim('executed', 'MISSING', 'result file missing') ...
                dim('integrity', 'MISSING', 'no result to check')];
    row.required = uniform_dimensions('MISSING', 'result file missing');
    row.note = 'result file missing';
    return;
end
try
    r = jsondecode(fileread(rf));
catch ME
    row.executed = 'ERROR';
    row.overall = 'ERROR';
    row.dims = [dim('executed', 'ERROR', ['unreadable result: ' ME.message]) ...
                dim('integrity', 'ERROR', 'unreadable result')];
    row.required = uniform_dimensions('ERROR', ['unreadable result: ' ME.message]);
    row.note = ['unreadable result: ' ME.message];
    return;
end
row.executed = 'PASS';
row.dims(end+1) = dim('executed', 'PASS', 'result file readable');
row.actualSkill = char(getf(r, 'routePrimary', ''));
row.actualTool = char(getf(r, 'tool', ''));
row.actualVerdict = char(getf(r, 'verdict', 'MISSING'));

% 2 route
if ~req.routeRequired
    row.dims(end+1) = dim('route', 'NOT_REQUIRED', req.routeReason);
elseif ~arm.hasSkills
    row.dims(end+1) = dim('route', 'NOT_APPLICABLE_ARM', ...
        sprintf('arm "%s" has no Skills; a missing skill cannot be required', arm.name));
elseif ~has_recorded_route(r)
    row.dims(end+1) = dim('route', 'UNRECORDED', ...
        'routing was required but the result carries no route evidence');
else
    okRoute = strcmp(row.actualSkill, row.expectedSkill) && ...
        strcmp(char(getf(r, 'routeDecision', '')), 'ROUTE');
    row.dims(end+1) = dim('route', passfail(okRoute), ...
        sprintf('skill "%s" vs "%s", decision "%s"', row.actualSkill, ...
        row.expectedSkill, char(getf(r, 'routeDecision', ''))));
end

% 3 tool
if ~req.toolRequired
    row.dims(end+1) = dim('tool', 'NOT_REQUIRED', req.toolReason);
elseif ~arm.hasTools
    row.dims(end+1) = dim('tool', 'NOT_APPLICABLE_ARM', ...
        sprintf('arm "%s" has no MATLAB skill tools', arm.name));
elseif ~isfield(r, 'tool') || isempty(r.tool)
    row.dims(end+1) = dim('tool', 'UNRECORDED', ...
        'a tool was required but the result carries no tool evidence');
else
    row.dims(end+1) = dim('tool', passfail(strcmp(row.actualTool, row.expectedTool)), ...
        sprintf('"%s" vs "%s"', row.actualTool, row.expectedTool));
end

% 4 verdict
row.dims(end+1) = dim('verdict', passfail(strcmp(row.actualVerdict, row.expectedVerdict)), ...
    sprintf('%s vs %s', row.actualVerdict, row.expectedVerdict));

% 5 fields
if isfield(ans, 'fields') && ~isempty(ans.fields)
    F = ans.fields; if isstruct(F), F = num2cell(F(:)); end
    for q = 1:numel(F)
        spec = F{q};
        nm = char(spec.name);
        fr = struct('name', nm, 'ok', false, 'detail', '');
        [fr.ok, fr.detail] = compare_field(r, strrep(nm, '.', '_'), spec);
        row.fieldResults(end+1) = fr; %#ok<AGROW>
    end
end
fieldsOk = all([row.fieldResults.ok]);
if isempty(row.fieldResults)
    row.dims(end+1) = dim('fields', 'NOT_REQUIRED', 'no fields declared');
else
    bad = {row.fieldResults(~[row.fieldResults.ok]).name};
    row.dims(end+1) = dim('fields', passfail(fieldsOk), ...
        ternary(fieldsOk, 'all declared fields within tolerance', ...
        ['out of tolerance: ' strjoin(bad, ', ')]));
end

% 6 integrity
falseAccept = strcmp(row.expectedVerdict, 'FAIL') && strcmp(row.actualVerdict, 'PASS');
runnerError = strcmp(char(getf(r, 'status', '')), 'ERROR');
if falseAccept
    row.dims(end+1) = dim('integrity', 'FAIL', 'false accept: FAIL expected, PASS reported');
elseif runnerError
    row.dims(end+1) = dim('integrity', 'FAIL', ...
        ['runner error: ' char(getf(r, 'error', ''))]);
else
    row.dims(end+1) = dim('integrity', 'PASS', 'no false accept, runner completed');
end

% 7 schema
row.dims(end+1) = check_schema_dim(r, id, req, ...
    isfield(ans, 'fields') && ~isempty(ans.fields));

% 8 budget
row.dims(end+1) = check_budget_dim(r, req);

% six required dimensions + overall
row.required = required_dimensions(row);
statuses = {row.required.status};
if runnerError
    row.overall = 'ERROR';
elseif any(strcmp(statuses, 'FAIL'))
    % A definite failure is a fact. A gap elsewhere does not make it unknown.
    row.overall = 'FAIL';
elseif any(strcmp(statuses, 'UNRECORDED'))
    row.overall = 'UNDETERMINED';
else
    row.overall = 'PASS';
end

bits = {};
for q = 1:numel(row.dims)
    if strcmp(row.dims(q).status, 'FAIL'), bits{end+1} = row.dims(q).name; end %#ok<AGROW>
    if strcmp(row.dims(q).status, 'UNRECORDED'), bits{end+1} = [row.dims(q).name ':unrecorded']; end %#ok<AGROW>
end
if isempty(bits), row.note = 'all applicable criteria met'; ...
else, row.note = ['failed/unrecorded: ' strjoin(bits, ', ')]; end
end

function d = dim(name, status, detail)
d = struct('name', name, 'status', status, 'detail', detail);
end

function out = dim_label(D, name)
hit = D(strcmp({D.name}, name));
if isempty(hit), out = 'n/a'; else, out = hit(1).label; end
end

function ok = has_recorded_route(r)
ok = isfield(r, 'routePrimary') && ~isempty(r.routePrimary) && ...
     isfield(r, 'routeDecision') && ~isempty(r.routeDecision);
end

function s = passfail(ok)
s = ternary(ok, 'PASS', 'FAIL');
end

function v = getf(s, name, dflt)
if isfield(s, name) && ~isempty(s.(name)), v = s.(name); else, v = dflt; end
end

function [ok, detail] = compare_field(r, nm, spec)
ok = false; detail = '';
if ~isfield(r, 'fields') || ~isfield(r.fields, nm)
    detail = 'field missing from result';
    return;
end
a = r.fields.(nm);
ref = spec.ref;
op = char(spec.op);
tol = 0;
if isfield(spec, 'tol') && ~isempty(spec.tol), tol = spec.tol; end
if ischar(a) || ischar(ref)
    ok = strcmp(char(a), char(ref));
    detail = sprintf('"%s" vs "%s"', char(a), char(ref));
    return;
end
if ~isnumeric(a) || isempty(a)
    detail = 'field is not numeric';
    return;
end
switch lower(op)
    case 'exact'
        ok = isequal(double(a), double(ref));
        detail = sprintf('%s vs %s', mat2str(a), mat2str(ref));
    case 'abs'
        err = max(abs(double(a(:)) - double(ref(:))));
        ok = err <= tol;
        detail = sprintf('abs err %.3e <= %.3e', err, tol);
    case 'rel'
        err = max(abs(double(a(:)) - double(ref(:))));
        if all(double(ref(:)) == 0)
            lim = tol;
        else
            lim = tol * max(abs(double(ref(:))));
        end
        ok = err <= lim;
        detail = sprintf('abs err %.3e <= %.3e (rel %.3g)', err, lim, tol);
    case 'maxabsdiff'
        err = max(abs(double(a(:)) - double(ref(:))));
        ok = err <= tol;
        detail = sprintf('max|diff| %.3e <= %.3e', err, tol);
    case 'min'
        ok = double(a) >= double(ref) - tol;
        detail = sprintf('%.6g >= %.6g - %.3g', double(a), double(ref), tol);
    case 'max'
        ok = double(a) <= double(ref) + tol;
        detail = sprintf('%.6g <= %.6g + %.3g', double(a), double(ref), tol);
    otherwise
        detail = sprintf('unknown op "%s"', op);
end
end

function names = required_dimension_names()
names = {'mathematicalCorrectness', 'engineeringVerdictCorrect', ...
    'outputSchemaValid', 'workflowCompliance', 'withinBudget', 'deliveryValid'};
end

function names = detail_dimension_names()
names = {'executed', 'route', 'tool', 'verdict', 'fields', 'schema', ...
    'budget', 'integrity'};
end

function D = uniform_dimensions(status, detail)
names = required_dimension_names();
D = struct('name', names, 'status', status, 'detail', detail);
end

function D = required_dimensions(row)
d = @(name, status, detail) dim(name, status, detail);

fields = pick_dim(row.dims, 'fields');
verdict = pick_dim(row.dims, 'verdict');
schema = pick_dim(row.dims, 'schema');
route = pick_dim(row.dims, 'route');
tool = pick_dim(row.dims, 'tool');
executed = pick_dim(row.dims, 'executed');
budget = pick_dim(row.dims, 'budget');
integrity = pick_dim(row.dims, 'integrity');

parts = {sprintf('executed=%s', executed.status), ...
         sprintf('route=%s', route.status), sprintf('tool=%s', tool.status)};
st = {route.status, tool.status};
if ~strcmp(executed.status, 'PASS')
    wf = executed.status;
elseif any(strcmp(st, 'FAIL'))
    wf = 'FAIL';
elseif any(strcmp(st, 'UNRECORDED'))
    wf = 'UNRECORDED';
else
    wf = 'PASS';
end
workflow = d('workflowCompliance', wf, strjoin(parts, ', '));

parts = {sprintf('executed=%s', executed.status), ...
         sprintf('integrity=%s', integrity.status)};
if strcmp(integrity.status, 'FAIL') || strcmp(executed.status, 'ERROR')
    dv = 'FAIL';
elseif strcmp(executed.status, 'MISSING')
    dv = 'MISSING';
else
    dv = 'PASS';
end
delivery = d('deliveryValid', dv, strjoin(parts, ', '));

D = [d('mathematicalCorrectness', fields.status, fields.detail), ...
     d('engineeringVerdictCorrect', verdict.status, verdict.detail), ...
     d('outputSchemaValid', schema.status, schema.detail), ...
     workflow, d('withinBudget', budget.status, budget.detail), delivery];
end

function p = pick_dim(dims, name)
p = dims(strcmp({dims.name}, name));
if isempty(p), p = dim(name, 'UNRECORDED', 'dimension was never evaluated');
else, p = p(1); end
end

function S = check_schema_dim(r, id, req, fieldsDeclared)
issues = {};
switch req.schemaProfile
    case 'mas-result/2'
        if ~isfield(r, 'schema') || ~strcmp(char(r.schema), 'mas-result/2')
            issues{end+1} = 'schema is not "mas-result/2"'; %#ok<AGROW>
        end
        if ~isfield(r, 'taskId') || ~strcmp(char(r.taskId), id)
            issues{end+1} = sprintf('taskId does not identify "%s"', id); %#ok<AGROW>
        end
    case 'mas-result/1-legacy'
        % The Phase 5.6 shape has no schema or taskId; the file name carries the
        % task identity and the grader already opened that file. Absence is not
        % an error, but the profile is recorded in the scoring file.
    otherwise
        issues{end+1} = sprintf('unknown schema profile "%s"', req.schemaProfile); %#ok<AGROW>
end
if ~isfield(r, 'verdict')
    issues{end+1} = 'verdict key is absent'; %#ok<AGROW>
elseif ~any(strcmp(char(r.verdict), legal_verdicts()))
    issues{end+1} = sprintf('verdict "%s" is not a legal enum value', char(r.verdict)); %#ok<AGROW>
end
if fieldsDeclared && (~isfield(r, 'fields') || ~isstruct(r.fields))
    issues{end+1} = 'fields must be an object when the task declares fields'; %#ok<AGROW>
end
if isempty(issues)
    S = dim('schema', 'PASS', sprintf('profile %s accepted', req.schemaProfile));
else
    S = dim('schema', 'FAIL', strjoin(issues, '; '));
end
end

function B = check_budget_dim(r, req)
b = req.budget;
if ~isstruct(b) || ~logical(getf(b, 'required', false))
    B = dim('budget', 'NOT_REQUIRED', 'contract declares no budget');
    return;
end
if ~isfield(r, 'budget') || ~isstruct(r.budget)
    B = dim('budget', 'UNRECORDED', 'budget required but the result records no usage');
    return;
end
issues = {}; kinds = {};
if isfield(b, 'maxToolCalls')
    if ~isfield(r.budget, 'toolCalls') || ~isnumeric(r.budget.toolCalls) || ...
            ~isscalar(r.budget.toolCalls) || ~isfinite(r.budget.toolCalls) || ...
            r.budget.toolCalls < 0
        issues{end+1} = 'toolCalls is missing or invalid'; kinds{end+1} = 'gap'; %#ok<AGROW>
    elseif r.budget.toolCalls > b.maxToolCalls
        issues{end+1} = sprintf('toolCalls %g > %g', r.budget.toolCalls, b.maxToolCalls);
        kinds{end+1} = 'fail'; %#ok<AGROW>
    end
end
if isfield(b, 'maxWallSeconds')
    if ~isfield(r.budget, 'wallSeconds') || ~isnumeric(r.budget.wallSeconds) || ...
            ~isscalar(r.budget.wallSeconds) || ~isfinite(r.budget.wallSeconds) || ...
            r.budget.wallSeconds < 0
        issues{end+1} = 'wallSeconds is missing or invalid'; kinds{end+1} = 'gap'; %#ok<AGROW>
    elseif r.budget.wallSeconds > b.maxWallSeconds
        issues{end+1} = sprintf('wallSeconds %g > %g', r.budget.wallSeconds, b.maxWallSeconds);
        kinds{end+1} = 'fail'; %#ok<AGROW>
    end
end
if any(strcmp(kinds, 'fail'))
    B = dim('budget', 'FAIL', strjoin(issues, '; '));
elseif any(strcmp(kinds, 'gap'))
    B = dim('budget', 'UNRECORDED', strjoin(issues, '; '));
else
    B = dim('budget', 'PASS', 'within the declared budget');
end
end

function v = legal_verdicts()
v = {'PASS', 'FAIL', 'UNDETERMINED', 'UNKNOWN'};
end

function D = summarize_dimensions(R, names, field)
D = struct('name', {}, 'applicable', {}, 'pass', {}, 'fail', {}, 'notRequired', {}, ...
    'notApplicableArm', {}, 'unrecorded', {}, 'label', {});
for k = 1:numel(names)
    st = {};
    for q = 1:numel(R)
        dims = R(q).(field);
        s = dims(strcmp({dims.name}, names{k}));
        if ~isempty(s), st{end+1} = s(1).status; end %#ok<AGROW>
    end
    nPass = nnz(strcmp(st, 'PASS'));
    nFail = nnz(strcmp(st, 'FAIL'));
    nNr = nnz(strcmp(st, 'NOT_REQUIRED'));
    nNa = nnz(strcmp(st, 'NOT_APPLICABLE_ARM'));
    nUn = nnz(strcmp(st, 'UNRECORDED'));
    applicable = nPass + nFail + nUn;
    D(end+1) = struct('name', names{k}, 'applicable', applicable, 'pass', nPass, ...
        'fail', nFail, 'notRequired', nNr, 'notApplicableArm', nNa, ...
        'unrecorded', nUn, 'label', sprintf('%d/%d scored, %d N/R, %d N/A, %d unrec', ...
        nPass, applicable, nNr, nNa, nUn)); %#ok<AGROW>
end
end

function G = group_counts(R, field)
vals = {R.(field)};
u = unique(vals);
G = struct('name', {}, 'n', {}, 'nPass', {}, 'nFail', {}, 'nUndetermined', {});
for k = 1:numel(u)
    hit = strcmp(vals, u{k});
    G(end+1) = struct('name', u{k}, 'n', nnz(hit), ...
        'nPass', nnz(hit & strcmp({R.overall}, 'PASS')), ...
        'nFail', nnz(hit & strcmp({R.overall}, 'FAIL')), ...
        'nUndetermined', nnz(hit & strcmp({R.overall}, 'UNDETERMINED'))); %#ok<AGROW>
end
end

function s = strip_trailing_sep(p)
s = p;
while ~isempty(s) && (s(end) == '\' || s(end) == '/'), s(end) = []; end
end

function h = sha256_file(p)
fid = fopen(p, 'r');
if fid < 0, error('benchmark_grade_v2:hash', 'cannot open %s', p); end
b = fread(fid, Inf, '*uint8'); fclose(fid);
md = java.security.MessageDigest.getInstance('SHA-256');
d = typecast(md.digest(b), 'uint8');
h = lower(reshape(dec2hex(d)', 1, []));
end

function out = ternary(cond, a, b)
if cond, out = a; else, out = b; end
end
