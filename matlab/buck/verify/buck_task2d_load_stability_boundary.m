%% 任务二补充（定稿）：轻载方向的失稳边界 —— 负载电阻上限 R_crit
%
% 任务二/二c 刻画了"重参数方向"（Kp/Ki 增大）的失稳边界。本脚本刻画工程上
% 更常见的方向：**负载变轻（R 增大）**。谐振峰 |Gvd(f_n)| = Vin*R/(L*wn)
% 随 R 线性增长（Q = R*sqrt(C/L) 亦随 R 线性增长），而陷波深度 zn/zd 固定 ——
% 轻载是把环路推过失稳边界的自然路径。
%
% 【结论先行】
%   BASE 纯积分：R_crit = 1/(Ki*Vin*C) = 11.98 ohm（精确闭式，数值互证 3e-5）。
%                 额定负载 6ohm 的 2 倍即半载 —— 原始设计轻于半载即失稳。
%   OPT 陷波器+PI：**无有限 R_crit，对所有 R 线性稳定**（扫描至 1e7 ohm，
%                 maxRe 恒 ~ -82.6；R->inf 极限特征多项式与 R 无关且根全在 LHP）。
%                 成对 -180 deg 穿越现象见下。
%
% 【闭式推导 1 —— 纯积分回路（精确，非近似）】
%   phase(L(j*wn)) = -90 deg(积分器) + (-90 deg)(LC 二阶在谐振处) = -180 deg
%   【谐振频率 wn=1/sqrt(LC) 与 R 无关；二阶系统在谐振处相位恰为 -90 deg，
%     与阻尼无关 —— 故该相位条件对任意 R 精确成立】
%   |L(j*wn)| = Ki*R*Vin*C
%   => GM=0 当且仅当  R_crit = 1/(Ki*Vin*C)   【精确闭式】
%
% 【闭式推导 2 —— 陷波器+PI：为什么没有有限 R_crit】
%   (a) |L(j*wn)| = Kp*(zn/zd)*Vin*R/(L*wn)（Ki/wn 可忽略）：谐振峰触 0dB 的
%       负载 R_peak = L*wn*zd/(zn*Kp*Vin) = 10.75 ohm。但这只是"峰触 0dB"，
%       不是稳定边界 —— wn 处总相位仅 -91.3 deg（PI -1.3 + N 0 + Gvd -90），
%       临界点 -1 在 Nyquist 图上远离该处。
%   (b) 随 R 增大，Gvd 相位过渡带变陡，总相位在 wn 上方一小段跌到 -180 deg
%       以下（成对穿越），但陷波器在 wn 以上的相位超前（峰值 +65 deg）把总相位
%       托回 -180 deg 以上，HF 处从上方趋近 -180 deg。两个 -180 deg 穿越
%       （|L| 大者先、小者后）构成一段贴近负实轴的细长"sliver"，临界点 -1
%       位于两个穿越点的**右侧**，不在 sliver 内 -> 环绕数为 0 -> 稳定。
%       【此时 GM 单点指标失效：它报 GM<0，但闭环稳定。判定必须以 maxRe/
%        Nyquist 环绕数为准。】
%   (c) R->inf 时被控对象阻尼项 (L/R)s 消失，闭环特征多项式与 R 无关，
%       其根即大 R 极限极点（脚本第 2(c) 节数值给出，全部在 LHP）
%       -> 对所有 R 稳定（有限 R 的修正量由扫描证明很小）。
%
% 输出: task2d_load_stability_boundary.mat / .png
clear; close all;
outDir = getenv('BUCK_OUT'); if isempty(outDir), outDir = fullfile(pwd,'buck'); end
outDir = strrep(outDir,'/',filesep); if ~exist(outDir,'dir'), mkdir(outDir); end
addpath(fullfile(fileparts(fileparts(mfilename('fullpath')))));

