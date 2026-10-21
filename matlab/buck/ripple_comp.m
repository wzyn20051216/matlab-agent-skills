function c = ripple_comp(p, phi)
%RIPPLE_COMP  Half-ripple compensation for a current sample taken at phase phi.
%
%   c = ripple_comp(p, phi)
%
% The inner loop regulates the SAMPLED inductor current, not the cycle average.
% At 62 % peak-to-peak ripple those differ by up to half a ripple, so the
% sampled value must be corrected with the analytically known offset:
%
%   comp(phi) = iL_avg - iL(phi)
%
% with the duty at the START of the period (sawtooth carrier from 0) and a
% triangular ripple of up-slope m1 = (Vin - Vref)/L and down-slope
% m2 = -m1*d0/(1-d0), d0 = Vref/Vin:
%
%   phi <= d0 :  iL(phi) - iL_avg = m1*Ts*(phi - d0/2)
%   phi >  d0 :  iL(phi) - iL_avg = m1*Ts*(d0*(phi-d0)/(1-d0) - d0/2)
%
% so comp = iL_avg - iL(phi):
%   phi = 0    (valley)   -> +m1*Ts*d0/2   (the classic half-ripple term)
%   phi = d0   (peak)     -> -m1*Ts*d0/2
%   phi = 1    (valley)   -> +m1*Ts*d0/2
%   phi = 0.5  (mid-period, not mid-ON when d0 < 0.5)
%
% SIGN, settled by the two limit cases rather than by algebra: the two branches
% must agree at phi = d0 and must both return +dIL/2 at a valley. Writing the
% phi > d0 branch as (d0/2 - d0*(phi-d0)/(1-d0)) instead gives +dIL/2 at the
% peak and -dIL/2 at the valley, i.e. exactly inverted and discontinuous by dIL
% at phi = d0. (This file was briefly "fixed" into that state during Task 4 and
% the ripple-geometry check in buck_a6_task4_phase.m rejected it; the check itself
% had the same sign error, which is why the limit cases are quoted here.)
%
% MODES
%   p.compMode = 'phase'     compensation follows the sample position (correct)
%   p.compMode = 'boundary'  the phi = 0 formula is used at every phase. This is
%                            what a designer gets by moving the ADC trigger and
%                            leaving the firmware constant alone, so it is a
%                            configuration that must be tested, not assumed.
%   p.compScale              multiplier on either, to sweep the compensation
%                            error. A static error of this kind does NOT change
%                            the loop gain (it is a constant term in the current
%                            error), so its effect is a bias absorbed by the
%                            outer integrator -- verified in
%                            verify/buck_a6_task4_phase.m section 3.
%
% At phi = 0 and compScale = 1 this returns exactly the term used by the frozen
% 3A.4/3A.5/3A.6 baseline, so the existing results are preserved.

if ~isfield(p,'rippleComp') || ~p.rippleComp
    c = 0; return;
end
if ~isfield(p,'compMode'),  mode = 'boundary'; else, mode = p.compMode;  end
if ~isfield(p,'compScale'), sc = 1;            else, sc = p.compScale;   end

Ts = 1/p.fs;
m1 = (p.Vin - p.Vref)/p.L;
d0 = p.Vref/p.Vin;

switch lower(mode)
    case 'boundary'
        c = m1*Ts*d0/2;
    case 'phase'
        if phi <= d0
            c = m1*Ts*(d0/2 - phi);
        else
            c = m1*Ts*(d0*(phi-d0)/(1-d0) - d0/2);
        end
    otherwise
        error('ripple_comp:mode','unknown compMode "%s"', mode);
end
c = c*sc;
end
