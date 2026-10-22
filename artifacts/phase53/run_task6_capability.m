%% Task 6: re-run the capability consistency test after the matrix update.
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(here));
addpath(fullfile(repo, 'skills', 'matlab-orchestrator', 'scripts'));
addpath(fullfile(repo, 'skills', 'matlab-orchestrator', 'tests'));

txt = evalc('r = test_capability(true);');
fid = fopen(fullfile(here, 'evidence', 'task6_capability.log'), 'w');
if fid >= 0, fwrite(fid, txt, 'char'); fclose(fid); end
fprintf('%s\n', txt);
fprintf('CAPABILITY SUMMARY: %d / %d passed\n', r.nPass, r.nTotal);
