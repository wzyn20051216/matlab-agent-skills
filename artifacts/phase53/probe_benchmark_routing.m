function probe_benchmark_routing()
repo = fileparts(fileparts(fileparts(mfilename('fullpath'))));
addpath(fullfile(repo, 'skills', 'matlab-orchestrator', 'scripts'));
F = jsondecode(fileread('E:\desktop\MATLAB-bench-holdout-phase53\tasks.json'));
T = F.tasks; if isstruct(T), T = num2cell(T(:)); end;
for k = 1:numel(T)
    r = mas_route(char(T{k}.prompt));
    fprintf('%-10s expected %-28s got %-28s %s\n', char(T{k}.id), ...
        char(T{k}.skill), r.primary, r.decision);
end
end
