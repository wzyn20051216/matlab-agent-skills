%% Re-run the frozen holdout after moving results to the evaluation side.
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(here));
addpath(fullfile(repo, 'benchmark'));

out = {};
out{end+1} = '=== Phase 5.3 holdout re-run (external output default) ===';
txt = evalc('run_holdout;');
out{end+1} = txt;
out{end+1} = sprintf('MAS_BENCH_HOLDOUT_ROOT=%s', getenv('MAS_BENCH_HOLDOUT_ROOT'));
out{end+1} = sprintf('MAS_BENCH_OUT=%s', getenv('MAS_BENCH_OUT'));
out{end+1} = sprintf('MATLAB %s', version);

all = strjoin(out, sprintf('\n'));
fprintf('%s\n', all);
% The console names per-task expected verdicts; keep it on the evaluation side.
root = getenv('MAS_BENCH_HOLDOUT_ROOT');
if isempty(root), root = 'E:\desktop\MATLAB-bench-holdout-phase53'; end
outRoot = getenv('MAS_BENCH_OUT');
if isempty(outRoot), outRoot = fullfile(root, 'runs', 'latest'); end
if ~isfolder(outRoot), mkdir(outRoot); end
logFile = fullfile(outRoot, 'rerun_console.txt');
fid = fopen(logFile, 'w');
if fid >= 0, fwrite(fid, all, 'char'); fclose(fid); end
fprintf('\nlog written to %s (%d bytes)\n', logFile, numel(all));
