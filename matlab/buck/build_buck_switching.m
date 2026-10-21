function res = build_buck_switching(outDir, cfg)
%BUILD_BUCK_SWITCHING  Switching-level Buck with a dual-loop controller.
%
%   res = build_buck_switching(outDir, cfg)
%
% THIS IS A REAL SWITCHING MODEL, NOT AN AVERAGE MODEL.
% The plant is two integrators (iL, vC) driven by the INSTANTANEOUS switch-node
% voltage, which alternates every switching period according to whichever
% semiconductor conducts:
%
%   switch on :  vSW = Vin - iL*RonSW
%   switch off:  vSW = -Vf - iL*RonD          (freewheel diode conducts)
%
%   diL/dt = (vSW - vOut - iL*RL)/L
%   vOut   = (vC + ESR*iL)/(1 + ESR/R)
%   dvC/dt = (iL - vOut/R)/C
%
% The duty is compared against a sawtooth carrier at fs, so switching states,
% switching ripple and the diode drop all appear in the waveform. The load step
% is a resistive step (R -> R/ratio).
%
% Controller: identical law to build_buck_dual_loop.m / buck_dual_sim.m
%   iLref = Kp_e*e + Ki_e*xe (+ ff*iLoad), clamped to [Imin, Imax]
%   d     = Vref/Vin + Kci*(iLref - iL)/Vin, clamped to [Dmin, Dmax]
%   xe'   = e + (1/Tt)*[(dSat-dRaw)*Vin/Kci + (iLrefLim - iLrefRaw)]/Ki_e
% plus error clamp and soft start. cfg.ctrlDelay inserts one switching period of
% computation delay (Unit Delay at Ts) to expose the sampled-data effect on the
% switching model.
%
% WHY BASIC BLOCKS AND NOT SIMSCAPE ELECTRICAL
% Simscape Electrical is licensed here and its blocks resolve (a
% Vdc+Resistor+Reference+SolverConfiguration netlist wires successfully). The
% full converter could not be wired in `-batch` without repeated port/domain
% errors on the ideal Switch block, at ~1 minute per attempt. The brief allows
% the base-block fallback as long as the model really switches, which this one
% does. This is a schedule decision, not a licensing limitation, and the
% Simscape version is listed as a follow-up in the report.
%
% cfg (defaults): Vin, L, C, R, Vref[12], fs[50e3], Kci, Kpe, Kie, ff[0],
%   RL[20e-3], ESR[10e-3], Vf[0.35], RonD[2e-3], RonSW[1e-3],
%   Imin[0], Imax[12], Dmin[0.05], Dmax[0.85], Tt[3e-4], Eclamp[1.5], Tss[5e-3],
%   loadStepTime[0.06], loadStepRatio[2], tStop[0.10], nSub[200],
%   ctrlDelay[false], modelName['buck_sw'], saveModel[true]

if nargin < 1 || isempty(outDir), outDir = getenv('BUCK_OUT'); end
if nargin < 2, cfg = struct(); end
outDir = strrep(outDir,'/',filesep);
if ~exist(outDir,'dir'), mkdir(outDir); end

d = struct('Vin',48,'L',150e-6,'C',220e-6,'R',6,'Vref',12,'fs',50e3, ...
    'Kci',6,'Kpe',1.8,'Kie',4000,'ff',0, ...
    'RL',20e-3,'ESR',10e-3,'Vf',0.35,'RonD',2e-3,'RonSW',1e-3, ...
    'Imin',0,'Imax',12,'Dmin',0.05,'Dmax',0.85, ...
    'Tt',3e-4,'Eclamp',1.5,'Tss',5e-3, ...
    'loadStepTime',0.06,'loadStepRatio',2, ...
    'tStop',0.10,'nSub',200,'ctrlDelay',false, ...
    'ctrlSample',true,'sampPhase',0.5,'rippleComp',false, ...
    'modelName','buck_sw','saveModel',true);
f = fieldnames(cfg); for i=1:numel(f), d.(f{i}) = cfg.(f{i}); end
Ts = 1/d.fs;

mdl = regexprep(d.modelName,'[^A-Za-z0-9_]','_');
if bdIsLoaded(mdl), close_system(mdl,0); end
new_system(mdl); open_system(mdl);

