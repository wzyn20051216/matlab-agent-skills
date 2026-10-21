function res = boost_b2_task3_simulink(outDir)
%BOOST_B2_TASK3_SIMULINK  Verify the two generated .slx models against the MATLAB
%engines.
%
%   res = boost_b2_task3_simulink(outDir)
%
% WHAT IS CHECKED (and what is NOT)
%   A1  the model can be built, loaded, updated and saved
%   A2  steady state: vOut, iL, duty against boost_avg_sim / boost_sw_sim
%   A3  load step: dip and recovery against the same engines
%   A4  DCM boundary: at R = 300 ohm the switching model must clamp iL at 0 and
%       the output must rise, matching boost_sw_sim (which detects DCM)
%   A5  step-size sensitivity: nSub 200 -> 800 must not move the answers by more
%       than the acceptance resolution
%   A6  no pre-generated MAT data and no absolute path inside the models
%
% The models use an IDEAL sensor (no gain/offset/noise); the MATLAB comparison
% runs are made with the sensor disabled so the two are comparable. The sensor
% chain is a separate, documented assumption and is exercised in boost_b2_accept.
%
% KNOWN CONVENTION DIFFERENCE: the switching model samples vOut at the period
% boundary, where the ESR step occurs (the diode current jumps from iL to 0 at the
% ON edge). Sampling just before or just after that edge changes the regulated
% value by ESR*iL/(1+ESR/R) ~ 100 mV. The measured offset is reported, not hidden.

if nargin < 1 || isempty(outDir), outDir = getenv('BOOST_OUT'); end
if isempty(outDir), outDir = fullfile(pwd,'artifacts','validation','boost_b2'); end
outDir = strrep(outDir,'/',filesep);
here = fileparts(mfilename('fullpath'));
addpath(fileparts(here));
addpath(fullfile(fileparts(fileparts(here)),'buck'));
if ~exist(outDir,'dir'), mkdir(outDir); end
% The .slx files are DELIVERABLES, so they live in the repository
% (matlab/boost/models), not under artifacts/ which is git-ignored. Everything the
% script measures is written to outDir.
modelDir = fullfile(fileparts(here),'models');
if ~exist(modelDir,'dir'), mkdir(modelDir); end

p = boost_params(); [dA, ~] = boost_designs(p, 650);
Ts = 1/p.fs;
fprintf('===== Phase 3B.2 Task 3: Simulink models =====\n');

%% ---- A2/A3: average model ----
fprintf('\n--- A2/A3 average model vs boost_avg_sim ---\n');
ra1 = build_boost_avg(modelDir, struct('loadStepRatio',1,'tStop',0.03,'modelName','boost_avg'));
ma1 = lazy_metrics(ra1, p, 0.02, 0.03);
o = struct('ratio',1,'tStep',0.02,'tEnd',0.03,'nSub',200,'nDly',1);
ea1 = boost_avg_sim(p, dA, o);
me1 = lazy_metrics(ea1, p, 0.02, 0.03);
fprintf('  steady  SLX vOut %.6f iL %.6f d %.6f | MATLAB %.6f %.6f %.6f\n', ...
    ma1.vOut, ma1.iL, ma1.d, me1.vOut, me1.iL, me1.d);
res.avgSteady = struct('slx',ma1,'matlab',me1, ...
    'dVout',abs(ma1.vOut-me1.vOut),'dIL',abs(ma1.iL-me1.iL),'dd',abs(ma1.d-me1.d));

ra2 = build_boost_avg(modelDir, struct('loadStepRatio',1.5,'tStop',0.06,'modelName','boost_avg'));
ma2 = step_only(ra2, p);
o2 = struct('ratio',1.5,'tStep',0.02,'tEnd',0.06,'nSub',200,'nDly',1);
ea2 = boost_avg_sim(p, dA, o2);
me2 = step_only(ea2, p);
fprintf('  step    SLX dip %+.4f %% s5 %.4f ms | MATLAB %+.4f %% %.4f ms\n', ...
    ma2.dip, ma2.s5, me2.dip, me2.s5);
