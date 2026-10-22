function probe_task2()
% Probe all Phase 5.3 Task-2 tools with hand-checkable cases and print the
% numbers that the contract tests will pin. No assertions here; this is the
% independent grounding run.

repo = 'E:\desktop\MATLAB';
addpath(fullfile(repo, 'skills', 'matlab-data-analysis', 'scripts'));
addpath(fullfile(repo, 'skills', 'matlab-data-analysis', 'tests'));
clear mas_quad_check mas_linsolve_check mas_converge_check mas_fit_check ...
      mas_stat_check mas_uncert_check mas_repro_check
rehash path

show = @(tag, r) fprintf('%-28s %-12s %s\n', tag, r.verdict, r.detail);

fprintf('\n===== QUAD =====\n');
f1 = @(x) 4./(1+x.^2);
q1 = mas_quad_check(f1, 0, 1, struct('value', pi, 'tolRel', 1e-8, ...
    'method', 'simpson', 'n', 32, 'derivAt', 0.5, 'derivValue', -2.56, ...
    'derivTolRel', 1e-6));
show('Q1 pi simpson', q1);
fprintf('  ref quadgk=%.15g rich=%.15g gap=%.3e floor=%.3e\n', ...
    q1.ref.quadgk, q1.ref.trapzRichardson, q1.ref.gap, q1.ref.floor);
fprintf('  orders: method=%.6f (%s) derivative=%.6f\n', q1.orders.method, ...
    q1.orders.methodName, q1.orders.derivative);
for k = 1:numel(q1.checks)
    fprintf('    %-20s %-13s %s\n', q1.checks(k).id, q1.checks(k).status, q1.checks(k).detail);
end

q2 = mas_quad_check(f1, 0, 1, struct('value', pi, 'tolRel', 1e-12, ...
    'method', 'trapz', 'n', 64));
show('Q2 pi trapz tol 1e-12', q2);

q3 = mas_quad_check(f1, 0, 1, struct('value', pi + 1e-3, 'tolRel', 1e-6, ...
    'method', 'simpson', 'n', 64));
show('Q3 wrong value', q3);

f4 = @(x) sin(200*x);
ex4 = (1 - cos(200))/200;
q4 = mas_quad_check(f4, 0, 1, struct('value', ex4, 'tolRel', 1e-6, ...
    'method', 'trapz', 'n', 64));
show('Q4 oscillatory', q4);
fprintf('  ref gap=%.3e quadgk=%.15g rich=%.15g\n', q4.ref.gap, q4.ref.quadgk, q4.ref.trapzRichardson);

f5 = @(x) exp(sin(x));
d5 = cos(1)*exp(sin(1));
q5 = mas_quad_check(f5, 0, 2, struct('value', integral(f5, 0, 2), 'tolRel', 1e-9, ...
    'derivAt', 1, 'derivValue', d5, 'derivTolRel', 1e-8));
show('Q5 deriv analytic', q5);
fprintf('  orders: method=%.4f deriv=%.6f\n', q5.orders.method, q5.orders.derivative);
for k = 1:numel(q5.checks)
    fprintf('    %-20s %-13s %s\n', q5.checks(k).id, q5.checks(k).status, q5.checks(k).detail);
end

f6 = @(x) abs(x - 1/3);
q6 = mas_quad_check(f6, 0, 1, struct('value', 5/18, 'tolRel', 1e-8, ...
    'method', 'trapz', 'n', 64));
show('Q6 kink', q6);
fprintf('  ref gap=%.3e quadgk=%.12g rich=%.12g\n', q6.ref.gap, q6.ref.quadgk, q6.ref.trapzRichardson);

q6b = mas_quad_check(f6, 0, 1, struct('value', 5/18, 'tolRel', 1e-6, ...
    'method', 'simpson', 'n', 32));
show('Q6b kink simpson', q6b);
fprintf('  measured order=%.4f\n', q6b.orders.method);

fprintf('\n-- order sanity (hand Simpson values) --\n');
for nn = [8 16 32 64]
    S = simp(@(x) exp(x), 0, 1, nn);
    fprintf('  exp  n=%2d err=%.3e\n', nn, abs(S - (exp(1) - 1)));
end
for nn = [8 16 32 64]
    S = simp(f1, 0, 1, nn);
    fprintf('  rat  n=%2d err=%.3e\n', nn, abs(S - pi));
end

