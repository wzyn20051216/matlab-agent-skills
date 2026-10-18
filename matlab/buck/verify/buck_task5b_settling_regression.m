%% 调节时间口径修复的回归测试（Phase 3A.2 / 缺陷 F-16）
%
% 覆盖：
%   S1 单调指数衰减（解析解可算 settle）
%   S2 先进入频带、再越界、再进入（首次进入口径会高估恢复——本测试的核心）
%   S3 增长振荡（不得报告恢复成功）
%   S4 含 NaN（不得输出虚假数字）
%   S5 记录窗口不足（末段仍在衰减：区分"未收敛"与"窗口不足"）
%   S6 真实负载阶跃波形（C1×BASE / C1×OPT）：修复前后指标对比 +
%      求解器步长 / 仿真时长 / 稳态窗口敏感性
%
% 输出: settling_regression.json
clear; close all;
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, '..'));
outDir = getenv('BUCK_OUT');
if isempty(outDir), outDir = fullfile(here, '..', '..', 'artifacts', 'validation', 'buck'); end
outDir = strrep(outDir, '/', filesep);
if ~exist(outDir, 'dir'), mkdir(outDir); end
nPass = 0; nFail = 0;
fprintf('================ 调节时间口径回归（F-16）================\n');

%% ---------- S1：单调指数（解析解） ----------
fprintf('\n--- S1 单调指数衰减（解析解）---\n');
tau = 5e-3;
t = (0:0.00001:0.05)';                   % 0.01ms 网格：settle 量化误差 <0.01ms
y = 12*(1 + 0.2*exp(-t/tau));
m1 = step_metrics(t, y, 12, 0, 1);
settle_ref = tau*log(0.2/0.01)*1e3;       % 12*0.2*exp(-t/tau)=0.12
fprintf('  settle=%.4f ms（解析 %.4f）  firstEntry=%.4f  nExits=%d  converged=%d\n', ...
    m1.settleMs, settle_ref, m1.firstEntryMs, m1.nExits, m1.converged);
ok = abs(m1.settleMs - settle_ref) < 0.01 && abs(m1.firstEntryMs - settle_ref) < 0.01 ...
     && m1.nExits == 0 && m1.converged;
nPass = nPass + report('S1 单调指数：settle 命中解析值（起步型首次进入也正确）', ok);
r.S1_settle = m1.settleMs; r.S1_ref = settle_ref;

%% ---------- S2：先进入频带后又越界（核心用例） ----------
fprintf('\n--- S2 先进入、后越界、再进入（首次进入口径的高估陷阱）---\n');
t = (0:0.0001:0.05)';
bump = 0.3*exp(-(t-0.010)/0.003).*(t >= 0.010);
y = 12 + 0.05*exp(-t/0.001).*cos(2*pi*t/0.0005) + bump;
m2 = step_metrics(t, y, 12, 0, 1);
settle_ref2 = 0.003*log(0.3/0.12)*1e3 + 10;   % 凸包衰减到 0.12 的时刻
% 旧口径（3A.1 实现：锚在最小值后首次进入）会报什么：
[~, diOld] = min(y - 12);
inBO = abs(y - 12) <= 0.12;
biOld = find(inBO(diOld:end), 1, 'first');
oldFirst = t(diOld+biOld-1)*1e3;
fprintf('  新口径: firstEntry=%.4f  settle=%.4f ms（解析 %.4f）  nExits=%d\n', ...
    m2.firstEntryMs, m2.settleMs, settle_ref2, m2.nExits);
fprintf('  旧口径（锚最小值）会报 firstEntry=%.4f ms -> 高估恢复 %.2f ms\n', ...
    oldFirst, m2.settleMs - oldFirst);
ok = abs(m2.settleMs - settle_ref2) < 0.05 && abs(m2.firstEntryMs - settle_ref2) < 0.15 ...
     && oldFirst < 1 && m2.nExits == 0;
