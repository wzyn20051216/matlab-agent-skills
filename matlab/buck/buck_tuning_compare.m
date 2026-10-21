% Buck PI 调参对比：不同 Kp 对负载阶跃跌落的影响
% 核心：纯积分 vs 加比例项的扰动抑制权衡（Task4 定稿版）
%
% 与旧版的区别（事故复盘见 buck_pi_tuning_sweep.m 头部注释）：
%   - 扫描逻辑移入 buck_pi_tuning_sweep，三条不变量在函数内结构性保证
%   - 本脚本负责不变量断言（失败即报错，不允许"看起来跑完了"）
%   - 裕度用 local_margins（全交越最坏值），不用 margin() 单点
%
% 用法: buck_tuning_compare(outDir)
function buck_tuning_compare(outDir)
if nargin < 1 || isempty(outDir)
    outDir = fullfile(fileparts(mfilename('fullpath')), '..', '..', ...
        'artifacts', 'validation', 'buck');
end
if ~exist(outDir, 'dir'); mkdir(outDir); end
close all;

% ---- 候选参数组：纯积分 + 不同比例项（负载 6Ω->3Ω @30ms）----
configs = [
    struct('Kp',0.0,   'Ki',7.902901, 'label','纯积分 Ki=7.9')
    struct('Kp',0.005, 'Ki',7.902901, 'label','Kp=0.005')
    struct('Kp',0.01,  'Ki',7.902901, 'label','Kp=0.01')
    struct('Kp',0.02,  'Ki',7.902901, 'label','Kp=0.02')
];

sweep = buck_pi_tuning_sweep(configs, outDir);

% ---- 不变量断言（Task4 回归核心，任一条失败即 error）----
assert(numel(sweep) == numel(configs), ...
    'I1 违反：遍历数 %d ~= 配置数 %d', numel(sweep), numel(configs));
assert(numel(unique({sweep.id})) == numel(sweep), 'I2 违反：id 不唯一');
for k = 1:numel(sweep)
    if strcmp(sweep(k).status, 'failed')
        assert(isnan(sweep(k).Pm) && isnan(sweep(k).dipPct) ...
            && isempty(sweep(k).vC) && isempty(sweep(k).t), ...
            'I3 违反：失败条目 %d 的指标未清空（疑似沿用）', k);
    else
        assert(isfinite(sweep(k).Pm) && isfinite(sweep(k).dipPct) ...
            && ~isempty(sweep(k).vC), ...
            'ok 条目 %d 指标不完整', k);
    end
end

% ---- 结果表 ----
fprintf('=== PI 调参对比（负载阶跃 6Ω→3Ω @30ms，不变量断言已通过）===\n');
fprintf('%-18s %8s %8s %9s %10s %9s %10s\n', ...
    'label', 'PM(°)', 'GM(dB)', 'f_c(Hz)', '跌落%', '恢复(ms)', '启动超调%');
for k = 1:numel(sweep)
    s = sweep(k);
    if strcmp(s.status, 'ok')
        fprintf('%-18s %8.2f %8s %9.2f %10.3f %9s %10.3f\n', ...
            s.label, s.Pm, ...
            merge_str(isinf(s.Gm_dB), 'Inf', sprintf('%.2f', s.Gm_dB)), ...
            s.fc, s.dipPct, ...
            merge_str(isnan(s.recoverMs), '--', sprintf('%.3f', s.recoverMs)), ...
            s.startupOs);
    else
        fprintf('%-18s FAILED: %s\n', s.label, s.errMsg);
    end
end

% ---- 物理序回归：Kp 增大 -> 交越被推向 f_n -> PM 必须显著退化 ----
okIdx = find(strcmp({sweep.status}, 'ok'));
Pms = arrayfun(@(i) sweep(i).Pm, okIdx);
if numel(Pms) >= 2
    assert(Pms(end) < Pms(1) - 30, ...
        ['物理序回归失败：Kp=%.4f 的 PM(%.2f) 相比纯积分(%.2f) 退化不足 30°，' ...
         '与"Kp 把交越推入 LC 谐振区"的根因结论矛盾'], ...
        sweep(okIdx(end)).Kp, Pms(end), Pms(1));
    fprintf('\n物理序回归通过：PM 从 %.2f°（纯积分）退化到 %.2f°（Kp=%.4f）\n', ...
        Pms(1), Pms(end), sweep(okIdx(end)).Kp);
end

save(fullfile(outDir, 'buck_tuning_compare.mat'), 'configs', 'sweep');
fprintf('结果已保存：buck_tuning_compare.mat（%d 条配置，%d 条成功）\n', ...
    numel(sweep), sum(strcmp({sweep.status}, 'ok')));
end

function t = merge_str(c, a, b)
if c, t = a; else, t = b; end
end
