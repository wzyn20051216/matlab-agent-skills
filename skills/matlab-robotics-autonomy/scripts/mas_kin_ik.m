function r = mas_kin_ik(L, pTarget, q0, opts)
%MAS_KIN_IK  Damped-least-squares inverse kinematics for a planar n-R chain.
%
%   r = mas_kin_ik([0.5 0.4], [0.6; 0.3], [0.1; 0.1])
%   r = mas_kin_ik(L, p, q0, struct('method','normal'))   % the fragile variant
%
%   r.q          joint solution
%   r.pos        tip actually reached (forward kinematics of r.q)
%   r.err        |pTarget - r.pos|
%   r.nIter      iterations used
%   r.converged  err <= tol
%   r.feasible   target inside maxReach (checked before iterating)
%   r.stepRawMax largest UNBOUNDED |dq| -- the number that explodes at a singularity
%   r.maxStep    largest |dq| actually applied, after the step limit
%   r.condMin    smallest Jacobian condition number seen along the path
%   r.verdict
%
% WHY DAMPING, AND WHAT THE `normal` METHOD IS FOR
% Solving (J'J)dq = J'e is the form most people write first. At a singularity J'J
% loses rank, MATLAB warns and returns a step of order 1/eps, and the arm is thrown
% across the workspace. DLS solves
%
%     dq = J'(JJ' + lambda^2 I)^{-1} e
%
% which stays bounded; the cost is that the tip slows near the boundary instead of
% teleporting, which is the behaviour you want.
%
% `method='normal'` is kept deliberately, not as a curiosity: it is the negative
% control the test uses to prove `stepRawMax` measures something. A "robustness"
% metric that stays flat when the fragile method blows up would be worthless, so the
% test asserts the normal method's raw step is orders of magnitude larger than DLS's
% at a boundary target.
%
% STEPS ARE LIMITED, AND THE UNLIMITED VALUE IS STILL REPORTED
% The update is clamped to `stepLimit` rad per joint per iteration, because the
% Jacobian is a first-order model: a large Cartesian error produces a step that
% overshoots the region where that model holds, and the iteration oscillates
% instead of converging. Suppressing the clamp silently would hide the very
% information that tells you the configuration is bad, so both numbers are returned:
% `maxStep` is what was applied, `stepRawMax` is what the linearization asked for.
%
% Joint limits are applied AFTER the step -- clamping inside would corrupt the
% least-squares direction -- and `r.limitHit` records whether the clamp ever bound,
% because a solution found while clamped solves a DIFFERENT problem.

if nargin < 4, opts = struct(); end
opts = dflt(opts, struct('lambda', 1e-3, 'maxIter', 200, 'tol', 1e-10, ...
    'method', 'dls', 'stepLimit', 0.5, 'qMin', [], 'qMax', []));

% L, q and theta are COLUMNS throughout.
L = L(:);  n = numel(L);
pTarget = pTarget(:);
if numel(pTarget) ~= 2
    error('mas_kin_ik:target', 'pTarget must be a 2-element [x; y]');
end
if nargin < 3 || isempty(q0), q0 = zeros(n, 1); end
q0 = q0(:);
if numel(q0) ~= n
    error('mas_kin_ik:size', 'L has %d links but q0 has %d joints', n, numel(q0));
end

maxReach = sum(L);
biggest = max(L);
minReach = max(0, 2*biggest - maxReach);       % only > 0 if one link dominates
d = norm(pTarget);
feasible = (d <= maxReach + 1e-9) && (d >= minReach - 1e-9);

q = q0;
warn = {};
if ~feasible
    % Say which side, because "infeasible" alone sends the caller looking in the
    % wrong place: too far for the arm, or too close for it to fold back.
    if d > maxReach + 1e-9
        why = sprintf('beyond max reach %.4f', maxReach);
    else
        why = sprintf('inside min reach %.4f (the longest link cannot fold back that far)', minReach);
    end
    warn{end+1} = sprintf('target at |p| = %.4f is %s: no solution exists, no iterations run', d, why);
    nIter = 0; maxStep = 0; stepRawMax = 0; condMin = Inf; err = norm(pTarget - fk(L, q));
else
    maxStep = 0; stepRawMax = 0; condMin = Inf; nIter = opts.maxIter;
    for it = 1:opts.maxIter
        e = pTarget - fk(L, q);
        err = norm(e);
        nIter = it;
        if err <= opts.tol, break; end
        J = jac(L, q);
        s = svd(J);
        condMin = min(condMin, s(1)/max(s(end), eps(s(1))));
        switch lower(opts.method)
            case 'dls'
                dq = J.' * ((J*J.' + opts.lambda^2*eye(2)) \ e);
            case 'normal'
                dq = (J.'*J) \ (J.'*e);
            otherwise
                error('mas_kin_ik:method', 'unknown method "%s"', opts.method);
        end
        raw = norm(dq);
        if ~isfinite(raw)
            warn{end+1} = sprintf('non-finite step at iteration %d: Jacobian is singular here', it);
            break;
        end
        stepRawMax = max(stepRawMax, raw);
        dq = clamp_norm(dq, opts.stepLimit);
        maxStep = max(maxStep, norm(dq));
        q = q + dq;
        if ~isempty(opts.qMin), q = max(q, opts.qMin(:)); end
        if ~isempty(opts.qMax), q = min(q, opts.qMax(:)); end
    end
end

limitHit = false;
if ~isempty(opts.qMin), limitHit = limitHit || any(q <= opts.qMin(:) + 1e-12); end
if ~isempty(opts.qMax), limitHit = limitHit || any(q >= opts.qMax(:) - 1e-12); end
if limitHit
    warn{end+1} = ['a joint limit bound at the solution: this is a constrained ' ...
        'solution, not the unconstrained IK that was asked for.'];
end

r = struct();
r.q = q; r.pos = fk(L, q); r.err = err; r.nIter = nIter;
r.converged = (err <= opts.tol);
r.feasible = feasible; r.maxReach = maxReach; r.minReach = minReach;
r.maxStep = maxStep; r.stepRawMax = stepRawMax;
r.condMin = condMin; r.limitHit = limitHit;
r.warnings = warn;
r.ok = r.converged;
r.verdict = tern(r.ok, 'PASS', 'FAIL');
r.detail = sprintf('err %.3e in %d iters, maxStep %.3g, rawMax %.3g, minCond %.3g -- %s', ...
    err, nIter, maxStep, stepRawMax, condMin, r.verdict);
end

% ---------------------------------------------------------------------------
function r = dflt(r, d)
f = fieldnames(d);
for k = 1:numel(f)
    if ~isfield(r, f{k}), r.(f{k}) = d.(f{k}); end
end
end
function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
function p = fk(L, q)
th = cumsum(q(:));
p = [sum(L(:).*cos(th)); sum(L(:).*sin(th))];
end
function J = jac(L, q)
n = numel(L);
th = cumsum(q(:));
J = zeros(2, n);
for j = 1:n
    J(1, j) = -sum(L(j:n) .* sin(th(j:n)));
    J(2, j) =  sum(L(j:n) .* cos(th(j:n)));
end
end
function v = clamp_norm(v, lim)
nv = norm(v);
if nv > lim, v = v * (lim/nv); end
end
