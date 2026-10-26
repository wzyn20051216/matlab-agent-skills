function r = mas_quat_check(q, claims)
%MAS_QUAT_CHECK  Quaternion algebra contract: is this quaternion a rotation, and do
%                its derived quantities agree with independent routes?
%
%   r = mas_quat_check(q)                       % hygiene + inverse + double cover
%   r = mas_quat_check(q, struct('compose', q2, 'angle', a, 'axis', ax, ...
%                                'rotvec', rv, 'matrix', R, 'applyV', v, ...
%                                'applyExpected', Rv, ...
%                                'interp', struct('qEnd', q1, 't', 0.5)))
%
%   r.qUnit       normalised quaternion (input is never silently replaced)
%   r.R           3x3 rotation matrix
%   r.angle       rotation angle in [0, pi]
%   r.axis        rotation axis (unit), NaN when the angle is zero
%   r.rotvec      angle * axis
%   r.compose     q (x) q2, when .compose is supplied
%   r.inverseErr  max|q (x) conj(q) - identity|
%   r.slerp       sampled interpolation, when .interp is supplied
%   r.checks, r.verdict
%
% WHY THIS EXISTS
% Quaternion code fails in ways that produce a valid-looking rotation matrix:
%   * a non-unit quaternion. Every derived matrix is scaled by norm^2, so a
%     quaternion of norm 2 rotates by 4x -- the axis is right and the angle is wrong.
%   * the inverse conjugation: q^{-1} = conj(q)/norm^2, not conj(q), unless unit.
%   * composition order. q1 (x) q2 applies q2 FIRST (Hamilton product), the opposite
%     of the matrix product R1*R2 when both are read as frame maps.
%   * the double cover. q and -q are the same rotation; code that compares
%     quaternions by component equality rejects a correct orientation.
%   * SLERP that is linear in the components instead of the angle: endpoints are
%     right, the midpoint is not the shortest arc, and the speed is not constant.
%
% Each of those has a check below. The composition and matrix checks use R(q1)R(q2)
% as the independent route -- matrix multiplication shares no code with the
% quaternion product. Where Robotics System Toolbox is licensed, quat2rotm,
% quatmultiply and rotm2quat are run on the same input and the deviation reported;
% absence is reported as crossCheck.checked = false, never faked.

if nargin < 2, claims = struct(); end
q = q(:);
if numel(q) ~= 4
    error('mas_quat_check:size', 'q must have 4 elements [w x y z], got %d', numel(q));
end
if ~all(isfinite(q))
    error('mas_quat_check:finite', 'q contains NaN or Inf');
end
tolNorm = getf(claims, 'tolNorm', 1e-8);
tolComp = getf(claims, 'tolCompose', 1e-9);
tolAngle = getf(claims, 'tolAngle', 1e-9);
tolAxis = getf(claims, 'tolAxis', 1e-9);
tolVec = getf(claims, 'tolVec', 1e-9);

C = struct('id', {}, 'status', {}, 'detail', {});

% ---- unit norm ------------------------------------------------------------
nq = norm(q);
unit = abs(nq - 1) <= tolNorm;
if nq == 0
    error('mas_quat_check:zero', 'zero quaternion has no rotation');
end
qU = q / nq;
if unit
    C = add(C, 'unitNorm', true, sprintf('|q| = %.16g', nq));
else
    C = add(C, 'unitNorm', false, sprintf(['|q| = %.16g, off unit by %.3e: every derived ' ...
        'rotation is scaled by |q|^2. The checks below use the NORMALISED q, but the ' ...
        'input as given is not a rotation quaternion.'], nq, abs(nq-1)));
end

R = quat_to_rotm(qU);
[w, v] = deal(qU(1), qU(2:4));
sv = norm(v);
if sv < 1e-12
    angle = 0;
    axis = [NaN; NaN; NaN];
    axisDefined = false;
else
    angle = 2*atan2(sv, abs(w));
    axis = sign(w) * v / sv;
    if w == 0, axis = v / sv; end          % 180 deg: sign is a convention
    axisDefined = true;
end
rotvec = axis * angle;

% ---- double cover ---------------------------------------------------------
Rneg = quat_to_rotm(-qU);
coverErr = max(max(abs(R - Rneg)));
C = add(C, 'doubleCover', coverErr <= 1e-12, sprintf( ...
    'q and -q give the same R to %.1e; compare orientations, not components', coverErr));

% ---- inverse --------------------------------------------------------------
qInv = [qU(1); -qU(2:4)];                  % unit, so conj == inverse
p = quat_mult(qU, qInv);
inverseErr = max(abs(p - [1;0;0;0]));
C = add(C, 'inverse', inverseErr <= tolComp, sprintf( ...
    'q (x) conj(q) = [%.16g %.1e %.1e %.1e]', p(1), p(2), p(3), p(4)));