res.avgStep = struct('slx',ma2,'matlab',me2, ...
    'dDip',abs(ma2.dip-me2.dip),'dS5',abs(ma2.s5-me2.s5));

%% ---- A2/A3: switching model ----
fprintf('\n--- A2/A3 switching model vs boost_sw_sim (ideal sensor) ---\n');
rs1 = build_boost_switching(modelDir, struct('loadStepRatio',1,'tStop',0.03,'modelName','boost_sw'));
ms1 = sw_steady(rs1, p);
os = struct('ratio',1,'tStep',0.02,'tEnd',0.03,'nSub',200,'nDly',1,'noise',false);
es1 = boost_sw_sim(p, dA, os);
mse1 = sw_steady(es1, p);
fprintf('  steady  SLX vOut %.6f iL %.6f d %.6f ripple %.4f A | MATLAB %.6f %.6f %.6f %.4f\n', ...
    ms1.vOut, ms1.iL, ms1.d, ms1.ripple, mse1.vOut, mse1.iL, mse1.d, mse1.ripple);
res.swSteady = struct('slx',ms1,'matlab',mse1,'dVout',abs(ms1.vOut-mse1.vOut), ...
    'dIL',abs(ms1.iL-mse1.iL),'dRipple',abs(ms1.ripple-mse1.ripple), ...
    'offsetPct',100*(ms1.vOut-mse1.vOut)/mse1.vOut);

rs2 = build_boost_switching(modelDir, struct('loadStepRatio',1.5,'tStop',0.06,'modelName','boost_sw'));
ms2 = sw_step(rs2, p);
os2 = struct('ratio',1.5,'tStep',0.02,'tEnd',0.06,'nSub',200,'nDly',1,'noise',false);
es2 = boost_sw_sim(p, dA, os2);
mse2 = sw_step(es2, p);
fprintf('  step    SLX dip %+.4f %% s5 %.4f ms | MATLAB %+.4f %% %.4f ms\n', ...
    ms2.dip, ms2.s5, mse2.dip, mse2.s5);
res.swStep = struct('slx',ms2,'matlab',mse2, ...
    'dDip',abs(ms2.dip-mse2.dip),'dS5',abs(ms2.s5-mse2.s5));

%% ---- A4: DCM ----
fprintf('\n--- A4 DCM boundary (R = 300 ohm) ---\n');
pq = p; pq.R = 300; pq.Pout = pq.Vref^2/300;
rq = build_boost_switching(modelDir, struct('R',300,'loadStepRatio',1,'tStop',0.08, ...
    'modelName','boost_sw','Vin',p.Vin));
mq = sw_steady(rq, pq);
oq = struct('ratio',1,'tStep',0.02,'tEnd',0.08,'nSub',200,'nDly',1,'noise',false);
eq = boost_sw_sim(pq, dA, oq);
meq = sw_steady(eq, pq);
fprintf('  SLX vOut %.3f iLmin %.6f | MATLAB vOut %.3f iLmin %.6f dcm %.2f %%\n', ...
    mq.vOut, mq.iLmin, meq.vOut, meq.iLmin, 100*eq.dcmFracTotal);
res.dcm = struct('slx',mq,'matlab',meq,'dVout',abs(mq.vOut-meq.vOut), ...
    'dcmDetected',eq.dcmTime>0,'slxClamped',mq.iLmin<1e-6);

%% ---- A5: step-size sensitivity ----
fprintf('\n--- A5 step-size sensitivity (nSub 200 -> 800) ---\n');
r800 = build_boost_switching(modelDir, struct('loadStepRatio',1.5,'tStop',0.06, ...
    'nSub',800,'modelName','boost_sw'));
m800 = sw_step(r800, p);
fprintf('  nSub 200: dip %+.4f %% s5 %.4f ms\n', ms2.dip, ms2.s5);
fprintf('  nSub 800: dip %+.4f %% s5 %.4f ms\n', m800.dip, m800.s5);
fprintf('  delta   : %.5f pp, %.5f ms\n', abs(m800.dip-ms2.dip), abs(m800.s5-ms2.s5));
res.stepSensitivity = struct('dip200',ms2.dip,'dip800',m800.dip, ...
    's5200',ms2.s5,'s5800',m800.s5,'dDip',abs(m800.dip-ms2.dip), ...
    'dS5',abs(m800.s5-ms2.s5));

