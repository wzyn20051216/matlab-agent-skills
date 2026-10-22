%% Task 6: re-run the per-domain licence probe and keep a dated copy.
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(here));
addpath(fullfile(repo, 'matlab', 'validation', 'phase53'));

txt = evalc('r = phase53_license_probe();');
fid = fopen(fullfile(here, 'evidence', 'task6_license_probe.json'), 'w');
if fid >= 0, fwrite(fid, jsonencode(r), 'char'); fclose(fid); end
fid = fopen(fullfile(here, 'evidence', 'task6_license.log'), 'w');
if fid >= 0, fwrite(fid, txt, 'char'); fclose(fid); end

fprintf('%s\n', txt);
fprintf('MATLAB %s | probe written to evidence/task6_license_probe.json\n', version);