% ---- claimed derived quantities ------------------------------------------
if isfield(claims, 'matrix')
    Rc = claims.matrix;
    if ~isequal(size(Rc), [3 3])
        error('mas_quat_check:matrix', 'claims.matrix must be 3x3');
    end
    e = max(max(abs(R - Rc)));
    C = add(C, 'matrixVsClaim', e <= getf(claims, 'tolMatrix', tolComp), ...
        sprintf('max|R - claimed| = %.3e', e));
end
if isfield(claims, 'angle')
    e = abs(angle - claims.angle);
    C = add(C, 'angleVsClaim', e <= tolAngle, sprintf( ...
        'angle %.12g vs claimed %.12g, |diff| %.3e', angle, claims.angle, e));
end
if isfield(claims, 'axis')
    ac = claims.axis(:);
    if numel(ac) ~= 3
        error('mas_quat_check:axis', 'claims.axis must have 3 elements');
    end
    if ~axisDefined
        C = add(C, 'axisVsClaim', NaN, ...
            'rotation is the identity: the axis is undefined, so it cannot be graded');
    else
        e = min(norm(axis - ac), norm(axis + ac));
        % + and - are the same axis only at 180 deg; elsewhere the canonical axis is
        % fixed, and accepting the negative would let a reversed axis pass.
        if abs(w) > 1e-9, e = norm(axis - ac); end
        C = add(C, 'axisVsClaim', e <= tolAxis, sprintf( ...
            'axis [%s] vs claimed [%s], deviation %.3e', num2str(axis.', 4), ...
            num2str(ac.', 4), e));
    end
end
if isfield(claims, 'rotvec')
    rv = claims.rotvec(:);
    if numel(rv) ~= 3
        error('mas_quat_check:rotvec', 'claims.rotvec must have 3 elements');
    end
    e = norm(rotvec - rv);
    C = add(C, 'rotvecVsClaim', e <= tolVec, sprintf( ...
        'rotvec [%s] vs claimed [%s], deviation %.3e', num2str(rotvec.', 4), ...
        num2str(rv.', 4), e));
end
if isfield(claims, 'applyV')
    vv = claims.applyV(:);
    if numel(vv) ~= 3
        error('mas_quat_check:applyV', 'claims.applyV must have 3 elements');
    end
    if ~isfield(claims, 'applyExpected')
        error('mas_quat_check:applyExpected', 'applyV requires applyExpected');
    end
    e = norm(R*vv - claims.applyExpected(:));
    C = add(C, 'applyVsClaim', e <= getf(claims, 'tolApply', 1e-9), ...
        sprintf('|R*v - claimed| = %.3e', e));
end

% ---- composition ----------------------------------------------------------
if isfield(claims, 'compose')
    q2 = claims.compose(:);
    if numel(q2) ~= 4
        error('mas_quat_check:compose', 'claims.compose must have 4 elements');
    end
    n2 = norm(q2);
    if n2 == 0, error('mas_quat_check:composeZero', 'compose quaternion is zero'); end
    q2u = q2 / n2;
    C = add(C, 'composeUnitNorm', abs(n2 - 1) <= tolNorm, sprintf( ...
        'second quaternion has |q| = %.16g: the product as given is not a rotation', n2));
    q12 = quat_mult(qU, q2u);
    r.compose = q12;
    R2 = quat_to_rotm(q2u);
    e = max(max(abs(quat_to_rotm(q12) - R*R2)));
    C = add(C, 'composeVsMatrix', e <= tolComp, sprintf( ...
        ['|R(q1*q2) - R(q1)R(q2)| = %.3e -- the matrix route shares no code with ' ...
         'the quaternion product'], e));
    if have_toolbox()
        qb = normalize4(quatmultiply(qU.', q2u.'));
        e2 = min(max(abs(q12.' - qb)), max(abs(q12.' + qb)));
        C = add(C, 'composeVsToolbox', e2 <= 1e-12, ...
            sprintf('vs quatmultiply, deviation %.3e (sign-insensitive)', e2));
    else
        C = add(C, 'composeVsToolbox', 'na', 'Robotics System Toolbox not available');
    end
end

% ---- SLERP ---------------------------------------------------------------
if isfield(claims, 'interp')
    it = claims.interp;
    if ~isfield(it, 'qEnd') || ~isfield(it, 't')
        error('mas_quat_check:interp', 'interp needs qEnd and t');
    end
    q1 = it.qEnd(:);
    if numel(q1) ~= 4, error('mas_quat_check:qEnd', 'qEnd must have 4 elements'); end
    q1 = q1 / norm(q1);
    ts = it.t(:).';
    if any(ts < 0 | ts > 1)
        error('mas_quat_check:interpRange', 'interp.t must lie in [0,1]');
    end
    [qs, ang] = slerp(qU, q1, ts);
    r.slerp = qs;
    r.slerpAngle = ang;
    % endpoints, sign-insensitive
    e0 = quat_dist(qs(:,1), qU);
    e1 = quat_dist(qs(:,end), q1);
    C = add(C, 'slerpEndpoints', max(e0, e1) <= 1e-9, sprintf( ...
        'endpoint deviations %.3e / %.3e', e0, e1));
    % constant angular speed: angle from q0 must be t*angle(q0,q1)
    total = quat_angle(qU, q1);
    expected = ts(:) * total;
    linErr = max(abs(ang(:) - expected));
    C = add(C, 'slerpGeodesic', linErr <= 1e-9, sprintf( ...
        'angle along the arc deviates from t*%.6f by %.3e', total, linErr));
    if isfield(it, 'expected')
        qe = it.expected;
        if size(qe, 1) ~= 4
            error('mas_quat_check:interpExpected', 'interp.expected must be 4xK');
        end
        e = max(arrayfun(@(k) quat_dist(qs(:,k), qe(:,k)), 1:numel(ts)));
        C = add(C, 'slerpVsClaim', e <= getf(claims, 'tolSlerp', 1e-9), ...
            sprintf('max quaternion distance to the claimed samples = %.3e', e));
    end
end

% ---- toolbox cross-check --------------------------------------------------
if have_toolbox()
    e = max(max(abs(R - quat2rotm(qU.'))));
    C = add(C, 'matrixVsToolbox', e <= 1e-12, sprintf('vs quat2rotm, deviation %.3e', e));
    qb = normalize4(rotm2quat(R));
    qb = qb(:);
    e2 = min(norm(qU - qb), norm(qU + qb));
    C = add(C, 'roundTripVsToolbox', e2 <= 1e-9, sprintf( ...
        'rotm2quat(quat2rotm(q)) returns q up to sign, deviation %.3e', e2));
else
    C = add(C, 'matrixVsToolbox', 'na', 'Robotics System Toolbox not available');
    C = add(C, 'roundTripVsToolbox', 'na', 'Robotics System Toolbox not available');
end

r.q = q; r.qUnit = qU; r.R = R; r.angle = angle; r.axis = axis;
r.rotvec = rotvec; r.inverseErr = inverseErr; r.checks = C;
r.nChecks = numel(C); r.nPass = nnz(strcmp({C.status}, 'pass'));
r.nFail = nnz(strcmp({C.status}, 'fail'));
r.nUndetermined = nnz(strcmp({C.status}, 'undetermined'));
r.nNa = nnz(strcmp({C.status}, 'na'));
r.verdict = verdict_of(C);
r.detail = sprintf('|q| %.12g, angle %.6f rad, %d/%d checks -- %s', ...
    nq, angle, r.nPass, r.nChecks, r.verdict);
end

% ===========================================================================
function [qs, ang] = slerp(q0, q1, ts)
% Shortest-arc SLERP. The sign flip makes d >= 0, which selects the arc <= pi:
% without it, q and -q describe the same orientation but the interpolation takes
% the long way around, and the midpoint is wrong even though both endpoints match.
d = dot(q0, q1);
if d < 0, q1 = -q1; d = -d; end
d = min(d, 1);
th0 = acos(d);
qs = zeros(4, numel(ts));
ang = zeros(1, numel(ts));
for k = 1:numel(ts)
    t = ts(k);
    if th0 < 1e-12
        q = q0;
    elseif d > 0.9995
        q = (1-t)*q0 + t*q1;
        q = q / norm(q);
    else
        q = (sin((1-t)*th0)*q0 + sin(t*th0)*q1) / sin(th0);
    end
    qs(:,k) = q / norm(q);
    ang(k) = 2*acos(min(abs(dot(q0, qs(:,k))), 1));
end
end

function d = quat_dist(a, b)
a = a / norm(a); b = b / norm(b);
d = min(norm(a - b), norm(a + b));
end

function a = quat_angle(q0, q1)
d = abs(dot(q0/norm(q0), q1/norm(q1)));
a = 2*acos(min(d, 1));
end

function q = normalize4(q)
q = q(:).' / norm(q);
end

function p = quat_mult(a, b)
w1 = a(1); v1 = a(2:4);
w2 = b(1); v2 = b(2:4);
p = [w1*w2 - v1.'*v2; w1*v2 + w2*v1 + cross(v1, v2)];
end

function R = quat_to_rotm(q)
q = q(:) / max(norm(q), eps);
w = q(1); x = q(2); y = q(3); z = q(4);
R = [1-2*(y*y+z*z),   2*(x*y-w*z),   2*(x*z+w*y); ...
       2*(x*y+w*z), 1-2*(x*x+z*z),   2*(y*z-w*x); ...
       2*(x*z-w*y), 2*(y*z+w*x), 1-2*(x*x+y*y)];
end

function tf = have_toolbox()
tf = exist('quat2rotm', 'file') == 2 && exist('quatmultiply', 'file') == 2 && ...
     exist('rotm2quat', 'file') == 2;
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
