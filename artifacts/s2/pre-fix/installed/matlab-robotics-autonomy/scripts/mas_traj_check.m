function r = mas_traj_check(t, q, claims)
%MAS_TRAJ_CHECK  Trajectory contract: waypoints hit, limits respected, derivatives
%                consistent with an analytic route.
%
%   r = mas_traj_check(t, q, struct('waypoints', wp, 'vMax', 1.0, 'aMax', 2.0, ...
%                                   'qMin', -pi, 'qMax', pi))
%   r = mas_traj_check(t, q, struct('vel', v, 'acc', a, ...))  % certified limits
%
%   t             N x 1, strictly increasing (seconds)
%   q             N x d joint positions
%   wp(k).t       waypoint time; wp(k).q is the 1 x d position required there
%
%   r.waypointErr max |q(t_wp) - q_wp| (linear interpolation at the waypoint time)
%   r.vMax        max |velocity| per joint
%   r.aMax        max |acceleration| per joint
%   r.jMax        max |jerk| per joint
%   r.certified   true when analytic vel/acc were supplied; false means the peak is
%                 only a SAMPLE, and a peak between samples is not ruled out
%   r.checks, r.verdict
%
% WHY A TRAJECTORY NEEDS A CONTRACT
% A plot of q(t) that looks smooth can still: miss a via point (the interpolant
% rounds the corner), exceed a joint velocity between samples (finite differences at
% 10 Hz miss a 40 Hz wiggle), start before t=0 or run backwards after a timestamp
% bug, or overshoot a joint limit while the endpoints look fine. Those are four
% different defects; the tool reports them separately instead of one "looks OK".
%
% SAMPLED VS CERTIFIED
% When `.vel`/`.acc` are supplied, they are used for the limit check and are
% cross-checked against a 5-point interior stencil of q -- two independent routes, and
% a disagreement FAILS. The boundary samples are excluded because a one-sided
% difference there is only first order: an exact derivative and a central difference
% legitimately disagree by O(h) at t(1) and t(end), which is a property of the sampling,
% not a defect in the claim. Without `.vel`/`.acc` the limits are checked on the
% sampled data (gradient, boundaries included) and `r.certified` is false: the tool
% says the peak is a sampled peak, not a bound. Claiming a continuous-time bound from
% samples alone is exactly the overreach this flag prevents.

if nargin < 3, claims = struct(); end
t = t(:);
if ~isnumeric(q) || ndims(q) ~= 2
    error('mas_traj_check:q', 'q must be an N x d numeric matrix');
end
N = numel(t);
if size(q, 1) ~= N
    error('mas_traj_check:size', 't has %d samples but q has %d rows', N, size(q, 1));
end
d = size(q, 2);
if N < 2
    error('mas_traj_check:samples', 'need at least 2 samples, got %d', N);
end
if ~all(isfinite(t)) || ~all(isfinite(q(:)))
    error('mas_traj_check:finite', 't or q contains NaN or Inf');
end

hasWp = isfield(claims, 'waypoints') && ~isempty(claims.waypoints);
hasLim = any(isfield(claims, {'vMax','aMax','jMax','qMin','qMax'}));
hasDer = isfield(claims, 'vel') || isfield(claims, 'acc');
if ~(hasWp || hasLim || hasDer)
    error('mas_traj_check:claims', ['no waypoints, limits or analytic derivatives ' ...
        'were supplied: there is no acceptance criterion, so there is no PASS']);
end

C = struct('id', {}, 'status', {}, 'detail', {});

% ---- time base -----------------------------------------------------------
dt = diff(t);
mono = all(dt > 0);
if mono
    C = add(C, 'timeMonotonic', true, sprintf( ...
        '%d samples over [%.6g, %.6g] s, dt %.3g..%.3g s', N, t(1), t(end), min(dt), max(dt)));
else
    bad = find(dt <= 0, 1);
    C = add(C, 'timeMonotonic', false, sprintf([ ...
        't is not strictly increasing at sample %d (dt = %.3g): the trajectory runs ' ...
        'backwards or repeats a timestamp'], bad+1, dt(bad)));
    r = pack(C, NaN, NaN, NaN, NaN, NaN, false, false, false, N, d, t, q);
    return
end

