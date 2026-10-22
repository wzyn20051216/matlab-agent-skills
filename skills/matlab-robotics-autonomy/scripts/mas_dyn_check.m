function r = mas_dyn_check(params, q, qd, claims)
%MAS_DYN_CHECK  Planar 2-link dynamics contract: M, C, g checked against an
%               independent Lagrange route and against energy conservation.
%
%   r = mas_dyn_check(p, q, qd)
%   r = mas_dyn_check(p, q, qd, struct('M', M, 'C', C, 'g', g))
%
%   p.m1,p.m2      link masses                p.l1,p.l2   link lengths
%   p.lc1,p.lc2    COM distances (default l/2)
%   p.I1,p.I2      COM inertias (default m*l^2/12, uniform rod)
%   p.g            gravity (default 9.81)
%
%   r.Mref,r.Cref,r.gref  analytic reference at (q,qd)
%   r.M,r.C,r.g           the model actually graded (claim if supplied)
%   r.skewErr      max|Mdot - 2C + (Mdot - 2C)'| / scale
%   r.coriolisErr  |C*qd - (Mdot*qd - dT/dq)| / scale (Lagrange identity)
%   r.gravityErr   |g - dV/dq| / scale (central difference of the potential)
%   r.energyDrift  |E(T) - E(0)| / max(|E(0)|, 1) under tau = 0, RK4
%   r.energySource which model the ODE integrated ('reference model' or 'claimed model')
%   r.checks, r.verdict
%
% THE THREE PROPERTIES THAT MAKE A DYNAMICS MODEL USABLE
%   1. M(q) symmetric and positive definite. A non-symmetric M cannot come from a
%      scalar kinetic energy; a non-PD M means some velocity direction has negative
%      kinetic energy and the simulation can run backwards in time.
%   2. Mdot - 2C skew-symmetric. This is passivity: with tau = 0 the system cannot
%      create energy. A sign error in C breaks it, and the arm still moves.
%   3. g = dV/dq. A gravity vector that is not the gradient of the potential is a
%      different system than the one the energy check assumes.
%
% The reference M, C and g are derived from the Lagrange equations for a planar
% 2-link arm. They are NOT accepted on faith either: M is rebuilt from link kinetic
% energies (velocities from forward kinematics), C*qd from the identity
% Mdot*qd - dT/dq with numerical derivatives, and g from a central difference of
% the potential. Those routes share no algebra with the closed forms.
%
% ENERGY CONSERVATION is the end-to-end check: RK4 integrates a model with zero
% torque for 2 s. A consistent model holds its energy; a wrong C sign or a
% non-symmetric M leaks or creates energy, and the drift is reported, not hidden.
% The integrated model is the reference unless `claims.model` -- a handle returning
% [M,C,g] at (q,qd) -- is supplied. Point claims (M,C,g matrices at one pose) cannot
% define dynamics elsewhere, so integrating those as constants would measure nothing;
% the point claims are graded against the independent routes above instead.
%
% Claims are optional. With no claims the tool verifies the reference model itself
% (useful as a generator and as a self-test); with claims it grades the submitted
% M, C, g against the independent routes.

if nargin < 4, claims = struct(); end
p = dflt_params(params);
q = q(:); qd = qd(:);
if numel(q) ~= 2 || numel(qd) ~= 2
    error('mas_dyn_check:size', 'q and qd must have 2 elements (planar 2-link)');
end
if ~all(isfinite(q)) || ~all(isfinite(qd))
    error('mas_dyn_check:finite', 'q or qd contains NaN or Inf');
end

[Mref, Cref, gref] = model(p, q, qd);

% ---- claims ---------------------------------------------------------------
hasM = isfield(claims, 'M') && ~isempty(claims.M);
hasC = isfield(claims, 'C') && ~isempty(claims.C);
hasG = isfield(claims, 'g') && ~isempty(claims.g);
M = Mref; C = Cref; gv = gref;
if hasM
    if ~isequal(size(claims.M), [2 2]), error('mas_dyn_check:M', 'claims.M must be 2x2'); end
    M = claims.M;
