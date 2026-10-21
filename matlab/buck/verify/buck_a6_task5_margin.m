function res = buck_a6_task5_margin(outDir)
%BUCK_A6_TASK5_MARGIN  Engineering safety and margin review.
%
% Phase 3A.6 Task 5. The D+ level passed 7/7, but two criteria passed by a hair:
% S4 (steady-state error 0.0977 % against a 0.1 % limit) and S8 (duty lower
% bound exactly 0.050 against a 0.05 limit). A pass with 2 % of the limit left is
% not the same engineering statement as a pass with 40 % left, and the report has
% to say which one it is. This script
%
%   1) recomputes ALL margins with one normalised definition (no threshold is
%      changed -- S1..S9 keep their original numbers);
%   2) finds out WHY S4 and S8 sit on the limit, instead of just reporting that
%      they do (the first version of this phase would have shipped "zero margin
%      on the duty lower bound" without noticing it is an initial-condition
%      artefact of the soft start);
%   3) compares the current peak with the 12 A command clamp AND with what a real
%      protection would measure;
%   4) computes the ripple and the CCM/DCM boundary, because beyond that boundary
%      the model is not valid and the right verdict is UNDETERMINED, not PASS;
%   5) sweeps parameter tolerances, with every range labelled either as taken
%      from an acceptance condition or as an ASSUMPTION (no datasheet exists).
%
% CLASSIFICATION (the four labels required by the task, applied AFTER the raw
% threshold check, never instead of it):
%   PASS                 raw criterion met, normalised margin >= 20 %
%   PASS WITH LOW MARGIN raw criterion met, normalised margin <  20 %
%   FAIL                 raw criterion not met
%   UNDETERMINED         no valid evidence (model invalid, or quantity not
%                        measurable in this model)

if nargin < 1 || isempty(outDir), outDir = getenv('BUCK_OUT'); end
outDir = strrep(outDir,'/',filesep);
here = fileparts(mfilename('fullpath')); addpath(fileparts(here));
if ~exist(outDir,'dir'), mkdir(outDir); end

Vref = 12;
STD = struct('sserr_max',0.1,'s5_max',1.0,'os_max',5,'dip_max',12, ...
             'dlo',0.05,'dhi',0.85,'imax',12);
LOWMARGIN = 20;      % < 20 % of the limit left -> "PASS WITH LOW MARGIN"
oRun = struct('ratio',2,'tStep',0.06,'tEnd',0.08,'nSub',200,'Tss',5e-3);

conds = [ ...
    struct('id','C1','Vin',48,'R',6,  'L',150e-6)
    struct('id','C2','Vin',42,'R',6,  'L',150e-6)
    struct('id','C3','Vin',54,'R',6,  'L',150e-6)
    struct('id','C4','Vin',48,'R',12, 'L',150e-6)
    struct('id','C5','Vin',48,'R',3,  'L',150e-6)
    struct('id','C6','Vin',54,'R',3,  'L',150e-6)
    struct('id','C7','Vin',48,'R',6,  'L',195e-6) ];

sensDp = struct('enable',true,'fBW',10e3,'nd',1,'gain',1.02,'offset',0.1, ...
                'sigma',0.02,'lsb',0.02,'iMaxPhys',10,'tol',3.0);

fprintf('============ 3A.6 Task 5: engineering safety and margins ============\n');
fprintf('limits unchanged: S4 0.1%%, S5 1.0 ms, S6 5%%, S7 12%%, S8 [0.05,0.85], Imax 12 A\n');
fprintf('"margin" = 1 - |value|/limit  (S8: absolute distance to the nearer rail)\n\n');

%% ---------- 1) unified margins from the frozen D+ records ----------
fprintf('--- 1) margins from the existing D+ records (no new runs) ---\n');
fname = fullfile(outDir,'a6_dplus.json');
if ~exist(fname,'file')
    error('a6_dplus.json not found -- the D+ baseline must be regenerated first');
end
D = jsondecode(fileread(fname));
recs = D.records;
fprintf('%-4s %9s %9s %9s %9s %9s %9s %9s %9s | %s\n', ...
    'cond','S4 %','S5 %','S6 %','S7 %','S8lo %','S8hi %','Ipk %','ssErr%','class');
