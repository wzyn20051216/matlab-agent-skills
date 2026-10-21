function d = boost_duty_for(p, Vtarget)
%BOOST_DUTY_FOR  Duty cycle that produces Vtarget in CCM, losses included.
%
%   d = boost_duty_for(p, 48)
%
% Closed form. With u = 1-d and Req(u) = (RL+RonSW) + u*(RonD-RonSW), the
% steady-state relation of boost_steady.m is
%
%   Vin - u*Vf = Vtarget*(u + Req(u)/(R*u))
%
% which, multiplied by u, is a quadratic in u:
%
%   (Vtarget + Vf)*u^2 + (Vtarget*(RonD-RonSW)/R - Vin)*u + Vtarget*(RL+RonSW)/R = 0
%
% The physically meaningful root is the one in (0,1) near the ideal 1-Vin/Vtarget.
% If the quadratic has no such root (Vtarget unreachable with these losses, e.g.
% beyond the maximum gain 1/(1-Dmax)), the function falls back to a bracketed
% fzero and finally errors instead of returning a duty that does not deliver.
%
% ACHIEVABILITY: the lossy converter cannot reach Vin/(1-D) exactly, and above a
% certain duty the gain actually DECREASES (Req/(R*u) grows like 1/u while the
% ideal gain grows like 1/u only in the numerator). This function therefore also
% checks the answer by simulating the steady state back.

A = Vtarget + p.Vf;
B = Vtarget*(p.RonD - p.RonSW)/p.R - p.Vin;
C = Vtarget*(p.RL + p.RonSW)/p.R;

d = NaN;
disc = B^2 - 4*A*C;
if disc >= 0
    r = roots([A B C]);
    r = r(r > 0 & r < 1);
    if ~isempty(r)
        [~, k] = min(abs(r - (1 - p.Vin/Vtarget)));   % root nearest the ideal
        d = 1 - r(k);
    end
end
if ~isfinite(d) || d <= 0 || d >= 0.995
    % fallback: bracket the duty on the achievable range and solve numerically
    f = @(dd) boost_steady(p, dd).vOut - Vtarget;
    lo = 0.01; hi = 0.95;
    if f(lo)*f(hi) > 0
        error('boost_duty_for:unreachable', ...
            'Vout=%g V is not reachable with Vin=%g V and Dmax=%g', ...
            Vtarget, p.Vin, p.Dmax);
    end
    d = fzero(f, [lo hi]);
end

% self-check: the duty must actually deliver Vtarget
chk = boost_steady(p, d);
if abs(chk.vOut - Vtarget) > 1e-6*max(1,Vtarget)
    error('boost_duty_for:inconsistent', ...
        'duty %.6f gives %.6f V, asked for %.6f V', d, chk.vOut, Vtarget);
end
end
