%% Phase 3A.4: select the final dual-loop parameters from the Task 3+4 search
%
% Selection rules
%   R1 hard feasibility (non-negotiable, from the original standards):
%      PM(discrete, 1 Ts) >= 50, GM >= 6 dB, S5 <= 1 ms, |dip| <= 12%,
%      no duty saturation in the linear model, inner-loop z = 1-Kci*Ts/L >= 0,
%      closed loop stable.
%   R2 ENGINEERING MARGIN (added before the acceptance run, and applied to both
%      architectures identically): PM_d >= 51 deg, dutyMax <= 0.80, z_inner >= 0.15.
%      Rationale: the first grid pass returned a CAND-A point sitting at
%      PM_d=50.24, S5=0.992 and dip=-11.765 -- i.e. three criteria each within
%      1 % of their limit. Such a point is arithmetically feasible but not
%      deliverable, and it is exactly the kind of result that evaporates in a
%      real simulation. Shipping a controller on 0.24 deg of margin would be
%      self-deception, so a margin tier is imposed. It makes the candidates
%      HARDER to pass, never easier, and no standard is relaxed.
%   R3 within the R2 set minimise the worst-case S5 over the 7 conditions.
%   R4 if an architecture has no R2 point, fall back to its best R1 point and
%      label it KNIFE-EDGE -- that fact is itself a result.
%
% Output: a4_dualsel.mat (A and B parameter sets), a4_dualsel.json

clear; close all;
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here,'..'));
outDir = getenv('BUCK_OUT');
if isempty(outDir), outDir = fullfile(here,'..','..','artifacts','validation','buck'); end
outDir = strrep(outDir,'/',filesep);

D = load(fullfile(outDir,'a4_task34_design.mat'));
P = D.P; condTbl = D.condTbl; condIds = D.condIds;

fprintf('=== 3A.4 final selection ===\n');
S = struct();
for k = 1:2
    if k == 1, R = D.RA; nm = 'A'; ff = 0;
    else,      R = D.RB; nm = 'B'; ff = 1; end
    fprintf('\n--- CAND-%s (ff=%d), %d points evaluated ---\n', nm, ff, numel(R));

    % tier 1: feasible with engineering margin (R1 + R2)
    okR = [R.feas] & [R.pmd] >= 51 & [R.dutyMax] <= 0.80 & [R.zInner] >= 0.15;
    % tier 2: feasible but on the edge (R1 only)
    ok = [R.feas];
    % tier 3: meets PM/GM/saturation/sampling but misses S5 or dip
    ok2 = [R.pmd] >= 50 & [R.gmd] >= 6 & ~[R.dut] & [R.zInner] >= 0 & ~isnan([R.s5]);

    if any(okR)
        cand = R(okR);
        [~, i0] = min([cand.s5]);
        best = cand(i0);
        tier = 'FEASIBLE with margin';
    elseif any(ok)
        cand = R(ok);
        [~, i0] = min([cand.s5]);
        best = cand(i0);
        tier = 'KNIFE-EDGE (feasible only without margin)';
    elseif any(ok2)
        cand = R(ok2);
        [~, i0] = min([cand.s5]);
        best = cand(i0);
        tier = 'BEST-EFFORT (S5 or dip not met)';
    else
        error('CAND-%s: nothing meets even PM/GM/saturation', nm);
    end
    fprintf('  selected: %s\n', tier);
    fprintf('  Kci=%.3f  Kp_e=%.4f  Ki_e=%.1f\n', best.Kci, best.Kpe, best.Kie);
    fprintf('  PM_c=%.2f  PM_d=%.2f deg  GM_d=%.2f dB  z_inner=%.4f\n', ...
        best.pmc, best.pmd, best.gmd, best.zInner);
    fprintf('  S5worst=%.4f ms  dipWorst=%.3f %%  dutyMax=%.4f  iLmax=%.3f A\n', ...
        best.s5, best.dip, best.dutyMax, best.iLmax);
    fprintf('  per condition:\n');
    for ic = 1:7
        fprintf('    %s: S5=%8.4f ms  dip=%9.3f %%\n', condIds{ic}, ...
            best.s5v(ic), best.dipv(ic));
    end
    S.(nm) = struct('Kci',best.Kci,'Kpe',best.Kpe,'Kie',best.Kie,'ff',ff, ...
        'pmc',best.pmc,'pmd',best.pmd,'gmd',best.gmd,'zInner',best.zInner, ...
        's5worst',best.s5,'dipworst',best.dip,'tier',tier, ...
        's5v',best.s5v,'dipv',best.dipv);
end

save(fullfile(outDir,'a4_dualsel.mat'),'S');
fid = fopen(fullfile(outDir,'a4_dualsel.json'),'w');
fwrite(fid, jsonencode(struct('DUAL_A',S.A,'DUAL_B',S.B)), 'char'); fclose(fid);
fprintf('\nsaved a4_dualsel.mat / .json\n');