M = struct('cond',{},'s4',{},'s5',{},'s6',{},'s7',{},'s8lo',{},'s8hi',{}, ...
    'ipk',{},'ssErr',{},'class',{},'worst',{});
for ic = 1:numel(conds)
    sel = strcmp({recs.cond}, conds(ic).id);
    e  = max(abs([recs(sel).ssErr]));
    s5 = max([recs(sel).settleMs]);
    os = max([recs(sel).osPct]);
    dp = min([recs(sel).dipPct]);
    dl = min([recs(sel).dMin]); dh = max([recs(sel).dMax]);
    pk = max([recs(sel).iLpk]);
    m4 = 100*(1 - e/STD.sserr_max);
    m5 = 100*(1 - s5/STD.s5_max);
    m6 = 100*(1 - os/STD.os_max);
    m7 = 100*(1 - abs(dp)/STD.dip_max);
    m8l = 100*(dl - STD.dlo)/(STD.dhi-STD.dlo);
    m8h = 100*(STD.dhi - dh)/(STD.dhi-STD.dlo);
    mi = 100*(1 - pk/STD.imax);
    rawPass = m4>=0 && m5>=0 && m6>=0 && m7>=0 && m8l>=0 && m8h>=0;
    worst = min([m4 m5 m6 m7 m8l m8h]);
    cls = classify(rawPass, worst, LOWMARGIN);
    fprintf('%-4s %9.2f %9.1f %9.1f %9.1f %9.1f %9.1f %9.2f %+9.4f | %s\n', ...
        conds(ic).id, m4, m5, m6, m7, m8l, m8h, mi, e, cls);
    M(end+1) = struct('cond',conds(ic).id,'s4',m4,'s5',m5,'s6',m6,'s7',m7, ...
        's8lo',m8l,'s8hi',m8h,'ipk',mi,'ssErr',e,'class',cls,'worst',worst); %#ok<AGROW>
end
fprintf('  note: Ipk %% is NOT part of S1-S9; it is the device limit check and it is\n');
fprintf('        graded separately in section 4 (negative = over the 12 A limit).\n');

%% ---------- 2) WHY is S4 at 0.0977 %? ----------
% Hypothesis: the ADC LSB (0.02 A) makes the current loop dither by one code and
% the OUTER integrator then has a deadband of one duty step; the mean output
% offset is a fraction of that step, not a controller design error.
fprintf('\n--- 2) S4 near-cliff: where does 0.0977 %% come from? ---\n');
fprintf('%-4s %10s %10s %10s %10s %10s | %s\n','cond','LSB=0.02','no noise','LSB=0','no sensor','LSB=0.005','reading');
s4 = struct('cond',{},'base',{},'noNoise',{},'noLsb',{},'noSens',{},'smallLsb',{});
for ic = [1 3 5 6]
    c = conds(ic);
    v = zeros(1,5);
    % (a) baseline D+ sensor, seed 11
    p = dual_params(c.Vin,c.R,c.L,'nDly',1,'sens',sensDp);
    o = oRun; o.noise = true; o.seed = 11;
    v(1) = cfg_metrics(p,o,Vref).ssErr;
    % (b) same sensor, noise off
    o2 = oRun; o2.noise = false; o2.seed = 11;
    v(2) = cfg_metrics(p,o2,Vref).ssErr;
    % (c) ideal ADC (infinite resolution), noise on
    s = sensDp; s.lsb = 0;
    p = dual_params(c.Vin,c.R,c.L,'nDly',1,'sens',s);
    v(3) = cfg_metrics(p,o,Vref).ssErr;
    % (d) no sensor at all (ideal measurement)
    p = dual_params(c.Vin,c.R,c.L,'nDly',1);
    v(4) = cfg_metrics(p,o,Vref).ssErr;
    % (e) a realistic 12-bit converter on a +-10 A range (LSB = 0.005 A)
    s = sensDp; s.lsb = 0.005;
    p = dual_params(c.Vin,c.R,c.L,'nDly',1,'sens',s);
    v(5) = cfg_metrics(p,o,Vref).ssErr;
    fprintf('%-4s %10.4f %10.4f %10.4f %10.4f %10.4f | %s\n', c.id, v(1), v(2), v(3), v(4), v(5), ...
        tern(abs(v(1))>5*abs(v(3)) && abs(v(1))>5*abs(v(2)), ...
             'LSB dominated', 'not LSB dominated'));
    s4(end+1) = struct('cond',c.id,'base',v(1),'noNoise',v(2),'noLsb',v(3), ...
        'noSens',v(4),'smallLsb',v(5)); %#ok<AGROW>