Vin=48; L=150e-6; C=220e-6; R=6; Vout=12;
wn = 1/sqrt(L*C); fn = wn/(2*pi);
Ki_base = 7.902901;
% OPT 定稿参数（任务三；此处为可复现硬编码，与 task3_best_controller.mat 一致）
Kp_o=0.04; Ki_o=5; zn_o=0.02; zd_o=0.5;

fprintf('================ 任务二补充：轻载失稳边界 R_crit ================\n');
fprintf('f_n=%.2f Hz, wn=%.1f rad/s, Q(R=6)=%.2f\n', fn, wn, R*sqrt(C/L));

gvdOf = @(Rv) minreal(tf(ss([0,-1/L; 1/C,-1/(Rv*C)], [Vin/L;0], [0 1], 0)));
s = tf('s');
notch_o = (s^2+2*zn_o*wn*s+wn^2)/(s^2+2*zd_o*wn*s+wn^2);
Lbase = @(Rv) pid(0,Ki_base,0,0)*gvdOf(Rv);
Lopt  = @(Rv) pid(Kp_o,Ki_o,0,0)*notch_o*gvdOf(Rv);

% 密网格（wn 附近加密：轻载时 -180 deg 穿越点极度靠近 wn，默认网格会漏检）
wgrid = unique([logspace(-2, 8, 200001), logspace(log10(wn)-2, log10(wn)+1, 50001)]);
marginsOf = @(Lf,Rv) local_margins(Lf(Rv), wgrid);

%% ---------- 1) 纯积分回路：闭式 R_crit ----------
Ki_crit_R = 1/(Ki_base*Vin*C);     % = 1/(Ki*Vin*C)，精确
fprintf('\n--- 纯积分回路（Ki=%.4f）---\n', Ki_base);
fprintf('闭式 R_crit = 1/(Ki*Vin*C) = %.4f ohm（额定 6ohm 的 %.2f 倍 = 半载）\n', ...
    Ki_crit_R, Ki_crit_R/6);
phAtWn = rad2deg(angle(freqresp(Lbase(6),wn)));
fprintf('验证: phase(L(j*wn)) = %.6f deg（应为 -180，任意 R 精确成立）\n', phAtWn);

fprintf('\n%8s %9s %9s %10s %10s %11s %6s\n', ...
    'R(ohm)','PM(deg)','GM(dB)','fc(Hz)','fc/f_n','maxRe极点','稳定');
Rlist_b = [3 6 9 10 11 11.9 12 12.1 13 16 20];
rowsB = [];
for Rv = Rlist_b
    [Gm_dB,Pm,~,Wcp] = marginsOf(Lbase,Rv);
    clp = pole(feedback(Lbase(Rv),1)); mre = max(real(clp));
    fc = Wcp/(2*pi);
    fprintf('%8.2f %9.2f %9s %10.2f %10.3f %11.2f %6d\n', Rv, Pm, ...
        merge_s(isinf(Gm_dB),'Inf',sprintf('%.2f',Gm_dB)), fc, fc/fn, mre, mre<0);
    rowsB(end+1,:) = [Rv Pm Gm_dB fc mre]; %#ok<SAGROW>
end

a=10; b=14;
fa = marginsOf(Lbase,a); fb = marginsOf(Lbase,b);
fprintf('\nGM(%.0f)=%+.3f dB, GM(%.0f)=%+.3f dB -> 二分 GM=0\n', a,fa(1),b,fb(1));
for it=1:45
    m=0.5*(a+b);
    if marginsOf(Lbase,m) > 0, a=m; else, b=m; end
end
Rnum_b = 0.5*(a+b);
fprintf('数值 R_crit(BASE) = %.4f ohm（闭式 %.4f，相对误差 %.2e）\n', ...
    Rnum_b, Ki_crit_R, abs(Rnum_b-Ki_crit_R)/Ki_crit_R);
