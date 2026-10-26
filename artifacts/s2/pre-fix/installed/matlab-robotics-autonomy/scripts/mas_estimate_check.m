function r = mas_estimate_check(truth, est, P, claims)
%MAS_ESTIMATE_CHECK  Is a recorded state estimate consistent with its own covariance?
%
%   r = mas_estimate_check(truth, est, P)
%   r = mas_estimate_check(truth, est, P, struct('alpha',0.05,'maxBias',0.1, ...
%        'innovation', nu, 'S', S))
%
%   truth, est    N x n (one run) or N x n x R (R independent runs)
%   P             n x n x N x R, n x n x N (one run), or n x n (constant)
%
%   r.aneesPerStep  mean NEES at each step (R runs)
%   r.aneesMean     average over the accepted steps; target n
%   r.aneesBand     two-sided chi-square band for the average over all accepted samples
%   r.aneesStepBand chi-square band for one step's mean over runs (wider)
%   r.inBandFrac    fraction of steps inside the per-step band
%   r.halfMeans     [first-half second-half] mean ANEES, reported not graded
%   r.minEigP       smallest covariance eigenvalue over every step and run
%   r.bias          mean(truth - est) over the accepted samples
%   r.maxAutocorr   largest normalised innovation autocorrelation over the lags
%
% WHY MONTE CARLO RUNS ARE REQUIRED
% A single estimate sequence gives one NEES per step; that number is as noisy as the
% noise it measures, so "ANEES is 2.4, close to 2" from one run proves nothing. With
% R independent runs the average over samples is ~ chi2(R*(N-burnIn)*n)/(R*(N-burnIn)),
% which is where the mean band comes from; a single step's mean over runs follows the
% wider chi2(R*n)/R band. Fewer than `minRuns` (default 20) runs makes both bands so
% wide that they cannot reject a bad filter; the tool returns UNDETERMINED instead of
% pretending.
%
% The band is two-sided. A filter with ANEES far below n is not "better": it is
% under-confident, discarding information it was given. Both directions are defects.
%
% COVARIANCE HYGIENE IS CHECKED SEPARATELY
% Symmetry and positive definiteness are not implied by a small NEES at one step, and
% a covariance with a negative eigenvalue makes `P\e` meaningless (or negative), so
% those checks run before NEES and their failure is reported in its own right.
%
% INNOVATION WHITENESS
% When the innovations and their predicted covariance S are supplied, the normalised
% innovations should be white. A correlated sequence means the filter is not using
% the information it has (a lagged state, a missing input), even when the marginal
% covariance looks right. The threshold is family-wise over the tested lags,
% sqrt(2)*erfcinv(alpha/L)/sqrt(m*N_eff): the metric is the MAX of L autocorrelations,
% so a per-lag 95% bound would reject white noise roughly 40% of the time.

if nargin < 4, claims = struct(); end
[truth, est, P, nRuns, N, n] = normalize(truth, est, P);
if nRuns < 1, error('mas_estimate_check:runs', 'no runs in the input'); end
burnIn = getf(claims, 'burnIn', 0);
if burnIn < 0 || burnIn >= N
    error('mas_estimate_check:burnIn', 'burnIn must be in [0, N)');
end
keep = (burnIn+1):N;

C = struct('id', {}, 'status', {}, 'detail', {});

if ~all(isfinite(truth(:))) || ~all(isfinite(est(:))) || ~all(isfinite(P(:)))
    C = add(C, 'finiteInputs', false, ...
        'truth, est or P contains NaN/Inf: the consistency statistic is undefined');
    r = pack(C, struct(), N, n, nRuns, burnIn);
    return
end
C = add(C, 'finiteInputs', true, 'truth, est and P are finite');

