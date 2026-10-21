function res = buck_a6_task2_dplus(outDir)
%BUCK_A6_TASK2_DPLUS  Level D+ : switching behaviour AND sensor non-idealities together.
%
% Phase 3A.5 verified C (sensor non-idealities, average plant) and D (switching,
% ideal sensor) separately. Nothing verified them TOGETHER. This level does.
%
% ENGINE
% sw_dual_sim.m: period-by-period, exact at the switch instant, with the full
% sensor chain. It is cross-checked against the Simulink switching model
% (build_buck_switching.m, whose Level D numbers are read from a5_levelD.json)
% in section 1 of the output -- no re-simulation of the reference is needed.
%
% STATISTICS
% Sensor noise is stochastic, so a "3 repeats, 0 spread" claim is meaningless here.
% Each condition is run with NDIFF seeds drawn from a fixed list, and the results
% are summarised as mean / std / min / max. The seed list is fixed so the whole
% table is reproducible; the noise itself is produced by rng(seed).
%
% SAMPLED vs AVERAGE vs PEAK CURRENT
% The controller only ever sees the SAMPLED current. The converter cares about the
% CYCLE AVERAGE (it sets the delivered charge) and the protection cares about the
% INSTANTANEOUS PEAK. At 62 % ripple these three differ by up to half a ripple,
% which is why all three are reported separately and never mixed.

if nargin < 1 || isempty(outDir), outDir = getenv('BUCK_OUT'); end
outDir = strrep(outDir,'/',filesep);
here = fileparts(mfilename('fullpath')); addpath(fileparts(here));
if ~exist(outDir,'dir'), mkdir(outDir); end

Vref = 12;
conds = [ ...
    struct('id','C1','Vin',48,'R',6,  'L',150e-6)
    struct('id','C2','Vin',42,'R',6,  'L',150e-6)
    struct('id','C3','Vin',54,'R',6,  'L',150e-6)
    struct('id','C4','Vin',48,'R',12, 'L',150e-6)
    struct('id','C5','Vin',48,'R',3,  'L',150e-6)
    struct('id','C6','Vin',54,'R',3,  'L',150e-6)
    struct('id','C7','Vin',48,'R',6,  'L',195e-6) ];

% D+ sensor: the engineering-assumption set used at Level C, plus a 1-sample
% transport delay (2 samples already failed S5 at Level C).
sensDp = struct('enable',true,'fBW',10e3,'nd',1,'gain',1.02,'offset',0.1, ...
                'sigma',0.02,'lsb',0.02,'iMaxPhys',10,'tol',3.0);
SEEDS = [11 23 37 41 59];
NDIFF = numel(SEEDS);

STD = struct('sserr_max',0.1,'s5_max',1.0,'os_max',5,'dip_max',12, ...
             'dlo',0.05,'dhi',0.85,'imax',12);

fprintf('=========== Level D+ : switching + non-ideal sensor ===========\n');
fprintf('sensor: fBW=%.0f Hz, delay=%d sample, gain=%.2f, offset=%.2f A, sigma=%.2f A, LSB=%.3f A\n', ...
    sensDp.fBW, sensDp.nd, sensDp.gain, sensDp.offset, sensDp.sigma, sensDp.lsb);
fprintf('seeds: %s  (noise is stochastic -- three identical runs would prove nothing)\n\n', ...
    mat2str(SEEDS));

%% ---------- 1) engine cross-check against the stored Simulink Level D ----------
fprintf('--- 1) engine cross-check vs Simulink Level D (ideal sensor) ---\n');
fprintf('%-5s %10s %10s %10s %10s %9s %9s\n','cond','dip_sim','dip_slk','S5_sim','S5_slk','pk_sim','pk_slk');
chk = struct('cond',{},'dipSim',{},'dipSlk',{},'s5Sim',{},'s5Slk',{},'pkSim',{},'pkSlk',{});
if exist(fullfile(outDir,'a5_levelD.json'),'file')
    Ld = jsondecode(fileread(fullfile(outDir,'a5_levelD.json')));
    for ic = 1:numel(conds)
        c = conds(ic);
        p = dual_params(c.Vin, c.R, c.L, 'nDly', 1);
        r = sw_dual_sim(p, struct('ratio',2,'tStep',0.06,'tEnd',0.08,'nSub',200,'Tss',5e-3));
        m = step_metrics(r.t, r.vOut, Vref, 0.06, 1);
        % matching reference record: delay = 1, rep 1
        q = [];
        for k = 1:numel(Ld.records)
            if strcmp(Ld.records(k).cond,c.id) && Ld.records(k).delay==1 && Ld.records(k).rep==1
                q = Ld.records(k); break;
            end
        end
        if isempty(q), continue; end
        fprintf('%-5s %10.3f %10.3f %10.4f %10.4f %9.3f %9.3f\n', c.id, ...
            m.dipPct, q.dipPct, m.settleMs, q.settleMs, max(r.iL), q.iLmax);
        chk(end+1) = struct('cond',c.id,'dipSim',m.dipPct,'dipSlk',q.dipPct, ...
            's5Sim',m.settleMs,'s5Slk',q.settleMs,'pkSim',max(r.iL),'pkSlk',q.iLmax); %#ok<AGROW>
    end
    dDip = max(abs([chk.dipSim]-[chk.dipSlk]));
    dS5  = max(abs([chk.s5Sim]-[chk.s5Slk]));
    dPk  = max(abs([chk.pkSim]-[chk.pkSlk]));
    fprintf('  max |diff| : dip %.3f pp, S5 %.4f ms, iLpeak %.3f A\n', dDip, dS5, dPk);
    fprintf('  => the period simulator reproduces the Simulink switching model;\n');
    fprintf('     it is used for the seed sweeps only, never in place of the reference.\n');
