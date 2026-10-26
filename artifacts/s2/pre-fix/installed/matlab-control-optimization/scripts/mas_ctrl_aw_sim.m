function r = mas_ctrl_aw_sim(P, c, o)
%MAS_CTRL_AW_SIM  Closed-loop step with actuator saturation and anti-windup modes.
%
%   r = mas_ctrl_aw_sim(P, cfg, opts)
%
%   cfg.Kp, cfg.Ki            PI gains on the error  (u = Kp*e + Ki*integral(e))
%   cfg.uMin, cfg.uMax        actuator limits
%   cfg.aw                    'none' | 'clamp' | 'backcalc'
%   cfg.Tt                    back-calculation time constant (backcalc only)
%   cfg.Ts                    controller sample time
%   opts.tEnd, opts.dt, opts.ref, opts.loadStep
%
%   r.overshootPct, r.settleMs, r.iae, r.satFrac, r.uMax, r.integralPeak,
%   r.windupExcursion         how far the integrator wanders past what the
%                             actuator could deliver, in units of the limit
%
% WHY THIS EXISTS
% A linear design says nothing about what happens when the actuator runs out. The
% Boost work in this repository produced exactly that failure twice: a duty that hit
% its lower rail during recovery, and a current command pinned at its clamp while
% the loop kept integrating. Both looked like "the controller is slow" in the time
% series and were only explained by looking at the integrator state.
%
% The three modes are included because the difference is not cosmetic:
%   none      the integrator keeps integrating a error the actuator cannot fix
%   clamp     integration frozen while saturated -- simple, but it also freezes the
%             recovery once the error changes sign
%   backcalc  u = u_sat + (1/Tt)*(u_unsat - u_sat) fed back, so the integrator is
%             pulled back by exactly the deficit. 1/Tt must scale with the loop gain;
%             reusing a Tt from a different controller is a real defect (it happened
%             in the Buck phase).

if nargin < 3, o = struct(); end
c = dflt(c, struct('Kp', 1, 'Ki', 1, 'uMin', -Inf, 'uMax', Inf, 'aw', 'none', ...
    'Tt', 0.02, 'Ts', 0));
o = dflt(o, struct('tEnd', 4, 'dt', [], 'ref', 1, 'dist', 0, ...
    'loadTime', Inf));

% continuous plant, discretised by RK4 at dt; the controller runs at Ts (Ts = 0
% means "same as dt", i.e. an analog controller)
[A, B, C, D] = ssdata(ss(P));
if isempty(o.dt)
    if c.Ts > 0, o.dt = c.Ts/20; else, o.dt = min(1e-3, o.tEnd/2e4); end
end
if c.Ts <= 0, c.Ts = o.dt; end
nSub = max(1, round(c.Ts/o.dt));
dt = o.dt;

t = (0:dt:o.tEnd).';
N = numel(t);
y = zeros(N, 1); u = zeros(N, 1); xI = zeros(N, 1); e = zeros(N, 1);
x = zeros(size(A, 1), 1);
y(1) = C*x;
xi = 0;
uPrev = 0;
for k = 1:N-1
    rk = o.ref;
    % o.dist is a LOAD disturbance added at the plant INPUT, not a change of the
    % reference. The first version subtracted it from the reference, which tests
    % setpoint tracking and calls it a disturbance rejection -- a different
    % experiment with a different answer.
    dk = 0; if t(k) >= o.loadTime, dk = o.dist; end
    ek = rk - y(k);
    e(k) = ek;
    if mod(k-1, nSub) == 0
        uUnsat = c.Kp*ek + c.Ki*xi;
        uSat = min(max(uUnsat, c.uMin), c.uMax);
        % integrate ONLY when the controller tick happens
        switch lower(c.aw)
            case 'none'
                xi = xi + ek*c.Ts;
            case 'clamp'
                if uUnsat == uSat, xi = xi + ek*c.Ts; end
            case 'backcalc'
                % The integrator stores I = integral(e), and the command is
                % u = Kp*e + Ki*I. Back-calculation must therefore divide the
                % deficit by Ki: dI/dt = e + (u_sat-u)/(Tt*Ki). Without the 1/Ki the
                % correction gain is proportional to Ki, and with Ki=12, Ts=0.01,
                % Tt=0.02 the loop diverged to 1e300 within a second -- measured
                % before this was fixed.
                xi = xi + ek*c.Ts + (uSat - uUnsat)*c.Ts/(c.Tt*max(c.Ki, 1e-12));
            otherwise
                error('mas_ctrl_aw_sim:aw', 'unknown anti-windup mode "%s"', c.aw);
        end
        uPrev = uSat;
    end
    u(k) = uPrev;
    xI(k) = xi;
    uTot = uPrev + dk;
    % plant step
    f = @(xx, uu) A*xx + B*uu;
    k1 = f(x, uTot);
    k2 = f(x + 0.5*dt*k1, uTot);
    k3 = f(x + 0.5*dt*k2, uTot);
    k4 = f(x + dt*k3, uTot);
    x = x + dt/6*(k1 + 2*k2 + 2*k3 + k4);
    y(k+1) = C*x + D*uTot;
end
u(N) = uPrev; e(N) = e(N-1); xI(N) = xi;

yf = y(end);
% Overshoot is measured against the FINAL value when the run converges, otherwise
% against the reference: a run that never gets there has no meaningful "final", and
% dividing by it would report a huge overshoot for a controller that is merely slow.
if ~isfinite(yf) || abs(yf) < 1e-9, yf = o.ref; end
os = 100*(max(y) - yf)/max(abs(yf), 1e-12);

band = 0.02*abs(yf);
outside = find(abs(y - yf) > band, 1, 'last');
if isempty(outside), settle = 0; else, settle = t(outside); end

r = struct();
r.t = t; r.y = y; r.u = u; r.e = e; r.xI = xI;
r.overshootPct = os;
r.settleS = settle;
r.iae = sum(abs(e))*dt;
r.satFrac = mean(u <= c.uMin + 1e-12 | u >= c.uMax - 1e-12);
r.uMaxUsed = max(abs(u));
r.integralPeak = max(abs(xI));
% how far the integrator implies a command the actuator could never deliver
r.windupExcursion = max(abs(c.Kp*e + c.Ki*xI) - max(abs([c.uMin c.uMax])))/ ...
    max(1e-12, max(abs([c.uMin c.uMax])));
r.finalValue = y(end);
r.aw = c.aw;
r.limit = [c.uMin c.uMax];
end

% ---------------------------------------------------------------------------
function o = dflt(o, d)
f = fieldnames(d);
for k = 1:numel(f)
    if ~isfield(o, f{k}), o.(f{k}) = d.(f{k}); end
end
end
