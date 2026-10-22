function run_holdout()
%RUN_HOLDOUT  Run + grade the frozen held-out benchmark (tool-level baseline).
%
%   MAS_BENCH_HOLDOUT_ROOT   external evaluation root (tasks/answers/manifest)
%   MAS_BENCH_OUT            result folder, default <root>/runs/latest
%
% Results default to the evaluation side, not the repository: the graded output
% names expected verdicts and per-task outcomes, which must not become part of
% the workspace handed to an agent.
%
% This entry point NEVER freezes. Freezing is a separate, explicit act
% (benchmark_freeze.m) performed before the run; re-freezing after seeing a
% result would defeat the freeze. The manifest hash is checked by both the
% audit and the grader.
%
% The runner is a deterministic policy, so the output is a tool-level baseline,
% not an Agent benchmark. The grade file states this explicitly.

here = fileparts(mfilename('fullpath'));
repo = fileparts(here);
addpath(here);

root = getenv('MAS_BENCH_HOLDOUT_ROOT');
if isempty(root)
    root = 'E:\desktop\MATLAB-bench-holdout-phase53';
end
outDir = getenv('MAS_BENCH_OUT');
if isempty(outDir)
    outDir = fullfile(root, 'runs', 'latest');
end

tasks = fullfile(root, 'tasks.json');
answers = fullfile(root, 'answers.json');
manifest = fullfile(root, 'manifest.json');
if ~isfile(manifest)
    error('run_holdout:notFrozen', ['no manifest at %s. Freeze tasks and answers ' ...
        'before running; see benchmark/README.md.'], manifest);
end

fprintf('===== isolation audit =====\n');
A = benchmark_audit(repo, root, manifest);
for k = 1:numel(A.checks)
    if A.checks(k).pass, tag = 'PASS'; else, tag = 'FAIL'; end
    fprintf('%-24s %s  %s\n', A.checks(k).id, tag, A.checks(k).detail);
end
if ~A.ok
    error('run_holdout:isolation', 'isolation audit failed; refusing to run');
end

fprintf('\n===== held-out tool-level run =====\n');
R = benchmark_run(tasks, outDir); %#ok<NASGU>

fprintf('\n===== held-out grade =====\n');
G = benchmark_grade(outDir, tasks, answers, manifest, fullfile(outDir, 'grade.json')); %#ok<NASGU>
fprintf('\n%s\n', 'This is a tool-level baseline. Agent-level competence is NOT TESTED.');
end
