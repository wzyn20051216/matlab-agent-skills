function r = boost_sw_sim(p, c, o)
%BOOST_SW_SIM  Switching-level Boost converter with a discrete dual-loop controller.
%
%   r = boost_sw_sim(p, c, o)
%
% DIFFERENCE FROM THE AVERAGE MODEL (boost_avg_sim.m)
% The average model weights the two switch states by d and has no notion of the
% diode; it is valid only in CCM. This file integrates the actual sequence within
% each period and enforces the DIODE'S UNIDIRECTIONAL CONDUCTION:
%
%   ON       switch closed, diode reverse biased, capacitor feeds the load
%   OFF      switch open, diode conducts while iL > 0
%   DCM      iL has reached 0 before the period ends: both devices off, the
%            inductor is open, the capacitor feeds the load alone
%
% When the current would go negative it is clamped to zero and the period is
% marked as DCM. That is a MODEL VALIDITY event, not a numerical detail: the
% controller design and the acceptance thresholds in this phase are derived for
% CCM, so any run that spends time in DCM is reported as UNDETERMINED rather than
% PASS. (This is the rule the brief asks for: never let a non-physical state keep
% integrating and then report success.)
%
% c: same controller struct as boost_avg_sim (arch 'A' or 'B')
% o: ratio[1], tStep[0.02], tEnd[0.06], nSub[200], nDly[1], Tss[1e-9],
%    VinStep[0], seed[0], noise[false], Vref0[]
%
% OUTPUT r: t, vOut, iL, duty, iLref, iMeas (waveform, decimated),
%           iLpeak/iLvalley/iLavg per period, dcm fraction per period,
%           dcmTime (total time in DCM), cfg, opt

if nargin < 3, o = struct(); end
if ~isfield(o,'ratio'),   o.ratio = 1; end
if ~isfield(o,'tStep'),   o.tStep = 0.02; end
if ~isfield(o,'tEnd'),    o.tEnd = 0.06; end
if ~isfield(o,'nSub'),    o.nSub = 200; end
if ~isfield(o,'nDly'),    o.nDly = 1; end
if ~isfield(o,'Tss'),     o.Tss = 1e-9; end
if ~isfield(o,'VinStep'), o.VinStep = 0; end
if ~isfield(o,'noise'),   o.noise = false; end
if ~isfield(o,'seed'),    o.seed = 0; end
if ~isfield(o,'Vref0'),   o.Vref0 = []; end
if isempty(o.Vref0)
    if o.Tss > 1e-6, o.Vref0 = 0; else, o.Vref0 = p.Vref; end
end

Ts = 1/p.fs; h = Ts/o.nSub; nPer = round(o.tEnd/Ts);
xs = boost_steady(p, c.D0);
iL = xs.iL; vC = xs.vC; xI = 0;
dHist = repmat(c.D0, o.nDly, 1);
Rcur = p.R; VinCur = p.Vin; pCur = p;
if o.noise, rng(o.seed); else, rng(0); end

% nominal half-ripple compensation, same convention as the Buck phase: at the
% period boundary the sample sits on the ripple VALLEY, so the cycle average is
% iL_sampled + dIL/2. dIL uses the nominal operating point, not the live duty.
dILn = (p.Vin - xs.iL*(p.RL + p.RonSW))*c.D0*Ts/p.L;
comp = dILn/2;

dec = max(1, round(o.nSub/40));
nRec = nPer*ceil(o.nSub/dec) + 10;
rt = zeros(nRec,1); rv = zeros(nRec,1); ri = zeros(nRec,1);
rd = zeros(nRec,1); rr = zeros(nRec,1); rm = zeros(nRec,1);
n = 0;
rILpk = zeros(nPer,1); rILvl = zeros(nPer,1); rILav = zeros(nPer,1); rDcm = zeros(nPer,1);

