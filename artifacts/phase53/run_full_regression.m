function run_full_regression()
%RUN_FULL_REGRESSION  Phase 5.3 full regression (Phase 5.2 suites + new contracts).
%
% Runs matlab/validation/phase4/run_all.m, which includes every Phase 5.2 suite,
% the three Phase 5.3 contract suites, and the benchmark harness. Writes the
% console output and a structured summary under artifacts/phase53.

repo = 'E:/desktop/MATLAB';
outDir = fullfile(repo, 'artifacts', 'validation', 'phase53');
ev = fullfile(repo, 'artifacts', 'phase53', 'evidence');
if ~isfolder(ev), mkdir(ev); end
if ~isfolder(outDir), mkdir(outDir); end
cd(fullfile(repo, 'matlab', 'validation', 'phase4'));
clear functions;
txt = evalc('res = run_all(outDir);');

fid = fopen(fullfile(ev, 'full_suite_after.log'), 'w');
if fid >= 0, fwrite(fid, txt, 'char'); fclose(fid); end

fid = fopen(fullfile(ev, 'full_suite_after_summary.json'), 'w');
if fid >= 0, fwrite(fid, jsonencode(res), 'char'); fclose(fid); end

fprintf('FULL %d/%d suite tests | refs %d/%d | cross %d/%d | pipeline %d/%d | errored=%d | %.1f s\n', ...
    res.skillPass, res.skillTotal, res.references.pass, res.references.total, ...
    res.crossdomain.pass, res.crossdomain.total, res.pipeline.pass, ...
    res.pipeline.total, res.suitesErrored, res.elapsedS);
end
