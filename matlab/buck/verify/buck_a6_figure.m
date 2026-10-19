function buck_a6_figure(outDir)
%BUCK_A6_FIGURE  Two results that carry the round: Floquet margins and the L trade-off.
% Reads a6_stability.json and a6_inductance.json -- no re-simulation, so the figure
% cannot disagree with the tables.
if nargin < 1 || isempty(outDir), outDir = getenv('BUCK_OUT'); end
outDir = strrep(outDir,'/',filesep);

S = jsondecode(fileread(fullfile(outDir,'a6_stability.json')));
D = jsondecode(fileread(fullfile(outDir,'a6_inductance.json')));

%% ---- panel 1: distance to the unit circle, all 14 orbits ----
lbl = cell(1, numel(S.records));
mrg = zeros(1, numel(S.records));
isPost = false(1, numel(S.records));
for k = 1:numel(S.records)
    lbl{k} = sprintf('%s %s', S.records(k).cond, S.records(k).phase);
    mrg(k) = S.records(k).margin;
    isPost(k) = strcmp(S.records(k).phase,'post');
end

fig = figure('Position',[60 60 1220 760],'Color','w');

subplot(2,2,1); hold on; grid on;
b1 = bar(find(~isPost), mrg(~isPost), 0.7, 'FaceColor',[0.16 0.42 0.72],'EdgeColor','k');
b2 = bar(find(isPost),  mrg(isPost),  0.7, 'FaceColor',[0.85 0.40 0.15],'EdgeColor','k');
yline(0,'r-','linewidth',1.6);
set(gca,'XTick',1:numel(mrg),'XTickLabel',lbl,'FontSize',8);
xtickangle(45);
ylabel('1 - max|\lambda|   (margin to unit circle)');
title('Floquet margin per orbit (bar at 0 = instability)');
legend([b1 b2],{'pre-step orbit','post-step orbit'},'Location','southwest');

%% ---- panel 2: ripple ratio and CCM boundary vs L ----
LK   = [D.summary.L]*1e6;
rip  = [D.summary.rippleWorstPct];
icr  = [D.summary.icritA];
subplot(2,2,2); hold on; grid on;
yyaxis left;
plot(LK, rip, 'o-','LineWidth',1.8,'Color',[0.16 0.42 0.72],'MarkerFaceColor',[0.16 0.42 0.72]);
ylabel('worst ripple ratio (%)');
yyaxis right;
plot(LK, icr, 's--','LineWidth',1.6,'Color',[0.85 0.40 0.15],'MarkerFaceColor',[0.85 0.40 0.15]);
ylabel('CCM/DCM boundary I_{crit} (A)');
xlabel('L (\muH)');
title('Rising L: ripple falls, DCM margin widens');
set(gca,'XTick',LK);

%% ---- panel 3: dip vs L (the cost) ----
dip = [D.summary.dipWorst];
subplot(2,2,3); hold on; grid on;
plot(LK, -dip, 'o-','LineWidth',1.8,'Color',[0.80 0.25 0.20],'MarkerFaceColor',[0.80 0.25 0.20]);
yline(12,'r--','S7 limit 12 %','LineWidth',1.4);
xlabel('L (\muH)'); ylabel('|voltage dip| (%)');
title('...but the current slew collapses: dip gets worse monotonically');
set(gca,'XTick',LK); ylim([0 13]);

%% ---- panel 4: S5 and S4 vs L ----
s5 = [D.summary.s5Worst];
sse = [D.summary.ssErrWorst];
subplot(2,2,4); hold on; grid on;
yyaxis left;
plot(LK, s5, 'o-','LineWidth',1.8,'Color',[0.15 0.55 0.30],'MarkerFaceColor',[0.15 0.55 0.30]);
ylabel('S5 worst (ms)');
yyaxis right;
plot(LK, sse, 'd--','LineWidth',1.6,'Color',[0.35 0.35 0.70],'MarkerFaceColor',[0.35 0.35 0.70]);
ylabel('worst |ssErr| (%)');
yline(0.1,'r:','S4 limit 0.1 %','LineWidth',1.3);
xlabel('L (\muH)');
title('S5 is non-monotonic (best at 220); S4 only improves');
set(gca,'XTick',LK);

sgtitle('Phase 3A.6  -  DUAL-B: independent stability margins and the inductance trade-off', ...
    'FontSize',12,'FontWeight','bold');

print(fig, fullfile(outDir,'a6_summary.png'),'-dpng','-r130');
close(fig);
fprintf('saved a6_summary.png\n');
end
