% Buck 闭环 PI 控制器设计 v2：正确处理相位余量
% 关键：LC 谐振频率 ~876 Hz，穿越频率必须远低于它才有相位余量
%
% ---------------------------------------------------------------------------
% 【历史警示——本脚本保留作过程证据，结论以 verify/ 下任务二/三为准】
% 本脚本是 margin() 误读问题的"活教材"：pidtune 针对 fc=400Hz 给出的
% Ki=41.576（纯积分）在 400Hz 处相位良好，margin() 于是报出
% "PM=60.77 deg, GM=Inf"——但 Ki=41.576 > Ki_crit=1/(R*Vin*C)=15.78，
% 该回路在 f_n 处 |L|=Ki*R*Vin*C=2.63（相位恰 -180 deg），实际 GM=-8.4dB、
% 闭环有 RHP 极点，是真不稳。margin() 在这里同时犯了两个错：
%   (1) 只返回一个 0dB 交越点（该回路有 400Hz 与 1039.5Hz 两个交越）；
%   (2) 其自适应网格漏掉了 f_n 处的 -180 deg 穿越（于是 Gm=Inf）。
% 这正是后来编写 local_margins.m（稠密网格 + 全交越 + 最坏值口径）的原因，
% 见 verify/buck_task2c_negative_pm_regime.m 与报告 docs/PHASE3A_BUCK_STABILITY_ZH.md。
% 另外本脚本"解析法"给出的 Ki=-37.5（负积分）是退化解，勿用。
% ---------------------------------------------------------------------------
function buck_controller_design2()
close all;

Vin = 48; fsw = 50e3; R = 6; L = 150e-6; C = 220e-6;
Vref = 12;

% 控制对象
A = [0, -1/L; 1/C, -1/(R*C)];
B = [Vin/L; 0];
sys = ss(A, B, [0 1], 0);
Gvd = tf(sys);

f_res = 1/(2*pi*sqrt(L*C));
fprintf('=== 控制对象 ===\n');
fprintf('谐振频率 f_res = %.1f Hz\n', f_res);
fprintf('直流增益 = %.1f (= Vin)\n', dcgain(Gvd));

% 在不同穿越频率处看 Gvd 的相位，选择合适 fc
fprintf('\n=== 扫描候选穿越频率 ===\n');
for fc_test = [200, 300, 400, 500, 876, 1500, 2500]
    wc = 2*pi*fc_test;
    [m, p] = bode(Gvd, wc);
    fprintf('fc=%-5d Hz  |Gvd|=%.4f  phase=%.2f°\n', fc_test, m(1), p(1));
end

% 选 fc = 400 Hz（远低于 876 Hz 谐振，相位约 -95°，有 ~85° 余量可分配）
fc = 400;
wc = 2*pi*fc;
[mag_wc, phase_wc] = bode(Gvd, wc);
mag_wc = mag_wc(1); phase_wc = phase_wc(1);
fprintf('\n选定 fc = %d Hz，Gvd 相位 = %.2f°\n', fc, phase_wc);

% ==== 方法1：pidtune（目标 wc）====
C_pid = pidtune(Gvd, 'PI', wc);
Kp_pid = C_pid.Kp; Ki_pid = C_pid.Ki;
fprintf('\n=== pidtune ===\n');
fprintf('Kp = %.6f, Ki = %.6f\n', Kp_pid, Ki_pid);
L_pid = C_pid * Gvd;
[Gm1, Pm1, ~, Wcp1] = margin(L_pid);
fprintf('相位裕度 PM = %.2f°，穿越频率 = %.1f Hz，增益裕度 = %.1f dB\n', Pm1, Wcp1/(2*pi), 20*log10(Gm1));

% ==== 方法2：解析法（目标 PM = 60°）====
% PI: C(s) = Kp + Ki/s = Kp*(s + Ki/Kp)/s
% 在 wc 处，C 的相位 = atan(wc*Kp/Ki) - 90°
% Gvd 相位 phase_wc，总相位 = phase_wc + phase_C = -180 + PM
% => phase_C = -180 + PM - phase_wc
PM_target = 60;
phase_C_needed = -180 + PM_target - phase_wc;
% atan(wc*Kp/Ki) - 90 = phase_C_needed
% => atan(wc*Kp/Ki) = phase_C_needed + 90
ratio = tan(deg2rad(phase_C_needed + 90));  % = wc*Kp/Ki
% |C(jwc)| = Kp * sqrt(1 + ratio^2)/ratio ... 实际 |Kp + Ki/(jw)| = sqrt(Kp^2 + (Ki/wc)^2)
% 设 Ki/wc = Kp/ratio => |C| = Kp * sqrt(1 + 1/ratio^2)
% 要求 |C|*|Gvd| = 1 => Kp = 1/(mag_wc * sqrt(1 + 1/ratio^2))
Kp_analytic = 1 / (mag_wc * sqrt(1 + 1/ratio^2));
Ki_analytic = Kp_analytic * wc / ratio;

fprintf('\n=== 解析法（PM=60°）===\n');
fprintf('Kp = %.6f, Ki = %.6f\n', Kp_analytic, Ki_analytic);
C_analytic = pid(Kp_analytic, Ki_analytic, 0, 0);
L_analytic = C_analytic * Gvd;
[Gm2, Pm2, ~, Wcp2] = margin(L_analytic);
fprintf('相位裕度 PM = %.2f°，穿越频率 = %.1f Hz，增益裕度 = %.1f dB\n', Pm2, Wcp2/(2*pi), 20*log10(Gm2));

% ==== 闭环阶跃响应（用 pidtune 结果）====
T_cl = feedback(L_pid, 1);
info = stepinfo(T_cl);
fprintf('\n=== 闭环阶跃响应（pidtune 控制器）===\n');
fprintf('稳态 = %.4f\n', dcgain(T_cl));
fprintf('超调 = %.2f%%\n', info.Overshoot);
fprintf('峰值时间 = %.3f ms\n', info.PeakTime*1e3);
fprintf('调节时间 = %.3f ms\n', info.SettlingTime*1e3);

% 用解析法结果再算闭环
T_cl2 = feedback(L_analytic, 1);
info2 = stepinfo(T_cl2);
fprintf('\n=== 闭环阶跃响应（解析法控制器）===\n');
fprintf('稳态 = %.4f\n', dcgain(T_cl2));
fprintf('超调 = %.2f%%\n', info2.Overshoot);
fprintf('调节时间 = %.3f ms\n', info2.SettlingTime*1e3);

% 保存（统一用 pidtune 结果作为最终 PI 参数，两者应接近）
Kp = Kp_pid; Ki = Ki_pid;
save(fullfile(fileparts(mfilename('fullpath')), '..', '..', 'artifacts', 'validation', 'buck', 'controller_design.mat'), ...
    'Kp', 'Ki', 'fc', 'Gvd', 'C_analytic', 'L_analytic', 'T_cl', 'Kp_analytic', 'Ki_analytic', 'C_pid', 'L_pid');

fprintf('\n=== 设计结论 ===\n');
fprintf('最终 PI：Kp=%.6f, Ki=%.6f（pidtune）\n', Kp_pid, Ki_pid);
fprintf('解析法：Kp=%.6f, Ki=%.6f\n', Kp_analytic, Ki_analytic);
fprintf('穿越频率 fc=%d Hz，相位裕度约 %.0f°\n', fc, Pm1);
end