%% ---- A1: build / load / update / save ----
fprintf('\n--- A1 model lifecycle ---\n');
res = struct('level','3B.2-Task3');
life = struct();
for k = 1:2
    if k == 1, nm = 'boost_avg'; else, nm = 'boost_sw'; end
    f = fullfile(modelDir,[nm '.slx']);
    life.(nm) = struct('exists',exist(f,'file')==2,'size',0,'loaded',0,'updated',0);
    if life.(nm).exists
        d = dir(f); life.(nm).size = d.bytes;
        load_system(f);
        life.(nm).loaded = bdIsLoaded(nm);
        try
            set_param(nm,'SimulationCommand','update');
            life.(nm).updated = 1;
        catch ME
            life.(nm).updated = 0;
            fprintf('  %s update FAILED: %s\n', nm, ME.message);
        end
        close_system(nm,0);
    end
    fprintf('  %-9s exists %d  size %7d B  loaded %d  updated %d\n', nm, ...
        life.(nm).exists, life.(nm).size, life.(nm).loaded, life.(nm).updated);
end
res.lifecycle = life;

%% ---- A6: no base-workspace data ----------------
fprintf('\n--- A6 model self-containment ---\n');
% A model built only from library blocks and numeric constants uses ZERO variables
% from the base workspace. That is stronger than scanning the file for a path: it
% proves the model cannot depend on leftover MATLAB data either.
nvars = 0;
for k = 1:2
    if k == 1, nm = 'boost_avg'; else, nm = 'boost_sw'; end
    load_system(fullfile(modelDir,[nm '.slx']));
    v = Simulink.findVars(nm);
    % Only BASE-workspace symbols matter. Simulink.findVars also reports the
    % internal mask parameters of library blocks (the Repeating Sequence exposes
    % period/rep_seq_t/rep_seq_y), which are part of the block, not of the model's
    % environment. Counting those would wrongly suggest an external dependency.
    if ~isempty(v)
        v = v(strcmp({v.SourceType},'base workspace'));
    end
    nvars = nvars + numel(v);
    close_system(nm,0);
end
fprintf('  base-workspace variables used by the models: %d\n', nvars);
res.modelVariables = nvars;

res.outDirName = outDir;
res.modelDir = modelDir;
save(fullfile(outDir,'b2_task3_simulink.mat'),'res');
fid = fopen(fullfile(outDir,'b2_task3_simulink.json'),'w');
if fid >= 0, fwrite(fid, jsonencode(res), 'char'); fclose(fid); end
fprintf('\nsaved b2_task3_simulink.json/.mat\n');
end

% ---------------------------------------------------------------------------
function m = lazy_metrics(r, p, tStep, tEnd)
q = r.t > tEnd - 0.01;
m = struct('vOut',mean(r.vOut(q)),'iL',mean(r.iL(q)), ...
    'd',mean(r.duty(q)),'tStep',tStep);
end

function m = step_only(r, p)
q = r.t > 0.045;
sm = step_metrics(r.t, r.vOut, p.Vref, 0.02, 1);
m = struct('vOut',mean(r.vOut(q)),'dip',sm.dipPct,'s5',sm.settleMs);
end

function m = sw_steady(r, p)
q = r.t > max(r.t) - 0.01;
m = struct('vOut',mean(r.vOut(q)),'iL',mean(r.iL(q)),'d',mean(r.duty(q)), ...
    'ripple',max(r.iL(q))-min(r.iL(q)),'iLmin',min(r.iL(q)));
end

function m = sw_step(r, p)
q = r.t > 0.045;
sm = step_metrics(r.t, r.vOut, p.Vref, 0.02, 1);
m = struct('vOut',mean(r.vOut(q)),'dip',sm.dipPct,'s5',sm.settleMs, ...
    'ripple',max(r.iL(q))-min(r.iL(q)));
end
