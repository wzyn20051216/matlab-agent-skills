function res = buck_a6_task3_inductance(outDir)
%BUCK_A6_TASK3_INDUCTANCE  Is the 62 % current ripple a problem, and does raising L fix it?
%
% The nominal ripple ratio at L = 150 uH is often quoted as 62 % (C1). That is
% the LIGHTEST relevant operating point? No -- C4 (12 ohm, iL = 1 A) measures
% 125 %: the ripple ratio scales with 1/iL, so the light-load case is the worst
% one and it sits only ~1.7x above the CCM/DCM boundary. This script quantifies
% the trade-off over four inductance values.
%
% CANDIDATES (exploration only -- none of these is a preselected design)
%   L = 150 uH  baseline, as built
%   L = 220 / 330 / 470 uH
%
% WHAT IS MEASURED (all on the D+ engine: switching plant + non-ideal sensor)
%   ripple ratio (per period, / cycle-average current)
%   CCM/DCM boundary current  Icrit = dIL/2
%   instantaneous peak current vs Imax = 12 A
%   current slew available    (Vin*Dmax - Vout)/L   [A/s]  -> load-step capability
%   output ripple Vpp
%   S4 / S5 / S7 / S8 over the 7 conditions
%   discrete stability margin (Floquet max|lambda| at the nominal orbit)
%
% WHAT IS ESTIMATED, NOT MEASURED (flagged as such in the output)
%   DCR and volume. A first-order scaling is used: with the same core family and
%   the same winding window, L ~ N^2 and R_dc ~ N, so R_dc ~ sqrt(L); stored
%   energy ~ L*I^2. These are ORDER-OF-MAGNITUDE estimates to price the trade-off,
%   not datasheet numbers. No magnetics design was done in this phase.

if nargin < 1 || isempty(outDir), outDir = getenv('BUCK_OUT'); end
outDir = strrep(outDir,'/',filesep);
here = fileparts(mfilename('fullpath')); addpath(fileparts(here));
if ~exist(outDir,'dir'), mkdir(outDir); end

Vref = 12; Ts = 20e-6;
LK = [150 220 330 470]*1e-6;
SEEDS = [11 37 59];
conds = [ ...
    struct('id','C1','Vin',48,'R',6)
    struct('id','C2','Vin',42,'R',6)
    struct('id','C3','Vin',54,'R',6)
    struct('id','C4','Vin',48,'R',12)
    struct('id','C5','Vin',48,'R',3)
    struct('id','C6','Vin',54,'R',3)
    struct('id','C7','Vin',48,'R',6) ];     % C7 uses L+30% of the candidate

sensDp = struct('enable',true,'fBW',10e3,'nd',1,'gain',1.02,'offset',0.1, ...
                'sigma',0.02,'lsb',0.02,'iMaxPhys',10,'tol',3.0);
STD = struct('sserr_max',0.1,'s5_max',1.0,'os_max',5,'dip_max',12, ...
             'dlo',0.05,'dhi',0.85,'imax',12);

fprintf('=========== 3A.6 Task 3: inductance trade-off ===========\n');
fprintf('engine: D+ (switching + non-ideal sensor), %d seeds/case\n', numel(SEEDS));
fprintf('every candidate is measured, not assumed better\n\n');

R = struct('L',{},'cond',{},'seed',{},'ripplePct',{},'icritA',{},'iLavgA',{}, ...
    'iLpk',{},'dipPct',{},'settleMs',{},'ssErr',{},'osPct',{}, ...
    'vpp',{},'dMin',{},'dMax',{},'pass',{});
% every field the records will carry must be preallocated, otherwise
% summ(end+1) = struct(...) fails with "subscripted assignment between dissimilar
% structures" (hit twice in this project).
summ = struct('L',{},'rippleWorstPct',{},'icritA',{},'vppSwitchNom',{}, ...
    'slewAps',{},'iLpk',{},'dipWorst',{},'s5Worst',{},'ssErrWorst',{}, ...
    'vppWorst',{},'dutyMin',{},'dutyMax',{},'maxAbsLam',{},'dscrRatio',{}, ...
    'energyRatio',{},'nPassCond',{});

