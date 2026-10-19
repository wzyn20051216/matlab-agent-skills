function r = boost_avg_sim(p, c, o)
%BOOST_AVG_SIM  Closed-loop simulation of the CCM average Boost model.
%
%   r = boost_avg_sim(p, c, o)
%
% Plant : boost_avg_f.m (CCM average, conduction losses, ESR)
% Control: discrete at fs, zero-order hold, o.nDly periods of computation delay
%          arch 'A' = single voltage PI acting on the duty
%          arch 'B' = inner current loop (proportional) + outer voltage PI
%
% WHY AN AVERAGE SIMULATOR AT ALL
% The controller comparison in Part 3 needs many designs (gain sweeps, line and
% load steps, bandwidth studies). The switching simulator costs ~1.5 s per run
% and adds ripple; the average model costs ~0.05 s and isolates the control
% question. The switching model is then used to VERIFY the chosen design, never
% to search it. The average model is CCM only: there is no DCM state here, so any
% operating point below the CCM boundary is out of scope by construction (the
% switching simulator is the one that detects it).
%
% c fields (all required unless noted):
%   arch 'A'|'B', Kp, Ki, Kci (B only), ff 0|1 (B only), D0,
%   Tt, Eclamp, Imax, Dmin, Dmax, Tss, Vref0(default 0)
% o fields: ratio[1], tStep[0.02], tEnd[0.06], nSub[100], nDly[1],
%           VinStep[0] (additive Vin change at tStep), recDecim[1]

if nargin < 3, o = struct(); end
if ~isfield(o,'ratio'),   o.ratio = 1; end
if ~isfield(o,'tStep'),   o.tStep = 0.02; end
if ~isfield(o,'tEnd'),    o.tEnd = 0.06; end
if ~isfield(o,'nSub'),    o.nSub = 100; end
if ~isfield(o,'nDly'),    o.nDly = 1; end
if ~isfield(o,'VinStep'), o.VinStep = 0; end
if ~isfield(o,'recDecim'),o.recDecim = 1; end
if ~isfield(c,'Vref0'),   c.Vref0 = 0; end

Ts = 1/p.fs;
h  = Ts/o.nSub;
nPer = round(o.tEnd/Ts);

xs = boost_steady(p, c.D0);               % start exactly on the design point
x = [xs.iL; xs.vC];
xI = 0;
dHist = repmat(c.D0, o.nDly, 1);
dPrev = c.D0;            % duty applied during the PREVIOUS period
Rcur = p.R; VinCur = p.Vin;
% The plant function reads R and ESR from a parameter struct, so the step must
% build a NEW struct. Passing Vin as an argument but leaving R inside p is how the
% first version produced a load step that never reached the plant (every dip read
% 0.00 %). Same failure mode as the Buck phase's p.R vs Rcur bug.
pCur = p;

nRec = nPer*o.nSub + 10;
rt = zeros(nRec,1); rv = zeros(nRec,1); ri = zeros(nRec,1);
rd = zeros(nRec,1); rr = zeros(nRec,1); rmode = zeros(nRec,1);
n = 0; stepDone = false;
dcmTime = 0; nClamp = 0;

