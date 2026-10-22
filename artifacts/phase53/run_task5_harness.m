%% Run the isolated-benchmark harness tests (Task 5 evidence).
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(here));
addpath(fullfile(repo, 'benchmark'));
addpath(fullfile(repo, 'benchmark', 'tests'));

out = {};
out{end+1} = '=== Phase 5.3 isolated benchmark harness ===';
txt = evalc('res = test_benchmark_harness(true);');
out{end+1} = txt;
out{end+1} = sprintf('HARNESS SUMMARY: %d / %d passed, suite pass = %d', ...
    res.nPass, res.nTotal, res.pass);
out{end+1} = sprintf('MATLAB %s', version);

all = strjoin(out, sprintf('\n'));
fprintf('%s\n', all);
logFile = fullfile(here, 'task5_harness.txt');
fid = fopen(logFile, 'w');
if fid >= 0, fwrite(fid, all, 'char'); fclose(fid); end
fprintf('\nlog written to %s (%d bytes)\n', logFile, numel(all));
