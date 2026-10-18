% Buck 闭环 + 负载阶跃扰动测试 v2
% 正确物理模型：i_load = vC/R(t)，R 从 6Ω 阶跃到 3Ω
% 状态：diL/dt = -(1/L)vC + (Vin/L)d
%        dvC/dt = (1/C)iL - (1/C)*vC/R(t)
% 实现：State-Space 表示 [iL; vC] 的 A（不含 R 项）+ 外部 i_load = vC/R 反馈
function build_buck_load_step2(outDir)
if nargin < 1 || isempty(outDir)
    outDir = fullfile(fileparts(mfilename('fullpath')), '..', '..', 'artifacts', 'validation', 'buck');
end
if ~exist(outDir, 'dir'); mkdir(outDir); end
close all;

Vin = 48; fsw = 50e3; L = 150e-6; C = 220e-6; Vref = 12;
Kp = 0.0; Ki = 7.902901;
Dmax = 0.9; Dmin = 0.0; Tt = 0.001;

% 状态空间：x=[iL; vC]，输入=[d; i_load]
% diL/dt = -(1/L)vC + (Vin/L)d
% dvC/dt = (1/C)iL - (1/C)i_load
A = [0, -1/L; 1/C, 0];
B = [Vin/L, 0; 0, -1/C];
C_out = [0 1; 1 0];
D_out = [0 0; 0 0];

mdl = 'buck_load_step';
if bdIsLoaded(mdl); close_system(mdl, 0); end
new_system(mdl);
open_system(mdl);

add_block('simulink/Sources/Constant', [mdl '/Vref'], 'Value', num2str(Vref));
add_block('simulink/Math Operations/Sum', [mdl '/Error'], 'Inputs', '+-');

add_block('simulink/Continuous/Integrator', [mdl '/Integrator'], 'InitialCondition', '0');
add_block('simulink/Math Operations/Gain', [mdl '/Ki'], 'Gain', num2str(Ki));
add_block('simulink/Math Operations/Gain', [mdl '/Kp'], 'Gain', num2str(Kp));
add_block('simulink/Math Operations/Sum', [mdl '/PI_sum'], 'Inputs', '++');
add_block('simulink/Math Operations/Sum', [mdl '/Integrator_input'], 'Inputs', '++');
add_block('simulink/Discontinuities/Saturation', [mdl '/Duty_limit'], ...
    'LowerLimit', num2str(Dmin), 'UpperLimit', num2str(Dmax));
add_block('simulink/Math Operations/Sum', [mdl '/Sat_diff'], 'Inputs', '+-');
add_block('simulink/Math Operations/Gain', [mdl '/AntiGain'], 'Gain', num2str(1/Tt));

% 负载：电导 G(t) = 1/R(t)，从 1/6 阶跃到 1/3
% i_load = vC * G(t)
add_block('simulink/Sources/Step', [mdl '/Conductance'], 'Time', '0.03', 'Before', num2str(1/6), 'After', num2str(1/3));
add_block('simulink/Math Operations/Product', [mdl '/Load'], 'Inputs', '2');

add_block('simulink/Continuous/State-Space', [mdl '/Plant'], ...
    'A', mat2str(A), 'B', mat2str(B), 'C', mat2str(C_out), 'D', mat2str(D_out), ...
    'X0', mat2str([0;0]));

add_block('simulink/Sinks/To Workspace', [mdl '/vC_sink'], 'VariableName', 'vC_step', 'SaveFormat', 'Timeseries');
add_block('simulink/Sinks/To Workspace', [mdl '/iL_sink'], 'VariableName', 'iL_step', 'SaveFormat', 'Timeseries');
add_block('simulink/Sinks/To Workspace', [mdl '/duty_sink'], 'VariableName', 'duty_step', 'SaveFormat', 'Timeseries');
add_block('simulink/Signal Routing/Demux', [mdl '/Demux'], 'Outputs', '2');
add_block('simulink/Signal Routing/Mux', [mdl '/Mux'], 'Inputs', '2');

