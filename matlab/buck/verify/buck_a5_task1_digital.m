%% Phase 3A.5 / Task 1: real discrete closed-loop time-domain verification
%
% The 3A.4 acceptance matrix (level A) used a CONTINUOUS controller. This script
% produces level B: the DUAL-B controller running as a genuine sampled-data
% controller at fs = 50 kHz.
%
% Model (buck_dual_sim.m, validated against the continuous model in Task 0):
%   - ADC samples (iL, vC) once per switching period at the carrier boundary
%   - digital PI + inner current loop, all gains discrete
%   - the duty command is applied cfg.delaySamples periods later (ZOH + delay)
%   - discrete back-calculation anti-windup, iLref and duty clamps
%
% For every condition and every delay the script reports
%   frequency domain : worst PM/GM of the DISCRETE loop, max|z| of the closed loop
%   time domain      : S5 (strict), dip, startup overshoot, duty range, iL peak
% and decides PASS/FAIL against the ORIGINAL S1-S9 thresholds.
%
% Delay convention: delaySamples = d means d full switching periods of pure
% computation delay ON TOP of the zero-order hold, i.e. an effective delay of
% (d + 0.5)*Ts. d=1 is a single-update PWM with one period of computation.
%
% Output: a5_task1_digital.json / .mat

clear; close all;
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here,'..'));
outDir = getenv('BUCK_OUT');
if isempty(outDir), outDir = fullfile(here,'..','..','artifacts','validation','buck'); end
outDir = strrep(outDir,'/',filesep);

STD = struct('PM_min',50,'GM_min',6,'sserr_max',0.1,'recover_max',1.0, ...
             'startup_os_max',5,'dip_max',12,'duty_lo',0.05,'duty_hi',0.85,'repro',1e-9);
fprintf('=========== 3A.5 Task 1: discrete closed loop (level B) ===========\n');
fprintf('S2 PM>=%g  S3 GM>=%g dB  S5<=%g ms  S6<=%g%%  S7<=%g%%  S8 duty in [%g,%g]\n\n', ...
    STD.PM_min, STD.GM_min, STD.recover_max, STD.startup_os_max, STD.dip_max, ...
    STD.duty_lo, STD.duty_hi);

% ---- DUAL-B design under test (unchanged from 3A.4) ----
S = load(fullfile(outDir,'a4_dualsel.mat')); S = S.S;
D = struct('Kci',S.B.Kci,'Kpe',S.B.Kpe,'Kie',S.B.Kie,'ff',1, ...
           'Imin',0,'Imax',12,'Dmin',0.05,'Dmax',0.85,'Tt',3e-4, ...
           'Eclamp',1.5,'Tss',5e-3);
fprintf('DUAL-B: Kci=%.3f  Kp_e=%.4f  Ki_e=%.1f  Imax=%g  Tt=%.1e  Tss=%.1e\n\n', ...
    D.Kci, D.Kpe, D.Kie, D.Imax, D.Tt, D.Tss);

conds = [ ...
    struct('id','C1','Vin',48,'R',6,'L',150e-6)
    struct('id','C2','Vin',42,'R',6,'L',150e-6)
    struct('id','C3','Vin',54,'R',6,'L',150e-6)
    struct('id','C4','Vin',48,'R',12,'L',150e-6)
    struct('id','C5','Vin',48,'R',3,'L',150e-6)
    struct('id','C6','Vin',54,'R',3,'L',150e-6)
    struct('id','C7','Vin',48,'R',6,'L',195e-6) ];
Ts = 1/50e3; tStep = 0.06; ratio = 2; nRep = 3;

rows = struct('cond',{},'delay',{},'cond_delay',{}, ...
    'pmC',{},'pmD',{},'gmD',{},'maxAbsZ',{}, ...
    'dip',{},'s5',{},'os',{},'sserr',{},'dmin',{},'dmax',{},'iLmax',{},'iLrefmax',{}, ...
    'repro',{},'S1',{},'S2',{},'S3',{},'S4',{},'S5',{},'S6',{},'S7',{},'S8',{},'all',{});

fprintf('%-5s %5s %9s %9s %10s %10s %10s %10s %9s %8s %6s\n', ...
    'cond','dTs','PM_disc','GM_disc','max|z|','dip%','S5ms','startOS%','dutyMax','iLmax','verdict');

