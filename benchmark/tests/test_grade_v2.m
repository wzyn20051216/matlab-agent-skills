function res = test_grade_v2(verbose)
%TEST_GRADE_V2  Pins the conditional scoring contract introduced in Phase 5.7.
%
%   res = test_grade_v2()
%
% The fixtures cover the cases v1 could not express: a requirement that does
% not apply to the arm, a requirement that applies but has no recorded
% evidence, a missing result, and a false accept. v1 files must not change.

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
bench = fileparts(here);
addpath(bench);

base = fullfile(tempdir, sprintf('mas_grade_v2_%s', datestr(now, 'yyyymmddHHMMSSFFF')));
scoringFile = fullfile(base, 'scoring.json');
r2 = fullfile(base, 'arm_R2');
r1 = fullfile(base, 'arm_R1');
mkdir(r2); mkdir(r1);
cleaner = onCleanup(@() rmdir(base, 's')); %#ok<NASGU>

tasksR2 = fullfile(base, 'tasks_R2.json');
answersR2 = fullfile(base, 'answers_R2.json');
manifestR2 = fullfile(base, 'manifest_R2.json');
tasksR1 = fullfile(base, 'tasks_R1.json');
answersR1 = fullfile(base, 'answers_R1.json');
manifestR1 = fullfile(base, 'manifest_R1.json');
mk_tasks(tasksR2, {'T-ROUTE', 'T-BASIC', 'T-WRONG', 'T-FA', 'T-UNREC', ...
    'T-MISSING', 'T-ENUM'});
mk_answers(answersR2, {'T-ROUTE', 'T-BASIC', 'T-WRONG', 'T-FA', 'T-UNREC', ...
    'T-MISSING', 'T-ENUM'});
mk_manifest(manifestR2, tasksR2, answersR2);
mk_tasks(tasksR1, {'T-NA', 'T-BASIC'});
mk_answers(answersR1, {'T-NA', 'T-BASIC'});
mk_manifest(manifestR1, tasksR1, answersR1);
mk_scoring(scoringFile);

wjson(fullfile(r2, 'result_T-ROUTE.json'), result('matlab-signal-vision-ai', ...
    'ROUTE', 'mas_x', 'PASS', 1.0));
wjson(fullfile(r2, 'result_T-BASIC.json'), result('', '', '', 'UNDETERMINED', 2.0));
wjson(fullfile(r2, 'result_T-WRONG.json'), result('matlab-signal-vision-ai', ...
    'ROUTE', 'mas_x', 'PASS', 9.0));
wjson(fullfile(r2, 'result_T-FA.json'), result('matlab-data-analysis', ...
    'ROUTE', 'mas_ode', 'PASS', 1.0));
wjson(fullfile(r2, 'result_T-UNREC.json'), result('', '', '', 'PASS', 1.0));
% T-ENUM: correct number, illegal verdict, no route/tool evidence, over budget.
% It exists to prove that a definite FAIL is not downgraded to UNDETERMINED by
% an UNRECORDED gap elsewhere.
wjson(fullfile(r2, 'result_T-ENUM.json'), result('', '', '', 'MAYBE', 1.0, 99));
wjson(fullfile(r1, 'result_T-NA.json'), result('', '', '', 'PASS', 1.0));
wjson(fullfile(r1, 'result_T-BASIC.json'), result('', '', '', 'UNDETERMINED', 2.0));

nP = 0; nT = 0;
if verbose, fprintf('=== grading protocol v2 tests ===\n'); end
chk(exist('benchmark_grade.m', 'file') == 2, true, 'v1 grader still exists');
v1path = fullfile(bench, 'benchmark_grade.m');
v1before = sha256_file(v1path);

G2 = benchmark_grade_v2(r2, tasksR2, answersR2, manifestR2, scoringFile, ...
    fullfile(base, 'grade_R2.json'));
chk(G2.schema, 'mas-benchmark-grade/2', 'schema v2');
chk(G2.protocol, 'mas-benchmark-scoring/2', 'protocol v2');
chk(G2.arm, 'R2', 'arm inferred from dir');
chk(G2.replay.of, 'phase56', 'replay label is explicit');
chk(G2.nTasks, 7, 'seven tasks in the R2 fixture');
chk(G2.nPass, 2, 'two passes');
chk(G2.nFail, 3, 'three failures');
chk(G2.nUndetermined, 1, 'one undetermined');
chk(G2.nMissing, 1, 'one missing');
chk(G2.passAll, false, 'not all tasks pass');
chk(numel(G2.dimensions), 6, 'six required dimensions are reported');
chk(isequal({G2.dimensions.name}, G2.dimensionNames), true, ...
    'aggregate dimensions carry the required names');

