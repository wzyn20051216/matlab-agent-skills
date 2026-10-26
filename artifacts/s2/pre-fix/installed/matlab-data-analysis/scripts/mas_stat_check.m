function r = mas_stat_check(x, varargin)
%MAS_STAT_CHECK  Re-derive a statistical claim and cross-check it by resampling.
%
%   r = mas_stat_check(x, struct('mu0', 0, 'mean', 12.4, 'ci', [12.1 12.7]))
%   r = mas_stat_check(x1, x2, struct('claimDiff', 2.5, 'p', 0.03, 'alpha', 0.05))
%
% One sample: claims fields
%   .mu0        null mean (default 0)
%   .mean       reported sample mean
%   .ci         reported confidence interval [lo hi]
%   .p          reported p-value
%   .alpha      significance level (default 0.05)
%   .tail       'both' (default) | 'greater' | 'less'
%   .decision   'reject' | 'retain'
%   .tolRel / .ciTolRel / .pAbsTol   comparison tolerances
%
% Two samples (Welch): .claimDiff instead of .mean; the interval and p-value are
% for the difference mean(x1) - mean(x2).
%
% At least one claim must be stated -- with none there is nothing to grade.
%
% r.verdict  PASS | FAIL | UNDETERMINED
% r.stats    mean/sd/se/df/t/p/ci and, for two samples, the Welch df and Cohen's d
% r.cross    the resampling p-value, its method, and whether the two routes agree
%
% WHY A p-VALUE IS NOT SELF-CERTIFYING
% A p-value is a number produced by a formula; checking it against itself proves
% nothing. This tool does three separate things:
%
%   1. recomputes the statistic from the raw data (mean, SE, Welch df, CI) so a
%      copy-paste or wrong-alpha report is caught;
%   2. recomputes the p-value from the t distribution via the incomplete beta
%      function (base MATLAB -- no Statistics Toolbox), and compares it with the
%      reported value;
%   3. runs an independent resampling test -- an exact sign-flip test for one
%      sample, a label permutation for two -- which assumes only symmetry or
%      exchangeability, not normality. If the two routes disagree about the
%      decision at the stated alpha, the verdict is UNDETERMINED with the message
%      NOT to claim significance; the two tests are answering slightly different
%      questions and the data cannot separate them.
%
% Non-finite observations are not silently dropped: the sample is incomplete and
% any inference computed from the remainder is reported as FAIL, because "n = 37"
% quietly standing in for "n = 40" is exactly the kind of loss this project bans.
%
% A constant sample has zero variance: t is 0/0 or x/0, the t distribution does
% not apply, and the result is UNDETERMINED rather than a confident p = 1.

if nargin == 2 && isstruct(varargin{1})
    r = local_one(x, varargin{1});
elseif nargin == 3 && isstruct(varargin{2})
    r = local_two(x, varargin{1}, varargin{2});
else
    error('mas_stat_check:args', ...
        'usage: mas_stat_check(x, claims) or mas_stat_check(x1, x2, claims)');
end
end

% ===========================================================================
function r = local_one(x, claims)
if ~isnumeric(x) || ~isvector(x)
    error('mas_stat_check:sample', 'x must be a numeric vector');
end
x = x(:);
if numel(x) < 2
    error('mas_stat_check:sample', 'need at least 2 observations (got %d)', numel(x));
end
mu0 = local_field(claims, 'mu0', 0);
alpha = local_field(claims, 'alpha', 0.05);
tail = local_tail_name(claims);
wantMean = isfield(claims, 'mean') && isscalar(claims.mean);
wantCI = isfield(claims, 'ci') && numel(claims.ci) == 2;
wantP = isfield(claims, 'p') && isscalar(claims.p);
wantDec = isfield(claims, 'decision');
if ~(wantMean || wantCI || wantP || wantDec)
    error('mas_stat_check:claims', ...
        'state at least one of mean, ci, p, decision -- otherwise there is no claim to grade');
