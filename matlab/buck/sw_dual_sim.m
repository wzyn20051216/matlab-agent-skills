function r = sw_dual_sim(p, o)
%SW_DUAL_SIM  Period-by-period simulator of the closed-loop switching converter.
%
%   r = sw_dual_sim(p, o)
%
% WHY IT EXISTS
% The Simulink switching model (build_buck_switching.m) is the reference, but it
% costs ~45 s per 80 ms run plus model-build overhead, which makes seed sweeps and
% six inductance candidates impractical. This file integrates the SAME equations
% period by period with the duty held, and is validated against that Simulink
% model in verify/buck_a6_task2_dplus.m (operating point, ripple, dip, S5).
%
% PROPAGATION
% Within a switching state the plant is a 2-state LTI system
%   z = [iL; vC],  dz/dt = A z + b,   z(t+h) = expm(A h) z + A\(expm(A h)-I) b
% With a fixed substep h = Ts/nSub the two matrices (on / off) are computed once,
% so a period costs nSub matrix-vector products. The switch instant is rounded to
% the substep grid, which is exactly the PWM resolution of the hardware (100 ns
% at nSub = 200, fs = 50 kHz) and matches what the fixed-step Simulink solver does.
%
% WHAT IT ADDS OVER THE PERIOD MAP (sw_period_map.m)
%   - time-varying load (load step) and a soft-start reference
%   - the full sensor chain: bandwidth, transport delay, gain, offset, Gaussian
%     noise with a seed, ADC quantization, and a physical-range clamp
%   - recording of instantaneous peak / cycle-average current, which is needed to
%     separate "sampled value" from "average" from "peak" (Task 2 requirement)
%   - sampling phase (sampPhase) and ADC phase JITTER (o.phaseJitter). Jitter is
%     deliberately here and not in the map: a jittered sample makes the system
%     non-periodic, so Floquet multipliers are NOT defined for it and the map
%     must not be used to produce a number that looks like one.
%   It is NOT autonomous, so it cannot be used for the Floquet analysis; that is
% what sw_period_map.m is for. The two share the same parameter struct (dual_params).
%
% SAMPLING (Phase 3A.6 Task 4)
%   phi = 0     control evaluated at the period boundary (baseline)
%   phi > 0     control evaluated at phi*Ts inside the period; the computed duty
%               is latched at the period end and applied at the next boundary,
%               i.e. the effective delay is (1-phi)*Ts. Same convention as
%               sw_period_map.m, verified cell by cell in buck_a6_task4_phase.m.
%
% o (options): ratio [1], tStep [0.06], tEnd [0.08], Tss [5e-3], nSub [p.Nsub],
%              Vref0 [0] (initial reference, 0 for soft start), recDecim [5],
%              seed [], noise [false], phaseJitter [0] (fraction of Ts, uniform)

if nargin < 2, o = struct(); end
if ~isfield(o,'ratio'),    o.ratio = 1; end
if ~isfield(o,'tStep'),    o.tStep = 0.06; end
if ~isfield(o,'tEnd'),     o.tEnd = 0.08; end
if ~isfield(o,'Tss'),      o.Tss = 5e-3; end
if ~isfield(o,'nSub'),     o.nSub = p.Nsub; end
if ~isfield(o,'Vref0'),    o.Vref0 = 0; end
if ~isfield(o,'recDecim'), o.recDecim = 5; end
if ~isfield(o,'noise'),    o.noise = false; end
if ~isfield(o,'seed'),     o.seed = 0; end
if ~isfield(o,'phaseJitter'), o.phaseJitter = 0; end

Ts = 1/p.fs;
phi = 0; if isfield(p,'sampPhase'), phi = p.sampPhase; end
if phi < 0 || phi >= 1
    error('sw_dual_sim:phase','sampPhase must be in [0,1); got %g', phi);
end
R = p.R; Vref = p.Vref; L = p.L; C = p.C; ESR = p.ESR;
nDly = p.nDly; nd = p.sens.nd;
if phi > 0 && nDly < 1
    error('sw_dual_sim:delay', ...
        ['sampPhase=%g with nDly=0 is not realisable: a sample inside the ' ...
         'period can only change the duty at the next period boundary'], phi);
end
h = Ts/o.nSub;

