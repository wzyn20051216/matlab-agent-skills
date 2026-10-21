function r = mas_kin_check(L, q, opts)
%MAS_KIN_CHECK  Planar n-R forward kinematics with the Jacobian cross-checked.
%
%   r = mas_kin_check([0.5 0.4 0.3], [0.2; -0.5; 0.1])
%
%   r.pos        [x; y] tip position
%   r.theta      absolute angle of each link (cumsum of q)
%   r.J          analytic Jacobian, 2 x n
%   r.Jnum       central-difference Jacobian    -- different method, same quantity
%   r.jacErr     max|J - Jnum| / max|J|
%   r.singular   rank loss (tip at a workspace boundary or at the base)
%   r.condJ      condition number, capped
%   r.manip      manipulability sqrt(det(J*J'))
%   r.maxReach   sum(L), the exact reach of a chain with free-rotating joints
%   r.onBoundary  |pos| at (or beyond) maxReach
%   r.verdict
%
% WHY THE JACOBIAN IS COMPARED AGAINST A FINITE DIFFERENCE
% Every downstream consumer -- resolved-rate control, IK, singularity maps, the
% manipulability ellipsoid, force/torque mapping -- is built on J. A sign error or a
% transposed index in the analytic Jacobian does not throw, does not look wrong on a
% plot of the arm, and produces a controller that drives the tip the wrong way.
% Differentiating the FK numerically shares no code with the analytic derivative, so
% agreement between the two is real evidence and disagreement is a defect. It is
% checked on every call rather than left to the caller.
%
% The analytic form used here: for a planar chain with absolute link angles
% theta_i = sum_{k<=i} q_k,
%     dx/dq_j = -sum_{i>=j} L_i sin(theta_i),   dy/dq_j = sum_{i>=j} L_i cos(theta_i)
% -- the OUTER sum appears because joint j moves every link from j outward. Dropping
% it is the standard mistake: it yields a Jacobian that is correct for the first joint
% and silently wrong for all the others.

if nargin < 3, opts = struct(); end
opts = dflt(opts, struct('h', 1e-6, 'singTol', 1e-8));

% L, q and theta are COLUMNS throughout. Mixing orientations here silently
% produces an outer product: L(j:n) as a row times theta(j:n) as a column gives a
% K-by-K matrix, sum() then returns a 1-by-K vector, and the assignment into
% J(1,j) fails -- but only for n > 2, so a 2-link smoke test would pass.
L = L(:);  n = numel(L);
q = q(:);
if numel(q) ~= n
    error('mas_kin_check:size', 'L has %d links but q has %d joints', n, numel(q));
end
if any(L <= 0) || ~all(isfinite(L))
    error('mas_kin_check:L', 'link lengths must be finite and positive');
end

[pos, theta] = fk(L, q);

% ---- analytic Jacobian ----------------------------------------------------
J = zeros(2, n);
for j = 1:n
    J(1, j) = -sum(L(j:n) .* sin(theta(j:n)));
    J(2, j) =  sum(L(j:n) .* cos(theta(j:n)));
end

% ---- numerical Jacobian (central difference) ------------------------------
h = opts.h;
Jnum = zeros(2, n);
for j = 1:n
    qp = q; qp(j) = qp(j) + h;
    qm = q; qm(j) = qm(j) - h;
    Jnum(:, j) = (fk(L, qp) - fk(L, qm)) / (2*h);
end

scale = max(abs(J(:)));
if scale == 0, scale = 1; end
jacErr = max(abs(J(:) - Jnum(:))) / scale;

% ---- conditioning ---------------------------------------------------------
s = svd(J);
sMax = max(s); sMin = min(s);
condJ = min(sMax / max(sMin, eps(sMax)), 1/realmin);
singular = sMin < opts.singTol * max(sMax, 1);
manip = sqrt(max(prod(s.^2), 0));

maxReach = sum(L);
onBoundary = norm(pos) > maxReach - 1e-9;

warn = {};
if jacErr > 1e-6
    warn{end+1} = sprintf(['analytic and numerical Jacobians disagree by %.2e: one ' ...
        'of them is wrong, and every IK / resolved-rate result built on it is wrong too.'], jacErr);
end
if singular
    warn{end+1} = ['Jacobian lost rank: the tip is at a workspace boundary or the ' ...
        'base, so one Cartesian direction is unreachable.'];
end

r = struct();
r.pos = pos; r.theta = theta; r.L = L; r.q = q;
r.J = J; r.Jnum = Jnum; r.jacErr = jacErr;
r.singular = singular; r.condJ = condJ; r.manip = manip;
r.maxReach = maxReach; r.onBoundary = onBoundary;
r.warnings = warn;
r.ok = isempty(warn);
r.verdict = tern(r.ok, 'PASS', 'FAIL');
r.detail = sprintf('tip (%.4f, %.4f), jacErr %.2e, cond %.3g, manip %.4f -- %s', ...
    pos(1), pos(2), jacErr, condJ, manip, r.verdict);
end

% ---------------------------------------------------------------------------
function [pos, theta] = fk(L, q)
theta = cumsum(q(:));
pos = [sum(L(:) .* cos(theta)); sum(L(:) .* sin(theta))];
end

% ---------------------------------------------------------------------------
function o = dflt(o, d)
f = fieldnames(d);
for k = 1:numel(f)
    if ~isfield(o, f{k}), o.(f{k}) = d.(f{k}); end
end
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