%% ================= switching power stage =================
add_block('simulink/Sources/Repeating Sequence',[mdl '/Carrier'], ...
    'rep_seq_t',sprintf('[0 %g]',Ts),'rep_seq_y','[0 1]');
add_block('simulink/Logic and Bit Operations/Relational Operator',[mdl '/PWM'], ...
    'Operator','>=');
add_line(mdl,'Carrier/1','PWM/2','autorouting','on');

add_block('simulink/Sources/Constant',[mdl '/Vin'],'Value',num2str(d.Vin));
add_block('simulink/Math Operations/Sum',[mdl '/vSW_on'],'Inputs','+-');
add_line(mdl,'Vin/1','vSW_on/1','autorouting','on');
add_block('simulink/Math Operations/Gain',[mdl '/RonSW'],'Gain',num2str(d.RonSW));
add_line(mdl,'RonSW/1','vSW_on/2','autorouting','on');

add_block('simulink/Sources/Constant',[mdl '/Vf'],'Value',num2str(d.Vf));
add_block('simulink/Math Operations/Sum',[mdl '/vSW_off'],'Inputs','--');
add_line(mdl,'Vf/1','vSW_off/1','autorouting','on');
add_block('simulink/Math Operations/Gain',[mdl '/RonD'],'Gain',num2str(d.RonD));
add_line(mdl,'RonD/1','vSW_off/2','autorouting','on');

add_block('simulink/Signal Routing/Switch',[mdl '/SW'], ...
    'Criteria','u2 >= Threshold','Threshold','0.5');
add_line(mdl,'PWM/1','SW/2','autorouting','on');
add_line(mdl,'vSW_on/1','SW/1','autorouting','on');
add_line(mdl,'vSW_off/1','SW/3','autorouting','on');

% vOut = (vC + ESR*iL)/(1 + ESR/R)
add_block('simulink/Sources/Step',[mdl '/Rload'], ...
    'Time',num2str(d.loadStepTime),'Before',num2str(d.R), ...
    'After',num2str(d.R/d.loadStepRatio));
add_block('simulink/Sources/Constant',[mdl '/One'],'Value','1');
% 1/R via Math Function(reciprocal): the Divide block rejects the 'Inputs'
% strings used here, and a Product with a reciprocal is equivalent and robust.
add_block('simulink/Math Operations/Math Function',[mdl '/Gload'], ...
    'Function','reciprocal');
add_line(mdl,'Rload/1','Gload/1','autorouting','on');
add_block('simulink/Math Operations/Gain',[mdl '/ESR_iL'],'Gain',num2str(d.ESR));
add_block('simulink/Math Operations/Gain',[mdl '/ESR_G'],'Gain',num2str(d.ESR));
add_line(mdl,'Gload/1','ESR_G/1','autorouting','on');
add_block('simulink/Math Operations/Sum',[mdl '/vOut_num'],'Inputs','++');
add_line(mdl,'ESR_iL/1','vOut_num/1','autorouting','on');
add_block('simulink/Math Operations/Sum',[mdl '/vOut_den'],'Inputs','++');
add_line(mdl,'One/1','vOut_den/1','autorouting','on');
add_line(mdl,'ESR_G/1','vOut_den/2','autorouting','on');
add_block('simulink/Math Operations/Math Function',[mdl '/inv_den'], ...
    'Function','reciprocal');
add_line(mdl,'vOut_den/1','inv_den/1','autorouting','on');
add_block('simulink/Math Operations/Product',[mdl '/vOut'],'Inputs','2');
add_line(mdl,'vOut_num/1','vOut/1','autorouting','on');
add_line(mdl,'inv_den/1','vOut/2','autorouting','on');

% vL = vSW - vOut - iL*RL
add_block('simulink/Math Operations/Gain',[mdl '/RL'],'Gain',num2str(d.RL));
add_block('simulink/Math Operations/Sum',[mdl '/vL'],'Inputs','+--');
add_line(mdl,'SW/1','vL/1','autorouting','on');
add_line(mdl,'vOut/1','vL/2','autorouting','on');
add_line(mdl,'RL/1','vL/3','autorouting','on');
add_block('simulink/Math Operations/Gain',[mdl '/invL'],'Gain',num2str(1/d.L));
add_line(mdl,'vL/1','invL/1','autorouting','on');
add_block('simulink/Continuous/Integrator',[mdl '/iL_int'],'InitialCondition','0');
add_line(mdl,'invL/1','iL_int/1','autorouting','on');
add_line(mdl,'iL_int/1','RonSW/1','autorouting','on');
add_line(mdl,'iL_int/1','RonD/1','autorouting','on');
add_line(mdl,'iL_int/1','ESR_iL/1','autorouting','on');
add_line(mdl,'iL_int/1','RL/1','autorouting','on');

