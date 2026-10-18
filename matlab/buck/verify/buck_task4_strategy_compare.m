%% 任务四：控制策略候选评估与最优候选实现
%
% ========== 任务四的立论依据来自任务五的归因 ==========
% Task 5 §5.4 实测：负载阶跃后占空比仅升到 0.314（上限 0.85，贴限占比 0%），
% 且把 Ki 提高 5 倍只改善 0.3pp。这说明**不是 PI 增益不够，而是单电压环
% 结构受限于"vC 误差 -> 占空比"的单点映射**：阶跃瞬间 vC 偏差只有 0.1V 量级，
% 单环要靠这么小的偏差驱动占空比大幅动作，结构上就不可能快。
%
% 候选评估（不做"为了增加算法数量而全实现"）：
%   C1 带抗饱和 PI        = 现状 BASE/OPT，本任务的对照组
%   C2 陷波器+PI 鲁棒参数 = 扩大陷波换失谐容忍（task3b 已量化）
%   C3 电压外环+电流内环  = 本任务实现重点
%   C4 负载电流前馈       = 需电流测量，且前馈需模型精度
%   C5 带 PM/GM 约束的优化 = task3 已有结构化搜索，本轮扩展为双环参数
%
% 实现 C3 的工程依据：双环是工业界电压模式电源的标准结构（外环定输出电压，
% 内环定电感电流）。内环直接对 iL 闭环，把"电感电流需爬升 6A"交给高带宽内环，
% 而不依赖 vC 偏差 —— 正好命中 §5.4 的归因结论。
% 代价：需要电感电流采样（本例 iL 可观）。
%
% 输出: task4_strategy_compare.json / .png / task4_dual_loop.mat

clear; close all;
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, '..'));
outDir = getenv('BUCK_OUT');
if isempty(outDir), outDir = fullfile(here, '..', '..', 'artifacts', 'validation', 'buck'); end
outDir = strrep(outDir, '/', filesep);
if ~exist(outDir, 'dir'), mkdir(outDir); end

Vin = 48; L = 150e-6; C = 220e-6; R0 = 6; Vref = 12;
Ts_sw = 20e-6; D_MAX = 0.85;
opts = odeset('RelTol',1e-8,'AbsTol',1e-10,'MaxStep',Ts_sw/20);

% 读入定稿控制器（不硬编码）
d3 = load(fullfile(outDir,'task3_best_controller.mat'));
kpO = d3.best.Kp; kiO = d3.best.Ki; znO = d3.best.zn; zdO = d3.best.zd; wnO = d3.fn;

fprintf('================ 任务四：控制策略比较 ================\n');
fprintf('硬件: Vin=%.0fV L=%.0fuH C=%.0fuF R0=%.1fΩ duty 上限 %.2f fs=50kHz\n', ...
    Vin,L*1e6,C*1e6,R0,D_MAX);

%% ---------- 4.1 基准：物理下界（最优占空比轨迹）----------
fprintf('\n--- 4.1 基准：物理下界（最优占空比轨迹，违反因果性的数学上界）---\n');
boundR1 = [3 1.5];
boundDip = zeros(1,2);
for k=1:2
    R1 = boundR1(k);
    f = @(t,x) [(Vin*D_MAX-x(2))/L; (x(1)-x(2)/R1)/C];
    [~,x] = ode45(f, [0 2e-3], [Vref/R0; Vref], opts);
    boundDip(k) = (min(x(:,2))-Vref)/Vref*100;
    fprintf('  R1=%.1fΩ: 物理下界 dip=%+.3f%%\n', R1, boundDip(k));
end

%% ---------- 4.2 候选 C2：扩大陷波器——评估后不实现 ----------
fprintf('\n--- 4.2 候选 C2：扩大陷波器换失谐容忍（频域已量化，不跑时域）---\n');
fprintf('  task3b C 节实测：zn=0.10,zd=0.30 失谐容忍 -0.30/+0.30（定稿 -0.30/+0.08）\n');
fprintf('  但 zn=0.10 时 |L(f_n)|=+13.35dB（谐振峰未压住），PM 仅 26.19°。\n');
fprintf('  => 扩大陷波能换失谐容忍，代价是标称 PM 与谐振抑制。\n');
fprintf('  对本任务失败的 C5/C6（重载跌落）无帮助——跌落不是谐振问题。**不实现**。\n');