for k = 1:nPer
    t = (k-1)*Ts;
    if ~stepDone && t >= o.tStep - 1e-15
        Rcur = p.R/o.ratio;
        VinCur = p.Vin + o.VinStep;
        pCur.R = Rcur;
        stepDone = true;
    end
    if t < c.Tss
        vref = c.Vref0 + (p.Vref - c.Vref0)*t/c.Tss;
    else
        vref = p.Vref;
    end

    % ---- measurement at the period boundary (average model: iL is already the
    % cycle average, so no half-ripple correction is needed here) ----
    % dPrev, NOT dHist(1): the state at the start of period k was produced by the
    % duty applied in period k-1. dHist(1) is the duty ABOUT to be applied, i.e. a
    % one-period lookahead in the output equation. It is invisible at steady state
    % and wrong during a transient.
    vOut = boost_avg_out(x, dPrev, VinCur, pCur);
    iL   = x(1);

    % ---- controller ----
    e = min(max(vref - vOut, -c.Eclamp), c.Eclamp);
    if c.arch == 'A'
        dRaw = c.D0 + c.Kp*e + xI;
        dSat = min(max(dRaw, c.Dmin), c.Dmax);
        dxI  = c.Ki*e + (1/c.Tt)*(dSat - dRaw);
        iLref = NaN;
    else
        ff = 0;
        % input-current feedforward: the inductor current IS the input current, and
        % the outer loop commands iLref, so the feedforward term is iLoad/(1-D).
        % It is OPTIONAL because it needs no extra sensor here (iL is already
        % measured by the inner loop) but does change the start-up behaviour.
        % Feedforward must be the LOAD current, not the measured inductor current:
        % iL is the quantity being regulated, so iL/(1-D0) closes a positive
        % feedback path of gain 1/(1-D0) ~= 2 and changes the loop, not just its
        % bias. Measured with the wrong term: vOut 47.9357 V (-0.13 %) instead of
        % 48.0000 V with ff = 0.
        if isfield(c,'ff') && c.ff, ff = (vOut/pCur.R)/(1 - c.D0); end
        iLrefRaw = c.Kpe*e + xI + ff;
        iLref = min(max(iLrefRaw, 0), c.Imax);
        dRaw = c.D0 + c.Kci*(iLref - iL)/p.Vref;
        dSat = min(max(dRaw, c.Dmin), c.Dmax);
        aw = (1/c.Tt)*((p.Vref/c.Kci)*(dSat - dRaw) + (iLref - iLrefRaw));
        dxI = c.Kie*e + aw;
    end

    if o.nDly >= 1, dApply = dHist(1); else, dApply = dSat; end

    % ---- plant: RK4 over the period with the duty held ----
    for q = 1:o.nSub
        k1 = boost_avg_f(x, dApply, pCur, VinCur);
        k2 = boost_avg_f(x + 0.5*h*k1, dApply, pCur, VinCur);
        k3 = boost_avg_f(x + 0.5*h*k2, dApply, pCur, VinCur);
        k4 = boost_avg_f(x + h*k3, dApply, pCur, VinCur);
        x = x + (h/6)*(k1 + 2*k2 + 2*k3 + k4);
        if x(1) < 0
            x(1) = 0; nClamp = nClamp + 1;   % counted, not silent: see dcm below
        end
        if mod(q-1, o.recDecim) == 0
            n = n + 1;
            rt(n) = t + q*h; ri(n) = x(1); rv(n) = boost_avg_out(x, dApply, VinCur, pCur);
            rd(n) = dApply;
            if c.arch == 'A', rr(n) = NaN; else, rr(n) = iLref; end
            rmode(n) = 1;
        end
    end
    % ---- CCM validity: the average model has no DCM state, so as soon as the
    % estimated valley reaches zero the model is outside its domain. It must SAY
    % SO; without this check it happily reports 48.000 V at R = 400 ohm while the
    % switching model gives 56.6 V (measured).
    dILper = (VinCur - x(1)*(pCur.RL + pCur.RonSW))*dApply*Ts/pCur.L;
    if (x(1) - dILper/2) <= 0, dcmTime = dcmTime + Ts; end

    xI = xI + dxI*Ts;
    dPrev = dApply;
    if o.nDly >= 1, dHist = [dHist(2:end); dSat]; end
end

r = struct();
r.t = rt(1:n); r.vOut = rv(1:n); r.iL = ri(1:n); r.duty = rd(1:n); r.iLref = rr(1:n);
r.cfg = c; r.opt = o; r.Rpost = Rcur; r.VinPost = VinCur;
% validity of the CCM average model on this run
r.dcmTime  = dcmTime;
r.dcmFrac  = dcmTime/(nPer*Ts);
r.nClamp   = nClamp;
r.valid    = (dcmTime == 0) && (nClamp == 0);
r.invalidReason = '';
if dcmTime > 0, r.invalidReason = 'DCM: valley current reached zero'; end
if nClamp  > 0, r.invalidReason = [r.invalidReason ' iL clamped at zero']; end
end
