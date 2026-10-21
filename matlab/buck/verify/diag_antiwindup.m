%% 诊断：抗饱和符号方向与稳态误差来源
clear; clc;
outDir = getenv('BUCK_OUT'); if isempty(outDir), outDir=fullfile(pwd,'buck'); end
addpath(fullfile(fileparts(fileparts(mfilename('fullpath')))));  % 可移植：相对定位 matlab/buck

fprintf('=== 诊断1：抗饱和 AntiGain 符号方向的影响 ===\n');
fprintf('标准 back-calculation: Int_in = Ki*e + (1/Tt)*(u_sat - u_unsat)\n');
fprintf('当 u_unsat > Dmax 时 u_sat = Dmax < u_unsat => (u_sat-u_unsat) < 0 => 积分器减速（正确）\n\n');

for Tt = [1e-3 1e-2]
  for AG = [1/Tt, -1/Tt]   % 正负两种
    cfg = struct('Kp',0.04,'Ki',20,'notchEnable',false,'Tt',Tt, ...
        'AntiGainOverride',AG, ...
        'loadStepTime',0.03,'loadStepRatio',2,'tStop',0.06,'modelName', ...
        sprintf('diag_%s_%d',merge(AG>0,'pos','neg'), round(abs(AG))));
    try
      r = build_buck_closed_loop_generic(outDir, cfg);
      t=r.t; vC=r.vC; duty=r.duty;
      fprintf('  Tt=%.0e AntiGain=%+.0f: vC(end)=%.4f duty(end)=%.4f duty_max=%.3f 启动超调=%.2f%%\n', ...
          Tt, AG, vC(end), duty(end), max(duty), (max(vC)-12)/12*100);
    catch e
      fprintf('  Tt=%.0e AntiGain=%+.0f: FAIL %s\n', Tt, AG, e.message);
    end
  end
end

fprintf('\n=== 诊断2：去掉抗饱和（AntiGain=0）看纯 PI 稳态 ===\n');
cfg = struct('Kp',0.04,'Ki',20,'notchEnable',false,'Tt',1e9, ...
    'loadStepTime',[],'tStop',0.06,'Dmax',10,'Dmin',-10,'modelName','diag_nosat');
try
    r = build_buck_closed_loop_generic(outDir, cfg);
    fprintf('  无饱和+无抗饱和: vC(end)=%.6f (理论 12) 误差=%.6f\n', r.vC(end), r.vC(end)-12);
catch e
    fprintf('  FAIL %s\n', e.message);
end

fprintf('\n=== 诊断3：Ki 扫描看稳态收敛 ===\n');
for Ki = [5 10 20 40 80]
    cfg = struct('Kp',0.02,'Ki',Ki,'notchEnable',false, ...
        'loadStepTime',[],'tStop',0.1,'modelName',sprintf('diag_ki_%g',Ki));
    try
        r = build_buck_closed_loop_generic(outDir, cfg);
        fprintf('  Ki=%5.1f: vC(end)=%.6f 误差=%+.6f duty(end)=%.5f\n', ...
            Ki, r.vC(end), r.vC(end)-12, r.duty(end));
    catch e
        fprintf('  Ki=%5.1f FAIL %s\n', Ki, e.message);
    end
end

function t = merge(c,a,b)
if c, t = a; else, t = b; end
end