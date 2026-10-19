function res = sw_floquet(p, opts)
%SW_FLOQUET  Periodic-steady-state and Floquet (monodromy) multipliers of the
%            closed-loop switching converter, from the period map.
%
%   res = sw_floquet(p)          analyse the configuration described by p
%   res = sw_floquet(p, opts)    opts.maxIter (4000), opts.tol (1e-12),
%                                opts.x0 (warm start), opts.verbose (true)
%
% OUTPUT
%   res.xstar     periodic steady state (state at a period boundary)
%   res.lambda    Floquet multipliers  eig(DP(x*))
%   res.maxAbs    max |lambda|  -> local asymptotic stability iff < 1
%   res.margin   1 - maxAbs   (distance from the unit circle; larger is safer)
%   res.iter      periods needed to reach the fixed point
%   res.J         numerically differentiated period map
%   res.converged fixed point reached within maxIter
%   res.consistent  |maxAbs - average-model discrete pole| is reported separately
%                   by the caller; this function makes no such comparison itself
%
% WHAT THIS PROVES, AND WHAT IT DOES NOT
% ------------------------------------------------------------------
% The converter switches at 50 kHz, so it is a PERIODIC system: the right object
% is not "the eigenvalues of a linear model" but the Floquet multipliers of the
% periodic orbit. Writing P for one period of the closed loop,
%     x_{k+1} = P(x_k)
% the orbit is LOCALLY ASYMPTOTICALLY STABLE iff every |lambda(DP(x*))| < 1.
% This is an exact statement about the sampled dynamics and needs no settling
% time, no time window and no average model.
%
% It is still LOCAL. It does not claim global stability, does not cover a load
% step (R changes, so the map is non-autonomous across the step), and does not
% cover the saturating start-up. Those are covered separately by time-domain
% runs, and are labelled as such in the report.

if nargin < 2, opts = struct(); end
if ~isfield(opts,'maxIter'), opts.maxIter = 4000; end
if ~isfield(opts,'tol'),     opts.tol     = 1e-12; end
if ~isfield(opts,'verbose'), opts.verbose = true; end

nDly = p.nDly; nd = p.sens.nd;
n = 4 + nDly + nd;                     % 3 plant + nDly duty + yS + nd measurements

if isfield(opts,'x0') && ~isempty(opts.x0)
    x = opts.x0(:);
else
    % sensible cold start: iL at the load current, vC at the reference,
    % integrator at zero (correct for ff=1: iLref = xI + iLoad), duty at D0
    x = [p.Vref/p.R; p.Vref; 0; repmat(p.Vref/p.Vin, nDly, 1); 0; zeros(nd,1)];
end
if numel(x) ~= n
    error('sw_floquet:badX0','x0 has %d entries, expected %d', numel(x), n);
end

%% ---- 1) iterate the map to the periodic steady state ----
hist = zeros(1, opts.maxIter);
converged = false;
it = 0;
for k = 1:opts.maxIter
    xn = sw_period_map(x, p);
    dk = max(abs(xn - x));
    hist(k) = dk;
    x = xn; it = k;
    if dk < opts.tol, converged = true; break; end
end
if ~converged
    % a slowly drifting fixed point is itself a result: report it, do not hide it
    if opts.verbose
        fprintf(2,'  [sw_floquet] no fixed point within %d periods (last d=%.3e)\n', ...
            opts.maxIter, hist(it));
    end
end

%% ---- 2) numerical Jacobian of the period map (forward differences) ----
J = zeros(n, n);
xnext0 = sw_period_map(x, p);
for q = 1:n
    h = 1e-7*max(1, abs(x(q)));
    xp = x; xp(q) = xp(q) + h;
    J(:,q) = (sw_period_map(xp, p) - xnext0)/h;
end
lam = eig(J);
[~, iw] = max(abs(lam));

%% ---- 3) independent consistency check: run the map from a perturbed state ----
% If the linearisation is meaningful, the deviation should decay at the rate of
% the dominant multiplier. This is a time-domain check of the eigenvalue, not a
% substitute for it, but it catches a wrong Jacobian.
dx0 = zeros(n,1); dx0(2) = 0.05;                   % 50 mV on vC
xp = x + dx0;
nk = 120;
env = zeros(1,nk);
for k = 1:nk
    xp = sw_period_map(xp, p);
    env(k) = abs(xp(2) - x(2));
end
% fit the tail (skip the first 10 periods, where fast modes still dominate)
% IMPORTANT: if there is no period-1 fixed point the "perturbation decay" measures
% attraction to a LIMIT CYCLE, not to a point -- it is then meaningless and must
% not be reported as if it confirmed the multiplier. Measured example (nDly=2):
% the fit returns 1.00096 while the linearisation says 1.1466, because the orbit
% has already been captured by the cycle.
w = 10:min(nk, 60);
if converged && numel(w) > 5 && all(env(w) > 0)
    pf = polyfit(w, log(env(w)), 1);
    lamEmp = exp(pf(1));
else
    lamEmp = NaN;
end

res = struct('xstar', x, 'lambda', lam, 'maxAbs', max(abs(lam)), ...
    'margin', 1 - max(abs(lam)), 'iter', it, 'converged', converged, ...
    'J', J, 'lamEmp', lamEmp, 'env', env, 'nStates', n, ...
    'nDly', nDly, 'nd', nd);

if opts.verbose
    fprintf('  fixed point after %d periods (d=%.2e), states=%d\n', it, hist(it), n);
    fprintf('  |lambda| = [%s]\n', strjoin(arrayfun(@(z) sprintf('%.5f',abs(z)), ...
        lam, 'UniformOutput', false).', ', '));
    fprintf('  max|lambda| = %.5f  -> margin to unit circle = %.5f  (%s)\n', ...
        res.maxAbs, res.margin, ternary(res.maxAbs < 1, 'STABLE', 'UNSTABLE'));
    if isnan(lamEmp)
        fprintf('  empirical decay: N/A (no period-1 orbit, so the decay would\n');
        fprintf('                   measure attraction to a limit cycle, not to a point)\n');
    else
        fprintf('  empirical decay from a 50 mV perturbation: %.5f (vs dominant %.5f)\n', ...
            lamEmp, abs(lam(iw)));
    end
end
end

function s = ternary(c,a,b)
if c, s = a; else, s = b; end
end
