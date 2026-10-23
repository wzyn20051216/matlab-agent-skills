function r = mas_stat_verdict(nErr, n, spec)
%MAS_STAT_VERDICT  Map a counted observation onto what it can and cannot prove.
%
%   r = mas_stat_verdict(0, 128, struct('theory', 0.5*erfc(sqrt(10^0.6))))
%   r = mas_stat_verdict(50, 1000, struct('target', 1e-2))
%
% spec fields (at least one of target / theory is required):
%   .target       largest rate the claim allows (BER, error fraction, failure
%                 rate). The claim is "rate <= target".
%   .theory       rate the claim says will be observed. The claim is
%                 "rate == theory, within counting noise".
%   .criterion    'auto' (default) | 'meets-target' | 'matches-theory' | 'both'.
%                 'both' grades the two claims separately and takes the worse.
%   .level        confidence level, default 0.95
%   .zMax         |z| acceptance limit against counting noise, default 3
%   .minExpected  expected count under the claim below which the run has no
%                 power, default 10
%
% r.verdict  PASS | FAIL | UNDETERMINED
% r.state    one of five names, and the state decides the verdict -- never the
%            other way round:
%   'sufficient-support'         PASS
%   'sufficient-refutation'      FAIL
%   'insufficient-sample'        UNDETERMINED  the run could not have seen the
%                                              rate it is grading (few expected
%                                              events, so no power either way)
%   'interval-straddles-target'  UNDETERMINED  the run IS powered and the target
%                                              still lies inside the interval
%   'criterion-missing'          UNDETERMINED  nothing was claimed
%
% WHY THE TWO UNDETERMINED STATES MUST NOT BE MERGED
% They prescribe opposite actions. 'insufficient-sample' means collect more
% trials; 'interval-straddles-target' means the estimate really sits at the
% threshold and the claim itself needs rethinking. A single "inconclusive"
% hides that difference, and an agent that only sees one bucket tends to pick
% the direction it wanted.
%
% ZERO ERRORS IS NEITHER "RATE = 0" NOR "CLAIM IS FALSE"
% With 0 counted events the exact one-sided bound is 1-(1-L)^(1/n) (the rule of
% three at 95 %). If the claimed target is ABOVE that bound the run genuinely
% certifies it -- a zero count is evidence, and calling it inconclusive would
% throw away the only evidence a rare-event test ever produces. If the target is
% BELOW that bound the same zero count says nothing at all. Both cases are
% decided by the interval, never by the mood of the counter.

if nargin < 3, error('mas_stat_verdict:args', 'need nErr, n and spec'); end
if ~isscalar(n) || n < 1 || floor(n) ~= n
    error('mas_stat_verdict:n', 'n must be a positive integer trial count');
end
if ~isscalar(nErr) || nErr < 0 || nErr > n || floor(nErr) ~= nErr
    error('mas_stat_verdict:nErr', 'need integer 0 <= nErr <= n');
end
if ~isstruct(spec), error('mas_stat_verdict:spec', 'spec must be a struct'); end

S = spec;
L = local_get(S, 'level', 0.95);
zMax = local_get(S, 'zMax', 3);
minExp = local_get(S, 'minExpected', 10);
tgt = local_get(S, 'target', []);
pth = local_get(S, 'theory', []);
crit = local_get(S, 'criterion', 'auto');

phat = nErr / n;
zq = local_quantile(L);
[ciLo, ciHi] = local_wilson(nErr, n, zq);
zeroUp = 1 - (1 - L)^(1/n);                % exact one-sided bound for 0 events
ciUpper = (nErr == 0) * zeroUp + (nErr > 0) * ciHi;

r = struct();
r.nErr = nErr; r.n = n; r.rateMeasured = phat; r.level = L;
r.ci = struct('method', 'Wilson score (exact binomial bound when nErr == 0)', ...
    'level', L, 'lo', ciLo, 'hi', ciHi, 'zeroCountUpper', zeroUp);
r.zMax = zMax; r.minExpected = minExp;

