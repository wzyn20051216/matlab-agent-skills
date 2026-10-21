% Buck 闭环控制 Simulink 模型：PI + 占空比限幅 + 抗饱和 + 负载阶跃
function build_buck_closed_loop(outDir)
if nargin < 1 || isempty(outDir)
    outDir = fullfile(fileparts(mfilename('fullpath')), '..', '..', 'artifacts', 'validation', 'buck');
end
if ~exist(outDir, 'dir'); mkdir(outDir); end
close all;

% ==== 参数 ====
Vin = 48; fsw = 50e3; R = 6; L = 150e-6; C = 220e-6;
Vref = 12;
Kp = 0.0;   % 纯积分（物理最优，见设计分析）
Ki = 7.902901;
Dmax = 0.9; Dmin = 0.0;   % 占空比限幅

% 控制对象（平均状态空间）
A = [0, -1/L; 1/C, -1/(R*C)];
B = [Vin/L; 0];
C_out = [0 1];
D_out = 0;

mdl = 'buck_cl_loop';
if bdIsLoaded(mdl); close_system(mdl, 0); end
new_system(mdl);
open_system(mdl);

% 1. 参考电压
add_block('simulink/Sources/Constant', [mdl '/Vref'], 'Value', num2str(Vref));

% 2. 误差 = Vref - vC
add_block('simulink/Math Operations/Sum', [mdl '/Error'], 'Inputs', '+-');

% 3. PI 控制器（积分器 + 抗饱和 back-calculation）
% 结构：err -> [Ki*err + antiwindup] -> Integrator -> + Kp*err -> 占空比 -> 限幅
% 抗饱和：把 (u_sat - u_unsat)/Tt 加到积分器**输入**，阻止 windup
Tt = 0.001;   % 抗饱和时间常数
add_block('simulink/Continuous/Integrator', [mdl '/Integrator'], 'InitialCondition', '0');
add_block('simulink/Math Operations/Gain', [mdl '/Ki'], 'Gain', num2str(Ki));
add_block('simulink/Math Operations/Gain', [mdl '/Kp'], 'Gain', num2str(Kp));
add_block('simulink/Math Operations/Sum', [mdl '/PI_sum'], 'Inputs', '++');
add_block('simulink/Math Operations/Sum', [mdl '/Integrator_input'], 'Inputs', '++');

% 4. 占空比限幅
add_block('simulink/Discontinuities/Saturation', [mdl '/Duty_limit'], ...
    'LowerLimit', num2str(Dmin), 'UpperLimit', num2str(Dmax));

% 抗饱和反馈：u_sat - u_unsat
add_block('simulink/Math Operations/Sum', [mdl '/Sat_diff'], 'Inputs', '+-');
add_block('simulink/Math Operations/Gain', [mdl '/AntiGain'], 'Gain', num2str(1/Tt));

% 5. 控制对象（平均模型）
add_block('simulink/Continuous/State-Space', [mdl '/Plant'], ...
    'A', mat2str(A), 'B', mat2str(B), 'C', mat2str(C_out), 'D', mat2str(D_out), ...
    'X0', mat2str([0;0]));

% 7. 输出记录
add_block('simulink/Sinks/To Workspace', [mdl '/vC_sink'], 'VariableName', 'vC_cl', 'SaveFormat', 'Timeseries');
add_block('simulink/Sinks/To Workspace', [mdl '/duty_sink'], 'VariableName', 'duty_cl', 'SaveFormat', 'Timeseries');

% 连线
add_line(mdl, 'Vref/1', 'Error/1');
add_line(mdl, 'Plant/1', 'Error/2');   % vC 反馈

% PI 主路径：积分器输入 = Ki*err + antiwindup
add_line(mdl, 'Error/1', 'Ki/1');
add_line(mdl, 'Ki/1', 'Integrator_input/1');
add_line(mdl, 'AntiGain/1', 'Integrator_input/2');
add_line(mdl, 'Integrator_input/1', 'Integrator/1');
add_line(mdl, 'Integrator/1', 'PI_sum/1');
add_line(mdl, 'Error/1', 'Kp/1');
add_line(mdl, 'Kp/1', 'PI_sum/2');
add_line(mdl, 'PI_sum/1', 'Duty_limit/1');
add_line(mdl, 'Duty_limit/1', 'Plant/1');

% 抗饱和反馈：Sat_diff = 限幅输出(u_sat) - 限幅输入(u_unsat)
add_line(mdl, 'Duty_limit/1', 'Sat_diff/1');   % + u_sat
add_line(mdl, 'PI_sum/1', 'Sat_diff/2');       % - u_unsat
add_line(mdl, 'Sat_diff/1', 'AntiGain/1');

% 输出
add_line(mdl, 'Plant/1', 'vC_sink/1');
add_line(mdl, 'Duty_limit/1', 'duty_sink/1');

set_param(mdl, 'StopTime', '0.06', 'Solver', 'ode45', 'MaxStep', '1e-5');

save_system(mdl, fullfile(outDir, 'buck_cl_loop.slx'));

% ==== 仿真 ====
simout = sim(mdl);
vC = simout.vC_cl.Data;
duty = simout.duty_cl.Data;
t = simout.vC_cl.Time;

fprintf('=== 闭环仿真结果 ===\n');
fprintf('vC 稳态 = %.4f V（参考 12 V）\n', vC(end));
fprintf('稳态误差 = %.4f V\n', vC(end) - Vref);
fprintf('占空比稳态 = %.4f（理论 0.25）\n', duty(end));
fprintf('vC 超调峰值 = %.4f V\n', max(vC));

save(fullfile(outDir, 'buck_cl_loop_results.mat'), 't', 'vC', 'duty');

% 画图
fig = figure('Visible', 'off');
subplot(2,1,1);
plot(t*1e3, vC); hold on; yline(Vref, 'r--', 'Vref'); grid on;
xlabel('t (ms)'); ylabel('v_C (V)'); title('闭环输出电压（纯积分控制）');
subplot(2,1,2);
plot(t*1e3, duty); grid on; xlabel('t (ms)'); ylabel('占空比 d');
title('占空比');
saveas(fig, fullfile(outDir, 'buck_cl_loop_response.png'));
close(fig);

close_system(mdl, 0);
fprintf('模型已保存：%s\n', fullfile(outDir, 'buck_cl_loop.slx'));
end
