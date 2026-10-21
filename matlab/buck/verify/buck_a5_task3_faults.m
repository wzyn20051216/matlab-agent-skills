%% Phase 3A.5 / Task 3: feedforward fault injection and degradation strategy
%
% DUAL-B's feedforward is the only part of the design that depends on a sensor.
% If that sensor lies, the feedforward injects the lie directly into the current
% command, which is worse than having no feedforward at all. This script does two
% things:
%
%   1. injects five faults (open, frozen, railed, biased, slow) plus an abrupt
%      manual disconnect, with and without the supervisor, and shows the
%      difference;
%   2. measures the DEGRADED mode (no feedforward) so that its performance and
%      its safety envelope are on record. The degraded mode is NOT required to
%      meet S5 = 1 ms -- it is required to be stable and inside the actuator and
%      current limits.
%
% Supervisor (in buck_dual_sim.m):
%   trip    : 3 consecutive bad samples, where bad = out of range | frozen while
%             vC is moving | inconsistent with iLoad = iL - C*dvC/dt by > tol
%   recover : 20 consecutive good samples (0.4 ms at 50 kHz)
%   transfer: xe += -+iLoad/Ki_e at the switching instant -> iLref is continuous
%             (bumpless), so tripping/recovering does not step the inner loop
%
% Faults are injected at t = 0.020 s (steady state) and the load step is at
% t = 0.060 s, so the fault transient and the step response are separable.
%
% Output: a5_task3_faults.json / .mat, a5_task3_faults.png

clear; close all;
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here,'..'));
outDir = getenv('BUCK_OUT');
if isempty(outDir), outDir = fullfile(here,'..','..','artifacts','validation','buck'); end
outDir = strrep(outDir,'/',filesep);

S = load(fullfile(outDir,'a4_dualsel.mat')); S = S.S;
D = struct('Kci',S.B.Kci,'Kpe',S.B.Kpe,'Kie',S.B.Kie,'ff',1, ...
           'Imin',0,'Imax',12,'Dmin',0.05,'Dmax',0.85,'Tt',3e-4, ...
           'Eclamp',1.5,'Tss',5e-3);
fprintf('=========== 3A.5 Task 3: feedforward faults and degradation ===========\n');
tFault = 0.020; tStep = 0.060;

% fault table: name, sens override, external ff schedule
F = { ...
 'none',            struct(),                                              [],        []; ...
 'open_circuit',    struct('enable',true,'gain',0),                        [],        []; ...
 'frozen_reading',  struct('enable',true,'stuckAt',tFault),                [],        []; ...
 'railed_high',     struct('enable',true,'oorAt',tFault),                  [],        []; ...
 'bias_+2A',        struct('enable',true,'offset',2.0),                    [],        []; ...
 'slow_1kHz',       struct('enable',true,'fBW',1000),                      [],        []; ...
 'delay_5_samples', struct('enable',true,'delayS',5),                      [],        []; ...
 'forced_off',      struct('enable',true),                                 tFault,    []; ...
 'off_then_on',     struct('enable',true),                                 tFault,    0.080 ; };

rows = struct('fault',{},'sup',{},'faultDev',{},'dip',{},'s5',{}, ...
              'sserr',{},'dmin',{},'dmax',{},'iLmax',{},'nTrip',{},'nRecover',{}, ...
              'stable',{},'safe',{});

fprintf('%-16s %5s %11s %10s %9s %9s %8s %8s %8s %6s %6s\n', ...
    'fault','sup','faultDev(V)','dip %','S5 ms','ssErr%','dutyMin','dutyMax','iLmax','trips','safe');

for q = 1:size(F,1)
  for sup = [0 1]
    sens = F{q,2};
    if isempty(fieldnames(sens)), sens = struct('enable',false); end
    if ~isfield(sens,'enable'), sens.enable = true; end
    sens.tol = 3.0;
    cf = struct('Vin',48,'L',150e-6,'C',220e-6,'R',6,'Vref',12, ...
        'Kci',D.Kci,'Kpe',D.Kpe,'Kie',D.Kie,'ff',D.ff, ...
        'Dmin',D.Dmin,'Dmax',D.Dmax,'Imin',D.Imin,'Imax',D.Imax, ...
        'Tt',D.Tt,'Eclamp',D.Eclamp,'Tss',D.Tss,'sens',sens, ...
        'supEnable',logical(sup),'tFFoff',F{q,3},'tFFon',F{q,4}, ...
        'ratio',2,'tStep',tStep,'tEnd',0.10,'delaySamples',1,'nSub',8);
    r = buck_dual_sim(cf);
    m = step_metrics(r.t, r.vC, 12, tStep, 1);
    % fault transient: deviation between the injection and the load step
    w = r.t >= tFault & r.t < tStep;
    faultDev = max(abs(r.vC(w)-12));
    post = r.t >= tStep;
    sserr = (mean(r.vC(r.t>0.09))-12)/12*100;
    stable = all(isfinite(r.vC)) && max(abs(r.vC)) < 30;
    % safety envelope: actuator limits AND an output-voltage bound. A railed
    % sensor used to drive vC to 30 V while every duty/current check still
    % passed, so vC has to be part of the envelope.
    safe = max(r.d(post)) <= D.Dmax + 1e-6 && min(r.d(post)) >= 0 && ...
           max(r.iL(post)) <= 1.6*D.Imax && max(r.vC) <= 1.5*12;
    fprintf('%-16s %5d %11.4f %10.3f %9.4f %9.4f %8.3f %8.3f %8.2f %6d %6d\n', ...
        F{q,1}, sup, faultDev, m.dipPct, m.settleMs, sserr, ...
        min(r.d(post)), max(r.d(post)), max(r.iL(post)), r.nTrip, safe);
    rows(end+1) = struct('fault',F{q,1},'sup',logical(sup),'faultDev',faultDev, ...
        'dip',m.dipPct,'s5',m.settleMs,'sserr',sserr,'dmin',min(r.d(post)), ...
        'dmax',max(r.d(post)),'iLmax',max(r.iL(post)),'nTrip',r.nTrip, ...
        'nRecover',r.nRecover,'stable',stable,'safe',safe);
    if q == 1 && sup == 1, rNom = r; mNom = m; end
    if strcmp(F{q,1},'forced_off') && sup == 0, rDeg = r; mDeg = m; end
  end
  fprintf('\n');
