function m = boost_run_metrics(r, p, o)
%BOOST_RUN_METRICS  One place that turns a simulation run into graded numbers.
%
%   m = boost_run_metrics(r, p, o)
%
% WHY THIS EXISTS
% The simulator returns TWO time bases:
%   waveform  r.t, r.vOut, r.iL, r.duty, r.iLref, r.iMeas   (~40 samples/period)
%   per-period r.tPer, r.iLpeak, r.iLvalley, r.iLavg, r.dcmFrac   (1/period)
% Applying a per-period mask to a waveform array does NOT raise an error in
% MATLAB: it silently indexes the FIRST nPer samples, i.e. the first 1.5 ms of the
% run. In this phase that bug reported iLref = 0 for every condition and produced
% a completely wrong "the current command is railed" conclusion. Every mask in
% this file is therefore built on the array it is applied to, and nowhere else.
%
% WINDOWS
%   pre   [0.6*tStep, tStep)          steady state before the load step
%   post  [tStep + 0.025, tEnd]       settled state after it
%   transient = everything else
% DCM is counted in all three windows separately: a brief excursion during the
% transient is physically possible and is reported, but only steady-state DCM
% invalidates the CCM claim (m.ccmValid).
%
% FIELDS (all measured on this run, none inherited)
%   vOut, ssErr, ripplePct, rippleA      (OUTPUT voltage ripple)
%   iLrippleA                            (INDUCTOR current ripple, measured)
%   dip, s5            from step_metrics (shared with the Buck phase)
%   iLavgPre, iLrefPre, cmdErr, cmdSaturated
%   iLpkSS, iLpkTr, iLvalleyPre
%   dcmStartup, dcmPre, dcmTr, dcmPost  (% of each window; only pre/post are
%                    graded, the start-up window is reported separately because
%                    the run does not start from 0 V)
%   dMin, dMax, dutyMarginHi, dutyMarginLo
%   ccmValid, verdictDCM

if nargin < 3, o = struct(); end
if ~isfield(o,'tStep'), o.tStep = 0.02; end
if ~isfield(o,'tEnd'),  o.tEnd  = 0.06; end

Vref = p.Vref;
m = struct();

% ---------------- windows on the WAVEFORM grid ----------------
postStart = min(o.tEnd - 2/p.fs, o.tStep + 0.025);
wpost = r.t >= postStart;
wpre  = r.t >= 0.6*o.tStep & r.t < o.tStep;

vPost = r.vOut(wpost);
m.vOut    = mean(vPost);
m.ssErr   = (m.vOut - Vref)/Vref*100;
m.rippleA = max(vPost) - min(vPost);
m.ripplePct = 100*m.rippleA/m.vOut;

% ---------------- step metrics (shared definition) ----------------
sm = step_metrics(r.t, r.vOut, Vref, o.tStep, 1);
m.dip = sm.dipPct;
m.s5  = sm.settleMs;

% ---------------- windows on the PER-PERIOD grid ----------------
pper = r.tPer >= 0.6*o.tStep & r.tPer < o.tStep;
m.iLavgPre  = mean(r.iLavg(pper));
m.iLrippleA = mean(r.iLpeak(pper) - r.iLvalley(pper));   % measured dIL, per period
m.iLpkSS    = max(r.iLpeak(pper));
m.iLvalleyPre = min(r.iLvalley(pper));
m.iLpkTr    = max(r.iLpeak);

% the command is a WAVEFORM signal: same window, waveform mask
m.iLrefPre = mean(r.iLref(wpre));
m.cmdErr   = m.iLrefPre - m.iLavgPre;

% ---------------- duty ----------------
wd = r.t >= o.tStep;
m.dMin = min(r.duty(wd));
m.dMax = max(r.duty(wd));
m.dutyMarginHi = p.Dmax - m.dMax;     % to the modulator rail
m.dutyMarginLo = m.dMin - p.Dmin;

% ---------------- DCM per window (per-period data) ----------------
tp = r.tPer;
% dcmFrac(k) is the fraction of period k spent in DCM, so the fraction over a
% window is simply the MEAN of dcmFrac over the periods in that window.
% The pre-step steady window starts at 0.6*tStep. Everything before that is the
% START-UP transient and must not be mixed into it: the runs start at the 24 V
% operating point, so at other input voltages the first ~1.5 ms can dip into DCM.
% Measured: 69 DCM periods all inside t < 1.5 ms at 28 V/50 %, zero after 12 ms.
m.dcmStartup = 100*mean(r.dcmFrac(tp < 0.6*o.tStep));
m.dcmPre  = 100*mean(r.dcmFrac(tp >= 0.6*o.tStep & tp < o.tStep));
mWin      = tp >= o.tStep & tp < postStart;
m.dcmTr   = 100*mean(r.dcmFrac(mWin));
m.dcmPost = 100*mean(r.dcmFrac(tp >= postStart));
m.ccmValid = (m.dcmPre == 0) && (m.dcmPost == 0);
m.dcmAny   = r.dcmTime > 0;

% ---------------- command saturation ----------------
% The command is "saturated" when it sits at a clamp for the whole pre window,
% which means the outer loop has no authority left at that operating point.
tol = 1e-6;
m.cmdSaturated = (m.iLrefPre <= tol) || (abs(m.iLrefPre - r.cfg.Imax) <= tol);

if m.ccmValid
    m.verdictDCM = 'CCM';
else
    m.verdictDCM = 'UNDETERMINED (steady-state DCM)';
end
end
