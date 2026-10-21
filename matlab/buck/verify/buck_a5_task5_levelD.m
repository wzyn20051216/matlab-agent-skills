function res = buck_a5_task5_levelD(outDir)
%BUCK_A5_TASK5_LEVELD  Level D acceptance: switching-level model (real PWM, ripple, losses).
%
% Level D is the FIRST level where the plant really switches. It is NOT a
% continuation of Levels A/B/C: the switching model has instantaneous duty,
% inductor ripple (1.23 App on 2 A DC at nominal), diode drop, switch and
% inductor resistance, ESR, and a sampled modulator (ZOH at Ts).
%
% Controller configuration (chosen from the Phase 3A.5 Task-4 experiments):
%   sampPhase  = 0     sample the current at the switching-period boundary
%   rippleComp = true  add dIL/2 = (Vin-Vref)*(Vref/Vin)*Ts/(2L) to the sample
%   ctrlDelay  = 1 Ts  one full period of computation delay
% Sampling at mid-ON instead was measured UNSTABLE at one period of delay
% (S5 = 30 ms, 17 % startup overshoot), so boundary sampling + analytic
% half-ripple compensation is the only configuration that survives.
%
% Note on S2/S3: a switching model cannot produce a small-signal phase margin,
% so the discrete margins are carried over from the average model as
% DESIGN-TIME values and flagged as such (field s2s3Source). They are not an
% independent measurement at this level and must not be quoted as one.

if nargin < 1 || isempty(outDir), outDir = getenv('BUCK_OUT'); end
outDir = strrep(outDir,'/',filesep);
if ~exist(outDir,'dir'), mkdir(outDir); end
here = fileparts(mfilename('fullpath')); addpath(fileparts(here));

Vref = 12; Ts = 20e-6;
Kci = 6; Kpe = 1.8; Kie = 4000;
STD = struct('PM_min',50,'GM_min',6,'sserr_max',0.1,'s5_max',1.0, ...
             'os_max',5,'dip_max',12,'dlo',0.05,'dhi',0.85);

conds = [ ...
    struct('id','C1','Vin',48,'R',6,  'L',150e-6)
    struct('id','C2','Vin',42,'R',6,  'L',150e-6)
    struct('id','C3','Vin',54,'R',6,  'L',150e-6)
    struct('id','C4','Vin',48,'R',12, 'L',150e-6)
    struct('id','C5','Vin',48,'R',3,  'L',150e-6)
    struct('id','C6','Vin',54,'R',3,  'L',150e-6)
    struct('id','C7','Vin',48,'R',6,  'L',195e-6) ];

fprintf('=========== LEVEL D acceptance: switching-level model ===========\n');
fprintf('plant: RL=20 mOhm, RonSW=1 mOhm, RonD=2 mOhm, Vf=0.35 V, ESR=10 mOhm, nSub=200\n');
fprintf('ctrl : sampPhase=0 (boundary) + half-ripple comp, 1 Ts computation delay\n');
fprintf('S2/S3 at this level are DESIGN-TIME values carried from the average model.\n\n');

R = struct('cond',{},'rep',{},'delay',{},'dipPct',{},'settleMs',{},'ssErr',{}, ...
    'osPct',{},'dMin',{},'dMax',{},'iLmax',{},'vpp',{},'ipp',{},'pmD',{},'gmD',{}, ...
    'pass',{},'flags',{},'verdict',{});