% ---- propagation caches (rebuilt once at the load step) ----
% The first version rounded the on-time to the substep grid, i.e. quantised the
% duty to 1/nSub = 0.5 %. The controller then dithers between two adjacent duty
% values and the measured ripple came out 14 % high (1.404 App instead of 1.232)
% and the output ripple 2.2x high -- a pure SIMULATION artefact that would have
% contaminated the inductance study. The switch instant is therefore propagated
% EXACTLY: full substeps use cached matrices, the two partial steps use the
% eigendecomposition of the same A, which is exact for any duration.
[MatOn, MatOff] = operators(R, p, h);
cOn  = make_cache(p, R, true);
cOff = make_cache(p, R, false);

% ---- state ----
iL = Vref/R; vC = Vref; xI = 0; dHist = repmat(Vref/p.Vin, nDly, 1);
yS = Vref/R; mbuf = repmat(Vref/R, nd, 1);

if o.noise || o.phaseJitter > 0
    rng(o.seed);                        % reproducible noise / jitter
else
    rng(0);
end

nPer = round(o.tEnd/Ts);
dec = o.recDecim;
nRec = nPer*ceil(o.nSub/dec) + 10;
rt = zeros(nRec,1); rvO = zeros(nRec,1); riL = zeros(nRec,1);
rd = zeros(nRec,1); rIr = zeros(nRec,1); rIm = zeros(nRec,1);
rdPk = zeros(nPer,1); rdAv = zeros(nPer,1);
rILpk = zeros(nPer,1); rILav = zeros(nPer,1); rILvl = zeros(nPer,1); rILsmp = zeros(nPer,1);
n = 0;

Rcur = R;
stepDone = false;
ctlState = struct('yS',yS,'mbuf',mbuf);
dxI = 0;
% Logged controller signals. They are initialised so that the substeps BEFORE the
% sampling instant can be logged even when sampPhase > 0 (with boundary sampling
% the sample happens first and this is overwritten immediately). Leaving them
% undefined is not a cosmetic issue: the log line runs on the first substep of
% every period and crashed for every phi > 0.
iLsmp = iL; iMeasNow = Vref/R; iLrefNow = Vref/R;