for delay = [0 1 2]
  for ic = 1:numel(conds)
    c = conds(ic);
    % ---------- discrete frequency domain ----------
    q = struct('L',c.L,'C',220e-6);
    Gv = tf(dual_loop_gain(q, c.R, D.Kci, D.Kpe, D.Kie, D.ff, 'plant'));
    Cs = tf([D.Kpe D.Kie],[1 0]);
    if delay == 0, dly = 1; else, dly = tf(1,[1 zeros(1,delay-1) 0], Ts); end
    Ld = c2d(Cs,Ts,'zoh')*dly*c2d(Gv,Ts,'zoh');
    [pmD,gmD] = margin_fast(Ld, 4000);   % margin_fast returns (pm, gm, wc, info)
    zc = pole(feedback(Ld,1)); mz = max(abs(zc));
    % continuous reference
    [pmC,~] = margin_fast(minreal(Cs*Gv), 4000);

    % ---------- time domain, 3 repeats ----------
    s5v = nan(1,nRep); dipv = nan(1,nRep); osv = nan(1,nRep);
    ssv = nan(1,nRep); dmn = nan(1,nRep); dmxv = nan(1,nRep);
    ilv = nan(1,nRep); irv = nan(1,nRep);
    for ir = 1:nRep
        % load-step run (steady-state init, soft start is irrelevant at 60 ms)
        cf = struct('Vin',c.Vin,'L',c.L,'C',220e-6,'R',c.R,'Vref',12, ...
            'Kci',D.Kci,'Kpe',D.Kpe,'Kie',D.Kie,'ff',D.ff, ...
            'Dmin',D.Dmin,'Dmax',D.Dmax,'Imin',D.Imin,'Imax',D.Imax, ...
            'Tt',D.Tt,'Eclamp',D.Eclamp,'Tss',D.Tss, ...
            'ratio',ratio,'tStep',tStep,'tEnd',0.12,'delaySamples',delay,'nSub',8);
        rr = buck_dual_sim(cf);
        m = step_metrics(rr.t, rr.vC, 12, tStep, 1);
        s5v(ir) = m.settleMs; dipv(ir) = m.dipPct;
        ssv(ir) = (mean(rr.vC(rr.t > 0.11))-12)/12*100;
        post = rr.t >= tStep;
        dmn(ir) = min(rr.d(post)); dmxv(ir) = max(rr.d(post));
        ilv(ir) = max(rr.iL(post)); irv(ir) = max(rr.iLref(post));
        % startup run (from vC = 0, soft start active)
        cs = cf; cs.ratio = 1; cs.tStep = 0.05; cs.tEnd = 0.10; cs.vCinit = 0;
        rs = buck_dual_sim(cs);
        % startup overshoot = peak of vC over the WHOLE startup run
        osv(ir) = (max(rs.vC) - 12)/12*100;
    end
    % reproducibility: rerun once more and compare waveforms
    cf1 = struct('Vin',c.Vin,'L',c.L,'C',220e-6,'R',c.R,'Vref',12, ...
        'Kci',D.Kci,'Kpe',D.Kpe,'Kie',D.Kie,'ff',D.ff,'Dmin',D.Dmin,'Dmax',D.Dmax, ...
        'Imin',D.Imin,'Imax',D.Imax,'Tt',D.Tt,'Eclamp',D.Eclamp,'Tss',D.Tss, ...
        'ratio',ratio,'tStep',tStep,'tEnd',0.12,'delaySamples',delay,'nSub',8);
    ra = buck_dual_sim(cf1); rb = buck_dual_sim(cf1);
    repro = max(abs(ra.vC - rb.vC));
    % report the spread of the three load-step repeats as well
    spread = max(s5v) - min(s5v);

    % ---------- verdicts ----------
    v = struct();
    v.S1 = mz < 1;
    v.S2 = pmD >= STD.PM_min;
    v.S3 = gmD >= STD.GM_min;
    v.S4 = abs(ssv(1)) <= STD.sserr_max;
    v.S5 = isfinite(s5v(1)) && s5v(1) <= STD.recover_max;
    v.S6 = osv(1) <= STD.startup_os_max;
    v.S7 = abs(dipv(1)) <= STD.dip_max;
    v.S8 = dmn(1) >= STD.duty_lo && dmxv(1) <= STD.duty_hi;
    v.all = v.S1&&v.S2&&v.S3&&v.S4&&v.S5&&v.S6&&v.S7&&v.S8 && repro < STD.repro;

    fprintf('%-5s %5d %9.2f %9.2f %10.6f %10.3f %10.4f %10.2f %9.3f %8.2f %6s\n', ...
        c.id, delay, pmD, gmD, mz, dipv(1), s5v(1), osv(1), dmxv(1), ilv(1), ...
        merge(v.all,'PASS','FAIL'));
    if ~v.all
        fprintf('        fails: %s\n', crits(v));
    end
    rows(end+1) = struct('cond',c.id,'delay',delay,'cond_delay',sprintf('%s_d%d',c.id,delay), ...
        'pmC',pmC,'pmD',pmD,'gmD',gmD,'maxAbsZ',mz, ...
        'dip',dipv(1),'s5',s5v(1),'os',osv(1),'sserr',ssv(1), ...
        'dmin',dmn(1),'dmax',dmxv(1),'iLmax',ilv(1),'iLrefmax',irv(1), ...
        'repro',repro,'S1',v.S1,'S2',v.S2,'S3',v.S3,'S4',v.S4,'S5',v.S5, ...
        'S6',v.S6,'S7',v.S7,'S8',v.S8,'all',v.all);
  end
  fprintf('\n');
end

%% ---------- summary ----------
fprintf('================ level B summary ================\n');
for delay = [0 1 2]
    sel = [rows.delay] == delay;
    fprintf('  delay=%d Ts (%d cond) : %d/%d PASS\n', delay, sum(sel), ...
        sum([rows(sel).all]), sum(sel));
end
fprintf('\n  worst-case metrics by delay\n');
fprintf('  %6s %10s %10s %10s %10s %10s\n','dTs','worstPM','worstDip','worstS5','worstOS','max|z|');
for delay = [0 1 2]
    sel = [rows.delay] == delay;
    fprintf('  %6d %10.2f %10.3f %10.4f %10.2f %10.6f\n', delay, ...
        min([rows(sel).pmD]), min([rows(sel).dip]), max([rows(sel).s5]), ...
        max([rows(sel).os]), max([rows(sel).maxAbsZ]));
end

save(fullfile(outDir,'a5_task1_digital.mat'),'rows','D','STD','conds');
fid = fopen(fullfile(outDir,'a5_task1_digital.json'),'w');
fwrite(fid, jsonencode(struct('results',rows,'design',D,'standards',STD)), 'char');
fclose(fid);
fprintf('\nsaved a5_task1_digital.json / .mat\n');

function s = merge(c,a,b)
if c, s = a; else, s = b; end
end

function s = crits(v)
f = {'S1','S2','S3','S4','S5','S6','S7','S8'};
s = '';
for q = 1:numel(f)
    if ~v.(f{q}), s = [s f{q} ' ']; end
end
end