fprintf('注：R=12ohm 恰在边界外 0.017ohm —— PM 89.7->8.98 deg、maxRe 转正。\n');
fprintf('    任务五 C4 工况（R=12）对 BASE 的失败由此精确解释，不是测试 bug。\n');

%% ---------- 2) 陷波器+PI 回路：R_peak 与"无有限 R_crit"证明 ----------
R_peak = L*wn*zd_o/(zn_o*Kp_o*Vin);
fprintf('\n--- 陷波器+PI 回路（Kp=%.2f Ki=%.1f zn=%.2f zd=%.1f）---\n', Kp_o,Ki_o,zn_o,zd_o);
fprintf('R_peak（谐振峰触 0dB）= L*wn*zd/(zn*Kp*Vin) = %.3f ohm\n', R_peak);
fprintf('  注：|L(j*wn)| = %.6f*R；wn 处总相位 %.2f deg（远未到 -180）\n', ...
    abs(squeeze(freqresp(Lopt(1),wn))), rad2deg(angle(freqresp(Lopt(1),wn))));

fprintf('\n(a) R 扫描（稳定性以 maxRe 为准）\n');
fprintf('%9s %9s %9s %10s %11s %6s\n', ...
    'R(ohm)','PM(deg)','GM(dB)','fc(Hz)','maxRe极点','稳定');
Rlist_o = [3 6 10 12 20 50 100 1000 1e4 1e5 3e5 1e6 1e7];
rowsO = [];
for Rv = Rlist_o
    [Gm_dB,Pm,~,Wcp] = marginsOf(Lopt,Rv);
    clp = pole(feedback(Lopt(Rv),1)); mre = max(real(clp));
    fc = Wcp/(2*pi);
    fprintf('%9.0f %9.2f %9s %10.2f %11.2f %6d\n', Rv, Pm, ...
        merge_s(isinf(Gm_dB),'Inf',sprintf('%.2f',Gm_dB)), fc, mre, mre<0);
    rowsO(end+1,:) = [Rv Pm Gm_dB fc mre]; %#ok<SAGROW>
end

fprintf('\n(b) GM<0 但 maxRe<0 的解释：成对 -180 deg 穿越（GM 指标失效区）\n');
[Gm3,~,~,~,xov3] = marginsOf(Lopt,3e5);
fprintf('R=3e5 ohm: GM=%+.2f dB，但全部相位穿越如下：\n', Gm3);
fprintf('  %14s %12s %10s\n', 'f(Hz)','|L|(dB)','穿越方向');
phCross = xov3(strcmp({xov3.kind},'phase'));
for j=1:numel(phCross)
    fprintf('  %14.2f %12.2f %10s\n', phCross(j).freq/(2*pi), ...
        phCross(j).mag_dB, '见相位序列');
end
% 直接给出穿越点两侧的相位，展示"先跌穿、后回升"的成对结构
w1 = logspace(log10(wn)-0.001, log10(wn)+0.001, 21);
phs = rad2deg(angle(freqresp(Lopt(3e5), w1)));
fprintf('  wn 附近相位序列（展示成对穿越：跌穿 -180 后被陷波器超前托回）:\n');
for j=1:numel(w1)
    if abs(w1(j)/wn-1) < 3e-4 || mod(j,4)==1
        fprintf('    f=%10.2f Hz  phase=%+9.3f deg\n', w1(j)/(2*pi), phs(j));
    end
end

fprintf('\n(c) R->inf 极限：特征多项式与 R 无关，根即大 R 极限极点\n');
gvdLim = tf(ss([0,-1/L; 1/C,0], [Vin/L;0], [0 1], 0));   % (L/R)s 项消失
Llim = pid(Kp_o,Ki_o,0,0)*notch_o*gvdLim;
clpLim = pole(feedback(Llim,1));
fprintf('  极限闭环极点:\n');
for i=1:numel(clpLim)
    wn_i = abs(clpLim(i));
    fprintf('    %+10.2f %+10.1f   f=%8.1f Hz  zeta=%.4f\n', ...
        real(clpLim(i)), imag(clpLim(i)), wn_i/2/pi, -real(clpLim(i))/wn_i);
