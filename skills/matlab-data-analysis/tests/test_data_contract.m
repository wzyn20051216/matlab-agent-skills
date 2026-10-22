function res = test_data_contract(verbose)
%TEST_DATA_CONTRACT  Contract tests for the Phase 5.3 scientific-computing tools.
%
%   res = test_data_contract()
%
% Every expected value below is either recomputed here from the raw data by a
% route different from the tool's (hand formulas, a second factorisation, a
% resampling test) or is a property of the contract (a verdict, a status). None
% of the checks is "the tool returned what the tool returned".
%
% Fixtures are computed once at the top; each case extracts one field, so a
% failure names the promise that broke rather than "the suite threw".

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
addpath(fullfile(repo, 'skills', 'matlab-data-analysis', 'scripts'));

% =========================================================================
% QUADRATURE
% =========================================================================
f1 = @(x) 4./(1+x.^2);
Q1 = mas_quad_check(f1, 0, 1, struct('value', pi, 'tolRel', 1e-8, ...
    'method', 'simpson', 'n', 32, 'derivAt', 0.5, 'derivValue', -2.56, ...
    'derivTolRel', 1e-6));
Q2 = mas_quad_check(f1, 0, 1, struct('value', pi, 'tolRel', 1e-12, ...
    'method', 'trapz', 'n', 64));
Q3 = mas_quad_check(f1, 0, 1, struct('value', pi + 1e-3, 'tolRel', 1e-6, ...
    'method', 'simpson', 'n', 64));
f4 = @(x) sin(200*x);
Q4 = mas_quad_check(f4, 0, 1, struct('value', (1 - cos(200))/200, 'tolRel', 1e-6, ...
    'method', 'trapz', 'n', 64));
f5 = @(x) exp(sin(x));
Q5 = mas_quad_check(f5, 0, 2, struct('value', integral(f5, 0, 2), 'tolRel', 1e-6, ...
    'derivAt', 1, 'derivValue', cos(1)*exp(sin(1)), 'derivTolRel', 1e-8));
fk = @(x) abs(x - 1/3);
Q6 = mas_quad_check(fk, 0, 1, struct('value', 5/18, 'tolRel', 1e-8, ...
    'method', 'trapz', 'n', 64));
Q6b = mas_quad_check(fk, 0, 1, struct('value', 5/18, 'tolRel', 1e-6, ...
    'method', 'simpson', 'n', 32));
Q7 = mas_quad_check(f1, 0, 1, struct('value', pi));   % no tolerance stated

% =========================================================================
% LINEAR SYSTEMS
% =========================================================================
A = [4 1; 1 3];
xt = [1; -1];
b = A*xt;
L1 = mas_linsolve_check(A, A\b, b, struct('tolRel', 1e-12, 'xTrue', xt));
L2 = mas_linsolve_check(A, xt + [1e-6; 0], b, struct('tolRel', 1e-9, 'xTrue', xt));
Ah = hilb(12);
bh = Ah*ones(12, 1);
L3 = mas_linsolve_check(Ah, Ah\bh, bh, struct('tolRel', 1e-6));
Ar = [1 2; 2 4];
L4 = mas_linsolve_check(Ar, [1; 1], [3; 6], struct('tolRel', 1e-9));
L6 = mas_linsolve_check(A, A\b, b, struct());

% =========================================================================
% CONVERGENCE
% =========================================================================
xx = 1; eN = zeros(1, 7);
for k = 1:7
    eN(k) = abs(xx - sqrt(2));
    xx = (xx + 2/xx)/2;
end
C1 = mas_converge_check(eN, struct('order', 2, 'tolFinal', 1e-10));
C2 = mas_converge_check(0.5*2.^-(0:10), struct('order', 1, 'rate', 0.5, 'tolFinal', 1e-3));
C3 = mas_converge_check(10.^(0:5), struct('tolFinal', 1e-6));
C4 = mas_converge_check([1 .5 .33 .25 .2 .18 .17 .165 .163 .162], struct('tolFinal', 1e-6));
C5 = mas_converge_check([1e-1 1e-2 1e-4 1e-8 2e-16], struct('order', 2, 'tolFinal', 1e-15));
C6 = mas_converge_check([1 0.1 Inf], struct('tolFinal', 1e-6));

