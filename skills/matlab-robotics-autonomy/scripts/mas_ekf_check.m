function r = mas_ekf_check(model, opts)
%MAS_EKF_CHECK  Is the filter's uncertainty honest? NEES / NIS consistency test.
%
%   r = mas_ekf_check(struct('A',A,'H',H,'Q',Q,'R',R,'x0',x0,'P0',P0))
%
%   r.anees            average normalised estimation error squared, per step
%   r.aneesMean        overall mean; must be near n (the state dimension)
%   r.aneesBand        [lo hi] chi-square acceptance band
%   r.inBandFrac       fraction of steps inside the band
%   r.nisMean          mean normalised innovation squared; near m (measurement dim)
%   r.verdict
%
% THE QUESTION THIS ANSWERS
% A filter can be stable, smooth, and confidently wrong. Its own covariance P is the
% only claim it makes about accuracy, and a Kalman filter is only meaningful if that
% claim matches reality. NEES tests exactly that:
%
%     eps_k = (x_k - xhat_k)' P_k^{-1} (x_k - xhat_k)      E[eps] = n
%
% If eps >> n the filter is over-confident -- it believes itself more than the data
% justifies, and downstream gating will reject good measurements. If eps << n it is
% under-confident and is throwing away information. Both are defects, and neither is
% visible in a plot of the estimate: the estimate tracks the truth in all three cases.
%
% WHY IT NEEDS MONTE CARLO AND A CHI-SQUARE BAND
% A single run gives one noisy number, so this averages over `nRuns` independent
% ground-truth realisations drawn from the SAME Q and R the filter is given. Under
% the filter's own assumptions N * ANEES ~ chi2(N*n), which gives a two-sided band
% rather than an arbitrary tolerance.
%
% The band is two-sided on purpose: "close to n" is not the same as "consistent", and
% a filter tuned by making R enormous is pessimistic, not correct.
%
% The verdict checks the band fraction, not just the mean, because a filter can have
% the right mean while being inconsistent at particular times (during a transient,
% for instance). `inBandFrac` at 0.9 with a 99 % band catches that.
%
% Requires Statistics and Machine Learning Toolbox for chi2inv; without it the
% verdict falls back to a fixed +/-20 % band around n and says which was used.

if nargin < 2, opts = struct(); end
opts = dflt(opts, struct('nSteps', 60, 'nRuns', 200, 'alpha', 0.01, ...
    'burnIn', 10, 'seed', 20240, 'tolFrac', 0.20));

m = model;
A = m.A; H = m.H; Q = m.Q; R = m.R;

% Q and R are what the filter is TOLD. Qtrue / Rtrue are what the world actually
% does. They default to being equal, which is the case a correctly tuned filter
% must pass. Separating them is what lets this function test a MIS-tuned filter:
% with a single covariance there is no way to build the negative control, so the
% consistency check could not be shown to detect anything.
Qt = pick(m, 'Qtrue', Q);
Rt = pick(m, 'Rtrue', R);
n = size(A, 1);
mm = size(H, 1);

rng(opts.seed);
Lq = chol_safe(Qt, n);
Lr = chol_safe(Rt, mm);

anees = zeros(opts.nSteps, 1);
nis   = zeros(opts.nSteps, 1);

for run = 1:opts.nRuns
    x = m.x0(:);
    xh = m.x0(:);
    P = m.P0;
    for k = 1:opts.nSteps
        % process the ACTUAL system with the ACTUAL noise
        x = A*x + Lq.'*randn(n, 1);
        % predict
        xh = A*xh;
        P  = A*P*A.' + Q;
        % update
        z  = H*x + Lr.'*randn(mm, 1);
        nu = z - H*xh;
        S  = H*P*H.' + R;
        K  = P*H.'/S;
        xh = xh + K*nu;
        P  = (eye(n) - K*H)*P;
        % metrics against ground truth
        ee = x - xh;
        anees(k) = anees(k) + ee.'*(P\ee);
        nis(k)   = nis(k)   + nu.'*(S\nu);
    end
end
anees = anees / opts.nRuns;
nis   = nis   / opts.nRuns;