end
fprintf('  maxRe(极限) = %.2f < 0 -> 大 R 极限稳定；结合 (a) 扫描（有限 R 修正小）\n', ...
    max(real(clpLim)));
fprintf('  => 结论：OPT 回路无有限 R_crit，对任意负载线性稳定。\n');

%% ---------- 3) 时域抽查（Simulink，与线性结论互相印证）----------
fprintf('\n--- 时域抽查（无负载阶跃，起步激励；tStop=60ms）---\n');
tdCases = [
    struct('id','BASE_R10','R',10,'Kp',0,     'Ki',Ki_base,'notchEnable',false, ...
           'notchWn',NaN,'notchZn',NaN,'notchZd',NaN, ...
           'expect','R<R_crit 应稳定')
    struct('id','BASE_R13','R',13,'Kp',0,     'Ki',Ki_base,'notchEnable',false, ...
           'notchWn',NaN,'notchZn',NaN,'notchZd',NaN, ...
           'expect','R>R_crit 应振荡增长')
    struct('id','OPT_R12', 'R',12,'Kp',Kp_o,  'Ki',Ki_o,   'notchEnable',true, ...
           'notchWn',wn,'notchZn',zn_o,'notchZd',zd_o,'expect','C4 轻载应稳定')
    struct('id','OPT_R1k', 'R',1000,'Kp',Kp_o,'Ki',Ki_o,   'notchEnable',true, ...
           'notchWn',wn,'notchZn',zn_o,'notchZd',zd_o,'expect','极轻载仍应稳定')
];
tdRes = [];
for i=1:size(tdCases,1)
    tc = tdCases(i);
    cfg = struct('Kp',tc.Kp,'Ki',tc.Ki,'R',tc.R,'Vin',Vin,'L',L,'C',C, ...
        'Vref',Vout,'tStop',0.06,'maxStep',1e-6, ...
        'modelName', sprintf('bnd_%s', tc.id), 'saveModel', false);
    if tc.notchEnable
        cfg.notchEnable = true; cfg.notchWn = tc.notchWn;
        cfg.notchZn = tc.notchZn; cfg.notchZd = tc.notchZd;
    end
    r = build_buck_closed_loop_generic(outDir, cfg);
    t=r.t; vC=r.vC;
    e1 = max(vC(t>=0.010&t<0.025)) - min(vC(t>=0.010&t<0.025));
    e2 = max(vC(t>=0.045&t<0.060)) - min(vC(t>=0.045&t<0.060));
    ratio = e2/max(e1,eps);
    fprintf('%-10s R=%7.1f  末值=%9.4f  包络(10-25ms)=%7.4f  (45-60ms)=%7.4f  增长比=%8.3f  [%s]\n', ...
        tc.id, tc.R, vC(end), e1, e2, ratio, tc.expect);
    tdRes(i).id = tc.id; tdRes(i).R = tc.R; tdRes(i).vEnd = vC(end);
    tdRes(i).env1 = e1; tdRes(i).env2 = e2; tdRes(i).growth = ratio;
    tdRes(i).t = t; tdRes(i).vC = vC;
end

%% ---------- 4) 图 ----------
fig = figure('Visible','off','Position',[100 100 1400 900]);

subplot(2,3,1); hold on; grid on;
semilogx(rowsB(:,1), rowsB(:,3), 'bs-','LineWidth',1.5);
semilogx(rowsO(:,1), rowsO(:,3), 'mo-','LineWidth',1.5);
xline(Ki_crit_R,'b--',sprintf('BASE 闭式 %.2f',Ki_crit_R));
xline(R_peak,'m:',sprintf('R_{peak} %.2f',R_peak));
yline(0,'r--','GM=0');
xlabel('R (ohm)'); ylabel('GM (dB)'); title('GM vs 负载电阻');
legend('纯积分','陷波器+PI','Location','best');
annotation('textarrow',[0.62 0.62],[0.78 0.62], ...
    'String','OPT 的 GM<0 是成对穿越假象（maxRe 仍<0）','FontSize',8);

