function r = mas_filter_check(b, a, spec)
%MAS_FILTER_CHECK  Grade a designed FIR/IIR filter against its stated spec.
%
%   r = mas_filter_check(b, a, spec)
%
% spec fields:
%   .fs         required, Hz
%   .type       'lowpass' (default) | 'highpass'
%   .fpass      required, passband edge Hz
%   .fstop      required, stopband edge Hz
%   .astopDb    required, minimum stopband attenuation, dB
%   .apassDb    optional, maximum passband ripple, dB; absent -> not graded (na)
%   .requireLinearPhase  optional logical, default false
%
% r.verdict  PASS | FAIL | UNDETERMINED
% r.checks   id / status (pass|fail|na|undetermined) / detail
% r.achieved struct: maxPoleMag, stopbandDb, passbandRippleDb, edgeGainDb, ...
%
% WHAT IS ACTUALLY VERIFIED
% The specification is never taken from the same code that produced the
% filter, and the response is evaluated on TWO independent routes:
%
% - `freqz` is the standard route, but it is DFT-based and it silently changes
%   meaning without `fs` (its w is then rad/SAMPLE). The second route evaluates
%   H(z) = sum(b_k z^-k)/sum(a_k z^-k) directly as a polynomial sum at
%   z = exp(jw) -- different code path, same physics. A mismatch means one of
%   the two is being misused, typically the unit convention.
% - IIR stability is decided by the poles of the denominator polynomial, and
%   the margin 1 - max|p| is printed: a pole at 0.9999 is "stable" only until
%   the coefficients are rounded.
% - the stopband number is the WORST response over [fstop, fs/2], evaluated on
%   a dense grid -- not the value at a token frequency. A design that meets the
%   spec at fstop but humps 6 dB higher at 0.7*fs/2 fails here.
% - phase: a symmetric FIR has linear phase and its measured group delay must
%   equal (N-1)/2 samples; that is checked against the response, not inferred
%   from the coefficient vector alone. Non-symmetric filters report their
%   measured group-delay variation; linear phase is only graded when the spec
%   demands it (requireLinearPhase), because "not required" is not "passed".
%
% A note on fs: every frequency in spec is Hz, and the response grid is built
% in Hz. The classic trap this closes is comparing a design done in normalized
% units (w = 0.4 of Nyquist) against a spec written in Hz (400 Hz at fs = 1000
% is ALSO 0.4 of Nyquist, but at fs = 4000 it is not).

if nargin < 3, error('mas_filter_check:args', 'need b, a and spec'); end
b = b(:).'; a = a(:).';
if isempty(b) || any(~isfinite(b)) || any(~isfinite(a))
    error('mas_filter_check:coeffs', 'b and a must be finite non-empty vectors');
end
if abs(a(1)) < eps
    error('mas_filter_check:coeffs', 'a(1) is zero'); 
end

S = local_spec(spec);
fs = S.fs;
C = local_check_empty();
notes = {};
if abs(a(1) - 1) > 1e-12
    notes{end+1} = sprintf(['a(1) = %.12g ~= 1: the response is evaluated as ' ...
        'given; most design functions return a(1) = 1'], a(1));
end

% ---- spec sanity ---------------------------------------------------------
if S.fpass <= 0 || S.fstop <= 0 || S.fpass >= fs/2 || S.fstop >= fs/2
    error('mas_filter_check:spec', 'fpass and fstop must lie inside (0, fs/2)');
end
if strcmp(S.type, 'lowpass') && S.fpass >= S.fstop
    error('mas_filter_check:spec', 'lowpass needs fpass < fstop');
end
if strcmp(S.type, 'highpass') && S.fstop >= S.fpass
    error('mas_filter_check:spec', 'highpass needs fstop < fpass');
end

% ---- route 1: freqz, Hz grid --------------------------------------------
K = 4096;
fGrid = linspace(0, fs/2, K).';
H1 = freqz(b, a, fGrid, fs);              % fs given: w in Hz, not rad/sample

% ---- route 2: direct polynomial evaluation at z = exp(j 2 pi f / fs) -----
H2 = zeros(K, 1);
nb = numel(b); na = numel(a);
for q = 1:K
    zi = exp(-1j*2*pi*fGrid(q)/fs);
    H2(q) = sum(b .* zi.^(0:nb-1)) / sum(a .* zi.^(0:na-1));
end
scale = max(abs(H1));
routeErr = max(abs(H1 - H2)) / max(scale, realmin);
C = local_check_add(C, 'responseRoutes', routeErr < 1e-9, sprintf( ...
    'freqz(Hz) vs direct z-expansion agree to %.2e (limit 1e-9)', routeErr));

