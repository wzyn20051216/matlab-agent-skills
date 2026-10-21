function r = sw_ref_sim(p, o)
%SW_REF_SIM  Independent time-domain reference for the sampling-phase extension.
%
%   r = sw_ref_sim(p, o)
%
% WHY A SECOND SIMULATOR
% Phase 3A.6 Task 4 extends the period map to non-zero sample phases, which adds
% a state (the held integrator slope) and a second propagation segment. A map
% that is extended and then checked against ITSELF proves nothing, so this file
% re-implements the same converter in the most different way that is still
% defensible:
%
%   * one global fixed-step RK4 loop, no matrix exponentials, no per-period
%     analytic split -- the opposite of the map, which propagates each switch
%     state with expm(A t);
%   * the step is shortened to land EXACTLY on each event (switch instant,
%     sample instant, period boundary), so no event is straddled;
%   * the derivative is written out once, from the same physical equations.
%
% The two implementations share only the parameter struct. Agreement to ~1e-9
% over hundreds of periods is then evidence that the map is right, not that both
% repeat the same mistake. The Simulink switching model is the third, fully
% independent implementation and is used as the final arbiter.
%
% OUTPUT
%   r.tb, r.iLb, r.vCb, r.xIb   state at each period boundary
%   r.t, r.vOut, r.iL           fine waveform (for plots / metric cross-checks)

if nargin < 2, o = struct(); end
if ~isfield(o,'nSub'),  o.nSub  = 4000; end
if ~isfield(o,'nPer'),  o.nPer  = 400;  end
if ~isfield(o,'Vref0'), o.Vref0 = 0;    end
if ~isfield(o,'Tss'),   o.Tss   = 5e-3; end

Ts = 1/p.fs; h = Ts/o.nSub; phi = p.sampPhase;
nd = p.sens.nd; np = p.nDly;
if phi > 0 && np < 1
    error('sw_ref_sim:delay','sampPhase>0 needs nDly>=1');
end

% initial state: defaults reproduce the map's cold start; o.x0 / o.d0 let a test
% start BOTH implementations from the same point, which is what a one-period
% comparison needs (a multi-period comparison hides a plant difference behind
% the contraction of a stable orbit).
iL = p.Vref/p.R; vC = p.Vref; xI = 0;
if isfield(o,'x0') && ~isempty(o.x0), iL = o.x0(1); vC = o.x0(2); xI = o.x0(3); end
yS = iL; mbuf = repmat(iL,nd,1);
dHold = p.Vref/p.Vin;
if isfield(o,'d0') && ~isempty(o.d0), dHold = o.d0; end
dPipe = repmat(dHold, max(np,1), 1);
dNext = dHold;
dxI = 0;
if isfield(o,'dxI') && ~isempty(o.dxI), dxI = o.dxI; end
vref = o.Vref0;

% control update at t = 0 for boundary sampling only (the map does the same);
% with phi > 0 the first sample is inside period 0, so nothing is computed here.
if phi <= 0
    [dNext, dxI, yS, mbuf] = ctl_ref(iL, vC, xI, vref, yS, mbuf, p, phi);
    if np == 0, dHold = dNext; end
end

nb = o.nPer+2;
r.tb = zeros(nb,1); r.iLb = zeros(nb,1); r.vCb = zeros(nb,1); r.xIb = zeros(nb,1);
nwmax = o.nPer*(o.nSub+6) + 10;
r.t = zeros(nwmax,1); r.vOut = zeros(nwmax,1); r.iL = zeros(nwmax,1);
nw = 0; nbk = 1;
r.tb(1) = 0; r.iLb(1) = iL; r.vCb(1) = vC; r.xIb(1) = xI;