r = by_id(G2.rows, 'T-ROUTE');
chk(r.overall, 'PASS', 'required+recorded route and tool passes');
chk(getdim(r, 'route').status, 'PASS', 'route dimension scored');
chk(getdim(r, 'tool').status, 'PASS', 'tool dimension scored');
chk(getreq(r, 'mathematicalCorrectness').status, 'PASS', 'math dimension passes');
chk(getreq(r, 'engineeringVerdictCorrect').status, 'PASS', 'verdict dimension passes');
chk(getreq(r, 'outputSchemaValid').status, 'PASS', 'schema dimension passes');
chk(getreq(r, 'workflowCompliance').status, 'PASS', 'workflow dimension passes');
chk(getreq(r, 'withinBudget').status, 'PASS', 'declared budget is honoured');
chk(getreq(r, 'deliveryValid').status, 'PASS', 'delivery dimension passes');

r = by_id(G2.rows, 'T-BASIC');
chk(r.overall, 'PASS', 'task without route/tool requirements passes');
chk(getdim(r, 'route').status, 'NOT_REQUIRED', 'route not required is stated');
chk(getdim(r, 'tool').status, 'NOT_REQUIRED', 'tool not required is stated');
chk(getreq(r, 'workflowCompliance').status, 'PASS', ...
    'workflow is satisfied by execution alone when route/tool do not apply');
chk(getreq(r, 'withinBudget').status, 'NOT_REQUIRED', ...
    'no budget declared means the dimension leaves the denominator');

r = by_id(G2.rows, 'T-UNREC');
chk(r.overall, 'UNDETERMINED', 'required but unrecorded route is undetermined');
chk(getdim(r, 'route').status, 'UNRECORDED', 'unrecorded route is not a pass');
chk(getdim(r, 'tool').status, 'UNRECORDED', 'unrecorded tool is not a pass');
chk(getreq(r, 'workflowCompliance').status, 'UNRECORDED', ...
    'workflow dimension carries the gap');

r = by_id(G2.rows, 'T-MISSING');
chk(r.overall, 'MISSING', 'missing result is not a fail');
chk(r.executed, 'MISSING', 'executed dimension missing');
chk(getreq(r, 'deliveryValid').status, 'MISSING', 'delivery dimension is missing');

r = by_id(G2.rows, 'T-FA');
chk(r.overall, 'FAIL', 'false accept fails');
chk(getdim(r, 'integrity').status, 'FAIL', 'integrity catches the false accept');
chk(getreq(r, 'deliveryValid').status, 'FAIL', 'delivery dimension catches it');

r = by_id(G2.rows, 'T-WRONG');
chk(r.overall, 'FAIL', 'wrong field fails');
chk(getdim(r, 'fields').status, 'FAIL', 'fields dimension names the failure');
chk(getreq(r, 'mathematicalCorrectness').status, 'FAIL', 'math dimension names it');

r = by_id(G2.rows, 'T-ENUM');
chk(getreq(r, 'outputSchemaValid').status, 'FAIL', 'illegal enum fails the schema dimension');
chk(getreq(r, 'mathematicalCorrectness').status, 'PASS', ...
    'the number is right even though the schema is not');
chk(getreq(r, 'withinBudget').status, 'FAIL', 'budget overflow fails that dimension');
chk(getreq(r, 'workflowCompliance').status, 'UNRECORDED', ...
    'missing route/tool evidence is recorded as a gap');
chk(r.overall, 'FAIL', 'a definite failure outranks a missing-evidence gap');

G1 = benchmark_grade_v2(r1, tasksR1, answersR1, manifestR1, scoringFile, ...
    fullfile(base, 'grade_R1.json'));
chk(G1.arm, 'R1', 'R1 arm inferred');
r = by_id(G1.rows, 'T-NA');
chk(r.overall, 'PASS', 'an arm without Skills is not punished for route');
chk(getdim(r, 'route').status, 'NOT_APPLICABLE_ARM', 'route marked not applicable to arm');
chk(getdim(r, 'tool').status, 'NOT_APPLICABLE_ARM', 'tool marked not applicable to arm');
chk(getreq(r, 'workflowCompliance').status, 'PASS', ...
    'workflow passes on execution when route/tool cannot apply to the arm');
chk(dstat(G1.detailDimensions, 'route').notApplicableArm, 1, ...
    'aggregate counts not-applicable route');