% ---- stability (IIR) -----------------------------------------------------
if na > 1
    p = roots(a);
    maxPole = max(abs(p));
    r_pole = maxPole;
    if maxPole >= 1
        nearBoundary = abs(maxPole - 1) < 1e-6;
        C = local_check_add(C, 'stability', false, sprintf( ...
            ['max |pole| = %.6g >= 1: the IIR filter is %s (unstable); ' ...
             'a designed filter must have all poles strictly inside the unit circle'], ...
            maxPole, local_tern(nearBoundary, 'on the stability boundary', 'unstable')));
    else
        C = local_check_add(C, 'stability', true, sprintf( ...
            'max |pole| = %.6g, margin %.2e inside the unit circle', ...
            maxPole, 1 - maxPole));
        if 1 - maxPole < 1e-3
            notes{end+1} = sprintf(['max |pole| = %.6f is within 1e-3 of the ' ...
                'boundary: stable, but coefficient rounding can break it'], maxPole);
        end
    end
else
    maxPole = 0;
    r_pole = 0;
end

% ---- passband ripple -----------------------------------------------------
if strcmp(S.type, 'lowpass')
    pb = fGrid <= S.fpass;
    sb = fGrid >= S.fstop;
    pbF = [0 S.fpass]; sbIn = [S.fstop fs/2];
else
    pb = fGrid >= S.fpass;
    sb = fGrid <= S.fstop;
    pbF = [S.fpass fs/2]; sbIn = [0 S.fstop];
end
magDb = 20*log10(max(abs(H1), realmin));
pbMax = max(abs(H1(pb))); pbMin = min(abs(H1(pb)));
rippleDb = 20*log10(pbMax / max(pbMin, realmin));
r_ripple = rippleDb;
if isfield(S, 'apassDb') && ~isempty(S.apassDb)
    C = local_check_add(C, 'passbandRipple', rippleDb <= S.apassDb + 1e-9, sprintf( ...
        ['passband %.6g-%.6g Hz ripple %.4f dB (limit %.4f dB), deviation ' ...
         'from unity %.2e'], pbF(1), pbF(2), rippleDb, S.apassDb, max(abs(abs(H1(pb)) - 1))));
else
    C = local_check_add(C, 'passbandRipple', 'na', sprintf( ...
        ['passband ripple measured %.4f dB but the spec states no apassDb: ' ...
         'not graded (no criterion, no pass)'], rippleDb));
end

% ---- stopband, worst over the whole band ---------------------------------
sbMax = max(abs(H1(sb)));
sbDb = -20*log10(max(sbMax, realmin));
r_stop = sbDb;
C = local_check_add(C, 'stopband', sbDb >= S.astopDb - 1e-9, sprintf( ...
    'worst attenuation over %.6g-%.6g Hz is %.2f dB (spec >= %.2f dB)%s', ...
    sbIn(1), sbIn(2), sbDb, S.astopDb, local_worst_note(fGrid, abs(H1), sb)));

% ---- edge gain (report what actually happens at the corners) -------------
r_edge = magDb(find(fGrid >= S.fpass, 1, 'first'));
notes{end+1} = sprintf('|H| at the passband edge %.6g Hz is %.2f dB', ...
    S.fpass, r_edge);

% ---- phase / group delay -------------------------------------------------
% Two distinctions the first version got wrong:
% 1. Symmetry of b alone does not make the FILTER linear-phase -- an IIR with a
%    symmetric numerator and a non-trivial denominator is not. The check is
%    therefore gated on the filter being FIR (a == 1); a measured group delay
%    that misses (N-1)/2 because a denominator is present is a property of IIR
%    design, not a defect, and must not be graded 'fail' when the spec never
%    asked for linear phase.
% 2. Antisymmetric FIRs (types III/IV) are linear-phase too, so both parities
%    of symmetry are accepted as the linear-phase form.
symTol = 1e-8 * max(abs(b));
symmetric = (max(abs(b - fliplr(b))) <= symTol);
antisym = (max(abs(b + fliplr(b))) <= symTol);
isFIR = na == 1;
gdAtPass = NaN; gdVar = NaN;
if strcmp(S.type, 'lowpass')
    fInt = linspace(0.1, 0.9, 256) * S.fpass;                 % 0.1..0.9 of the passband
else
    fInt = S.fpass + linspace(0.1, 0.9, 256) * (fs/2 - S.fpass);
end
wInt = 2*pi*fInt/fs;
Hw = zeros(1, numel(wInt));
for q = 1:numel(wInt)
    zi = exp(-1j*wInt(q));
    Hw(q) = sum(b .* zi.^(0:nb-1)) / sum(a .* zi.^(0:na-1));
end
ph = unwrap(angle(Hw));
gd = -diff(ph) ./ diff(wInt);           % samples
gdAtPass = mean(gd);
gdVar = max(gd) - min(gd);
if isFIR && (symmetric || antisym)
    expectedGd = (nb - 1)/2;
    if abs(gdAtPass - expectedGd) > 1e-6*(1 + expectedGd)
        C = local_check_add(C, 'phaseLinear', false, sprintf( ...
            'group delay %.6g does not match (N-1)/2 = %.6g for a symmetric FIR', ...
            gdAtPass, expectedGd));
    else
        C = local_check_add(C, 'phaseLinear', true, sprintf( ...
            ['%s FIR (type %s): group delay %.6g samples over the passband, ' ...
             'variation %.2e; expected (N-1)/2 = %.6g'], ...
            local_tern(symmetric, 'symmetric', 'antisymmetric'), ...
            local_fir_type(b, symmetric), gdAtPass, gdVar, expectedGd));
    end
