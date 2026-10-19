function out = cd_d5_statespace()
%CD_D5_STATESPACE  Control: state-space model, stability, step metrics.
%
% INDEPENDENT REFERENCE (closed form for a standard second-order system)
%   A = [0 1; -4 -2]  ->  s^2 + 2 s + 4  ->  wn = 2, zeta = 0.5
%     overshoot      = exp(-pi*zeta/sqrt(1-zeta^2))     = 16.303 %
%     peak time      = pi/(wn*sqrt(1-zeta^2))           = 1.8138 s
%     settling (2 %) = 4/(zeta*wn)                      = 4.0 s
%     poles          = -1 +- j*sqrt(3)
%   These are the reference; stepinfo is the measurement.

A = [0 1; -4 -2]; B = [0;1]; C = [1 0]; D = 0;
sys = ss(A,B,C,D);

wn = 2; zeta = 0.5;
ref.OS  = 100*exp(-pi*zeta/sqrt(1-zeta^2));
ref.Tp  = pi/(wn*sqrt(1-zeta^2));
ref.Ts  = 4/(zeta*wn);
ref.poleReal = -1;

p = pole(sys);
stable = all(real(p) < 0);
S = stepinfo(sys);
OS = S.Overshoot; Tp = S.PeakTime; Ts = S.SettlingTime;

ok = stable && abs(imag(p(1)) - sqrt(3)) < 1e-9 && abs(real(p(1)) + 1) < 1e-9 && ...
     abs(OS - ref.OS) < 0.2 && abs(Tp - ref.Tp) < 0.02 && abs(Ts - ref.Ts) < 0.15;

out.values = struct('poleReal',real(p).','poleImag',imag(p).','stable',stable,'overshoot',OS, ...
    'peakTime',Tp,'settlingTime',Ts);
out.reference = ref;
out.status = tern(ok,'PASS','FAIL');
out.detail = sprintf('poles %.3f+-%.3fj, OS %.2f%% (ref %.2f), Ts %.2f s (ref %.1f)', ...
    real(p(1)), abs(imag(p(1))), OS, ref.OS, Ts, ref.Ts);
end

function s = tern(c,a,b)
if c, s = a; else, s = b; end
end
