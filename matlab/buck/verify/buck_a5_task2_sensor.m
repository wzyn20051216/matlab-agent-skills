%% Phase 3A.5 / Task 2: load-current sensor non-ideality sensitivity
%
% DUAL-B's feedforward needs a MEASURED load current. Every parameter swept here
% is an ENGINEERING ASSUMPTION invented for this study -- none is taken from a
% real sensor datasheet. The purpose is to find how good the measurement has to
% be, not to model a specific part.
%
% Sensor chain (buck_dual_sim.m):
%   anti-alias/bandwidth pole -> transport delay -> gain error -> zero offset
%   -> Gaussian noise -> ADC quantization
%
% Two conditions are used because they bracket the problem:
%   C1  6 -> 3 ohm   (dI = 2 A, the nominal step)
%   C5  3 -> 1.5 ohm (dI = 4 A, the worst S7 case)
%
% The supervisor is DISABLED for this sweep (cfg.supEnable = false) so that what
% is measured is the raw sensor degradation, not the supervisor's reaction to
% it. Task 3 sweeps the supervisor separately.
%
% Output: a5_task2_sensor.json / .mat, a5_task2_sensor.png

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
Ts = 1/50e3; tStep = 0.06;
fprintf('=========== 3A.5 Task 2: sensor sensitivity (level C) ===========\n');
fprintf('DUAL-B: Kci=%.2f Kp_e=%.2f Ki_e=%.0f ; fs=50 kHz (Ts=%.0f us)\n', ...
    D.Kci, D.Kpe, D.Kie, Ts*1e6);
fprintf('reference S5 (ideal sensor, 1 Ts delay, C1) = 0.140 ms = %.2f switching periods\n\n', ...
    0.140e-3/Ts);

conds = [struct('id','C1','Vin',48,'R',6,'L',150e-6)
         struct('id','C5','Vin',48,'R',3,'L',150e-6)];

rows = struct('sweep',{},'param',{},'value',{},'cond',{}, ...
              's5',{},'dip',{},'dmax',{},'iLmax',{},'ok5',{},'ok7',{});
sweeps = { ...
  'bandwidth_Hz',  {inf, 20000, 10000, 5000, 2000, 1000, 500, 200}, ...
  'sensor_delay_samples', {0, 1, 2, 3}, ...
  'gain_error',    {1.0, 1.02, 1.05, 1.10, 1.20, 0.95, 0.90, 0.80}, ...
  'zero_offset_A', {0, 0.05, 0.1, 0.25, 0.5, 1.0}, ...
  'noise_sigma_A', {0, 0.02, 0.05, 0.1, 0.2, 0.5}, ...
  'adc_lsb_A',     {0, 0.005, 0.01, 0.02, 0.05, 0.1} };

fprintf('%-22s %8s %-4s %10s %10s %9s %8s %8s\n', ...
    'sweep','value','cond','S5 ms','dip %','dutyMax','S5 ok','S7 ok');
% sweeps is a flat cell {name1, vals1, name2, vals2, ...}: walk it in pairs
for si = 1:2:numel(sweeps)
    name = sweeps{si};
    vals = sweeps{si+1};
    for vi = 1:numel(vals)
        v = vals{vi};
        for ic = 1:numel(conds)
            c = conds(ic);
            sens = struct('enable',true,'fBW',inf,'delayS',0,'gain',1, ...
                          'offset',0,'sigma',0,'lsb',0,'seed',7,'tol',1e9);
            switch name
                case 'bandwidth_Hz',            sens.fBW = v;
                case 'sensor_delay_samples',    sens.delayS = v;
                case 'gain_error',              sens.gain = v;
                case 'zero_offset_A',           sens.offset = v;
                case 'noise_sigma_A',           sens.sigma = v;
                case 'adc_lsb_A',               sens.lsb = v;
            end
            cf = struct('Vin',c.Vin,'L',c.L,'C',220e-6,'R',c.R,'Vref',12, ...
                'Kci',D.Kci,'Kpe',D.Kpe,'Kie',D.Kie,'ff',1, ...
                'Dmin',D.Dmin,'Dmax',D.Dmax,'Imin',D.Imin,'Imax',D.Imax, ...
                'Tt',D.Tt,'Eclamp',D.Eclamp,'Tss',D.Tss,'sens',sens, ...
                'supEnable',false, ...
                'ratio',2,'tStep',tStep,'tEnd',0.10,'delaySamples',1,'nSub',8);
            r = buck_dual_sim(cf);
            m = step_metrics(r.t, r.vC, 12, tStep, 1);
            post = r.t >= tStep;
            ok5 = isfinite(m.settleMs) && m.settleMs <= 1.0;
            ok7 = abs(m.dipPct) <= 12;
            fprintf('%-22s %8.4g %-4s %10.4f %10.3f %9.3f %8d %8d\n', ...
                name, v, c.id, m.settleMs, m.dipPct, max(r.d(post)), ok5, ok7);
            rows(end+1) = struct('sweep',name,'param',name,'value',v,'cond',c.id, ...
                's5',m.settleMs,'dip',m.dipPct,'dmax',max(r.d(post)), ...
                'iLmax',max(r.iL(post)),'ok5',ok5,'ok7',ok7);
        end
    end
    fprintf('\n');