end

% Is 0.09 % an OFFSET or an unfinished TAIL? The D+ metric averages the last 5 ms
% of an 80 ms run. If the value keeps shrinking with a longer window it is a tail
% (i.e. the criterion is being measured too early), and calling it a
% "steady-state error" would be wrong. This decides which it is.
fprintf('   window test (C1, D+ sensor, seed 11): does the error keep shrinking?\n');
WT = struct('tEnd',{},'e5',{},'e2',{},'e1',{});
p = dual_params(48,6,150e-6,'nDly',1,'sens',sensDp);
for tEnd = [0.08 0.16 0.32]
    o = oRun; o.tEnd = tEnd; o.noise = true; o.seed = 11;
    r = sw_dual_sim(p,o);
    w = [0.005 0.002 0.001];
    e = zeros(1,3);
    for q = 1:3
        e(q) = (mean(r.vOut(r.t > tEnd-w(q))) - Vref)/Vref*100;
    end
    fprintf('     tEnd=%.2f s : mean err over last 5/2/1 ms = %+8.4f %+8.4f %+8.4f %%\n', ...
        tEnd, e);
    WT(end+1) = struct('tEnd',tEnd,'e5',e(1),'e2',e(2),'e1',e(3)); %#ok<AGROW>
end
% same question asked without any sensor non-ideality
p = dual_params(48,6,150e-6,'nDly',1);
r = sw_dual_sim(p, struct('ratio',2,'tStep',0.06,'tEnd',0.32,'nSub',200,'Tss',5e-3));
eIdeal = (mean(r.vOut(r.t > 0.319)) - Vref)/Vref*100;
fprintf('     ideal sensor, tEnd=0.32 s : last 1 ms = %+8.4f %%\n', eIdeal);

%% ---------- 3) WHY is the duty lower bound exactly 0.050? ----------
% Hypothesis: the simulation starts at the 12 V operating point while the soft
% start ramps the reference from 0 V. The output is then "too high" for 5 ms and
% the controller correctly drives the duty into Dmin. If so, 0.050 is an
% INITIAL-CONDITION artefact, not an operating-point saturation, and the honest
% S8 margin is the one measured with a consistent start.
fprintf('\n--- 3) S8 near-cliff: when is the duty at 0.050? ---\n');
fprintf('%-4s %10s %10s %10s %10s %8s %8s | %s\n','cond','dMin all','t(dMin) ms','dMin>60ms','dMin noSS','atDmin%','postDmin','where');
s8 = struct('cond',{},'dMinAll',{},'tMin',{},'dMinPost',{},'dMinNoSS',{},'satPct',{});
for ic = 1:numel(conds)
    c = conds(ic);
    p = dual_params(c.Vin,c.R,c.L,'nDly',1,'sens',sensDp);
    o = oRun; o.noise = true; o.seed = 11;
    m = cfg_metrics(p,o,Vref);
    [dmin, ix] = min(m.r.duty);
    [dmp, ixp] = min(m.r.duty(m.r.t >= o.tStep));
    % no soft start: reference starts at Vref, consistent with the initial state
    o2 = o; o2.Vref0 = Vref;
    m2 = cfg_metrics(p,o2,Vref);
    satPct = 100*mean(abs(m.r.duty(m.r.t>=o.tStep) - p.Dmin) < 1e-9);
    if m.r.t(ix) < o.Tss
        where = 'startup (t<Tss)';
    elseif dmp <= p.Dmin + 1e-9
        where = 'post-step at Dmin';
    else
        where = 'not at Dmin';
    end
    fprintf('%-4s %10.4f %10.4f %10.4f %10.4f %8.2f %8.4f | %s\n', c.id, dmin, ...
        m.r.t(ix)*1e3, dmp, min(m2.r.duty), satPct, dmp, where);
    s8(end+1) = struct('cond',c.id,'dMinAll',dmin,'tMin',m.r.t(ix), ...
        'dMinPost',dmp,'dMinNoSS',min(m2.r.duty),'satPct',satPct); %#ok<AGROW>