t = 0; k = 0;
tEnd = o.nPer*Ts;
sampledFlag = (phi <= 0);
while t < tEnd - 1e-15
    tau = t - k*Ts;
    if t < o.Tss, vref = o.Vref0 + (p.Vref-o.Vref0)*t/o.Tss; else, vref = p.Vref; end

    % ---- next event inside this period ----
    % NOTE: the sample instant can be LATER than the switch instant (any phase
    % past d*Ts), so the event list is not in time order. Taking ev(1) instead of
    % min(ev) silently straddles the switch instant; measured as a 3.9e-4 A error
    % per period at phi = 0.5 with 5 ns steps, i.e. exactly one straddled step.
    ev = [phi*Ts, dHold*Ts, Ts];
    ev = ev(ev > tau + 1e-14);
    if isempty(ev), step = h; else, step = min(h, min(ev)-tau); end
    if step < 1e-14, step = 1e-14; end

    sw = ((tau + 0.5*step) < dHold*Ts);
    y = [iL; vC; xI];
    k1 = f(y, sw, dxI, p);
    k2 = f(y + 0.5*step*k1, sw, dxI, p);
    k3 = f(y + 0.5*step*k2, sw, dxI, p);
    k4 = f(y + step*k3, sw, dxI, p);
    y = y + (step/6)*(k1 + 2*k2 + 2*k3 + k4);
    iL = y(1); vC = y(2); xI = y(3);
    t = t + step; tau = t - k*Ts;

    nw = nw + 1;
    if nw > nwmax
        error('sw_ref_sim:buf','waveform buffer overflow -- increase nwmax');
    end
    r.t(nw) = t; r.iL(nw) = iL; r.vOut(nw) = po(iL,vC,p);

    % ---- sample event (inside the period) ----
    if ~sampledFlag && tau >= phi*Ts - 1e-13
        [dNext, dxI, yS, mbuf] = ctl_ref(iL, vC, xI, vref, yS, mbuf, p, phi);
        sampledFlag = true;
    end

    % ---- period boundary ----
    if tau >= Ts - 1e-13
        k = k + 1; t = k*Ts;
        if np >= 1
            dPipe = [dPipe(2:end); dNext];
            dHold = dPipe(1);
        end
        sampledFlag = false;
        nbk = nbk + 1;
        r.tb(nbk) = t; r.iLb(nbk) = iL; r.vCb(nbk) = vC; r.xIb(nbk) = xI;
        if phi <= 0
            [dNext, dxI, yS, mbuf] = ctl_ref(iL, vC, xI, vref, yS, mbuf, p, phi);
            if np == 0, dHold = dNext; end
            sampledFlag = true;
        end
    end
end

r.tb = r.tb(1:nbk); r.iLb = r.iLb(1:nbk); r.vCb = r.vCb(1:nbk); r.xIb = r.xIb(1:nbk);
r.t = r.t(1:nw); r.vOut = r.vOut(1:nw); r.iL = r.iL(1:nw);
end

% ---------------------------------------------------------------------------
function dy = f(y, sw, dxI, p)
iL = y(1); vC = y(2);
vO = po(iL,vC,p); iLoad = vO/p.R;
if sw, vSW = p.Vin - iL*p.RonSW; else, vSW = -(p.Vf + iL*p.RonD); end
dy = [ (vSW - vO - iL*p.RL)/p.L ; (iL - iLoad)/p.C ; dxI ];
end

function vO = po(iL, vC, p)
vO = (vC + p.ESR*iL)/(1 + p.ESR/p.R);
end

function [dSat, dxI, yS, mbuf] = ctl_ref(iL, vC, xI, vref, yS, mbuf, p, phi)
vO = po(iL,vC,p); iLoad = vO/p.R;
if p.sens.enable && isfinite(p.sens.fBW) && p.sens.fBW > 0
    aF = exp(-2*pi*p.sens.fBW*(1/p.fs));
    yS = aF*yS + (1-aF)*iLoad;
else
    yS = iLoad;
end
if p.sens.nd > 0
    mbuf = [yS; mbuf(1:end-1)]; raw = mbuf(end);
else
    raw = yS;
end
if p.sens.enable
    iMeas = p.sens.gain*raw + p.sens.offset;
    if p.sens.lsb > 0, iMeas = p.sens.lsb*round(iMeas/p.sens.lsb); end
    iMeas = min(max(iMeas,0), p.sens.iMaxPhys);
else
    iMeas = iLoad;
end
iSig = iL + ripple_comp(p, phi);
e = min(max(vref - vO, -p.Eclamp), p.Eclamp);
iLrefRaw = p.Kpe*e + xI;
if p.ff, iLrefRaw = iLrefRaw + iMeas; end
iLrefLim = min(max(iLrefRaw, p.Imin), p.Imax);
dRaw = p.Vref/p.Vin + p.Kci*(iLrefLim - iSig)/p.Vin;
dSat = min(max(dRaw, p.Dmin), p.Dmax);
aw = (1/p.Tt)*( (p.Vin/p.Kci)*(dSat-dRaw) + (iLrefLim-iLrefRaw) );
dxI = p.Kie*e + aw;
end