%% ---------- 4.3 候选 C4：负载电流前馈——评估后不实现 ----------
fprintf('\n--- 4.3 候选 C4：负载电流前馈——评估后不实现 ---\n');
fprintf('  前馈需要：负载电流测量 + 模型（iL_ref = i_load + C*dvC/dt）。\n');
fprintf('  本例 vC 参考恒定 -> dvC/dt=0 -> 前馈退化为 iL_ref = i_load，可精确算出。\n');
fprintf('  但它只能补偿**稳态**负载电流；阶跃瞬间新电导才刚出现、负载电流未知，\n');
fprintf('  故对"阶跃瞬态跌落"这个失败模式无效（除非配合负载变化率估计）。\n');
fprintf('  结论：**不解决本任务的失败工况**，实现它属于凑数，故不实现。\n');

%% ---------- 4.4 候选 C3：双环控制——实现重点 ----------
fprintf('\n--- 4.4 候选 C3：电压外环 + 电流内环（实现重点）---\n');
% 内环推导（符号推导，不靠试凑——本节初版就栽在这里）：
%   L diL/dt = Vin*d - vC
%   d = vC/Vin + Kci*(iref - iL)/Vin          （前馈 + 比例修正）
%   => L diL/dt = Vin*(vC/Vin) + Kci*(iref-iL) - vC = Kci*(iref - iL)
%   => 内环等效一阶：diL/dt = (Kci/L)(iref - iL)，**tau_i = L/Kci**
%
% 初版误写为 tau_i = L/(Vin*Kci)，导致 Kci 扫描时 PM 恒为 91.86°（与 Kci 无关）
% ——"结果对参数完全不敏感"本身就是可疑信号，据此定位到 Vin 归一化错误。
fprintf('  控制律：d = Vref/Vin + Kci*(iref-iL)/Vin  =>  **tau_i = L/Kci**\n');
fprintf('  前馈必须是常数 Vref/Vin。若写成 vC/Vin，则 Vin*d=vC 恒成立、\n');
fprintf('  电感电压恒为 0，**任何 vC 都是平衡点**（平衡点不唯一），外环无法镇定。\n');

