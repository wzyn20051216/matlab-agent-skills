%% Task 6: regenerate the isolation audit with the directory blind spot removed.
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(here));
root = 'E:\desktop\MATLAB-bench-holdout-phase53';
addpath(fullfile(repo, 'benchmark'));

A = benchmark_audit(repo, root, fullfile(root, 'manifest.json'));
fid = fopen(fullfile(here, 'benchmark', 'isolation_audit.json'), 'w');
if fid >= 0, fwrite(fid, jsonencode(A), 'char'); fclose(fid); end
for k = 1:numel(A.checks)
    if A.checks(k).pass, tag = 'PASS'; else, tag = 'FAIL'; end
    fprintf('%-24s %s  %s\n', A.checks(k).id, tag, A.checks(k).detail);
end
fprintf('AUDIT %d/%d, ok=%d\n', nnz([A.checks.pass]), numel(A.checks), A.ok);