% ---- covariance hygiene ----------------------------------------------------
symErr = 0; minEig = Inf;
for k = keep
    for rr = 1:nRuns
        Pk = P(:,:,k,rr);
        sc = max(1, max(abs(Pk(:))));
        symErr = max(symErr, max(max(abs(Pk - Pk.')))/sc);
        minEig = min(minEig, min(eig((Pk + Pk.')/2)));
    end
end
C = add(C, 'covSymmetry', symErr <= 1e-8, sprintf( ...
    'max relative |P-P''| = %.3e', symErr));
C = add(C, 'covPositiveDefinite', minEig > 0, sprintf( ...
    'smallest eigenvalue over all steps/runs = %.3e (must be > 0)', minEig));

% ---- NEES ------------------------------------------------------------------
% Two bands, because two different statistics are being tested:
%   band      for the mean over ALL accepted samples, ~ chi2(n*nRuns*nStep)/(nRuns*nStep)
%   stepBand  for a single step's mean over runs, ~ chi2(n*nRuns)/nRuns
% Using the mean band on individual steps (or vice versa) makes a correct filter fail:
% with 40 runs the mean band is +/-0.1 while a per-step ANEES has sd ~0.32, so at most
% ~25% of steps could ever land inside it.
alpha = getf(claims, 'alpha', 0.01);
minRuns = getf(claims, 'minRuns', 20);
nStep = numel(keep);
aneesStep = zeros(nStep, 1);
for kk = 1:nStep
    k = keep(kk);
    s = 0;
    for rr = 1:nRuns
        e = truth(k,:,rr).' - est(k,:,rr).';
        s = s + e.'*(P(:,:,k,rr)\e);
    end
    aneesStep(kk) = s / nRuns;
end
aneesMean = mean(aneesStep);
[nTot, band, bandSrc] = nees_band(n, nRuns*nStep, alpha);
[~, stepBand] = nees_band(n, nRuns, alpha);
if nRuns < minRuns
    C = add(C, 'nees', NaN, sprintf([ ...
        '%d run(s), minimum %d: the chi-square band would be too wide to reject a ' ...
        'bad filter, so NEES is reported but not graded'], nRuns, minRuns));
    inFrac = NaN;
elseif nStep < 5
    C = add(C, 'nees', NaN, sprintf( ...
        'only %d accepted step(s): too few for a chi-square band (need >= 5)', nStep));
    inFrac = NaN;
else
    inFrac = mean(aneesStep >= stepBand(1) & aneesStep <= stepBand(2));
    ok = isfinite(aneesMean) && aneesMean >= band(1) && aneesMean <= band(2) && inFrac >= 0.90;
    if aneesMean > band(2)
        why = 'OVER-CONFIDENT: P is too small, so the filter trusts itself too much';
    elseif aneesMean < band(1)
        why = 'UNDER-CONFIDENT: P is too large, so the filter discards information';
    elseif inFrac < 0.90
        why = 'the mean is in band but per-step coverage is not: the inconsistency is time-varying';
    else
        why = 'mean and per-step coverage agree';
    end
    C = add(C, 'nees', ok, sprintf( ...
        'ANEES %.3f vs mean band %.3f..%.3f (%s), per-step in-band %.0f%% (band %.3f..%.3f) -- %s', ...
        aneesMean, band(1), band(2), bandSrc, 100*inFrac, stepBand(1), stepBand(2), why));
end

% Half means are reported, not graded: the same runs are reused at every step, so the
% per-step ANEES values are serially correlated and a chi-square band on a half mean
% (which assumes independence across steps) rejects correct filters. A large split is
% still visible for the reader, and a real time-varying inconsistency shows up as
% per-step ANEES outside the step band above.
if nStep >= 4
    half = floor(nStep/2);
    halfMeans = [mean(aneesStep(1:half)), mean(aneesStep(half+1:end))];
else
    halfMeans = [NaN NaN];
end

% ---- bias ------------------------------------------------------------------
e = truth(keep,:,:) - est(keep,:,:);
bias = squeeze(mean(mean(e, 1), 3));
if n == 1, bias = bias(:); end
biasNorm = norm(bias);
if isfield(claims, 'maxBias')
    C = add(C, 'bias', biasNorm <= claims.maxBias, sprintf( ...
        '||mean error|| = %.3e vs maxBias %.3e', biasNorm, claims.maxBias));
end

% ---- innovation whiteness --------------------------------------------------
maxAc = NaN; thr = NaN;
if isfield(claims, 'innovation') && ~isempty(claims.innovation)
    nu = claims.innovation;
    if ismatrix(nu) && nRuns == 1
        nu = reshape(nu, [size(nu,1), size(nu,2), 1]);
    end
    if ndims(nu) ~= 3 || size(nu,1) ~= N
        error('mas_estimate_check:innovation', 'innovation must be N x m (x R)');
    end
    if ~isfield(claims, 'S') || isempty(claims.S)
        C = add(C, 'whiteness', NaN, ...
            'innovations supplied without S: normalised innovations cannot be formed');
    else
        S = claims.S;
        m = size(nu, 2);
        % A scalar or a single m x m covariance is a constant S: broadcast it over
        % every step and run. A 3-D S carries one page per step and is shared.
        if isscalar(S)
            S = repmat(S, [m m N nRuns]);
        elseif isequal(size(S), [m m])
            S = repmat(S, [1 1 N nRuns]);
        elseif ndims(S) == 3 && isequal(size(S), [m m N])
            S = repmat(reshape(S, [m m N 1]), [1 1 1 nRuns]);
        end
        if ndims(S) ~= 4 || size(S,1) ~= m || size(S,2) ~= m
            error('mas_estimate_check:S', 'S must be m x m x N (x R)');
        end
        z = zeros(N, m, nRuns);
        badS = false;
        for rr = 1:nRuns
            for k = keep
                Sk = S(:,:,k,rr);
                [L, p] = chol((Sk + Sk.')/2, 'lower');
                if p ~= 0, badS = true; break; end
                z(k,:,rr) = (L \ nu(k,:,rr).').';
            end
            if badS, break; end
        end
        if badS
            C = add(C, 'whiteness', NaN, ...
                'an innovation covariance is not positive definite: cannot whiten');
        else
            lags = getf(claims, 'whitenessLags', 1:10);
            acs = zeros(numel(lags), 1);
            for q = 1:numel(lags)
                L = lags(q);
                if L >= N, acs(q) = NaN; continue; end
                a = z(keep(1):end-L, :, :);
                b = z(keep(1)+L:end, :, :);
                acs(q) = mean(a(:).*b(:));       % pooled over components, steps, runs
            end
            nEff = nRuns * max(1, nStep - max(lags));
            % The metric is the MAX over lags, so a per-lag 95% bound rejects white
            % noise about 40% of the time with 10 lags. Split alpha across the lags:
            % P(|Z| > z) = alpha/L  =>  z = sqrt(2)*erfcinv(alpha/L).
            alphaW = getf(claims, 'whitenessAlpha', 0.05);
            zq = sqrt(2)*erfcinv(alphaW/numel(lags));
            thr = zq / sqrt(m * nEff);
            maxAc = max(abs(acs));
            C = add(C, 'whiteness', maxAc <= thr, sprintf( ...
                'max |autocorrelation| %.4f over lags %s vs family-wise %.0f%% threshold %.4f', ...
                maxAc, mat2str(lags), 100*(1-alphaW), thr));
        end
    end
end

r = pack(C, struct('aneesStep', aneesStep, 'aneesMean', aneesMean, ...
    'band', band, 'stepBand', stepBand, 'bandSrc', bandSrc, 'inFrac', inFrac, 'minEig', minEig, ...
    'symErr', symErr, 'bias', bias, 'biasNorm', biasNorm, 'halfMeans', halfMeans, ...
    'maxAc', maxAc, 'thr', thr, 'nTot', nTot), N, n, nRuns, burnIn);
end

% ===========================================================================
function [truth, est, P, R, N, n] = normalize(truth, est, P)
if ~isnumeric(truth) || ~isnumeric(est)
    error('mas_estimate_check:type', 'truth and est must be numeric');
end
R = 1;
if ndims(truth) == 2
    N = size(truth, 1); n = size(truth, 2);
    truth = reshape(truth, [N n 1]);
elseif ndims(truth) == 3
    N = size(truth, 1); n = size(truth, 2); R = size(truth, 3);
else
    error('mas_estimate_check:dim', 'truth must be N x n or N x n x R');
end
if ~isequal(size(est), size(truth))
    error('mas_estimate_check:size', 'est must have the same size as truth');
end
if isempty(P)
    error('mas_estimate_check:P', 'P is required: without a covariance there is no consistency claim');
end
if ndims(P) == 2
    if ~isequal(size(P), [n n]), error('mas_estimate_check:P', 'P must be n x n'); end
    P = repmat(P, [1 1 N R]);
elseif ndims(P) == 3
    if R ~= 1 || size(P,3) ~= N
        error('mas_estimate_check:P', '3-D P requires one run and N pages');
    end
    P = reshape(P, [n n N 1]);
elseif ndims(P) == 4
    if ~isequal(size(P), [n n N R])
        error('mas_estimate_check:P', '4-D P must be n x n x N x R');
    end
else
    error('mas_estimate_check:P', 'P must be 2-D, 3-D or 4-D');
end
end

function [nTot, band, src] = nees_band(n, nTot, alpha)
nu = nTot * n;
band = [chi2inv_base(alpha/2, nu)/nTot, chi2inv_base(1-alpha/2, nu)/nTot];
src = sprintf('chi2, %g%%', 100*(1-alpha));
end

function x = chi2inv_base(p, nu)
% chi2inv without Statistics Toolbox: chi2(nu) is gamma(nu/2, 2).
x = 2*gammaincinv(p, nu/2);
end

function r = pack(C, v, N, n, nRuns, burnIn)
r = struct();
r.n = n; r.nSteps = N; r.nRuns = nRuns; r.burnIn = burnIn;
if isfield(v, 'aneesStep'), r.aneesPerStep = v.aneesStep; end
if isfield(v, 'aneesMean'), r.aneesMean = v.aneesMean; end
if isfield(v, 'band'), r.aneesBand = v.band; r.bandSource = v.bandSrc; end
if isfield(v, 'stepBand'), r.aneesStepBand = v.stepBand; end
if isfield(v, 'inFrac'), r.inBandFrac = v.inFrac; end
if isfield(v, 'minEig'), r.minEigP = v.minEig; r.covSymErr = v.symErr; end
if isfield(v, 'bias'), r.bias = v.bias; r.biasNorm = v.biasNorm; end
if isfield(v, 'maxAc'), r.maxAutocorr = v.maxAc; r.whitenessThreshold = v.thr; end
if isfield(v, 'halfMeans'), r.halfMeans = v.halfMeans; end
if isfield(v, 'nTot'), r.neesSamples = v.nTot; end
r.checks = C; r.nChecks = numel(C);
r.nPass = nnz(strcmp({C.status}, 'pass'));
r.nFail = nnz(strcmp({C.status}, 'fail'));
r.nUndetermined = nnz(strcmp({C.status}, 'undetermined'));
r.nNa = nnz(strcmp({C.status}, 'na'));
r.verdict = verdict_of(C);
r.detail = sprintf('%d run(s) x %d step(s), n=%d, %d/%d checks -- %s', ...
    nRuns, N, n, r.nPass, r.nChecks, r.verdict);
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