nPass = nPass + report('S2 新口径锚在最大偏差处正确；旧口径高估 12.5ms（陷阱复现）', ok);
r.S2_first = m2.firstEntryMs; r.S2_settle = m2.settleMs; r.S2_oldFirst = oldFirst;

%% ---------- S3：增长振荡（不得报恢复） ----------
fprintf('\n--- S3 增长振荡（末点仍越界，必须报未收敛）---\n');
t = (0:0.0001:0.05)';
y = 12 + 0.5*exp(t/0.005);              % 指数增长：任何时刻都出频带
m3 = step_metrics(t, y, 12, 0, 1);
fprintf('  settle=%s  converged=%d  nExits=%s  growth=%.3f（>1=在增长）\n', ...
    m3s(m3.settleMs), m3.converged, m3s(m3.nExits), m3.growth);
ok = isnan(m3.settleMs) && ~m3.converged && m3.growth > 1;
nPass = nPass + report('S3 增长振荡：settle=NaN，不报恢复', ok);
r.S3_growth = m3.growth;

%% ---------- S4：含 NaN（不得输出虚假数字） ----------
fprintf('\n--- S4 输入含 NaN ---\n');
t = (0:0.0001:0.05)';
y = 12*(1 + 0.2*exp(-t/tau));
y(1000:1100) = NaN;                     % 注入一段 NaN
m4 = step_metrics(t, y, 12, 0, 1);
fprintf('  hasNaN=%d  settle=%s  dipPct=%s  growth=%s（全部应为 NaN/不可用）\n', ...
    m4.hasNaN, m3s(m4.settleMs), m3s(m4.dipPct), m3s(m4.growth));
ok = m4.hasNaN && isnan(m4.settleMs) && isnan(m4.dipPct) && isnan(m4.growth);
nPass = nPass + report('S4 NaN 输入：指标全 NaN，不输出虚假数字', ok);
r.S4_hasNaN = m4.hasNaN;

%% ---------- S5：记录窗口不足（与 S3 的"真未收敛"区分） ----------
fprintf('\n--- S5 记录窗口不足（末段仍在衰减，但不是发散）---\n');
t = (0:0.0001:0.010)';                 % 只记到 10ms，解析 settle 在 14.98ms
y = 12*(1 + 0.2*exp(-t/tau));
m5 = step_metrics(t, y, 12, 0, 1);
fprintf('  settle=%s  converged=%d  growth=%.3f（<1=仍在衰减）\n', ...
    m3s(m5.settleMs), m5.converged, m5.growth);
ok = isnan(m5.settleMs) && ~m5.converged && m5.growth < 1;
nPass = nPass + report('S5 窗口不足：不伪造收敛（growth<1 提示仍在衰减）', ok);
r.S5_growth = m5.growth;

%% ---------- S6：真实波形 + 敏感性 ----------
fprintf('\n--- S6 真实负载阶跃波形（C1×BASE / C1×OPT）与敏感性 ---\n');
Vin=48; Lb=150e-6; Cb=220e-6;
d3 = load(fullfile(outDir,'task3_best_controller.mat'));
b = d3.best; fnNom = d3.fn;
runOne = @(cfg) build_buck_closed_loop_generic(outDir, cfg);
baseCfg = struct('Kp',0,'Ki',7.902901,'R',6,'Vin',Vin,'L',Lb,'C',Cb,'Vref',12, ...
    'loadStepTime',0.06,'loadStepRatio',2,'tStop',0.12,'maxStep',1e-6, ...
    'saveModel',false);
optCfg = baseCfg; optCfg.Kp = b.Kp; optCfg.Ki = b.Ki; optCfg.notchEnable = true;
optCfg.notchWn = fnNom; optCfg.notchZn = b.zn; optCfg.notchZd = b.zd;
rB = runOne(baseCfg); rO = runOne(optCfg);
mB = step_metrics(rB.t, rB.vC, 12, 0.06, 1);
mO = step_metrics(rO.t, rO.vC, 12, 0.06, 1);
fprintf('  C1×BASE: dip=%+.3f%%  firstEntry=%.3f ms  settle=%.3f ms  nExits=%d  tailInBand=%.2f ms\n', ...
    mB.dipPct, mB.firstEntryMs, mB.settleMs, mB.nExits, mB.tailInBandMs);