for k = 1:nPer
    t = (k-1)*Ts;
    % load step: rebuild the operators exactly once
    if ~stepDone && t >= o.tStep - 1e-15
        Rcur = R/o.ratio;
        [MatOn, MatOff] = operators(Rcur, p, h);
        cOn  = make_cache(p, Rcur, true);
        cOff = make_cache(p, Rcur, false);
        stepDone = true;
    end
    % soft-start reference
    if t < o.Tss
        vref = o.Vref0 + (Vref - o.Vref0)*max(t,0)/o.Tss;
    else
        vref = Vref;
    end

    % ---- sampling instant for this period ----
    if o.phaseJitter > 0
        phiK = phi + o.phaseJitter*(2*rand-1);
        phiK = min(max(phiK, 0), 0.98);
    else
        phiK = phi;
    end
    tS = phiK*Ts;

    % ---- applied duty (latched at the previous boundary) ----
    if nDly >= 1, dApply = dHist(1); else, dApply = NaN; end

    sampled = false;
    if tS <= 1e-15
        [dSat, dxI, w] = ctl(iL, vC, xI, vref, Rcur, p, phiK, ctlState, o.noise);
        ctlState = w;
        iLsmp = iL; iMeasNow = w.iMeas; iLrefNow = w.iLrefLim;
        sampled = true;
        if nDly == 0, dApply = dSat; end
    end

    % ---- step plan: honour the switch instant AND the sample instant ----
    % Baseline (phi = 0): identical plan to the pre-Task-4 code (full substeps
    % plus one partial step at the end of each switch state), so the frozen
    % results are reproduced bit for bit. For phi > 0 the substep containing the
    % sample is split in two, because the controller must see the state at
    % exactly tS and the integrator slope changes there.
    ton = dApply*Ts;  toff = Ts - ton;
    nFullOn  = floor(ton/h + 1e-12);   remOn  = ton  - nFullOn*h;
    nFullOff = floor(toff/h + 1e-12);  remOff = toff - nFullOff*h;
    durs  = [repmat(h,1,nFullOn),  remOn,  repmat(h,1,nFullOff), remOff];
    kinds = [ones(1,nFullOn),      1,      zeros(1,nFullOff),    0];
    if ~sampled && tS < Ts - 1e-15
        cum = [0, cumsum(durs)];
        qs = find(cum < tS - 1e-18, 1, 'last');
        if isempty(qs), qs = 1; end
        if qs <= numel(durs)
            a1 = tS - cum(qs);
            if a1 > 1e-15 && a1 < durs(qs) - 1e-15
                durs  = [durs(1:qs-1), a1, durs(qs)-a1, durs(qs+1:end)];
                kinds = [kinds(1:qs-1), kinds(qs), kinds(qs), kinds(qs+1:end)];
            end
        end
    end

    % z(1) at the period boundary is what the ADC sees at phi = 0; the cycle
    % average and the instantaneous peak are different quantities at 62 % ripple
    % and are recorded separately so they can never be confused downstream.
    z = [iL; vC];
    ipk = z(1); ivl = z(1); iavg = 0; nsub = 0; tcur = 0;
    for q = 1:numel(durs)
        dtq = durs(q);
        if dtq <= 1e-15, continue; end
        iLprev = z(1);
        if abs(dtq - h) <= 1e-18
            if kinds(q) == 1, z = MatOn.M*z  + MatOn.N;
            else,             z = MatOff.M*z + MatOff.N; end
        else
            if kinds(q) == 1, cc = cOn; else, cc = cOff; end
            [E, N] = seg_eval(cc, dtq);
            z = E*z + N;
        end
        xI = xI + dxI*dtq;
        tcur = tcur + dtq;
        nsub = nsub + 1;
        if z(1) > ipk, ipk = z(1); end
        if z(1) < ivl, ivl = z(1); end
        % trapezoidal: the per-period mean must be time-weighted. A plain
        % right-endpoint sum over a sawtooth is biased because the switch instant
        % adds a partial step every period (measured bias 0.37 % on iL).
        iavg = iavg + 0.5*(iLprev + z(1))*dtq;
        % ---- sample instant reached: run the controller HERE, on the state at tS
        if ~sampled && tcur >= tS - 1e-15
            [dSat, dxI, w] = ctl(z(1), z(2), xI, vref, Rcur, p, phiK, ctlState, o.noise);
            ctlState = w;
            iLsmp = z(1); iMeasNow = w.iMeas; iLrefNow = w.iLrefLim;
            sampled = true;
        end
        if mod(nsub-1, dec) == 0
            [vo, ~] = po(z(1), z(2), Rcur, ESR);
            n = n + 1;
            rt(n) = t + tcur; rvO(n) = vo; riL(n) = z(1);
            rd(n) = dApply; rIr(n) = iLrefNow; rIm(n) = iMeasNow;
        end
    end
    iL = z(1); vC = z(2);
    rdPk(k) = ipk; rdAv(k) = iavg/Ts;
    rILpk(k) = ipk; rILav(k) = iavg/Ts; rILvl(k) = ivl; rILsmp(k) = iLsmp;

    % ---- advance the duty pipeline ----
    if nDly >= 1, dHist = [dHist(2:end); dSat]; end
end

r = struct();
r.t = rt(1:n); r.vOut = rvO(1:n); r.iL = riL(1:n);
r.duty = rd(1:n); r.iLref = rIr(1:n); r.iMeas = rIm(1:n);
r.tPer = (0:nPer-1).'*Ts;
r.iLpeak = rILpk; r.iLavg = rILav; r.iLvalley = rILvl; r.iLsampled = rILsmp;
r.cfg = p; r.opt = o; r.Rpost = R/1; if o.ratio ~= 1, r.Rpost = R/o.ratio; end
end

% ---------------------------------------------------------------------------
function [dSat, dxI, w] = ctl(iL, vC, xI, vref, Rcur, p, phi, st, noiseOn)
%CTL  One control update at the sampling instant (identical law to the map).
% Rcur, not p.R: after the load step the measured load current must come from the
% NEW resistance. Using p.R here halves the feedforward after the step and the
% symptom is a dip of -6.7 % instead of -2.2 % and S5 of 1.12 ms instead of
% 0.18 ms -- i.e. the baseline silently fails S5. (Found exactly that way.)
% noiseOn: the sensor noise term lives here, so it MUST be passed in. When this
% function was first factored out of the loop the flag was not, the noise
% silently disappeared, and five different seeds produced bit-identical results.
% The seed sweep is what made that visible; a single run would have looked fine.
[vOut, iLoad] = po(iL, vC, Rcur, p.ESR);

