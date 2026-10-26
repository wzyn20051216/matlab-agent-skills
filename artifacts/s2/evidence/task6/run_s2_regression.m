scriptPath = mfilename('fullpath');
repoRoot = fileparts(fileparts(fileparts(fileparts(fileparts(scriptPath)))));
cd(repoRoot);
outDir = fullfile(repoRoot, 'artifacts', 's2', 'evidence', 'task6', 'matlab-regression');
addpath(fullfile(repoRoot, 'matlab', 'validation', 'phase4'));
res = run_all(outDir);
fprintf('S2_REGRESSION skill=%d/%d errored=%d suitesRun=%d allOk=%d\n', ...
    res.skillPass, res.skillTotal, res.suitesErrored, res.suitesRun, res.allSuitesOk);
if res.suitesErrored ~= 0 || ~res.allSuitesOk
    error('S2_REGRESSION_NOT_GREEN');
end