fprintf('  C1×OPT : dip=%+.3f%%  firstEntry=%.3f ms  settle=%.3f ms  nExits=%d  tailInBand=%.2f ms\n', ...
    mO.dipPct, mO.firstEntryMs, mO.settleMs, mO.nExits, mO.tailInBandMs);
ok6 = ~isnan(mB.settleMs) && ~isnan(mO.settleMs) && ...
      (mB.settleMs > mB.firstEntryMs) && (mO.settleMs > mO.firstEntryMs);
nPass = nPass + report('S6 真实波形：两个口径都算出且 settle>firstEntry（旧口径高估）', ok6);
r.S6_base_first = mB.firstEntryMs; r.S6_base_settle = mB.settleMs;
r.S6_opt_first = mO.firstEntryMs;  r.S6_opt_settle = mO.settleMs;

% 敏感性 1：求解器步长
fprintf('\n  敏感性-求解器步长（C1×BASE）:\n');
for ms = [5e-7 1e-6 1e-5]
    cfg = baseCfg; cfg.maxStep = ms; cfg.modelName = sprintf('sens_ms_%g', ms);
    rr = runOne(cfg); mm = step_metrics(rr.t, rr.vC, 12, 0.06, 1);
    fprintf('    maxStep=%.1e: settle=%.4f ms  dip=%+.4f%%  ssErr(110-120ms)=%+.5f%%\n', ...
        ms, mm.settleMs, mm.dipPct, (mean(rr.vC(rr.t>0.11))-12)/12*100);
end
% 敏感性 2：仿真终止时间（C1×OPT，慢模态 tau=12.1ms）
fprintf('  敏感性-仿真终止时间（C1×OPT）:\n');
for ts = [0.12 0.20 0.30]
    cfg = optCfg; cfg.tStop = ts; cfg.modelName = sprintf('sens_ts_%g', ts);
    rr = runOne(cfg); mm = step_metrics(rr.t, rr.vC, 12, 0.06, 1);
    fprintf('    tStop=%.2f s: settle=%.4f ms  ssErr(末10ms)=%+.5f%%  ssErr(100-120ms)=%+.5f%%\n', ...
        ts, mm.settleMs, (mean(rr.vC(rr.t>ts-0.01))-12)/12*100, ...
        (mean(rr.vC(rr.t>0.10 & rr.t<0.12))-12)/12*100);
end
% 敏感性 3：稳态窗口（C1×OPT）
fprintf('  敏感性-稳态窗口（C1×OPT, tStop=0.30）:\n');
cfg = optCfg; cfg.tStop = 0.30; cfg.modelName = 'sens_win';
rr = runOne(cfg);
for w0 = [0.06 0.10 0.18 0.28]
    ss = (mean(rr.vC(rr.t>w0))-12)/12*100;
    fprintf('    窗口 t>%.2f s: ssErr=%+.5f%%\n', w0, ss);
end

%% ---------- 汇总 ----------
fprintf('\n================ 汇总 ================\n');
fprintf('通过 %d / 失败 %d（共 6 组）\n', nPass, nFail);
fid = fopen(fullfile(outDir,'settling_regression.json'),'w');
fwrite(fid, jsonencode(struct('passed',nPass,'failed',nFail,'detail',r)), 'char'); fclose(fid);
fprintf('已保存 settling_regression.json\n');

function n = report(name, ok)
if ok, fprintf('  [PASS] %s\n', name); n = 1;
else, fprintf('  [FAIL] %s\n', name); n = 0; end
end

function s = m3s(x)
if isnan(x), s = 'NaN'; else, s = sprintf('%.4f', x); end
end
