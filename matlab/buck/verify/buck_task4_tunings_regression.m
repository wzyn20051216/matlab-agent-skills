%% 任务四回归测试：tunings 扫描不变量 + 物理序 + 裕度函数自检
%
% 背景：旧版 buck_tuning_compare.m 有三个缺陷（numel 遍历 cell 得 12 而非 4、
% 序号命名丢 label 关联、失败无隔离）。修复后的不变量由
% buck_pi_tuning_sweep.m 结构性保证，本脚本逐条独立验证：
%   T1 失败注入：3 有效 + 2 故意坏配置（Kp 非数值 / 缺 Ki 字段）
%      -> I1 数量一致、I2 id 唯一（含同名 label 去重）、I3 失败条目指标
%         全 NaN 且波形为空（不沿用），且失败不中断后续有效配置
%   T2 真实 4 配置扫描：数量一致、全部 ok、PM 随 Kp 显著退化
%      （物理序：Kp 把交越推向 LC 谐振 f_n，PM 必须掉 >30°）
%   T3 local_margins 自检：与 margin() 在基线上一致（GM/PM/交越频率），
%      且基线的相位穿越必须精确落在 f_n（物理：相位在谐振处过 -180°）
%
% 任一检查失败 -> 脚本报错退出（exit code 1），可作 CI 门禁。
clear; close all;
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, '..'));                 % matlab/buck（local_margins 等）
outDir = getenv('BUCK_OUT');
if isempty(outDir), outDir = fullfile(here, '..', '..', 'artifacts', 'validation', 'buck'); end
outDir = strrep(outDir, '/', filesep);

fails = {};

fprintf('================ 任务四回归 ================\n');

%% ---------- T1：失败注入与不变量 ----------
fprintf('\n--- T1：失败注入（3 有效 + 2 故意坏）---\n');
bad1 = struct('Kp','not-a-number', 'Ki',7.902901, 'label','坏Kp');
bad2 = struct('Kp',0.01, 'label','缺Ki字段');      % 故意不写 Ki
% 用 cell 数组：结构体数组要求所有元素字段一致，无法表达"缺字段"
cfgT1 = {
    struct('Kp',0.0,  'Ki',7.902901, 'label','有效A')
    bad1
    struct('Kp',0.02, 'Ki',7.902901, 'label','有效B')
    bad2
    struct('Kp',0.0,  'Ki',7.902901, 'label','有效A')   % 同名 label -> 必须去重
};
s1 = buck_pi_tuning_sweep(cfgT1, outDir);
for k = 1:numel(s1)
    fprintf('  [%d] id=%-14s status=%-7s Pm=%s\n', k, s1(k).id, s1(k).status, ...
        merge2(isnan(s1(k).Pm), 'NaN', sprintf('%.2f', s1(k).Pm)));
end
fails = check(fails, numel(s1) == numel(cfgT1), ...
    sprintf('I1: 数量 %d ~= %d', numel(s1), numel(cfgT1)));
fails = check(fails, numel(unique({s1.id})) == numel(s1), 'I2: id 不唯一');
fails = check(fails, strcmp(s1(2).status,'failed'), '坏 Kp 配置未记 failed');
fails = check(fails, strcmp(s1(4).status,'failed'), '缺 Ki 配置未记 failed');
for k = [2 4]
    fails = check(fails, isempty(s1(k).vC) && isempty(s1(k).t) ...
        && isnan(s1(k).Pm) && isnan(s1(k).dipPct) && isnan(s1(k).Gm_dB), ...
        sprintf('I3: 失败条目 %d 指标未清空', k));
end
for k = [1 3 5]
    fails = check(fails, strcmp(s1(k).status,'ok') && ~isempty(s1(k).vC) ...
        && isfinite(s1(k).Pm) && isfinite(s1(k).dipPct), ...
        sprintf('失败未隔离：有效条目 %d 受影响', k));
end
fails = check(fails, ~strcmp(s1(1).id, s1(5).id), 'I2: 同名 label 未去重');

