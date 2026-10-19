function res = run_all(outDir)
%RUN_ALL  Phase 4: run every skill test suite and the cross-domain suite, once.
%
%   res = run_all()
%
% Reproducible entry point. It does not grade anything itself; it collects the
% verdicts of the four skill suites plus the eight cross-domain tasks so a
% reviewer can re-run one command and compare.

if nargin < 1 || isempty(outDir), outDir = getenv('MAS_OUT'); end
if isempty(outDir), outDir = fullfile(pwd,'artifacts','validation','phase4'); end
outDir = strrep(outDir,'/',filesep);
% mfilename -> matlab/validation/phase4/run_all; four levels up is the repo root
repo = fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
addpath(fullfile(repo,'skills','matlab-orchestrator','scripts'));
addpath(fullfile(repo,'skills','matlab-orchestrator','tests'));
addpath(fullfile(repo,'skills','matlab-runner','scripts'));
addpath(fullfile(repo,'skills','matlab-runner','tests'));
addpath(fullfile(repo,'skills','matlab-testing-ci','scripts'));
addpath(fullfile(repo,'skills','matlab-testing-ci','tests'));
addpath(fullfile(repo,'skills','matlab-simulink-modeling','scripts'));
addpath(fullfile(repo,'skills','matlab-simulink-modeling','tests'));
addpath(fullfile(repo,'matlab','validation','crossdomain'));
if ~exist(outDir,'dir'), mkdir(outDir); end

fprintf('########## Phase 4 verification ##########\n\n');
t0 = tic;

a = test_routing(false);        fprintf('routing      %d/%d\n', a.nPass, a.nTotal);
b = test_precheck(false);       fprintf('precheck     %d/%d\n', b.nPass, b.nTotal);
c = test_grade(false);          fprintf('grading      %d/%d\n', c.nPass, c.nTotal);
d = test_model_check(false);    fprintf('model check  %d/%d\n', d.nPass, d.nTotal);
e = run_crossdomain(outDir);    fprintf('cross-domain %d pass / %d fail / %d skip\n', ...
    e.nPass, e.nFail, e.nSkip);

tot = a.nTotal + b.nTotal + c.nTotal + d.nTotal;
pas = a.nPass + b.nPass + c.nPass + d.nPass;
res = struct('level','Phase4','skillTests',struct( ...
        'routing',struct('pass',a.nPass,'total',a.nTotal), ...
        'precheck',struct('pass',b.nPass,'total',b.nTotal), ...
        'grading',struct('pass',c.nPass,'total',c.nTotal), ...
        'modelCheck',struct('pass',d.nPass,'total',d.nTotal)), ...
    'skillPass',pas,'skillTotal',tot, ...
    'crossdomain',struct('pass',e.nPass,'fail',e.nFail,'skip',e.nSkip), ...
    'elapsedS',toc(t0),'matlabVersion',version);
save(fullfile(outDir,'phase4_all.mat'),'res');
fid = fopen(fullfile(outDir,'phase4_all.json'),'w');
if fid >= 0, fwrite(fid, jsonencode(res),'char'); fclose(fid); end
fprintf('\nSKILL TESTS %d/%d ; CROSS-DOMAIN %d pass / %d fail / %d skip ; %.1f s\n', ...
    pas, tot, e.nPass, e.nFail, e.nSkip, res.elapsedS);
end
