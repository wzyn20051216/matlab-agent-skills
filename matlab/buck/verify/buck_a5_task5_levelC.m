function R = buck_a5_task5_levelC(outDir)
%BUCK_A5_TASK5_LEVELC  Level C acceptance: digital average model + non-ideal load-current sensor.
%
% Level definitions used throughout Phase 3A.5 (they are NOT interchangeable):
%   A : ideal continuous average model            (Phase 3A.4, 84 Simulink runs)
%   B : ideal discrete-time average model         (buck_dual_sim, 1 sample delay)
%   C : discrete average model + sensor chain     (THIS FILE)
%   D : switching-level model                     (buck_a5_task5_levelD.m)
%   E : real hardware                             (SKIPPED - no hardware)
%
% The sensor parameter set below is an ENGINEERING ASSUMPTION chosen from the
% Phase 3A.5 Task-2 sensitivity sweep. It is not taken from any datasheet:
%   bandwidth 10 kHz   (>= 5 kHz needed: at 1 kHz S5 already exceeds 1 ms)
%   transport delay 1 sample (2 samples already fails S5 = 1.04 ms)
%   gain error +2 %    (a 2 % error only costs 0.14 ms; the outer integrator
%                       removes the resulting steady-state error)
%   zero offset 0.1 A  (measured to have NO effect: the integrator absorbs it)
%   noise sigma 0.02 A (0.2 A sigma breaks it)
%   ADC LSB 0.02 A     (measured to have almost no effect)
%
% Every case runs 3 times. S1-S8 thresholds are the original ones, unchanged.

here = fileparts(mfilename('fullpath'));
addpath(fileparts(here));            % matlab/buck (dual_loop_gain, buck_dual_sim, ...)
if nargin < 1 || isempty(outDir), outDir = getenv('BUCK_OUT'); end
outDir = strrep(outDir,'/',filesep);
if ~exist(outDir,'dir'), mkdir(outDir); end

Vref = 12; Ts = 20e-6;
P0 = struct('Vin',48,'L',150e-6,'C',220e-6,'R',6,'Vref',Vref,'fs',50e3);
% DUAL-B final tuning from Phase 3A.4
Kci = 6; Kpe = 1.8; Kie = 4000;

conds = [ ...
    struct('id','C1','Vin',48,'R',6,  'L',150e-6,'desc','nominal 48V/6ohm')
    struct('id','C2','Vin',42,'R',6,  'L',150e-6,'desc','Vin -12.5%')
    struct('id','C3','Vin',54,'R',6,  'L',150e-6,'desc','Vin +12.5%')
    struct('id','C4','Vin',48,'R',12, 'L',150e-6,'desc','light load 12ohm')
    struct('id','C5','Vin',48,'R',3,  'L',150e-6,'desc','heavy load 3ohm')
    struct('id','C6','Vin',54,'R',3,  'L',150e-6,'desc','Vin+12.5% & 3ohm')
    struct('id','C7','Vin',48,'R',6,  'L',195e-6,'desc','L +30%') ];

STD = struct('PM_min',50,'GM_min',6,'sserr_max',0.1,'s5_max',1.0, ...
             'os_max',5,'dip_max',12,'dlo',0.05,'dhi',0.85);

sensC = struct('enable',true,'fBW',10e3,'delayS',1,'gain',1.02,'offset',0.1, ...
               'sigma',0.02,'lsb',0.02,'seed',7,'tol',3.0);

fprintf('=========== LEVEL C acceptance: digital average model + non-ideal sensor ===========\n');
fprintf('sensor: fBW=%.0f Hz, delay=%d sample, gain=%.2f, offset=%.2f A, sigma=%.2f A, LSB=%.3f A\n', ...
    sensC.fBW, sensC.delayS, sensC.gain, sensC.offset, sensC.sigma, sensC.lsb);
fprintf('thresholds: PM>=%g GM>=%g dB |ssErr|<=%g%% S5<=%g ms OS<=%g%% |dip|<=%g%% duty in [%g,%g]\n\n', ...
    STD.PM_min, STD.GM_min, STD.sserr_max, STD.s5_max, STD.os_max, STD.dip_max, STD.dlo, STD.dhi);

% Preallocation must carry EVERY field the records will have, otherwise
% R(end+1) = rec fails with "subscripted assignment between dissimilar
% structures" (hit in this file).
R = struct('cond',{},'rep',{},'pmD',{},'gmD',{},'dipPct',{},'settleMs',{}, ...
    'ssErr',{},'osPct',{},'dMin',{},'dMax',{},'trips',{},'maxDev',{}, ...
    'pass',{},'flags',{},'verdict',{});

