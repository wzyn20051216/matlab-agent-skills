function run_task5_benchmark()
% Task 5: freeze, audit, run the tool-level baseline and grade it.
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(here));
addpath(fullfile(repo, 'benchmark'));

holdout = 'E:\desktop\MATLAB-bench-holdout-phase53';
hTasks = fullfile(holdout, 'tasks.json');
hAns = fullfile(holdout, 'answers.json');
hMan = fullfile(holdout, 'manifest.json');
dTasks = fullfile(repo, 'benchmark', 'dev', 'tasks.json');
dAns = fullfile(repo, 'benchmark', 'dev', 'answers.json');
dMan = fullfile(repo, 'benchmark', 'dev', 'manifest.json');
outRoot = fullfile(here, 'benchmark');
hOut = fullfile(outRoot, 'results_holdout');
dOut = fullfile(outRoot, 'results_dev');

fprintf('===== freeze (before any evaluation) =====\n');
benchmark_freeze(hTasks, hAns, hMan);
benchmark_freeze(dTasks, dAns, dMan);

fprintf('\n===== isolation audit =====\n');
A = benchmark_audit(repo, holdout, hMan);
for k = 1:numel(A.checks)
    fprintf('%-24s %s  %s\n', A.checks(k).id, tag(A.checks(k).pass), A.checks(k).detail);
end
fprintf('audit ok = %d\n', A.ok);
save_json(fullfile(outRoot, 'isolation_audit.json'), A);

fprintf('\n===== held-out tool-level run =====\n');
RH = benchmark_run(hTasks, hOut);
fprintf('ran %d task(s)\n', RH.nTasks);

fprintf('\n===== held-out grade =====\n');
GH = benchmark_grade(hOut, hTasks, hAns, hMan, fullfile(hOut, 'grade.json'));

fprintf('\n===== dev self-test =====\n');
RD = benchmark_run(dTasks, dOut); %#ok<NASGU>
GD = benchmark_grade(dOut, dTasks, dAns, dMan, fullfile(dOut, 'grade.json'));

S = struct('holdoutRun', RM_run(RH), 'holdoutGrade', RM_grade(GH), ...
    'devGrade', RM_grade(GD), 'auditOk', A.ok, 'generatedAt', datestr(now, 31), ...
    'matlabVersion', version);
save_json(fullfile(outRoot, 'task5_summary.json'), S);
fprintf('\nsummary written to %s\n', fullfile(outRoot, 'task5_summary.json'));
end

function t = tag(b)
if b, t = 'PASS'; else, t = 'FAIL'; end
end

function s = RM_run(x)
s = struct('nTasks', x.nTasks, 'tasksSha256', x.tasksSha256, ...
    'rows', numel(x.rows), 'startedAt', x.startedAt, 'finishedAt', x.finishedAt);
end

function s = RM_grade(x)
s = struct('nTasks', x.nTasks, 'nPass', x.nPass, 'nFail', x.nFail, ...
    'routePass', x.routePass, 'toolPass', x.toolPass, ...
    'verdictPass', x.verdictPass, 'falseAccepts', x.falseAccepts, ...
    'baseline', x.baseline, 'agentLevel', x.agentLevel);
end

function save_json(p, obj)
fid = fopen(p, 'w');
if fid >= 0, fwrite(fid, jsonencode(obj), 'char'); fclose(fid); end
end
