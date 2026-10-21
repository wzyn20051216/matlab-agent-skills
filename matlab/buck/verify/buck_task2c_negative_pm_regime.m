%% 任务二补充（定稿）：负相位裕度区间的完整刻画
%
% 任务二主表只覆盖 Kp<=0.02（PM 最低 8.56 deg，仍为正）。"负相位裕度"
% 出现在更大 Kp / 更大 Ki 的组合。本脚本给出负 PM 的完整边界与闭式条件：
%
% 【闭式推导】纯积分回路 L(s) = (Ki/s)*Gvd(s)，Gvd 为 LC 二阶：
%   phase(L(j*wn)) = -90 deg(积分器) + (-90 deg)(二阶在谐振处) = -180 deg  【精确】
%   |L(j*wn)| = (Ki/wn) * |Gvd(wn)|，而 |Gvd(wn)| = Vin*R/(L*wn) = Vin*R*C  【谐振峰值】
%   => |L(wn)| = Ki*R*Vin*C
%   => PM = 0（交越恰落在谐振点）当且仅当  Ki = 1/(R*Vin*C)
%   => Ki > 1/(R*Vin*C)：交越越过 f_n，PM<0 且 GM<0，闭环出现 RHP 极点（真不稳）
%
% 对 Kp 项：比例项把交越进一步推高并使高频相位结构改变，PM 随 Kp 单调劣化，
% 与 Ki 项共同决定交越位置；判据统一为"交越频率 vs f_n"。
%
% 输出: task2c_negative_pm_regime.mat + task2c_negative_pm_regime.png
clear; close all;
outDir = getenv('BUCK_OUT'); if isempty(outDir), outDir = fullfile(pwd,'buck'); end
outDir = strrep(outDir,'/',filesep); if ~exist(outDir,'dir'), mkdir(outDir); end
addpath(fullfile(fileparts(fileparts(mfilename('fullpath')))));

Vin=48; L=150e-6; C=220e-6; R=6; Vout=12;
A=[0,-1/L; 1/C,-1/(R*C)]; B=[Vin/L;0]; Co=[0,1];
Gvd = minreal(tf(ss(A,B,Co,0)));
wn = 1/sqrt(L*C); fn = wn/(2*pi);

fprintf('================ 任务二补充：负相位裕度区间 ================\n');
fprintf('f_n=%.2f Hz, |Gvd(f_n)|=%.2f (闭式 Vin*R/(L*wn)=%.2f)\n', ...
    fn, abs(squeeze(freqresp(Gvd,wn))), Vin*R/(L*wn));

% ---- 闭式临界 Ki ----
Ki_crit = 1/(R*Vin*C);
fprintf('闭式临界 Ki = 1/(R*Vin*C) = %.4f（此时交越恰在 f_n，PM=0）\n', Ki_crit);
% 数值验证：|L(j*wn)| = Ki*R*Vin*C
Lchk = (Ki_crit/wn)*abs(squeeze(freqresp(Gvd,wn)));
fprintf('数值验证: |L(j*wn)| @ Ki_crit = %.6f（应为 1）\n\n', Lchk);

%% ---------- 1) 纯积分 Ki 扫描 ----------
fprintf('--- 纯积分回路 Ki 扫描 ---\n');
fprintf('%10s %9s %9s %10s %11s %6s %12s\n', ...
    'Ki','PM(deg)','GM(dB)','fc(Hz)','maxRe极点','稳定','fc/f_n');
Ki_list = [7.9029 10 12 14 15.78 16 18 20 25 30 40 80 160];
rowsKi = [];
for Ki = Ki_list
    Lp = pid(0,Ki,0,0)*Gvd;
    [Gm_dB,Pm,~,Wcp] = local_margins(Lp);
    clp = pole(feedback(Lp,1)); mre = max(real(clp));
    fc = Wcp/(2*pi);
    fprintf('%10.4f %9.2f %9s %10.2f %11.2f %6d %12.3f\n', ...
        Ki, Pm, merge_s(isinf(Gm_dB),'Inf',sprintf('%.2f',Gm_dB)), ...
        fc, mre, mre<0, fc/fn);
    rowsKi(end+1,:) = [Ki Pm Gm_dB fc mre]; %#ok<SAGROW>
end

% 数值临界 Ki：GM(Ki) 单调递减穿过 0（纯积分回路 GM=0 与 PM=0 同在 Ki_crit）
% 注意不能对 PM 二分：Ki 略超临界后交越落到 f_n 下方，PM 反而变正（多交越），
% 不稳定必须以 GM<0 / RHP 极点判定。
gmOf = @(Ki) local_margins(pid(0,Ki,0,0)*Gvd);
a = 10; b = 40;
fa = gmOf(a); fb = gmOf(b);
fprintf('\nGM(%.1f)=%+.3f dB, GM(%.1f)=%+.3f dB -> 二分求 GM=0 的临界 Ki\n', a,fa,b,fb);
for it = 1:60
    m = 0.5*(a+b);
    if gmOf(m) > 0, a = m; else, b = m; end
end
Ki_num = 0.5*(a+b);
fprintf('数值临界 Ki = %.4f（闭式 %.4f，相对误差 %.2e）\n', ...
    Ki_num, Ki_crit, abs(Ki_num-Ki_crit)/Ki_crit);
fprintf('注：Ki>Ki_crit 后闭环不稳（GM<0、RHP 极点），此时 PM 读数因多交越失去意义。\n');