for il = 1:numel(LK)
    Lb = LK(il);
    fprintf('--- L = %.0f uH ---\n', Lb*1e6);
    rip = []; ick = []; ipk = []; dip = []; s5 = []; sse = []; vpp = []; osv = [];
    dmin = []; dmax = [];
    nPass = 0;

    % discrete stability margin at the nominal orbit (independent evidence)
    pn = dual_params(48, 6, Lb, 'nDly', 1);
    fl = sw_floquet(pn, struct('verbose', false));
    fprintf('  Floquet: max|lam| = %.5f (%s)\n', fl.maxAbs, ...
        tern(fl.converged && fl.maxAbs<1, 'stable', 'UNSTABLE'));
    % CCM/DCM boundary at nominal duty  (dIL/2)
    D0 = Vref/48;
    icrit = (48 - Vref)*D0*Ts/(2*Lb);
    % switching ripple WITHOUT sensor noise, separated from noise-induced jitter
    pnn = dual_params(48, 6, Lb, 'nDly', 1);
    rnn = sw_dual_sim(pnn, struct('ratio',1,'tStep',1,'tEnd',0.06,'nSub',200));
    wnn = rnn.t > 0.045;
    vppSw = max(rnn.vOut(wnn)) - min(rnn.vOut(wnn));

    for ic = 1:numel(conds)
        c = conds(ic);
        Lr = Lb;
        if strcmp(c.id,'C7'), Lr = 1.30*Lb; end      % C7 keeps the +30 % tolerance
        for is = 1:numel(SEEDS)
            p = dual_params(c.Vin, c.R, Lr, 'nDly', 1, 'sens', sensDp);
            r = sw_dual_sim(p, struct('ratio',2,'tStep',0.06,'tEnd',0.08, ...
                'nSub',200,'Tss',5e-3,'noise',true,'seed',SEEDS(is)));
            m = step_metrics(r.t, r.vOut, Vref, 0.06, 1);
            % TWO different masks: the per-period arrays have nPer entries, the
            % fine-grid arrays have ~nPer*nSub/dec. Applying the per-period mask to
            % r.vOut does NOT raise an error in R2026a -- it silently returns a
            % wrong subset (measured 0.647 V instead of 0.058 V). Keep them apart.
            pre  = r.tPer > 0.05 & r.tPer < 0.06;      % per-period arrays
            preT = r.t > 0.045 & r.t < 0.06;           % fine-grid arrays
            post = r.t >= 0.06;
            ssErr = (mean(r.vOut(r.t > 0.075)) - Vref)/Vref*100;
            rp = mean(r.iLpeak(pre) - r.iLvalley(pre))/mean(r.iLavg(pre))*100;
            vp = max(r.vOut(preT)) - min(r.vOut(preT));
            ok = abs(ssErr)<=STD.sserr_max && isfinite(m.settleMs) && m.settleMs<=STD.s5_max ...
                 && abs(m.dipPct)<=STD.dip_max && min(r.duty(post))>=STD.dlo-1e-6 ...
                 && max(r.duty(post))<=STD.dhi+1e-6;
            R(end+1) = struct('L',Lb,'cond',c.id,'seed',SEEDS(is),'ripplePct',rp, ...
                'icritA',icrit,'iLavgA',mean(r.iLavg(pre)),'iLpk',max(r.iL(post)), ...
                'dipPct',m.dipPct,'settleMs',m.settleMs,'ssErr',ssErr, ...
                'osPct',(max(r.vOut)-Vref)/Vref*100,'vpp',vp, ...
                'dMin',min(r.duty(post)),'dMax',max(r.duty(post)),'pass',ok); %#ok<AGROW>
            rip(end+1)=rp; ipk(end+1)=max(r.iL(post)); dip(end+1)=m.dipPct;
            s5(end+1)=m.settleMs; sse(end+1)=ssErr; vpp(end+1)=vp;
            osv(end+1)=(max(r.vOut)-Vref)/Vref*100;
            dmin(end+1)=min(r.duty(post)); dmax(end+1)=max(r.duty(post));
        end
        sel = strcmp({R.cond},c.id) & [R.L]==Lb;
        if all([R(sel).pass]), nPass = nPass + 1; end
    end
    slew = (48*0.85 - Vref)/Lb;
    dscr = sqrt(Lb/150e-6);
    energy = (Lb*max(ipk)^2)/(150e-6*max(ipk)^2);   % L ratio at the same current
    summ(end+1) = struct('L',Lb,'rippleWorstPct',max(rip),'icritA',icrit, ...
        'vppSwitchNom',vppSw, ...
        'slewAps',slew,'iLpk',max(ipk),'dipWorst',min(dip),'s5Worst',max(s5), ...
        'ssErrWorst',max(abs(sse)),'vppWorst',max(vpp),'dutyMin',min(dmin), ...
        'dutyMax',max(dmax),'maxAbsLam',fl.maxAbs,'dscrRatio',dscr, ...
        'energyRatio',energy,'nPassCond',nPass); %#ok<AGROW>
    fprintf('  ripple worst %6.1f %% | Icrit %.3f A | iLpk %5.2f A | dip %7.3f%% | S5 %6.4f ms | ssErr %.4f%% | Vpp %.4f V | Vpp(no-noise,nom) %.4f V | pass %d/7\n', ...
        max(rip), icrit, max(ipk), min(dip), max(s5), max(abs(sse)), max(vpp), vppSw, nPass);