%% ---------- T2：真实 4 配置 + 物理序 ----------
fprintf('\n--- T2：真实 4 配置扫描与物理序回归 ---\n');
cfgT2 = [
    struct('Kp',0.0,   'Ki',7.902901, 'label','纯积分 Ki=7.9')
    struct('Kp',0.005, 'Ki',7.902901, 'label','Kp=0.005')
    struct('Kp',0.01,  'Ki',7.902901, 'label','Kp=0.01')
    struct('Kp',0.02,  'Ki',7.902901, 'label','Kp=0.02')
];
s2 = buck_pi_tuning_sweep(cfgT2, outDir);
fails = check(fails, numel(s2) == 4, sprintf('T2: 数量 %d ~= 4', numel(s2)));
okMask = strcmp({s2.status}, 'ok');
fails = check(fails, all(okMask), 'T2: 存在失败条目（真实配置应全部成功）');
if all(okMask)
    Pms = [s2.Pm];
    fprintf('  PM = %s\n', mat2str(Pms, 3));
    fails = check(fails, Pms(2) < Pms(1) - 30, ...
        sprintf('物理序: Kp=0.005 PM=%.2f 相比纯积分 %.2f 退化不足 30 deg', Pms(2), Pms(1)));
    fails = check(fails, Pms(4) < Pms(1) - 30, ...
        sprintf('物理序: Kp=0.02 PM=%.2f 相比纯积分 %.2f 退化不足 30 deg', Pms(4), Pms(1)));
    fails = check(fails, all(isfinite([s2.dipPct])), 'T2: dipPct 存在非有限值');
    fails = check(fails, all([s2.dutyMin] >= 0 & [s2.dutyMax] <= 0.9), ...
        'T2: duty 超出 [0,0.9] 限幅');
end

%% ---------- T3：local_margins 与 margin() 一致性 ----------
fprintf('\n--- T3：local_margins 自检 ---\n');
Vin = 48; Lc = 150e-6; Cc = 220e-6; Rc = 6;
Gvd = tf(ss([0,-1/Lc; 1/Cc,-1/(Rc*Cc)], [Vin/Lc;0], [0 1], 0));
Lb = pid(0, 7.902901, 0, 0) * Gvd;
[Gm0, Pm0, Wcg0, Wcp0] = margin(Lb);
[g1, p1, wcg1, wcp1, xov1] = local_margins(Lb);
fprintf('  margin(): GM=%.4f (%.3f dB)  PM=%.4f deg  Wcg=%.2f  Wcp=%.2f\n', ...
    Gm0, 20*log10(Gm0), Pm0, Wcg0, Wcp0);
fprintf('  local  : GM=%.3f dB         PM=%.4f deg  Wcg=%.2f  Wcp=%.2f  穿越数=%d\n', ...
    g1, p1, wcg1, wcp1, numel(xov1));
fails = check(fails, abs(20*log10(Gm0) - g1) < 0.05, ...
    sprintf('T3: GM 不一致 %.4f vs %.4f', 20*log10(Gm0), g1));
fails = check(fails, abs(Pm0 - p1) < 0.05, ...
    sprintf('T3: PM 不一致 %.4f vs %.4f', Pm0, p1));
fails = check(fails, abs(Wcp0 - wcp1)/Wcp0 < 1e-3, ...
    sprintf('T3: Wcp 不一致 %.2f vs %.2f', Wcp0, wcp1));
fn = 1/sqrt(Lc*Cc);
fails = check(fails, abs(wcg1 - fn)/fn < 0.01, ...
    sprintf('T3: 基线相位穿越 %.2f rad/s 未落在 f_n=%.2f', wcg1, fn));

%% ---------- 汇总 ----------
fprintf('\n================ 汇总 ================\n');
if isempty(fails)
    fprintf('任务四回归：全部通过（T1 失败注入 / T2 物理序 / T3 裕度自检）\n');
else
    for k = 1:numel(fails), fprintf('FAIL: %s\n', fails{k}); end
    error('任务四回归失败：%d 项', numel(fails));
end

function fails = check(fails, cond, msg)
if ~cond, fails{end+1} = msg; end
end

function t = merge2(c, a, b)
if c, t = a; else, t = b; end
end
