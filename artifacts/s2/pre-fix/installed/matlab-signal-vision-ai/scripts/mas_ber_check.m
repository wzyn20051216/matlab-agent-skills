function r = mas_ber_check(nErr, nBits, spec)
%MAS_BER_CHECK  Grade a measured BER against theory the way a count must be graded.
%
%   r = mas_ber_check(588, 262144, struct('scheme','QPSK','ebn0dB',6))
%
% spec fields:
%   .scheme   'BPSK' | 'QPSK' (exact) | 'QAM16' | 'QAM64' (Gray approximation)
%   .ebn0dB   Eb/N0 of the measurement, dB    (required unless .esn0dB given)
%   .esn0dB   Es/N0, dB; if both are given they must agree through
%             Es/N0 = Eb/N0 + 10 log10(k). A 3.01 dB disagreement for QPSK is
%             the classic "Es/N0 labelled Eb/N0" defect and fails here.
%   .level    confidence level for the interval, default 0.95
%   .zMax     |z| acceptance limit against counting noise, default 3
%   .theory   function handle f(ebn0Lin) -> BER, overrides the built-in formula
%   .targetBer  largest BER the claim allows. When present, the graded claim is
%             "BER <= targetBer" and r.state comes from that claim; the theory
%             comparison stays as its own check either way.
%
% r.verdict  PASS | FAIL | UNDETERMINED
% r.state    the five-state evidence label from mas_stat_verdict:
%            sufficient-support | sufficient-refutation | insufficient-sample |
%            interval-straddles-target | criterion-missing
% r.checks   id / status (pass|fail|na|undetermined) / detail
% r.z        (p_hat - p_theory) / sqrt(p(1-p)/n); the whole test in one number
% r.ci       Wilson score interval at the stated level, plus a Poisson upper
%            bound for the zero-error case
%
% WHY A z-TEST AND NOT A TOLERANCE
% A BER is a count, not an amplitude. Grading it with a flat 15 % tolerance
% gets BOTH directions wrong: at BER 1e-4 over 1e6 bits (~100 errors) the
% counting noise alone is 10 %, so the tolerance is slack where it should be
% tight; at BER 1e-5 (~10 errors) it is 30 %, so the tolerance rejects correct
% measurements. The z-score against the binomial spread rejects a real scaling
% defect (a 3 dB Eb/N0 convention error moves the QPSK BER by more than
% 10x around 5 dB) while accepting honest counting scatter.
%
% ZERO ERRORS IS NOT "BER = 0"
% With 0 counted errors over n bits the data are consistent with any p up to
% ~3/n; the tool reports that Poisson upper bound and REFUSES to certify a
% rate the measurement cannot see. If theory predicts more than ~3/n errors,
% the zero count is itself a strong z-deviation (noise lower than claimed).

if nargin < 3, error('mas_ber_check:args', 'need nErr, nBits and spec'); end
if ~isscalar(nErr) || ~isscalar(nBits) || nBits < 1 || nErr < 0 || nErr > nBits
    error('mas_ber_check:counts', 'need 0 <= nErr <= nBits, nBits >= 1');
end
if ~isstruct(spec), error('mas_ber_check:spec', 'spec must be a struct'); end

S = spec;
if ~isfield(S, 'scheme') || isempty(S.scheme), S.scheme = 'QPSK'; end
S.scheme = upper(S.scheme);
k = local_bitsper(S.scheme);
C = local_check_empty();
notes = {};

L = 0.95;
if isfield(S, 'level') && isscalar(S.level), L = S.level; end
zMax = 3;
if isfield(S, 'zMax') && isscalar(S.zMax), zMax = S.zMax; end
haveTargetBer = isfield(S, 'targetBer') && isscalar(S.targetBer) && ...
    S.targetBer > 0 && S.targetBer <= 1;

% ---- Eb/N0 vs Es/N0 ------------------------------------------------------
haveEb = isfield(S, 'ebn0dB') && isscalar(S.ebn0dB);
haveEs = isfield(S, 'esn0dB') && isscalar(S.esn0dB);
if ~haveEb && ~haveEs
    error('mas_ber_check:spec', 'spec.ebn0dB (or esn0dB) is required');
end
if haveEb && haveEs
    expectedEb = S.esn0dB - 10*log10(k);
    dDb = abs(S.ebn0dB - expectedEb);
    if dDb <= 0.05
        C = local_check_add(C, 'convention', true, sprintf( ...
            ['Eb/N0 %.4g and Es/N0 %.4g agree through k = %d (%.4g dB): ' ...
             'consistent conventions'], S.ebn0dB, S.esn0dB, k, 10*log10(k)));
        ebn0dB = S.ebn0dB;
    else
        C = local_check_add(C, 'convention', false, sprintf( ...
            ['Eb/N0 %.4g dB and Es/N0 %.4g dB disagree by %.4g dB; with k = %d ' ...
             'bits/symbol the gap must be %.4g dB. A 3.01 dB gap at k = 2 is ' ...
             'Es/N0 labelled as Eb/N0 -- the BER tables will not match'], ...
            S.ebn0dB, S.esn0dB, abs(S.ebn0dB - S.esn0dB), k, 10*log10(k)));
        ebn0dB = S.ebn0dB;
    end