chk(dstat(G1.detailDimensions, 'route').applicable, 0, ...
    'not-applicable route leaves the denominator');

chk(sha256_file(v1path), v1before, 'v1 grader byte-identical after v2 run');
chk(G2.scoringSha256, sha256_file(scoringFile), 'scoring file hash recorded');

% guards
badTasks = fullfile(base, 'tasks_bad.json');
txt = fileread(tasksR2); txt = strrep(txt, 'T-ROUTE', 'T-ROUTE-X');
fid = fopen(badTasks, 'w'); fwrite(fid, txt, 'char'); fclose(fid);
chk(throws(@() benchmark_grade_v2(r2, badTasks, answersR2, manifestR2, scoringFile, ...
    fullfile(base, 'x.json'))), true, 'tasks hash mismatch is rejected');

badScoring = fullfile(base, 'scoring_bad.json');
S = jsondecode(fileread(scoringFile)); S.schema = 'mas-benchmark-scoring/1';
fid = fopen(badScoring, 'w'); fwrite(fid, jsonencode(S), 'char'); fclose(fid);
chk(throws(@() benchmark_grade_v2(r2, tasksR2, answersR2, manifestR2, badScoring, ...
    fullfile(base, 'y.json'))), true, 'wrong scoring schema is rejected');

badArm = fullfile(base, 'scoring_arm.json');
S = jsondecode(fileread(scoringFile)); S.arms = rmfield(S.arms, 'R2');
fid = fopen(badArm, 'w'); fwrite(fid, jsonencode(S), 'char'); fclose(fid);
chk(throws(@() benchmark_grade_v2(r2, tasksR2, answersR2, manifestR2, badArm, ...
    fullfile(base, 'z.json'))), true, 'undeclared arm is rejected when required');

% The real Phase 5.6 replay runs separately (p57_grade_v2_replay). Here we only
% require that its scoring file parses and keeps v1 separate.
retro = fullfile(bench, 'scoring_p56_retro.json');
if isfile(retro)
    R = jsondecode(fileread(retro));
    chk(R.schema, 'mas-benchmark-scoring/2', 'retro scoring file is v2');
    chk(R.requireArmDeclaration, true, 'retro file declares every arm');
    chk(isfield(R.tasks, matlab.lang.makeValidName('P56-SIG-B')), true, ...
        'retro file declares each task');
else
    chk(true, true, 'retro scoring file absent in this checkout');
end

res = struct('nPass', nP, 'nTotal', nT, 'pass', nP == nT);
if verbose
    fprintf('\n---- %d / %d v2 grading cases passed ----\n', nP, nT);
end

    function chk(got, want, label)
        nT = nT + 1;
        if ischar(want), ok = ischar(got) && strcmp(got, want);
        else, ok = isequal(got, want); end
        nP = nP + ok;
        if verbose, fprintf('  [%s] %s\n', ternary(ok, 'PASS', 'FAIL'), label); end
        if ~ok
            error('test_grade_v2:case', '%s (got %s, want %s)', label, ...
                tostr(got), tostr(want));
        end
    end
end

% ===========================================================================
function mk_tasks(p, ids)
tasks = [];
for k = 1:numel(ids)
    [domain, kind, v] = meta(ids{k});
    tasks = [tasks; task(ids{k}, domain, kind, v)]; %#ok<AGROW>
end
wjson(p, struct('schema', 'fixture-tasks/1', 'tasks', tasks));
end

function t = task(id, domain, kind, verdict)
t = struct('id', id, 'domain', domain, 'kind', kind, 'expectedVerdict', verdict);
end

function [domain, kind, verdict] = meta(id)
switch id
    case 'T-ROUTE',   domain = 'sig';  kind = 'number';    verdict = 'PASS';
    case 'T-BASIC',   domain = 'data'; kind = 'judgement'; verdict = 'UNDETERMINED';
    case 'T-WRONG',   domain = 'sig';  kind = 'number';    verdict = 'PASS';
    case 'T-FA',      domain = 'data'; kind = 'number';    verdict = 'FAIL';
    case 'T-UNREC',   domain = 'sig';  kind = 'number';    verdict = 'PASS';
    case 'T-MISSING', domain = 'data'; kind = 'number';    verdict = 'PASS';
    case 'T-NA',      domain = 'sig';  kind = 'number';    verdict = 'PASS';
    case 'T-ENUM',    domain = 'sig';  kind = 'number';    verdict = 'PASS';
    otherwise, error('test_grade_v2:meta', 'unknown fixture id %s', id);
