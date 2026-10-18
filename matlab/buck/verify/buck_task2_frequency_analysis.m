%% 任务二（定稿）：负相位裕度根因调查
%
% 已由 probe_loop.m 实测确认的关键事实：
%   Gvd 无有限零点；LC 谐振 f_n=876 Hz，zeta=0.0688，Q=7.27（几乎无阻尼）
%   margin() 返回顺序是 [Gm, Pm, Wcg, Wcp]（极易读反）；本脚本裕度一律用
%   local_margins（自实现稠密网格全交越扫描，避开 margin() 单点返回行为）
%   纯积分 Ki=7.9 -> PM=89.45 deg, 交越 60.7 Hz
%   Kp 增大 -> 环路增益在 f_n 处隆起，交越被推入谐振区，相位崩塌
clear; close all; clc;

outDir = getenv('BUCK_OUT'); if isempty(outDir), outDir = fullfile(pwd,'buck'); end
outDir = strrep(outDir,'/',filesep); if ~exist(outDir,'dir'), mkdir(outDir); end
% 路径可移植：从本脚本位置（matlab/buck/verify）推 matlab/buck，不写死盘符
addpath(fullfile(fileparts(fileparts(mfilename('fullpath')))));

Vin = 48; fsw = 50e3; L = 150e-6; C = 220e-6; R = 6; Vout = 12;
D = Vout/Vin; Ts = 1/fsw;
A = [0, -1/L; 1/C, -1/(R*C)]; B = [Vin/L; 0]; Co = [0 1]; Do = 0;
Gvd = minreal(tf(ss(A, B, Co, Do)));
fn = 1/sqrt(L*C); zn = (L/R)/(2*sqrt(L*C));

fprintf('================ 任务二：负相位裕度根因 ================\n');
fprintf('Gvd 分母 = %s\n', mat2str(Gvd.den{1},6));
fprintf('Gvd 分子 = %s   零点 = %s   dcgain = %.4f\n', ...
    mat2str(Gvd.num{1},6), mat2str(zero(Gvd),6), dcgain(Gvd));
fprintf('f_n = %.2f Hz (%.1f rad/s),  zeta = %.4f,  Q = %.2f\n\n', ...
    fn/(2*pi), fn, zn, 1/(2*zn));

tunings = [0.0, 7.902901; 0.005, 7.902901; 0.01, 7.902901; 0.02, 7.902901];
labels  = {'I-only Ki=7.90','Kp=0.005','Kp=0.010','Kp=0.020'};
n = size(tunings,1); rows = cell(n,1);

fprintf('%-15s %9s %8s %11s %9s %11s %6s\n', ...
    '参数','PM(deg)','GM(dB)','Wcp(rad/s)','fc(Hz)','maxRe极点','稳定');
for i = 1:n
    Kp = tunings(i,1); Ki = tunings(i,2);
    Ls = pid(Kp, Ki, 0, 0) * Gvd;

    % 裕度统一用 local_margins（稠密网格 + 全交越 + 最坏值口径）。
    % 历史教训（本轮自查发现并已修正）：早期版本把 margin() 的 Wcg
    % （相位穿越频率, rad/s）误当成"相位穿越处的 |L| 幅值"，导致 GM 列
    % 恒为 20*log10(1/ω) ≈ -70 dB 的垃圾值。正确关系：
    %   GM(dB) = -|L|_dB(相位穿越处)；无相位穿越 -> +Inf
    %   PM(deg) = 180 + phase(0dB 穿越处)
    [Gm_dB, Pm, Wcg, Wcp] = local_margins(Ls);
    if isnan(Wcp), fc = NaN; else, fc = Wcp/(2*pi); end

    clp = pole(feedback(Ls,1));
    maxRe = max(real(clp));
    stable = maxRe < 0;

    Lfn = squeeze(freqresp(Ls, fn));
    wscan = logspace(1, 5, 20001);
    mag = squeeze(abs(freqresp(Ls, wscan)));
    [maxMag, iMax] = max(mag); wPeak = wscan(iMax);

    fprintf('%-15s %9.2f %8.2f %11.2f %9.2f %+11.2f %6d\n', ...
        labels{i}, Pm, Gm_dB, Wcp, fc, maxRe, stable);
    fprintf('        |L(f_n=%.0f Hz)|=%.3f (%+.1f dB) phase=%+8.2f deg | 峰值|L|=%.3f @ %.0f Hz\n', ...
        fn/(2*pi), abs(Lfn), 20*log10(abs(Lfn)), rad2deg(angle(Lfn)), maxMag, wPeak/(2*pi));

    rows{i} = struct('label',labels{i},'Kp',Kp,'Ki',Ki,'Pm',Pm,'Gm_dB',Gm_dB, ...
        'Wcp',Wcp,'Wcg',Wcg,'fc',fc,'clPoles',clp,'maxRe',maxRe,'stable',stable, ...
        'Lfn_mag',abs(Lfn),'Lfn_phase',rad2deg(angle(Lfn)), ...
        'peakMag',maxMag,'peakFreq',wPeak);