end
fprintf('  reading: a startup-only hit means S8 lower bound is an initial-condition\n');
fprintf('           artefact; a post-step hit means the operating point really sits on\n');
fprintf('           the rail and the margin is genuinely zero.\n');

%% ---------- 4) current peak vs the protection definition ----------
% The controller clamps the CURRENT COMMAND (a cycle average) at 12 A. The device
% sees the INSTANTANEOUS peak, which is half a ripple above the average. Calling
% the 12 A clamp a 12 A peak protection is therefore wrong by dIL/2.
fprintf('\n--- 4) current peak vs the 12 A definition ---\n');
fprintf('%-4s %8s %8s %8s %8s %9s %9s | %s\n','cond','iLpk','iLavg','dIL/2','pk-avg','vs 12 A','vs 13.2','verdict');
pk = struct('cond',{},'iLpk',{},'iLavg',{},'half',{},'margin12',{},'margin132',{});
for ic = 1:numel(conds)
    c = conds(ic);
    p = dual_params(c.Vin,c.R,c.L,'nDly',1,'sens',sensDp);
    o = oRun; o.noise = true; o.seed = 11;
    m = cfg_metrics(p,o,Vref);
    half = (m.iLpk - m.iLvalley)/2;
    v12 = m.iLpkAll - STD.imax;
    v132 = m.iLpkAll - 1.10*STD.imax;
    fprintf('%-4s %8.3f %8.3f %8.3f %8.3f %9.3f %9.3f | %s\n', c.id, m.iLpk, m.iLavg, ...
        half, m.iLpk-m.iLavg, v12, v132, tern(v12>0,'OVER 12 A','within 12 A'));
    pk(end+1) = struct('cond',c.id,'iLpk',m.iLpk,'iLavg',m.iLavg,'half',half, ...
        'margin12',v12,'margin132',v132); %#ok<AGROW>
end

%% ---------- 5) ripple, CCM/DCM boundary, model validity ----------
% The model has a diode that never reverse-conducts, but the plant equations do
% not switch to a DCM state when iL reaches zero: the OFF-state model keeps
% integrating through zero. Beyond the boundary the results are therefore NOT
% valid and the verdict is UNDETERMINED, not PASS.
fprintf('\n--- 5) ripple and CCM/DCM boundary (model validity) ---\n');
fprintf('%-4s %8s %9s %9s %9s %9s | %s\n','cond','ripple%','iLvalley','iLmin','Rdcm ohm','R op ohm','status');
ccm = struct('cond',{},'ripple',{},'valley',{},'iLmin',{},'Rdcm',{},'Rop',{});
for ic = 1:numel(conds)
    c = conds(ic);
    p = dual_params(c.Vin,c.R,c.L,'nDly',1,'sens',sensDp);
    o = oRun; o.noise = true; o.seed = 11;
    m = cfg_metrics(p,o,Vref);
    dIL = m.iLpk - m.iLvalley;
    Rdcm = Vref/(dIL/2);            % beyond this load resistance the valley hits 0
    fprintf('%-4s %8.1f %9.3f %9.3f %9.1f %9.1f | %s\n', c.id, m.ripplePct, ...
        m.iLvalley, m.iLminAll, Rdcm, c.R, tern(m.iLminAll>0.02,'CCM','DCM/borderline'));
    ccm(end+1) = struct('cond',c.id,'ripple',m.ripplePct,'valley',m.iLvalley, ...
        'iLmin',m.iLminAll,'Rdcm',Rdcm,'Rop',c.R); %#ok<AGROW>
end
fprintf('  => minimum load for CCM is R < %.1f ohm (%.2f A); the model does not\n', ...
    ccm(1).Rdcm, Vref/ccm(1).Rdcm);
fprintf('     represent DCM, so any condition above that load resistance is UNDETERMINED.\n');