fprintf('\n===== LINSOLVE =====\n');
A = [4 1; 1 3];
xt = [1; -1];
b = A*xt;
x = A\b;
l1 = mas_linsolve_check(A, x, b, struct('tolRel', 1e-12, 'xTrue', xt));
show('L1 well conditioned', l1);
fprintf('  eta=%.3e cond=%.6g bound=%.3e routeDiff=%.3e rank=%d\n', ...
    l1.backwardError, l1.cond, l1.errorBound, l1.routeDiff, l1.rank);

l2 = mas_linsolve_check(A, xt + [1e-6; 0], b, struct('tolRel', 1e-9, 'xTrue', xt));
show('L2 wrong x', l2);
fprintf('  eta=%.3e\n', l2.backwardError);

Ah = hilb(12);
bh = Ah*ones(12, 1);
lh = mas_linsolve_check(Ah, Ah\bh, bh, struct('tolRel', 1e-6));
show('L3 hilb12', lh);
fprintf('  eta=%.3e cond=%.3e bound=%.3e\n', lh.backwardError, lh.cond, lh.errorBound);

Ar = [1 2; 2 4];
br = [3; 6];
lr = mas_linsolve_check(Ar, [1; 1], br, struct('tolRel', 1e-9));
show('L4 rank deficient', lr);

