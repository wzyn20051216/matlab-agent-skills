function [xnext, wav] = sw_period_map(x, p)
%SW_PERIOD_MAP  One switching period of the closed-loop converter (Poincare map).
%
%   xnext = sw_period_map(x, p)
%   [xnext, wav] = sw_period_map(x, p)   also returns the in-period diagnostics
%
% WHY THIS EXISTS
% Phase 3A.5 accepted the switching-level cases by "the simulation converged
% within 60 ms". That is a finite-time observation, not a stability proof: a
% slowly growing oscillation can look settled inside a short window. This file
% implements the CLOSED-LOOP POINCARE MAP so the same converter can be analysed
% as a discrete-time system:
%
%   x_{k+1} = P(x_k),   x_k = state at the start of switching period k
%
% Local asymptotic stability of the periodic orbit is then exactly
%   max |eig(DP(x*))| < 1        (Floquet / monodromy multipliers)
%
% which is INDEPENDENT of the average model and of any settling-time heuristic.
%
% STATE VECTOR (layout defined once, in sw_state_layout.m)
%   x = [iL; vC; xI; dHist(1..np); yS; m(1..nd); (dxI)]
%     iL     inductor current                       [A]
%     vC     capacitor voltage                      [V]
%     xI     outer-loop integrator output            [A]   (dxI/dt has units A/s)
%     dHist  duty pipeline; dHist(1) is applied DURING this period, so
%            nDly = 1 means one period of computation delay
%     yS     sensor analog-filter state              [A]
%     m      last nd filtered measurements, m(1) newest
%     dxI    integrator slope held from the previous sample. PRESENT ONLY WHEN
%            sampPhase > 0: then the integrator runs from the period start to the
%            sample instant on the PREVIOUS slope, which is not a function of
%            (iL, vC, xI) and therefore must be a state. Carrying it is what makes
%            the map autonomous (hence Floquet-able) at a non-zero sample phase.
%
% SAMPLING PHASE (Phase 3A.6 Task 4)
%   sampPhase = 0  -> sample at the period boundary (the deployed baseline).
%                     Equivalent to the pre-Task-4 code path, unchanged.
%   sampPhase > 0  -> sample at sampPhase*Ts, inside the period. The duty is
%                     computed there and takes effect at the NEXT period
%                     boundary, so the effective delay is (1-sampPhase)*Ts.
%                     nDly >= 1 is required: a sample inside the period cannot
%                     change the duty before the next boundary (sw_state_layout
%                     rejects nDly = 0 rather than mislabelling it as zero delay).
% A non-zero phase therefore changes TWO things at once -- where on the ripple
% the current is measured, and how much delay the loop sees -- and the report
% separates them instead of attributing the whole effect to "sampling".
%
% PLANT (identical equations to build_buck_switching.m / sw_dual_sim.m)
%   vOut  = (vC + ESR*iL)/(1 + ESR/R)
%   iLoad = vOut/R
%   dvC/dt = (iL - iLoad)/C
%   vSW    = Vin - iL*RonSW    while the switch is on
%   vSW    = -(Vf + iL*RonD)   while the diode conducts
%   diL/dt = (vSW - vOut - iL*RL)/L
% Because the duty is held for the whole period and the carrier is a ramp
% starting at 0, the on-time is exactly d*Ts at the START of the period, so the
% period splits analytically into [0, d*Ts) on and [d*Ts, Ts) off. No event
% detection is needed and the map is smooth in d (important for the Jacobian).

L = sw_state_layout(p);
Ts = 1/p.fs; phi = L.phi;

iL = x(L.iIL); vC = x(L.iVC); xI = x(L.iXI);
if L.np >= 1, dHist = x(L.idx); else, dHist = []; end
yS = x(L.iYS);
if L.nd > 0, mbuf = x(L.iM); else, mbuf = []; end
if L.hasDxI, dxIold = x(L.iDxI); else, dxIold = 0; end

if phi <= 0
    %% ---------------- boundary sampling: pre-Task-4 path, unchanged ----------
    [dSat, dxI, w] = ctl_sample(iL, vC, xI, yS, mbuf, p, phi, L);
    yS = w.yS; mbuf = w.mbuf;

    if L.np == 0, dApply = dSat; else, dApply = dHist(1); end

    d = dApply;
    ton = min(max(d,0),1)*Ts;
    y = [iL; vC; xI];
    t = 0;
    if ton > 1e-15
        y = rk4(@(tt,yy) deriv(yy, 1, dxI, p), t, ton, y, p.Nsub);
        t = ton;
    end
    if Ts - t > 1e-15
        y = rk4(@(tt,yy) deriv(yy, 0, dxI, p), t, Ts, y, p.Nsub*(1-ton/Ts));
    end

    if L.np >= 1
        dHistNext = [dHist(2:end); dSat];
        xnext = [y(1); y(2); y(3); dHistNext; yS];
    else
        xnext = [y(1); y(2); y(3); yS];
    end
    if L.nd > 0, xnext = [xnext; mbuf]; end
    if L.hasDxI, xnext = [xnext; dxI]; end
else
    %% ---------------- in-period sampling: extended state --------------------
    tS = phi*Ts;
    dApply = dHist(1);            % latched at the previous period boundary

    % (1) plant from the period start to the sample instant, on the OLD slope
    [iL, vC] = prop_piece(iL, vC, 0, tS, dApply, Ts, p);
    xI = xI + dxIold*tS;

    % (2) measure and compute the new duty / slope at tS
    [dSat, dxI, w] = ctl_sample(iL, vC, xI, yS, mbuf, p, phi, L);
    yS = w.yS; mbuf = w.mbuf;

    % (3) plant from the sample instant to the period end, new slope
    [iL, vC] = prop_piece(iL, vC, tS, Ts, dApply, Ts, p);
    xI = xI + dxI*(Ts - tS);

    dHistNext = [dHist(2:end); dSat];
    xnext = [iL; vC; xI; dHistNext; yS];
    if L.nd > 0, xnext = [xnext; mbuf]; end
    xnext = [xnext; dxI];
