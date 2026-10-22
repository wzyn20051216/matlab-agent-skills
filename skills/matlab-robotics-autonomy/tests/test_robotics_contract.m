function res = test_robotics_contract(verbose)
%TEST_ROBOTICS_CONTRACT  Contract tests for the Phase 5.3 robotics tools.
%
%   res = test_robotics_contract()
%
% Every expected value is either a physical property recomputed here by a route
% different from the tool's (kinetic energy, potential gradient, hand rotation
% matrices, central differences, chi-square quantiles) or a property of the
% contract itself (a verdict, a status). No case asserts "the tool returned what
% the tool returned".
%
% Fixtures are computed once at the top; each case extracts one field, so a
% failure names the promise that broke rather than "the suite threw".

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
addpath(fullfile(repo, 'skills', 'matlab-robotics-autonomy', 'scripts'));

% =========================================================================
% QUATERNIONS
% =========================================================================
a = 0.6;
q = [cos(a/2); 0; 0; sin(a/2)];
q2 = qz(0.4);
qe = qz(pi/2);
ts = [0 0.25 0.5 0.75 1];
expq = zeros(4, numel(ts));
for k = 1:numel(ts), expq(:, k) = qz(a + ts(k)*(pi/2 - a)); end
Q1 = mas_quat_check(q, struct('matrix', Rz(a), 'angle', a, 'axis', [0;0;1], ...
    'rotvec', [0;0;a], 'compose', q2, ...
    'interp', struct('qEnd', qe, 't', ts, 'expected', expq)));
Q2 = mas_quat_check(2*q);
Q3 = mas_quat_check(q, struct('matrix', Rz(a + 0.1)));
Q4 = mas_quat_check(q, struct('angle', a + 0.1, 'axis', [1;0;0], ...
    'rotvec', [0;0;a + 0.1]));
Q5 = mas_quat_check(q, struct('interp', struct('qEnd', qe, 't', ts, ...
    'expected', [expq(:, 1:4), expq(:, 5)*0.9 + 0.1])));
Q6 = mas_quat_check([1;0;0;0], struct('axis', [1;0;0]));
Q7 = mas_quat_check(-q);
Q8 = mas_quat_check([0;1;0;0], struct('angle', pi, 'axis', [-1;0;0], ...
    'rotvec', [pi;0;0]));
Q10 = mas_quat_check(q, struct('compose', 2*q2));

% =========================================================================
% TRAJECTORIES
% =========================================================================
t = (0:0.01:1).';
Qc = [sin(pi*t), cos(pi*t)];
V = [pi*cos(pi*t), -pi*sin(pi*t)];
A = [-pi^2*sin(pi*t), -pi^2*cos(pi*t)];
wp = struct('t', {0, 0.5, 1}, 'q', {Qc(1,:), Qc(51,:), Qc(end,:)});
T1 = mas_traj_check(t, Qc, struct('waypoints', wp, 'vel', V, 'acc', A, ...
    'vMax', 4, 'aMax', 12, 'qMin', -2, 'qMax', 2));
T2 = mas_traj_check(t, Qc, struct('waypoints', wp, 'vel', V, 'acc', A, 'vMax', 2));
Qbad = Qc; Qbad(51, 1) = Qbad(51, 1) + 0.1;
T3 = mas_traj_check(t, Qbad, struct('waypoints', wp, 'vel', V, 'acc', A));
tb = t; tb(30) = tb(29);
T4 = mas_traj_check(tb, Qc, struct('vMax', 4));
T5 = mas_traj_check(t, Qc, struct('vel', 2*V, 'acc', A));
T6 = mas_traj_check(t, Qc, struct('vMax', 4, 'aMax', 12, 'qMin', -2, 'qMax', 2));
T7 = mas_traj_check(t, Qc, struct('qMin', 0.5));
tn = t.^2;
Qn = [sin(pi*tn), cos(pi*tn)];
Vn = [pi*cos(pi*tn), -pi*sin(pi*tn)];
T10 = mas_traj_check(tn, Qn, struct('vel', Vn));
t4 = (0:3).'/3;
Q4s = [sin(pi*t4), cos(pi*t4)];
V4s = [pi*cos(pi*t4), -pi*sin(pi*t4)];
T11 = mas_traj_check(t4, Q4s, struct('vel', V4s));
wpOut = struct('t', {1.5}, 'q', {Qc(end,:)});
T13 = mas_traj_check(t, Qc, struct('waypoints', wpOut, 'vel', V));

