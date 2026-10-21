function m = cfg_metrics(p, o, Vref)
%CFG_METRICS  One load-step run of the switching simulator, reduced to metrics.
%
%   m = cfg_metrics(p, o, Vref)
%
% Shared by the Task 4/5/6 acceptance scripts so the metric definitions cannot
% drift between them. Everything is taken from ONE run; the reporting layer
% decides which quantities are comparable and which are not.
%
% QUANTITIES THAT MUST NOT BE MIXED (this is where 3A.5 went wrong once):
%   iLavg      cycle-average current, trapezoidal, per period      -> sets the
%              delivered charge and must satisfy iLavg = iLoad
%   iLsampled  what the ADC sees at the sample instant             -> the only
%              current the controller has
%   iLpk       INSTANTANEOUS peak inside the period                 -> the only
%              current the hardware protection sees
% At 62 % ripple they differ by up to half a ripple.

if nargin < 3, Vref = 12; end
r = sw_dual_sim(p, o);
sm = step_metrics(r.t, r.vOut, Vref, o.tStep, 1);

pre  = r.tPer > (o.tStep - 0.01) & r.tPer < o.tStep;
post = r.t >= o.tStep;

m = struct();
m.dipPct   = sm.dipPct;
m.settleMs = sm.settleMs;
m.osPct    = (max(r.vOut) - Vref)/Vref*100;
m.ssErr    = (mean(r.vOut(r.t > 0.075)) - Vref)/Vref*100;
m.dMin     = min(r.duty(post));
m.dMax     = max(r.duty(post));
m.dMinAll  = min(r.duty);
m.dMaxAll  = max(r.duty);
m.iLpk     = max(r.iLpeak(pre));            % instantaneous peak, pre-step
m.iLavg    = mean(r.iLavg(pre));
m.iLvalley = min(r.iLvalley(pre));
m.iLsampled= mean(r.iLsampled(pre));
m.iLpkAll  = max(r.iL);                     % worst instantaneous peak anywhere
m.iLminAll = min(r.iL);                     % < 0 means the model entered DCM
m.iLminPost= min(r.iL(r.t >= o.tStep));
m.ripplePct= mean(r.iLpeak(pre) - r.iLvalley(pre))/mean(r.iLavg(pre))*100;
% fraction of periods sitting exactly on a duty limit (S8 has no margin at 0.05)
m.satDminPct = 100*mean(abs(r.duty(post) - p.Dmin) < 1e-9);
m.satDmaxPct = 100*mean(abs(r.duty(post) - p.Dmax) < 1e-9);
m.vOutMin  = min(r.vOut(post));
m.vOutMax  = max(r.vOut(post));
m.r = r;
end
