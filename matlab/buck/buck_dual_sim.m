function r = buck_dual_sim(cfg)
%BUCK_DUAL_SIM  Average-model simulation of the dual loop with a DIGITAL controller.
%
%   r = buck_dual_sim(cfg)
%
% Architecture
%   vC --[PI outer, sampled]--> iLref --[P inner]--> d --[ZOH + delay]--> Buck
%
% The controller is evaluated ONCE PER SWITCHING PERIOD at t = k*Ts using the
% state at that instant, and the resulting duty command is applied
% cfg.delaySamples periods later. This models
%   - ADC sampling at the carrier boundary,
%   - one period of computation,
%   - PWM update with zero-order hold.
% cfg.delaySamples = 1 corresponds to a single-update PWM with one period of
% computation; 0.5 is the "sample in the middle of the period and update at the
% boundary" case (not supported here, use delaySamples=1 for conservatism).
%
% Plant (average model, CCM, lossless):
%   d iL/dt = ( Vin*d - vC ) / L
%   d vC/dt = ( iL - vC/R ) / C
% where R switches from cfg.R to cfg.R*cfg.ratioLoad... see cfg.ratio.
%
% Saturation (both are enforced, with back-calculation on the outer integrator)
%   iLref in [cfg.Imin, cfg.Imax]
%   d     in [cfg.Dmin, cfg.Dmax]
%   dxe/dt = e + (d_sat - d_raw)*Vin/Kci        (equivalent current-error units)
%
% cfg fields (defaults in brackets)
%   Vin, Vref [12], L, C, R, fs [50e3]
%   Kci, Kpe, Kie
%   ratio      [2]     conductance multiplier at the load step (R -> R/ratio)
%   Dmin,Dmax  [0.05, 0.85]
%   Imin,Imax  [0, 20]
%   Tt         [1e-3]  back-calculation tracking time constant [s]
%   tStep      [0.06]  load-step instant [s]
%   tEnd       [0.12]  end of the simulation [s]
%   delaySamples [1]
%   nSub       [8]     RK4 substeps per switching period
%   x0         []      if empty: start from the exact pre-step steady state
%   vCinit     []      if set, vC starts here (startup test)
%
% Output
%   r.t, r.vC, r.iL, r.d, r.iLref, r.xe  (sampled at the control rate)
%   r.tf, r.vCf, r.iLf                   (fine grid, nSub per period)
%   r.dMin, r.dMax, r.iLMax, r.iLRefMax
%   r.ratio, r.R1

if ~isfield(cfg,'Vref'),  cfg.Vref = 12; end
if ~isfield(cfg,'fs'),    cfg.fs = 50e3; end
if ~isfield(cfg,'ratio'), cfg.ratio = 2; end
if ~isfield(cfg,'Dmin'),  cfg.Dmin = 0.05; end
if ~isfield(cfg,'Dmax'),  cfg.Dmax = 0.85; end
if ~isfield(cfg,'Imin'),  cfg.Imin = 0; end
if ~isfield(cfg,'Imax'),  cfg.Imax = 20; end
if ~isfield(cfg,'tStep'), cfg.tStep = 0.06; end
if ~isfield(cfg,'tEnd'),  cfg.tEnd = 0.12; end
if ~isfield(cfg,'delaySamples'), cfg.delaySamples = 1; end
if ~isfield(cfg,'nSub'),  cfg.nSub = 8; end
if ~isfield(cfg,'Tt'),    cfg.Tt = 1e-3; end
if ~isfield(cfg,'ff'),    cfg.ff = 0; end
if ~isfield(cfg,'supEnable'), cfg.supEnable = true; end
if ~isfield(cfg,'tFFoff'), cfg.tFFoff = []; end
if ~isfield(cfg,'tFFon'),  cfg.tFFon  = []; end

Ts = 1/cfg.fs;
R1 = cfg.R/cfg.ratio;
dSS = cfg.Vref/cfg.Vin;                       % steady-state duty (pre-step)
iL0 = cfg.Vref/cfg.R;
% Pre-step integrator state.
%   ff=0 : iLref_ss = Kie*xe = iL0            -> xe0 = iL0/Kie
%   ff=1 : iLref_ss = Kie*xe + iLoad = iL0    -> xe0 = 0   (iLoad == iL0 here)
% Using iL0/Kie unconditionally for ff=1 DOUBLE COUNTS the load current: the
% model then commands iLref = 2*iL0 at t=0 and produces a ~0.93 V spurious
% transient from a state that is not actually steady (Phase 3A.5 defect A1).
if cfg.ff
    xe0 = 0;
