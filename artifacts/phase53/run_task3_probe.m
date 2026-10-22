%% Capture the grounded probe output for the Phase 5.3 robotics tools.
here = fileparts(mfilename('fullpath'));
addpath(fullfile(fileparts(fileparts(here)), 'skills', 'matlab-robotics-autonomy', 'scripts'));
txt = evalc("run(fullfile(here,'probe_task3.m'))");
fprintf('%s\n', txt);
logFile = fullfile(here, 'task3_probe.txt');
fid = fopen(logFile, 'w');
if fid >= 0, fwrite(fid, txt, 'char'); fclose(fid); end
fprintf('probe log written to %s (%d bytes)\n', logFile, numel(txt));