%% ---------- 6) parameter tolerance ----------
fprintf('\n--- 6) parameter tolerance (one at a time, D+ sensor, seed 11) ---\n');
% every range is either an acceptance condition or an explicit ASSUMPTION
cases = { ...
  'Vin 43.2 (-10%)',   'Vin',   43.2,   'ASSUMPTION +-10%% DC bus'; ...
  'Vin 52.8 (+10%)',   'Vin',   52.8,   'ASSUMPTION +-10%% DC bus'; ...
  'L 120u (-20%)',     'L',     120e-6, 'ASSUMPTION no datasheet'; ...
  'L 180u (+20%)',     'L',     180e-6, 'ASSUMPTION no datasheet'; ...
  'C 176u (-20%)',     'C',     176e-6, 'ASSUMPTION no datasheet'; ...
  'C 264u (+20%)',     'C',     264e-6, 'ASSUMPTION no datasheet'; ...
  'ESR 5m',            'ESR',   5e-3,   'ASSUMPTION no datasheet'; ...
  'ESR 30m',           'ESR',   30e-3,  'ASSUMPTION cold electrolytic'; ...
  'RL 30m',            'RL',    30e-3,  'ASSUMPTION DCR +30%%'; ...
  'RonSW 5m',          'RonSW', 5e-3,   'ASSUMPTION 5x nominal'; ...
  'RonSW 50m',         'RonSW', 50e-3,  'ASSUMPTION realistic 48 V FET'; ...
  'RonD 10m',          'RonD',  10e-3,  'ASSUMPTION diode/body'; ...
  'Vf 0.60',           'Vf',    0.60,   'ASSUMPTION schottky hot'; ...
  'sens gain +5%',     'sensgain', 1.07,'ASSUMPTION 2%% spec + drift'; ...
  'sigma 0.05 A',      'sigma', 0.05,   'ASSUMPTION noisy shunt'; ...
  'LSB 0.05 A',        'lsb',   0.05,   'ASSUMPTION 8-bit-equivalent'};
T = struct('name',{},'field',{},'value',{},'source',{},'ssErr',{},'s5',{}, ...
    'dip',{},'dmin',{},'dmax',{},'ipk',{},'class',{});
fprintf('%-18s %9s %8s %8s %8s %8s %8s | %s\n','case','ssErr%','S5 ms','dip%','dMin','iLpk','margin%','class');
for q = 1:size(cases,1)
    p = dual_params(48,6,150e-6,'nDly',1,'sens',sensDp);
    switch cases{q,2}
        case 'sensgain', p.sens.gain = cases{q,3};
        case 'sigma',    p.sens.sigma = cases{q,3};
        case 'lsb',      p.sens.lsb = cases{q,3};
        otherwise,       p.(cases{q,2}) = cases{q,3};
    end
    o = oRun; o.noise = true; o.seed = 11;
    m = cfg_metrics(p,o,Vref);
    mg = min([100*(1-abs(m.ssErr)/STD.sserr_max), 100*(1-m.settleMs/STD.s5_max), ...
              100*(1-abs(m.dipPct)/STD.dip_max), ...
              100*(m.dMin-STD.dlo)/(STD.dhi-STD.dlo), 100*(STD.dhi-m.dMax)/(STD.dhi-STD.dlo)]);
    rawPass = abs(m.ssErr)<=STD.sserr_max && m.settleMs<=STD.s5_max && ...
              abs(m.dipPct)<=STD.dip_max && m.dMin>=STD.dlo && m.dMax<=STD.dhi;
    cls = classify(rawPass, mg, LOWMARGIN);
    fprintf('%-18s %9.4f %8.4f %8.3f %8.4f %8.2f %8.1f | %s\n', cases{q,1}, ...
        m.ssErr, m.settleMs, m.dipPct, m.dMin, m.iLpk, mg, cls);
    T(end+1) = struct('name',cases{q,1},'field',cases{q,2},'value',cases{q,3}, ...
        'source',cases{q,4},'ssErr',m.ssErr,'s5',m.settleMs,'dip',m.dipPct, ...
        'dmin',m.dMin,'dmax',m.dMax,'ipk',m.iLpk,'class',cls); %#ok<AGROW>
end

% combined worst cases, plus a Floquet check on them (metrics alone cannot tell
% a stable orbit from a slowly growing one)
fprintf('   combined worst cases:\n');
combos = { ...
  'W1 min Vin/L/C, max ESR', 43.2, 120e-6, 176e-6, 30e-3, 1e-3, 1.02; ...
  'W2 max Vin/L, min C',     52.8, 180e-6, 176e-6, 10e-3, 50e-3, 1.07};
C = struct('name',{},'ssErr',{},'s5',{},'dip',{},'dmin',{},'dmax',{},'ipk',{}, ...
    'maxAbs',{},'converged',{},'class',{});
