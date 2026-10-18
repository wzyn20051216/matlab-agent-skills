function res = build_buck_dual_loop(outDir, cfg)
%BUILD_BUCK_DUAL_LOOP  Simulink model of the cascaded dual loop (average plant).
%
%   res = build_buck_dual_loop(outDir, cfg)
%
% Structure (identical plant/actuator blocks to build_buck_closed_loop_generic,
% so the comparison against BASE/OPT is apples-to-apples):
%
%   e = Vref - vC
%   xI'      = Ki_e*e + (1/Tt)*(dSat - dRaw)*Vin/Kci + (1/Tt)*(iLrefLim - iLrefRaw)
%   iLrefRaw = Kp_e*e + xI
%   iLrefLim = sat(iLrefRaw, Imin, Imax)
%   iLref    = iLrefLim + ff*iLoad                 (ff = 0 or 1)
%   dRaw     = Vref/Vin + Kci*(iLref - iL)/Vin
%   d        = sat(dRaw, Dmin, Dmax)
%
% Units: Kci [V/A]=[ohm], Kp_e [A/V], Ki_e [A/(V*s)], xI [A], d [-].
% The feedforward term Vref/Vin MUST be a constant. A vC/Vin feedforward makes
% Vin*d = vC hold identically, every vC becomes an equilibrium and the outer
% loop cannot regulate (Phase 3A.2 finding #3).
%
% cfg (defaults)
%   Vin, L, C, R, Vref [12]
%   Kci, Kpe, Kie              (required)
%   ff [0]                     load-current feedforward flag
%   Imin [0], Imax [20]        current-reference clamp
%   Dmin [0.05], Dmax [0.85]   duty clamp (S8 in the original standards)
%   Tt [1e-3]                  back-calculation time constant
%   loadStepTime [0.06], loadStepRatio [2]   conductance x ratio (R -> R/ratio)
%   tStop [0.12], maxStep [1e-6]
%   modelName ['buck_dual'], saveModel [true]
%   vCinit []                  optional non-zero initial vC (startup test)
%
% Output res: t, vC, iL, duty, iLref, err, cfg, modelPath

if nargin < 1 || isempty(outDir), outDir = getenv('BUCK_OUT'); end
if nargin < 2, cfg = struct(); end
outDir = strrep(outDir,'/',filesep);
if ~exist(outDir,'dir'), mkdir(outDir); end

d = struct('Vin',48,'L',150e-6,'C',220e-6,'R',6,'Vref',12, ...
    'Kci',2,'Kpe',1,'Kie',2000,'ff',0, ...
    'Imin',0,'Imax',12,'Dmin',0.05,'Dmax',0.85,'Tt',3e-4, ...
    'Eclamp',1.5,'Tss',5e-3, ...
    'loadStepTime',0.06,'loadStepRatio',2, ...
    'tStop',0.12,'maxStep',1e-6, ...
    'modelName','buck_dual','saveModel',true,'vCinit',[]);
f = fieldnames(cfg); for i=1:numel(f), d.(f{i}) = cfg.(f{i}); end

Vin=d.Vin; L=d.L; C=d.C; R=d.R; Vref=d.Vref;
Kci=d.Kci; Kpe=d.Kpe; Kie=d.Kie; Tt=d.Tt;

mdl = regexprep(d.modelName, '[^A-Za-z0-9_]', '_');
if bdIsLoaded(mdl), close_system(mdl,0); end
new_system(mdl); open_system(mdl);

% ---- plant: x=[iL;vC], u=[d; i_load] ----
A = [0, -1/L; 1/C, 0];
B = [Vin/L, 0; 0, -1/C];
Co = [0 1; 1 0];
Do = [0 0; 0 0];
if isempty(d.vCinit), X0 = '[0;0]'; else, X0 = sprintf('[0;%.12g]', d.vCinit); end

% ---- reference: constant, or ramped (soft start) ----
% A 12 V step into a loop whose bandwidth is ~1 kHz produces 11-36 % startup
% overshoot: the charging transient (~0.3 ms) is FASTER than the loop (0.5 ms),
% so the outer integrator accumulates monotonically before the output arrives.
% A soft start makes the reference the slow signal instead, and the loop tracks
% it. BASE/OPT do not need one because their integral gain is ~700x smaller.
if d.Tss > 0
    add_block('simulink/Sources/Clock',[mdl '/Clock']);
    add_block('simulink/Math Operations/Gain',[mdl '/SS_rate'],'Gain',num2str(Vref/d.Tss));
    add_block('simulink/Discontinuities/Saturation',[mdl '/SS_lim'], ...
        'LowerLimit','0','UpperLimit',num2str(Vref));
    add_line(mdl,'Clock/1','SS_rate/1');
    add_line(mdl,'SS_rate/1','SS_lim/1');
    set_param([mdl '/SS_lim'],'Name','Vref');
else
    add_block('simulink/Sources/Constant',[mdl '/Vref'],'Value',num2str(Vref));
end
add_block('simulink/Math Operations/Sum',[mdl '/Error'],'Inputs','+-');

% ---- outer PI: iLrefRaw = Kpe*e + xI ----
add_block('simulink/Math Operations/Gain',[mdl '/Kpe'],'Gain',num2str(Kpe));
add_block('simulink/Math Operations/Gain',[mdl '/Kie'],'Gain',num2str(Kie));
add_block('simulink/Math Operations/Sum',[mdl '/Int_in'],'Inputs','++');
add_block('simulink/Continuous/Integrator',[mdl '/Int_xI'],'InitialCondition','0');
add_block('simulink/Math Operations/Sum',[mdl '/iLref_sum'],'Inputs','++');

% ---- current-reference clamp ----
add_block('simulink/Discontinuities/Saturation',[mdl '/iLref_lim'], ...
    'LowerLimit',num2str(d.Imin),'UpperLimit',num2str(d.Imax));
add_block('simulink/Math Operations/Sum',[mdl '/iL_satdiff'],'Inputs','+-');

% ---- load-current feedforward (optional) ----
if d.ff
    add_block('simulink/Math Operations/Sum',[mdl '/iLref_ff'],'Inputs','++');
end

% ---- inner current loop ----
add_block('simulink/Math Operations/Sum',[mdl '/iL_err'],'Inputs','+-');
add_block('simulink/Math Operations/Gain',[mdl '/Kci_ov_Vin'],'Gain',num2str(Kci/Vin));
add_block('simulink/Sources/Constant',[mdl '/D_ff'],'Value',num2str(Vref/Vin));
add_block('simulink/Math Operations/Sum',[mdl '/d_raw'],'Inputs','++');
add_block('simulink/Discontinuities/Saturation',[mdl '/Duty_limit'], ...
    'LowerLimit',num2str(d.Dmin),'UpperLimit',num2str(d.Dmax));
add_block('simulink/Math Operations/Sum',[mdl '/d_satdiff'],'Inputs','+-');
add_block('simulink/Math Operations/Gain',[mdl '/Vin_ov_Kci'],'Gain',num2str(Vin/Kci));

% ---- anti-windup: both saturations back-calculated into xI ----
add_block('simulink/Math Operations/Sum',[mdl '/aw_sum'],'Inputs','++');
add_block('simulink/Math Operations/Gain',[mdl '/AntiGain'],'Gain',num2str(1/Tt));

% ---- load ----
if isempty(d.loadStepTime)
    add_block('simulink/Sources/Constant',[mdl '/Conductance'],'Value',num2str(1/R));
else
    add_block('simulink/Sources/Step',[mdl '/Conductance'], ...
        'Time',num2str(d.loadStepTime),'Before',num2str(1/R), ...
        'After',num2str(d.loadStepRatio/R));
end
add_block('simulink/Math Operations/Product',[mdl '/Load'],'Inputs','2');

add_block('simulink/Continuous/State-Space',[mdl '/Plant'], ...
    'A',mat2str(A),'B',mat2str(B),'C',mat2str(Co),'D',mat2str(Do),'X0',X0);

add_block('simulink/Signal Routing/Mux',  [mdl '/Mux'],'Inputs','2');
add_block('simulink/Signal Routing/Demux',[mdl '/Demux'],'Outputs','2');

add_block('simulink/Sinks/To Workspace',[mdl '/vC_sink'],'VariableName','vC','SaveFormat','Timeseries');
add_block('simulink/Sinks/To Workspace',[mdl '/iL_sink'],'VariableName','iL','SaveFormat','Timeseries');
add_block('simulink/Sinks/To Workspace',[mdl '/duty_sink'],'VariableName','duty','SaveFormat','Timeseries');
add_block('simulink/Sinks/To Workspace',[mdl '/iLref_sink'],'VariableName','iLref','SaveFormat','Timeseries');
add_block('simulink/Sinks/To Workspace',[mdl '/err_sink'],'VariableName','err','SaveFormat','Timeseries');

% ---- wiring ----
add_line(mdl,'Vref/1','Error/1');
add_line(mdl,'Demux/1','Error/2');
% ---- error clamp (setpoint conditioning) ----
% Without it the proportional term commands Kp_e*12 = 21.6 A at startup.
% It cannot affect the load step: |e| there is at most 1.5 V < Eclamp.
if isfinite(d.Eclamp)
    add_block('simulink/Discontinuities/Saturation',[mdl '/E_clamp'], ...
        'LowerLimit',num2str(-d.Eclamp),'UpperLimit',num2str(d.Eclamp));
    add_line(mdl,'Error/1','E_clamp/1');
    eSig = 'E_clamp/1';
else
    eSig = 'Error/1';
end
add_line(mdl,eSig,'Kpe/1');
add_line(mdl,'Kpe/1','iLref_sum/1');
add_line(mdl,'Int_xI/1','iLref_sum/2');
add_line(mdl,eSig,'Kie/1');
add_line(mdl,'Kie/1','Int_in/1');
add_line(mdl,'AntiGain/1','Int_in/2');
add_line(mdl,'Int_in/1','Int_xI/1');

add_line(mdl,'iLref_sum/1','iLref_lim/1');
add_line(mdl,'iLref_sum/1','iL_satdiff/2');       % - iLrefRaw
add_line(mdl,'iLref_lim/1','iL_satdiff/1');       % + iLrefLim

% NOTE: iL_err must take the CLAMPED reference (iLref_lim), not iL_satdiff.
% iL_satdiff is the saturation DEFICIT (zero when unsaturated) and is used only
% by the anti-windup path. Wiring iL_err to it makes the inner loop see a zero
% current error in normal operation (bug hit and fixed in this file).
if d.ff
    add_line(mdl,'iLref_lim/1','iLref_ff/1');
    add_line(mdl,'Load/1','iLref_ff/2');          % + iLoad (measured)
    add_line(mdl,'iLref_ff/1','iL_err/1');
else
    add_line(mdl,'iLref_lim/1','iL_err/1');
end
add_line(mdl,'Demux/2','iL_err/2');
add_line(mdl,'iL_err/1','Kci_ov_Vin/1');
add_line(mdl,'Kci_ov_Vin/1','d_raw/1');
add_line(mdl,'D_ff/1','d_raw/2');
add_line(mdl,'d_raw/1','Duty_limit/1');
add_line(mdl,'Duty_limit/1','d_satdiff/1');
add_line(mdl,'d_raw/1','d_satdiff/2');
add_line(mdl,'d_satdiff/1','Vin_ov_Kci/1');
add_line(mdl,'Vin_ov_Kci/1','aw_sum/1');
add_line(mdl,'iL_satdiff/1','aw_sum/2');
add_line(mdl,'aw_sum/1','AntiGain/1');

add_line(mdl,'Duty_limit/1','Mux/1');
add_line(mdl,'Demux/1','Load/1');
add_line(mdl,'Conductance/1','Load/2');
add_line(mdl,'Load/1','Mux/2');
add_line(mdl,'Mux/1','Plant/1');
add_line(mdl,'Plant/1','Demux/1');

add_line(mdl,'Demux/1','vC_sink/1');
add_line(mdl,'Demux/2','iL_sink/1');
add_line(mdl,'Duty_limit/1','duty_sink/1');
if d.ff
    add_line(mdl,'iLref_ff/1','iLref_sink/1');
else
    add_line(mdl,'iLref_lim/1','iLref_sink/1');
end
add_line(mdl,'Error/1','err_sink/1');

set_param(mdl,'StopTime',num2str(d.tStop),'Solver','ode45','MaxStep',num2str(d.maxStep));
if d.saveModel
    save_system(mdl, fullfile(outDir, [mdl '.slx']));
end

simout = sim(mdl);
res = struct();
res.t = simout.vC.Time; res.vC = simout.vC.Data; res.iL = simout.iL.Data;
res.duty = simout.duty.Data; res.iLref = simout.iLref.Data; res.err = simout.err.Data;
res.cfg = d; res.modelPath = fullfile(outDir, [mdl '.slx']);
close_system(mdl,0);
end