keep = (opts.burnIn+1):opts.nSteps;
aneesMean = mean(anees(keep));
nisMean   = mean(nis(keep));

[band, bandSrc] = anees_band(n, opts.nRuns, opts.alpha, opts.tolFrac);
inBand = (anees(keep) >= band(1)) & (anees(keep) <= band(2));
inBandFrac = mean(inBand);

ok = (inBandFrac >= 0.90) && (aneesMean >= band(1)) && (aneesMean <= band(2)) && ...
     isfinite(aneesMean) && isfinite(nisMean);
warn = {};
if ~ok
    if aneesMean > band(2)
        warn{end+1} = sprintf(['ANEES %.3f is above the %.3f bound: the filter is ' ...
            'OVER-CONFIDENT (P too small, or Q/R too small). It will reject good ' ...
            'measurements and its error bars are lies.'], aneesMean, band(2));
    elseif aneesMean < band(1)
        warn{end+1} = sprintf(['ANEES %.3f is below the %.3f bound: the filter is ' ...
            'UNDER-CONFIDENT (P too large, or Q/R too large). It is discarding ' ...
            'information it was given.'], aneesMean, band(1));
    end
    if inBandFrac < 0.90
        warn{end+1} = sprintf(['only %.0f%% of steps fall inside the band: the ' ...
            'inconsistency is time-varying, not a constant mis-scaling.'], 100*inBandFrac);
    end
end

r = struct();
r.anees = anees; r.aneesMean = aneesMean; r.nis = nis; r.nisMean = nisMean;
r.aneesBand = band; r.bandSource = bandSrc;
r.inBandFrac = inBandFrac;
r.n = n; r.m = mm; r.nRuns = opts.nRuns; r.nSteps = opts.nSteps;
r.warnings = warn;
r.ok = ok;
r.verdict = tern(ok, 'PASS', 'FAIL');
r.detail = sprintf(['n=%d m=%d, %d runs x %d steps: ANEES %.3f (band %.3f..%.3f, %s), ' ...
    'NIS %.3f (target %d), in-band %.0f%% -- %s'], n, mm, opts.nRuns, opts.nSteps, ...
    aneesMean, band(1), band(2), bandSrc, nisMean, mm, 100*inBandFrac, r.verdict);
end

% ---------------------------------------------------------------------------
function v = pick(s, name, dfltVal)
if isstruct(s) && isfield(s, name), v = s.(name); else, v = dfltVal; end
end

function L = chol_safe(M, k)
% Factor M = L'*L without letting a semidefinite matrix silently succeed or a
% slightly indefinite one (rounding) fail. Falls back to an eigen-square-root so a
% noise covariance that is 0 in one direction still samples correctly.
M = (M + M.')/2;
[L, p] = chol(M);
if p == 0, return; end
[V, D] = eig(M);
d = max(real(diag(D)), 0);
L = sqrt(diag(d)) * V.';
end

function [band, src] = anees_band(n, nRuns, alpha, tolFrac)
% Two-sided chi-square band for the average NEES.
%
% Each run contributes one chi2(n); N independent runs sum to chi2(N*n), so
%
%     N * ANEES ~ chi2(N*n)   =>   ANEES ~ chi2(N*n) / N
%
% and the band divides by N (the number of runs), NOT by N*n. Dividing by N*n
% centres the band on 1 instead of on the state dimension n, so a perfectly
% consistent 2-state filter reports ANEES 2.0 against an acceptance band of
% 0.83..1.19 and is called over-confident. The first version made exactly
% this error and rejected every filter it was given, including the correct one.
if exist('chi2inv', 'file') == 2
    nu = nRuns * n;
    band = [chi2inv(alpha/2, nu)/nRuns, chi2inv(1 - alpha/2, nu)/nRuns];
    src = sprintf('chi2, %g%%', 100*(1-alpha));
else
    band = [n*(1 - tolFrac), n*(1 + tolFrac)];
    src = sprintf('fixed +/-%g%% (chi2inv unavailable)', 100*tolFrac);
end
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