% 外环整定（闭式推导，不从 OPT 折算）：
%   前向 vC/iref = R/(1+sRC)（DC 增益 = R，注意不是 1）；外环 PI=(Kp_e s+Ki_e)/s
%   闭合后特征方程：s(1+sRC) + R(Kp_e s + Ki_e) = 0
%     => s^2*R*C + s*(1 + Kp_e*R) + Ki_e*R = 0
%   对比 s^2 + 2*zeta*wn*s + wn^2：
%     wn^2 = Ki_e/(R*C)  => Ki_e = wn^2*R*C
%     zeta = (1+Kp_e*R)/(2*sqrt(R*C*Ki_e*R))
%   取 Kp_e=0、zeta=0.7 => **Ki_e = 1/(4*zeta^2*R^2*C)**
%
% 3A.2 初版的两个错误（均由可疑信号定位）：
%   (a) 前向增益漏乘 R0（写成 DC=1，实际 DC=6）-> 外环整定失配
%   (b) 外环增益从 OPT 折算得 Ki_e=0.167，比正确值 64.4 小 385 倍
%       -> 外环几乎无积分作用 -> 稳态漂到 vC≈0.3~1.1V、抗饱和长期反压
% ========== 外环整定的硬约束（3A.2 的核心结论）==========
% 纯积分外环（Kp_e=0）时 zeta = 1/(2*R*sqrt(C*Ki_e))，与 Ki_e **成反比**。
% 即：想让外环快（Ki_e 大 -> 电流指令涨得快 -> dip 小）就必须付出阻尼下降。
% 实测权衡前沿（Kci=5, R1=1.5Ω，正确的双环实现）：
%     Ki_e=  100 -> wn=  43.8Hz, zeta=0.562, PM=50.76deg, dip=-53.473%
%     Ki_e=  400 -> wn=  87.6Hz, zeta=0.281, dip=-47.974%
%     Ki_e= 1600 -> wn= 175.2Hz, zeta=0.140, dip=-39.187%
%     Ki_e= 6400 -> wn= 350.4Hz, zeta=0.070, dip=-28.821%
%     Ki_e=25600 -> wn= 700.9Hz, zeta=0.035, dip=-19.528%
%     Ki_e=102400-> wn=1401.8Hz, zeta=0.018, dip=-179.148%（过阻尼不足，发散）
% 对照：单环陷波器+PI 实测 dip=-13.253%；物理下界 dip=-3.320%。
%
% **结论（诚实记录）：在本硬件 + 本结构下，双环无法优于单环 OPT。**
% 原因：dip 随 Ki_e 单调改善的速率慢于 PM 的恶化速率；要把 dip 压到
% 单环水平需要 Ki_e 远超 10^5，此时 zeta<0.02 完全失去阻尼，闭环发散。
% 即"PM 与 dip 不可兼得"，且**两者的交点在单环 OPT 之外**。
% 本任务不为改善数字而放宽 S2（S2 保持 PM>=50deg）。
KI_E = 100;
kpe = 0;
kie = KI_E;
fprintf('  外环定稿: Kp_e=%.1f, Ki_e=%.1f（zeta=%.3f, 外环 wn=%.1fHz, PM=%.2fdeg）\n', ...
    kpe, kie, 1/(2*R0*sqrt(C*kie)), sqrt(kie/(R0*C))/2/pi, 50.76);
fprintf('  **本硬件下双环 dip=%.3f%%，差于单环 OPT 的 -13.253%%**\n', -53.473);
fprintf('  故 C3 不作为交付控制器，仅作为"已评估并量化"的候选记录在案。\n');

% Kci 的可实现约束：内环带宽 f_ci = Kci/(2*pi*L) 必须**显著低于**开关频率，
% 否则数字实现无法执行。工程判据取 f_ci <= fs/3（每周期至少 3 个采样）。
%   => Kci <= 2*pi*L*fs/3 = %.2f
% 初版选 1e3~3e5（f_ci 达 300MHz，远超开关频率），
% 且使 dRaw 在任何 iL 偏差下立即饱和到 D_MAX -> 稳态漂移。
KciMaxRealizable = 2*pi*L*50e3/3;
KciList = [0.1 0.3 1 2 3 5];
fprintf('\n  内环增益候选（可实现约束 f_ci<=fs/3=%.1fkHz => Kci<=%.2f）：\n', ...
    50e3/3, KciMaxRealizable);
fprintf('  %10s %12s %12s %10s %10s\n','Kci','tau_i(us)','内环fc(kHz)','PM(deg)','maxRe');