% =========================================================================
% DYNAMICS  (planar 2-link, hand-checkable)
% =========================================================================
p = struct('m1', 1.2, 'm2', 0.8, 'l1', 0.5, 'l2', 0.4);
pf = struct('m1', 1.2, 'm2', 0.8, 'l1', 0.5, 'l2', 0.4, ...
    'lc1', 0.25, 'lc2', 0.2, 'I1', 1.2*0.5^2/12, 'I2', 0.8*0.4^2/12, 'g', 9.81);
q0 = [0.4; -0.7]; qd0 = [0.3; -0.2];
D1 = mas_dyn_check(p, q0, qd0);
D2 = mas_dyn_check(p, q0, qd0, struct('M', D1.Mref + [0 0.1; 0.1 0]));
D3 = mas_dyn_check(p, q0, qd0, struct('C', -D1.Cref));
D4 = mas_dyn_check(p, q0, qd0, struct('g', -D1.gref));
Ms = D1.Mref; Ms(1, 2) = Ms(1, 2) + 1e-3;
D5 = mas_dyn_check(p, q0, qd0, struct('M', Ms));
D6 = mas_dyn_check(p, q0, qd0, struct('M', [1 2; 2 1]));
D7 = mas_dyn_check(p, q0, qd0, struct('M', D1.Mref, 'C', D1.Cref, 'g', D1.gref));
D10 = mas_dyn_check(p, q0, qd0, ...
    struct('model', @(qq, qqd) dyn_wrongC(pf, qq, qqd)));
D13 = mas_dyn_check(p, q0, qd0, ...
    struct('model', @(qq, qqd) dyn_model(pf, qq, qqd)));

% =========================================================================
% STATE ESTIMATION  (100 independent Kalman-filter runs)
% =========================================================================
[truth, est, P, nu] = kf_data(20261021, 50, 100);
E1 = mas_estimate_check(truth, est, P);
E2 = mas_estimate_check(truth, est, P/100);
E3 = mas_estimate_check(truth, est, P*100);
Pnp = P; Pnp(:, :, 20, 1) = [1 2; 2 1];
E4 = mas_estimate_check(truth, est, Pnp);
Pas = P; Pas(1, 2, 20, 1) = Pas(1, 2, 20, 1) + 0.01;
E5 = mas_estimate_check(truth, est, Pas);
E6 = mas_estimate_check(truth, est + 0.5, P, struct('maxBias', 0.1));
E7 = mas_estimate_check(truth(:, :, 1:5), est(:, :, 1:5), P(:, :, :, 1:5));
E8 = mas_estimate_check(truth, est, P, struct('burnIn', 46));
rng(7);
nw = zeros(50, 1, 100);
for rr = 1:100
    nw(1, 1, rr) = randn;
    for k = 2:50, nw(k, 1, rr) = 0.8*nw(k-1, 1, rr) + randn; end
end
E9 = mas_estimate_check(truth, est, P, struct('innovation', nw, 'S', 1));
rng(8);
ww = randn(50, 1, 100);
E10 = mas_estimate_check(truth, est, P, struct('innovation', ww, 'S', 1));
E11 = mas_estimate_check(truth, est, P, struct('innovation', nu));
E12 = mas_estimate_check(truth, est, P, struct('innovation', ww, 'S', -1));
E20 = mas_estimate_check(truth(:, :, 1:19), est(:, :, 1:19), P(:, :, :, 1:19));

% Independent NEES arithmetic at one step and the overall bias.
s25 = 0;
for rr = 1:100
    e = truth(25, :, rr).' - est(25, :, rr).';
    s25 = s25 + e.'*(P(:, :, 25, rr)\e);
end
anees25 = s25/100;
eb = truth - est;
biasLocal = squeeze(mean(mean(eb, 1), 3));
bandLocal = chi2band(100*50, 2, 0.01);
stepBandLocal = chi2band(100, 2, 0.01);
whitenessThr = sqrt(2)*erfcinv(0.05/10)/sqrt(1*100*(50 - 10));

% =========================================================================
% CASES
% =========================================================================
T = struct('name', {}, 'fn', {}, 'expect', {});

% --- quaternions ---------------------------------------------------------
T(end+1) = tc('quat: full claim set PASS', @() Q1.verdict, 'PASS');
T(end+1) = tc('quat: R matches hand rotation', ...
    @() max(max(abs(Q1.R - Rz(a)))) < 1e-15, true);