elseif S.requireLinearPhase
    if isFIR
        whyStr = 'b is neither symmetric nor antisymmetric';
    else
        whyStr = sprintf('the denominator (max |pole| %.4g) makes exact linear phase impossible', maxPole);
    end
    C = local_check_add(C, 'phaseLinear', false, sprintf( ...
        ['spec requires linear phase but %s: an asymmetric FIR or an IIR cannot ' ...
         'meet it exactly (measured group delay %.4g, variation %.4g samples)'], ...
        whyStr, gdAtPass, gdVar));
else
    if isFIR
        whyStr = 'b is neither symmetric nor antisymmetric';
    else
        whyStr = 'IIR: linear phase is impossible with this denominator';
    end
    C = local_check_add(C, 'phaseLinear', 'na', sprintf( ...
        ['%s; linear phase not required by spec, so not graded. Measured group ' ...
         'delay %.4g with variation %.4g samples over the passband'], ...
        whyStr, gdAtPass, gdVar));
end

% ---- verdict -------------------------------------------------------------
% Four states: a check that could not run ('na' only when the spec itself
% states no such requirement) never becomes a success, and a missing criterion
% ('undetermined') forces the verdict rather than being skipped.
st = {C.status};
if any(strcmp(st, 'fail'))
    r.verdict = 'FAIL';
elseif any(strcmp(st, 'undetermined'))
    r.verdict = 'UNDETERMINED';
else
    r.verdict = 'PASS';
end
r.ok = strcmp(r.verdict, 'PASS');
r.checks = C;
r.notes = notes;
r.nChecks = numel(C);
r.nPass = nnz(strcmp(st, 'pass'));
r.nFail = nnz(strcmp(st, 'fail'));
r.nUndetermined = nnz(strcmp(st, 'undetermined'));
r.nNa = nnz(strcmp(st, 'na'));
r.order = nb - 1;
r.iir = na > 1;
r.spec = S;
r.achieved = struct('maxPoleMag', r_pole, 'passbandRippleDb', r_ripple, ...
    'stopbandDb', r_stop, 'edgeGainDb', r_edge, ...
    'groupDelaySamples', gdAtPass, 'groupDelayVarSamples', gdVar);
r.f = fGrid; r.magDb = magDb;
notOk = strcmp(st, 'fail') | strcmp(st, 'undetermined');
if ~any(notOk)
    r.detail = sprintf('PASS: %d checks (%d na), stopband %.1f dB, ripple %.2f dB, %s', ...
        numel(C), r.nNa, r_stop, r_ripple, local_tern(r.iir, sprintf('max pole %.4g', r_pole), ...
        sprintf('FIR order %d', r.order)));
else
    r.detail = sprintf('%s: %s', r.verdict, strjoin({C(notOk).id}, ', '));
end
end

% ===========================================================================
function S = local_spec(spec)
if ~isstruct(spec), error('mas_filter_check:spec', 'spec must be a struct'); end
S = spec;
if ~isfield(S, 'fs') || ~isscalar(S.fs) || S.fs <= 0
    error('mas_filter_check:spec', 'spec.fs must be a positive scalar');
end
for f = {'fpass', 'fstop', 'astopDb'}
    if ~isfield(S, f{1}) || ~isscalar(S.(f{1}))
        error('mas_filter_check:spec', 'spec.%s is required', f{1});
    end
end
if ~isfield(S, 'type') || isempty(S.type), S.type = 'lowpass'; end
S.type = lower(S.type);
if ~any(strcmp(S.type, {'lowpass', 'highpass'}))
    error('mas_filter_check:spec', 'type must be lowpass or highpass');
end
S.requireLinearPhase = isfield(S, 'requireLinearPhase') && logical(S.requireLinearPhase);
end

function t = local_fir_type(b, symFlag)
% Standard linear-phase FIR taxonomy. Type parity decides whether Nyquist and
% DC are carried; misidentifying it is how a type-II highpass gets designed and
% silently has zero gain at fs/2. symFlag says whether the filter is symmetric
% (I/II) or antisymmetric (III/IV); the caller has already established it is one
% of the two.
evenLen = mod(numel(b), 2) == 0;
if symFlag
    t = local_tern(evenLen, 'II (even length, symmetric: zero at Nyquist)', ...
        'I (odd length, symmetric: full-band)');
else
    t = local_tern(evenLen, 'IV (even length, antisymmetric)', 'III (odd length, antisymmetric)');
end
end

function s = local_worst_note(fGrid, mag, sb)
[~, im] = max(mag .* sb);
s = sprintf('; worst point %.4g Hz', fGrid(im));
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

function s = local_tern(c, a, b)
if c, s = a; else, s = b; end
end