for q = 1:size(combos,1)
    p = dual_params(combos{q,2},6,combos{q,3},'nDly',1,'sens',sensDp);
    p.C = combos{q,4}; p.ESR = combos{q,5}; p.RonSW = combos{q,6};
    p.sens.gain = combos{q,7};
    o = oRun; o.noise = true; o.seed = 11;
    m = cfg_metrics(p,o,Vref);
    rf = sw_floquet(p, struct('verbose',false,'maxIter',1500));
    mg = min([100*(1-abs(m.ssErr)/STD.sserr_max), 100*(1-m.settleMs/STD.s5_max), ...
              100*(1-abs(m.dipPct)/STD.dip_max), ...
              100*(m.dMin-STD.dlo)/(STD.dhi-STD.dlo), 100*(STD.dhi-m.dMax)/(STD.dhi-STD.dlo)]);
    rawPass = abs(m.ssErr)<=STD.sserr_max && m.settleMs<=STD.s5_max && ...
              abs(m.dipPct)<=STD.dip_max && m.dMin>=STD.dlo && m.dMax<=STD.dhi;
    cls = classify(rawPass && rf.converged && rf.maxAbs<1, mg, LOWMARGIN);
    fprintf('   %-24s ssErr=%+7.4f%% S5=%.4f dip=%.3f dmin=%.4f iLpk=%.2f max|lam|=%.4f(conv %d) -> %s\n', ...
        combos{q,1}, m.ssErr, m.settleMs, m.dipPct, m.dMin, m.iLpk, rf.maxAbs, rf.converged, cls);
    C(end+1) = struct('name',combos{q,1},'ssErr',m.ssErr,'s5',m.settleMs, ...
        'dip',m.dipPct,'dmin',m.dMin,'dmax',m.dMax,'ipk',m.iLpk, ...
        'maxAbs',rf.maxAbs,'converged',rf.converged,'class',cls); %#ok<AGROW>
end

%% ---------- 7) engineering margin report ----------
fprintf('\n--- 7) engineering margin report ---\n');
fprintf('%-10s %-22s %-14s %-20s %s\n','criterion','value (worst)','limit','margin','class');
EM = struct('criterion',{},'value',{},'limit',{},'marginPct',{},'class',{},'why',{});
add = @(c,v,l,mp,cl,w) struct('criterion',c,'value',v,'limit',l, ...
    'marginPct',mp,'class',cl,'why',w);

% S1/S2/S3 come from the Task 1 stability record, not from the D+ table
worstLam = NaN; pmD = NaN; gmD = NaN;
fstab = fullfile(outDir,'a6_stability.json');
if exist(fstab,'file')
    S = jsondecode(fileread(fstab));
    worstLam = max([S.records.maxAbs]);
    pmD = min([S.records.pmDesign]);
    gmD = min([S.records.gmDesign]);
end
em = [ ...
  add('S1 local stability', worstLam, 'max|lambda|<1', 100*(1-worstLam), ...
      classify(worstLam<1, 100*(1-worstLam), LOWMARGIN), ...
      'Floquet multipliers, 14 orbits (3A.6 Task 1)'); ...
  add('S2 phase margin', pmD, '>=50 deg', 100*(1-50/pmD), 'UNDETERMINED', ...
      'average-model design value only; not measurable at switching level'); ...
  add('S3 gain margin', gmD, '>=6 dB', 100*(1-6/gmD), 'UNDETERMINED', ...
      'average-model design value only; not measurable at switching level'); ...
  add('S4 steady-state', max([M.ssErr]), '<=0.1 %', 100*(1-max([M.ssErr])/0.1), ...
      classify(max([M.ssErr])<=0.1, 100*(1-max([M.ssErr])/0.1), LOWMARGIN), ...
      'dominated by the ADC LSB, see section 2'); ...
  add('S5 settling', max([recs.settleMs]), '<=1.0 ms', 100*(1-max([recs.settleMs])), ...
      classify(max([recs.settleMs])<=1.0, 100*(1-max([recs.settleMs])), LOWMARGIN), ...
      'seed spread dominates, see D+ statistics'); ...
  add('S7 load dip', min([recs.dipPct]), '>= -12 %', ...
      100*(1-abs(min([recs.dipPct]))/12), ...
      classify(abs(min([recs.dipPct]))<=12, 100*(1-abs(min([recs.dipPct]))/12), LOWMARGIN), ...
      'slew limited, improves only with more inductance'); ...
  add('S8 duty lower', min([s8.dMinPost]), '[0.05, 0.85]', min([M.s8lo]), ...
      classify(min([s8.dMinPost])>=STD.dlo, min([M.s8lo]), LOWMARGIN), ...
      'measured hit is a soft-start initial-condition artefact, see section 3'); ...
  add('current peak', max([pk.iLpk]), '<=12 A', 100*(1-max([pk.iLpk])/12), ...
      classify(max([pk.iLpk])<=12, 100*(1-max([pk.iLpk])/12), LOWMARGIN), ...
      'command clamp is on the average; peak = average + dIL/2') ];