% 连线
add_line(mdl, 'Vref/1', 'Error/1');
add_line(mdl, 'Demux/1', 'Error/2');        % vC 反馈
add_line(mdl, 'Error/1', 'Ki/1');
add_line(mdl, 'Ki/1', 'Integrator_input/1');
add_line(mdl, 'AntiGain/1', 'Integrator_input/2');
add_line(mdl, 'Integrator_input/1', 'Integrator/1');
add_line(mdl, 'Integrator/1', 'PI_sum/1');
add_line(mdl, 'Error/1', 'Kp/1');
add_line(mdl, 'Kp/1', 'PI_sum/2');
add_line(mdl, 'PI_sum/1', 'Duty_limit/1');
add_line(mdl, 'Duty_limit/1', 'Mux/1');     % d
% 负载电流 i_load = vC * G(t)
add_line(mdl, 'Demux/1', 'Load/1');         % vC
add_line(mdl, 'Conductance/1', 'Load/2');   % G(t)
add_line(mdl, 'Load/1', 'Mux/2');           % i_load
add_line(mdl, 'Mux/1', 'Plant/1');
add_line(mdl, 'Duty_limit/1', 'Sat_diff/1');
add_line(mdl, 'PI_sum/1', 'Sat_diff/2');
add_line(mdl, 'Sat_diff/1', 'AntiGain/1');
add_line(mdl, 'Plant/1', 'Demux/1');
add_line(mdl, 'Demux/1', 'vC_sink/1');
add_line(mdl, 'Demux/2', 'iL_sink/1');
add_line(mdl, 'Duty_limit/1', 'duty_sink/1');

set_param(mdl, 'StopTime', '0.06', 'Solver', 'ode45', 'MaxStep', '1e-5');
save_system(mdl, fullfile(outDir, 'buck_load_step.slx'));

simout = sim(mdl);
vC = simout.vC_step.Data;
iL = simout.iL_step.Data;
duty = simout.duty_step.Data;
t = simout.vC_step.Time;

t_step = 0.03;
% 阶跃前稳态：取 20~29ms（已稳定段，避开启动瞬态）
preIdx = t > 0.02 & t < t_step - 0.001;
vC_pre = mean(vC(preIdx));
% 阶跃后跌落：取 30~31ms 内的最小值
dipWin = t >= t_step & t <= t_step + 0.001;
vC_dip = min(vC(dipWin));
% 阶跃后稳态：取 50~60ms
postEnd = mean(vC(t > 0.05));

fprintf('=== 负载阶跃响应（6Ω -> 3Ω @ 30ms）===\n');
fprintf('阶跃前稳态 vC = %.4f V（理论 12）\n', vC_pre);
fprintf('阶跃后稳态 vC = %.4f V（理论 12）\n', postEnd);
fprintf('电压跌落 = %.4f V（%.2f%%）\n', vC_dip - Vref, (vC_dip - Vref)/Vref*100);

band = 0.01 * Vref;
recIdx = find(t > t_step & abs(vC - Vref) <= band, 1, 'first');
if ~isempty(recIdx)
    fprintf('恢复时间（±1%% 带）= %.4f ms\n', (t(recIdx) - t_step)*1e3);
end
fprintf('阶跃前 iL = %.4f A（理论 2）\n', mean(iL(preIdx)));
fprintf('阶跃后 iL = %.4f A（理论 4）\n', mean(iL(t > 0.05)));

save(fullfile(outDir, 'buck_load_step_results.mat'), 't', 'vC', 'iL', 'duty');

fig = figure('Visible', 'off');
subplot(3,1,1);
plot(t*1e3, vC); hold on; yline(Vref, 'r--'); grid on; xline(30, 'k--');
xlabel('t (ms)'); ylabel('v_C (V)'); title('负载阶跃 6Ω→3Ω：输出电压');
subplot(3,1,2);
plot(t*1e3, iL); grid on; xline(30, 'k--'); xlabel('t (ms)'); ylabel('i_L (A)'); title('电感电流');
subplot(3,1,3);
plot(t*1e3, duty); grid on; xline(30, 'k--'); xlabel('t (ms)'); ylabel('d'); title('占空比');
saveas(fig, fullfile(outDir, 'buck_load_step_response.png'));
close(fig);

close_system(mdl, 0);
fprintf('模型已保存：%s\n', fullfile(outDir, 'buck_load_step.slx'));
end
