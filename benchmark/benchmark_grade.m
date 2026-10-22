function G = benchmark_grade(resultsDir, tasksFile, answersFile, manifestFile, outFile, varargin)
%BENCHMARK_GRADE  Grade benchmark results against the sealed answer file.
%
%   G = benchmark_grade(resultsDir, tasksFile, answersFile, manifestFile)
%   G = benchmark_grade(..., outFile, 'agentRuns', n)
%
% Runs on the isolated evaluation side. Refuses to grade if the tasks or answers
% do not hash to the values frozen in the manifest. The grader never executes
% the task; it reads the result JSONs the runner produced and compares them with
% the sealed expectations (route, tool, verdict, declared numeric fields).
%
% The summary is explicit about what was measured. A tool-level run (the
% default) is never presented as an Agent benchmark; an actual agent episode
% must be declared by the caller via 'agentRuns'. Unexecuted tasks are reported
% as missing and are never counted as false rejects or extrapolated into a
% success rate.

if nargin < 5 || isempty(outFile)
    outFile = fullfile(resultsDir, 'grade.json');
end
agentRuns = 0;
for k = 1:2:numel(varargin)
    if strcmpi(varargin{k}, 'agentRuns')
        agentRuns = varargin{k+1};
    else
        error('benchmark_grade:option', 'unknown option "%s"', varargin{k});
    end
end
M = jsondecode(fileread(manifestFile));
if ~strcmp(char(M.tasksSha256), sha256_file(tasksFile))
    error('benchmark_grade:tamper', 'tasks file changed after freeze');
end
if ~strcmp(char(M.answersSha256), sha256_file(answersFile))
    error('benchmark_grade:tamper', 'answers file changed after freeze');
end

TF = jsondecode(fileread(tasksFile));
AF = jsondecode(fileread(answersFile));
T = TF.tasks; if isstruct(T), T = num2cell(T(:)); end
A = AF.tasks; if isstruct(A), A = num2cell(A(:)); end
amap = containers.Map('KeyType', 'char', 'ValueType', 'any');
for k = 1:numel(A), amap(char(A{k}.id)) = A{k}; end

rows = cell(1, numel(T));
for k = 1:numel(T)
    task = T{k}; id = char(task.id);
    rows{k} = grade_one(resultsDir, task, amap(id));
end
R = [rows{:}];

G = struct();
G.schema = 'mas-benchmark-grade/1';
G.gradedAt = datestr(now, 31);
G.resultsDir = resultsDir;
G.manifestSha256 = sha256_file(manifestFile);
G.agentRuns = agentRuns;
if agentRuns > 0
    G.baseline = 'independent agent episode (natural-language prompt, Skill loading, MATLAB MCP)';
    G.agentLevel = 'TESTED (partial holdout)';
    G.agentLevelReason = sprintf(['%d independent agent episode(s) executed; only the ' ...
        'executed tasks are graded and no success rate is extrapolated to the full holdout'], ...
        agentRuns);
else
    G.baseline = 'tool-level scripted policy (NOT an Agent benchmark)';
    G.agentLevel = 'NOT TESTED';
    G.agentLevelReason = ['no independent agent episode was executed; the runner is a ' ...
        'deterministic policy, so only tool-level evidence is reported'];
end
G.nTasks = numel(R);
G.nExecuted = nnz(~strcmp({R.actualVerdict}, 'MISSING'));
G.nMissing = G.nTasks - G.nExecuted;
G.nPass = nnz([R.pass]);
G.nFail = numel(R) - G.nPass;
G.nExecutedPass = nnz([R.pass] & ~strcmp({R.actualVerdict}, 'MISSING'));
G.routePass = nnz([R.routeOk]);
G.toolPass = nnz([R.toolOk]);
G.verdictPass = nnz([R.verdictOk]);
G.falseAccepts = nnz([R.falseAccept]);
G.falseRejects = nnz(strcmp({R.expectedVerdict}, 'PASS') & ...
    ~strcmp({R.actualVerdict}, 'PASS') & ~strcmp({R.actualVerdict}, 'MISSING'));
G.rows = R;
G.perDomain = group_counts(R, 'domain');
G.perKind = group_counts(R, 'kind');
G.passAll = G.nPass == G.nTasks;