%% ---------- 2) Kp 扫描（Ki=7.9029 固定）----------
fprintf('\n--- Kp 扫描（Ki=7.9029 固定）---\n');
fprintf('%8s %9s %9s %10s %10s %11s %6s\n', ...
    'Kp','PM(deg)','GM(dB)','fc(Hz)','fc/f_n','超调%','稳定');
Kp_list = [0 0.005 0.01 0.02 0.05 0.1 0.2];
rowsKp = [];
for Kp = Kp_list
    Lp = pid(Kp,7.902901,0,0)*Gvd;
    [Gm_dB,Pm,~,Wcp] = local_margins(Lp);
    clp = pole(feedback(Lp,1)); mre = max(real(clp));
    Tcl = feedback(Lp,1);
    os = stepinfo(Tcl).Overshoot;
    fc = Wcp/(2*pi);
    fprintf('%8.3f %9.2f %9s %10.2f %10.3f %11.2f %6d\n', ...
        Kp, Pm, merge_s(isinf(Gm_dB),'Inf',sprintf('%.2f',Gm_dB)), ...
        fc, fc/fn, os, mre<0);
    rowsKp(end+1,:) = [Kp Pm Gm_dB fc os mre]; %#ok<SAGROW>
end

%% ---------- 3) 负裕度实例：Ki 越过临界值的不同表现 ----------
% 理论：任意 Kp>0 都会把 f_n 处的相位抬到 -180 deg 以上（pid 相位 > -90 deg），
% 因此 GM<0/RHP 极点只在 Ki 越过 1/(R*Vin*C) 且 Kp 足够小时出现；
% Kp 较大时 PM->0+（趋近但不越过 0），表现为超调爆炸而非数值发散。
fprintf('\n--- 负裕度实例（Ki 越过 1/(R*Vin*C)）---\n');
combos = [0, 160; 0.001, 160; 0.02, 20; 0.05, 40; 0.10, 80];
rowsNeg = [];
for i = 1:size(combos,1)
    Kp = combos(i,1); Ki = combos(i,2);
    Lp = pid(Kp,Ki,0,0)*Gvd;
    [Gm_dB,Pm,~,Wcp] = local_margins(Lp);
    clp = pole(feedback(Lp,1)); mre = max(real(clp));
    nRHP = sum(real(clp) > 0);
    fprintf('Kp=%.3f Ki=%5.1f | PM=%+8.2f deg  GM=%8s dB  maxRe=%+9.2f  RHP极点=%d\n', ...
        Kp, Ki, Pm, merge_s(isinf(Gm_dB),'Inf',sprintf('%.2f',Gm_dB)), mre, nRHP);
    rowsNeg(end+1,:) = [Kp Ki Pm Gm_dB mre nRHP]; %#ok<SAGROW>
end

%% ---------- 图 ----------
fig = figure('Visible','off','Position',[100 100 1280 850]);
subplot(2,2,1);
semilogx(rowsKi(:,1), rowsKi(:,2), 'bo-','LineWidth',1.5); hold on; grid on;
yline(0,'r--','PM=0'); xline(Ki_crit,'g--',sprintf('K_i_{crit}=%.2f',Ki_crit));
xlabel('K_i'); ylabel('PM (deg)');
title(sprintf('纯积分：PM vs K_i（临界 K_i=1/(R V_{in} C)=%.2f）',Ki_crit));
unstable = rowsKi(:,5) >= 0;
if any(unstable)
    semilogx(rowsKi(unstable,1), rowsKi(unstable,2),'rs','MarkerSize',10);
    legend('PM','PM=0','临界 Ki','RHP 极点','Location','best');
end

subplot(2,2,2);
semilogx(rowsKi(:,1), rowsKi(:,3), 'mo-','LineWidth',1.5); hold on; grid on;
yline(0,'r--','GM=0'); xline(Ki_crit,'g--');
xlabel('K_i'); ylabel('GM (dB)');
title('纯积分：GM vs K_i（Ki 越界后 GM<0，真不稳）');

subplot(2,2,3);
semilogx(rowsKp(:,1), rowsKp(:,2), 'bo-','LineWidth',1.5); hold on; grid on;
yline(0,'r--','PM=0');
xlabel('K_p（K_i=7.9029 固定）'); ylabel('PM (deg)');
title('Kp 劣化：PM 从 89.5° 崩到近 0');

subplot(2,2,4);
semilogx(rowsKp(:,1), rowsKp(:,4)/fn, 'ks-','LineWidth',1.5); hold on; grid on;
yline(1,'r--','f_n');
yyaxis right;
semilogx(rowsKp(:,1), rowsKp(:,5), 'r^-','LineWidth',1.5);
ylabel('阶跃超调 (%)'); xlabel('K_p');
title('交越频率越过 f_n + 超调爆炸');
legend('f_c/f_n','f_n','超调%','Location','best');
sgtitle('负相位裕度区间：交越频率与 LC 谐振 f_n 的相对位置决定 PM');
saveas(fig, fullfile(outDir,'task2c_negative_pm_regime.png')); close(fig);

save(fullfile(outDir,'task2c_negative_pm_regime.mat'), ...
    'rowsKi','rowsKp','rowsNeg','Ki_crit','Ki_num','Gvd','wn','fn','Vin','L','C','R','Vout');
fprintf('\n已保存 task2c_negative_pm_regime.mat / .png\n');

function t = merge_s(c,a,b)
if c, t = a; else, t = b; end
end
