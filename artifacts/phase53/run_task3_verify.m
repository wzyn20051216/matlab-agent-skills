%% Run the Phase 5.3 robotics contract suite plus the Phase 5.2 robotics suite.
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(here));
addpath(fullfile(repo, 'skills', 'matlab-robotics-autonomy', 'tests'));

out = {};
out{end+1} = '=== Phase 5.3 robotics contract ===';
txt = evalc('res = test_robotics_contract(true);');
out{end+1} = txt;
out{end+1} = sprintf('CONTRACT SUMMARY: %d / %d passed, suite pass = %d', ...
    res.nPass, res.nTotal, res.pass);
out{end+1} = '';
out{end+1} = '=== Phase 5.2 robotics regression ===';
txt = evalc('res2 = test_robotics(true);');
out{end+1} = txt;
out{end+1} = sprintf('REGRESSION SUMMARY: %d / %d passed, suite pass = %d', ...
    res2.nPass, res2.nTotal, res2.pass);
out{end+1} = sprintf('MATLAB %s', version);

all = strjoin(out, sprintf('\n'));
fprintf('%s\n', all);
logFile = fullfile(here, 'task3_contract.txt');
fid = fopen(logFile, 'w');
if fid >= 0, fwrite(fid, all, 'char'); fclose(fid); end
fprintf('\nlog written to %s (%d bytes)\n', logFile, numel(all));
