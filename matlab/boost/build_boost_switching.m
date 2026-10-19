function res = build_boost_switching(outDir, cfg)
%BUILD_BOOST_SWITCHING  Switching-level Boost Simulink project (.slx).
%
%   res = build_boost_switching(outDir, cfg)
%
% WHAT THIS MODEL IS
% The 48 V / 96 W Boost with an actual 50 kHz PWM, an ideal switch, a diode that
% conducts in one direction only, and the same discrete dual-loop controller as
% boost_sw_sim.m.
%
%   ON      switch closed, diode reverse biased, C feeds the load
%   OFF     switch open, diode conducts while iL > 0
%   DCM     iL reaches zero before the period ends; the diode cannot conduct
%           backwards, so the inductor is open and C feeds the load alone
%
% DCM IS ENFORCED BY THE INTEGRATOR, NOT BY A FLAG. iL is an "Integrator Limited"
% with a lower saturation of 0: when the OFF-state derivative would drive the
% current negative, the state stops at zero. That is exactly what the diode does,
% and it is why the model can be trusted in DCM instead of merely detecting it.
%
% The duty is latched once per switching period (Unit Delay at Ts) and compared
% with a sawtooth carrier, so the PWM is a real modulator rather than an average.
%
% cfg (defaults): Vin, R, Vref, fs, L, C, RL, RonSW, RonD, Vf, ESR,
%   loadStepTime[0.02], loadStepRatio[1], tStop[0.06], nSub[200], modelName,
%   Imax[8]

if nargin < 1 || isempty(outDir), outDir = getenv('BOOST_OUT'); end
if isempty(outDir), outDir = fullfile(pwd,'artifacts','validation','boost_b2'); end
outDir = strrep(outDir,'/',filesep);
if nargin < 2, cfg = struct(); end
if ~exist(outDir,'dir'), mkdir(outDir); end
here = fileparts(mfilename('fullpath')); addpath(here);

p = boost_params();
[dA, ~] = boost_designs(p, 650);
c = dA;

d = struct('Vin',p.Vin,'R',p.R,'Vref',p.Vref,'fs',p.fs,'L',p.L,'C',p.C, ...
    'RL',p.RL,'RonSW',p.RonSW,'RonD',p.RonD,'Vf',p.Vf,'ESR',p.ESR, ...
    'loadStepTime',0.02,'loadStepRatio',1,'tStop',0.06,'nSub',200, ...
    'modelName','boost_sw','Imax',8);
f = fieldnames(cfg); for k=1:numel(f), d.(f{k}) = cfg.(f{k}); end
c.Imax = d.Imax;
Ts = 1/d.fs; h = Ts/d.nSub;

mdl = regexprep(d.modelName,'[^A-Za-z0-9_]','_');
if bdIsLoaded(mdl), close_system(mdl,0); end
new_system(mdl); open_system(mdl);
add = @(nm,lib,varargin) add_block(lib,[mdl '/' nm],varargin{:});
lnk = @(a,b) add_line(mdl,a,b,'autorouting','on');

xs = boost_steady(p, c.D0);
rip = boost_ripple(p, c.D0);
iL0 = xs.iL - rip.dIL/2;          % start at the ripple VALLEY (period boundary)
if iL0 < 0, iL0 = xs.iL; end

%% ---------------- power stage ----------------
add('Vin','simulink/Sources/Constant','Value',num2str(d.Vin));

add('Rstep','simulink/Sources/Step','Time',num2str(d.loadStepTime), ...
    'Before','0','After','1');
add('Rdelta','simulink/Sources/Constant','Value',num2str(d.R*(1/d.loadStepRatio-1)));
add('Rprod','simulink/Math Operations/Product','Inputs','2');
lnk('Rstep/1','Rprod/1'); lnk('Rdelta/1','Rprod/2');
add('Rnow','simulink/Math Operations/Sum','Inputs','++');
add('Rbase','simulink/Sources/Constant','Value',num2str(d.R));
lnk('Rbase/1','Rnow/1'); lnk('Rprod/1','Rnow/2');
add('Gload','simulink/Math Operations/Math Function','Function','reciprocal');
lnk('Rnow/1','Gload/1');