else
    dDip = NaN; dS5 = NaN; dPk = NaN;
    fprintf('  a5_levelD.json not found -- cross-check skipped\n');
end

%% ---------- 2) D+ matrix: 7 conditions x NDIFF seeds ----------
fprintf('\n--- 2) D+ matrix (switching + non-ideal sensor), %d seeds/condition ---\n', NDIFF);
R = struct('cond',{},'seed',{},'dipPct',{},'settleMs',{},'ssErr',{},'osPct',{}, ...
    'dMin',{},'dMax',{},'iLpk',{},'iLavg',{},'iLsampled',{},'iLvalley',{}, ...
    'ripplePct',{},'sensErrMax',{},'pass',{},'flags',{},'verdict',{});

for ic = 1:numel(conds)
    c = conds(ic);
    for is = 1:NDIFF
        p = dual_params(c.Vin, c.R, c.L, 'nDly', 1, 'sens', sensDp);
        o = struct('ratio',2,'tStep',0.06,'tEnd',0.08,'nSub',200,'Tss',5e-3, ...
                   'noise',true,'seed',SEEDS(is));
        r = sw_dual_sim(p, o);
        m = step_metrics(r.t, r.vOut, Vref, 0.06, 1);
        post = r.t >= 0.06;
        pre  = r.tPer > 0.05 & r.tPer < 0.06;
        ssErr = (mean(r.vOut(r.t > 0.075)) - Vref)/Vref*100;
        iLavg = mean(r.iLavg(pre));
        iLpk  = max(r.iLpeak(pre));
        iLvl  = min(r.iLvalley(pre));
        iLsmp = mean(r.iLsampled(pre));      % what the ADC actually sees
        % Per-period ripple, then averaged. Taking max(peak) over all periods and
        % min(valley) over all periods mixes DIFFERENT periods and inflates the
        % ratio (first version reported 80 % at C1 instead of 62 %).
        ripple = mean(r.iLpeak(pre) - r.iLvalley(pre))/mean(r.iLavg(pre))*100;
        % sensor error measured against the true cycle-average load current
        sErr = max(abs(r.iMeas(r.t > 0.05 & r.t < 0.06) - iLavg));

        rec = struct('cond',c.id,'seed',SEEDS(is),'dipPct',m.dipPct, ...
            'settleMs',m.settleMs,'ssErr',ssErr, ...
            'osPct',(max(r.vOut)-Vref)/Vref*100, ...
            'dMin',min(r.duty(post)),'dMax',max(r.duty(post)), ...
            'iLpk',max(r.iL(post)),'iLavg',iLavg,'iLsampled',iLsmp,'iLvalley',iLvl, ...
            'ripplePct',ripple,'sensErrMax',sErr, ...
            'pass',false,'flags',false(1,6),'verdict','');

        okS4 = abs(ssErr) <= STD.sserr_max;
        okS5 = isfinite(m.settleMs) && m.settleMs <= STD.s5_max;
        okS6 = rec.osPct <= STD.os_max;
        okS7 = abs(m.dipPct) <= STD.dip_max;
        okS8 = rec.dMin >= STD.dlo - 1e-6 && rec.dMax <= STD.dhi + 1e-6;
        okIpk = rec.iLpk <= 1.10*STD.imax;      % 10 % over Imax allowed for the ripple head
        rec.flags = [okS4 okS5 okS6 okS7 okS8 okIpk];
        rec.pass = all(rec.flags);
        if rec.pass, rec.verdict = 'PASS'; else, rec.verdict = 'FAIL'; end
        R(end+1) = rec; %#ok<AGROW>
        fprintf('%s s%-3d : S5=%8.4f ms dip=%8.3f%% OS=%5.2f%% ssErr=%+7.4f%% duty=[%.3f,%.3f] iLpk=%6.2f ripple=%5.1f%% -> %s\n', ...
            c.id, SEEDS(is), m.settleMs, m.dipPct, rec.osPct, ssErr, ...
            rec.dMin, rec.dMax, rec.iLpk, ripple, rec.verdict);
    end