else
    xe0 = iL0/cfg.Kie;
end
if isfield(cfg,'x0') && ~isempty(cfg.x0)
    x = cfg.x0(:);
else
    x = [iL0; cfg.Vref; xe0];
    if isfield(cfg,'vCinit') && ~isempty(cfg.vCinit)
        x(2) = cfg.vCinit;
        if ~isfield(cfg,'keepXe') || ~cfg.keepXe
            x(3) = 0;                          % cold start: no integral preload
        end
    end
end

nTotal = round(cfg.tEnd/Ts);
tOut = zeros(nTotal+1,1); yOut = zeros(nTotal+1,3); dOut = zeros(nTotal+1,1);
iRefOut = zeros(nTotal+1,1);
hFine = Ts/cfg.nSub;
nFine = nTotal*cfg.nSub + 1;
tfOut = zeros(nFine,1); vcfOut = zeros(nFine,1); ilfOut = zeros(nFine,1);

dq = zeros(cfg.delaySamples+1,1);             % delay line, holds duty commands
dq(:) = dSS;

t = 0; k = 0; fi = 1;
tOut(1) = 0; yOut(1,:) = x.'; dOut(1) = dSS; iRefOut(1) = iL0;
tfOut(1) = 0; vcfOut(1) = x(2); ilfOut(1) = x(1);

% ---------- load-current sensor model + feedforward supervisor ----------
% DUAL-B needs a MEASURED load current. This block models everything between
% the physical current and the number the controller sees:
%   analog bandwidth pole -> transport delay -> gain error -> offset ->
%   Gaussian noise -> ADC quantization -> injected faults
% Every one of these is an ENGINEERING ASSUMPTION chosen for this study; none of
% them comes from a real sensor datasheet (see the report, Task 2).
if ~isfield(cfg,'sens') || isempty(cfg.sens), cfg.sens = struct(); end
sd = struct('enable',false,'fBW',inf,'delayS',0,'gain',1,'offset',0, ...
            'sigma',0,'lsb',0,'seed',7,'stuckAt',[],'oorAt',[],'tol',3.0, ...
            'iMaxPhys',1.25*cfg.Vref/1.5);
sf = fieldnames(cfg.sens);
for q = 1:numel(sf), sd.(sf{q}) = cfg.sens.(sf{q}); end
cfg.sens = sd;
sensY = 0;                                     % analog filter state
sensBuf = zeros(max(sd.delayS,0)+1,1);         % transport delay line
sensStuck = false; sensStuckVal = 0;
rng(sd.seed);                                  % deterministic noise -> S9
ffOn = logical(cfg.ff);                        % supervisor output
vCprev = x(2);
faultCnt = 0; healthyCnt = 1e6;
measHist = zeros(8,1); histIdx = 1;
nTrip = 0; nRecover = 0; iFF = 0;
iMeasLog = zeros(nTotal+1,1); ffLog = false(nTotal+1,1); faultLog = false(nTotal+1,1);
iMeasLog(1) = x(2)/cfg.R; ffLog(1) = ffOn;