haveTarget = ~isempty(tgt) && isscalar(tgt) && isfinite(tgt) && tgt > 0 && tgt <= 1;
haveTheory = ~isempty(pth) && isscalar(pth) && isfinite(pth) && pth > 0 && pth <= 1;
if strcmp(crit, 'auto')
    if haveTarget && haveTheory, crit = 'both';
    elseif haveTarget, crit = 'meets-target';
    elseif haveTheory, crit = 'matches-theory';
    else, crit = 'none';
    end
end
r.criterion = crit;
r.target = tgt; r.theory = pth;

if strcmp(crit, 'none') || strcmp(crit, 'criterion-missing')
    r.state = 'criterion-missing';
    r.verdict = 'UNDETERMINED';
    r.sub = {};
    r.expectedUnderClaim = NaN;
    r.nRequired = NaN;
    r.z = NaN;
    r.detail = sprintf(['no acceptance criterion stated: %d/%d events (%.4g) was ' ...
        'compared with nothing, so the run refutes nothing and certifies nothing'], ...
        nErr, n, phat);
    r.ok = false;
    return;
end

sub = {};
if any(strcmp(crit, {'meets-target', 'both'}))
    if ~haveTarget
        error('mas_stat_verdict:target', ...
            'criterion %s needs spec.target; a target-free run has nothing to grade', crit);
    end
    sub{end+1} = local_target_state(nErr, n, tgt, ciLo, ciUpper, L, minExp); %#ok<AGROW>
end
if any(strcmp(crit, {'matches-theory', 'both'}))
    if ~haveTheory
        error('mas_stat_verdict:theory', ...
            'criterion %s needs spec.theory', crit);
    end
    sub{end+1} = local_theory_state(nErr, n, pth, zq, zMax, minExp); %#ok<AGROW>
end

r.sub = sub;
worse = local_worse(sub);
r.state = worse.state;
r.verdict = local_verdict_of(worse.state);
r.z = local_z(nErr, n, tgt, pth);
r.expectedUnderClaim = local_expected(n, tgt, pth);
r.nRequired = local_n_required(tgt, pth, L, minExp);
r.ok = strcmp(r.verdict, 'PASS');
r.detail = sprintf('%s -> %s | %s', r.verdict, r.state, ...
    strjoin(cellfun(@(s) s.detail, sub, 'UniformOutput', false), ' ; '));
end

% ===========================================================================
function s = local_target_state(nErr, n, tgt, ciLo, ciUpper, L, minExp)
% Claim: rate <= tgt. The interval decides, in both directions.
s = struct();
s.criterion = 'meets-target';
s.target = tgt;
s.expectedUnderTarget = n*tgt;
s.nRequiredToCertify = ceil(log(1 - L)/log(1 - tgt));   % events needed for 0-fail proof
s.expectedUnderClaim = n*tgt;
s.nRequired = s.nRequiredToCertify;
if ciLo > tgt
    s.state = 'sufficient-refutation';
    s.detail = sprintf(['target %.4g lies BELOW the %.4g%% lower bound %.4g: ' ...
        '%d/%d events refute the claim, whatever the sample size'], ...
        tgt, 100*L, ciLo, nErr, n);
elseif ciUpper <= tgt
    s.state = 'sufficient-support';
    s.detail = sprintf(['target %.4g is at or above the %.4g%% upper bound %.4g: ' ...
        '%d/%d events certify rate <= %.4g'], tgt, 100*L, ciUpper, nErr, n, tgt);
elseif n*tgt < minExp
    s.state = 'insufficient-sample';
    s.detail = sprintf(['only %.3g events expected under the target %.4g in %d trials, ' ...
        'so a run this short cannot see the rate it is grading; needs >= %d trials'], ...
        n*tgt, tgt, n, s.nRequiredToCertify);
else
    s.state = 'interval-straddles-target';
    s.detail = sprintf(['powered (expected %.3g >= %g) but the %.4g%% interval ' ...
        '[%.4g, %.4g] straddles the target %.4g: the estimate sits at the threshold itself'], ...
        n*tgt, minExp, 100*L, ciLo, ciUpper, tgt);