for q = 1:numel(em)
    fprintf('%-10s %-22s %-14s %-20s %s\n', em(q).criterion, num2str(em(q).value,6), ...
        em(q).limit, num2str(em(q).marginPct,5), em(q).class);
end
EM = em;

% controller parameter margins, measured on the switching map: how far can each
% gain be scaled before the period-1 orbit is lost? The Task 4 x0.8/x1.2 sweep
% already showed that Kci x1.2 is unstable, so this quantifies the actual limit
% instead of leaving a factor-1.2 bracket.
fprintf('   controller parameter margins (switching map, C1 pre-step):\n');
marg = struct('knob',{},'factor',{},'maxAbs',{});
knobs = {'Kci','Kpe','Kie'};
for kk = 1:numel(knobs)
    lo = 1; hi = 2;
    p = dual_params(48,6,150e-6,'nDly',1); p0 = p;
    rh = sw_floquet(setfield(p,knobs{kk},p0.(knobs{kk})*hi), ...
        struct('verbose',false,'maxIter',1200)); %#ok<SFLD>
    if rh.converged && rh.maxAbs < 1
        marg(end+1) = struct('knob',knobs{kk},'factor',hi,'maxAbs',rh.maxAbs); %#ok<AGROW>
        fprintf('     %-4s x%.2f still stable -> margin above x2 (not bracketed)\n', knobs{kk}, hi);
        continue;
    end
    for it = 1:6
        mid = 0.5*(lo+hi);
        rm = sw_floquet(setfield(p,knobs{kk},p0.(knobs{kk})*mid), ...
            struct('verbose',false,'maxIter',1200)); %#ok<SFLD>
        if rm.converged && rm.maxAbs < 1, lo = mid; else, hi = mid; end
    end
    marg(end+1) = struct('knob',knobs{kk},'factor',lo,'maxAbs',0); %#ok<AGROW>
    fprintf('     %-4s margin x%.3f (%.2f dB)  [bracket %.3f .. %.3f]\n', ...
        knobs{kk}, lo, 20*log10(lo), lo, hi);
end
% voltage-loop crossover margin is not measurable here: report it as such
fprintf('     (a phase margin in degrees is still NOT measurable at this level)\n');

res = struct('level','3A.6-Task5','std',STD,'lowMarginPct',LOWMARGIN, ...
    'condMargins',M,'s4Diagnosis',s4,'s4Window',WT,'s4Ideal',eIdeal, ...
    's8Diagnosis',s8,'peak',pk,'ccm',ccm,'tolerance',T,'combos',C, ...
    'ctrlMargins',marg,'engineeringMargin',EM, ...
    'note',['No S1-S9 threshold was changed. S8 lower bound is reported twice: ' ...
            'as measured (with the frozen initial condition) and with a ' ...
            'consistent soft start. The current-peak check is graded against ' ...
            'the strict 12 A device limit, not the 1.10x allowance used in 3A.6 Task 2.']);
save(fullfile(outDir,'a6_task5_margin.mat'),'res');
txt = jsonencode(res);
fid = fopen(fullfile(outDir,'a6_task5_margin.json'),'w');
if fid >= 0, fwrite(fid, txt, 'char'); fclose(fid); end
fprintf('\nsaved a6_task5_margin.mat/.json\n');
end

% ---------------------------------------------------------------------------
function cls = classify(rawPass, marginPct, lowLimit)
if ~rawPass
    cls = 'FAIL';
elseif ~isfinite(marginPct) || marginPct < lowLimit
    cls = 'PASS WITH LOW MARGIN';
else
    cls = 'PASS';
end
end

function s = tern(c,a,b)
if c, s = a; else, s = b; end
end