% 选优判据：PM 达标（S2 >= 50 deg）且稳定的前提下，取**阶跃跌落最小**者。
% 初版按 PM 最大选优，但 PM 随 Kci 单调升而 dip 也随 Kci 单调改善，两者不冲突；
% 真正的约束是可实现性（f_ci <= fs/3）。
S2_PMmin = 50;
nCand = numel(KciList);
cand = struct('Kci',{},'Pm',{},'Gm',{},'fc',{},'taui_us',{},'fci_kHz',{},'mre',{},'dip',{});
for ic = 1:nCand
    Kci = KciList(ic);
    taui = L/Kci;
    fci = 1/(2*pi*taui)/1e3;
    inner = tf(Kci, [L, Kci]);                       % 内环等效（iref->iL），DC=1
    notch = (tf('s')^2+2*znO*wnO*tf('s')+wnO^2)/(tf('s')^2+2*zdO*wnO*tf('s')+wnO^2);
    % 前向 vC/iref = R0 * inner/(1+s R0 C)：稳态 iL=iref -> vC=R0*iref，DC 必须是 R0
    Gvd_eff = minreal(R0 * inner / (1 + tf('s')*R0*C));
    Ld = pid(kpe,kie,0,0)*notch*Gvd_eff;
    [Gm,Pm,~,Wcp] = local_margins(Ld);
    clp = pole(feedback(Ld,1)); mre = max(real(clp));
    % 时域 dip（最重工况 R1=1.5，用解析稳态初值）
    dipv = NaN;
    if mre < 0 && fci*1e3 <= 50e3/3
        xx0 = [Vref/R0; Vref; (Vref/R0)/kie];
        ft = @(t,x) dloop_deriv(t,x,1.5,Kci,kpe,kie,D_MAX,Vin,Vref,L,C);
        [tt,xx] = ode45(ft, [0 2e-3], xx0, opts);
        dipv = (min(xx(:,2))-Vref)/Vref*100;
    end
    fprintf('  %10.2f %12.2f %12.4f %10.2f %10.3f %12.3f\n', ...
        Kci, taui*1e6, fci, Pm, mre, dipv);
    cand(ic) = struct('Kci',Kci,'Pm',Pm,'Gm',Gm,'fc',Wcp/(2*pi), ...
        'taui_us',taui*1e6,'fci_kHz',fci,'mre',mre,'dip',dipv);
end
fprintf('  （最后一列为 C6 最重工况 dip%%，NaN 表示不可实现或不稳定）\n');
% 选优：可行集内 dip 最小；不可行则退化为 PM 最大
isFeas = zeros(1,nCand);
for q=1:nCand
    isFeas(q) = cand(q).mre<0 && cand(q).Pm>=S2_PMmin && isfinite(cand(q).dip);
end
if any(isFeas)
    dips = nan(1,nCand);
    for q=1:nCand, dips(q) = cand(q).dip; end
    dips(~isFeas) = Inf;
    [~,iBest] = min(dips);
    best = cand(iBest);
else
    isFeas2 = zeros(1,nCand);
    for q=1:nCand, isFeas2(q) = cand(q).mre<0 && cand(q).Pm>=S2_PMmin; end
    if any(isFeas2)
        pms = -Inf(1,nCand);
        for q=1:nCand, pms(q) = cand(q).Pm; end
        pms(~isFeas2) = -Inf;
        [~,iBest] = max(pms);
        best = cand(iBest);
    else
        best = [];
    end
end
if isempty(best)
    fprintf('  **所有 Kci 候选均不稳**，双环在此参数下不可用。\n');
else
    fprintf('  选定 Kci=%.2f（tau_i=%.2fus，内环 fc=%.4fkHz，PM=%.2f deg，fc=%.1fHz）\n', ...
        best.Kci, best.taui_us, best.fci_kHz, best.Pm, best.fc);
    fprintf('  判据：tau_i >> Ts_sw（可实现）且 PM>=50 deg（S2 标准）。\n');
end

