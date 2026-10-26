function r = mas_sample_check(x, fs, opts)
%MAS_SAMPLE_CHECK  Verify the sampling chain: Nyquist margin, alias fold, reconstruction.
%
%   r = mas_sample_check(x, fs, struct('fMax', 200))
%   r = mas_sample_check(x, fs, struct('fMax', 200, 'truth', struct('f', @(t) sin(2*pi*150*t))))
%
% opts fields:
%   .fMax     claimed maximum component frequency of x, Hz. Required for the
%             alias check; without it that check is undetermined, not passed.
%   .truth    struct('f', fnHandle) -- the analytic signal x was sampled from.
%             Enables the reconstruction check; the record is first verified to
%             BE samples of that function before anything is reconstructed.
%   .reconTol relative RMS reconstruction tolerance, default 1e-2
%   .nDense   interpolation factor for the dense grid, default 8
%   .window   analysis window for the spectrum, default 'hann'
%
% r.verdict  PASS | FAIL | UNDETERMINED
% r.checks   id / status (pass|fail|na|undetermined) / detail
% r.measured struct: fPeak, fRes, leakage, topBandFrac, reconRelErr, aliasFoldHz
%
% THE THREE THINGS THIS CHECKS, AND WHY
% 1. Nyquist margin, IN THE UNITS THE CLAIM USES. A claim of "300 Hz content"
%    on a record sampled at 500 Hz is not merely under-sampled: the sampled data
%    contains that component at the FOLDED frequency |300 - 500| = 200 Hz, where
%    it is indistinguishable from a real 200 Hz signal. The folded frequency is
%    printed, because "aliasing occurred" without the fold location is not
%    actionable.
% 2. The measured peak must lie inside the claimed band. If the spectrum shows a
%    tone above fMax (and below Nyquist), the claim understates what is there.
%    Note the asymmetry: the spectrum can CONFIRM content below fMax; it can
%    never rule out content above Nyquist -- that is the point of check 1.
% 3. Reconstruction, when and only when an independent reference exists. The
%    bandlimited interpolation (exact for a periodic, below-Nyquist signal) is
%    compared against the analytic truth on the interior 80% of the record. If
%    the truth is NOT bandlimited below Nyquist, its samples are a valid record
%    but no interpolation can reproduce them -- the error blows up, which is the
%    measurement of aliasing damage rather than an assertion about it.
%
% Before reconstructing, the record is verified to actually BE samples of the
% supplied truth (max deviation <= 1e-9 relative). A reference that does not
% match the data would otherwise grade the reconstruction against the wrong
% function -- a green check for a broken pair.

if nargin < 3, opts = struct(); end
opts = local_dflt(opts, struct('fMax', [], 'truth', [], 'reconTol', 1e-2, ...
    'nDense', 8, 'window', 'hann'));
x = x(:);
N = numel(x);
if N < 32, error('mas_sample_check:short', 'need at least 32 samples, got %d', N); end
if ~isscalar(fs) || fs <= 0, error('mas_sample_check:fs', 'fs must be positive'); end

C = local_check_empty();
notes = {};

s = mas_spectrum_check(x, fs, struct('window', opts.window));
fPeak = s.fPeak;
df = fs / s.nfft;
r_meas = struct('fPeak', fPeak, 'fRes', df, 'leakage', s.leakage, ...
    'concentration', s.concentration, 'aliasFoldHz', NaN, ...
    'topBandFrac', NaN, 'reconRelErr', NaN);

% ---- 1. Nyquist vs the claimed band -------------------------------------
if isempty(opts.fMax)
    C = local_check_add(C, 'nyquist', NaN, ...
        'no fMax claim given: whether this record obeys Nyquist is undetermined');
else
    if opts.fMax <= 0 || opts.fMax >= fs
        error('mas_sample_check:fMax', 'fMax must be in (0, fs)');
    end
    if opts.fMax >= fs/2
        fold = local_fold(opts.fMax, fs);
        r_meas.aliasFoldHz = fold;
        C = local_check_add(C, 'nyquist', false, sprintf( ...
            ['claimed band extends to %.6g Hz with fs = %.6g Hz: above Nyquist ' ...
             '%.6g Hz, so the component at %.6g Hz appears in the samples at ' ...
             '%.6g Hz, where it is indistinguishable from a real signal there'], ...
            opts.fMax, fs, fs/2, opts.fMax, fold));
    else
        C = local_check_add(C, 'nyquist', true, sprintf( ...
            '%.6g Hz band vs Nyquist %.6g Hz: margin %.1f%% of fs', ...
            opts.fMax, fs/2, 100*(fs/2 - opts.fMax)/fs));
    end
end

% ---- 2. measured peak vs the claim --------------------------------------
if strcmp(s.leakage, 'HIGH')
    C = local_check_add(C, 'peakVsClaim', false, sprintf( ...
        ['record holds %.3f cycles of its dominant tone: the measured peak is ' ...
         'unreliable and cannot confirm the claimed band'], s.cycles));
elseif isempty(opts.fMax)
    C = local_check_add(C, 'peakVsClaim', NaN, ...
        'no fMax claim to compare the measured peak against');
