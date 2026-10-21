function res = boost_b1_task4_switching(outDir)
%BOOST_B1_TASK4_SWITCHING  Part 4: switching-level model, DCM boundary, waveforms.
%
% Three jobs:
%   1. show that the switching model reproduces the average model where the
%      average model is valid (operating point, ripple, load-step response), so
%      that the fast model used for design is trustworthy;
%   2. find the CCM/DCM boundary by measurement and compare it with the analytic
%      value from Part 1;
%   3. show what happens when the model is pushed past that boundary: the AC
%      acceptance must then report UNDETERMINED, never PASS.
%
% The diode constraint is enforced inside boost_sw_sim.m (iL is clamped at zero
% and the period is flagged), which is what makes point 3 possible at all: a model
% that keeps integrating negative current would report a beautiful 48 V while
% being physically meaningless.

if nargin < 1 || isempty(outDir), outDir = getenv('BOOST_OUT'); end
outDir = strrep(outDir,'/',filesep);
here = fileparts(mfilename('fullpath')); addpath(fileparts(here));
addpath(fullfile(fileparts(fileparts(here)),'buck'));
if ~exist(outDir,'dir'), mkdir(outDir); end

p  = boost_params();
d0 = boost_duty_for(p, p.Vref);
r  = boost_ripple(p, d0);
c  = boost_design(p, 'B', 650);
Ts = 1/p.fs;

fprintf('================ Phase 3B.1 Task 4: switching level ================\n');
fprintf('controller B @ %.0f Hz (PM %.1f deg), Td = 1 period, boundary sampling,\n', c.fcActual, c.PM);
fprintf('half-ripple compensation on the sampled current\n\n');

%% ---------- 1) average vs switching ----------
fprintf('--- 1) switching model vs average model ---\n');
oA = struct('ratio',1,'tStep',0.02,'tEnd',0.06,'nSub',300,'nDly',1);
oW = struct('ratio',1,'tStep',0.02,'tEnd',0.06,'nSub',200,'nDly',1);
ra = boost_avg_sim(p, c, oA);
rw = boost_sw_sim(p, c, oW);
ssA = mean(ra.vOut(ra.t > 0.05)); ssW = mean(rw.vOut(rw.t > 0.05));
dILw = mean(rw.iLpeak(rw.tPer > 0.05) - rw.iLvalley(rw.tPer > 0.05));
fprintf('  steady-state vOut : average %.4f V, switching %.4f V (dev %.3f %%)\n', ...
    ssA, ssW, 100*(ssW/ssA-1));
fprintf('  ripple iL         : switching %.4f A, analytic %.4f A (dev %.2f %%)\n', ...
    dILw, r.dIL, 100*(dILw/r.dIL-1));
fprintf('  duty at the setpoint: %.4f (loss-inclusive design value %.4f)\n', ...
    mean(rw.duty(rw.t > 0.05)), d0);

oA2 = oA; oA2.ratio = 1.5; oW2 = oW; oW2.ratio = 1.5;
ra2 = boost_avg_sim(p, c, oA2);
rw2 = boost_sw_sim(p, c, oW2);
sA = step_metrics(ra2.t, ra2.vOut, p.Vref, oA2.tStep, 1);
sW = step_metrics(rw2.t, rw2.vOut, p.Vref, oW2.tStep, 1);
fprintf('  load step 100->150 %%: dip average %.3f %%, switching %.3f %% (dev %.3f pp)\n', ...
    sA.dipPct, sW.dipPct, abs(sA.dipPct-sW.dipPct));
fprintf('                          S5  average %.4f ms, switching %.4f ms\n', ...
    sA.settleMs, sW.settleMs);
