% Buck 平均状态空间模型：Simulink 构建 + 仿真验证
% 平均模型：dx/dt = A x + B d（d 为占空比），输出 vC 与 iL
% 输出目录由 outDir 参数指定，产物不落源码目录。
function build_buck_avg_model(outDir)
if nargin < 1 || isempty(outDir)
    outDir = fullfile(fileparts(mfilename('fullpath')), '..', '..', 'artifacts', 'validation', 'buck');
end
if ~exist(outDir, 'dir'); mkdir(outDir); end
close all;

% ==== 参数 ====
Vin = 48;
fsw = 50e3;
R = 6;
L = 150e-6;
C = 220e-6;
D = 0.25;   % 初始占空比

% ==== 平均状态空间（控制输入为占空比 d）====
% A 含负载项，B 是 d 的系数
A = [0, -1/L; 1/C, -1/(R*C)];
B = [Vin/L; 0];   % dx/dt = A x + B * d
C_out = [0, 1; 1, 0];  % 输出 [vC; iL]
D_out = [0; 0];

mdl = 'buck_avg_plant';
if bdIsLoaded(mdl); close_system(mdl, 0); end
new_system(mdl);
open_system(mdl);

% 状态空间块（平均模型核心）
add_block('simulink/Continuous/State-Space', [mdl '/Plant'], ...
    'A', mat2str(A), 'B', mat2str(B), 'C', mat2str(C_out), 'D', mat2str(D_out), ...
    'X0', mat2str([0;0]));

% 占空比输入（阶跃到 0.25）
add_block('simulink/Sources/Step', [mdl '/Duty'], 'Time', '0', 'Before', '0', 'After', num2str(D));

% 输出分接
add_block('simulink/Sinks/To Workspace', [mdl '/vC_sink'], 'VariableName', 'vC_avg', 'SaveFormat', 'Timeseries');
add_block('simulink/Sinks/To Workspace', [mdl '/iL_sink'], 'VariableName', 'iL_avg', 'SaveFormat', 'Timeseries');

% Demux 分离 [vC; iL]
add_block('simulink/Signal Routing/Demux', [mdl '/Demux'], 'Outputs', '2');

add_line(mdl, 'Duty/1', 'Plant/1');
add_line(mdl, 'Plant/1', 'Demux/1');
add_line(mdl, 'Demux/1', 'vC_sink/1');
add_line(mdl, 'Demux/2', 'iL_sink/1');

set_param(mdl, 'StopTime', '0.02', 'Solver', 'ode45', 'MaxStep', '1e-5');

save_system(mdl, fullfile(outDir, 'buck_avg_plant.slx'));

% ==== 仿真 ====
simout = sim(mdl);
vC = simout.vC_avg.Data;
iL = simout.iL_avg.Data;
t = simout.vC_avg.Time;

fprintf('=== 平均模型仿真结果 ===\n');
fprintf('vC 终值 = %.4f V（理论 12 V）\n', vC(end));
fprintf('iL 终值 = %.4f A（理论 2 A）\n', iL(end));
fprintf('vC 超调峰值 = %.4f V\n', max(vC));
fprintf('vC 稳态误差 = %.4f V\n', vC(end) - 12);

% 保存仿真数据
save(fullfile(outDir, 'buck_avg_results.mat'), 't', 'vC', 'iL');

% 画图
fig = figure('Visible', 'off');
subplot(2,1,1);
plot(t*1e3, vC); grid on; xlabel('t (ms)'); ylabel('v_C (V)');
title('Buck 平均模型：输出电压');
subplot(2,1,2);
plot(t*1e3, iL); grid on; xlabel('t (ms)'); ylabel('i_L (A)');
title('Buck 平均模型：电感电流');
saveas(fig, fullfile(outDir, 'buck_avg_response.png'));
close(fig);

close_system(mdl, 0);
fprintf('模型已保存：%s\n', fullfile(outDir, 'buck_avg_plant.slx'));
end