% iC = iL - vOut*G
add_block('simulink/Math Operations/Product',[mdl '/iLoad'],'Inputs','2');
add_line(mdl,'vOut/1','iLoad/1','autorouting','on');
add_line(mdl,'Gload/1','iLoad/2','autorouting','on');
add_block('simulink/Math Operations/Sum',[mdl '/iC'],'Inputs','+-');
add_line(mdl,'iL_int/1','iC/1','autorouting','on');
add_line(mdl,'iLoad/1','iC/2','autorouting','on');
add_block('simulink/Math Operations/Gain',[mdl '/invC'],'Gain',num2str(1/d.C));
add_line(mdl,'iC/1','invC/1','autorouting','on');
add_block('simulink/Continuous/Integrator',[mdl '/vC_int'],'InitialCondition','0');
add_line(mdl,'invC/1','vC_int/1','autorouting','on');
add_line(mdl,'vC_int/1','vOut_num/2','autorouting','on');

%% ================= ADC sampling of the measurements =================
% The current loop must see a SAMPLED current, and WHICH instant it samples
% matters a lot here: at 48 V/12 V/50 kHz with L=150 uH the ripple is 1.23 App
% on a 2 A DC current (62 %). Sampling at the period boundary lands on the
% ripple VALLEY, so the loop regulates the valley and the average current sits
% half a ripple higher; sampling at the middle of the ON pulse lands on the
% average. Measured before this block existed: iLref = 1.416 A while the true
% average iL was 2.000 A, i.e. a 0.58 A bias caused purely by the sample phase.
% sampPhase = 0 -> period boundary (valley), 0.5 -> mid-ON (average).
if d.ctrlSample
    % The offset must land on the fixed-step grid, otherwise Simulink rejects the
    % model ("all sample times must be integer multiples of the fixed step").
    hstep = 1/(d.fs*d.nSub);
    off = round(d.sampPhase*Ts/hstep)*hstep;
    stv = sprintf('[%g %g]',Ts,off);
    add_block('simulink/Discrete/Zero-Order Hold',[mdl '/zoh_v'],'SampleTime',stv);
    add_line(mdl,'vOut/1','zoh_v/1','autorouting','on');
    add_block('simulink/Discrete/Zero-Order Hold',[mdl '/zoh_i'],'SampleTime',stv);
    add_line(mdl,'iL_int/1','zoh_i/1','autorouting','on');
    vSig = 'zoh_v/1'; iSigBase = 'zoh_i/1';
else
    vSig = 'vOut/1'; iSigBase = 'iL_int/1';
end

% ---- half-ripple compensation ----
% Sampling at the period boundary lands on the ripple VALLEY, so the current
% loop regulates (iL_avg - dIL/2). Moving the sample to mid-ON fixes the bias
% but costs an extra 0.125*Ts of loop delay, which measured UNSTABLE at one
% cycle of computation delay. The correct combination is therefore: sample at
% the boundary (minimum delay) and add the analytically known half-ripple
%   dIL/2 = (Vin - vOut)*d*Ts/(2L)
% to the measured current. It is a feed-forward term from quantities the
% controller already has, so it needs no extra sensing.
if d.rippleComp
    % Computed at the NOMINAL duty (D0 = Vref/Vin) because this block is placed
    % with the ADC sampling, before the duty signal exists. The error over the
    % operating range is (d - D0)*Ts*(Vin-Vref)/(2L) = +-0.07 A on a 2 A DC
    % current, i.e. 3.5 %, which is far below the 0.6 A bias it removes.
    compNom = (d.Vin - d.Vref)*(d.Vref/d.Vin)*Ts/(2*d.L);
    add_block('simulink/Sources/Constant',[mdl '/ripple_c'], ...
        'Value',num2str(compNom));
    add_block('simulink/Math Operations/Sum',[mdl '/iL_comp'],'Inputs','++');
    add_line(mdl,iSigBase,'iL_comp/1','autorouting','on');
    add_line(mdl,'ripple_c/1','iL_comp/2','autorouting','on');
    iSig = 'iL_comp/1';
