%% 诊断：陷波器方案为什么 PM 仍不够？深度/宽度是否合理？
clear; clc;
addpath(fullfile(fileparts(fileparts(mfilename('fullpath')))));  % local_margins
Vin=48; L=150e-6; C=220e-6; R=6; Ts=1/50e3;
A=[0,-1/L; 1/C,-1/(R*C)]; B=[Vin/L;0]; Co=[0,1]; Do=0;
Gvd = minreal(tf(ss(A,B,Co,Do)));
fn = 1/sqrt(L*C);
s = tf('s');
fprintf('f_n = %.2f Hz\n\n', fn/(2*pi));

fprintf('=== 不加陷波器时 Gvd 在 f_n 的增益 ===\n');
fprintf('  |Gvd(f_n)| = %.2f\n', abs(squeeze(freqresp(Gvd,fn))));
fprintf('  phase = %.2f deg\n\n', rad2deg(angle(squeeze(freqresp(Gvd,fn)))));

fprintf('=== 陷波器参数扫描（Kp=0.02, Ki=40）===\n');
fprintf('%8s %8s %10s %10s %10s %10s\n','zeta_n','zeta_d','notch(f_n)','PM','GM_dB','maxRe');
for zn_n = [0.01 0.02 0.05 0.10]
  for zd_n = [0.20 0.30 0.50 0.80 1.20]
    notch = (s^2 + 2*zn_n*fn*s + fn^2)/(s^2 + 2*zd_n*fn*s + fn^2);
    nf = abs(squeeze(freqresp(notch,fn)));
    C = pid(0.02,40,0,0)*notch;
    Ls = C*Gvd;
    % GM 用 local_margins（正确口径：-|L|_dB(相位穿越处)）。
    % 旧版误把 Wcg（相位穿越频率）当幅值，GM 恒为 -70 dB 量级。
    [Gm_dB, Pm, Wcg, Wcp] = local_margins(Ls);
    clp = pole(feedback(Ls,1));
    fprintf('%8.3f %8.3f %10.4f %10.2f %10.2f %10.2f\n', zn_n, zd_n, nf, Pm, Gm_dB, max(real(clp)));
  end
end

fprintf('\n=== 陷波器中心频率扫描（zn=0.02, zd=0.8, Kp=0.02, Ki=40）===\n');
fprintf('%12s %10s %10s %10s\n','wn(Hz)','notch(f_n)','PM','maxRe');
for scale = [0.7 0.85 1.0 1.15 1.3]
    wn = fn*scale;
    notch = (s^2 + 2*0.02*wn*s + wn^2)/(s^2 + 2*0.8*wn*s + wn^2);
    nf = abs(squeeze(freqresp(notch,fn)));
    C = pid(0.02,40,0,0)*notch; Ls=C*Gvd;
    [~,Pm]=margin(Ls); clp=pole(feedback(Ls,1));
    fprintf('%12.2f %10.4f %10.2f %10.2f\n', wn/(2*pi), nf, Pm, max(real(clp)));
end

fprintf('\n=== 关键洞察：PI 的零点位置 ===\n');
fprintf('PI 的零点 s=-Ki/Kp = -%.1f rad/s (%.1f Hz)\n', 40/0.02, 40/0.02/(2*pi));
fprintf('加 Kp=0.02 后 PI 在 f_n 处的相位贡献: %.2f deg\n', ...
    rad2deg(angle(squeeze(freqresp(pid(0.02,40,0,0), fn)))));
fprintf('Gvd 在 f_n 相位: %.2f deg\n', rad2deg(angle(squeeze(freqresp(Gvd,fn)))));
fprintf('积分器贡献 -90 deg => 扣掉积分器后的相位 %.2f deg\n', ...
    rad2deg(angle(squeeze(freqresp(pid(0.02,40,0,0)*Gvd,fn)))) - 90);
fprintf('\n=> 结论：交叉频率被推到 f_n 之上后，Gvd 相位已接近 -90deg，\n');
fprintf('   即使有 PI 的 +phase 也难补回 50deg 裕度，除非陷波器深度极大。\n');

fprintf('\n=== 换思路：把交越频率压回 f_n 以下但提高 Ki ====\n');
fprintf('%10s %10s %10s %10s %10s\n','Kp','Ki','PM','fc(Hz)','maxRe');
for Kp=[0 0.002 0.005 0.008 0.012]
  for Ki=[7.9 15 30 60 100 150]
    C=pid(Kp,Ki,0,0); Ls=C*Gvd;
    [Gm,Pm,Wcg,Wcp]=margin(Ls);
    if isnan(Wcp), continue; end
    clp=pole(feedback(Ls,1));
    if Pm>=40
        fprintf('%10.3f %10.1f %10.2f %10.2f %10.2f\n', Kp,Ki,Pm,Wcp/(2*pi),max(real(clp)));
    end
  end
end