for ic = 1:numel(conds)
    c = conds(ic);
    % design-time discrete margins (average model, same as Level B/C)
    q = struct('Vin',c.Vin,'L',c.L,'C',220e-6,'R',c.R,'Vref',Vref,'fs',50e3);
    Gv = tf(dual_loop_gain(q, c.R, Kci, Kpe, Kie, 1, 'plant'));
    Cs = tf([Kpe Kie],[1 0]);
    Ld = c2d(Cs,Ts,'zoh')*tf(1,[1 0],Ts)*c2d(Gv,Ts,'zoh');
    [pmD, gmD] = margin_fast(Ld, 4000);

    % delay=1 gets 3 repeats (the realistic case); delay=0 gets 1 (optimistic bound)
    plan = [1 1 1 0];
    for ir = 1:numel(plan)
        dl = plan(ir);
        cfg = struct('Vin',c.Vin,'L',c.L,'C',220e-6,'R',c.R,'Vref',Vref,'fs',50e3, ...
            'Kci',Kci,'Kpe',Kpe,'Kie',Kie,'ff',1, ...
            'RL',20e-3,'ESR',10e-3,'Vf',0.35,'RonSW',1e-3,'RonD',2e-3, ...
            'Imin',0,'Imax',12,'Dmin',0.05,'Dmax',0.85, ...
            'Tt',3e-4,'Eclamp',1.5,'Tss',5e-3, ...
            'loadStepTime',0.06,'loadStepRatio',2,'tStop',0.08,'nSub',200, ...
            'ctrlSample',true,'sampPhase',0,'rippleComp',true, ...
            'ctrlDelay',logical(dl), ...
            'modelName',sprintf('swL_%s_%d_%d',c.id,dl,ir),'saveModel',true);
        r = build_buck_switching(outDir, cfg);
        m = step_metrics(r.t, r.vOut, Vref, 0.06, 1);
        post = r.t >= 0.06;
        pre  = r.t >= 0.05 & r.t < 0.06;
        ssErr = (mean(r.vOut(r.t > 0.075)) - Vref)/Vref*100;
        rec = struct('cond',c.id,'rep',ir,'delay',dl, ...
            'dipPct',m.dipPct,'settleMs',m.settleMs,'ssErr',ssErr, ...
            'osPct',(max(r.vOut)-Vref)/Vref*100, ...
            'dMin',min(r.duty(post)),'dMax',max(r.duty(post)), ...
            'iLmax',max(r.iL), ...
            'vpp',max(r.vOut(pre))-min(r.vOut(pre)), ...
            'ipp',max(r.iL(pre))-min(r.iL(pre)), ...
            'pmD',pmD,'gmD',gmD,'pass',false,'flags',false(1,8),'verdict','');

        okS1 = isfinite(m.settleMs) && abs(ssErr) <= STD.sserr_max;
        okS2 = pmD >= STD.PM_min;                       % design-time
        okS3 = isinf(gmD) || gmD >= STD.GM_min;         % design-time
        okS4 = abs(ssErr) <= STD.sserr_max;
        okS5 = isfinite(m.settleMs) && m.settleMs <= STD.s5_max;
        okS6 = rec.osPct <= STD.os_max;
        okS7 = abs(m.dipPct) <= STD.dip_max;
        okS8 = rec.dMin >= STD.dlo - 1e-6 && rec.dMax <= STD.dhi + 1e-6;
        rec.flags = [okS1 okS2 okS3 okS4 okS5 okS6 okS7 okS8];
        rec.pass = all(rec.flags);
        if rec.pass, rec.verdict = 'PASS'; else, rec.verdict = 'FAIL'; end
        R(end+1) = rec; %#ok<AGROW>
        fprintf('%s d=%d r%d : S5=%8.4f ms dip=%8.3f%% OS=%6.2f%% ssErr=%+7.4f%% duty=[%.3f,%.3f] iLmax=%.2f Vpp=%.4f Ipp=%.3f -> %s\n', ...
            c.id, dl, ir, m.settleMs, m.dipPct, rec.osPct, ssErr, ...
            rec.dMin, rec.dMax, rec.iLmax, rec.vpp, rec.ipp, rec.verdict);
    end
end

% S9: repeat spread for the delay=1 records
for ic = 1:numel(conds)
    idx = find(strcmp({R.cond},conds(ic).id) & [R.delay] == 1);
    dev = max(abs([R(idx).settleMs] - R(idx(1)).settleMs));
    if ~(dev < 1e-6)
        for q2 = idx
            if R(q2).pass
                R(q2).pass = false; R(q2).verdict = 'FAIL';
            end
        end
        fprintf('  [S9] %s repeat spread %.3e ms -> FAIL\n', conds(ic).id, dev);
    end
end

fprintf('\n---- Level D summary (delay = 1 Ts, the realistic case) ----\n');
np = 0;
for ic = 1:numel(conds)
    isC = strcmp({R.cond},conds(ic).id) & [R.delay] == 1;
    sel = isC & strcmp({R.verdict},'PASS');
    if nnz(sel) == nnz(isC), np = np + 1; end
    fprintf('  %s : %d/%d repeats PASS\n', conds(ic).id, nnz(sel), nnz(isC));
end
fprintf('  => %d/7 conditions PASS at Level D (delay = 1 Ts)\n', np);
fprintf('  (delay = 0 is reported separately as the optimistic bound)\n');

res = struct('level','D','ctrl',struct('Kci',Kci,'Kpe',Kpe,'Kie',Kie, ...
    'sampPhase',0,'rippleComp',true),'plant',struct('RL',20e-3,'ESR',10e-3, ...
    'Vf',0.35,'RonSW',1e-3,'RonD',2e-3,'nSub',200),'std',STD,'records',R, ...
    'nPassConditions',np,'s2s3Source','design-time discrete margins from the average model (not measured at switching level)', ...
    'note','Level D = switching model; still no sensor noise and no hardware');
save(fullfile(outDir,'a5_levelD.mat'),'res');
txt = jsonencode(res);
fid = fopen(fullfile(outDir,'a5_levelD.json'),'w');
if fid >= 0, fwrite(fid, txt, 'char'); fclose(fid); end
fprintf('saved a5_levelD.mat/.json\n');
end
