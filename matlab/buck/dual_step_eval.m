function r = dual_step_eval(cfg, Vin, R0, Lq, Kci, Kpe, Kie, ff, ratio)
%DUAL_STEP_EVAL  Exact load-step metrics of the dual loop from the modal sum.
%
%   r = dual_step_eval(cfg, Vin, R0, Lq, Kci, Kpe, Kie, ff, ratio)
%
% The load step is a PARAMETER change (R0 -> R0/ratio), not an additive
% disturbance, so the residues of T(s) (reference step) must not be used.
% Instead the state is continuous across the step, so the post-step response is
%   dev(t) = sum_q  V(2,q)*c(q)*exp(lam_q*t) ,  c = V \ (x0 - xss_post)
% which is exact for the linear (unsaturated) system.
%
% Returns (all negative values are sign-consistent with vC - Vref):
%   r.s5ms     strict settling time (first sample after the last out-of-band
%              sample), NaN if it never settles inside the horizon
%   r.dipPct   deepest deviation [% of Vref]
%   r.Apct     amplitude of the mode that leaves the band last [%]
%   r.domRe, r.domHz   that mode
%   r.dmax     peak linear duty command (saturation flag if >= Dmax)
%   r.dmin     minimum linear duty command
%   r.iLmaxA   peak inductor current [A]
%   r.slewMax  peak |diL/dt| [A/s]
%   r.dutFlag  true if the linear duty command leaves [Dmin,Dmax]
%
% Horizon: 30 ms after the step at 2 us resolution (S5 for this plant never
% exceeds ~30 ms in the searched region; anything that has not settled by then
% is reported as NaN, i.e. UNDETERMINED, not PASS).

if nargin < 9, ratio = 2; end
Vref = cfg.Vref;
R1 = R0/ratio;
if ff
    % feedforward carries the steady-state current, so the integrator sits at 0
    xe0 = 0; xe1 = 0;
else
    xe0 = (Vref/R0)/Kie; xe1 = (Vref/R1)/Kie;
end
x0  = [Vref/R0; Vref; xe0];
xss = [Vref/R1; Vref; xe1];

A = dual_A(cfg, R1, Kci, Kpe, Kie, ff);
[V,Lam] = eig(A);
c = V \ (x0 - xss);
lam = diag(Lam);

tv = (0:2e-6:0.030).';
dev  = zeros(size(tv));
devI = zeros(size(tv));
devX = zeros(size(tv));
for q = 1:size(V,2)
    e = exp(lam(q)*tv);
    dev  = dev  + real(V(2,q)*c(q)*e);
    devI = devI + real(V(1,q)*c(q)*e);
    devX = devX + real(V(3,q)*c(q)*e);
end

band = 0.01*Vref;
lo = find(abs(dev) > band, 1, 'last');
if isempty(lo), r_s5 = 0;
elseif lo == numel(tv), r_s5 = NaN;
else, r_s5 = tv(lo+1)*1e3; end

amp = abs(V(2,:).'.*c);
tExit = -inf(size(lam));
for q = 1:numel(lam)
    if amp(q) > band && real(lam(q)) < 0
        tExit(q) = log(amp(q)/band)/(-real(lam(q)));
    end
end
[~,iq] = max(tExit);

% duty and current (linear, unsaturated)
%   iLref = Vref/R1 + (-Kpe + ff/R1)*dev + Kie*devX
% The (ff/R1)*dev term is the linearised measured load current iLoad = vC/R1.
iLrefAbs = Vref/R1 + (-Kpe + ff/R1)*dev + Kie*devX;
iLAbs    = Vref/R1 + devI;
dlin = Vref/Vin + Kci*(iLrefAbs - iLAbs)/Vin;
slew = [0; abs(diff(devI))]/2e-6;

r = struct();
r.s5ms   = r_s5;
r.dipPct = min(dev)/Vref*100;
r.osPct  = max(dev)/Vref*100;
r.Apct   = amp(iq)/Vref*100;
r.domRe  = real(lam(iq));
r.domHz  = abs(imag(lam(iq)))/(2*pi);
r.dmax   = max(dlin);
r.dmin   = min(dlin);
r.iLmaxA = max(iLAbs);
r.slewMax = max(slew);
r.dutFlag = (r.dmax >= cfg.Dmax - 1e-9) || (r.dmin <= cfg.Dmin + 1e-9);
r.maxRe  = max(real(lam));
end