awTerm = 0;                                    % held over the period
while k < nTotal
    % ---------- control instant ----------
    Rnow = cfg.R; if t >= cfg.tStep, Rnow = R1; end
    % Optional soft start: the reference ramps 0 -> Vref over cfg.Tss.
    % Needed because the outer loop bandwidth (~1 kHz, 0.5 ms) is much faster
    % than the startup charging transient (~0.3 ms), so with a 12 V step the
    % integrator accumulates monotonically and the output overshoots by 25-36 %.
    % BASE/OPT do not need this: their integral gain is ~700x smaller, so their
    % startup is intrinsically slow and the loop tracks it.
    vrefEff = cfg.Vref;
    if isfield(cfg,'Tss') && ~isempty(cfg.Tss) && cfg.Tss > 0 && t < cfg.Tss
        vrefEff = cfg.Vref*max(t,0)/cfg.Tss;
    end
    e = vrefEff - x(2);
    % Error clamp (setpoint conditioning). Without it the proportional term
    % commands Kp_e*12 = 21.6 A at startup, far beyond any sane current, and the
    % outer integrator winds up while the duty is railed. Clamping e limits the
    % over-command. It does NOT touch the load-step response because there
    % |e| <= 1.5 V < Eclamp.
    if isfield(cfg,'Eclamp') && ~isempty(cfg.Eclamp) && isfinite(cfg.Eclamp)
        e = min(max(e, -cfg.Eclamp), cfg.Eclamp);
    end
    % ---------- load-current measurement ----------
    iLoadTrue = x(2)/Rnow;
    if sd.enable
        if isfinite(sd.fBW) && sd.fBW > 0
            aF = exp(-2*pi*sd.fBW*Ts);
            sensY = aF*sensY + (1-aF)*iLoadTrue;   % analog bandwidth pole
        else
            sensY = iLoadTrue;
        end
        sensBuf = [sensY; sensBuf(1:end-1)];       % transport delay
        iMeas = sensBuf(end);
        iMeas = sd.gain*iMeas + sd.offset;         % gain error / zero offset
        if sd.sigma > 0, iMeas = iMeas + sd.sigma*randn; end
        if sd.lsb > 0, iMeas = sd.lsb*round(iMeas/sd.lsb); end
        if ~isempty(sd.stuckAt) && t >= sd.stuckAt
            if ~sensStuck, sensStuck = true; sensStuckVal = iMeas; end
            iMeas = sensStuckVal;                  % frozen reading
        end
        if ~isempty(sd.oorAt) && t >= sd.oorAt, iMeas = 1.6*cfg.Imax; end
    else
        iMeas = iLoadTrue;
    end
    % Physically plausible range. The load current cannot exceed Vref/Rmin
    % (Rmin = 1.5 ohm -> 8 A), so anything outside [0, 1.25*8] is a hardware
    % reading error. Clamping here means a railed sensor can never inject its
    % full value into the current command, even before the supervisor reacts.
    hardBad = (iMeas < -0.5) || (iMeas > 1.2*sd.iMaxPhys);
    iMeas = min(max(iMeas, 0), sd.iMaxPhys);

    % ---------- plausibility check (analytical redundancy) ----------
    % The controller already has iL and vC, so iLoad is reconstructable:
    %   iLoad = iL - C*dvC/dt
    % Comparing the sensor against that estimate catches gross faults (frozen,
    % open, railed) with no extra hardware. The derivative is noisy so the
    % tolerance is generous, and three consecutive bad samples are required.
    dvCdt = (x(2) - vCprev)/Ts;
    iLoadEst = x(1) - cfg.C*dvCdt;
    measHist(histIdx) = iMeas; histIdx = mod(histIdx,8)+1;
    frozen = (max(measHist)-min(measHist) < 1e-9) && (abs(dvCdt) > 50);
    bad = hardBad || frozen || (abs(iMeas - iLoadEst) > sd.tol);
    if bad
        faultCnt = faultCnt + 1; healthyCnt = 0;
    else
        faultCnt = 0; healthyCnt = healthyCnt + 1;
    end
    % A RANGE violation is unambiguous, so it trips on the FIRST sample -- with
    % a railed sensor every sample of delay is 1.6 A of wrong current command.
    % The plausibility / frozen tests are noise-prone, so they need 3 samples.
    if ~cfg.supEnable
        ffCmd = logical(cfg.ff);
    elseif hardBad || faultCnt >= 3
        ffCmd = false;
    elseif healthyCnt >= 20
        ffCmd = logical(cfg.ff);
    else
        ffCmd = ffOn;
    end
    if ~isempty(cfg.tFFoff) && t >= cfg.tFFoff, ffCmd = false; end
    if ~isempty(cfg.tFFon)  && t >= cfg.tFFon,  ffCmd = true;  end

    % ---------- bumpless transfer ----------
    % iLref = Ki_e*xe + ff*iLoad. Toggling ff changes the command by the whole
    % load current unless the integrator absorbs it, which would put a step on
    % the inner loop. Shifting xe by -+iLoad/Ki_e keeps iLref continuous.
    % On a TRIP the value to remove is the one that was actually in the last
    % command (iFF), not the current -- possibly railed -- reading. Using the
    % broken reading here would push the integrator by its full value.
    if ffCmd && ~ffOn
        x(3) = x(3) - iMeas/cfg.Kie; nRecover = nRecover + 1;
    elseif ~ffCmd && ffOn
        x(3) = x(3) + iFF/cfg.Kie;   nTrip = nTrip + 1;
    end
    ffOn = ffCmd;
    vCprev = x(2);

    iRefRaw = cfg.Kpe*e + cfg.Kie*x(3);
    if ffOn, iRefRaw = iRefRaw + iMeas; iFF = iMeas; else, iFF = 0; end
    iRef = min(max(iRefRaw, cfg.Imin), cfg.Imax);
    dRaw = cfg.Vref/cfg.Vin + cfg.Kci*(iRef - x(1))/cfg.Vin;
    dSat = min(max(dRaw, cfg.Dmin), cfg.Dmax);
    % Back-calculation anti-windup, identical in structure and gain to the
    % Simulink model (build_buck_dual_loop.m):
    %   dxI/dt = Ki_e*e + (1/Tt)*( (dSat-dRaw)*Vin/Kci + (iRef - iRefRaw) )
    % with xI = Ki_e*xe, so in terms of xe:
    %   dxe/dt = e + (1/Tt)*( ... )/Ki_e
    % The 1/Tt gain MUST scale with the forward gain: Phase 3A.2 used Tt=1 ms
    % with Ki=7.9, this design has Ki_e=4000-5500, i.e. 700x the forward gain,
    % and the same 1/Tt then leaves the integrator winding up during startup
    % (measured S6 = 25-36 %). See the Tt sweep in the report.
    dIref  = iRef - iRefRaw;
    dDuty  = (dSat - dRaw)*cfg.Vin/cfg.Kci;
    awTerm = (1/cfg.Tt) * (dDuty + dIref) / cfg.Kie;
    % push into the delay line; the duty applied now was issued delaySamples ago
    dq = [dSat; dq(1:end-1)];
    dApply = dq(end);

    % ---------- integrate one switching period with constant d ----------
    Rhere = Rnow;
    nSub = cfg.nSub;
    for j = 1:nSub
        x = rk4_step(x, dApply, cfg, Rhere, hFine, e, awTerm);
        fi = fi + 1;
        tfOut(fi) = t + j*hFine;
        vcfOut(fi) = x(2);
        ilfOut(fi) = x(1);
    end
    t = t + Ts; k = k + 1;
    tOut(k+1) = t; yOut(k+1,:) = x.'; dOut(k+1) = dApply; iRefOut(k+1) = iRef;
    iMeasLog(k+1) = iMeas; ffLog(k+1) = ffOn; faultLog(k+1) = bad;