elseif haveEs
    ebn0dB = S.esn0dB - 10*log10(k);
    C = local_check_add(C, 'convention', true, sprintf( ...
        ['Es/N0 %.4g dB converted with k = %d to Eb/N0 %.4g dB'], ...
        S.esn0dB, k, ebn0dB));
else
    ebn0dB = S.ebn0dB;
    C = local_check_add(C, 'convention', true, sprintf( ...
        'Eb/N0 %.4g dB taken as given (k = %d, Es/N0 would be %.4g dB)', ...
        ebn0dB, k, ebn0dB + 10*log10(k)));
end

% ---- theory --------------------------------------------------------------
ebn0Lin = 10^(ebn0dB/10);
if isfield(S, 'theory') && isa(S.theory, 'function_handle')
    p0 = S.theory(ebn0Lin);
    theoryExact = true;
    notes{end+1} = 'theoretical reference supplied by the caller (function handle)';
else
    [p0, theoryExact] = local_theory(S.scheme, ebn0Lin);
end
if ~isfinite(p0) || p0 <= 0 || p0 > 1
    error('mas_ber_check:theory', 'theory BER %.4g is not in (0,1]', p0);
end
if ~theoryExact
    notes{end+1} = [S.scheme ' uses the standard Gray-mapped high-SNR approximation; ' ...
        'below ~4 dB Eb/N0 the true BER departs from it'];
end

% ---- the measurement -----------------------------------------------------
phat = nErr / nBits;
zq = -sqrt(2)*erfcinv(2*(1 - (1+L)/2));           % two-sided normal quantile
zq = abs(zq);
den = 1 + zq^2/nBits;
center = (phat + zq^2/(2*nBits)) / den;
half = zq/den * sqrt(phat*(1-phat)/nBits + zq^2/(4*nBits^2));
ciLo = max(0, center - half);
ciHi = min(1, center + half);

z = (phat - p0) / sqrt(p0*(1-p0)/nBits);
C = local_check_add(C, 'measuredRange', phat >= 0 && phat <= 1, sprintf( ...
    '%d errors in %d bits -> BER %.6g (%.4g%% of bits counted)', ...
    nErr, nBits, phat, 100*phat));

if nErr == 0
    poissonUp = -log(1-L)/nBits;                  % one-sided upper bound, no errors
    C = local_check_add(C, 'zeroErrors', true, sprintf( ...
        ['0 errors is consistent with any BER up to %.3g at %g%%: a zero count ' ...
         'certifies an upper bound, never the rate 0'], poissonUp, 100*L));
    notes{end+1} = sprintf('zero-error run: report BER <= %.3g, not 0', poissonUp);
else
    poissonUp = NaN;
end

width = ciHi - ciLo;
if haveTargetBer && width > 0.5*p0 && width > 2*phat
    % The run resolves the TARGET, not the theory. With an explicit targetBer the
    % claim is graded against that number, so the theory-resolution gate does not
    % apply -- letting it fire would demote a genuinely certified bound.
    C = local_check_add(C, 'resolution', 'na', sprintf(['interval width %.3g cannot separate ' ...
        'the theory %.3g from a 2x-different one, but the graded claim is BER <= %.4g, which ' ...
        'this interval does decide'], width, p0, S.targetBer));
elseif width > 0.5*p0 && width > 2*phat
    C = local_check_add(C, 'resolution', NaN, sprintf( ...
        ['interval width %.3g is comparable to the theory %.3g: this run cannot ' ...
         'distinguish the claimed SNR from a 2x different one; collect more bits ' ...
         'before grading'], width, p0));
else
    C = local_check_add(C, 'resolution', true, sprintf( ...
        'interval [%.3g, %.3g] resolves the theory %.3g (width/tau = %.2f)', ...
        ciLo, ciHi, p0, width/p0));
end

C = local_check_add(C, 'vsTheory', abs(z) <= zMax, sprintf( ...
    ['measured %.3g vs theory %.3g: z = %+.2f (limit +/-%g) -- %s' ...
     '%s'], phat, p0, z, zMax, ...
    local_tern(abs(z) <= zMax, 'within counting noise', 'BEYOND counting noise'), ...
    local_theory_side(phat, p0, z, zMax)));

% ---- the five-state evidence flow ---------------------------------------
% The counted claim itself is decided by mas_stat_verdict, so every count-based
% measurement in this skill follows one rule: a run with no power to see the rate
% it is grading is INCONCLUSIVE, not a refutation, and a zero count that does
% clear a stated target is evidence, not an absence of news. The convention and
% z checks above keep failing real defects independently of this.
if haveTargetBer
    svSpec = struct('criterion', 'meets-target', 'target', S.targetBer, ...
        'level', L, 'zMax', zMax);
    claimTxt = sprintf('BER <= %.4g', S.targetBer);
else
    svSpec = struct('criterion', 'matches-theory', 'theory', p0, ...
        'level', L, 'zMax', zMax);
    claimTxt = sprintf('BER == %.4g (theory)', p0);