fid = fopen(outFile, 'w');
if fid < 0, error('benchmark_grade:write', 'cannot write %s', outFile); end
fwrite(fid, jsonencode(G), 'char'); fclose(fid);

fprintf('%-10s %-8s %-9s %-12s %-12s %-7s %s\n', ...
    'task', 'domain', 'kind', 'expected', 'actual', 'pass', 'criteria');
for k = 1:numel(R)
    fprintf('%-10s %-8s %-9s %-12s %-12s %-7d %s\n', R(k).taskId, R(k).domain, ...
        R(k).kind, R(k).expectedVerdict, R(k).actualVerdict, R(k).pass, R(k).note);
end
fprintf('\n%d/%d tasks | executed %d/%d (pass %d) | route %d/%d | tool %d/%d | verdict %d/%d | false accepts %d | false rejects %d\n', ...
    G.nPass, G.nTasks, G.nExecuted, G.nTasks, G.nExecutedPass, ...
    G.routePass, G.nTasks, G.toolPass, G.nTasks, ...
    G.verdictPass, G.nTasks, G.falseAccepts, G.falseRejects);
fprintf('baseline: %s\nagent level: %s (%s)\n', G.baseline, G.agentLevel, G.agentLevelReason);
fprintf('grade written to %s\n', outFile);
end

% ===========================================================================
function row = grade_one(resultsDir, task, ans)
id = char(task.id);
row = struct('taskId', id, 'domain', char(task.domain), 'kind', char(task.kind), ...
    'expectedSkill', char(ans.skill), 'actualSkill', '', 'routeOk', false, ...
    'expectedTool', char(ans.tool), 'actualTool', '', 'toolOk', false, ...
    'expectedVerdict', char(ans.verdict), 'actualVerdict', 'MISSING', ...
    'verdictOk', false, 'pass', false, 'falseAccept', false, 'note', '', ...
    'fieldResults', struct('name', {}, 'ok', {}, 'detail', {}));
rf = fullfile(resultsDir, sprintf('result_%s.json', id));
if ~isfile(rf)
    row.note = 'result file missing';
    return;
end
try
    r = jsondecode(fileread(rf));
catch ME
    row.note = ['unreadable result: ' ME.message];
    return;
end
row.actualTool = char(getf(r, 'tool', ''));
row.actualSkill = char(getf(r, 'routePrimary', ''));
row.actualVerdict = char(getf(r, 'verdict', 'MISSING'));
row.routeOk = strcmp(row.actualSkill, row.expectedSkill) && ...
    strcmp(char(getf(r, 'routeDecision', '')), 'ROUTE');
row.toolOk = strcmp(row.actualTool, row.expectedTool);
row.verdictOk = strcmp(row.actualVerdict, row.expectedVerdict);
row.falseAccept = strcmp(row.expectedVerdict, 'FAIL') && strcmp(row.actualVerdict, 'PASS');

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
row.pass = row.routeOk && row.toolOk && row.verdictOk && fieldsOk;

bits = {};
if ~row.routeOk, bits{end+1} = 'route'; end
if ~row.toolOk, bits{end+1} = 'tool'; end
if ~row.verdictOk, bits{end+1} = 'verdict'; end
if ~fieldsOk, bits{end+1} = 'fields'; end
if isempty(bits), row.note = 'all criteria met'; else, row.note = ['failed: ' strjoin(bits, ', ')]; end
if strcmp(char(getf(r, 'status', '')), 'ERROR')
    row.note = ['runner error: ' char(getf(r, 'error', ''))];
end
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

function G = group_counts(R, field)
vals = {R.(field)};
u = unique(vals);
G = struct('name', {}, 'n', {}, 'nPass', {});
for k = 1:numel(u)
    G(end+1) = struct('name', u{k}, 'n', nnz(strcmp(vals, u{k})), ...
        'nPass', nnz(strcmp(vals, u{k}) & [R.pass])); %#ok<AGROW>
end
end

function h = sha256_file(p)
fid = fopen(p, 'r');
if fid < 0, error('benchmark_grade:hash', 'cannot open %s', p); end
b = fread(fid, Inf, '*uint8'); fclose(fid);
md = java.security.MessageDigest.getInstance('SHA-256');
d = typecast(md.digest(b), 'uint8');
h = lower(reshape(dec2hex(d)', 1, []));
end