end
end

function mk_answers(p, ids)
tasks = [];
for k = 1:numel(ids)
    id = ids{k};
    [~, ~, v] = meta(id);
    ref = 1.0;
    if strcmp(id, 'T-BASIC'), ref = 2.0; end
    fields = struct('name', 'k', 'op', 'exact', 'ref', ref, 'tol', 0);
    switch id
        case {'T-ROUTE', 'T-WRONG', 'T-UNREC', 'T-NA', 'T-ENUM'}
            skill = 'matlab-signal-vision-ai'; tool = 'mas_x';
        case {'T-FA', 'T-MISSING'}
            skill = 'matlab-data-analysis'; tool = 'mas_ode';
        otherwise
            skill = ''; tool = '';
    end
    tasks = [tasks; aspec(id, skill, tool, v, fields)]; %#ok<AGROW>
end
wjson(p, struct('schema', 'fixture-answers/1', 'tasks', tasks));
end

function a = aspec(id, skill, tool, verdict, fields)
a = struct('id', id, 'skill', skill, 'tool', tool, 'verdict', verdict, 'fields', fields);
end

function mk_manifest(p, tasksFile, answersFile)
m = struct('schema', 'fixture-manifest/1', ...
    'tasksSha256', sha256_file(tasksFile), 'answersSha256', sha256_file(answersFile));
wjson(p, m);
end

function mk_scoring(p)
S = struct();
S.schema = 'mas-benchmark-scoring/2';
S.protocolVersion = '2.0';
S.replayOf = 'phase56';
S.requireArmDeclaration = true;
S.defaults = struct('routeRequired', true, 'toolRequired', true);
S.arms = struct();
S.arms.R1 = struct('hasSkills', false, 'hasTools', false, 'reason', 'fixture no skills');
S.arms.R2 = struct('hasSkills', true, 'hasTools', true, 'reason', 'fixture full');
S.tasks = struct();
S.tasks.T_BASIC = struct('routeRequired', false, 'toolRequired', false, ...
    'routeReason', 'fixture declares no routing', 'toolReason', 'fixture declares no tool');
S.tasks.T_ROUTE = struct('budget', struct('required', true, ...
    'maxToolCalls', 5, 'maxWallSeconds', 60));
S.tasks.T_ENUM = struct('budget', struct('required', true, ...
    'maxToolCalls', 5, 'maxWallSeconds', 60));
wjson(p, S);
end

function r = result(skill, decision, tool, verdict, k, toolCalls)
if nargin < 6, toolCalls = 3; end
r = struct('status', 'OK', 'routePrimary', skill, 'routeDecision', decision, ...
    'tool', tool, 'verdict', verdict, 'fields', struct('k', k), ...
    'budget', struct('toolCalls', toolCalls, 'wallSeconds', 10));
end

function wjson(p, v)
fid = fopen(p, 'w');
if fid < 0, error('test_grade_v2:write', 'cannot write %s', p); end
fwrite(fid, jsonencode(v), 'char'); fclose(fid);
end

function r = by_id(rows, id)
r = rows(strcmp({rows.taskId}, id));
if isempty(r), error('test_grade_v2:missing', 'no row for %s', id); end
r = r(1);
end

function d = getdim(row, name)
d = row.dims(strcmp({row.dims.name}, name));
if isempty(d), error('test_grade_v2:missing', 'no dimension %s', name); end
d = d(1);
end

function d = getreq(row, name)
d = row.required(strcmp({row.required.name}, name));
if isempty(d), error('test_grade_v2:missing', 'no required dimension %s', name); end
d = d(1);
end

function d = dstat(D, name)
d = D(strcmp({D.name}, name));
if isempty(d), error('test_grade_v2:missing', 'no aggregate %s', name); end
d = d(1);
end

function tf = throws(fn)
try
    fn(); tf = false;
catch
    tf = true;
end
end

function s = tostr(v)
if ischar(v), s = v; elseif islogical(v), s = mat2str(v); else, s = mat2str(v); end
end

function out = ternary(c, a, b)
if c, out = a; else, out = b; end
end

function h = sha256_file(p)
fid = fopen(p, 'r');
if fid < 0, error('test_grade_v2:hash', 'cannot open %s', p); end
b = fread(fid, Inf, '*uint8'); fclose(fid);
md = java.security.MessageDigest.getInstance('SHA-256');
d = typecast(md.digest(b), 'uint8');
h = lower(reshape(dec2hex(d)', 1, []));
end