end

C = local_check_empty();
notes = {};
fin = isfinite(x);
if all(fin)
    C = local_check_add(C, 'complete', true, sprintf('%d finite observations', numel(x)));
    xf = x;
else
    C = local_check_add(C, 'complete', false, sprintf( ...
        '%d of %d observations are non-finite: inference on the remainder is NOT the stated sample', ...
        nnz(~fin), numel(x)));
    xf = x(fin);
    notes{end+1} = 'incomplete sample: the reported n is not the sample size of the data';
end
if numel(xf) < 2
    error('mas_stat_check:sample', 'fewer than 2 finite observations remain');
end

n = numel(xf);
m = mean(xf);
s = std(xf);
se = s/sqrt(n);
df = n - 1;
if se == 0
    if m == mu0, t = 0; else, t = sign(m - mu0)*Inf; end
else
    t = (m - mu0)/se;
end
p2 = local_t_p(t, df);
p = local_t_tail(p2, t, tail);
tCrit = local_t_quantile(1 - alpha/2, df);
ci = [m - tCrit*se, m + tCrit*se];
cohenD = (m - mu0)/s;

if s == 0
    C = local_check_add(C, 'defined', NaN, sprintf( ...
        'zero sample variance (all %d values equal %g): the t distribution does not apply', n, m));
else
    C = local_check_add(C, 'defined', true, sprintf('sample sd %.6g > 0', s));
end

if wantMean
    tol = local_field(claims, 'tolRel', 1e-9);
    C = local_check_add(C, 'claimMean', abs(m - claims.mean) <= tol*max(1, abs(m)), sprintf( ...
        'recomputed mean %.10g vs reported %.10g (dev %.2e, tol %.1e)', ...
        m, claims.mean, abs(m - claims.mean), tol*max(1, abs(m))));
else
    C = local_check_add(C, 'claimMean', 'na', 'no mean reported');
end

if wantCI
    tol = local_field(claims, 'ciTolRel', 1e-6);
    dLo = abs(ci(1) - claims.ci(1)); dHi = abs(ci(2) - claims.ci(2));
    C = local_check_add(C, 'claimCI', ...
        dLo <= tol*max(1, abs(ci(1))) && dHi <= tol*max(1, abs(ci(2))), sprintf( ...
        'recomputed %.2f%% CI [%.10g, %.10g] vs reported [%.10g, %.10g] (t* = %.6g)', ...
        100*(1 - alpha), ci(1), ci(2), claims.ci(1), claims.ci(2), tCrit));
else
    C = local_check_add(C, 'claimCI', 'na', 'no confidence interval reported');
end

if wantP
    tol = local_field(claims, 'pAbsTol', 1e-8) + 1e-6*abs(claims.p);
    C = local_check_add(C, 'claimP', abs(p - claims.p) <= tol, sprintf( ...
        'recomputed %s p = %.6g vs reported %.6g (t = %.6g, df = %d)', ...
        tail, p, claims.p, t, df));
else
    C = local_check_add(C, 'claimP', 'na', 'no p-value reported');
end

if wantDec
    dec = local_decision(claims.decision);
    obs = local_decision_from_p(p, alpha);
    C = local_check_add(C, 'decision', strcmp(dec, obs), sprintf( ...
        'recomputed decision "%s" (p = %.4g vs alpha = %.2g) vs reported "%s"', ...
        obs, p, alpha, dec));
else
    C = local_check_add(C, 'decision', 'na', 'no decision reported');
end

d = xf - mu0;
[pPerm, how] = local_signflip(d, mean(d), tail);
decP = local_decision_from_p(p, alpha);
decPerm = local_decision_from_p(pPerm, alpha);
if strcmp(decP, decPerm)
    C = local_check_add(C, 'methodAgreement', true, sprintf( ...
        't-test and %s agree on "%s" (p = %.4g vs %.4g)', how, decP, p, pPerm));