% iL with the diode's unidirectional limit
add('iL_int','simulink/Continuous/Integrator Limited','InitialCondition',num2str(iL0));
% 1e6 A, not inf: "inf" is stored as an EXPRESSION, which makes the model depend on
% a base-workspace symbol and Simulink.findVars reports it. A finite ceiling keeps
% the model self-contained and is far above anything physical here.
set_param([mdl '/iL_int'],'LimitOutput','on','LowerSaturationLimit','0', ...
    'UpperSaturationLimit','1e6');
add('vC_int','simulink/Continuous/Integrator','InitialCondition',num2str(xs.vC));
add('d_zoh','simulink/Discrete/Unit Delay','SampleTime',num2str(Ts), ...
    'InitialCondition',num2str(c.D0));

% PWM: duty >= sawtooth
add('Carrier','simulink/Sources/Repeating Sequence', ...
    'rep_seq_t',sprintf('[0 %g]',Ts),'rep_seq_y','[0 1]');
add('PWM','simulink/Logic and Bit Operations/Relational Operator','Operator','>=');
lnk('d_zoh/1','PWM/1'); lnk('Carrier/1','PWM/2');
add('DiodeGate','simulink/Logic and Bit Operations/Logical Operator','Operator','NOT');
lnk('PWM/1','DiodeGate/1');

% iDiode = iL while the switch is off, else 0
add('iDiode','simulink/Math Operations/Product','Inputs','2');
lnk('iL_int/1','iDiode/1'); lnk('DiodeGate/1','iDiode/2');

% vOut = (vC + ESR*iDiode)/(1 + ESR/R)
add('One','simulink/Sources/Constant','Value','1');
add('ESR','simulink/Math Operations/Gain','Gain',num2str(d.ESR));
add('ESR_iD','simulink/Math Operations/Product','Inputs','2');
lnk('ESR/1','ESR_iD/1'); lnk('iDiode/1','ESR_iD/2');
add('vOut_num','simulink/Math Operations/Sum','Inputs','++');
lnk('vC_int/1','vOut_num/1'); lnk('ESR_iD/1','vOut_num/2');
add('ESR_G','simulink/Math Operations/Product','Inputs','2');
lnk('ESR/1','ESR_G/1'); lnk('Gload/1','ESR_G/2');
add('vOut_den','simulink/Math Operations/Sum','Inputs','++');
lnk('One/1','vOut_den/1'); lnk('ESR_G/1','vOut_den/2');
add('inv_den','simulink/Math Operations/Math Function','Function','reciprocal');
lnk('vOut_den/1','inv_den/1');
add('vOut','simulink/Math Operations/Product','Inputs','2');
lnk('vOut_num/1','vOut/1'); lnk('inv_den/1','vOut/2');
add('iOut','simulink/Math Operations/Product','Inputs','2');
lnk('vOut/1','iOut/1'); lnk('Gload/1','iOut/2');

% switch-node voltage: ON = RonSW*iL ; OFF = vOut + Vf + RonD*iL
add('RonSW','simulink/Math Operations/Gain','Gain',num2str(d.RonSW));
lnk('iL_int/1','RonSW/1');
add('RonD','simulink/Math Operations/Gain','Gain',num2str(d.RonD));
lnk('iL_int/1','RonD/1');
add('Vf','simulink/Sources/Constant','Value',num2str(d.Vf));
add('vSW_off','simulink/Math Operations/Sum','Inputs','+++');
lnk('vOut/1','vSW_off/1'); lnk('Vf/1','vSW_off/2'); lnk('RonD/1','vSW_off/3');
add('SW','simulink/Signal Routing/Switch','Criteria','u2 >= Threshold','Threshold','0.5');
lnk('RonSW/1','SW/1'); lnk('PWM/1','SW/2'); lnk('vSW_off/1','SW/3');

% diL = (Vin - vSW - RL*iL)/L
add('RL','simulink/Math Operations/Gain','Gain',num2str(d.RL));
lnk('iL_int/1','RL/1');
add('vL','simulink/Math Operations/Sum','Inputs','+--');
lnk('Vin/1','vL/1'); lnk('SW/1','vL/2'); lnk('RL/1','vL/3');
add('invL','simulink/Math Operations/Gain','Gain',num2str(1/d.L));
lnk('vL/1','invL/1');
lnk('invL/1','iL_int/1');