end

%% ---------- composite "realistic" sensor ----------
fprintf('--- composite realistic sensor (assumed, not a datasheet) ---\n');
comp = [ ...
    struct('id','S-ideal',  'fBW',inf,  'delayS',0,'gain',1,   'offset',0,   'sigma',0,   'lsb',0)
    struct('id','S-good',   'fBW',20000,'delayS',0,'gain',1.01,'offset',0.02,'sigma',0.02,'lsb',0.005)
    struct('id','S-mid',    'fBW',5000, 'delayS',1,'gain',1.02,'offset',0.05,'sigma',0.05,'lsb',0.01)
    struct('id','S-poor',   'fBW',1000, 'delayS',2,'gain',1.05,'offset',0.15,'sigma',0.10,'lsb',0.05) ];
fprintf('%-10s %-4s %10s %10s %9s %8s %8s\n','config','cond','S5 ms','dip %','dutyMax','S5 ok','S7 ok');
for q = 1:numel(comp)
    for ic = 1:numel(conds)
        c = conds(ic);
        sens = struct('enable',true,'fBW',comp(q).fBW,'delayS',comp(q).delayS, ...
            'gain',comp(q).gain,'offset',comp(q).offset,'sigma',comp(q).sigma, ...
            'lsb',comp(q).lsb,'seed',7,'tol',1e9);
        cf = struct('Vin',c.Vin,'L',c.L,'C',220e-6,'R',c.R,'Vref',12, ...
            'Kci',D.Kci,'Kpe',D.Kpe,'Kie',D.Kie,'ff',1, ...
            'Dmin',D.Dmin,'Dmax',D.Dmax,'Imin',D.Imin,'Imax',D.Imax, ...
            'Tt',D.Tt,'Eclamp',D.Eclamp,'Tss',D.Tss,'sens',sens, ...
            'supEnable',false,'ratio',2,'tStep',tStep,'tEnd',0.10, ...
            'delaySamples',1,'nSub',8);
        r = buck_dual_sim(cf);
        m = step_metrics(r.t, r.vC, 12, tStep, 1);
        post = r.t >= tStep;
        ok5 = isfinite(m.settleMs) && m.settleMs <= 1.0;
        ok7 = abs(m.dipPct) <= 12;
        fprintf('%-10s %-4s %10.4f %10.3f %9.3f %8d %8d\n', ...
            comp(q).id, c.id, m.settleMs, m.dipPct, max(r.d(post)), ok5, ok7);
        rows(end+1) = struct('sweep','composite','param',comp(q).id,'value',0, ...
            'cond',c.id,'s5',m.settleMs,'dip',m.dipPct,'dmax',max(r.d(post)), ...
            'iLmax',max(r.iL(post)),'ok5',ok5,'ok7',ok7);
    end
end

%% ---------- figure: S5 vs sensor bandwidth and vs delay ----------
fig = figure('Position',[80 80 1000 420],'Color','w');
sub = [2 1];
for sp = 1:2
    if sp == 1, key = 'bandwidth_Hz'; ttl = 'sensor bandwidth';
    else, key = 'sensor_delay_samples'; ttl = 'sensor transport delay'; end
    subplot(1,2,sp); hold on; grid on;
    hl = []; 
    for ic = 1:numel(conds)
        sel = strcmp({rows.sweep},key) & strcmp({rows.cond},conds(ic).id);
        rr = rows(sel);
        if isempty(rr), continue; end
        xv = [rr.value]; yv = [rr.s5];
        if sp == 1, hh = semilogx(xv,yv,'o-','LineWidth',1.6);
        else,       hh = plot(xv,yv,'o-','LineWidth',1.6); end
        hl(end+1) = hh;
    end
    hLim = yline(1.0,'r--','S5 limit 1 ms','LineWidth',1.4);
    xlabel(ttl); ylabel('S5 (ms)');
    title(sprintf('DUAL-B S5 vs %s', ttl));
    legend([hl hLim], {'C1 (6->3 ohm)','C5 (3->1.5 ohm)','S5 limit'}, ...
        'Location','northwest');
end
sgtitle('Sensor non-ideality erodes the feedforward benefit (supervisor OFF)','FontWeight','bold');
print(fig, fullfile(outDir,'a5_task2_sensor.png'), '-dpng','-r140'); close(fig);

save(fullfile(outDir,'a5_task2_sensor.mat'),'rows','comp','D');
fid = fopen(fullfile(outDir,'a5_task2_sensor.json'),'w');
fwrite(fid, jsonencode(struct('results',rows,'composite',comp,'design',D)), 'char');
fclose(fid);
fprintf('\nsaved a5_task2_sensor.json / .mat / .png\n');