end

fprintf('\n============ 根因判定 ============\n');
fprintf('1) 纯积分(Kp=0) 交越 f_c = %.1f Hz，只有 LC 谐振的 1/%.1f；\n', ...
    rows{1}.fc, (fn/(2*pi))/rows{1}.fc);
fprintf('   此时 |L| 在 f_n 处仅 %.3f（%+.1f dB），远低于 0 dB，谐振峰未被激励。\n', ...
    rows{1}.Lfn_mag, 20*log10(rows{1}.Lfn_mag));
fprintf('2) 加 Kp 后比例项抬高高频环路增益，|L| 在 f_n 附近隆起并穿越 0 dB，\n');
fprintf('   交越频率被推进谐振区：\n');
for i = 2:n
    fprintf('   %-15s |L(f_n)=%.3f (%+.1f dB)  f_c=%7.1f Hz = %.2f*f_n  相位 %+7.1f deg\n', ...
        rows{i}.label, rows{i}.Lfn_mag, 20*log10(rows{i}.Lfn_mag), ...
        rows{i}.fc, rows{i}.fc/(fn/(2*pi)), rows{i}.Lfn_phase);
end
fprintf('3) LC 双极点 zeta 仅 %.4f（Q=%.2f），f_n 附近相位由 0 陡降至 -180 deg。\n', zn, 1/(2*zn));
fprintf('\n=> 根因：**不是**反馈符号错、**不是**线性化工作点错、**不是**多重交越、\n');
fprintf('   也**不是** RHP zero（本模型净传函无零点）。而是：\n');
fprintf('   高 Q 的 LC 双极点 + 比例项抬高高频环路增益 => 交越频率被推入谐振区。\n');

fprintf('\n============ 采样效应（Ts=%.0f us，c2d ZOH + 离散 PI）============\n', Ts*1e6);
Gvd_d = c2d(Gvd, Ts, 'zoh');   % Ts=20us，与离散 PI 的采样周期一致
for i = 1:n
    Kp = tunings(i,1); Ki = tunings(i,2);
    % 采样时间必须一致：Gvd_d 的 Ts = Ts，pid(...,Ts) 的 Ts = Ts
    Cd = pid(Kp, Ki, 0, 0, Ts);   % 第4参=微分滤波N，第5参=采样时间Ts
    Ld = Cd * Gvd_d;
    [~, PmD, ~, WcpD] = local_margins(Ld);
    z = pole(feedback(Ld,1));
    fprintf('%-15s PM连续=%7.2f  PM离散=%7.2f  损失=%5.2f deg  离散稳定=%d  max|z|=%.5f\n', ...
        labels{i}, rows{i}.Pm, PmD, rows{i}.Pm-PmD, all(abs(z)<1), max(abs(z)));
    rows{i}.Pm_discrete = PmD; rows{i}.z_discrete = z; rows{i}.stable_discrete = all(abs(z)<1);
end

% Bode 图
fig = figure('Visible','off','Position',[100 100 1200 900]);
wplot = logspace(0, 5, 2000);
for i = 1:n
    subplot(2,2,i);
    Ls = pid(rows{i}.Kp, rows{i}.Ki, 0, 0) * Gvd;
    bodeplot(Ls, wplot); grid on; hold on;
    xline(fn, 'r--', 'f_n');
    title(sprintf('%s  PM=%.1f^\\circ  f_c=%s Hz', rows{i}.label, rows{i}.Pm, ...
        merge(isnan(rows{i}.fc),'--',sprintf('%.1f',rows{i}.fc))));
end
sgtitle('环路 L(s)=C(s)\cdot Gvd(s) 的 Bode 图（红线为 LC 谐振 f_n）');
saveas(fig, fullfile(outDir,'task2_bode_comparison.png')); close(fig);

save(fullfile(outDir,'task2_frequency_analysis.mat'),'rows','Gvd','tunings','labels', ...
    'Vin','L','C','R','Vout','D','Ts','fn','zn');
fprintf('\n已保存 task2_frequency_analysis.mat 与 task2_bode_comparison.png\n');

function t = merge(c,a,b)
if c, t = a; else, t = b; end
end