if p.sens.enable && isfinite(p.sens.fBW) && p.sens.fBW > 0
    aF = exp(-2*pi*p.sens.fBW*(1/p.fs));
    yS = aF*st.yS + (1-aF)*iLoad;
else
    yS = iLoad;
end
nd = p.sens.nd;
if nd > 0
    mbuf = [yS; st.mbuf(1:end-1)];
    raw = mbuf(end);
else
    mbuf = st.mbuf;
    raw = yS;
end
if p.sens.enable
    iMeas = p.sens.gain*raw + p.sens.offset;
    if noiseOn && p.sens.sigma > 0, iMeas = iMeas + p.sens.sigma*randn; end
    if p.sens.lsb > 0, iMeas = p.sens.lsb*round(iMeas/p.sens.lsb); end
    iMeas = min(max(iMeas, 0), p.sens.iMaxPhys);
else
    iMeas = iLoad;
end

comp = ripple_comp(p, phi);
iSig = iL + comp;
e = min(max(vref - vOut, -p.Eclamp), p.Eclamp);
iLrefRaw = p.Kpe*e + xI;
if p.ff, iLrefRaw = iLrefRaw + iMeas; end
iLrefLim = min(max(iLrefRaw, p.Imin), p.Imax);
dRaw = p.Vref/p.Vin + p.Kci*(iLrefLim - iSig)/p.Vin;
dSat = min(max(dRaw, p.Dmin), p.Dmax);
aw = (1/p.Tt)*( (p.Vin/p.Kci)*(dSat - dRaw) + (iLrefLim - iLrefRaw) );
dxI = p.Kie*e + aw;

w = struct('yS',yS,'mbuf',mbuf,'iMeas',iMeas,'iLrefLim',iLrefLim, ...
    'iSig',iSig,'e',e,'comp',comp,'dRaw',dRaw,'dSat',dSat,'vOut',vOut);
end

% ---------------------------------------------------------------------------
function [Mo, Mf] = operators(R, p, h)
% cached one-substep propagators for the switch-on and switch-off states
[Ao, bo, Af, bf] = state_matrices(R, p);
Mo = seg(Ao, bo, h);
Mf = seg(Af, bf, h);
end

function M = seg(A, b, h)
E = expm(A*h);
M = struct('M', E, 'N', A\((E - eye(2))*b));
end

function [Ao, bo, Af, bf] = state_matrices(R, p)
% plant written as dz/dt = A z + b for each switch state; z = [iL; vC]
k1 = 1/(1 + p.ESR/R);
k2 = p.ESR/(1 + p.ESR/R);
A0 = [ -(k2 + p.RL)/p.L, -k1/p.L ; ...
        (1 - k2/R)/p.C,   -k1/(R*p.C) ];
Ao = A0 + [-p.RonSW/p.L 0; 0 0];  bo = [p.Vin/p.L; 0];
Af = A0 + [-p.RonD/p.L  0; 0 0];  bf = [-p.Vf/p.L; 0];
end

function c = make_cache(p, R, isOn)
% eigendecomposition of A so expm(A*t) can be evaluated for ANY t in a few
% operations: this is what makes the exact switch instant affordable.
if isOn, [A, b] = state_matrices(R, p); else, [~,~,A,b] = state_matrices(R, p); end
[V, D] = eig(A);
c = struct('A', A, 'b', b, 'V', V, 'W', inv(V), 'lam', diag(D));
end

function [E, N] = seg_eval(c, t)
% The eigenvalues of A are a complex pair, so the eigendecomposition route
% returns a complex matrix whose imaginary part is pure rounding noise (the true
% propagator of a real system is real). Dropping it with real() is exact and is
% required: otherwise every downstream quantity becomes complex and repmat/floor
% fail with "complex replication factor" (hit here).
E = real(c.V * diag(exp(c.lam*t)) * c.W);
N = real(c.A\((E - eye(2))*c.b));
end

function [vOut, iLoad] = po(iL, vC, R, ESR)
vOut  = (vC + ESR*iL)/(1 + ESR/R);
iLoad = vOut/R;
end
