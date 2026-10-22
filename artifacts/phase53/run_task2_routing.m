% Routing probe for the Task 2 vocabulary, plus the 15-task pipeline match.
clear functions; rehash;
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(here));
addpath(fullfile(repo, 'skills', 'matlab-orchestrator', 'scripts'));
P = { '对实验数据做误差传播分析', '假设检验和置信区间怎么算', '数值微分与条件数分析', ...
      '迭代收敛阶怎么测', '用 fsolve 解方程', 'fitlm 回归拟合' };
L = {};
for k = 1:numel(P)
    d = mas_route(P{k});
    L{end+1} = sprintf('%-22s -> %-24s %s', P{k}, d.primary, d.decision); %#ok<SAGROW>
end
C = { '用 fmincon 求带约束的最优控制', 'PID 调参和相位裕度' };
for k = 1:numel(C)
    d = mas_route(C{k});
    L{end+1} = sprintf('%-22s -> %-24s %s', C{k}, d.primary, d.decision); %#ok<SAGROW>
end
txt = strjoin(L, sprintf('\n'));
fprintf('%s\n', txt);
txt = [txt sprintf('\n')];
fid = fopen(fullfile(here, 'task2_routing.txt'), 'w');
if fid >= 0, fwrite(fid, txt, 'char'); fclose(fid); end