else
    C = local_check_add(C, 'methodAgreement', NaN, sprintf( ...
        ['t-test says "%s" (p = %.4g) but %s says "%s" (p = %.4g): ' ...
         'the data do not support a significance claim'], ...
        decP, p, how, decPerm, pPerm));
end

stats = struct('mode', 'one-sample', 'n', n, 'mean', m, 'sd', s, 'se', se, ...
    'df', df, 't', t, 'p', p, 'ci', ci, 'mu0', mu0, 'alpha', alpha, ...
    'tail', tail, 'cohenD', cohenD);
cross = struct('pPerm', pPerm, 'method', how, 'decision', decPerm);
r = local_finish(C, notes, stats, cross);
end

% ===========================================================================
function r = local_two(x1, x2, claims)
if ~isnumeric(x1) || ~isnumeric(x2) || ~isvector(x1) || ~isvector(x2)
    error('mas_stat_check:sample', 'x1 and x2 must be numeric vectors');
end
x1 = x1(:); x2 = x2(:);
if numel(x1) < 2 || numel(x2) < 2
    error('mas_stat_check:sample', 'each sample needs at least 2 observations');
end
alpha = local_field(claims, 'alpha', 0.05);
tail = local_tail_name(claims);
wantDiff = isfield(claims, 'claimDiff') && isscalar(claims.claimDiff);
wantCI = isfield(claims, 'ci') && numel(claims.ci) == 2;
wantP = isfield(claims, 'p') && isscalar(claims.p);
wantDec = isfield(claims, 'decision');
if ~(wantDiff || wantCI || wantP || wantDec)
    error('mas_stat_check:claims', ...
        'state at least one of claimDiff, ci, p, decision -- otherwise there is no claim to grade');
end

C = local_check_empty();
notes = {};
f1 = isfinite(x1); f2 = isfinite(x2);
if all(f1) && all(f2)
    C = local_check_add(C, 'complete', true, sprintf('%d + %d finite observations', ...
        numel(x1), numel(x2)));
    a = x1; b = x2;
else
    C = local_check_add(C, 'complete', false, sprintf( ...
        '%d and %d non-finite observations: inference on the remainder is NOT the stated samples', ...
        nnz(~f1), nnz(~f2)));
    a = x1(f1); b = x2(f2);
    notes{end+1} = 'incomplete samples: the reported n is not the sample size of the data';
end
if numel(a) < 2 || numel(b) < 2
    error('mas_stat_check:sample', 'fewer than 2 finite observations remain in a sample');
end

n1 = numel(a); n2 = numel(b);
m1 = mean(a); m2 = mean(b);
s1 = std(a); s2 = std(b);
v1 = s1^2/n1; v2 = s2^2/n2;
se = sqrt(v1 + v2);
diff = m1 - m2;
if se == 0
    df = n1 + n2 - 2;
    if diff == 0, t = 0; else, t = sign(diff)*Inf; end
else
    df = (v1 + v2)^2/(v1^2/(n1 - 1) + v2^2/(n2 - 1));
    t = diff/se;
end
p2 = local_t_p(t, df);
p = local_t_tail(p2, t, tail);
tCrit = local_t_quantile(1 - alpha/2, df);
ci = diff + [-1 1]*tCrit*se;
sp = sqrt(((n1 - 1)*s1^2 + (n2 - 1)*s2^2)/(n1 + n2 - 2));
cohenD = diff/sp;

if s1 == 0 && s2 == 0
    C = local_check_add(C, 'defined', NaN, sprintf( ...
        'both samples are constant (%g and %g): zero standard error, no sampling distribution', m1, m2));
else
    C = local_check_add(C, 'defined', true, sprintf('sample sds %.6g and %.6g', s1, s2));
end

if wantDiff
    tol = local_field(claims, 'tolRel', 1e-9);
    C = local_check_add(C, 'claimDiff', abs(diff - claims.claimDiff) <= tol*max(1, abs(diff)), ...
        sprintf('recomputed difference %.10g vs reported %.10g (dev %.2e, tol %.1e)', ...
        diff, claims.claimDiff, abs(diff - claims.claimDiff), tol*max(1, abs(diff))));