stepDone = false;
for k = 1:nPer
    t0 = (k-1)*Ts;
    if ~stepDone && t0 >= o.tStep - 1e-15
        Rcur = p.R/o.ratio; VinCur = p.Vin + o.VinStep;
        pCur.R = Rcur; stepDone = true;
    end
    if t0 < o.Tss, vref = o.Vref0 + (p.Vref-o.Vref0)*t0/o.Tss; else, vref = p.Vref; end

    % ---- measurement at the period boundary ----
    % At the boundary the diode is still conducting (the ON edge comes next), so
    % the capacitor current includes iL. Sampling exactly ON the edge makes this a
    % convention, and the convention is stated: measured with vOut evaluated
    % BEFORE the edge.
    vOut = out_v(iL, vC, iL, pCur);
    iMeas = iL;
    if isfield(c,'sens') && c.sens.enable
        iMeas = c.sens.gain*iL + c.sens.offset;
        if o.noise && c.sens.sigma > 0, iMeas = iMeas + c.sens.sigma*randn; end
        if c.sens.lsb > 0, iMeas = c.sens.lsb*round(iMeas/c.sens.lsb); end
        iMeas = min(max(iMeas,0), c.sens.iMaxPhys);
    end

    % ---- controller ----
    e = min(max(vref - vOut, -c.Eclamp), c.Eclamp);
    if c.arch == 'A'
        dRaw = c.D0 + c.Kp*e + xI;
        dSat = min(max(dRaw, c.Dmin), c.Dmax);
        dxI  = c.Ki*e + (1/c.Tt)*(dSat - dRaw);
        iLref = NaN;
    else
        ff = 0;
        % load-current feedforward, NOT the measured inductor current: iL is the
        % regulated quantity, so iL/(1-D0) is a positive feedback of gain ~2 that
        % changes the loop rather than compensating the load. Same defect was
        % found and fixed in boost_avg_sim.m.
        if isfield(c,'ff') && c.ff, ff = (vOut/pCur.R)/(1 - c.D0); end
        iLrefRaw = c.Kpe*e + xI + ff;
        iLref = min(max(iLrefRaw, 0), c.Imax);
        iSig = iMeas + comp;
        dRaw = c.D0 + c.Kci*(iLref - iSig)/p.Vref;
        dSat = min(max(dRaw, c.Dmin), c.Dmax);
        aw = (1/c.Tt)*((p.Vref/c.Kci)*(dSat - dRaw) + (iLref - iLrefRaw));
        dxI = c.Kie*e + aw;
    end
    if o.nDly >= 1, dApply = dHist(1); else, dApply = dSat; end

    % ---- propagate the period with the duty held ----
    ton = min(max(dApply,0),1)*Ts;
    t = 0; z = [iL; vC]; dcmT = 0; ipk = iL; ivl = iL; iavg = 0; nsub = 0;
    inDcm = false;
    while t < Ts - 1e-15
        segEnd = min(t + h, Ts);
        if t < ton - 1e-15
            segEnd = min(segEnd, ton);              % do not straddle the switch
        end
        dt = segEnd - t;
        % state for this segment
        if t < ton - 1e-15
            st = 1;                              % ON
        elseif inDcm || z(1) <= 0
            st = 0;                              % DCM: inductor open
        else
            st = 2;                              % OFF, diode conducts
        end
        y0 = z; 
        k1 = dfs(z,st,pCur,VinCur); k2 = dfs(z+0.5*dt*k1,st,pCur,VinCur);
        k3 = dfs(z+0.5*dt*k2,st,pCur,VinCur); k4 = dfs(z+dt*k3,st,pCur,VinCur);
        z = z + (dt/6)*(k1+2*k2+2*k3+k4);
        if st == 2 && z(1) < 0
            % the diode cannot conduct backwards: clamp and enter DCM
            z(1) = 0; inDcm = true;
        end
        iIn = 0; if st == 2, iIn = z(1); end
        vO = out_v(z(1), z(2), iIn, pCur);
        ipk = max(ipk, z(1)); ivl = min(ivl, z(1));
        iavg = iavg + 0.5*(y0(1)+z(1))*dt;
        if inDcm, dcmT = dcmT + dt; end
        t = segEnd; nsub = nsub + 1;
        if mod(nsub-1, dec) == 0
            n = n + 1;
            rt(n) = t0 + t; rv(n) = vO; ri(n) = z(1); rd(n) = dApply;
            if c.arch == 'A', rr(n) = NaN; else, rr(n) = iLref; end
            rm(n) = iMeas;
        end
    end
    iL = z(1); vC = z(2);
    if iL < 0, iL = 0; end
    xI = xI + dxI*Ts;
    if o.nDly >= 1, dHist = [dHist(2:end); dSat]; end
    rILpk(k) = ipk; rILvl(k) = ivl; rILav(k) = iavg/Ts; rDcm(k) = dcmT/Ts;
end

r = struct();
r.t = rt(1:n); r.vOut = rv(1:n); r.iL = ri(1:n);
r.duty = rd(1:n); r.iLref = rr(1:n); r.iMeas = rm(1:n);
r.tPer = (0:nPer-1).'*Ts;
r.iLpeak = rILpk; r.iLvalley = rILvl; r.iLavg = rILav; r.dcmFrac = rDcm;
r.dcmTime = sum(rDcm)*Ts;
r.dcmPeriods = nnz(rDcm > 1e-9);
r.cfg = c; r.opt = o; r.Rpost = Rcur; r.VinPost = VinCur;
% DCM is a MODEL VALIDITY event: any time spent in DCM means the CCM design was
% not validated on this run. Callers must not grade it as PASS.
% r.dcmFrac is PER PERIOD (length nPer, set above); the run-level scalar gets its
% own name so the two can never be confused. Overwriting dcmFrac with the scalar
% here is what made the first version of boost_run_metrics crash.
r.dcmFracTotal = r.dcmTime/(nPer*Ts);
r.valid   = (r.dcmTime == 0);
r.invalidReason = '';
if r.dcmTime > 0
    r.invalidReason = sprintf('DCM for %.3f %% of the run', 100*r.dcmFracTotal);
end
end

% ---------------------------------------------------------------------------
function dy = dfs(z, st, p, Vin)
% st = 1 ON, 2 OFF with diode conducting, 0 DCM (inductor open)
iL = z(1); vC = z(2);
switch st
    case 1
        vOut = vC/(1 + p.ESR/p.R);
        dy = [(Vin - iL*(p.RL + p.RonSW))/p.L; -(vOut/p.R)/p.C];
    case 2
        vOut = (vC + p.ESR*iL)/(1 + p.ESR/p.R);
        dy = [(Vin - vOut - p.Vf - (p.RL + p.RonD)*iL)/p.L; (iL - vOut/p.R)/p.C];
    otherwise
        vOut = vC/(1 + p.ESR/p.R);
        dy = [0; -(vOut/p.R)/p.C];
end
end

function vO = out_v(iL, vC, iIn, p)
vO = (vC + p.ESR*iIn)/(1 + p.ESR/p.R);
end