T(end+1) = tc('quat: angle matches', @() near(Q1.angle, a, 1e-12), true);
T(end+1) = tc('quat: axis matches', @() max(abs(Q1.axis - [0;0;1])) < 1e-15, true);
T(end+1) = tc('quat: rotvec matches', @() max(abs(Q1.rotvec - [0;0;a])) < 1e-15, true);
T(end+1) = tc('quat: inverse below 1e-15', @() Q1.inverseErr < 1e-15, true);
T(end+1) = tc('quat: compose equals qz(a+0.4)', ...
    @() qdist(Q1.compose, qz(a + 0.4)) < 1e-14, true);
T(end+1) = tc('quat: compose matrix route', @() st(Q1, 'composeVsMatrix'), 'pass');
T(end+1) = tc('quat: slerp midpoint is qz(mid)', ...
    @() qdist(Q1.slerp(:, 3), qz((a + pi/2)/2)) < 1e-12, true);
T(end+1) = tc('quat: slerp geodesic', @() st(Q1, 'slerpGeodesic'), 'pass');
T(end+1) = tc('quat: slerp matches closed form', @() st(Q1, 'slerpVsClaim'), 'pass');
T(end+1) = tc('quat: toolbox checks not failed', ...
    @() all(~strcmp({Q1.checks(ismember({Q1.checks.id}, ...
    {'composeVsToolbox', 'matrixVsToolbox', 'roundTripVsToolbox'})).status}, 'fail')), true);
T(end+1) = tc('quat: non-unit FAIL', @() Q2.verdict, 'FAIL');
T(end+1) = tc('quat: non-unit caught', @() st(Q2, 'unitNorm'), 'fail');
T(end+1) = tc('quat: non-unit still derives right R', ...
    @() max(max(abs(Q2.R - Rz(a)))) < 1e-15, true);
T(end+1) = tc('quat: wrong matrix FAIL', @() Q3.verdict, 'FAIL');
T(end+1) = tc('quat: wrong matrix caught', @() st(Q3, 'matrixVsClaim'), 'fail');
T(end+1) = tc('quat: only the matrix fails', @() Q3.nFail == 1, true);
T(end+1) = tc('quat: wrong angle/axis/rotvec FAIL', @() Q4.verdict, 'FAIL');
T(end+1) = tc('quat: angle caught', @() st(Q4, 'angleVsClaim'), 'fail');
T(end+1) = tc('quat: axis caught', @() st(Q4, 'axisVsClaim'), 'fail');
T(end+1) = tc('quat: rotvec caught', @() st(Q4, 'rotvecVsClaim'), 'fail');
T(end+1) = tc('quat: bent slerp FAIL', @() Q5.verdict, 'FAIL');
T(end+1) = tc('quat: bent slerp caught', @() st(Q5, 'slerpVsClaim'), 'fail');
T(end+1) = tc('quat: slerp endpoints still pass', @() st(Q5, 'slerpEndpoints'), 'pass');
T(end+1) = tc('quat: identity axis UNDETERMINED', @() Q6.verdict, 'UNDETERMINED');
T(end+1) = tc('quat: undefined axis not graded', @() st(Q6, 'axisVsClaim'), 'undetermined');
T(end+1) = tc('quat: -q is the same rotation', @() Q7.verdict, 'PASS');
T(end+1) = tc('quat: -q same R', ...
    @() max(max(abs(Q7.R - Rz(a)))) < 1e-15, true);
T(end+1) = tc('quat: 180 deg axis sign accepted', @() Q8.verdict, 'PASS');
T(end+1) = tc('quat: 180 deg angle', @() near(Q8.angle, pi, 1e-12), true);
T(end+1) = tc('quat: zero rejected', ...
    @() err_of(@() mas_quat_check([0;0;0;0])), 'ERR');
T(end+1) = tc('quat: 3 elements rejected', ...
    @() err_of(@() mas_quat_check([1;0;0])), 'ERR');
T(end+1) = tc('quat: non-unit compose FAIL', @() Q10.verdict, 'FAIL');
T(end+1) = tc('quat: compose norm caught', @() st(Q10, 'composeUnitNorm'), 'fail');
T(end+1) = tc('quat: normalised compose still right', ...
    @() st(Q10, 'composeVsMatrix'), 'pass');
T(end+1) = tc('quat: zero compose rejected', ...
    @() err_of(@() mas_quat_check(q, struct('compose', [0;0;0;0]))), 'ERR');