else
    iSig = iSigBase;
end

%% ================= dual-loop controller =================
add_block('simulink/Sources/Clock',[mdl '/Clock']);
add_block('simulink/Math Operations/Gain',[mdl '/SS_rate'],'Gain',num2str(d.Vref/d.Tss));
add_block('simulink/Discontinuities/Saturation',[mdl '/Vref']);
set_param([mdl '/Vref'],'LowerLimit','0','UpperLimit',num2str(d.Vref));
add_line(mdl,'Clock/1','SS_rate/1','autorouting','on');
add_line(mdl,'SS_rate/1','Vref/1','autorouting','on');

add_block('simulink/Math Operations/Sum',[mdl '/Err'],'Inputs','+-');
add_line(mdl,'Vref/1','Err/1','autorouting','on');
add_line(mdl,vSig,'Err/2','autorouting','on');
add_block('simulink/Discontinuities/Saturation',[mdl '/Eclamp']);
set_param([mdl '/Eclamp'],'LowerLimit',num2str(-d.Eclamp), ...
    'UpperLimit',num2str(d.Eclamp));
add_line(mdl,'Err/1','Eclamp/1','autorouting','on');

add_block('simulink/Math Operations/Gain',[mdl '/Kpe'],'Gain',num2str(d.Kpe));
add_line(mdl,'Eclamp/1','Kpe/1','autorouting','on');
add_block('simulink/Math Operations/Gain',[mdl '/Kie'],'Gain',num2str(d.Kie));
add_line(mdl,'Eclamp/1','Kie/1','autorouting','on');
add_block('simulink/Math Operations/Sum',[mdl '/iLref_sum'],'Inputs','++');
add_line(mdl,'Kpe/1','iLref_sum/1','autorouting','on');
add_block('simulink/Math Operations/Sum',[mdl '/Int_in'],'Inputs','++');
add_block('simulink/Continuous/Integrator',[mdl '/Int_xI'],'InitialCondition','0');
add_line(mdl,'Kie/1','Int_in/1','autorouting','on');
add_line(mdl,'Int_in/1','Int_xI/1','autorouting','on');
add_line(mdl,'Int_xI/1','iLref_sum/2','autorouting','on');

if d.ff
    add_block('simulink/Math Operations/Sum',[mdl '/iLref_ff'],'Inputs','++');
    add_line(mdl,'iLref_sum/1','iLref_ff/1','autorouting','on');
    add_line(mdl,'iLoad/1','iLref_ff/2','autorouting','on');
    rawSig = 'iLref_ff/1';
else
    rawSig = 'iLref_sum/1';
end
add_block('simulink/Discontinuities/Saturation',[mdl '/iLref_lim']);
set_param([mdl '/iLref_lim'],'LowerLimit',num2str(d.Imin), ...
    'UpperLimit',num2str(d.Imax));
add_line(mdl,rawSig,'iLref_lim/1','autorouting','on');
add_block('simulink/Math Operations/Sum',[mdl '/iL_satdiff'],'Inputs','+-');
add_line(mdl,'iLref_lim/1','iL_satdiff/1','autorouting','on');
add_line(mdl,rawSig,'iL_satdiff/2','autorouting','on');

add_block('simulink/Math Operations/Sum',[mdl '/iL_err'],'Inputs','+-');
add_line(mdl,'iLref_lim/1','iL_err/1','autorouting','on');
add_line(mdl,iSig,'iL_err/2','autorouting','on');
add_block('simulink/Math Operations/Gain',[mdl '/Kci_Vin'],'Gain',num2str(d.Kci/d.Vin));
add_line(mdl,'iL_err/1','Kci_Vin/1','autorouting','on');
add_block('simulink/Sources/Constant',[mdl '/Dff'],'Value',num2str(d.Vref/d.Vin));
add_block('simulink/Math Operations/Sum',[mdl '/d_raw'],'Inputs','++');
add_line(mdl,'Kci_Vin/1','d_raw/1','autorouting','on');
add_line(mdl,'Dff/1','d_raw/2','autorouting','on');
add_block('simulink/Discontinuities/Saturation',[mdl '/D_lim']);
set_param([mdl '/D_lim'],'LowerLimit',num2str(d.Dmin),'UpperLimit',num2str(d.Dmax));
add_line(mdl,'d_raw/1','D_lim/1','autorouting','on');
add_block('simulink/Math Operations/Sum',[mdl '/d_satdiff'],'Inputs','+-');
add_line(mdl,'D_lim/1','d_satdiff/1','autorouting','on');
add_line(mdl,'d_raw/1','d_satdiff/2','autorouting','on');
add_block('simulink/Math Operations/Gain',[mdl '/Vin_Kci'],'Gain',num2str(d.Vin/d.Kci));
add_line(mdl,'d_satdiff/1','Vin_Kci/1','autorouting','on');
add_block('simulink/Math Operations/Sum',[mdl '/aw_sum'],'Inputs','++');
add_line(mdl,'Vin_Kci/1','aw_sum/1','autorouting','on');
add_line(mdl,'iL_satdiff/1','aw_sum/2','autorouting','on');
add_block('simulink/Math Operations/Gain',[mdl '/AntiGain'],'Gain',num2str(1/d.Tt));
add_line(mdl,'aw_sum/1','AntiGain/1','autorouting','on');
add_line(mdl,'AntiGain/1','Int_in/2','autorouting','on');

