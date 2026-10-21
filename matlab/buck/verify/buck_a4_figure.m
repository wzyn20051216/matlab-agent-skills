%% Phase 3A.4: figure for the report -- load-step response of all four controllers
% Reads the stored waveforms from a4_acceptance.mat (no re-simulation).
clear; close all;
outDir = 'E:/desktop/MATLAB/artifacts/validation/buck';
D = load(fullfile(outDir,'a4_acceptance.mat'));
recs = D.recs;
ids = {'BASE','OPT','DUALA','DUALB'};
lbl = {'BASE (pure I)','OPT (notch+PI)','DUAL-A (dual loop)','DUAL-B (dual + iLoad FF)'};
col = [0.55 0.55 0.55; 0.16 0.42 0.72; 0.85 0.45 0.15; 0.10 0.60 0.30];

fig = figure('Position',[80 80 1180 780],'Color','w');
cases = {'C1','C5'};
for ic = 1:2
    ax = subplot(2,2,ic*2-1); hold(ax,'on'); grid(ax,'on'); h = gobjects(1,4);
    for q = 1:4
        idx = find(strcmp({recs.cond},cases{ic}) & strcmp({recs.ctrl},ids{q}),1);
        t = recs(idx).t; v = recs(idx).vC;
        m = t >= 0.060 & t <= 0.060 + 0.012;
        h(q) = plot(ax, (t(m)-0.060)*1e3, v(m), 'Color', col(q,:), 'LineWidth', 1.6);
    end
    plot(ax,[0 12],[12 12],'k--'); plot(ax,[0 12],[12.12 12.12],'r:');
    plot(ax,[0 12],[11.88 11.88],'r:');
    xlabel('t after load step (ms)'); ylabel('v_C (V)');
    title(sprintf('%s : 4 controllers overlaid (red dotted = +-1%%)', cases{ic}));
    yl = ylim(ax);
    legend(h, lbl, 'Location','southeast'); ylim(ax,[min(10.4,yl(1)) 12.6]);
end
% second column: zoom on the settling window
for ic = 1:2
    ax2 = subplot(2,2,ic*2); hold(ax2,'on'); grid(ax2,'on');
    for q = 1:4
        idx = find(strcmp({recs.cond},cases{ic}) & strcmp({recs.ctrl},ids{q}),1);
        t = recs(idx).t; v = recs(idx).vC;
        m = t >= 0.060 & t <= 0.060 + 0.003;
        plot(ax2, (t(m)-0.060)*1e3, v(m), 'Color', col(q,:), 'LineWidth', 1.6);
        sm = recs(idx).settleMs;
        if isfinite(sm)
            plot(ax2, max(sm,0), 12, 'o', 'Color', col(q,:), ...
                 'MarkerFaceColor', col(q,:), 'MarkerSize', 8);
        end
    end
    plot(ax2,[0 3],[12 12],'k--'); plot(ax2,[0 3],[12.12 12.12],'r:');
    plot(ax2,[0 3],[11.88 11.88],'r:');
    xlabel('t after load step (ms)'); ylabel('v_C (V)');
    title(sprintf('%s : first 3 ms, dot = S5 settle (strict, holds +-1%%)', cases{ic}));
    xlim(ax2,[0 3]); ylim(ax2,[10.6 12.5]);
end
sgtitle('Phase 3A.4  load step 6\Omega\rightarrow3\Omega (C1) and 3\Omega\rightarrow1.5\Omega (C5)','FontWeight','bold');
print(fig, fullfile(outDir,'a4_dual_vs_single.png'), '-dpng','-r140');
close(fig);
fprintf('saved a4_dual_vs_single.png\n');

% numeric summary printed for the report
fprintf('\n%-6s %-6s %10s %10s %10s\n','cond','ctrl','dip%','S5ms','dutyMax');
for ic = 1:2
  for q = 1:4
    idx = find(strcmp({recs.cond},cases{ic}) & strcmp({recs.ctrl},ids{q}),1);
    fprintf('%-6s %-6s %10.3f %10.4f %10.3f\n', cases{ic}, ids{q}, ...
      recs(idx).dipPct, recs(idx).settleMs, recs(idx).dutyMax);
  end
end