T(end+1) = tc('quat: interp outside [0,1] rejected', ...
    @() err_of(@() mas_quat_check(q, struct('interp', ...
    struct('qEnd', qe, 't', [-0.1 0.5])))), 'ERR');

% --- trajectories --------------------------------------------------------
T(end+1) = tc('traj: certified trajectory PASS', @() T1.verdict, 'PASS');
T(end+1) = tc('traj: all 8 checks pass', @() T1.nPass == 8 && T1.nChecks == 8, true);
T(end+1) = tc('traj: waypoints hit', @() T1.waypointErr < 1e-12, true);
T(end+1) = tc('traj: velocity peak is pi', ...
    @() max(abs(T1.vMax - pi)) < 1e-9, true);
T(end+1) = tc('traj: acceleration peak is pi^2', ...
    @() max(abs(T1.aMax - pi^2)) < 1e-8, true);
T(end+1) = tc('traj: analytic velocity consistent', @() T1.derivErrV < 1e-6, true);
T(end+1) = tc('traj: analytic acceleration consistent', @() T1.derivErrA < 1e-6, true);
T(end+1) = tc('traj: certified flag set', @() T1.certified, true);
T(end+1) = tc('traj: velocity limit FAIL', @() T2.verdict, 'FAIL');
T(end+1) = tc('traj: velocity limit caught', @() st(T2, 'velocityLimit'), 'fail');
T(end+1) = tc('traj: missed waypoint FAIL', @() T3.verdict, 'FAIL');
T(end+1) = tc('traj: waypoint error is 0.1', @() near(T3.waypointErr, 0.1, 1e-12), true);
T(end+1) = tc('traj: missed waypoint caught', @() st(T3, 'waypointsHit'), 'fail');
T(end+1) = tc('traj: backwards time FAIL', @() T4.verdict, 'FAIL');
T(end+1) = tc('traj: backwards time caught', @() st(T4, 'timeMonotonic'), 'fail');
T(end+1) = tc('traj: early return leaves peaks unset', @() isnan(T4.vMax), true);
T(end+1) = tc('traj: doubled velocity FAIL', @() T5.verdict, 'FAIL');
T(end+1) = tc('traj: doubled velocity caught', @() st(T5, 'velocityDerivativeAgrees'), 'fail');
T(end+1) = tc('traj: doubled velocity deviation ~0.5', ...
    @() near(T5.derivErrV, 0.5, 1e-3), true);
T(end+1) = tc('traj: acceleration still agrees', ...
    @() st(T5, 'accelerationDerivativeAgrees'), 'pass');
T(end+1) = tc('traj: sampled-only limits PASS', @() T6.verdict, 'PASS');
T(end+1) = tc('traj: sampled-only not certified', @() T6.certified, false);
T(end+1) = tc('traj: sampled peak below limit', @() all(T6.vMax < 4), true);
T(end+1) = tc('traj: position limit FAIL', @() T7.verdict, 'FAIL');
T(end+1) = tc('traj: position limit caught', @() st(T7, 'positionMin'), 'fail');
T(end+1) = tc('traj: no claims rejected', ...
    @() err_of(@() mas_traj_check(t, Qc, struct())), 'ERR');
T(end+1) = tc('traj: one sample rejected', ...
    @() err_of(@() mas_traj_check(t(1), Qc(1, :), struct('vMax', 1))), 'ERR');
T(end+1) = tc('traj: non-uniform sampling UNDETERMINED', @() T10.verdict, 'UNDETERMINED');
T(end+1) = tc('traj: no derivative route on non-uniform t', ...
    @() st(T10, 'velocityDerivativeAgrees'), 'undetermined');
T(end+1) = tc('traj: too few samples UNDETERMINED', @() T11.verdict, 'UNDETERMINED');
T(end+1) = tc('traj: five-point stencil needs 5 samples', ...
    @() st(T11, 'velocityDerivativeAgrees'), 'undetermined');
T(end+1) = tc('traj: wrong vel shape rejected', ...
    @() err_of(@() mas_traj_check(t, Qc, struct('vel', V(1:end-1, :)))), 'ERR');
T(end+1) = tc('traj: waypoint outside time FAIL', @() T13.verdict, 'FAIL');
T(end+1) = tc('traj: waypoint outside time caught', @() st(T13, 'waypointsHit'), 'fail');