for ic = 1:numel(conds)
    c = conds(ic);
    % --- discrete-loop margins (analytical, sensor-independent) ---
    q = P0; q.Vin = c.Vin; q.L = c.L; q.R = c.R;
    Gv = tf(dual_loop_gain(q, c.R, Kci, Kpe, Kie, 1, 'plant'));
    Cs = tf([Kpe Kie],[1 0]);                        % PI on the voltage error
    Ld = c2d(Cs,Ts,'zoh') * tf(1,[1 0],Ts) * c2d(Gv,Ts,'zoh');
    [pmD, gmD] = margin_fast(Ld, 4000);
    clp = pole(feedback(Ld,1)); stable = max(abs(clp)) < 1;

    for rep = 1:3
        cfg = struct('Vin',c.Vin,'L',c.L,'C',P0.C,'R',c.R,'Vref',Vref, ...
            'Kci',Kci,'Kpe',Kpe,'Kie',Kie,'ff',1, ...
            'Dmin',0.05,'Dmax',0.85,'Imin',0,'Imax',12, ...
            'Tt',3e-4,'Eclamp',1.5,'Tss',5e-3, ...
            'ratio',2,'tStep',0.06,'tEnd',0.12,'delaySamples',1,'nSub',8);
        cfg.sens = sensC;
        % ---- startup run (no load step) for S6 ----
        cs = cfg; cs.ratio = 1; cs.tEnd = 0.06; cs.tStep = 1;
        rs = buck_dual_sim(cs);
        osPct = (max(rs.vC) - Vref)/Vref*100;
        % ---- load-step run ----
        rl = buck_dual_sim(cfg);
        m = step_metrics(rl.t, rl.vC, Vref, 0.06, 1);
        post = rl.t >= 0.06;
        ssErr = (mean(rl.vC(rl.t > 0.11)) - Vref)/Vref*100;
        rec = struct('cond',c.id,'rep',rep,'pmD',pmD,'gmD',gmD, ...
            'dipPct',m.dipPct,'settleMs',m.settleMs,'ssErr',ssErr, ...
            'osPct',osPct,'dMin',min(rl.d(post)),'dMax',max(rl.d(post)), ...
            'trips',rl.nTrip,'maxDev',NaN,'pass',false,'flags',false(1,8),'verdict','');

        okS1 = stable;
        okS2 = pmD >= STD.PM_min;
        okS3 = isinf(gmD) || gmD >= STD.GM_min;
        okS4 = abs(ssErr) <= STD.sserr_max;
        okS5 = isfinite(m.settleMs) && m.settleMs <= STD.s5_max;
        okS6 = osPct <= STD.os_max;
        okS7 = abs(m.dipPct) <= STD.dip_max;
        okS8 = rec.dMin >= STD.dlo && rec.dMax <= STD.dhi;
        rec.pass = okS1&&okS2&&okS3&&okS4&&okS5&&okS6&&okS7&&okS8;
        rec.flags = [okS1 okS2 okS3 okS4 okS5 okS6 okS7 okS8];
        rec.verdict = ternary(rec.pass,'PASS','FAIL');
        R(end+1) = rec; %#ok<AGROW>
        fprintf('%s rep%d : PMd=%6.2f GMd=%6.2f S5=%7.4f ms dip=%7.3f%% OS=%5.2f%% ssErr=%+7.4f%% duty=[%.3f,%.3f] trips=%d -> %s\n', ...
            c.id, rep, pmD, gmD, m.settleMs, m.dipPct, osPct, ssErr, ...
            rec.dMin, rec.dMax, rl.nTrip, rec.verdict);
    end
    % S9 reproducibility across the 3 repeats
    idx = find(strcmp({R.cond}, c.id));
    dev = max(abs([R(idx).settleMs] - R(idx(1)).settleMs));
    for q2 = idx, R(q2).maxDev = dev; end
    if ~(dev < 1e-9)
        for q2 = idx, R(q2).pass = false; R(q2).verdict = 'FAIL'; end
        fprintf('   [S9] repeat deviation %.3e ms -> FAIL\n', dev);
    end
end

% ---------- summary ----------
fprintf('\n---- Level C summary ----\n');
cids = {conds.id};
np = 0;
for ic = 1:numel(cids)
    isC = strcmp({R.cond}, cids{ic});                % restrict to this condition
    sel = isC & strcmp({R.verdict},'PASS');
    % all(sel) over the WHOLE record vector is always false (other conditions are
    % false) -- the count must be restricted to isC first.
    if nnz(sel) == nnz(isC), np = np + 1; end
    fprintf('  %s : %d/%d repeats PASS\n', cids{ic}, nnz(sel), nnz(isC));
end
fprintf('  => %d/7 conditions fully PASS at Level C\n', np);

res = struct('level','C','sensor',sensC,'std',STD,'records',R, ...
    'nPassConditions',np,'levels',{{'A','B','C','D','E'}}, ...
    'note','Level C = discrete average model + modelled sensor chain; NOT a switching or hardware result');
save(fullfile(outDir,'a5_levelC.mat'),'res');
txt = jsonencode(res);
fid = fopen(fullfile(outDir,'a5_levelC.json'),'w');
if fid >= 0, fwrite(fid, txt, 'char'); fclose(fid); end
fprintf('saved a5_levelC.mat/.json\n');
end

function s = ternary(c,a,b)
if c, s = a; else, s = b; end
end