% ---- waypoints -----------------------------------------------------------
wpErr = NaN;
if hasWp
    wp = claims.waypoints;
    if ~isstruct(wp)
        error('mas_traj_check:waypoints', 'waypoints must be a struct array');
    end
    tolWp = getf(claims, 'waypointTol', 1e-6);
    errs = zeros(numel(wp), 1);
    outside = false(numel(wp), 1);
    for k = 1:numel(wp)
        if ~isfield(wp(k), 't') || ~isfield(wp(k), 'q')
            error('mas_traj_check:waypointFields', 'each waypoint needs .t and .q');
        end
        qw = wp(k).q(:).';
        if numel(qw) ~= d
            error('mas_traj_check:waypointDim', 'waypoint %d has %d values, q has %d columns', ...
                k, numel(qw), d);
        end
        tw = wp(k).t;
        if tw < t(1) - 1e-12 || tw > t(end) + 1e-12
            outside(k) = true;
            errs(k) = Inf;
            continue
        end
        qi = interp1(t, q, tw, 'linear');
        errs(k) = max(abs(qi(:).' - qw));
    end
    wpErr = max(errs);
    if any(outside)
        C = add(C, 'waypointsHit', false, sprintf([ ...
            'waypoint(s) %s lie outside [%.6g, %.6g]: the trajectory never reaches ' ...
            'that time, so it cannot pass through them'], mat2str(find(outside).'), ...
            t(1), t(end)));
    else
        C = add(C, 'waypointsHit', wpErr <= tolWp, sprintf( ...
            '%d waypoint(s), max deviation %.3e (tol %.1e)', numel(wp), wpErr, tolWp));
    end
end

% ---- derivatives ---------------------------------------------------------
% gradient(F, t) rejects a vector spacing unless it is given once per array
% dimension, so differentiate joint by joint.
vFd = zeros(N, d); aFd = zeros(N, d); jFd = zeros(N, d);
for j = 1:d
    vFd(:, j) = gradient(q(:, j), t);
    aFd(:, j) = gradient(vFd(:, j), t);
    jFd(:, j) = gradient(aFd(:, j), t);
end
certV = false; certA = false;
derivErrV = NaN; derivErrA = NaN;

% A derivative at the first/last sample is one-sided and only first order, so an
% exact analytic derivative differs there by O(h) -- for a smooth signal that alone
% is a 1e-2 relative "error" and would condemn a correct trajectory. Compare on the
% interior with a 5-point stencil (O(h^4)) instead. Non-uniform sampling has no
% equally sharp route here, so the check is UNDETERMINED rather than relaxed.
h = diff(t);
uniform = max(abs(h - mean(h))) <= 1e-9*max(abs(mean(h)), eps);
canDiff = N >= 5 && uniform;
if canDiff
    idx = (3:N-2).';
    v5 = (q(idx-2,:) - 8*q(idx-1,:) + 8*q(idx+1,:) - q(idx+2,:)) ./ (12*h(idx-1));
    a5 = (-q(idx-2,:) + 16*q(idx-1,:) - 30*q(idx,:) + 16*q(idx+1,:) - q(idx+2,:)) ...
        ./ (12*h(idx-1).^2);
end

if isfield(claims, 'vel')
    vA = claims.vel;
    if ~isequal(size(vA), size(q))
        error('mas_traj_check:vel', 'claims.vel must be N x d, same as q');
    end
    scale = max(max(abs(vA)));
    if scale == 0, scale = 1; end
    tolD = getf(claims, 'derivTol', 1e-6);
    if canDiff
        derivErrV = max(max(abs(vA(idx,:) - v5))) / scale;
        C = add(C, 'velocityDerivativeAgrees', derivErrV <= tolD, sprintf( ...
            'analytic vs 5-point interior stencil: relative deviation %.3e (tol %.1e)', ...
            derivErrV, tolD));
    else
        C = add(C, 'velocityDerivativeAgrees', NaN, ...
            'non-uniform spacing or fewer than 5 samples: no independent derivative route at this tolerance');
    end
    vUse = vA; certV = true;
else
    vUse = vFd;
end

if isfield(claims, 'acc')
    aA = claims.acc;
    if ~isequal(size(aA), size(q))
        error('mas_traj_check:acc', 'claims.acc must be N x d, same as q');
    end
    scale = max(max(abs(aA)));
    if scale == 0, scale = 1; end
    tolD = getf(claims, 'derivTol', 1e-6);
    if canDiff
        derivErrA = max(max(abs(aA(idx,:) - a5))) / scale;
        C = add(C, 'accelerationDerivativeAgrees', derivErrA <= tolD, sprintf( ...
            'analytic vs 5-point interior stencil: relative deviation %.3e (tol %.1e)', ...
            derivErrA, tolD));
    else
        C = add(C, 'accelerationDerivativeAgrees', NaN, ...
            'non-uniform spacing or fewer than 5 samples: no independent derivative route at this tolerance');
    end
    aUse = aA; certA = true;
else
    aUse = aFd;
end

vMax = max(abs(vUse), [], 1);
aMax = max(abs(aUse), [], 1);
jMax = max(abs(jFd), [], 1);

if isfield(claims, 'vMax')
    lim = limit_of(claims.vMax, d);
    ok = all(vMax <= lim*(1 + 1e-12));
    C = add(C, 'velocityLimit', ok, sprintf( ...
        'max |v| %s vs limit %s (%s)', vecstr(vMax), vecstr(lim), tag(certV)));
end
if isfield(claims, 'aMax')
    lim = limit_of(claims.aMax, d);
    ok = all(aMax <= lim*(1 + 1e-12));
    C = add(C, 'accelerationLimit', ok, sprintf( ...
        'max |a| %s vs limit %s (%s)', vecstr(aMax), vecstr(lim), tag(certA)));
end
if isfield(claims, 'jMax')
    lim = limit_of(claims.jMax, d);
    ok = all(jMax <= lim*(1 + 1e-12));
    C = add(C, 'jerkLimit', ok, sprintf( ...
        'max |j| %s vs limit %s (sampled: jerk has no analytic route here)', ...
        vecstr(jMax), vecstr(lim)));
end

% ---- joint position limits ----------------------------------------------
if isfield(claims, 'qMin')
    lim = limit_of(claims.qMin, d);
    lo = min(q, [], 1);
    C = add(C, 'positionMin', all(lo >= lim - 1e-12), sprintf( ...
        'min q %s vs lower limit %s', vecstr(lo), vecstr(lim)));
end
if isfield(claims, 'qMax')
    lim = limit_of(claims.qMax, d);
    hi = max(q, [], 1);
    C = add(C, 'positionMax', all(hi <= lim + 1e-12), sprintf( ...
        'max q %s vs upper limit %s', vecstr(hi), vecstr(lim)));
end

r = pack(C, wpErr, vMax, aMax, jMax, derivErrV, certV, certA, true, N, d, t, q);
r.derivErrA = derivErrA;
r.jMax = jMax;
end

% ===========================================================================
function r = pack(C, wpErr, vMax, aMax, jMax, derivErrV, certV, certA, ran, N, d, t, q)
r = struct();
r.waypointErr = wpErr; r.vMax = vMax; r.aMax = aMax; r.jMax = jMax;
r.derivErrV = derivErrV;
r.certified = certV && certA;
r.certifiedVelocity = certV; r.certifiedAcceleration = certA;
r.nSamples = N; r.nJoints = d; r.t = t; r.q = q;
r.checks = C; r.nChecks = numel(C);
r.nPass = nnz(strcmp({C.status}, 'pass'));
r.nFail = nnz(strcmp({C.status}, 'fail'));
r.nUndetermined = nnz(strcmp({C.status}, 'undetermined'));
r.nNa = nnz(strcmp({C.status}, 'na'));
r.verdict = verdict_of(C);
if ran
    r.detail = sprintf('%d samples, %d joints, vMax %s, aMax %s, certified %d -- %s', ...
        N, d, vecstr(vMax), vecstr(aMax), r.certified, r.verdict);
else
    r.detail = sprintf('%d samples, time base invalid -- %s', N, r.verdict);
end
end

function lim = limit_of(v, d)
v = v(:).';
if isscalar(v)
    lim = repmat(v, 1, d);
elseif numel(v) == d
    lim = v;
else
    error('mas_traj_check:limit', 'limit has %d values for %d joints', numel(v), d);
end
end

function s = vecstr(v)
s = ['[' sprintf('%.4g ', v) ']'];
s = strrep(s, ' ]', ']');
end

function s = tag(cert)
if cert, s = 'analytic, certified'; else, s = 'sampled only'; end
end

function v = getf(s, name, dflt)
if isstruct(s) && isfield(s, name), v = s.(name); else, v = dflt; end
end

function C = add(C, id, pass, detail)
if ischar(pass), st = pass;
elseif isnan(pass), st = 'undetermined';
elseif pass, st = 'pass';
else, st = 'fail'; end
C(end+1) = struct('id', id, 'status', st, 'detail', detail);
end

function v = verdict_of(C)
st = {C.status};
if any(strcmp(st, 'fail')), v = 'FAIL';
elseif any(strcmp(st, 'undetermined')), v = 'UNDETERMINED';
else, v = 'PASS'; end
end