% --- dynamics ------------------------------------------------------------
T(end+1) = tc('dyn: reference model PASS', @() D1.verdict, 'PASS');
T(end+1) = tc('dyn: 7 checks pass', @() D1.nPass == 7 && D1.nChecks == 7, true);
T(end+1) = tc('dyn: M matches kinetic-energy route', ...
    @() max(max(abs(D1.Mref - M_kin(pf, q0)))) < 1e-14, true);
T(end+1) = tc('dyn: C matches hand formula', ...
    @() max(max(abs(D1.Cref - C_hand(pf, q0, qd0)))) < 1e-14, true);
T(end+1) = tc('dyn: g matches potential gradient', ...
    @() max(abs(D1.gref - gradV(pf, q0))) < 1e-8, true);
T(end+1) = tc('dyn: skew error below threshold', @() D1.skewErr < 1e-8, true);
T(end+1) = tc('dyn: Lagrange identity at roundoff', @() D1.coriolisErr < 1e-9, true);
T(end+1) = tc('dyn: gravity gradient at roundoff', @() D1.gravityErr < 1e-8, true);
T(end+1) = tc('dyn: energy drift below 1e-9', @() D1.energyDrift < 1e-9, true);
T(end+1) = tc('dyn: E0 matches hand energy', ...
    @() near(D1.E0, 0.5*qd0.'*M_kin(pf, q0)*qd0 + V_hand(pf, q0), 1e-12), true);
T(end+1) = tc('dyn: reference energy source', @() D1.energySource, 'reference model');
T(end+1) = tc('dyn: wrong M FAIL', @() D2.verdict, 'FAIL');
T(end+1) = tc('dyn: claimed M vs reference caught', @() st(D2, 'massVsReference'), 'fail');
T(end+1) = tc('dyn: claimed M vs energy route caught', ...
    @() st(D2, 'massVsEnergyRoute'), 'fail');
T(end+1) = tc('dyn: flipped C FAIL', @() D3.verdict, 'FAIL');
T(end+1) = tc('dyn: flipped C breaks passivity', @() st(D3, 'coriolisSkew'), 'fail');
T(end+1) = tc('dyn: flipped C breaks Lagrange identity', ...
    @() st(D3, 'coriolisIdentity'), 'fail');
T(end+1) = tc('dyn: flipped g FAIL', @() D4.verdict, 'FAIL');
T(end+1) = tc('dyn: flipped g caught', @() st(D4, 'gravityGradient'), 'fail');
T(end+1) = tc('dyn: asymmetric M FAIL', @() D5.verdict, 'FAIL');
T(end+1) = tc('dyn: asymmetry caught', @() st(D5, 'massSymmetry'), 'fail');
T(end+1) = tc('dyn: non-PD M FAIL', @() D6.verdict, 'FAIL');
T(end+1) = tc('dyn: negative eigenvalue caught', @() st(D6, 'massPositiveDefinite'), 'fail');
T(end+1) = tc('dyn: exact claims PASS', @() D7.verdict, 'PASS');
T(end+1) = tc('dyn: 10 checks with full claims', @() D7.nPass == 10 && D7.nChecks == 10, true);
T(end+1) = tc('dyn: all claims recognised', ...
    @() D7.claimed.M && D7.claimed.C && D7.claimed.g, true);
T(end+1) = tc('dyn: wrong model leaks energy FAIL', @() D10.verdict, 'FAIL');
T(end+1) = tc('dyn: energy check catches wrong model', ...
    @() st(D10, 'energyConservation'), 'fail');
T(end+1) = tc('dyn: wrong-model drift is large', @() D10.energyDrift > 1e-2, true);
T(end+1) = tc('dyn: claimed model used for energy', @() D10.energySource, 'claimed model');
T(end+1) = tc('dyn: correct claimed model PASS', @() D13.verdict, 'PASS');
T(end+1) = tc('dyn: correct claimed model source', @() D13.energySource, 'claimed model');
T(end+1) = tc('dyn: bad model handle rejected', ...
    @() err_of(@() mas_dyn_check(p, q0, qd0, struct('model', 3))), 'ERR');
T(end+1) = tc('dyn: missing l2 rejected', ...
    @() err_of(@() mas_dyn_check(struct('m1', 1, 'm2', 1, 'l1', 1), q0, qd0)), 'ERR');
T(end+1) = tc('dyn: negative mass rejected', ...
    @() err_of(@() mas_dyn_check(struct('m1', -1, 'm2', 1, 'l1', 1, 'l2', 1), ...
    q0, qd0)), 'ERR');
T(end+1) = tc('dyn: COM beyond link rejected', ...
    @() err_of(@() mas_dyn_check(struct('m1', 1, 'm2', 1, 'l1', 0.5, 'l2', 0.4, ...
    'lc1', 0.6), q0, qd0)), 'ERR');
T(end+1) = tc('dyn: 1x2 mass matrix rejected', ...
    @() err_of(@() mas_dyn_check(p, q0, qd0, struct('M', [1 2]))), 'ERR');

% --- state estimation ----------------------------------------------------
T(end+1) = tc('est: consistent filter PASS', @() E1.verdict, 'PASS');
T(end+1) = tc('est: four checks pass', @() E1.nPass == 4 && E1.nChecks == 4, true);
T(end+1) = tc('est: ANEES near n=2', @() abs(E1.aneesMean - 2) < 0.1, true);
T(end+1) = tc('est: band matches chi-square', ...
    @() max(abs(E1.aneesBand - bandLocal)) < 1e-12, true);
T(end+1) = tc('est: step band matches chi-square', ...
    @() max(abs(E1.aneesStepBand - stepBandLocal)) < 1e-12, true);
T(end+1) = tc('est: step-25 ANEES matches hand loop', ...
    @() near(E1.aneesPerStep(25), anees25, 1e-12), true);
T(end+1) = tc('est: samples counted', @() E1.neesSamples == 5000, true);
T(end+1) = tc('est: in-band coverage', @() E1.inBandFrac >= 0.95, true);
T(end+1) = tc('est: bias matches hand mean', ...
    @() max(abs(E1.bias - biasLocal)) < 1e-12 && ...
    near(E1.biasNorm, norm(biasLocal), 1e-12), true);
T(end+1) = tc('est: half means reported', ...
    @() numel(E1.halfMeans) == 2 && all(isfinite(E1.halfMeans)), true);
T(end+1) = tc('est: no whiteness metric without innovations', ...
    @() isnan(E1.maxAutocorr), true);
T(end+1) = tc('est: over-confident FAIL', @() E2.verdict, 'FAIL');
T(end+1) = tc('est: over-confidence caught', @() st(E2, 'nees'), 'fail');
T(end+1) = tc('est: ANEES above band', @() E2.aneesMean > E2.aneesBand(2), true);
T(end+1) = tc('est: under-confident FAIL', @() E3.verdict, 'FAIL');
T(end+1) = tc('est: under-confidence caught', @() st(E3, 'nees'), 'fail');
T(end+1) = tc('est: ANEES below band', @() E3.aneesMean < E3.aneesBand(1), true);
T(end+1) = tc('est: non-PD covariance FAIL', @() E4.verdict, 'FAIL');
T(end+1) = tc('est: non-PD caught', @() st(E4, 'covPositiveDefinite'), 'fail');
T(end+1) = tc('est: negative eigenvalue reported', @() near(E4.minEigP, -1, 1e-12), true);
T(end+1) = tc('est: asymmetric covariance FAIL', @() E5.verdict, 'FAIL');
T(end+1) = tc('est: asymmetry caught', @() st(E5, 'covSymmetry'), 'fail');
T(end+1) = tc('est: asymmetry magnitude', @() E5.covSymErr > 1e-4, true);
T(end+1) = tc('est: biased estimate FAIL', @() E6.verdict, 'FAIL');
T(end+1) = tc('est: bias caught', @() st(E6, 'bias'), 'fail');
T(end+1) = tc('est: bias norm matches shifted mean', ...
    @() near(E6.biasNorm, norm(biasLocal - 0.5), 1e-10), true);
T(end+1) = tc('est: NEES also rejects a constant offset', @() st(E6, 'nees'), 'fail');
T(end+1) = tc('est: five runs UNDETERMINED', @() E7.verdict, 'UNDETERMINED');
T(end+1) = tc('est: run gate caught', @() st(E7, 'nees'), 'undetermined');
T(end+1) = tc('est: ANEES still reported', @() isfinite(E7.aneesMean), true);
T(end+1) = tc('est: four kept steps UNDETERMINED', @() E8.verdict, 'UNDETERMINED');
T(end+1) = tc('est: step gate caught', @() st(E8, 'nees'), 'undetermined');
T(end+1) = tc('est: burn-in changes the sample count', @() E8.neesSamples == 400, true);
T(end+1) = tc('est: correlated innovations FAIL', @() E9.verdict, 'FAIL');
T(end+1) = tc('est: whiteness caught', @() st(E9, 'whiteness'), 'fail');
T(end+1) = tc('est: white innovations PASS', @() E10.verdict, 'PASS');
T(end+1) = tc('est: whiteness passes', @() st(E10, 'whiteness'), 'pass');
T(end+1) = tc('est: max autocorrelation below threshold', ...
    @() E10.maxAutocorr <= E10.whitenessThreshold, true);
T(end+1) = tc('est: family-wise threshold', ...
    @() near(E10.whitenessThreshold, whitenessThr, 1e-12), true);
T(end+1) = tc('est: correlated signal is far above white', ...
    @() E9.maxAutocorr > 10*E10.maxAutocorr, true);
T(end+1) = tc('est: innovations without S UNDETERMINED', @() E11.verdict, 'UNDETERMINED');
T(end+1) = tc('est: missing S caught', @() st(E11, 'whiteness'), 'undetermined');
T(end+1) = tc('est: non-PD S UNDETERMINED', @() E12.verdict, 'UNDETERMINED');
T(end+1) = tc('est: non-PD S caught', @() st(E12, 'whiteness'), 'undetermined');
T(end+1) = tc('est: wrong innovation length rejected', ...
    @() err_of(@() mas_estimate_check(truth, est, P, ...
    struct('innovation', nw(1:49, :, :), 'S', 1))), 'ERR');
T(end+1) = tc('est: negative burn-in rejected', ...
    @() err_of(@() mas_estimate_check(truth, est, P, struct('burnIn', -1))), 'ERR');
T(end+1) = tc('est: burn-in at N rejected', ...
    @() err_of(@() mas_estimate_check(truth, est, P, struct('burnIn', 50))), 'ERR');
T(end+1) = tc('est: est size mismatch rejected', ...
    @() err_of(@() mas_estimate_check(truth, est(1:end-1, :, :), P)), 'ERR');
T(end+1) = tc('est: empty covariance rejected', ...
    @() err_of(@() mas_estimate_check(truth, est, [])), 'ERR');
T(end+1) = tc('est: 3-D P with many runs rejected', ...
    @() err_of(@() mas_estimate_check(truth, est, P(:, :, :, 1))), 'ERR');
T(end+1) = tc('est: 4-D truth rejected', ...
    @() err_of(@() mas_estimate_check(repmat(truth, [1 1 1 2]), est, P)), 'ERR');
T(end+1) = tc('est: 19 runs still UNDETERMINED', @() E20.verdict, 'UNDETERMINED');
T(end+1) = tc('est: run gate boundary caught', @() st(E20, 'nees'), 'undetermined');

% =========================================================================
nP = 0;
if verbose, fprintf('=== robotics contract tests ===\n'); end
R = struct('case', {}, 'got', {}, 'pass', {});
for k = 1:numel(T)
    t = T(k);
    try
        got = t.fn();
    catch
        got = 'ERR';
    end
    if ischar(t.expect)
        ok = strcmp(char(string(got)), t.expect);
    else
        ok = isequal(got, t.expect);
    end
    nP = nP + ok;
    if verbose
        fprintf('  [%s] %-46s -> %s\n', tern(ok, 'PASS', 'FAIL'), t.name, ...
            char(string(got)));
    end
    R(end+1) = struct('case', t.name, 'got', char(string(got)), 'pass', ok); %#ok<AGROW>
end
res = struct('nPass', nP, 'nTotal', numel(T), 'cases', R, 'pass', nP == numel(T));
if verbose
    fprintf('\n---- %d / %d robotics-contract cases passed ----\n', nP, numel(T));
end
end

% ===========================================================================
% Independent references
% ===========================================================================
function R = Rz(a)
R = [cos(a) -sin(a) 0; sin(a) cos(a) 0; 0 0 1];
end

function q = qz(a)
q = [cos(a/2); 0; 0; sin(a/2)];
end

function d = qdist(a, b)
a = a/norm(a); b = b/norm(b);
d = min(norm(a - b), norm(a + b));
end

function M = M_kin(p, q)
q1 = q(1); q2 = q(2);
J1 = p.lc1*[-sin(q1), 0; cos(q1), 0];
J2 = [-p.l1*sin(q1) - p.lc2*sin(q1+q2), -p.lc2*sin(q1+q2); ...
       p.l1*cos(q1) + p.lc2*cos(q1+q2),  p.lc2*cos(q1+q2)];
M = p.m1*(J1.'*J1) + p.I1*[1 0; 0 0] + ...
    p.m2*(J2.'*J2) + p.I2*[1 1; 1 1];
end

function C = C_hand(p, q, qd)
h = p.m2*p.l1*p.lc2*sin(q(2));
C = [-h*qd(2), -h*(qd(1)+qd(2)); h*qd(1), 0];
end

function V = V_hand(p, q)
V = (p.m1*p.lc1 + p.m2*p.l1)*p.g*sin(q(1)) + ...
    p.m2*p.lc2*p.g*sin(q(1)+q(2));
end

function d = gradV(p, q)
h = 1e-6;
d = zeros(2, 1);
for j = 1:2
    qp = q; qp(j) = qp(j) + h;
    qm = q; qm(j) = qm(j) - h;
    d(j) = (V_hand(p, qp) - V_hand(p, qm))/(2*h);
end
end

function [M, C, g] = dyn_wrongC(p, q, qd)
c2 = cos(q(2)); s2 = sin(q(2));
M11 = p.I1 + p.I2 + p.m1*p.lc1^2 + p.m2*(p.l1^2 + p.lc2^2 + 2*p.l1*p.lc2*c2);
M12 = p.I2 + p.m2*(p.lc2^2 + p.l1*p.lc2*c2);
M = [M11 M12; M12 p.I2 + p.m2*p.lc2^2];
h = p.m2*p.l1*p.lc2*s2;
C = [h*qd(2), h*(qd(1)+qd(2)); -h*qd(1), 0];
g = [(p.m1*p.lc1 + p.m2*p.l1)*p.g*cos(q(1)) + p.m2*p.lc2*p.g*cos(q(1)+q(2)); ...
     p.m2*p.lc2*p.g*cos(q(1)+q(2))];
end

function [M, C, g] = dyn_model(p, q, qd)
c2 = cos(q(2)); s2 = sin(q(2));
M11 = p.I1 + p.I2 + p.m1*p.lc1^2 + p.m2*(p.l1^2 + p.lc2^2 + 2*p.l1*p.lc2*c2);
M12 = p.I2 + p.m2*(p.lc2^2 + p.l1*p.lc2*c2);
M = [M11 M12; M12 p.I2 + p.m2*p.lc2^2];
h = p.m2*p.l1*p.lc2*s2;
C = [-h*qd(2), -h*(qd(1)+qd(2)); h*qd(1), 0];
g = [(p.m1*p.lc1 + p.m2*p.l1)*p.g*cos(q(1)) + p.m2*p.lc2*p.g*cos(q(1)+q(2)); ...
     p.m2*p.lc2*p.g*cos(q(1)+q(2))];
end

function b = chi2band(nTot, n, alpha)
nu = nTot*n;
b = [2*gammaincinv(alpha/2, nu/2)/nTot, ...
     2*gammaincinv(1 - alpha/2, nu/2)/nTot];
end

function [truth, est, P, nu] = kf_data(seed, N, R)
dt = 0.1; Q = 0.05*[dt^3/3 dt^2/2; dt^2/2 dt]; Rm = 0.4;
A = [1 dt; 0 1]; H = [1 0];
truth = zeros(N, 2, R); est = zeros(N, 2, R); P = zeros(2, 2, N, R);
nu = zeros(N, 1, R);
rng(seed);
for rr = 1:R
    x = [1; -0.5] + chol([1 0; 0 1]).'*randn(2, 1);
    xh = [1; -0.5]; Pk = eye(2);
    for k = 1:N
        x = A*x + chol(Q).'*randn(2, 1);
        xh = A*xh; Pk = A*Pk*A.' + Q;
        z = H*x + sqrt(Rm)*randn;
        innov = z - H*xh; Sk = H*Pk*H.' + Rm;
        K = Pk*H.'/Sk; xh = xh + K*innov; Pk = (eye(2) - K*H)*Pk;
        truth(k, :, rr) = x.'; est(k, :, rr) = xh.'; P(:, :, k, rr) = Pk;
        nu(k, 1, rr) = innov;
    end
end
end

% ===========================================================================
% Harness
% ===========================================================================
function v = st(r, id)
v = 'MISSING';
for k = 1:numel(r.checks)
    if strcmp(r.checks(k).id, id)
        v = r.checks(k).status;
        return
    end
end
end

function v = near(a, b, tol)
v = max(abs(double(a(:)) - double(b(:)))) <= tol;
end

function s = err_of(fn)
try
    fn();
    s = 'NO_ERROR';
catch
    s = 'ERR';
end
end

function t = tc(name, fn, expect)
t = struct('name', name, 'fn', fn, 'expect', expect);
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
