% Buck 平均模型 vs 开关级模型对比
function buck_model_compare()
close all;

Vin = 48; Vout = 12; fsw = 50e3; L = 150e-6; C = 220e-6; D = 0.25;

% 载入两个模型的仿真结果
avgDir = fullfile(fileparts(mfilename('fullpath')), '..', '..', 'artifacts', 'validation', 'buck');
load(fullfile(avgDir, 'buck_avg_results.mat'));     % t, vC(平均), iL(平均)
t_avg = t; vC_avg = vC; iL_avg = iL;

load(fullfile(avgDir, 'buck_switching_results.mat')); % t, vC(开关), vsw
t_sw = t; vC_sw = vC; vsw_sw = vsw;

% 稳态对比（取各自末段）
n_avg = numel(t_avg);
n_sw = numel(t_sw);
avg_ss = vC_avg(floor(n_avg*0.7):end);
% 开关级纹波只在最后 10 个开关周期内取（避开过渡过程）
lastT = t_sw(end);
sw_last = t_sw > (lastT - 10/fsw);
sw_ss = vC_sw(sw_last);

fprintf('=== 平均模型 vs 开关级模型对比 ===\n');
fprintf('%-20s %-12s %-12s\n', '指标', '平均模型', '开关级模型');
fprintf('%-20s %-12.4f %-12.4f\n', '稳态均值 vC (V)', mean(avg_ss), mean(sw_ss));
fprintf('%-20s %-12.4f %-12.4f\n', '稳态误差 (V)', mean(avg_ss)-12, mean(sw_ss)-12);

% 纹波：平均模型理论上无纹波（状态平均），开关模型有纹波
sw_ripple = max(sw_ss) - min(sw_ss);
fprintf('%-20s %-12s %-12.4f\n', '输出电压纹波 (mV)', 'N/A(平均)', sw_ripple*1e3);

% 理论纹波
theory_ripple = (Vin-Vout)*Vout/(8*L*C*fsw^2*Vin);
fprintf('%-20s %-12s %-12.4f\n', '理论纹波 (mV)', '', theory_ripple*1e3);

% 动态响应（启动超调、调节时间）
avg_peak = max(vC_avg);
sw_peak = max(vC_sw);
fprintf('%-20s %-12.4f %-12.4f\n', '启动峰值 (V)', avg_peak, sw_peak);

% 执行时间（从结果无法直接得，用数据点数近似）
fprintf('%-20s %-12d %-12d\n', '采样点数', n_avg, n_sw);

% 模型适用性说明
fprintf('\n=== 模型适用性 ===\n');
fprintf('平均模型：无开关纹波，适合控制器设计/稳定性分析/快速仿真\n');
fprintf('开关级模型：含 PWM 纹波，适合纹波分析/EMI 评估/更真实波形\n');
fprintf('差异来源：平均模型用状态平均消除开关动作，开关模型保留 PWM 方波\n');

% 画对比图
fig = figure('Visible', 'off');
subplot(2,1,1);
plot(t_avg*1e3, vC_avg, 'b-', 'LineWidth', 1.5); hold on;
plot(t_sw*1e3, vC_sw, 'r-'); grid on;
xlabel('t (ms)'); ylabel('v_C (V)'); legend('平均模型', '开关级模型');
title('两种模型输出电压对比');
subplot(2,1,2);
plot(t_sw*1e3, vsw_sw, 'r-'); grid on;
xlabel('t (ms)'); ylabel('v_{sw} (V)'); title('开关级模型斩波电压（PWM 方波）');
saveas(fig, fullfile(avgDir, 'buck_model_compare.png'));
close(fig);

% 保存对比数据
save(fullfile(avgDir, 'buck_model_compare.mat'), 't_avg', 'vC_avg', 't_sw', 'vC_sw', 'sw_ripple', 'theory_ripple');
fprintf('对比图已保存：buck_model_compare.png\n');
end