try
    mas_linsolve_check(A, x.', b, struct('tolRel', 1e-9));
    fprintf('L5 row x               NO_ERROR\n');
catch ME
    fprintf('L5 row x               ERR: %s\n', ME.message);
end

fprintf('\n===== CONVERGE =====\n');
xx = 1; eN = zeros(1, 7);
for k = 1:7
    eN(k) = abs(xx - sqrt(2));
    xx = (xx + 2/xx)/2;
end
fprintf('  newton errors: %s\n', mat2str(eN, 6));
c1 = mas_converge_check(eN, struct('order', 2, 'tolFinal', 1e-10));
show('C1 newton', c1);
fprintf('  obs order=%.6f spread=%.3e rate=%.3e tailP=%s\n', c1.observed.order, ...
    c1.observed.orderSpread, c1.observed.rate, mat2str(c1.observed.tailOrder, 4));

eB = 0.5*2.^-(0:10);
c2 = mas_converge_check(eB, struct('order', 1, 'rate', 0.5, 'tolFinal', 1e-3));
show('C2 bisection', c2);
fprintf('  obs order=%.6f rate=%.6f\n', c2.observed.order, c2.observed.rate);

c3 = mas_converge_check(10.^(0:5), struct('tolFinal', 1e-6));
show('C3 divergent', c3);

eS = [1 .5 .33 .25 .2 .18 .17 .165 .163 .162];
c4 = mas_converge_check(eS, struct('tolFinal', 1e-6));
show('C4 stagnant', c4);

eF = [1e-1 1e-2 1e-4 1e-8 2e-16];
c5 = mas_converge_check(eF, struct('order', 2, 'tolFinal', 1e-15));
show('C5 floor limited', c5);
fprintf('  tailP=%s\n', mat2str(c5.observed.tailOrder, 6));

c6 = mas_converge_check([1 0.1 Inf], struct('tolFinal', 1e-6));
show('C6 non-finite', c6);

try
    mas_converge_check([1 -0.1 0.01], struct('tolFinal', 1e-3));
    fprintf('C7 negative             NO_ERROR\n');
catch ME
    fprintf('C7 negative             ERR: %s\n', ME.message);
end

fprintf('\n===== FIT =====\n');
rng(11);
t = (0:9).';
X = [ones(10, 1), t];
y = 2 + 0.5*t + 0.05*randn(10, 1);
beta = X\y;
n = 10; p = 2; dof = n - p;
res = y - X*beta;
sse = sum(res.^2); sst = sum((y - mean(y)).^2);
r2 = 1 - sse/sst; rmse = sqrt(sse/n);
sig = sqrt(sse/dof);
XpX = X'*X;
covB = sig^2*inv(XpX);
seB = sqrt(diag(covB));
tc = betaincinv(0.05, dof/2, 0.5);
tc = sqrt(dof*(1 - tc)/tc);
fprintf('  beta=%s\n', mat2str(beta.', 10));
fprintf('  sse=%.12g r2=%.12g rmse=%.12g sigma=%.12g tCrit=%.15g\n', sse, r2, rmse, sig, tc);
fprintf('  se=%s\n', mat2str(seB.', 10));
fprintf('  ciLo=%s\n', mat2str((beta - tc*seB).', 10));
fprintf('  ciHi=%s\n', mat2str((beta + tc*seB).', 10));
% holdout
th = (10:14).';
Xh = [ones(5, 1), th];
yh = 2 + 0.5*th + 0.05*randn(5, 1);
rmseH = sqrt(mean((yh - Xh*beta).^2));
fprintf('  holdoutRmse=%.12g\n', rmseH);

f1c = struct('r2', r2, 'rmse', rmse, 'se', seB, 'ciLo', beta - tc*seB, ...
    'ciHi', beta + tc*seB, 'holdout', struct('X', Xh, 'y', yh), 'holdoutRmse', rmseH);
fit1 = mas_fit_check(X, y, beta, f1c);
show('F1 linear fit', fit1);
for k = 1:numel(fit1.checks)
    fprintf('    %-20s %-13s %s\n', fit1.checks(k).id, fit1.checks(k).status, fit1.checks(k).detail);
end

fit2 = mas_fit_check(X, y, beta + [0.01; 0], f1c);
show('F2 perturbed beta', fit2);

Xn = [ones(3,1) (1:3).' (1:3).'.^2];
yn = [1;2;3];
fit3 = mas_fit_check(Xn, yn, Xn\yn, struct());
show('F3 n == p', fit3);

Xd = [ones(10,1) t t];
fit4 = mas_fit_check(Xd, y, Xd\y, struct());
show('F4 rank deficient', fit4);

H = hilb(8);
Xh8 = [H; H];
y8 = Xh8*((1:8).') + 0.01*randn(16, 1);
b8 = Xh8\y8;
[~, R8] = qr(Xh8, 0); Ri8 = R8\eye(8);
sig8 = sqrt(sum((y8 - Xh8*b8).^2)/(16-8));
se8 = sqrt(diag(sig8^2*(Ri8*Ri8')));
fit5 = mas_fit_check(Xh8, y8, b8, struct('se', se8));
show('F5 ill-conditioned', fit5);
fprintf('  condX=%.3e\n', fit5.condX);
for k = 1:numel(fit5.checks)
    fprintf('    %-20s %-13s %s\n', fit5.checks(k).id, fit5.checks(k).status, fit5.checks(k).detail);
end

try
    mas_fit_check(X, y, beta.', struct());
    fprintf('F6 row beta             NO_ERROR\n');
catch ME
    fprintf('F6 row beta             ERR: %s\n', ME.message);
end

fprintf('\n===== STAT one-sample =====\n');
xs = [10.2 9.8 10.1 10.3 9.9 10.0].';
m = mean(xs); s = std(xs); se = s/sqrt(numel(xs)); df1 = numel(xs) - 1;
tt = (m - 10)/se;
pp = betainc(df1/(df1 + tt^2), df1/2, 0.5);
tq = sqrt(df1*(1 - betaincinv(0.05, df1/2, 0.5))/betaincinv(0.05, df1/2, 0.5));
fprintf('  mean=%.12g p=%.12g ci=[%.12g %.12g] tCrit=%.12g\n', m, pp, ...
    m - tq*se, m + tq*se, tq);
s1 = mas_stat_check(xs, struct('mu0', 10, 'mean', m, 'ci', [m - tq*se, m + tq*se], ...
    'p', pp, 'decision', 'retain'));
show('S1 one-sample', s1);
fprintf('  pPerm=%.6g (%s) decision=%s\n', s1.cross.pPerm, s1.cross.method, s1.cross.decision);
for k = 1:numel(s1.checks)
    fprintf('    %-20s %-13s %s\n', s1.checks(k).id, s1.checks(k).status, s1.checks(k).detail);
end

s2 = mas_stat_check(xs, struct('mu0', 10, 'mean', m + 0.5));
show('S2 wrong mean', s2);

xnan = xs; xnan(3) = NaN;
s3 = mas_stat_check(xnan, struct('mu0', 10, 'mean', mean(xs(isfinite(xs)))));
show('S3 NaN sample', s3);
for k = 1:numel(s3.checks)
    fprintf('    %-20s %-13s %s\n', s3.checks(k).id, s3.checks(k).status, s3.checks(k).detail);
end

s4 = mas_stat_check(5*ones(8,1), struct('mu0', 5, 'p', 1));
show('S4 constant', s4);

fprintf('\n===== STAT two-sample =====\n');
rng(21);
xa = 10 + randn(12, 1);
xb = 11 + 1.5*randn(10, 1);
n1 = numel(xa); n2 = numel(xb);
d = mean(xa) - mean(xb);
v1 = var(xa)/n1; v2 = var(xb)/n2;
sew = sqrt(v1 + v2);
dfw = (v1 + v2)^2/(v1^2/(n1-1) + v2^2/(n2-1));
tw = d/sew;
pw = betainc(dfw/(dfw + tw^2), dfw/2, 0.5);
tqw = sqrt(dfw*(1 - betaincinv(0.05, dfw/2, 0.5))/betaincinv(0.05, dfw/2, 0.5));
fprintf('  diff=%.12g t=%.9g df=%.9g p=%.12g CI=[%.12g %.12g]\n', d, tw, dfw, pw, ...
    d - tqw*sew, d + tqw*sew);
s5 = mas_stat_check(xa, xb, struct('claimDiff', d, 'p', pw, ...
    'ci', [d - tqw*sew, d + tqw*sew], 'decision', 'reject'));
show('S5 two-sample', s5);
fprintf('  pPerm=%.6g (%s)\n', s5.cross.pPerm, s5.cross.method);

s6 = mas_stat_check(xa, xb, struct('p', 0.0001));
show('S6 wrong p', s6);

fprintf('\n===== SEARCH disagreement samples =====\n');
[dOne, pOne] = find_disagree_one();
if isempty(dOne)
    fprintf('  one-sample: none found\n');
else
    fprintf('  one-sample n=%d\n  x=%s\n  pT=%.6g pPerm=%.6g\n', numel(dOne), ...
        mat2str(dOne.', 6), pOne(1), pOne(2));
    sd = mas_stat_check(dOne, struct('mu0', 0, 'p', pOne(1)));
    fprintf('  tool verdict=%s detail=%s\n', sd.verdict, sd.detail);
end
[dTwo, pTwo] = find_disagree_two();
if isempty(dTwo)
    fprintf('  two-sample: none found\n');
else
    fprintf('  two-sample n1=%d n2=%d\n  x1=%s\n  x2=%s\n  pT=%.6g pPerm=%.6g\n', ...
    size(dTwo,1), size(dTwo,2), mat2str(dTwo(:,1).', 6), ...
    mat2str(dTwo(:,2).', 6), pTwo(1), pTwo(2));
end

fprintf('\n===== UNCERT =====\n');
fu = @(x) x(1)*x(2);
u1 = mas_uncert_check(fu, [2; 3], [0.02; 0.03], struct('value', 6, ...
    'sigma', 0.0848528137423857, 'sigmaTolRel', 0.02, 'nMC', 20000));
show('U1 linear product', u1);
fprintf('  lin=%.9g mc=%.9g se=%.3e jac=%s bias=%.3e\n', u1.sigmaLin, ...
    u1.sigmaMC, u1.mcSE, u1.jacobianMethod, u1.mcBias);

fx = @(x) x(1)^2;
u2 = mas_uncert_check(fx, 3, 1, struct('value', 9, 'sigma', 6.0, ...
    'sigmaTolRel', 0.02, 'nMC', 20000, 'usedMethod', 'linearized'));
show('U2 nonlinear sigma 6.0', u2);
fprintf('  lin=%.9g mc=%.9g\n', u2.sigmaLin, u2.sigmaMC);
fprintf('  notes: %s\n', strjoin(u2.notes, ' | '));

u3 = mas_uncert_check(fx, 3, 1, struct('sigma', sqrt(38), ...
    'sigmaTolRel', 0.02, 'nMC', 20000));
show('U3 nonlinear sigma 6.164', u3);

u4 = mas_uncert_check(fu, [2; 3], [0.02; 0.03], struct('sigma', 0.08485, ...
    'sigmaTolRel', 0.001, 'nMC', 500));
show('U4 noisy MC', u4);

fa = @(x) abs(x(1));
u5 = mas_uncert_check(fa, 1, 0.1, struct('value', 1, 'sigma', 0.1, ...
    'sigmaTolRel', 0.02, 'nMC', 20000));
show('U5 abs non-analytic', u5);
fprintf('  jac=%s lin=%.6g mc=%.6g\n', u5.jacobianMethod, u5.sigmaLin, u5.sigmaMC);

u6 = mas_uncert_check(fu, [2; 3], [0.02; 0.03], struct('value', 6.1, 'sigma', 0.08485));
show('U6 wrong value', u6);

fprintf('\n===== REPRO =====\n');
r1 = mas_repro_check(@() sum(randn(1, 5)), struct('seed', 7, 'expectSeedDependence', true));
show('R1 stochastic', r1);
fprintf('  dSame=%.3e dSeed=%.3e digest=%s\n', r1.diffSameSeed, r1.diffOtherSeed, r1.digest);

r2 = mas_repro_check(@() 42, struct('seed', 7, 'expectSeedDependence', false));
show('R2 deterministic', r2);
r3 = mas_repro_check(@() 42, struct('seed', 7, 'expectSeedDependence', true));
show('R3 deterministic vs seed-dep', r3);

r4 = mas_repro_check(@() nonrepro(), struct('seed', 7));
show('R4 nonreproducible', r4);

rng(5); a1 = rand; a2 = rand;
r5 = mas_repro_check(@() rand, struct('seed', 1));
b1 = rand; b2 = rand;
rng(5); c1 = rand; c2 = rand; c3 = rand; c4 = rand;
fprintf('  restore=%d b1=%.6g c3=%.6g verdict=%s\n', ...
    isequal([a1 a2 b1 b2], [c1 c2 c3 c4]), b1, c3, r5.verdict);

try
    mas_repro_check(@() struct('a', 1), struct());
    fprintf('R6 struct output        NO_ERROR\n');
catch ME
    fprintf('R6 struct output        ERR: %s\n', ME.message);
end

fprintf('\n===== DONE =====\n');
end

% ---------------------------------------------------------------------------
function v = nonrepro()
rng('shuffle');
v = rand;
end

function [x, p] = find_disagree_one()
x = []; p = [];
for s = 1:4000
    rng(s);
    if mod(s, 2) == 0
        v = exp(randn(10, 1));                 % lognormal: skewed
    else
        v = [exprnd(1, 9, 1); 6];              % one large value
    end
    n = numel(v); m = mean(v); se = std(v)/sqrt(n);
    if se == 0, continue; end
    t = m/se;
    pt = betainc((n-1)/((n-1) + t^2), (n-1)/2, 0.5);
    pp = signflip_p(v, m);
    if (pt < 0.05) ~= (pp < 0.05)
        x = v; p = [pt pp];
        return;
    end
end
end

function [X, p] = find_disagree_two()
X = []; p = [];
% Unequal variances: Welch is designed for this, a permutation test assumes
% exchangeability and is not. This construction is the textbook disagreement.
for s = 1:200
    rng(s);
    a = randn(10, 1);
    b = 8 + 10*randn(10, 1);
    n1 = numel(a); n2 = numel(b);
    v1 = var(a)/n1; v2 = var(b)/n2;
    se = sqrt(v1 + v2);
    if se == 0, continue; end
    df = (v1 + v2)^2/(v1^2/(n1-1) + v2^2/(n2-1));
    t = (mean(a) - mean(b))/se;
    pt = betainc(df/(df + t^2), df/2, 0.5);
    pp = label_perm_p([a; b], n1, mean(a) - mean(b));
    if (pt < 0.05) ~= (pp < 0.05)
        X = [a b]; p = [pt pp];
        return;
    end
end
end

function p = signflip_p(d, obs)
n = numel(d); nC = 2^n;
ps = zeros(nC, 1);
for code = 0:nC-1
    sgn = (1 - 2*double(bitget(code, 1:n))).';
    ps(code+1) = mean(sgn.*d);
end
tol = 10*eps*max(1, abs(obs));
p = mean(abs(ps) >= abs(obs) - tol);
end

function p = label_perm_p(pooled, n1, obs)
B = 5000; N = numel(pooled);
st = rng; rng(20261021);
ps = zeros(B, 1);
for k = 1:B
    idx = randperm(N);
    ps(k) = mean(pooled(idx(1:n1))) - mean(pooled(idx(n1+1:end)));
end
rng(st);
p = mean(abs(ps) >= abs(obs) - 10*eps*max(1, abs(obs)));
end

function S = simp(f, a, b, n)
if mod(n, 2) ~= 0, n = n + 1; end
x = linspace(a, b, n + 1);
y = arrayfun(f, x);
h = (b - a)/n;
S = h/3*(y(1) + 4*sum(y(2:2:end-1)) + 2*sum(y(3:2:end-2)) + y(end));
end
