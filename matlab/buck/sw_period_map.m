function [xnext, wav] = sw_period_map(x, p)
%SW_PERIOD_MAP  One switching period of the closed-loop converter (Poincare map).
%
%   xnext = sw_period_map(x, p)
%   [xnext, wav] = sw_period_map(x, p)   also returns the in-period waveform
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
% STATE VECTOR
%   x = [iL; vC; xI; dHist(1..nDly); yS; m(1..nd)]
%     iL     inductor current                       [A]
%     vC     capacitor voltage                      [V]
%     xI     outer-loop integrator output            [A]   (dxI/dt has units A/s)
%     dHist  duty pipeline; dHist(1) is applied DURING this period, so
%            nDly = 1 means one period of computation delay
%     yS     sensor analog-filter state              [A]
%     m      last nd filtered measurements, m(1) newest
%
% SAMPLING AND DELAY (must match build_buck_switching.m with ctrlDelay = true)
%   measure at the start of period k  ->  compute duty  ->  apply in period k+1
% The map is therefore autonomous for constant R, which is what makes the
% Floquet analysis valid. sampPhase must be 0 (boundary sampling); the deployed
% configuration is boundary sampling + half-ripple compensation, so this is the
% case that matters. Any other phase would need the previous duty-rate in the
% state and is rejected rather than silently mis-modelled.
%
% PLANT (identical equations to build_buck_switching.m)
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

Vin = p.Vin; L = p.L; C = p.C; R = p.R; Ts = 1/p.fs;
if p.sampPhase ~= 0
    error('sw_period_map:sampPhase', ...
        'only boundary sampling (sampPhase=0) is modelled; got %g', p.sampPhase);
end

iL = x(1); vC = x(2); xI = x(3);
nDly = p.nDly; nd = p.sens.nd;
if nDly >= 1
    dHist = x(4:3+nDly); yS = x(4+nDly); base = 4+nDly;
    dApply = dHist(1);                     % decided in an earlier period
else
    dHist = []; yS = x(4); base = 4;
    dApply = NaN;                          % filled in by the control law below
end
if nd > 0, mbuf = x(base+1:base+nd); else, mbuf = []; end

%% ---- 1) MEASUREMENT AND CONTROL AT THE PERIOD BOUNDARY (sample instant) ----
[vOut, iLoad] = plant_out(iL, vC, R, p.ESR);

% sensor analog filter: one first-order update per sample (same as buck_dual_sim)
if p.sens.enable && isfinite(p.sens.fBW) && p.sens.fBW > 0
    aF = exp(-2*pi*p.sens.fBW*Ts);
    yS = aF*yS + (1-aF)*iLoad;
else
    yS = iLoad;
end
% transport delay: push the new filtered value, take the nd-samples-old one
if nd > 0
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

% current-loop feedback: sampled iL plus the analytic half-ripple compensation
if p.rippleComp
    comp = (p.Vin - p.Vref)*(p.Vref/p.Vin)*Ts/(2*p.L);
else
    comp = 0;
end
iSig = iL + comp;
vSig = vOut;

eRaw = p.Vref - vSig;
e    = min(max(eRaw, -p.Eclamp), p.Eclamp);

iLrefRaw = p.Kpe*e + xI;
if p.ff, iLrefRaw = iLrefRaw + iMeas; end
iLrefLim = min(max(iLrefRaw, p.Imin), p.Imax);

dRaw = p.Vref/Vin + p.Kci*(iLrefLim - iSig)/Vin;
dSat = min(max(dRaw, p.Dmin), p.Dmax);

% back-calculation anti-windup, identical to build_buck_switching.m
aw = (1/p.Tt) * ( (Vin/p.Kci)*(dSat - dRaw) + (iLrefLim - iLrefRaw) );
dxI = p.Kie*e + aw;

if nDly == 0, dApply = dSat; end      % zero computation delay: applied at once

%% ---- 2) PROPAGATE THE PERIOD WITH THE HELD DUTY ----
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

if nDly >= 1
    dHistNext = [dHist(2:end); dSat];
    xnext = [y(1); y(2); y(3); dHistNext; yS];
else
    xnext = [y(1); y(2); y(3); yS];
end
if nd > 0, xnext = [xnext; mbuf]; end

if nargout > 1
    wav = struct('iL_end', y(1), 'vC_end', y(2), 'xI_end', y(3), ...
        'dNext', dSat, 'dApplied', d, 'iMeas', iMeas, 'iSig', iSig, ...
        'iLrefRaw', iLrefRaw, 'iLrefLim', iLrefLim, 'dRaw', dRaw, ...
        'e', e, 'vOut', vOut, 'iLoad', iLoad, 'aw', aw);
end
end

% ---------------------------------------------------------------------------
function dy = deriv(y, sw, dxI, p)
% sw = 1 switch on (diode off), 0 switch off (diode conducts)
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