% dvC = (iDiode - iOut)/C
add('iC','simulink/Math Operations/Sum','Inputs','+-');
lnk('iDiode/1','iC/1'); lnk('iOut/1','iC/2');
add('invC','simulink/Math Operations/Gain','Gain',num2str(1/d.C));
lnk('iC/1','invC/1');
lnk('invC/1','vC_int/1');

%% ---------------- controller ----------------
sig = build_boost_ctrl_sw(mdl, p, c, Ts, 'vOut/1', 'iL_int/1');

%% ---------------- logging ----------------
nm = {'vOut','iL','duty','iLref','iDiode','vSW'};
src = {sig.vOut, sig.iL, sig.d, sig.iLref, 'iDiode/1', 'SW/1'};
for q = 1:numel(nm)
    add([nm{q} '_sink'],'simulink/Sinks/To Workspace','VariableName',nm{q}, ...
        'SaveFormat','Timeseries');
    lnk(src{q},[nm{q} '_sink/1']);
end

set_param(mdl,'StopTime',num2str(d.tStop),'Solver','ode4', ...
    'SolverType','Fixed-step','FixedStep',num2str(h));
save_system(mdl, fullfile(outDir,[mdl '.slx']));

simout = sim(mdl);
res = struct();
res.t = simout.vOut.Time;
res.vOut = simout.vOut.Data; res.iL = simout.iL.Data;
res.iDiode = simout.iDiode.Data; res.vSW = simout.vSW.Data;
res.duty = interp1(simout.duty.Time, simout.duty.Data, res.t, 'previous', 'extrap');
res.iLref = interp1(simout.iLref.Time, simout.iLref.Data, res.t, 'previous', 'extrap');
res.cfg = d; res.ctrl = c; res.modelPath = fullfile(outDir,[mdl '.slx']);
res.substeps = d.nSub;
res.iL0 = iL0;
close_system(mdl,0);
end

% ---------------------------------------------------------------------------
function s = build_boost_ctrl_sw(mdl, p, c, Ts, vSrc, iSrc)
%BUILD_BOOST_CTRL_SW  Dual-loop controller + half-ripple compensation.
add_block('simulink/Discrete/Zero-Order Hold',[mdl '/zoh_v'],'SampleTime',num2str(Ts));
add_block('simulink/Discrete/Zero-Order Hold',[mdl '/zoh_i'],'SampleTime',num2str(Ts));
add_line(mdl,vSrc,'zoh_v/1','autorouting','on');
add_line(mdl,iSrc,'zoh_i/1','autorouting','on');

% The sample lands on the ripple valley, so the loop would regulate the valley.
% Adding the nominal half-ripple makes it regulate the cycle average. Nominal duty,
% not live duty: the error over the range is (d-D0)*Ts*(Vin-Vref)/(2L) ~ 0.03 A.
xs = boost_steady(p, c.D0);
dILn = (p.Vin - xs.iL*(p.RL + p.RonSW))*c.D0*Ts/p.L;
add_block('simulink/Sources/Constant',[mdl '/ripple_c'],'Value',num2str(dILn/2));
add_block('simulink/Math Operations/Sum',[mdl '/iL_sig'],'Inputs','++');
add_line(mdl,'zoh_i/1','iL_sig/1','autorouting','on');
add_line(mdl,'ripple_c/1','iL_sig/2','autorouting','on');

add_block('simulink/Sources/Constant',[mdl '/Vref'],'Value',num2str(p.Vref));
add_block('simulink/Math Operations/Sum',[mdl '/Err'],'Inputs','+-');
add_line(mdl,'Vref/1','Err/1','autorouting','on');
add_line(mdl,'zoh_v/1','Err/2','autorouting','on');
add_block('simulink/Discontinuities/Saturation',[mdl '/Eclamp']);
set_param([mdl '/Eclamp'],'LowerLimit',num2str(-c.Eclamp), ...
    'UpperLimit',num2str(c.Eclamp));
