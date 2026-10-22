repo = 'E:\desktop\MATLAB';
addpath(fullfile(repo, 'benchmark'));
root = 'E:\desktop\MATLAB-bench-agent-phase54';
out = fullfile(root, 'out');
if ~exist(out, 'dir'), mkdir(out); end

T = jsondecode(fileread('E:\desktop\MATLAB-bench-holdout-phase53\tasks.json'));
if isstruct(T.tasks), T.tasks = num2cell(T.tasks(:)); end
ids = {'H-SIG-N', 'H-DATA-N', 'H-ROB-N'};
for k = 1:3
    task = [];
    for j = 1:numel(T.tasks)
        if strcmp(char(T.tasks{j}.id), ids{k}), task = T.tasks{j}; break; end
    end
    [~, spec, inputs] = benchmark_fixtures(char(task.fixture), 53);
    save(fullfile(root, sprintf('task%d', k), 'input.mat'), '-struct', 'inputs', '-v7');
    fid = fopen(fullfile(root, sprintf('task%d', k), 'spec.json'), 'w');
    fwrite(fid, jsonencode(spec), 'char');
    fclose(fid);
    fprintf('task%d <- %s fixture %s\n', k, ids{k}, char(task.fixture));
end