subplot(2,3,2); hold on; grid on;
semilogx(rowsB(:,1), rowsB(:,2), 'bs-','LineWidth',1.5);
semilogx(rowsO(:,1), rowsO(:,2), 'mo-','LineWidth',1.5);
yline(0,'r--','PM=0'); yline(50,'g--','PM=50');
xline(Ki_crit_R,'b--'); xline(R_peak,'m:');
set(gca,'YScale','linear'); ylim([-5 100]);
xlabel('R (ohm)'); ylabel('最坏 PM (deg)'); title('PM vs 负载电阻');

subplot(2,3,3); hold on; grid on;
semilogx(rowsB(:,1), rowsB(:,5), 'bs-','LineWidth',1.5);
semilogx(rowsO(:,1), rowsO(:,5), 'mo-','LineWidth',1.5);
yline(0,'r--','maxRe=0');
xline(Ki_crit_R,'b--'); xline(R_peak,'m:');
xlabel('R (ohm)'); ylabel('闭环极点最大实部'); title('maxRe vs R（真正的稳定性判据）');

subplot(2,3,4); hold on; grid on;
plot(tdRes(1).t*1e3, tdRes(1).vC, 'b-','LineWidth',1.2); hold on;
plot(tdRes(2).t*1e3, tdRes(2).vC, 'r-','LineWidth',1.2);
yline(12,'k--'); grid on;
xlabel('t (ms)'); ylabel('v_C (V)');
title(sprintf('纯积分: R=10(稳定) vs R=13(增长), R_{crit}=%.2f', Ki_crit_R));
legend('R=10 ohm','R=13 ohm','Location','best');

subplot(2,3,5); hold on; grid on;
plot(tdRes(3).t*1e3, tdRes(3).vC, 'm-','LineWidth',1.2); hold on;
plot(tdRes(4).t*1e3, tdRes(4).vC, 'c-','LineWidth',1.2);
yline(12,'k--'); grid on;
xlabel('t (ms)'); ylabel('v_C (V)');
title('陷波器+PI: R=12(C4) vs R=1000 均稳定');
legend('R=12 ohm','R=1000 ohm','Location','best');

subplot(2,3,6); hold on; grid on;
for Rv = [6 12 30]
    wv = logspace(log10(wn)-1, log10(wn)+1, 4001);
    semilogx(wv/(2*pi), 20*log10(abs(squeeze(freqresp(Lopt(Rv),wv)))), ...
        'LineWidth',1.5, 'DisplayName', sprintf('R=%g',Rv));
end
xline(fn,'r--','f_n'); yline(0,'k:','0 dB');
xlabel('f (Hz)'); ylabel('|L| (dB)'); title('OPT 环路谐振区增益 vs R（峰随 R 线性增长）');
legend('Location','best'); grid on;

sgtitle('轻载失稳边界：纯积分 R_{crit}=1/(K_i V_{in} C) 精确；陷波器回路无有限 R_{crit}');
saveas(fig, fullfile(outDir,'task2d_load_stability_boundary.png')); close(fig);

save(fullfile(outDir,'task2d_load_stability_boundary.mat'), ...
    'rowsB','rowsO','Ki_crit_R','Rnum_b','R_peak','tdRes','clpLim', ...
    'wn','fn','Vin','L','C','R','Vout','Ki_base','Kp_o','Ki_o','zn_o','zd_o');
fprintf('\n已保存 task2d_load_stability_boundary.mat / .png\n');

function t = merge_s(c,a,b)
if c, t = a; else, t = b; end
end