else
    C = local_check_add(C, 'claimDiff', 'na', 'no difference reported');
end

if wantCI
    tol = local_field(claims, 'ciTolRel', 1e-6);
    C = local_check_add(C, 'claimCI', ...
        abs(ci(1) - claims.ci(1)) <= tol*max(1, abs(ci(1))) && ...
        abs(ci(2) - claims.ci(2)) <= tol*max(1, abs(ci(2))), sprintf( ...
        'recomputed %.2f%% CI for the difference [%.10g, %.10g] vs reported [%.10g, %.10g]', ...
        100*(1 - alpha), ci(1), ci(2), claims.ci(1), claims.ci(2)));
else
    C = local_check_add(C, 'claimCI', 'na', 'no confidence interval reported');
end

if wantP
    tol = local_field(claims, 'pAbsTol', 1e-8) + 1e-6*abs(claims.p);
    C = local_check_add(C, 'claimP', abs(p - claims.p) <= tol, sprintf( ...
        'recomputed Welch %s p = %.6g vs reported %.6g (t = %.6g, df = %.4g)', ...
        tail, p, claims.p, t, df));
else
    C = local_check_add(C, 'claimP', 'na', 'no p-value reported');
end

if wantDec
    dec = local_decision(claims.decision);
    obs = local_decision_from_p(p, alpha);
    C = local_check_add(C, 'decision', strcmp(dec, obs), sprintf( ...
        'recomputed decision "%s" (p = %.4g vs alpha = %.2g) vs reported "%s"', ...
        obs, p, alpha, dec));
else
    C = local_check_add(C, 'decision', 'na', 'no decision reported');
end

pooled = [a; b];
[pPerm, how] = local_label_perm(pooled, n1, diff, tail);
decP = local_decision_from_p(p, alpha);
decPerm = local_decision_from_p(pPerm, alpha);
if strcmp(decP, decPerm)
    C = local_check_add(C, 'methodAgreement', true, sprintf( ...
        'Welch t and %s agree on "%s" (p = %.4g vs %.4g)', how, decP, p, pPerm));
else
    C = local_check_add(C, 'methodAgreement', NaN, sprintf( ...
        ['Welch t says "%s" (p = %.4g) but %s says "%s" (p = %.4g): ' ...
         'the data do not support a significance claim'], ...
        decP, p, how, decPerm, pPerm));
end

stats = struct('mode', 'two-sample Welch', 'n1', n1, 'n2', n2, ...
    'mean1', m1, 'mean2', m2, 'sd1', s1, 'sd2', s2, 'diff', diff, ...
    'se', se, 'df', df, 't', t, 'p', p, 'ci', ci, 'alpha', alpha, ...
    'tail', tail, 'cohenD', cohenD);
cross = struct('pPerm', pPerm, 'method', how, 'decision', decPerm);
r = local_finish(C, notes, stats, cross);
end

% ===========================================================================
function [p, how] = local_signflip(d, obs, tail)
% Exact sign-flip when n <= 14, otherwise seeded Monte Carlo.
n = numel(d);
if n <= 14
    nCodes = 2^n;
    ps = zeros(nCodes, 1);
    for code = 0:nCodes-1
        sgn = (1 - 2*double(bitget(code, 1:n))).';
        ps(code+1) = mean(sgn.*d);
    end
    p = local_perm_tail(ps, obs, tail);
    how = sprintf('exact sign-flip (%d patterns)', nCodes);
else
    B = 5000;
    st = rng;
    rng(20261021);
    ps = zeros(B, 1);
    for k = 1:B
        sgn = 1 - 2*double(rand(n, 1) < 0.5);
        ps(k) = mean(sgn.*d);
    end
    p = local_perm_tail(ps, obs, tail);
    rng(st);
    how = sprintf('Monte Carlo sign-flip (%d draws, seed 20261021)', B);
