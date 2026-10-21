function buck_a5_figure(outDir)
%BUCK_A5_FIGURE  Level B/C/D comparison, drawn from the saved JSON reports.
% No re-simulation: the numbers are exactly the ones in a5_task1_digital.json,
% a5_levelC.json and a5_levelD.json, so the figure cannot disagree with the tables.
if nargin < 1 || isempty(outDir), outDir = getenv('BUCK_OUT'); end
outDir = strrep(outDir,'/',filesep);
conds = {'C1','C2','C3','C4','C5','C6','C7'};

B = jsondecode(fileread(fullfile(outDir,'a5_task1_digital.json')));
C = jsondecode(fileread(fullfile(outDir,'a5_levelC.json')));
D = jsondecode(fileread(fullfile(outDir,'a5_levelD.json')));

s5 = nan(3,7); dp = nan(3,7);
for i = 1:7
    for r = 1:numel(B.results)
        if strcmp(B.results(r).cond,conds{i}) && B.results(r).delay == 1
            s5(1,i) = B.results(r).s5; dp(1,i) = B.results(r).dip;
        end
    end
    for r = 1:numel(C.records)
        if strcmp(C.records(r).cond,conds{i}) && C.records(r).rep == 1
            s5(2,i) = C.records(r).settleMs; dp(2,i) = C.records(r).dipPct;
        end
    end
    for r = 1:numel(D.records)
        if strcmp(D.records(r).cond,conds{i}) && D.records(r).delay == 1 && D.records(r).rep == 1
            s5(3,i) = D.records(r).settleMs; dp(3,i) = D.records(r).dipPct;
        end
    end
end

col = [0.16 0.42 0.72; 0.85 0.40 0.15; 0.15 0.55 0.30];
lbl = {'B  discrete average','C  + non-ideal sensor','D  switching level'};
fig = figure('Position',[80 80 1180 760],'Color','w');

subplot(2,1,1); hold on; grid on;
h = gobjects(1,3);
for q = 1:3
    h(q) = bar((1:7)+(q-2)*0.26, s5(q,:), 0.24, 'FaceColor', col(q,:), 'EdgeColor','k');
end
yline(1.0,'r--','S5 limit 1 ms','LineWidth',1.6,'LabelHorizontalAlignment','left');
set(gca,'XTick',1:7,'XTickLabel',conds,'FontSize',10);
ylabel('S5 settling time (ms)');
title('S5 by verification level (log scale: 0 is plotted as a floor)');
set(gca,'YScale','log'); ylim([0.02 2]);
legend(h,lbl,'Location','northwest');

subplot(2,1,2); hold on; grid on;
for q = 1:3
    bar((1:7)+(q-2)*0.26, -dp(q,:), 0.24, 'FaceColor', col(q,:), 'EdgeColor','k');
end
yline(12,'r--','S7 limit 12%','LineWidth',1.6,'LabelHorizontalAlignment','left');
set(gca,'XTick',1:7,'XTickLabel',conds,'FontSize',10);
ylabel('|voltage dip| (%)');
title('Load-step dip by verification level (C5/C6 are the 3->1.5 ohm step)');

sgtitle('Phase 3A.5 - DUAL-B: same controller, three verification levels (1 switching period of delay)', ...
    'FontSize',12,'FontWeight','bold');
print(fig, fullfile(outDir,'a5_levels_compare.png'),'-dpng','-r130');
close(fig);
fprintf('saved a5_levels_compare.png\n');
