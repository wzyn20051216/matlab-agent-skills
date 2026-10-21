% Buck PI 控制器设计 v3：用 pidtune 默认目标 + 目标相位裕度
function buck_controller_design3()
close all;
Vin = 48; fsw = 50e3; R = 6; L = 150e-6; C = 220e-6;
A = [0, -1/L; 1/C, -1/(R*C)]; B = [Vin/L; 0];
Gvd = tf(ss(A, B, [0 1], 0));
f_res = 1/(2*pi*sqrt(L*C));
fprintf('谐振频率 f_res = %.1f Hz\n', f_res);

% pidtune 默认（自动选穿越频率，目标 PM=60°）
fprintf('\n=== pidtune 默认（PM=60°）===\n');
C1 = pidtune(Gvd, 'PI');
fprintf('Kp=%.6f Ki=%.6f\n', C1.Kp, C1.Ki);
L1 = C1*Gvd;
[Gm1,Pm1,~,Wcp1] = margin(L1);
fprintf('PM=%.2f°  fc=%.1f Hz  Gm=%.1f dB\n', Pm1, Wcp1/(2*pi), 20*log10(Gm1));

% 明确指定目标 PM 和穿越频率
fprintf('\n=== pidtune 目标 PM=60°，wc=300Hz ===\n');
opts = pidtuneOptions('PhaseMargin', 60);
C2 = pidtune(Gvd, 'PI', 2*pi*300, opts);
fprintf('Kp=%.6f Ki=%.6f\n', C2.Kp, C2.Ki);
L2 = C2*Gvd;
[Gm2,Pm2,~,Wcp2] = margin(L2);
fprintf('PM=%.2f°  fc=%.1f Hz  Gm=%.1f dB\n', Pm2, Wcp2/(2*pi), 20*log10(Gm2));

% 目标 PM=60°，wc=200Hz
fprintf('\n=== pidtune 目标 PM=60°，wc=200Hz ===\n');
C3 = pidtune(Gvd, 'PI', 2*pi*200, opts);
fprintf('Kp=%.6f Ki=%.6f\n', C3.Kp, C3.Ki);
L3 = C3*Gvd;
[Gm3,Pm3,~,Wcp3] = margin(L3);
fprintf('PM=%.2f°  fc=%.1f Hz  Gm=%.1f dB\n', Pm3, Wcp3/(2*pi), 20*log10(Gm3));

% 目标 PM=75°（更保守），wc=300Hz
fprintf('\n=== pidtune 目标 PM=75°，wc=300Hz ===\n');
opts75 = pidtuneOptions('PhaseMargin', 75);
C4 = pidtune(Gvd, 'PI', 2*pi*300, opts75);
fprintf('Kp=%.6f Ki=%.6f\n', C4.Kp, C4.Ki);
L4 = C4*Gvd;
[Gm4,Pm4,~,Wcp4] = margin(L4);
fprintf('PM=%.2f°  fc=%.1f Hz  Gm=%.1f dB\n', Pm4, Wcp4/(2*pi), 20*log10(Gm4));

% 选 PM 最高、最稳定的那组，做闭环验证
fprintf('\n=== 闭环阶跃响应对比 ===\n');
for k = 1:4
    Ck = eval(sprintf('C%d', k));
    Lk = eval(sprintf('L%d', k));
    Tcl = feedback(Lk, 1);
    info = stepinfo(Tcl);
    [Gm,Pm] = margin(Lk);
    fprintf('C%d: Kp=%.6f Ki=%.6f | PM=%.1f° | 超调=%.1f%% 调节时间=%.2f ms 稳态=%.4f\n', ...
        k, Ck.Kp, Ck.Ki, Pm, info.Overshoot, info.SettlingTime*1e3, dcgain(Tcl));
end
end