fprintf('  => the average model is usable for design; the switching model is what the\n');
fprintf('     acceptance uses, because it is the only one that can say "DCM".\n');
fprintf('  NOTE on the -0.1 %% DC offset: the switching model samples vOut at the period\n');
fprintf('     boundary, which is exactly where the ESR step occurs (the diode current\n');
fprintf('     jumps from iL to 0). Sampling BEFORE the edge regulates the ripple PEAK,\n');
fprintf('     sampling AFTER it regulates the VALLEY -- a %.0f mV (%.2f %%) ambiguity for\n', ...
    1e3*p.ESR*boost_steady(p,d0).iL/(1+p.ESR/p.R), ...
    100*p.ESR*boost_steady(p,d0).iL/(1+p.ESR/p.R)/p.Vref);
fprintf('     ESR=%.0f mOhm. The average model has no such ambiguity, which is the whole\n', p.ESR*1e3);
fprintf('     %.3f %% difference. The acceptance protocol therefore states the convention\n', ...
    100*(ssW/ssA-1));
fprintf('     (pre-edge) instead of pretending the offset is zero.\n');

%% ---------- 2) CCM/DCM boundary by measurement ----------
fprintf('\n--- 2) CCM/DCM boundary ---\n');
fprintf('  analytic: valley reaches 0 at R = %.1f ohm (Iout %.3f A, %.1f %% of rated)\n', ...
    r.Rb, r.Ib, r.IoutFrac*100);
% open loop, fixed duty: sweep the load and look for the first DCM period
cOL = c; cOL.arch = 'A'; cOL.Kp = 0; cOL.Ki = 0; cOL.D0 = d0;
Rs = [50 100 150 170 180 190 200 250 400];
D = struct('R',{},'dcmFrac',{},'iLmin',{},'vOut',{});
fprintf('%8s %10s %10s %10s\n','R ohm','DCM time%','iL min A','vOut V');
for q = 1:numel(Rs)
    pq = p; pq.R = Rs(q);
    rq = boost_sw_sim(pq, cOL, struct('ratio',1,'tStep',1,'tEnd',0.03,'nSub',200,'nDly',1));
    sel = rq.tPer > 0.015;
    fprintf('%8.0f %10.2f %10.4f %10.3f\n', Rs(q), 100*rq.dcmTime/0.03, ...
        min(rq.iL), mean(rq.vOut(rq.t > 0.02)));
    D(end+1) = struct('R',Rs(q),'dcmFrac',100*rq.dcmTime/0.03, ...
        'iLmin',min(rq.iL),'vOut',mean(rq.vOut(rq.t>0.02))); %#ok<AGROW>
end
firstDcm = min([D([D.dcmFrac] > 0.5).R]);
fprintf('  measured: first DCM above R = %.0f ohm; analytic %.0f ohm (%.1f %% difference)\n', ...
    firstDcm, r.Rb, 100*(firstDcm/r.Rb-1));
fprintf('  the difference is expected: the analytic value assumes the small-ripple\n');
fprintf('  triangle and neglects the change of the operating point with load.\n');

%% ---------- 3) what a DCM run does to the closed loop ----------
fprintf('\n--- 3) closed loop near and below the boundary (must be UNDETERMINED) ---\n');
fprintf('%8s %10s %10s %10s %10s | %s\n','R ohm','load %','vOut V','dcm%','S5 ms','verdict');
CC = struct('R',{},'loadPct',{},'vOut',{},'dcm',{},'s5',{},'verdict',{});
for Rq = [48 96 178 250 400]
    pq = p; pq.R = Rq;
    rq = boost_sw_sim(pq, c, struct('ratio',1,'tStep',0.02,'tEnd',0.06,'nSub',200,'nDly',1));
    sm = step_metrics(rq.t, rq.vOut, p.Vref, 0.02, 1);
    dcmPct = 100*rq.dcmTime/0.06;
    if dcmPct > 0.5
        vd = 'UNDETERMINED (DCM)';
    elseif abs(sm.dipPct) < 1 && isfinite(sm.settleMs)
        vd = 'CCM, in band';
    else
        vd = 'CCM, check metrics';
    end
    fprintf('%8.0f %10.1f %10.3f %10.2f %10.4f | %s\n', Rq, 100*p.R/Rq, ...
        mean(rq.vOut(rq.t>0.045)), dcmPct, sm.settleMs, vd);
    CC(end+1) = struct('R',Rq,'loadPct',100*p.R/Rq,'vOut',mean(rq.vOut(rq.t>0.045)), ...
        'dcm',dcmPct,'s5',sm.settleMs,'verdict',vd); %#ok<AGROW>