end

if nargout > 1
    wav = w;
    wav.dApplied = dApply;
    wav.phi = phi;
end
end

% ---------------------------------------------------------------------------
function [dSat, dxI, w] = ctl_sample(iL, vC, xI, yS, mbuf, p, phi, L)
%CTL_SAMPLE  One control update, evaluated at a sampling instant.
% Shared by both branches so the boundary and in-period cases cannot drift.
[vOut, iLoad] = plant_out(iL, vC, p.R, p.ESR);

% sensor analog filter: one first-order update per sample (same as buck_dual_sim)
if p.sens.enable && isfinite(p.sens.fBW) && p.sens.fBW > 0
    aF = exp(-2*pi*p.sens.fBW*(1/p.fs));
    yS = aF*yS + (1-aF)*iLoad;
else
    yS = iLoad;
end
% transport delay: push the new filtered value, take the nd-samples-old one
if L.nd > 0
    mbuf = [yS; mbuf(1:end-1)];
    raw = mbuf(end);
else
    raw = yS;
end
if p.sens.enable
    iMeas = p.sens.gain*raw + p.sens.offset;
    if p.sens.lsb > 0, iMeas = p.sens.lsb*round(iMeas/p.sens.lsb); end
    iMeas = min(max(iMeas, 0), p.sens.iMaxPhys);
else
    iMeas = iLoad;
end

% current-loop feedback: sampled iL plus the ripple compensation for THIS phase
comp = ripple_comp(p, phi);
iSig = iL + comp;
vSig = vOut;

eRaw = p.Vref - vSig;
e    = min(max(eRaw, -p.Eclamp), p.Eclamp);

iLrefRaw = p.Kpe*e + xI;
if p.ff, iLrefRaw = iLrefRaw + iMeas; end
iLrefLim = min(max(iLrefRaw, p.Imin), p.Imax);

dRaw = p.Vref/p.Vin + p.Kci*(iLrefLim - iSig)/p.Vin;
dSat = min(max(dRaw, p.Dmin), p.Dmax);

% back-calculation anti-windup, identical to build_buck_switching.m
aw = (1/p.Tt) * ( (p.Vin/p.Kci)*(dSat - dRaw) + (iLrefLim - iLrefRaw) );
dxI = p.Kie*e + aw;

w = struct('yS',yS,'mbuf',mbuf,'dNext',dSat,'iMeas',iMeas,'iSig',iSig, ...
    'iLrefRaw',iLrefRaw,'iLrefLim',iLrefLim,'dRaw',dRaw,'e',e, ...
    'vOut',vOut,'iLoad',iLoad,'aw',aw,'comp',comp);
end

% ---------------------------------------------------------------------------
function [iL, vC] = prop_piece(iL, vC, t0, t1, d, Ts, p)
%PROP_PIECE  Propagate [t0,t1] with the duty held, splitting at the switch instant.
ton = min(max(d,0),1)*Ts;
edges = t0;
if ton > t0 + 1e-15 && ton < t1 - 1e-15, edges(end+1) = ton; end
edges(end+1) = t1;
for k = 1:numel(edges)-1
    a = edges(k); b = edges(k+1);
    if b - a <= 1e-15, continue; end
    sw = (a < ton - 1e-15);
    n = max(1, round(p.Nsub*(b-a)/Ts));
    y = rk4(@(tt,yy) deriv2(yy, sw, p), a, b, [iL; vC], n);
    iL = y(1); vC = y(2);
end
end

% ---------------------------------------------------------------------------
function dy = deriv(y, sw, dxI, p)
% sw = 1 switch on (diode off), 0 switch off (diode conducts); 3 states
iL = y(1); vC = y(2);
[vOut, iLoad] = plant_out(iL, vC, p.R, p.ESR);
if sw
    vSW = p.Vin - iL*p.RonSW;
else
    vSW = -(p.Vf + iL*p.RonD);
end
dy = [ (vSW - vOut - iL*p.RL)/p.L ; ...
       (iL - iLoad)/p.C ; ...
       dxI ];
end

function dy = deriv2(y, sw, p)
% two-state version used by prop_piece (xI is integrated analytically)
iL = y(1); vC = y(2);
[vOut, iLoad] = plant_out(iL, vC, p.R, p.ESR);
if sw
    vSW = p.Vin - iL*p.RonSW;
else
    vSW = -(p.Vf + iL*p.RonD);
end
dy = [ (vSW - vOut - iL*p.RL)/p.L ; ...
       (iL - iLoad)/p.C ];
end

function [vOut, iLoad] = plant_out(iL, vC, R, ESR)
vOut  = (vC + ESR*iL)/(1 + ESR/R);
iLoad = vOut/R;
end

function y = rk4(f, t0, t1, y, n)
% fixed-step RK4 over [t0,t1]; n is rounded up to at least 1 step
n = max(1, round(n));
h = (t1-t0)/n;
for k = 1:n
    k1 = f(0, y);
    k2 = f(0, y + 0.5*h*k1);
    k3 = f(0, y + 0.5*h*k2);
    k4 = f(0, y + h*k3);
    y = y + (h/6)*(k1 + 2*k2 + 2*k3 + k4);
end
end