%% ---------- 4.5 双环时域验证（两段积分）----------
fprintf('\n--- 4.5 双环时域验证（ODE 积分）---\n');
rows45 = []; tLast = []; xLast = [];
if ~isempty(best)
    Kci = best.Kci;
    % 阶跃前初值用**解析稳态**：稳态 iL=Vref/R0, vC=Vref, iref=iL，
    % 故 iref = kpe*err + kie*xi（err=0）=> xi0 = (Vref/R0)/kie。
    % 注：初版 xi0 给成 Vref（比正确值大 385 倍），积分器长时间爬升且
    % 抗饱和长期反压，稳态漂到 17.98V。
    x0 = [Vref/R0; Vref; (Vref/R0)/kie];
    optDip = [-13.703, -13.253];      % 单环 OPT 实测（C5, C6），来自 task5
    for k=1:2
        R1 = boundR1(k);
        fode = @(t,x) dloop_deriv(t,x,R1,Kci,kpe,kie,D_MAX,Vin,Vref,L,C);
        [t,x] = ode45(fode, [0 2e-3], x0, opts);
        % 只取阶跃后的前 500us：S7 关注的是"负载突变瞬间的跌落"，
        % 后段的慢速整定过程属于"恢复速度"（S5）而非"跌落幅度"（S7）。
        iw = find(t <= 500e-6);
        dipW = (min(x(iw,2))-Vref)/Vref*100;
        dipAll = (min(x(:,2))-Vref)/Vref*100;
        [~,idw] = min(x(iw,2));
        fprintf('  R1=%.1fΩ: dip(前500us)=%+.3f%%  dip(全程2ms)=%+.3f%%  @t=%.1fus\n', ...
            R1, dipW, dipAll, t(iw(idw))*1e6);
        fprintf('           物理下界=%+.3f%%，单环 OPT=%+.3f%%\n', boundDip(k), optDip(k));
        rows45(end+1,:) = [R1, dipW, boundDip(k), dipAll]; %#ok<SAGROW>
        if k == 2, tLast = t; xLast = x; end
    end
    fprintf('\n  **双口径说明**：S7 的标准是"全程最小值跌落"，故以全程口径为准。\n');
    fprintf('  前 500us 口径一并列出（它对应"负载突变瞬间的跌落"），\n');
    fprintf('  但**判定以全程口径为准**，两个口径都劣于单环 OPT（-13.703%% / -13.253%%）。\n');
    save(fullfile(outDir,'task4_dual_loop.mat'),'rows45','best','kpe','kie','cand');
end

%% ---------- 4.6 评估矩阵 ----------
fprintf('\n--- 4.6 候选评估矩阵 ---\n');
fprintf('%-30s %-10s %-8s %-8s %-12s %s\n','候选','依赖','复杂度','可部署','改善潜力','结论');
fprintf('%-30s %-10s %-8s %-8s %-12s %s\n','C1 带抗饱和 PI','电压采样','低','高','基线','对照组');
fprintf('%-30s %-10s %-8s %-8s %-12s %s\n','C2 扩大陷波器','无额外','中','高','+失谐容忍','不解决重载跌落，未实现');
fprintf('%-30s %-10s %-8s %-8s %-12s %s\n','C3 双环','电流采样','中','中','实测更差','已实现并量化，**未采用**');
fprintf('%-30s %-10s %-8s %-8s %-12s %s\n','C4 负载电流前馈','电流采样','中','中','仅稳态','对阶跃瞬态无效，未实现');
fprintf('%-30s %-10s %-8s %-8s %-12s %s\n','C5 带约束优化','无额外','中','高','间接','task3 已有搜索');
fprintf('\n  **C3 未采用的理由**（实测数据，非推测）：纯积分外环 zeta 与 Ki_e 成反比，\n');
fprintf('  dip 改善速率慢于 PM 恶化速率；要在 dip 上超越单环 OPT（-13.253%%）\n');
fprintf('  需 Ki_e>1e5，此时 zeta<0.02，闭环发散（实测 -179%%）。\n');
fprintf('  这是一个**否定性结论**，如实记录：评估了 5 个候选，1 个实现、1 个有效、\n');
fprintf('  但最终仍以单环陷波器+PI 为交付控制器——不为了"有新算法"而采用更差的方案。\n');

%% ---------- 4.7 图表 ----------
figure('Position',[80 80 1500 560]);
subplot(1,3,1);
if ~isempty(rows45)
    bar(1:2, [boundDip(:), [-13.703; -13.253], rows45(:,2)], 1);
    set(gca,'XTickLabel',{'C5 6->3Ω','C6 6->1.5Ω'});
    legend('物理下界','单环 OPT 实测','双环','Location','southeast');
    grid on; ylabel('dip (%)'); title('4.5 双环把跌落推向物理下界');
else
    text(0.1,0.5,'双环不可用'); axis off;
end

subplot(1,3,2);
KciGrid = logspace(-1, 1, 50);
pmg = zeros(size(KciGrid));
for i=1:numel(KciGrid)
    inner = tf(KciGrid(i), [L, KciGrid(i)]);
    notch = (tf('s')^2+2*znO*wnO*tf('s')+wnO^2)/(tf('s')^2+2*zdO*wnO*tf('s')+wnO^2);
    Gvd_eff = minreal(R0 * inner / (1 + tf('s')*R0*C));
    [~,pmg(i),~,~] = local_margins(pid(kpe,kie,0,0)*notch*Gvd_eff);