else
    tolF = max(2*df, 0.01*opts.fMax);
    if fPeak > opts.fMax + tolF && fPeak < fs/2
        C = local_check_add(C, 'peakVsClaim', false, sprintf( ...
            ['the record contains a component at %.4g Hz, above the claimed ' ...
             'band limit %.6g Hz (+%.3g Hz tolerance): the claim understates ' ...
             'the content'], fPeak, opts.fMax, tolF));
    else
        C = local_check_add(C, 'peakVsClaim', true, sprintf( ...
            'measured peak %.4g Hz lies inside the claimed band %.6g Hz', ...
            fPeak, opts.fMax));
    end
end

% ---- top-band energy (report, not gate) ---------------------------------
topMask = s.f > 0.9*fs/2;
if any(topMask)
    r_meas.topBandFrac = sum(s.psd(topMask)) / max(sum(s.psd), eps);
    if r_meas.topBandFrac > 0.01
        notes{end+1} = sprintf(['%.2f%% of the measured power sits above 0.9*fs/2: ' ...
            'little anti-alias headroom; verify the pre-sampling filter'], ...
            100*r_meas.topBandFrac);
    end
end

% ---- 3. reconstruction vs independent truth ------------------------------
if isempty(opts.truth)
    C = local_check_add(C, 'reconstruction', NaN, ...
        ['no independent reference given: reconstruction is NOT verified ' ...
         '(no truth, no pass)']);
else
    if ~isfield(opts.truth, 'f') || ~isa(opts.truth.f, 'function_handle')
        error('mas_sample_check:truth', 'opts.truth must be struct with .f function handle');
    end
    L = round(opts.nDense);
    if L < 2, error('mas_sample_check:nDense', 'nDense must be >= 2'); end
    tD = (0:N*L-1).'/(fs*L);
    yT = opts.truth.f(tD);
    yT = yT(:);
    % the record must actually be samples of the stated truth
    xRef = opts.truth.f((0:N-1).'/fs);
    devRef = max(abs(x - xRef)) / max(max(abs(xRef)), eps);
    if devRef > 1e-9
        C = local_check_add(C, 'truthMatches', false, sprintf( ...
            ['the record is not samples of the supplied truth: max deviation ' ...
             '%.3e relative. Grading a reconstruction against the wrong ' ...
             'reference would produce a meaningless green'], devRef));
    else
        C = local_check_add(C, 'truthMatches', true, sprintf( ...
            'record equals samples of the supplied truth to %.1e', devRef));
        yR = local_bandlimited_interp(x, L);
        e = round(0.1*N*L):round(0.9*N*L);
        relErr = sqrt(mean((yR(e) - yT(e)).^2)) / max(sqrt(mean(yT(e).^2)), eps);
        r_meas.reconRelErr = relErr;
        C = local_check_add(C, 'reconstruction', relErr <= opts.reconTol, sprintf( ...
            ['bandlimited interpolation vs truth on the interior 80%%: relative ' ...
             'RMS error %.3e (tol %.3e). %s'], relErr, opts.reconTol, ...
            local_tern(relErr <= opts.reconTol, ...
                'consistent with a strictly below-Nyquist signal', ...
                'either the signal is not bandlimited below Nyquist, or the record is not its samples')));
    end
end

% ---- verdict -------------------------------------------------------------
% Four states. The 'undetermined' entries here are all missing-evidence cases
% (no fMax claim, no independent truth): they cannot be verified, so they force
% UNDETERMINED -- they are never silently skipped into a green verdict.
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
r.measured = r_meas;
r.fs = fs;
r.nSamples = N;
r.nChecks = numel(C);
r.nPass = nnz(strcmp(st, 'pass'));
r.nFail = nnz(strcmp(st, 'fail'));
r.nUndetermined = nnz(strcmp(st, 'undetermined'));
r.nNa = nnz(strcmp(st, 'na'));
if r.ok
    r.detail = sprintf('PASS: %d checks (peak %.4g Hz, fs %.6g Hz)', numel(C), fPeak, fs);
else
    notOk = strcmp(st, 'fail') | strcmp(st, 'undetermined');
    r.detail = sprintf('%s: %s', r.verdict, strjoin({C(notOk).id}, ', '));
end
end

% ===========================================================================
function y = local_bandlimited_interp(x, L)
% Exact bandlimited interpolation for a periodic record: zero-pad the spectrum
% symmetrically and scale. Assumes no component exactly at Nyquist (where the
% single Nyquist bin is shared by +fs/2 and -fs/2 and interpolation is ambiguous).
N = numel(x);
X = fft(x(:));
Y = zeros(N*L, 1);
half = floor(N/2);
Y(1:half+1) = X(1:half+1);
Y(N*L - (N - half - 2) : N*L) = X(half+2:end);
y = ifft(Y) * L;
end

function f = local_fold(f, fs)
fm = mod(f, fs);
if fm > fs/2, fm = fs - fm; end
f = fm;
end

function o = local_dflt(o, d)
f = fieldnames(d);
for k = 1:numel(f)
    if ~isfield(o, f{k}), o.(f{k}) = d.(f{k}); end
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

function s = local_tern(c, a, b)
if c, s = a; else, s = b; end
end