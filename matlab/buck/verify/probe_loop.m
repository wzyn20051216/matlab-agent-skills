%% 最小诊断：直接打印环路幅相，验证交越频率与裕度
clear; clc;
Vin=48; L=150e-6; C=220e-6; R=6; Ts=1/50e3;
A=[0,-1/L; 1/C,-1/(R*C)]; B=[Vin/L;0]; Co=[0,1]; Do=0;
Gvd = minreal(tf(ss(A,B,Co,Do)));

fprintf('=== Gvd 幅相（关键频点）===\n');
w = [0.01 0.1 1 10 60.7*2*pi 100 300 757 876 1000 3000 5000 5505 10000 100000];
for k=1:numel(w)
    g = squeeze(freqresp(Gvd, w(k)));
    fprintf('  w=%10.3f rad/s (%8.2f Hz): |G|=%.5e  phase=%+8.3f deg\n', ...
        w(k), w(k)/(2*pi), abs(g), rad2deg(angle(g)));
end

Ki = 7.902901;
for Kp = [0, 0.005, 0.01, 0.02]
    Cc = pid(Kp, Ki, 0, 0);
    Ls = Cc * Gvd;
    fprintf('\n=== Kp=%.3f, Ki=%.3f 环路 L(s)=C(s)*Gvd(s) ===\n', Kp, Ki);
    fprintf('  L(s) 分子=%s\n', mat2str(Ls.num{1},6));
    fprintf('  L(s) 分母=%s\n', mat2str(Ls.den{1},6));
    wl = [1 10 60 100 300 757 876 1000 3000 5505 20000];
    for k=1:numel(wl)
        gg = squeeze(freqresp(Ls, wl(k)));
        fprintf('  w=%8.2f rad/s (%7.1f Hz): |L|=%9.4e (%7.2f dB) phase=%+9.3f deg\n', ...
            wl(k), wl(k)/(2*pi), abs(gg), 20*log10(abs(gg)), rad2deg(angle(gg)));
    end
    % margin() 返回顺序是 [Gm, Pm, Wcg, Wcp] —— 曾读反成 [Pm,Gm,...]，已修正
    [Gm,Pm,Wcg,Wcp] = margin(Ls);
    fprintf('  margin(): PM=%.3f deg  GM=%.4g  Wcg=%.4g  Wcp=%.4g\n', Pm,Gm,Wcg,Wcp);
    fprintf('  dcgain(L)=%s (Inf 表示含积分器)\n', mat2str(dcgain(Ls),6));
end