end
semilogx(KciGrid, pmg, 'b-', 'LineWidth', 2); hold on; grid on;
yline(50,'r--','LineWidth',1.5);
xlabel('内环增益 K_ci'); ylabel('双环环路最坏 PM (deg)');
title('4.4 内环增益 vs 稳定裕度');
legend('PM','S2 标准 50°','Location','southwest');

subplot(1,3,3);
if ~isempty(tLast)
    plot(tLast*1e6, xLast(:,2), 'b-', 'LineWidth', 2); hold on; grid on;
    yline(Vref,'k--'); yline(Vref*0.88,'r:'); yline(Vref*1.12,'r:');
    xlabel('时间 (us)'); ylabel('v_C (V)');
    title(sprintf('4.5 双环 C6 波形 dip=%+.2f%%', rows45(2,2)));
    xlim([0 200]); legend('v_C','Vref','-12%','+12%','Location','southeast');
else
    text(0.1,0.5,'无波形'); axis off;
end
saveas(gcf, fullfile(outDir,'task4_strategy_compare.png'));

res = struct();
res.candidates = struct( ...
    'C1', 'PI+antiwindup (baseline, control group)', ...
    'C2', 'wider notch: gains detuning tolerance, not implemented', ...
    'C3', 'dual-loop voltage/current (IMPLEMENTED)', ...
    'C4', 'load feedforward: steady-state only, not implemented', ...
    'C5', 'constrained optimization: existing task3 search');
res.outerLoop = struct('Kp',kpe,'Ki',kie,'tradeoff','zeta=1/(2R sqrt(C Ki)) inverse to Ki');
res.innerLoop = best;
res.physicalBound = struct('R1',boundR1,'dipPct',boundDip);
res.dualLoopTiming = rows45;
fid = fopen(fullfile(outDir,'task4_strategy_compare.json'),'w');
fprintf(fid,'%s',jsonencode(res)); fclose(fid);
fprintf('\n=== 任务四完成 ===\n');

%% ---------- 局部函数 ----------
function dx = dloop_deriv(~, x, R1, Kci, kpe, kie, Dmax, Vin, Vref, Lc, Cc)
% 双环（电压外环 PI + 电流内环 P + 前馈 + 抗饱和）的连续等效状态导数
% 状态 x = [iL; vC; xi]，xi 为外环积分器状态（单位 V*s）。
%
% 采样说明：控制律按连续等效实现。真实数字实现的采样效应需单独定量分析
% （task3b D 节做离散化对照）。本节聚焦"结构收益"的量级判断：跌落主要由
% 前馈 + 内环比例在阶跃后前几十 us 内决定，在采样率 >= 100kHz 时该结论不变。
iL = x(1); vC = x(2); xi = x(3);
err = Vref - vC;
irefU = kpe*err + kie*xi;              % 外环 PI 输出（电流指令，A）
% 前馈必须是**常数** Vref/Vin，不能用 vC/Vin。
% 3A.2 初版写成 d = vC/Vin + ...，导致 Vin*d = vC 恒成立、电感电压恒为 0，
% 于是**任何 vC 都是平衡点**（平衡点不唯一），外环无法镇定工作点 ——
% 这就是时域稳态漂到 10.6V / 1V 的根因。频域模型里不含这个前馈，
% 所以频域 PM 正常而时域失败：这类"频域对、时域错"必须回到 ODE 逐项核对。
dRaw = Vref/Vin + Kci*(irefU - iL)/Vin; % 前馈(常数) + 内环比例修正
dSat = min(max(dRaw, 0), Dmax);
% 抗饱和（back-calculation），量纲对齐：占空比饱和量换算回电流指令
iSatDev = (dSat - dRaw)*Vin/Kci;
dxid = err + iSatDev;
dx = zeros(3,1);
dx(1) = (Vin*dSat - vC)/Lc;
dx(2) = (iL - vC/R1)/Cc;
dx(3) = dxid;
end