end
sv = mas_stat_verdict(nErr, nBits, svSpec);
C = local_check_add(C, 'evidence', local_state_status(sv.state), sprintf( ...
    'claim %s -> %s: %s', claimTxt, sv.state, sv.detail));

% ---- verdict -------------------------------------------------------------
% 'resolution' and an unpowered 'evidence' state are the undetermined drivers:
% when the collected interval cannot separate the theory from a 2x-different one,
% the run is not evidence either way and the verdict must say so rather than
% guess.
st = {C.status};
if any(strcmp(st, 'fail'))
    r.verdict = 'FAIL';
elseif any(strcmp(st, 'undetermined'))
    r.verdict = 'UNDETERMINED';
else
    r.verdict = 'PASS';
end
r.ok = strcmp(r.verdict, 'PASS');
r.scheme = S.scheme;
r.k = k;
r.ebn0dB = ebn0dB;
r.esn0dB = ebn0dB + 10*log10(k);
r.nErr = nErr;
r.nBits = nBits;
r.berMeasured = phat;
r.berTheory = p0;
r.z = z;
r.zMax = zMax;
r.theoryIsExact = theoryExact;
r.state = sv.state;
r.evidence = sv;
r.sigmaRel = 1/sqrt(max(nErr, 1));               % relative counting noise
r.ci = struct('level', L, 'method', 'Wilson score', 'lo', ciLo, 'hi', ciHi, ...
    'poissonUpper', poissonUp);
r.checks = C;
r.notes = notes;
r.nChecks = numel(C);
r.nPass = nnz(strcmp(st, 'pass'));
r.nFail = nnz(strcmp(st, 'fail'));
r.nUndetermined = nnz(strcmp(st, 'undetermined'));
r.nNa = nnz(strcmp(st, 'na'));
if r.ok
    r.detail = sprintf(['PASS: %s @ %.4g dB Eb/N0, BER %.3g (theory %.3g, ' ...
        'z = %+.2f, %g%% CI [%.3g, %.3g])'], ...
        S.scheme, ebn0dB, phat, p0, z, 100*L, ciLo, ciHi);
else
    notOk = strcmp(st, 'fail') | strcmp(st, 'undetermined');
    r.detail = sprintf('%s: %s | measured %.3g vs theory %.3g, z = %+.2f', ...
        r.verdict, strjoin({C(notOk).id}, ', '), phat, p0, z);
end
end

% ===========================================================================
function k = local_bitsper(scheme)
switch scheme
    case 'BPSK',  k = 1;
    case 'QPSK',  k = 2;
    case 'QAM16', k = 4;
    case 'QAM64', k = 6;
    otherwise
        error('mas_ber_check:scheme', ...
            'unsupported scheme %s; provide spec.theory for custom schemes', scheme);
end
end

function [p, exact] = local_theory(scheme, ebn0Lin)
% BPSK/QPSK: Pb = 0.5 erfc(sqrt(Eb/N0)), exact.
% Square Gray-mapped M-QAM (Proakis): Pb = (4/k)(1 - 1/sqrt(M)) Q(sqrt(3k/(M-1) Eb/N0)),
% i.e. in erfc form (4/k)(1 - 1/sqrt(M)) * 0.5 * erfc(sqrt(3k/(2(M-1)) Eb/N0)).
% At M=4 this reproduces the QPSK result exactly; at M=16/64 it is the standard
% high-SNR approximation.
switch scheme
    case {'BPSK', 'QPSK'}
        p = 0.5*erfc(sqrt(ebn0Lin));
        exact = true;
    case 'QAM16'
        M = 16; k = 4;
        p = (4/k)*(1 - 1/sqrt(M))*0.5*erfc(sqrt(3*k/(2*(M-1))*ebn0Lin));
        exact = false;
    case 'QAM64'
        M = 64; k = 6;
        p = (4/k)*(1 - 1/sqrt(M))*0.5*erfc(sqrt(3*k/(2*(M-1))*ebn0Lin));
        exact = false;
    otherwise
        error('mas_ber_check:scheme', 'unsupported scheme %s', scheme);
end
end

function s = local_theory_side(phat, p0, z, zMax) %#ok<INUSD>
% Direction matters for diagnosis: more errors than theory means too little SNR
% or a scaling bug (noise variance too large); fewer means the noise is SMALLER
% than claimed, which is just as wrong and often means the SNR convention is off.
if abs(z) <= zMax
    s = '';
elseif z > 0
    s = ' [MORE errors than theory: excess noise or a variance scaling bug]';
else
    s = ' [FEWER errors than theory: the noise is smaller than the SNR label claims]';
end
end

function C = local_check_empty()
C = struct('id', {}, 'status', {}, 'detail', {});
end

function st = local_state_status(state)
% Feed the five-state flow into the check list without letting it invent a
% verdict: support passes, refutation fails, the three inconclusive states are
% reported as undetermined, which the existing gate turns into UNDETERMINED.
switch state
    case 'sufficient-support', st = true;
    case 'sufficient-refutation', st = false;
    otherwise, st = NaN;
end
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

function s = local_tern(c, a, b)
if c, s = a; else, s = b; end
end