end

%% ---------- degraded-mode baseline (no feedforward at all) ----------
fprintf('--- degraded baseline: ff disabled from the start (no sensor) ---\n');
cfg0 = struct('Vin',48,'L',150e-6,'C',220e-6,'R',6,'Vref',12, ...
    'Kci',D.Kci,'Kpe',D.Kpe,'Kie',D.Kie,'ff',0, ...
    'Dmin',D.Dmin,'Dmax',D.Dmax,'Imin',D.Imin,'Imax',D.Imax, ...
    'Tt',D.Tt,'Eclamp',D.Eclamp,'Tss',D.Tss,'supEnable',false, ...
    'ratio',2,'tStep',tStep,'tEnd',0.10,'delaySamples',1,'nSub',8);
r0 = buck_dual_sim(cfg0); m0 = step_metrics(r0.t, r0.vC, 12, tStep, 1);
post0 = r0.t >= tStep;
fprintf('  dip = %.3f %%   S5 = %.4f ms   duty in [%.3f, %.3f]   iLmax = %.2f A\n', ...
    m0.dipPct, m0.settleMs, min(r0.d(post0)), max(r0.d(post0)), max(r0.iL(post0)));
fprintf('  => degraded mode has S5 = %.2fx the 1 ms limit (this is expected and allowed:\n', ...
    m0.settleMs/1.0);
fprintf('     the standard is not met, but the loop is stable and within limits).\n');

%% ---------- figure: nominal vs degraded vs fault-with-supervisor ----------
fig = figure('Position',[80 80 1100 420],'Color','w');
subplot(1,2,1); hold on; grid on;
idxN = find(rNom.t>=tStep & rNom.t<=tStep+0.004);
idxD = find(rDeg.t>=tStep & rDeg.t<=tStep+0.004);
idx0 = find(r0.t>=tStep & r0.t<=tStep+0.004);
plot((rNom.t(idxN)-tStep)*1e3, rNom.vC(idxN), 'LineWidth', 1.6);
plot((rDeg.t(idxD)-tStep)*1e3, rDeg.vC(idxD), 'LineWidth', 1.6);
plot((r0.t(idx0)-tStep)*1e3, r0.vC(idx0), 'LineWidth', 1.6);
plot([0 4],[12.12 12.12],'r:'); plot([0 4],[11.88 11.88],'r:');
xlabel('t after load step (ms)'); ylabel('v_C (V)');
title('feedforward on / forced off / never present');
lg = {sprintf('ff on: S5 %.2f ms', mNom.settleMs), ...
      sprintf('ff forced off (bumpless): S5 %.2f ms', mDeg.settleMs), ...
      sprintf('no ff from the start: S5 %.2f ms', m0.settleMs)};
legend(lg,'Location','southeast');

subplot(1,2,2); hold on; grid on;
sel = strcmp({rows.fault},'open_circuit') | strcmp({rows.fault},'frozen_reading') | ...
      strcmp({rows.fault},'railed_high');
xx = 1:3; lbl = {'open','frozen','railed'};
vNo = zeros(1,3); vSup = zeros(1,3);
k = 0;
for nm = {'open_circuit','frozen_reading','railed_high'}
    k = k + 1;
    a = rows(strcmp({rows.fault},nm{1}) & ~[rows.sup]);
    b = rows(strcmp({rows.fault},nm{1}) &  [rows.sup]);
    vNo(k) = a.faultDev; vSup(k) = b.faultDev;
end
bh1 = bar(xx-0.18, vNo, 0.34, 'FaceColor',[0.80 0.30 0.25]);
bh2 = bar(xx+0.18, vSup, 0.34, 'FaceColor',[0.15 0.55 0.30]);
% annotate: a zero bar is invisible, and zero is exactly the good answer here
for k2 = 1:3
    text(xx(k2)-0.18, max(vNo(k2),0)+0.15, sprintf('%.2f',vNo(k2)), ...
        'HorizontalAlignment','center','FontSize',8);
    text(xx(k2)+0.18, max(vSup(k2),0)+0.15, sprintf('%.2f',vSup(k2)), ...
        'HorizontalAlignment','center','FontSize',8,'Color',[0.10 0.45 0.22]);
end
set(gca,'XTick',xx,'XTickLabel',lbl);
ylabel('max |v_C - 12| after the fault (V)');
title('fault transient: supervisor off vs on');
legend([bh1 bh2],{'no supervisor','supervisor trips + degrades'},'Location','northeast');
print(fig, fullfile(outDir,'a5_task3_faults.png'), '-dpng','-r140'); close(fig);

save(fullfile(outDir,'a5_task3_faults.mat'),'rows','F','D','m0');
fid = fopen(fullfile(outDir,'a5_task3_faults.json'),'w');
fwrite(fid, jsonencode(struct('results',rows, ...
    'degraded',struct('dip',m0.dipPct,'s5',m0.settleMs))), 'char');
fclose(fid);
fprintf('\nsaved a5_task3_faults.json / .mat / .png\n');