add_line(mdl,'Err/1','Eclamp/1','autorouting','on');
add_block('simulink/Math Operations/Gain',[mdl '/Kpe'],'Gain',num2str(c.Kpe));
add_line(mdl,'Eclamp/1','Kpe/1','autorouting','on');
add_block('simulink/Math Operations/Gain',[mdl '/Kie'],'Gain',num2str(c.Kie));
add_line(mdl,'Eclamp/1','Kie/1','autorouting','on');

add_block('simulink/Math Operations/Sum',[mdl '/iLrefRaw'],'Inputs','++');
add_line(mdl,'Kpe/1','iLrefRaw/1','autorouting','on');
add_block('simulink/Discontinuities/Saturation',[mdl '/iLrefLim']);
set_param([mdl '/iLrefLim'],'LowerLimit','0','UpperLimit',num2str(c.Imax));
add_line(mdl,'iLrefRaw/1','iLrefLim/1','autorouting','on');
add_block('simulink/Math Operations/Sum',[mdl '/iL_satdiff'],'Inputs','+-');
add_line(mdl,'iLrefLim/1','iL_satdiff/1','autorouting','on');
add_line(mdl,'iLrefRaw/1','iL_satdiff/2','autorouting','on');

add_block('simulink/Math Operations/Sum',[mdl '/iL_err'],'Inputs','+-');
add_line(mdl,'iLrefLim/1','iL_err/1','autorouting','on');
add_line(mdl,'iL_sig/1','iL_err/2','autorouting','on');
add_block('simulink/Math Operations/Gain',[mdl '/Kci_Vref'], ...
    'Gain',num2str(c.Kci/p.Vref));
add_line(mdl,'iL_err/1','Kci_Vref/1','autorouting','on');
add_block('simulink/Sources/Constant',[mdl '/D0'],'Value',num2str(c.D0));
add_block('simulink/Math Operations/Sum',[mdl '/d_raw'],'Inputs','++');
add_line(mdl,'Kci_Vref/1','d_raw/1','autorouting','on');
add_line(mdl,'D0/1','d_raw/2','autorouting','on');
add_block('simulink/Discontinuities/Saturation',[mdl '/D_lim']);
set_param([mdl '/D_lim'],'LowerLimit',num2str(c.Dmin),'UpperLimit',num2str(c.Dmax));
add_line(mdl,'d_raw/1','D_lim/1','autorouting','on');
add_line(mdl,'D_lim/1','d_zoh/1','autorouting','on');

add_block('simulink/Math Operations/Sum',[mdl '/d_satdiff'],'Inputs','+-');
add_line(mdl,'D_lim/1','d_satdiff/1','autorouting','on');
add_line(mdl,'d_raw/1','d_satdiff/2','autorouting','on');
add_block('simulink/Math Operations/Gain',[mdl '/Vref_Kci'], ...
    'Gain',num2str(p.Vref/c.Kci));
add_line(mdl,'d_satdiff/1','Vref_Kci/1','autorouting','on');
add_block('simulink/Math Operations/Sum',[mdl '/aw_sum'],'Inputs','++');
add_line(mdl,'Vref_Kci/1','aw_sum/1','autorouting','on');
add_line(mdl,'iL_satdiff/1','aw_sum/2','autorouting','on');
add_block('simulink/Math Operations/Gain',[mdl '/TtInv'],'Gain',num2str(1/c.Tt));
add_line(mdl,'aw_sum/1','TtInv/1','autorouting','on');
add_block('simulink/Math Operations/Sum',[mdl '/dxI'],'Inputs','++');
add_line(mdl,'Kie/1','dxI/1','autorouting','on');
add_line(mdl,'TtInv/1','dxI/2','autorouting','on');
add_block('simulink/Discrete/Discrete-Time Integrator',[mdl '/xI'], ...
    'SampleTime',num2str(Ts),'InitialCondition','0');
add_line(mdl,'dxI/1','xI/1','autorouting','on');
add_line(mdl,'xI/1','iLrefRaw/2','autorouting','on');

s = struct('vOut','vOut/1','iL','iL_int/1','d','d_zoh/1','iLref','iLrefLim/1');
end
