function res = run_all(outDir)
%RUN_ALL  One command: every skill test suite, the reference check, the cross-domain
%         tasks and the routed pipeline.
%
%   res = run_all()
%   res = run_all('artifacts/validation/phase4')
%
% Nothing here grades itself. Each suite returns a pass count, the references are
% verified against their frozen hashes, and the cross-domain tasks are graded by
% mas_verify_task from the manifest -- not by their own `out.status`.

if nargin < 1 || isempty(outDir), outDir = getenv('MAS_OUT'); end
if isempty(outDir), outDir = fullfile(pwd, 'artifacts', 'validation', 'phase4'); end
outDir = strrep(outDir, '/', filesep);

here = fileparts(mfilename('fullpath'));
% phase4 -> validation -> matlab -> repo: THREE levels, not four. Counting wrong
% makes every addpath a no-op and every suite fail with "undefined function for
% input arguments of type logical", which reads like a data problem and is not.
repo = fileparts(fileparts(fileparts(here)));
addpath(here);
for d = { ...
    'skills/matlab-orchestrator/scripts', 'skills/matlab-orchestrator/tests', ...
    'skills/matlab-runner/scripts',       'skills/matlab-runner/tests', ...
    'skills/matlab-testing-ci/scripts',   'skills/matlab-testing-ci/tests', ...
    'skills/matlab-simulink-modeling/scripts', 'skills/matlab-simulink-modeling/tests', ...
    'skills/matlab-control-optimization/scripts', 'skills/matlab-control-optimization/tests', ...
    'skills/matlab-data-analysis/scripts', 'skills/matlab-data-analysis/tests', ...
    'matlab/validation/crossdomain', 'matlab/validation/crossdomain/tasks'}
    p = fullfile(repo, d{1});
    if isfolder(p), addpath(p); end
end
if ~exist(outDir, 'dir'), mkdir(outDir); end

fprintf('########## Phase 4.2 verification ##########\n\n');
t0 = tic;

suites = { ...
  'routing',      @() test_routing(false); ...
  'precheck',     @() test_precheck(false); ...
  'depProbe',     @() test_dep_probe(false); ...
  'grading',      @() test_grade(false); ...
  'refcheck',     @() test_refcheck(false); ...
  'modelCheck',   @() test_model_check(false); ...
  'ctrlAnalyze',  @() test_ctrl_analyze(false); ...
  'tableAudit',   @() test_table_audit(false) };

S = struct('name', {}, 'pass', {}, 'total', {}, 'ok', {});
nP = 0; nT = 0;
for k = 1:size(suites, 1)
    try
        r = suites{k, 2}();
        S(end+1) = struct('name', suites{k,1}, 'pass', r.nPass, 'total', r.nTotal, ...
            'ok', r.nPass == r.nTotal); %#ok<AGROW>
        nP = nP + r.nPass; nT = nT + r.nTotal;
        fprintf('%-14s %3d / %3d\n', suites{k,1}, r.nPass, r.nTotal);
    catch ME
        S(end+1) = struct('name', suites{k,1}, 'pass', 0, 'total', NaN, 'ok', false); %#ok<AGROW>
        fprintf('%-14s ERROR: %s\n', suites{k,1}, ME.message);
    end
end

fprintf('\n-- references --\n');
ref = mas_refcheck('verify');

fprintf('\n-- cross-domain --\n');
cd_ = run_crossdomain(outDir);

fprintf('\n-- routed pipeline --\n');
pl = mas_pipeline('all', struct('outDir', outDir, 'verbose', true));

res = struct();
res.level = 'Phase4.2';
res.suites = S;
res.skillPass = nP;
res.skillTotal = nT;
res.references = struct('pass', ref.nPass, 'total', ref.nTotal, 'ok', ref.pass);
res.crossdomain = struct('pass', cd_.nPass, 'fail', cd_.nFail, ...
    'undetermined', cd_.nUndetermined, 'skip', cd_.nSkip, 'total', numel(cd_.tasks));
res.pipeline = struct('pass', pl.nPass, 'fail', pl.nFail, 'total', pl.nTasks, ...
    'skillMatchRate', pl.skillMatchRate, 'selfDisagreement', pl.selfDisagreement);
res.elapsedS = toc(t0);
res.matlabVersion = version;
res.timestamp = datestr(now, 31);

save(fullfile(outDir, 'phase4_all.mat'), 'res');
fid = fopen(fullfile(outDir, 'phase4_all.json'), 'w');
if fid >= 0, fwrite(fid, jsonencode(res), 'char'); fclose(fid); end

fprintf('\n==== %d/%d skill tests | %d/%d references | %d/%d cross-domain | %d/%d pipeline | %.1f s ====\n', ...
    nP, nT, ref.nPass, ref.nTotal, cd_.nPass, numel(cd_.tasks), pl.nPass, pl.nTasks, res.elapsedS);
end