end
if hasC
    if ~isequal(size(claims.C), [2 2]), error('mas_dyn_check:C', 'claims.C must be 2x2'); end
    C = claims.C;
end
if hasG
    if numel(claims.g) ~= 2, error('mas_dyn_check:g', 'claims.g must have 2 elements'); end
    gv = claims.g(:);
end

Ck = struct('id', {}, 'status', {}, 'detail', {});

% ---- mass matrix ----------------------------------------------------------
symErr = max(max(abs(M - M.')));
scaleM = max(1, max(abs(M(:))));
Ck = add(Ck, 'massSymmetry', symErr <= 1e-12*scaleM, sprintf( ...
    'max|M - M''| = %.3e (scale %.3g)', symErr, scaleM));
ev = eig((M + M.')/2);
Ck = add(Ck, 'massPositiveDefinite', all(ev > 0), sprintf( ...
    'eigenvalues %s', vecstr(ev)));

dTdq = T_grad(p, q, qd);
Tval = kinetic(p, q, qd);
% M from kinetic energy: T(ej) = 0.5*Mjj, T(e1+e2) - T(e1) - T(e2) = M12.
Mnum = zeros(2);
Mnum(1,1) = 2*kinetic(p, q, [1;0]);
Mnum(2,2) = 2*kinetic(p, q, [0;1]);
Mnum(1,2) = kinetic(p, q, [1;1]) - kinetic(p, q, [1;0]) - kinetic(p, q, [0;1]);
Mnum(2,1) = Mnum(1,2);
eM = max(max(abs(Mref - Mnum))) / max(1, max(abs(Mref(:))));
if hasM
    e = max(max(abs(M - Mref))) / scaleM;
    Ck = add(Ck, 'massVsReference', e <= getf(claims, 'tolM', 1e-9), sprintf( ...
        'claimed M vs closed form: relative deviation %.3e', e));
    Ck = add(Ck, 'massVsEnergyRoute', ...
        max(max(abs(M - Mnum)))/scaleM <= getf(claims, 'tolM', 1e-9), sprintf( ...
        'claimed M vs kinetic-energy route: %.3e', max(max(abs(M - Mnum)))/scaleM));
else
    Ck = add(Ck, 'massVsEnergyRoute', eM <= 1e-10, sprintf( ...
        'closed form vs kinetic-energy route: %.3e', eM));
end

% ---- Coriolis: skew and Lagrange identity ---------------------------------
h = 1e-6;
Mp = model(p, q + h*qd, qd); Mm = model(p, q - h*qd, qd);
Mdot = (Mp - Mm) / (2*h);
N = Mdot - 2*C;
nScale = max(1, max(abs(N(:))));
skewErr = max(max(abs(N + N.'))) / nScale;
Ck = add(Ck, 'coriolisSkew', skewErr <= 1e-8, sprintf( ...
    'max|Mdot-2C + (Mdot-2C)''| / scale = %.3e -- passivity', skewErr));

corNum = Mdot*qd - dTdq;
corUse = C*qd;
cScale = max(1, max(abs(corNum)));
corErr = norm(corUse - corNum) / cScale;
Ck = add(Ck, 'coriolisIdentity', corErr <= getf(claims, 'tolC', 1e-6), sprintf( ...
    '|C*qd - (Mdot*qd - dT/dq)| / scale = %.3e', corErr));
if hasC
    e = max(max(abs(C - Cref))) / max(1, max(abs(Cref(:))));
    Ck = add(Ck, 'coriolisVsReference', e <= getf(claims, 'tolC', 1e-9), sprintf( ...
        'claimed C vs closed form: relative deviation %.3e', e));
end

% ---- gravity --------------------------------------------------------------
gnum = V_grad(p, q);
gScale = max(1, max(abs(gnum)));
gErr = norm(gv - gnum) / gScale;
Ck = add(Ck, 'gravityGradient', gErr <= getf(claims, 'tolG', 1e-6), sprintf( ...
    '|g - dV/dq| / scale = %.3e (central difference of V)', gErr));
if hasG
    e = norm(gv - gref) / gScale;
    Ck = add(Ck, 'gravityVsReference', e <= getf(claims, 'tolG', 1e-9), sprintf( ...
        'claimed g vs closed form: relative deviation %.3e', e));
end

% ---- energy conservation --------------------------------------------------
% The ODE has to use M(q), C(q,qd), g(q) at EVERY step. A point claim (2x2 M at one
% configuration) cannot define dynamics elsewhere, so integrating it as a constant
% matrix would conserve nothing and measure the wrong thing. By default the reference
% model is integrated; `claims.model` (a handle [M,C,g] = f(q,qd)) makes the energy
% check grade a submitted model end to end instead.
tolE = getf(claims, 'tolEnergy', 1e-6);
if isfield(claims, 'model') && ~isempty(claims.model)
    if ~isa(claims.model, 'function_handle')
        error('mas_dyn_check:model', 'claims.model must be a function handle [M,C,g] = f(q,qd)');
    end
    mf = claims.model; energySrc = 'claimed model';
else
    mf = @(qq, qqd) model(p, qq, qqd); energySrc = 'reference model';
end
[drift, E0, E1, nStep] = energy_drift(p, mf, q, qd);
Ck = add(Ck, 'energyConservation', drift <= tolE, sprintf( ...
    'RK4 %d steps, tau=0, %s: |dE|/max(|E0|,1) = %.3e (E0 %.6g -> E1 %.6g, tol %.1e)', ...
    nStep, energySrc, drift, E0, E1, tolE));

r = struct();
r.Mref = Mref; r.Cref = Cref; r.gref = gref;
r.M = M; r.C = C; r.g = gv;
r.claimed = struct('M', hasM, 'C', hasC, 'g', hasG);
r.T = Tval; r.dTdq = dTdq; r.Mnum = Mnum;
r.skewErr = skewErr; r.coriolisErr = corErr; r.gravityErr = gErr;
r.massVsRefErr = NaN; if hasM, r.massVsRefErr = max(max(abs(M - Mref)))/scaleM; end
r.energyDrift = drift; r.E0 = E0; r.E1 = E1; r.energySource = energySrc;
r.checks = Ck; r.nChecks = numel(Ck);
r.nPass = nnz(strcmp({Ck.status}, 'pass'));
r.nFail = nnz(strcmp({Ck.status}, 'fail'));
r.nUndetermined = nnz(strcmp({Ck.status}, 'undetermined'));
r.nNa = nnz(strcmp({Ck.status}, 'na'));
r.verdict = verdict_of(Ck);
r.detail = sprintf(['M eig %s, skew %.3e, coriolis %.3e, gravity %.3e, ' ...
    'energy drift %.3e -- %s'], vecstr(ev), skewErr, corErr, gErr, drift, r.verdict);
end

% ===========================================================================
function [M, C, g] = model(p, q, qd)
q1 = q(1); q2 = q(2); d1 = qd(1); d2 = qd(2);
c2 = cos(q2); s2 = sin(q2);
m1 = p.m1; m2 = p.m2; l1 = p.l1; lc1 = p.lc1; lc2 = p.lc2;
I1 = p.I1; I2 = p.I2; g0 = p.g;

M11 = I1 + I2 + m1*lc1^2 + m2*(l1^2 + lc2^2 + 2*l1*lc2*c2);
M12 = I2 + m2*(lc2^2 + l1*lc2*c2);
M22 = I2 + m2*lc2^2;
M = [M11 M12; M12 M22];

h = m2*l1*lc2*s2;
C = [-h*d2, -h*(d1+d2); h*d1, 0];

g1 = (m1*lc1 + m2*l1)*g0*cos(q1) + m2*lc2*g0*cos(q1+q2);
g2 = m2*lc2*g0*cos(q1+q2);
g = [g1; g2];
end

function T = kinetic(p, q, qd)
% Link kinetic energy from forward kinematics of both COMs. Independent of the
% closed-form M: it only uses positions and velocities.
q1 = q(1); q2 = q(2);
v1 = p.lc1 * [-sin(q1); cos(q1)] * qd(1);
v2 = p.l1 * [-sin(q1); cos(q1)] * qd(1) + ...
     p.lc2 * [-sin(q1+q2); cos(q1+q2)] * (qd(1)+qd(2));
T = 0.5*p.m1*(v1.'*v1) + 0.5*p.I1*qd(1)^2 + ...
    0.5*p.m2*(v2.'*v2) + 0.5*p.I2*(qd(1)+qd(2))^2;
end

function d = T_grad(p, q, qd)
h = 1e-6;
d = zeros(2,1);
for j = 1:2
    qp = q; qp(j) = qp(j) + h;
    qm = q; qm(j) = qm(j) - h;
    d(j) = (kinetic(p, qp, qd) - kinetic(p, qm, qd)) / (2*h);
end
end

function V = potential(p, q)
V = (p.m1*p.lc1 + p.m2*p.l1)*p.g*sin(q(1)) + p.m2*p.lc2*p.g*sin(q(1)+q(2));
end

function d = V_grad(p, q)
h = 1e-6;
d = zeros(2,1);
for j = 1:2
    qp = q; qp(j) = qp(j) + h;
    qm = q; qm(j) = qm(j) - h;
    d(j) = (potential(p, qp) - potential(p, qm)) / (2*h);
end
end

function [drift, E0, E1, n] = energy_drift(p, mf, q0, qd0)
% RK4 on [q; qd], zero torque, fixed step, model evaluated at every state.
Tend = 2.0; dt = 1e-3; n = round(Tend/dt);
y = [q0; qd0];
[E0, ~] = energy(p, mf, y(1:2), y(3:4));
for k = 1:n
    k1 = deriv(mf, y);
    k2 = deriv(mf, y + 0.5*dt*k1);
    k3 = deriv(mf, y + 0.5*dt*k2);
    k4 = deriv(mf, y + dt*k3);
    y = y + (dt/6)*(k1 + 2*k2 + 2*k3 + k4);
end
[E1, ~] = energy(p, mf, y(1:2), y(3:4));
drift = abs(E1 - E0) / max(abs(E0), 1);
end

function ydot = deriv(mf, y)
q = y(1:2); qd = y(3:4);
[Mq, Cq, gq] = mf(q, qd);
ydot = [qd; Mq \ (-Cq*qd - gq)];
end

function [E, Mq] = energy(p, mf, q, qd)
[Mq, ~, ~] = mf(q, qd);
E = 0.5*qd.'*Mq*qd + potential(p, q);
end

function p = dflt_params(p)
if ~isstruct(p), error('mas_dyn_check:params', 'params must be a struct'); end
need = {'m1','m2','l1','l2'};
for k = 1:numel(need)
    if ~isfield(p, need{k}), error('mas_dyn_check:missing', 'params.%s is required', need{k}); end
end
p = fill(p, 'lc1', p.l1/2); p = fill(p, 'lc2', p.l2/2);
p = fill(p, 'I1', p.m1*p.l1^2/12); p = fill(p, 'I2', p.m2*p.l2^2/12);
p = fill(p, 'g', 9.81);
if any([p.m1 p.m2 p.l1 p.l2 p.lc1 p.lc2] <= 0)
    error('mas_dyn_check:params', 'masses, lengths and COM distances must be positive');
end
if p.lc1 > p.l1 || p.lc2 > p.l2
    error('mas_dyn_check:params', 'COM distance cannot exceed its link length');
end
if p.I1 < 0 || p.I2 < 0
    error('mas_dyn_check:params', 'inertias must be non-negative');
end
end

function p = fill(p, name, v)
if ~isfield(p, name), p.(name) = v; end
end

function v = getf(s, name, dflt)
if isstruct(s) && isfield(s, name), v = s.(name); else, v = dflt; end
end

function s = vecstr(v)
s = ['[' sprintf('%.4g ', v(:).') ']'];
s = strrep(s, ' ]', ']');
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
