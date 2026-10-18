%% 自检：Simulink 陷波器实现 vs 理论 tf 对象 的数值等价性
% 目的：防止「频域 tf 对象正确、Simulink 传函块实现错误」这类
%       只在时域仿真中暴露的错误再次发生。
clear; clc;
outDir = getenv('BUCK_OUT'); if isempty(outDir), outDir=fullfile(pwd,'buck'); end
addpath(fullfile(fileparts(fileparts(mfilename('fullpath')))));  % 可移植：相对定位 matlab/buck
s = tf('s');

fn = 5504.8;
zn = 0.02; zd = 0.5;
wn = fn;

% 理论陷波器
N_theory = minreal((s^2 + 2*zn*wn*s + wn^2)/(s^2 + 2*zd*wn*s + wn^2));
% Simulink 实现（严格真有理分解）
N_impl = minreal(tf([1, 2*zn*wn, wn^2], [1, 2*zd*wn, wn^2]));  % 与 Simulink Transfer Fcn 同参数

w = logspace(0,5,20001);
a = squeeze(freqresp(N_theory,w));
b = squeeze(freqresp(N_impl,w));
errMag = max(abs(abs(a)-abs(b)));
errPhs = max(abs(unwrap(angle(a))-unwrap(angle(b))));

fprintf('=== 陷波器传递函数自检（频域）===\n');
fprintf('DC 增益  : %.8f（应为 1）\n', dcgain(N_theory));
fprintf('f_n 处|N|: %.6f（应为 zn/zd = %.6f）\n', ...
    abs(squeeze(freqresp(N_theory,wn))), zn/zd);
fprintf('高频增益 : %.6f（应为 1）\n', abs(squeeze(freqresp(N_theory,1e6))));
if abs(dcgain(N_theory)-1)<1e-9 && abs(abs(squeeze(freqresp(N_theory,wn)))-zn/zd)<1e-6
    fprintf('>> 频域特性 PASS\n');
else
    fprintf('>> 频域特性 FAIL\n');
end

% 关键检验：Simulink 传函块实现的**时域**响应 vs tf 对象预测。
% 上一轮的真实缺陷是：频域 tf 对象算出的 PM=57deg 很漂亮，但 Simulink 里
% 用「分子拆两项」的方式实现陷波器会丢掉 s^2 项，导致时域发散。
% 这个缺陷只能靠端到端对照发现，频域比对发现不了。
fprintf('\n=== 端到端对照：Simulink 时域 vs tf 对象线性预测 ===\n');
Kp_t = 0.02; Ki_t = 10;
cfg = struct('Kp',Kp_t,'Ki',Ki_t,'notchEnable',true,'notchWn',wn, ...
    'notchZn',zn,'notchZd',zd,'loadStepTime',[],'tStop',0.05, ...
    'maxStep',1e-6,'modelName','notch_eq_test','saveModel',false);
r = build_buck_closed_loop_generic(outDir, cfg);

Vin=48; L=150e-6; C=220e-6; R=6;
A=[0,-1/L; 1/C,-1/(R*C)]; B=[Vin/L;0]; Co=[0,1]; Do=0;
Gvd = minreal(tf(ss(A,B,Co,Do)));
Cctrl = minreal(pid(Kp_t,Ki_t,0,0)*N_theory);
Tcl = minreal(feedback(Cctrl*Gvd,1));
t = r.t;
dt = t(2)-t(1);
tvec = (0:dt:t(end))';
yt = step(Tcl, tvec);      % 单位阶跃（参考=1V）
yt12 = yt*12;              % 缩放到 12V 参考

sim_ss = mean(r.vC(r.t > 0.04));
nT = size(yt12,1);
pred_ss = mean(yt12(round(0.8*nT):nT));
fprintf('Simulink 末段稳态 vC = %.6f V\n', sim_ss);
fprintf('tf 对象   末段稳态 vC = %.6f V\n', pred_ss);
fprintf('差值 = %.3e V\n', abs(sim_ss - pred_ss));
fprintf('Simulink duty(end) = %.6f（理论 0.25）\n', r.duty(end));

ok1 = abs(r.vC(end)-12) < 0.05;
ok2 = abs(sim_ss - pred_ss) < 0.5;
fprintf('\n');
if ok1, fprintf('>> 时域收敛 PASS：陷波器闭环收敛到 12V\n'); else
    fprintf('>> 时域收敛 FAIL：vC(end)=%.4f\n', r.vC(end)); end
if ok2, fprintf('>> 与线性预测一致 PASS\n'); else
    fprintf('>> 与线性预测不一致 FAIL：Simulink 与 tf 对象差 %.3f V\n', abs(sim_ss-pred_ss)); end