end

fprintf('\n--- summary ---\n');
fprintf('%6s %9s %7s %10s %8s %8s %8s %8s %10s %9s %8s %8s %6s\n', ...
    'L(uH)','ripple%','Icrit','slew kA/s','iLpk(A)','dip%','S5 ms','ssErr%','Vpp-noN(V)','Vpp+jit(V)','DCR x','energy x','pass');
for q = 1:numel(summ)
    s = summ(q);
    fprintf('%6.0f %9.1f %7.3f %10.1f %8.2f %8.3f %8.4f %8.4f %10.4f %9.4f %8.2f %8.2f %4d/7\n', ...
        s.L*1e6, s.rippleWorstPct, s.icritA, s.slewAps/1e3, s.iLpk, ...
        s.dipWorst, s.s5Worst, s.ssErrWorst, s.vppSwitchNom, s.vppWorst, ...
        s.dscrRatio, s.energyRatio, s.nPassCond);
end
fprintf('\nVpp-noN = switching ripple alone (sensor noise off, C1 nominal).\n');
fprintf('Vpp+jit = worst over the 7 conditions WITH sensor noise (noise dominates it).\n');
fprintf('\nDCR x and energy x are FIRST-ORDER SCALING ESTIMATES (R_dc ~ sqrt(L),\n');
fprintf('stored energy ~ L*I^2 at the same current), not magnetics design output.\n');

res = struct('candidates_uH', LK*1e6, 'seeds', SEEDS, 'sens', sensDp, ...
    'std', STD, 'records', R, 'summary', summ, ...
    'estimateNote','DCR and energy columns are order-of-magnitude scaling, not a magnetics design');
save(fullfile(outDir,'a6_inductance.mat'),'res');
txt = jsonencode(res);
fid = fopen(fullfile(outDir,'a6_inductance.json'),'w');
if fid >= 0, fwrite(fid, txt, 'char'); fclose(fid); end
fprintf('saved a6_inductance.mat/.json\n');
end

function s = tern(c,a,b)
if c, s = a; else, s = b; end
end