end
end

function [p, how] = local_label_perm(pooled, n1, obs, tail)
B = 5000;
N = numel(pooled);
st = rng;
rng(20261021);
ps = zeros(B, 1);
for k = 1:B
    idx = randperm(N);
    ps(k) = mean(pooled(idx(1:n1))) - mean(pooled(idx(n1+1:end)));
end
p = local_perm_tail(ps, obs, tail);
rng(st);
how = sprintf('label permutation (%d draws, seed 20261021)', B);
end

function p = local_perm_tail(ps, obs, tail)
tol = 10*eps*max(1, abs(obs));
switch tail
    case 'both',  hit = abs(ps) >= abs(obs) - tol;
    case 'greater', hit = ps >= obs - tol;
    case 'less',  hit = ps <= obs + tol;
end
p = mean(hit);
end

function p = local_t_p(t, nu)
if isnan(t)
    p = NaN;
    return;
end
p = betainc(nu/(nu + t^2), nu/2, 0.5);
end

function p = local_t_tail(p2, t, tail)
switch tail
    case 'both'
        p = p2;
    case 'greater'
        if t >= 0, p = p2/2; else, p = 1 - p2/2; end
    case 'less'
        if t <= 0, p = p2/2; else, p = 1 - p2/2; end
end
end

function t = local_t_quantile(p, nu)
a = 2*(1 - p);
x = betaincinv(a, nu/2, 0.5);
t = sqrt(nu*(1 - x)/x);
end

function tail = local_tail_name(claims)
tail = 'both';
if isfield(claims, 'tail') && ischar(claims.tail)
    tail = lower(claims.tail);
end
if ~any(strcmp(tail, {'both', 'greater', 'less'}))
    error('mas_stat_check:claims', 'tail must be both, greater or less');
end
end

function d = local_decision(s)
if ~ischar(s), error('mas_stat_check:claims', 'decision must be ''reject'' or ''retain'''); end
d = lower(s);
if ~any(strcmp(d, {'reject', 'retain'}))
    error('mas_stat_check:claims', 'decision must be ''reject'' or ''retain''');
end
end

function d = local_decision_from_p(p, alpha)
if p < alpha, d = 'reject'; else, d = 'retain'; end
end

function v = local_field(s, f, dflt)
v = dflt;
if isfield(s, f) && isscalar(s.(f)), v = s.(f); end
end

function r = local_finish(C, notes, stats, cross)
st = {C.status};
if any(strcmp(st, 'fail'))
    r.verdict = 'FAIL';
elseif any(strcmp(st, 'undetermined'))
    r.verdict = 'UNDETERMINED';
else
    r.verdict = 'PASS';
end
r.checks = C;
r.notes = notes;
r.stats = stats;
r.cross = cross;
r.nChecks = numel(C);
r.nPass = nnz(strcmp(st, 'pass'));
r.nFail = nnz(strcmp(st, 'fail'));
r.nUndetermined = nnz(strcmp(st, 'undetermined'));
r.nNa = nnz(strcmp(st, 'na'));
r.detail = sprintf('%s: %d pass, %d fail, %d undetermined, %d na', ...
    r.verdict, r.nPass, r.nFail, r.nUndetermined, r.nNa);
bad = strcmp(st, 'fail') | strcmp(st, 'undetermined');
if any(bad)
    r.detail = sprintf('%s (%s)', r.detail, strjoin({C(bad).id}, ', '));
end
end

function C = local_check_empty()
C = struct('id', {}, 'status', {}, 'detail', {});
end

function C = local_check_add(C, id, pass, detail)
if ischar(pass)
    st = pass;
elseif isnan(pass)
    st = 'undetermined';
elseif pass
    st = 'pass';
else
    st = 'fail';
end
C(end+1) = struct('id', id, 'status', st, 'detail', detail); %#ok<AGROW>
end