end

r = struct();
r.t = tOut; r.vC = yOut(:,2); r.iL = yOut(:,1); r.xe = yOut(:,3);
r.d = dOut; r.iLref = iRefOut;
r.tf = tfOut; r.vCf = vcfOut; r.iLf = ilfOut;
r.dMin = min(dOut); r.dMax = max(dOut);
r.iLMax = max(ilfOut); r.iLRefMax = max(iRefOut);
r.ratio = cfg.ratio; r.R1 = R1; r.cfg = cfg;
% sensor / supervisor observability
r.iLoadMeas = iMeasLog; r.ffOn = ffLog; r.faultFlag = faultLog;
r.nTrip = nTrip; r.nRecover = nRecover;
Rpost = R1;
r.iLoadTrue = yOut(:,2)/Rpost;
pre = r.t < cfg.tStep;
r.iLoadTrue(pre) = yOut(pre,2)/cfg.R;
end

% ------------------------------------------------------------------
function dx = deriv(x, d, cfg, R, e, awTerm)
dx = [ (cfg.Vin*d - x(2))/cfg.L ; ...
       (x(1) - x(2)/R)/cfg.C ; ...
       e + awTerm ];
end

function x = rk4_step(x, d, cfg, R, h, e, awTerm)
k1 = deriv(x,             d, cfg, R, e, awTerm);
k2 = deriv(x + h/2*k1,    d, cfg, R, e, awTerm);
k3 = deriv(x + h/2*k2,    d, cfg, R, e, awTerm);
k4 = deriv(x + h*k3,      d, cfg, R, e, awTerm);
x = x + h/6*(k1 + 2*k2 + 2*k3 + k4);
end
