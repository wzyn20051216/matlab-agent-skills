%% 闭环模型冒烟测试：验证 PI 与 PI+陷波器两条路径都能跑通
clear; clc;
outDir = getenv('BUCK_OUT'); if isempty(outDir), outDir=fullfile(pwd,'buck'); end
addpath(fullfile(fileparts(fileparts(mfilename('fullpath')))));  % 可移植：相对定位 matlab/buck

fprintf('=== 冒烟测试 1：纯 PI (Kp=0.04, Ki=20, 无陷波器) ===\n');
cfg1 = struct('Kp',0.04,'Ki',20,'notchEnable',false, ...
    'loadStepTime',0.03,'loadStepRatio',2,'tStop',0.06,'modelName','smoke_pi');
try
    r1 = build_buck_closed_loop_generic(outDir, cfg1);
    fprintf('  OK  vC(end)=%.4f  iL(end)=%.4f  duty(end)=%.4f  duty范围[%.3f,%.3f]\n', ...
        r1.vC(end), r1.iL(end), r1.duty(end), min(r1.duty), max(r1.duty));
catch e
    fprintf('  FAIL: %s\n', e.message);
end

fprintf('\n=== 冒烟测试 2：PI + 陷波器 (Kp=0.04, Ki=20) ===\n');
cfg2 = struct('Kp',0.04,'Ki',20,'notchEnable',true, ...
    'notchWn',1/sqrt(150e-6*220e-6),'notchZn',0.02,'notchZd',0.5, ...
    'loadStepTime',0.03,'loadStepRatio',2,'tStop',0.06,'modelName','smoke_notch');
try
    r2 = build_buck_closed_loop_generic(outDir, cfg2);
    fprintf('  OK  vC(end)=%.4f  iL(end)=%.4f  duty(end)=%.4f  duty范围[%.3f,%.3f]\n', ...
        r2.vC(end), r2.iL(end), r2.duty(end), min(r2.duty), max(r2.duty));
catch e
    fprintf('  FAIL: %s\n', e.message);
end

fprintf('\n=== 冒烟测试 3：基线纯积分 (Kp=0, Ki=7.9) ===\n');
cfg3 = struct('Kp',0,'Ki',7.902901,'notchEnable',false, ...
    'loadStepTime',0.03,'loadStepRatio',2,'tStop',0.06,'modelName','smoke_base');
try
    r3 = build_buck_closed_loop_generic(outDir, cfg3);
    fprintf('  OK  vC(end)=%.4f  iL(end)=%.4f  duty(end)=%.4f  duty范围[%.3f,%.3f]\n', ...
        r3.vC(end), r3.iL(end), r3.duty(end), min(r3.duty), max(r3.duty));
    % 负载阶跃指标
    t=r3.t; vC=r3.vC; ts=0.03;
    pre = mean(vC(t>0.02 & t<ts-0.001));
    dip = min(vC(t>=ts & t<=ts+0.002));
    fprintf('  阶跃前=%.4f 跌落=%.2f%% 稳态=%.4f\n', pre, (dip-12)/12*100, mean(vC(t>0.05)));
catch e
    fprintf('  FAIL: %s\n', e.message);
end