end
end

function s = local_theory_state(nErr, n, pth, zq, zMax, minExp)
% Claim: rate == pth within counting noise. A zero count with plenty of expected
% events is a REFUTATION (noise smaller than labelled), not an absence of news.
s = struct();
s.criterion = 'matches-theory';
s.theory = pth;
s.expectedUnderTheory = n*pth;
s.pZeroIfTheory = (1 - pth)^n;
s.nRequiredForPower = ceil(minExp/pth);
s.expectedUnderClaim = n*pth;
s.nRequired = s.nRequiredForPower;
z = (nErr/n - pth)/sqrt(pth*(1 - pth)/n);
s.z = z;
if n*pth < minExp
    s.state = 'insufficient-sample';
    s.detail = sprintf(['theory %.4g predicts %.3g events in %d trials ' ...
        '(P(0 events) = %.3g), below the %g-event power floor: this run supports ' ...
        'nothing and refutes nothing; about %d trials are needed'], ...
        pth, n*pth, n, s.pZeroIfTheory, minExp, s.nRequiredForPower);
elseif abs(z) <= zMax
    s.state = 'sufficient-support';
    s.detail = sprintf('%d/%d = %.4g against theory %.4g: z = %+.2f within +/-%g', ...
        nErr, n, nErr/n, pth, z, zMax);
else
    s.state = 'sufficient-refutation';
    if z > 0
        side = 'MORE events than claimed (excess noise or a scaling bug)';
    else
        side = 'FEWER events than claimed (the noise is smaller than the label)';
    end
    s.detail = sprintf(['%d/%d = %.4g against theory %.4g: z = %+.2f beyond +/-%g -- %s'], ...
        nErr, n, nErr/n, pth, z, zMax, side);
end
end

function w = local_worse(sub)
% FAIL beats UNDETERMINED beats PASS, and among equally severe states the first
% powered judgement is preferred over an unpowered one: a real refutation is not
% softened by one weak point, and a real support is not softened either.
w = sub{1};
for k = 2:numel(sub)
    if local_severity(sub{k}.state) > local_severity(w.state)
        w = sub{k};
    end
end
end

function v = local_severity(state)
switch state
    case 'sufficient-refutation', v = 3;
    case {'insufficient-sample', 'interval-straddles-target', 'criterion-missing'}, v = 2;
    case 'sufficient-support', v = 1;
    otherwise, v = 2;
end
end

function v = local_verdict_of(state)
switch state
    case 'sufficient-support', v = 'PASS';
    case 'sufficient-refutation', v = 'FAIL';
    otherwise, v = 'UNDETERMINED';
end
end

function z = local_z(nErr, n, tgt, pth)
p = (nErr/n - pth)/sqrt(pth*(1 - pth)/n);
if isempty(pth), p = (nErr/n - tgt)/sqrt(tgt*(1 - tgt)/n); end
z = p;
end

function e = local_expected(n, tgt, pth)
if ~isempty(pth), e = n*pth; else, e = n*tgt; end
end

function nn = local_n_required(tgt, pth, L, minExp)
a = -Inf;
if ~isempty(tgt), a = max(a, ceil(log(1 - L)/log(1 - tgt))); end
if ~isempty(pth), a = max(a, ceil(minExp/pth)); end
nn = a;
end

function val = local_get(S, fld, dflt)
if isfield(S, fld) && ~isempty(S.(fld)), val = S.(fld); else, val = dflt; end
end

function zq = local_quantile(L)
zq = abs(sqrt(2)*erfcinv(2*(1 - (1 + L)/2)));      % two-sided normal quantile
end

function [lo, hi] = local_wilson(k, n, zq)
p = k/n;
den = 1 + zq^2/n;
center = (p + zq^2/(2*n))/den;
half = zq/den*sqrt(p*(1 - p)/n + zq^2/(4*n^2));
lo = max(0, center - half);
hi = min(1, center + half);
end
