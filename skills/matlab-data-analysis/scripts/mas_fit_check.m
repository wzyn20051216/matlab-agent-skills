function r = mas_fit_check(X, y, beta, claims)
%MAS_FIT_CHECK  Re-derive a least-squares fit from its inputs and grade the claim.
%
%   r = mas_fit_check(X, y, beta, struct('r2', 0.94, 'rmse', 0.31))
%   r = mas_fit_check(X, y, beta, struct('ciLo', lo, 'ciHi', hi, 'level', 0.95))
%
% claims fields (all optional; the tool verifies the fit against the data even
% with no claims, because "this is the least-squares solution" is itself a claim):
%   .tolRel     coefficient agreement tolerance             (default 1e-8)
%   .r2 .adjR2 .rmse .sse .sigma   reported fit metrics to re-derive
%   .se .ciLo .ciHi .level         reported standard errors / intervals (0.95)
%   .holdout.X .holdout.y .holdoutRmse   an independent holdout check
%
% r.verdict  PASS | FAIL | UNDETERMINED
% r.metrics  sse, sst, r2, adjR2, rmse, sigma, n, p, dof
% r.ci       beta, se, lo, hi, level, tCrit   (NaN when not defined)
%
% WHY "THE FIT LOOKS RIGHT" IS NOT A CHECK
% A fitted curve that passes through the data can come from a wrong design
% matrix, a transposed response, or coefficients copied from a different run.
% Four independent facts are cheap to establish and each catches a different
% failure:
%
%   1. coefficients: beta must equal the least-squares solution X\y (a second
%      factorisation, not the code that produced beta);
%   2. orthogonality: X'*r must be zero -- the defining property of a least-
%      squares residual, checkable without knowing the true model;
%   3. metrics: R2/RMSE recomputed from beta and the data must match the report;
%   4. standard errors: sigma^2*(X'X)^-1 recomputed from scratch, which is only
%      meaningful when the design is well conditioned and n > p. With n == p the
%      fit interpolates, dof is zero, and SSE = 0 makes every SE zero -- an
%      impressive-looking "exact fit" that contains no information. That case is
%      undetermined, not passed.
%
% Standard errors are computed from the QR factor (Cov = sigma^2 * R^-1 R^-T),
% not by inverting X'X, because forming X'X squares the condition number.
% t quantiles come from betaincinv, so no Statistics Toolbox is required.
%
% A holdout RMSE is reported when supplied; it is the only number here that
% speaks to generalisation rather than to arithmetic self-consistency.

if nargin < 4 || isempty(claims), claims = struct(); end
if ~isnumeric(X) || ~isnumeric(y) || ~isnumeric(beta)
    error('mas_fit_check:type', 'X, y and beta must be numeric');
end
if ndims(X) ~= 2
    error('mas_fit_check:shape', 'X must be a 2-D design matrix');
end
[n, p] = size(X);
if ~isvector(y) || numel(y) ~= n
    error('mas_fit_check:shape', 'y must have %d elements (got %d)', n, numel(y));
end
y = y(:);
if numel(beta) ~= p
    error('mas_fit_check:shape', 'beta must have %d elements (one per column of X), got %d', ...
        p, numel(beta));
end
if size(beta, 1) ~= p
    error('mas_fit_check:shape', ...
        'beta must be %dx1; a 1x%d vector is usually a transposition mistake', p, p);
end

C = local_check_empty();
notes = {};

% ---- the least-squares solution and the reported one ---------------------
betaRef = X\y;
denB = max(1, norm(betaRef));
relBeta = norm(beta - betaRef)/denB;
tolBeta = local_field(claims, 'tolRel', 1e-8);

sv = svd(X);
if isempty(sv) || sv(1) == 0
    kappa = Inf; rnk = 0;
else
    rnk = nnz(sv > max(n, p)*eps*sv(1));
    if sv(end) <= 0 || ~isfinite(sv(end))
        kappa = Inf;
    else
        kappa = sv(1)/sv(end);
    end
end
fullRank = rnk == p;
dof = n - p;

% The normal equations square the condition number: a coefficient that came from
% (X'X)\(X'y) can legitimately differ from the QR solution by ~kappa^2*eps.
k2eps = kappa^2*eps;
if ~fullRank
    C = local_check_add(C, 'coeffAgree', NaN, sprintf( ...
        'rank %d < %d: the least-squares solution is not unique, so beta cannot be certified', ...
        rnk, p));
elseif isfinite(k2eps) && k2eps < 1
    crossTol = max(tolBeta, 10*k2eps);
    if relBeta <= crossTol
        C = local_check_add(C, 'coeffAgree', true, sprintf( ...
            'beta agrees with X\\y to %.3e (threshold %.3e, cond %.2e)', ...
            relBeta, crossTol, kappa));
    else
        C = local_check_add(C, 'coeffAgree', false, sprintf( ...
            'beta differs from X\\y by %.3e (threshold %.3e): this is not the least-squares solution', ...
            relBeta, crossTol));
    end
else
    C = local_check_add(C, 'coeffAgree', NaN, sprintf( ...
        ['cond^2*eps = %.2e: at this conditioning the QR and normal-equation ' ...
         'routes can differ by more than 100%%, so agreement with X\\y proves nothing'], k2eps));
end

if fullRank
    C = local_check_add(C, 'rank', true, sprintf( ...
        'X is full rank (%d of %d columns, cond %.2e)', rnk, p, kappa));
else
    C = local_check_add(C, 'rank', NaN, sprintf( ...
        'rank %d < %d: coefficients are not identifiable', rnk, p));
end

% ---- fit metrics from beta and the data ----------------------------------
yhat = X*beta;
resid = y - yhat;
sse = sum(resid.^2);
sst = sum((y - mean(y)).^2);
if sst > 0
    r2 = 1 - sse/sst;
else
    r2 = NaN;
end
if dof > 0
    adjR2 = 1 - (1 - r2)*(n - 1)/dof;
    sigma = sqrt(sse/dof);
else
    adjR2 = NaN;
    sigma = NaN;
end
rmse = sqrt(sse/n);
hasIntercept = any(all(X == 1, 1));
M = struct('sse', sse, 'sst', sst, 'r2', r2, 'adjR2', adjR2, ...
    'rmse', rmse, 'sigma', sigma, 'n', n, 'p', p, 'dof', dof);

orthoRel = norm(X'*resid)/(norm(X, 'fro')*norm(resid) + realmin);
if fullRank
    % X'*r is zero to working precision for the QR solution, but the relative
    % measure degrades with the conditioning of X; an ill-conditioned design is
    % not evidence that the residual is wrong.
    orthoTol = max(1e-8, 10*kappa*eps);
    C = local_check_add(C, 'orthogonality', orthoRel <= orthoTol, sprintf( ...
        '||X''*r||/(||X||*||r||) = %.3e (limit %.2e; least-squares residual must be orthogonal to X)', ...
        orthoRel, orthoTol));
else
    C = local_check_add(C, 'orthogonality', 'na', ...
        'rank-deficient: residual orthogonality alone does not pin the solution');
end

if hasIntercept
    mres = abs(mean(resid));
    lim = 1e-8*max(1, mean(abs(y)));
    C = local_check_add(C, 'residualMean', mres <= lim, sprintf( ...
        'mean residual %.3e (limit %.3e): an intercept forces it to zero', mres, lim));
else
    C = local_check_add(C, 'residualMean', 'na', 'no intercept column: mean residual need not be zero');
end

if dof > 0
    C = local_check_add(C, 'dof', true, sprintf('%d observations, %d parameters, %d residual dof', n, p, dof));
else
    C = local_check_add(C, 'dof', NaN, sprintf( ...
        ['%d observations for %d parameters: the fit interpolates, SSE = %.1e and every ' ...
         'standard error is zero by construction'], n, p, sse));
    notes{end+1} = 'n <= p: an interpolating fit cannot be validated by its own residuals';
end

% ---- reported metrics vs recomputed ones ---------------------------------
claimNames = {'r2', 'adjR2', 'rmse', 'sse', 'sigma'};
anyMetric = false;
worst = 0; worstName = ''; checked = 0; failedM = false;
for k = 1:numel(claimNames)
    f = claimNames{k};
    if isfield(claims, f) && isscalar(claims.(f)) && isfinite(claims.(f))
        anyMetric = true;
        ref = M.(f);
        if ~isfinite(ref)
            continue;
        end
        rel = abs(claims.(f) - ref)/max(1, abs(ref));
        checked = checked + 1;
        if rel > worst, worst = rel; worstName = f; end
        if rel > 1e-6, failedM = true; end
    end
end
if anyMetric && checked > 0
    C = local_check_add(C, 'metricsVsClaim', ~failedM, sprintf( ...
        '%d reported metric(s) re-derived; worst deviation %.2e (%s)', ...
        checked, worst, worstName));
elseif anyMetric
    C = local_check_add(C, 'metricsVsClaim', NaN, ...
        'reported metrics were not defined for this fit (zero dof or constant y)');
else
    C = local_check_add(C, 'metricsVsClaim', 'na', 'no fit metrics reported');
end

% ---- standard errors and intervals ---------------------------------------
level = local_field(claims, 'level', 0.95);
se = NaN(p, 1); lo = NaN(p, 1); hi = NaN(p, 1); tCrit = NaN;
if fullRank && dof > 0 && kappa <= 1e8 && isfinite(sigma)
    [~, Rr] = qr(X, 0);
    Ri = Rr\eye(p);
    covB = sigma^2*(Ri*Ri');
    se = sqrt(diag(covB));
    tCrit = local_t_quantile(1 - (1 - level)/2, dof);
    lo = beta - tCrit*se;
    hi = beta + tCrit*se;
elseif fullRank && dof > 0
    notes{end+1} = sprintf(['standard errors not reported: cond(X) = %.2e makes ' ...
        'sigma^2*(X''X)^-1 numerically meaningless'], kappa);
end

wantSe = (isfield(claims, 'se') && numel(claims.se) == p) || ...
         (isfield(claims, 'ciLo') && numel(claims.ciLo) == p) || ...
         (isfield(claims, 'ciHi') && numel(claims.ciHi) == p);
if wantSe
    if any(~isfinite(se))
        C = local_check_add(C, 'paramSeVsClaim', NaN, ...
            'standard errors are not defined for this fit (rank, dof or conditioning)');
    else
        bad = false; worstSE = 0;
        if isfield(claims, 'se') && numel(claims.se) == p
            rel = max(abs(claims.se(:) - se)./max(1, se));
            worstSE = max(worstSE, rel); bad = bad || rel > 1e-6;
        end
        if isfield(claims, 'ciLo') && numel(claims.ciLo) == p
            rel = max(abs(claims.ciLo(:) - lo)./max(1, abs(lo)));
            worstSE = max(worstSE, rel); bad = bad || rel > 1e-6;
        end
        if isfield(claims, 'ciHi') && numel(claims.ciHi) == p
            rel = max(abs(claims.ciHi(:) - hi)./max(1, abs(hi)));
            worstSE = max(worstSE, rel); bad = bad || rel > 1e-6;
        end
        C = local_check_add(C, 'paramSeVsClaim', ~bad, sprintf( ...
            'reported SE/CI re-derived at level %.2f; worst deviation %.2e', ...
            level, worstSE));
    end
else
    C = local_check_add(C, 'paramSeVsClaim', 'na', 'no standard errors or intervals reported');
end

% ---- holdout -------------------------------------------------------------
holdoutRmse = NaN;
if isfield(claims, 'holdout') && isstruct(claims.holdout) && ...
        isfield(claims.holdout, 'X') && isfield(claims.holdout, 'y')
    Xh = claims.holdout.X; yh = claims.holdout.y(:);
    if size(Xh, 2) ~= p || size(Xh, 1) ~= numel(yh)
        error('mas_fit_check:holdout', 'holdout X must be m-by-%d and y must have m elements', p);
    end
    holdoutRmse = sqrt(mean((yh - Xh*beta).^2));
    if isfield(claims, 'holdoutRmse') && isscalar(claims.holdoutRmse)
        rel = abs(claims.holdoutRmse - holdoutRmse)/max(1, holdoutRmse);
        C = local_check_add(C, 'holdout', rel <= 1e-6, sprintf( ...
            'holdout RMSE %.6g vs reported %.6g (dev %.2e)', ...
            holdoutRmse, claims.holdoutRmse, rel));
    else
        C = local_check_add(C, 'holdout', 'na', sprintf( ...
            'holdout RMSE computed (%.6g) but no value was reported to grade', holdoutRmse));
    end
else
    C = local_check_add(C, 'holdout', 'na', 'no holdout data supplied');
end

% ---- verdict -------------------------------------------------------------
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
r.metrics = M;
r.ci = struct('beta', beta, 'se', se, 'lo', lo, 'hi', hi, 'level', level, 'tCrit', tCrit);
r.betaRef = betaRef;
r.resid = resid;
r.condX = kappa;
r.rank = rnk;
r.hasIntercept = hasIntercept;
r.holdoutRmse = holdoutRmse;
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

% ===========================================================================
function t = local_t_quantile(p, nu)
% Two-sided Student-t quantile from the incomplete beta inverse (base MATLAB).
a = 2*(1 - p);
x = betaincinv(a, nu/2, 0.5);
t = sqrt(nu*(1 - x)/x);
end

function v = local_field(s, f, dflt)
v = dflt;
if isfield(s, f) && isscalar(s.(f)), v = s.(f); end
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