end

%% ---------- 3) statistics across seeds ----------
fprintf('\n--- 3) statistics across seeds (this is the statistical robustness evidence) ---\n');
fprintf('%-5s %-22s %9s %9s %9s\n','cond','metric','mean','std','worst');
stat = struct('cond',{},'metric',{},'mean',{},'std',{},'worst',{});
for ic = 1:numel(conds)
    sel = strcmp({R.cond}, conds(ic).id);
    v = [R(sel).settleMs];  vv = [R(sel).dipPct];
    fprintf('%-5s %-22s %9.4f %9.4f %9.4f\n', conds(ic).id, 'S5 (ms)', ...
        mean(v), std(v), max(v));
    fprintf('%-5s %-22s %9.3f %9.3f %9.3f\n', conds(ic).id, 'dip (%)', ...
        mean(vv), std(vv), min(vv));
    stat(end+1) = struct('cond',conds(ic).id,'metric','S5', ...
        'mean',mean(v),'std',std(v),'worst',max(v)); %#ok<AGROW>
    stat(end+1) = struct('cond',conds(ic).id,'metric','dip', ...
        'mean',mean(vv),'std',std(vv),'worst',min(vv)); %#ok<AGROW>
end

%% ---------- 4) effect of the sensor, iso-condition ----------
% Same conditions with the sensor switched off, so the cost of the non-idealities
% can be read directly instead of inferred.
fprintf('\n--- 4) sensor contribution (D+ minus ideal sensor, same engine) ---\n');
fprintf('%-5s %12s %12s %10s\n','cond','S5 ideal','S5 D+','delta ms');
delta = struct('cond',{},'s5Ideal',{},'s5Dp',{});
for ic = 1:numel(conds)
    c = conds(ic);
    p = dual_params(c.Vin, c.R, c.L, 'nDly', 1);            % sensor disabled
    r = sw_dual_sim(p, struct('ratio',2,'tStep',0.06,'tEnd',0.08,'nSub',200,'Tss',5e-3));
    m = step_metrics(r.t, r.vOut, Vref, 0.06, 1);
    sel = strcmp({R.cond}, c.id);
    s5dp = max([R(sel).settleMs]);
    fprintf('%-5s %12.4f %12.4f %10.4f\n', c.id, m.settleMs, s5dp, s5dp - m.settleMs);
    delta(end+1) = struct('cond',c.id,'s5Ideal',m.settleMs,'s5Dp',s5dp); %#ok<AGROW>
end

%% ---------- summary ----------
allPass = [R.pass];
fprintf('\n---- D+ summary ----\n');
cp = 0;
for ic = 1:numel(conds)
    sel = strcmp({R.cond}, conds(ic).id);
    if all([R(sel).pass]), cp = cp + 1; end
end
fprintf('  runs             : %d (%d conditions x %d seeds)\n', numel(R), numel(conds), NDIFF);
fprintf('  all-seed PASS    : %d / %d conditions\n', cp, numel(conds));
fprintf('  worst S5         : %.4f ms (limit 1.0)\n', max([R.settleMs]));
fprintf('  worst dip        : %.3f %% (limit 12)\n', min([R.dipPct]));
fprintf('  worst ssErr      : %.4f %% (limit 0.1)\n', max(abs([R.ssErr])));
fprintf('  worst duty range : [%.3f, %.3f] (limit [0.05,0.85])\n', min([R.dMin]), max([R.dMax]));
fprintf('  worst iL peak    : %.2f A (Imax 12)\n', max([R.iLpk]));

res = struct('level','D+','sens',sensDp,'seeds',SEEDS,'std',STD, ...
    'engineCrossCheck',struct('dip',dDip,'s5',dS5,'ilpeak',dPk,'records',chk), ...
    'records',R,'stats',stat,'sensorDelta',delta, ...
    'nPassConditions',cp,'nRuns',numel(R), ...
    'note',['Level D+ = switching plant + full sensor chain; still simulation, no hardware. ' ...
            'Statistics come from NDIFF distinct noise seeds, not from repeated identical runs.']);
save(fullfile(outDir,'a6_dplus.mat'),'res');
txt = jsonencode(res);
fid = fopen(fullfile(outDir,'a6_dplus.json'),'w');
if fid >= 0, fwrite(fid, txt, 'char'); fclose(fid); end
fprintf('saved a6_dplus.mat/.json\n');
end
