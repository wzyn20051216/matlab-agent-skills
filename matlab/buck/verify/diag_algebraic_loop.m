%% 诊断：代数环检测 + 与解析 margin 的交叉验证
clear; clc;
outDir = getenv('BUCK_OUT'); if isempty(outDir), outDir=fullfile(pwd,'buck'); end
addpath(fullfile(fileparts(fileparts(mfilename('fullpath')))));  % 可移植：相对定位 matlab/buck

Vin=48; L=150e-6; C=220e-6; R=6;
A=[0,-1/L; 1/C,-1/(R*C)]; B=[Vin/L;0]; Co=[0,1]; Do=0;
Gvd = minreal(tf(ss(A,B,Co,Do)));

fprintf('=== A. 解析 margin 与仿真对照 ===\n');
fprintf('%-8s %-8s %10s %10s %10s %12s\n','Kp','Ki','PM(deg)','fc(Hz)','maxRe','仿真vC(end)');
for Kp = [0 0.02]
  for Ki = [7.9029 20 40 80]
    Ls = pid(Kp,Ki,0,0)*Gvd;
    [Gm,Pm,Wcg,Wcp] = margin(Ls);
    clp = pole(feedback(Ls,1));
    maxRe = max(real(clp));
    cfg = struct('Kp',Kp,'Ki',Ki,'notchEnable',false,'Tt',1e-3, ...
        'loadStepTime',[],'tStop',0.1,'modelName',sprintf('xchk_%g_%g',Kp,Ki));
    r = build_buck_closed_loop_generic(outDir, cfg);
    fprintf('%-8.4g %-8.4g %10.2f %10.2f %10.2f %12.4f %s\n', Kp,Ki,Pm, ...
        merge(isnan(Wcp),NaN,Wcp/(2*pi)), maxRe, r.vC(end), ...
        merge(abs(r.vC(end)-12)<0.05,'', '  <-- 与解析不一致!'));
  end
end

fprintf('\n=== B. 抗饱和是否引入代数环？（对比启用/禁用）===\n');
fprintf('禁用方法：Dmax=100, Dmin=-100（永不饱和），AntiGain 任意\n');
fprintf('%-10s %-10s %12s %12s\n','Kp','Ki','无饱和vC','饱和vC');
for Ki=[20 40]
    c1 = struct('Kp',0.02,'Ki',Ki,'Dmax',100,'Dmin',-100,'tStop',0.1,'modelName',sprintf('nosat_%g',Ki));
    c2 = struct('Kp',0.02,'Ki',Ki,'Dmax',0.9,'Dmin',0,'tStop',0.1,'modelName',sprintf('sat_%g',Ki));
    r1 = build_buck_closed_loop_generic(outDir, c1);
    r2 = build_buck_closed_loop_generic(outDir, c2);
    fprintf('%-10.4g %-10.4g %12.4f %12.4f\n', 0.02, Ki, r1.vC(end), r2.vC(end));
end

fprintf('\n=== C. duty 轨迹（Ki=40，看是否卡在饱和）===\n');
cfg = struct('Kp',0.02,'Ki',40,'notchEnable',false,'Tt',1e-3, ...
    'loadStepTime',[],'tStop',0.1,'modelName','dtrace');
r = build_buck_closed_loop_generic(outDir, cfg);
for tt = [0.001 0.005 0.01 0.02 0.05 0.099]
    [~,ii] = min(abs(r.t-tt));
    fprintf('  t=%6.3fs: vC=%8.4f  duty=%7.4f  err=%8.4f\n', ...
        r.t(ii), r.vC(ii), r.duty(ii), r.err(ii));
end
fprintf('duty 范围 [%.4f, %.4f]\n', min(r.duty), max(r.duty));
fprintf('vC 范围   [%.4f, %.4f]\n', min(r.vC), max(r.vC));

fprintf('\n=== D. 若解析说稳定而仿真发散，检查线性化工作点 ===\n');
fprintf('线性化在 d=0.25, vC=12, iL=2 处。仿真从 vC=0 启动（大信号瞬态）\n');
fprintf('大信号瞬态可能进入 CCM 之外或触发饱和，需分清是「模型问题」还是「控制器问题」。\n');

function t = merge(c,a,b)
if c, t = a; else, t = b; end
end