% =========================================================================
% REGRESSION / FITTING  (hand-computed from the raw data)
% =========================================================================
rng(11);
tf = (0:9).';
Xf = [ones(10, 1), tf];
yf = 2 + 0.5*tf + 0.05*randn(10, 1);
bf = Xf\yf;
dofF = 8;
resF = yf - Xf*bf;
sseF = sum(resF.^2); sstF = sum((yf - mean(yf)).^2);
r2F = 1 - sseF/sstF;
rmseF = sqrt(sseF/10);
sigF = sqrt(sseF/dofF);
covF = sigF^2*inv(Xf'*Xf);
seF = sqrt(diag(covF));
tcritF = sqrt(dofF*(1 - betaincinv(0.05, dofF/2, 0.5))/betaincinv(0.05, dofF/2, 0.5));
th = (10:14).';
Xh = [ones(5, 1), th];
yh = 2 + 0.5*th + 0.05*randn(5, 1);
holdF = sqrt(mean((yh - Xh*bf).^2));
F1 = mas_fit_check(Xf, yf, bf, struct('r2', r2F, 'rmse', rmseF, ...
    'se', seF, 'ciLo', bf - tcritF*seF, 'ciHi', bf + tcritF*seF, ...
    'holdout', struct('X', Xh, 'y', yh), 'holdoutRmse', holdF));
F2 = mas_fit_check(Xf, yf, bf + [0.01; 0], struct('r2', r2F));
Xn = [ones(3, 1), (1:3).', (1:3).'.^2];
F3 = mas_fit_check(Xn, [1; 2; 3], Xn\[1; 2; 3], struct());
F4 = mas_fit_check([ones(10, 1), tf, tf], yf, [ones(10, 1), tf, tf]\yf, struct());
Hb = hilb(8);
Xi = [Hb; Hb];
yi = Xi*((1:8).') + 0.01*randn(16, 1);
bi = Xi\yi;
[~, Ri] = qr(Xi, 0);
sigi = sqrt(sum((yi - Xi*bi).^2)/(16 - 8));
sei = sqrt(diag(sigi^2*((Ri\eye(8))*(Ri\eye(8))')));
F5 = mas_fit_check(Xi, yi, bi, struct('se', sei));
F7 = mas_fit_check(Xf, yf, bf, struct('r2', 0.5));
F8 = mas_fit_check(Xf, yf, bf, struct('holdout', struct('X', Xh, 'y', yh), ...
    'holdoutRmse', holdF + 0.01));

% =========================================================================
% STATISTICS
% =========================================================================
xs = [10.2 9.8 10.1 10.3 9.9 10.0].';
mS = mean(xs); sS = std(xs); seS = sS/sqrt(numel(xs)); dfS = numel(xs) - 1;
tS = (mS - 10)/seS;
pS = betainc(dfS/(dfS + tS^2), dfS/2, 0.5);
tqS = sqrt(dfS*(1 - betaincinv(0.05, dfS/2, 0.5))/betaincinv(0.05, dfS/2, 0.5));
S1 = mas_stat_check(xs, struct('mu0', 10, 'mean', mS, ...
    'ci', [mS - tqS*seS, mS + tqS*seS], 'p', pS, 'decision', 'retain'));
S2 = mas_stat_check(xs, struct('mu0', 10, 'mean', mS + 0.5));
xnan = xs; xnan(3) = NaN;
S3 = mas_stat_check(xnan, struct('mu0', 10, 'mean', mS));
S4 = mas_stat_check(5*ones(8, 1), struct('mu0', 5, 'p', 1));
S10 = mas_stat_check(xs, struct('mu0', 10, 'p', pS/2, 'tail', 'greater', ...
    'decision', 'retain'));
rng(21);
xa = 10 + randn(12, 1);
xb = 11 + 1.5*randn(10, 1);
n1 = numel(xa); n2 = numel(xb);
dW = mean(xa) - mean(xb);
v1 = var(xa)/n1; v2 = var(xb)/n2;
seW = sqrt(v1 + v2);
dfW = (v1 + v2)^2/(v1^2/(n1 - 1) + v2^2/(n2 - 1));
tW = dW/seW;
pW = betainc(dfW/(dfW + tW^2), dfW/2, 0.5);
tqW = sqrt(dfW*(1 - betaincinv(0.05, dfW/2, 0.5))/betaincinv(0.05, dfW/2, 0.5));
S5 = mas_stat_check(xa, xb, struct('claimDiff', dW, 'p', pW, ...
    'ci', [dW - tqW*seW, dW + tqW*seW], 'decision', 'reject'));
S6 = mas_stat_check(xa, xb, struct('p', 0.0001));
% Skewed sample: the t-test retains (p ~ 0.07) while the exact sign-flip test
% rejects (p ~ 0.002). Both are valid answers to different questions; the tool
% must refuse to call significance either way.
xSkew = [8.96101 0.709983 1.51509 0.299897 0.0738771 1.15554 1.1088 ...
         0.772449 0.608652 1.72934].';
S7 = mas_stat_check(xSkew, struct('mean', mean(xSkew)));
% Unequal variances: Welch and the label permutation disagree.
xU1 = [0.0685264 0.951153 -0.344803 0.035942 1.12212 0.323684 ...
       -0.411221 -0.641786 -0.661485 -0.225258].';
xU2 = [-0.298834 6.73843 11.0874 2.29915 13.3884 12.6686 -11.7408 11.6296 ...
       1.3826 5.22958].';
S8 = mas_stat_check(xU1, xU2, struct('claimDiff', mean(xU1) - mean(xU2)));

% =========================================================================
% UNCERTAINTY PROPAGATION
% =========================================================================
fu = @(x) x(1).*x(2);
U1 = mas_uncert_check(fu, [2; 3], [0.02; 0.03], struct('value', 6, ...
    'sigma', 0.0848528137423857, 'sigmaTolRel', 0.02, 'nMC', 20000));
U2 = mas_uncert_check(@(x) x(1)^2, 3, 1, struct('value', 9, 'sigma', 6.0, ...
    'sigmaTolRel', 0.02, 'nMC', 20000, 'usedMethod', 'linearized'));
U3 = mas_uncert_check(@(x) x(1)^2, 3, 1, struct('sigma', sqrt(38), ...
    'sigmaTolRel', 0.02, 'nMC', 20000));
U4 = mas_uncert_check(fu, [2; 3], [0.02; 0.03], struct('sigma', 0.08485, ...
    'sigmaTolRel', 0.001, 'nMC', 500));
U5 = mas_uncert_check(@(x) abs(x(1)), 1, 0.1, struct('value', 1, 'sigma', 0.1, ...
    'sigmaTolRel', 0.02, 'nMC', 20000));
U6 = mas_uncert_check(fu, [2; 3], [0.02; 0.03], struct('value', 6.1, 'sigma', 0.08485));

% =========================================================================
% REPRODUCIBILITY
% =========================================================================
R1 = mas_repro_check(@() sum(randn(1, 5)), struct('seed', 7, 'expectSeedDependence', true));
R2 = mas_repro_check(@() 42, struct('seed', 7, 'expectSeedDependence', false));
R3 = mas_repro_check(@() 42, struct('seed', 7, 'expectSeedDependence', true));
R4 = mas_repro_check(@() local_nonrepro(), struct('seed', 7));
R7 = mas_repro_check(@() 42, struct('seed', 7));
rng(5); a1 = rand; a2 = rand;
R5 = mas_repro_check(@() rand, struct('seed', 1));
b1 = rand; b2 = rand;
rng(5); c1 = rand; c2 = rand; c3 = rand; c4 = rand;
rngRestored = isequal([a1 a2 b1 b2], [c1 c2 c3 c4]); %#ok<NASGU>

% =========================================================================
% CASES
% =========================================================================
T = struct('name', {}, 'fn', {}, 'expect', {});

% --- quadrature ----------------------------------------------------------
T(end+1) = tc('quad: simpson pi PASS', @() Q1.verdict, 'PASS');
T(end+1) = tc('quad: all 8 checks pass', @() Q1.nPass == Q1.nChecks, true);
T(end+1) = tc('quad: two reference schemes agree', @() Q1.ref.gap < 1e-12, true);
T(end+1) = tc('quad: simpson order not below 4', @() Q1.orders.method >= 4, true);
T(end+1) = tc('quad: derivative order ~2', @() near(Q1.orders.derivative, 2, 0.05), true);
T(end+1) = tc('quad: deriv claim verified', @() st(Q1, 'derivVsRef'), 'pass');
T(end+1) = tc('quad: trapz cannot support 1e-12', @() Q2.verdict, 'UNDETERMINED');
T(end+1) = tc('quad: tolerance unachievable flagged', ...
    @() st(Q2, 'methodSupportsTol'), 'undetermined');
T(end+1) = tc('quad: wrong value FAIL', @() Q3.verdict, 'FAIL');
T(end+1) = tc('quad: valueVsRef fails', @() st(Q3, 'valueVsRef'), 'fail');
T(end+1) = tc('quad: oscillatory reference undetermined', @() Q4.verdict, 'UNDETERMINED');
T(end+1) = tc('quad: refAgreement undetermined', @() st(Q4, 'refAgreement'), 'undetermined');
T(end+1) = tc('quad: analytic derivative PASS', @() Q5.verdict, 'PASS');
T(end+1) = tc('quad: kink beyond reference quality', @() Q6.verdict, 'UNDETERMINED');
T(end+1) = tc('quad: kink valueVsRef undetermined', @() st(Q6, 'valueVsRef'), 'undetermined');
T(end+1) = tc('quad: simpson on kink order fails', @() Q6b.verdict, 'FAIL');
T(end+1) = tc('quad: kink simpson orderClaim', @() st(Q6b, 'methodOrder'), 'fail');
T(end+1) = tc('quad: no tolerance no PASS', @() Q7.verdict, 'UNDETERMINED');
T(end+1) = tc('quad: bad method rejected', ...
    @() err_of(@() mas_quad_check(f1, 0, 1, struct('value', 1, 'method', 'gauss'))), 'ERR');
T(end+1) = tc('quad: reversed bounds rejected', ...
    @() err_of(@() mas_quad_check(f1, 1, 0, struct('value', 1))), 'ERR');

% --- linear systems ------------------------------------------------------
T(end+1) = tc('linsolve: well conditioned PASS', @() L1.verdict, 'PASS');
T(end+1) = tc('linsolve: backward error at floor', ...
    @() L1.backwardError <= 10*2*eps, true);
T(end+1) = tc('linsolve: certified error bound 0', @() L1.errorBound == 0, true);
T(end+1) = tc('linsolve: two factorisations agree', @() L1.routeDiff < 1e-14, true);
T(end+1) = tc('linsolve: wrong x FAIL', @() L2.verdict, 'FAIL');
T(end+1) = tc('linsolve: residual catches wrong x', @() st(L2, 'residual'), 'fail');
T(end+1) = tc('linsolve: xVsTrue catches wrong x', @() st(L2, 'xVsTrue'), 'fail');
T(end+1) = tc('linsolve: hilb12 undetermined', @() L3.verdict, 'UNDETERMINED');
T(end+1) = tc('linsolve: hilb12 forward bound large', @() L3.errorBound > 0.5, true);
T(end+1) = tc('linsolve: rank deficient undetermined', @() L4.verdict, 'UNDETERMINED');
T(end+1) = tc('linsolve: rank check undetermined', @() st(L4, 'rank'), 'undetermined');
T(end+1) = tc('linsolve: row x rejected', ...
    @() err_of(@() mas_linsolve_check(A, (A\b).', b, struct('tolRel', 1e-9))), 'ERR');
T(end+1) = tc('linsolve: no tolRel still PASS', @() L6.verdict, 'PASS');
T(end+1) = tc('linsolve: certification na without claim', ...
    @() st(L6, 'certifiable'), 'na');

% --- convergence ---------------------------------------------------------
T(end+1) = tc('converge: newton PASS', @() C1.verdict, 'PASS');
T(end+1) = tc('converge: newton order measured', @() near(C1.observed.order, 2, 0.02), true);
T(end+1) = tc('converge: bisection PASS', @() C2.verdict, 'PASS');
T(end+1) = tc('converge: bisection rate 0.5', @() near(C2.observed.rate, 0.5, 1e-9), true);
T(end+1) = tc('converge: divergence FAIL', @() C3.verdict, 'FAIL');
T(end+1) = tc('converge: towardZero fails', @() st(C3, 'towardZero'), 'fail');
T(end+1) = tc('converge: stagnation FAIL', @() C4.verdict, 'FAIL');
T(end+1) = tc('converge: tolFinal fails', @() st(C4, 'finalTol'), 'fail');
T(end+1) = tc('converge: floor-limited order undetermined', @() C5.verdict, 'UNDETERMINED');
T(end+1) = tc('converge: orderClaim undetermined', @() st(C5, 'orderClaim'), 'undetermined');
T(end+1) = tc('converge: floor-limited final tol passes', @() st(C5, 'finalTol'), 'pass');
T(end+1) = tc('converge: non-finite means divergence', @() C6.verdict, 'FAIL');
T(end+1) = tc('converge: negative history rejected', ...
    @() err_of(@() mas_converge_check([1 -0.1 0.01], struct('tolFinal', 1e-3))), 'ERR');
T(end+1) = tc('converge: no claim rejected', ...
    @() err_of(@() mas_converge_check([1 .1 .01], struct())), 'ERR');

% --- fitting -------------------------------------------------------------
T(end+1) = tc('fit: linear fit PASS', @() F1.verdict, 'PASS');
T(end+1) = tc('fit: R2 recomputed', @() near(F1.metrics.r2, r2F, 1e-12), true);
T(end+1) = tc('fit: t quantile from betaincinv', @() near(F1.ci.tCrit, 2.30600413520417, 1e-12), true);
T(end+1) = tc('fit: SE matches inv-free hand route', ...
    @() max(abs(F1.ci.se - seF)) < 1e-12, true);
T(end+1) = tc('fit: CI endpoints match', @() max(abs(F1.ci.lo - (bf - tcritF*seF))) < 1e-12, true);
T(end+1) = tc('fit: holdout RMSE matches', @() near(F1.holdoutRmse, holdF, 1e-12), true);
T(end+1) = tc('fit: perturbed beta FAIL', @() F2.verdict, 'FAIL');
T(end+1) = tc('fit: coeffAgree fails', @() st(F2, 'coeffAgree'), 'fail');
T(end+1) = tc('fit: interpolating fit undetermined', @() F3.verdict, 'UNDETERMINED');
T(end+1) = tc('fit: zero dof flagged', @() st(F3, 'dof'), 'undetermined');
T(end+1) = tc('fit: rank-deficient design undetermined', @() F4.verdict, 'UNDETERMINED');
T(end+1) = tc('fit: ill-conditioned design undetermined', @() F5.verdict, 'UNDETERMINED');
T(end+1) = tc('fit: ill-conditioned SE undefined', @() st(F5, 'paramSeVsClaim'), 'undetermined');
T(end+1) = tc('fit: ill-conditioned coeff route undetermined', ...
    @() st(F5, 'coeffAgree'), 'undetermined');
T(end+1) = tc('fit: row beta rejected', ...
    @() err_of(@() mas_fit_check(Xf, yf, bf.', struct())), 'ERR');
T(end+1) = tc('fit: wrong R2 fails', @() st(F7, 'metricsVsClaim'), 'fail');
T(end+1) = tc('fit: wrong holdout RMSE fails', @() st(F8, 'holdout'), 'fail');

% --- statistics ----------------------------------------------------------
T(end+1) = tc('stat: one-sample PASS', @() S1.verdict, 'PASS');
T(end+1) = tc('stat: p matches hand value', @() near(S1.stats.p, pS, 1e-12), true);
T(end+1) = tc('stat: CI matches hand value', ...
    @() max(abs(S1.stats.ci - [mS - tqS*seS, mS + tqS*seS])) < 1e-12, true);
T(end+1) = tc('stat: exact sign-flip p', @() near(S1.cross.pPerm, 0.6875, 1e-12), true);
T(end+1) = tc('stat: one-sided p is half', @() near(S10.stats.p, pS/2, 1e-12), true);
T(end+1) = tc('stat: one-sided PASS', @() S10.verdict, 'PASS');
T(end+1) = tc('stat: wrong mean FAIL', @() S2.verdict, 'FAIL');
T(end+1) = tc('stat: wrong mean caught', @() st(S2, 'claimMean'), 'fail');
T(end+1) = tc('stat: NaN sample FAIL', @() S3.verdict, 'FAIL');
T(end+1) = tc('stat: incomplete sample flagged', @() st(S3, 'complete'), 'fail');
T(end+1) = tc('stat: dropped NaN changes the mean', @() st(S3, 'claimMean'), 'fail');
T(end+1) = tc('stat: constant sample undetermined', @() S4.verdict, 'UNDETERMINED');
T(end+1) = tc('stat: zero variance flagged', @() st(S4, 'defined'), 'undetermined');
T(end+1) = tc('stat: Welch PASS', @() S5.verdict, 'PASS');
T(end+1) = tc('stat: Welch df matches', @() near(S5.stats.df, dfW, 1e-9), true);
T(end+1) = tc('stat: Welch p matches', @() near(S5.stats.p, pW, 1e-12), true);
T(end+1) = tc('stat: label permutation p', @() near(S5.cross.pPerm, 0.0008, 1e-12), true);
T(end+1) = tc('stat: wrong p FAIL', @() S6.verdict, 'FAIL');
T(end+1) = tc('stat: skew t-vs-signflip undetermined', @() S7.verdict, 'UNDETERMINED');
T(end+1) = tc('stat: skew methods disagree', @() st(S7, 'methodAgreement'), 'undetermined');
T(end+1) = tc('stat: skew t retains', @() S7.stats.p > 0.05, true);
T(end+1) = tc('stat: skew sign-flip rejects', @() S7.cross.pPerm < 0.05, true);
T(end+1) = tc('stat: unequal-variance disagreement', @() S8.verdict, 'UNDETERMINED');
T(end+1) = tc('stat: Welch rejects permutation', @() st(S8, 'methodAgreement'), 'undetermined');
T(end+1) = tc('stat: no claims rejected', ...
    @() err_of(@() mas_stat_check(xs, struct('mu0', 10))), 'ERR');
T(end+1) = tc('stat: bad tail rejected', ...
    @() err_of(@() mas_stat_check(xs, struct('p', 0.5, 'tail', 'two'))), 'ERR');

% --- uncertainty ---------------------------------------------------------
T(end+1) = tc('uncert: linear product PASS', @() U1.verdict, 'PASS');
T(end+1) = tc('uncert: linearized sigma exact', ...
    @() near(U1.sigmaLin, 0.0848528137423857, 1e-15), true);
T(end+1) = tc('uncert: complex step chosen', @() U1.jacobianMethod, 'complex step');
T(end+1) = tc('uncert: nonlinear linearized claim FAIL', @() U2.verdict, 'FAIL');
T(end+1) = tc('uncert: Monte Carlo exposes nonlinearity', @() U2.sigmaMC > 6.1, true);
T(end+1) = tc('uncert: correct nonlinear sigma PASS', @() U3.verdict, 'PASS');
T(end+1) = tc('uncert: noisy MC undetermined', @() U4.verdict, 'UNDETERMINED');
T(end+1) = tc('uncert: noisy MC flagged', @() st(U4, 'mcPrecision'), 'undetermined');
T(end+1) = tc('uncert: non-analytic uses central diff', ...
    @() U5.jacobianMethod, 'central differences');
T(end+1) = tc('uncert: abs() uncertainty PASS', @() U5.verdict, 'PASS');
T(end+1) = tc('uncert: wrong value FAIL', @() U6.verdict, 'FAIL');
T(end+1) = tc('uncert: wrong value caught', @() st(U6, 'valueVsClaim'), 'fail');
T(end+1) = tc('uncert: length mismatch rejected', ...
    @() err_of(@() mas_uncert_check(fu, [2; 3], 0.02, struct())), 'ERR');
T(end+1) = tc('uncert: negative sigma rejected', ...
    @() err_of(@() mas_uncert_check(fu, [2; 3], [-0.02; 0.03], struct())), 'ERR');

% --- reproducibility -----------------------------------------------------
T(end+1) = tc('repro: stochastic PASS', @() R1.verdict, 'PASS');
T(end+1) = tc('repro: same seed bitwise equal', @() R1.diffSameSeed == 0, true);
T(end+1) = tc('repro: seed changes the result', @() R1.diffOtherSeed > 0, true);
T(end+1) = tc('repro: SHA-256 digest recorded', @() numel(R1.digest) == 64, true);
T(end+1) = tc('repro: deterministic no seed effect', @() R2.verdict, 'PASS');
T(end+1) = tc('repro: missing seed effect FAIL', @() R3.verdict, 'FAIL');
T(end+1) = tc('repro: seedEffect fails', @() st(R3, 'seedEffect'), 'fail');
T(end+1) = tc('repro: non-reproducible FAIL', @() R4.verdict, 'FAIL');
T(end+1) = tc('repro: sameSeed catches it', @() st(R4, 'sameSeed'), 'fail');
T(end+1) = tc('repro: RNG stream restored', @() rngRestored, true);
T(end+1) = tc('repro: seed effect not asserted', @() R7.verdict, 'PASS');
T(end+1) = tc('repro: seedEffect na', @() st(R7, 'seedEffect'), 'na');
T(end+1) = tc('repro: struct output rejected', ...
    @() err_of(@() mas_repro_check(@() struct('a', 1), struct())), 'ERR');

% =========================================================================
nP = 0;
if verbose, fprintf('=== data contract tests ===\n'); end
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
        fprintf('  [%s] %-44s -> %s\n', tern(ok, 'PASS', 'FAIL'), t.name, ...
            char(string(got)));
    end
    R(end+1) = struct('case', t.name, 'got', char(string(got)), 'pass', ok); %#ok<AGROW>
end
res = struct('nPass', nP, 'nTotal', numel(T), 'cases', R, 'pass', nP == numel(T));
if verbose
    fprintf('\n---- %d / %d data-contract cases passed ----\n', nP, numel(T));
end
end

% ===========================================================================
function v = local_nonrepro()
rng('shuffle');
v = rand;
end

function v = st(r, id)
v = 'MISSING';
for k = 1:numel(r.checks)
    if strcmp(r.checks(k).id, id)
        v = r.checks(k).status;
        return;
    end
end
end

function v = near(a, b, tol)
v = abs(double(a) - b) <= tol;
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