end
fprintf('  => the CCM-designed controller is not validated in DCM. The runs above are\n');
fprintf('     reported, not graded: the model can now represent DCM (iL is clamped and\n');
fprintf('     flagged), but the DESIGN was not made for it.\n');

%% ---------- 4) waveforms ----------
o3 = struct('ratio',1,'tStep',0.02,'tEnd',0.06,'nSub',400,'nDly',1);
rw3 = boost_sw_sim(p, c, o3);
f = figure('Visible','off','Position',[80 80 1000 640]);
subplot(3,1,1);
m = rw3.t > 0.04 & rw3.t < 0.0402;
plot(rw3.t(m)*1e6, rw3.vOut(m)); grid on; ylabel('Vout');
title(sprintf('steady state, %.0f Hz controller: output ripple %.1f mV', c.fcActual, ...
    1e3*(max(rw3.vOut(m))-min(rw3.vOut(m)))));
subplot(3,1,2);
plot(rw3.t(m)*1e6, rw3.iL(m)); grid on; ylabel('iL A');
title(sprintf('inductor current, %.1f %% ripple (%.2f App)', ...
    100*(max(rw3.iL(m))-min(rw3.iL(m)))/mean(rw3.iL(m)), max(rw3.iL(m))-min(rw3.iL(m))));
subplot(3,1,3);
plot(rw3.t(m)*1e6, rw3.duty(m)); grid on; ylabel('duty'); xlabel('us');
title('applied duty (held per period)');
print(f,'-dpng','-r110',fullfile(outDir,'b1_sw_waveform.png')); close(f);

f = figure('Visible','off','Position',[80 80 1000 420]);
subplot(1,2,1);
oo = o3; oo.ratio = 1.5;
rw4 = boost_sw_sim(p, c, oo);
plot(rw4.t*1e3, rw4.vOut); grid on; xline(oo.tStep*1e3,'k--');
xlabel('ms'); ylabel('Vout'); title('switching: load step 100 -> 150 %');
subplot(1,2,2);
plot(rw4.t*1e3, rw4.iL); grid on; xline(oo.tStep*1e3,'k--');
xlabel('ms'); ylabel('iL A'); title('inductor current');
print(f,'-dpng','-r110',fullfile(outDir,'b1_sw_step.png')); close(f);

res = struct('level','3B.1-Task4','ssAvg',ssA,'ssSw',ssW, ...
    'rippleSw',dILw,'rippleAnalytic',r.dIL, ...
    'dipAvg',sA.dipPct,'dipSw',sW.dipPct,'s5Avg',sA.settleMs,'s5Sw',sW.settleMs, ...
    'RbAnalytic',r.Rb,'RbMeasured',firstDcm,'dcmSweep',D,'closedLoopDcm',CC, ...
    'dcmPeriodsSteady',rw.dcmPeriods, ...
    'note',['switching model enforces diode unidirectional conduction; runs that ' ...
            'enter DCM are reported as UNDETERMINED because the controller was ' ...
            'designed for CCM']);
save(fullfile(outDir,'b1_task4_switching.mat'),'res');
fid = fopen(fullfile(outDir,'b1_task4_switching.json'),'w');
if fid >= 0, fwrite(fid, jsonencode(res), 'char'); fclose(fid); end
fprintf('\nsaved b1_task4_switching.json/.mat/2 png\n');
end