% ---- modulator sampling (this is what makes the model DIGITAL) ----
% A real PWM peripheral latches the duty once per switching period. Without the
% ZOH the continuous controller output is compared against the ramp sample by
% sample, so d moves DURING the period (measured: 0.411 -> 0.351 inside one
% period). The effective applied duty is then the solution of carrier(t)=d(t),
% which is NOT the mean of d -- measured applied duty 0.259 against a logged
% mean of 0.3326. That artefact also forced a spurious 0.66 A steady-state
% current error (iLref=2.66 A for iL=2.00 A). Latching the duty once per
% period removes it and matches how the hardware actually works.
add_block('simulink/Discrete/Zero-Order Hold',[mdl '/d_zoh'], ...
    'SampleTime',num2str(Ts));
add_line(mdl,'D_lim/1','d_zoh/1','autorouting','on');
if d.ctrlDelay
    % one full switching period of computation delay (ADC + ISR + update)
    add_block('simulink/Discrete/Unit Delay',[mdl '/d_delay'],'SampleTime',num2str(Ts));
    add_line(mdl,'d_zoh/1','d_delay/1','autorouting','on');
    add_line(mdl,'d_delay/1','PWM/1','autorouting','on');
else
    add_line(mdl,'d_zoh/1','PWM/1','autorouting','on');
end

%% ================= logging =================
nm = {'vOut','iL','duty','dcmd','iLref','vSW'};
for q = 1:numel(nm)
    add_block('simulink/Sinks/To Workspace',[mdl '/' nm{q} '_sink'], ...
        'VariableName',nm{q},'SaveFormat','Timeseries');
end
add_line(mdl,'vOut/1','vOut_sink/1','autorouting','on');
add_line(mdl,'iL_int/1','iL_sink/1','autorouting','on');
add_line(mdl,'d_zoh/1','duty_sink/1','autorouting','on');   % APPLIED duty
add_line(mdl,'D_lim/1','dcmd_sink/1','autorouting','on');   % raw command
add_line(mdl,'iLref_lim/1','iLref_sink/1','autorouting','on');
add_line(mdl,'SW/1','vSW_sink/1','autorouting','on');

h = 1/(d.fs*d.nSub);
set_param(mdl,'StopTime',num2str(d.tStop),'Solver','ode4', ...
    'SolverType','Fixed-step','FixedStep',num2str(h));
if d.saveModel, save_system(mdl, fullfile(outDir,[mdl '.slx'])); end

simout = sim(mdl);
res = struct();
res.t = simout.vOut.Time; res.vOut = simout.vOut.Data; res.iL = simout.iL.Data;
res.dcmd = simout.dcmd.Data;
res.iLref = simout.iLref.Data; res.vSW = simout.vSW.Data;
% The applied duty is a DISCRETE signal (ZOH at Ts), so Simulink logs it only at
% its 1501 sample instants while the continuous states give 300001 points.
% Re-sample with zero-order hold so every field shares one time base -- using the
% raw vector with a logical mask built from res.t is an out-of-range error.
res.duty = interp1(simout.duty.Time, simout.duty.Data, res.t, 'previous', 'extrap');
res.cfg = d; res.modelPath = fullfile(outDir,[mdl '.slx']);
try, close_system(mdl,0); catch, end
end
