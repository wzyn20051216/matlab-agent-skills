function r = mas_measure_contract(x, fs, claims)
%MAS_MEASURE_CONTRACT  Grade claimed signal measurements against the record they came from.
%
%   r = mas_measure_contract(x, fs, claims)
%
% x       time record (vector, column-ised internally)
% fs      sampling rate, Hz (positive scalar)
% claims  struct, every field optional but at least one measurement required:
%   .freq     struct('value', 50, 'unit', 'Hz' | 'rad/s')   dominant tone
%   .power    struct('value', 0.25, 'unit', 'linear' | 'dB') mean power
%   .peak     scalar -- peak amplitude claim
%   .rms      scalar -- RMS claim
%   .window   analysis window the claim was made with ('hann' default)
%   .regime   'steady' (default) | 'transient'
%   .expected struct('value', v, 'tolRel', t)  theoretical reference
%   .expectedOf  'power' (default) | 'rms' | 'freq'  what `expected` refers to
%
% Returns
%   r.verdict   PASS | FAIL | UNDETERMINED
%   r.checks    struct array: id, status (pass | fail | na | undetermined), detail
%   r.freqHz / r.freqRadPerSec / r.powerLinear / r.powerDb   canonical units
%   r.ci        confidence intervals on power and dominant frequency
%   r.notes     cellstr
%
% THE CONTRACT THIS ENFORCES
% A number is not a measurement until its units, its window, its regime and its
% uncertainty are stated. Each of those is checked against the record, not
% against itself:
%
% - Hz vs rad/s: one claim, converted to BOTH units; w = 2*pi*f is not a
%   hypothesis, but a claim made in the wrong unit OFTEN IS one -- 628 rad/s
%   typed where 628 Hz was meant is caught by the Nyquist check (628 > fs/2).
% - linear vs dB: the conversion is 10*log10 for POWER. The 20*log10 amplitude
%   convention applied to a power value is a factor-of-2-in-dB error and is
%   flagged when the dB claim disagrees with the record.
% - peak vs RMS: rms <= peak for ANY signal, so a claim that violates it is
%   wrong regardless of waveform (labels swapped). The ratio is reported:
%   sqrt(2) means the claim is consistent with a sinusoid.
% - window: the window-weighted power identity is exact for the stated window,
%   so a power claim is compared against BOTH sum(x.^2.*w.^2)/sum(w.^2) (the
%   identity) and mean(x.^2) (the plain record power), and which one matched is
%   reported -- a claim made with a different window lands in neither.
% - theoretical vs measured: a theoretical value WITHOUT a tolerance is not
%   graded; it returns UNDETERMINED rather than PASS. Missing acceptance
%   criteria never become successes.
% - steady vs transient: for regime='steady' the record must be stationary at
%   the stated confidence -- a first-half/second-half Welch-style comparison on
%   block powers -- or the check fails with the drift printed. regime=
%   'transient' switches the stationarity check OFF (na), it does not silence
%   the rest of the contract.
% - confidence interval: every PASS carries a block t-interval on the power
%   (and on the dominant frequency when each block holds >= 10 cycles of the
%   tone -- with fewer the per-block peak is leakage-biased and the interval
%   would be tight and wrong at the same time). A record too short to yield an
%   interval returns UNDETERMINED -- an uncertainty-free number is not graded
%   as a success.
%
% The single rule behind all of it: 数据能画图不等于测对了. An FFT that renders
% a pretty peak proves only that FFT ran.

if nargin < 3, error('mas_measure_contract:args', 'need x, fs and claims'); end
x = x(:);
N = numel(x);
if N < 32, error('mas_measure_contract:short', 'need at least 32 samples, got %d', N); end
if ~isscalar(fs) || fs <= 0, error('mas_measure_contract:fs', 'fs must be positive'); end
if ~isstruct(claims), error('mas_measure_contract:claims', 'claims must be a struct'); end

L = local_level(claims);
B = local_blocks(claims);
w = local_window(claims);

C = local_check_empty();
notes = {};

% ---- canonical unit conversions -----------------------------------------
r = struct();
[fHz, fRad] = local_freq_pair(claims);
r.freqHz = fHz; r.freqRadPerSec = fRad;
[pLin, pDb] = local_power_pair(claims);
r.powerLinear = pLin; r.powerDb = pDb;
r.claimWindow = w;
r.regime = local_regime(claims);

% ---- data side, from the record itself ----------------------------------
s = mas_spectrum_check(x, fs, struct('window', w));
sRect = mas_spectrum_check(x, fs, struct('window', 'rect'));
df = fs / s.nfft;
pWin = s.powerWindowed;        % identity value for the stated window
pTime = s.powerTime;           % plain record power
r.measured = struct('fPeak', s.fPeak, 'powerWindowed', pWin, ...
    'powerPlain', pTime, 'maxAbs', max(abs(x)), 'fRes', df, ...
    'leakage', s.leakage, 'concentration', s.concentration);

% ---- 1. frequency: unit conversion + Nyquist + data agreement ------------
if isfinite(r.freqHz)
    C = local_check_add(C, 'freqUnits', true, sprintf( ...
        '%.6g Hz == %.6g rad/s (w = 2 pi f)', fHz, fRad));
    if r.freqHz >= fs/2
        fAlias = local_fold(r.freqHz, fs);
        C = local_check_add(C, 'freqNyquist', false, sprintf( ...
            ['claimed %.6g Hz >= Nyquist %.6g Hz: on this record the component ' ...
             'appears folded to %.6g Hz; the claim cannot be verified from x'], ...
            fHz, fs/2, fAlias));
    else
        C = local_check_add(C, 'freqNyquist', true, sprintf( ...
            '%.6g Hz is %.3f of Nyquist (%.6g Hz)', fHz, fHz/(fs/2), fs/2));
    end
    if strcmp(s.leakage, 'HIGH')
        C = local_check_add(C, 'freqVsData', false, sprintf( ...
            ['the record holds %.3f cycles of its dominant tone: the measured ' ...
             'peak is unreliable, so it cannot confirm any claimed frequency'], ...
            s.cycles));
    else
        tolF = max(2*df, 0.01*max(fHz, df));
        devF = abs(s.fPeak - fHz);
        C = local_check_add(C, 'freqVsData', devF <= tolF, sprintf( ...
            'measured peak %.4g Hz vs claimed %.6g Hz (dev %.3g Hz, tol %.3g Hz)', ...
            s.fPeak, fHz, devF, tolF));
    end
end

% ---- 2. power: unit conversion + agreement with the identity -------------
if isfinite(pLin)
    dbFromLinear = 10*log10(max(pLin, realmin));
    C = local_check_add(C, 'powerUnits', true, sprintf( ...
        '%.6g linear == %.4f dB (10 log10; a 20 log10 value would be %.4f dB)', ...
        pLin, pDb, 20*log10(max(pLin, realmin))));
    tolP = local_tol(claims, 'power', 1e-3);
    devWin = abs(pLin - pWin)/max(pWin, eps);
    devTime = abs(pLin - pTime)/max(pTime, eps);
    if devWin <= tolP
        C = local_check_add(C, 'powerVsData', true, sprintf( ...
            'matches the window-weighted power (%.6g) to %.2e [%s]', ...
            pWin, devWin, w));
    elseif devTime <= tolP
        C = local_check_add(C, 'powerVsData', true, sprintf( ...
            ['matches the PLAIN record power (%.6g) to %.2e, not the %s-weighted ' ...
             'power (%.6g): the claim was made without this window'], ...
            pTime, devTime, w, pWin));
        notes{end+1} = sprintf(['power claim matches mean(x.^2) rather than the ' ...
            'windowed identity; taper bias here is %.2e'], abs(pWin-pTime)/pTime);
    else
        C = local_check_add(C, 'powerVsData', false, sprintf( ...
            ['claimed %.6g does not match the record: window-weighted %.6g ' ...
             '(dev %.2e) or plain %.6g (dev %.2e); tolerance %.1e'], ...
            pLin, pWin, devWin, pTime, devTime, tolP));
    end
    if dbFromLinear < -300
        notes{end+1} = 'power claim is numerically zero; dB conversion clamped at realmin';
    end
end

% ---- 3. peak vs RMS ------------------------------------------------------
havePk = isfield(claims, 'peak') && isscalar(claims.peak);
haveRms = isfield(claims, 'rms') && isscalar(claims.rms);
if havePk && haveRms
    ratio = claims.peak / max(claims.rms, realmin);
    if claims.rms > claims.peak
        C = local_check_add(C, 'peakRms', false, sprintf( ...
            ['rms %.6g exceeds peak %.6g: impossible for any signal -- the two ' ...
             'labels are swapped or one value is wrong'], claims.rms, claims.peak));
    else
        C = local_check_add(C, 'peakRms', true, sprintf( ...
            'rms %.6g <= peak %.6g, ratio %.4f%s', claims.rms, claims.peak, ratio, ...
            local_sine_note(ratio)));
    end
end
if havePk
    if claims.peak < r.measured.maxAbs - 10*eps*max(1, r.measured.maxAbs)
        C = local_check_add(C, 'peakVsRecord', false, sprintf( ...
            ['claimed peak %.6g is below a sample the record contains (%.6g): ' ...
             'a sampled peak can never exceed the claimed bound'], ...
            claims.peak, r.measured.maxAbs));
    else
        C = local_check_add(C, 'peakVsRecord', true, sprintf( ...
            'claimed peak %.6g covers the record maximum %.6g', ...
            claims.peak, r.measured.maxAbs));
    end
end
if haveRms
    tolR = local_tol(claims, 'rms', 1e-3);
    devR = abs(claims.rms - sqrt(pWin))/max(sqrt(pWin), eps);
    devRt = abs(claims.rms - sqrt(pTime))/max(sqrt(pTime), eps);
    if devR <= tolR || devRt <= tolR
        C = local_check_add(C, 'rmsVsData', true, sprintf( ...
            'claimed rms %.6g matches the record (dev %.2e windowed / %.2e plain)', ...
            claims.rms, devR, devRt));
    else
        C = local_check_add(C, 'rmsVsData', false, sprintf( ...
            'claimed rms %.6g vs record rms %.6g (windowed) / %.6g (plain)', ...
            claims.rms, sqrt(pWin), sqrt(pTime)));
    end
end

% ---- 4. steady vs transient ---------------------------------------------
pk = local_block_power(x, B);
mA = mean(pk(1:floor(B/2)));
mB = mean(pk(floor(B/2)+1:end));
sA = std(pk(1:floor(B/2)));
sB = std(pk(floor(B/2)+1:end));
sDiff = sqrt(sA^2/(floor(B/2)) + sB^2/(B-floor(B/2)));
if sDiff > 0
    tCrit = local_tcrit(floor(B/2)-1, L);
    driftZ = abs(mA - mB) / sDiff;
else
    tCrit = Inf; driftZ = 0;
end
if strcmp(r.regime, 'steady')
    if driftZ > tCrit
        C = local_check_add(C, 'stationarity', false, sprintf( ...
            ['steady-state claimed but the record drifts: first-half block power ' ...
             '%.4g vs second-half %.4g, %.2f sigma (limit %.2f at %g%%). ' ...
             'Do not read steady metrics from this record, or re-label it transient.'], ...
            mA, mB, driftZ, tCrit, 100*L));
    else
        C = local_check_add(C, 'stationarity', true, sprintf( ...
            'steady-state claim holds: halves differ by %.2f sigma (limit %.2f)', ...
            driftZ, tCrit));
    end
else
    C = local_check_add(C, 'stationarity', 'na', ...
        'regime = transient: stationarity deliberately not asserted');
    notes{end+1} = ['transient regime: a spectrum over the whole record mixes the ' ...
        'transient; leakage and peak metrics apply only to the stated span'];
end

% ---- 5. theoretical vs measured -----------------------------------------
if isfield(claims, 'expected') && isstruct(claims.expected) && isfield(claims.expected, 'value')
    ofKind = 'power';
    if isfield(claims, 'expectedOf') && ischar(claims.expectedOf)
        ofKind = lower(claims.expectedOf);
    end
    switch ofKind
        case 'power', mv = pWin;
        case 'rms',   mv = sqrt(pWin);
        case 'freq',  mv = s.fPeak;
        otherwise, error('mas_measure_contract:expectedOf', 'expectedOf must be power|rms|freq');
    end
    if ~isfield(claims.expected, 'tolRel') || isempty(claims.expected.tolRel)
        C = local_check_add(C, 'expectedVsMeasured', NaN, sprintf( ...
            ['theoretical %s %.6g given WITHOUT a tolerance: the deviation ' ...
             '(measured %.6g, rel %.3e) is reported but NOT graded -- ' ...
             'no acceptance criterion, no PASS'], ...
            ofKind, claims.expected.value, mv, ...
            abs(mv - claims.expected.value)/max(abs(claims.expected.value), eps)));
    else
        relDev = abs(mv - claims.expected.value)/max(abs(claims.expected.value), eps);
        C = local_check_add(C, 'expectedVsMeasured', relDev <= claims.expected.tolRel, ...
            sprintf('%s: theoretical %.6g vs measured %.6g (rel %.3e, tol %.3e)', ...
            ofKind, claims.expected.value, mv, relDev, claims.expected.tolRel));
    end
end

% ---- 6. confidence intervals --------------------------------------------
[ci, ciOk, ciWhy] = local_ci(x, fs, pk, L, w, s.fPeak);
r.ci = ci;
if ciOk
    C = local_check_add(C, 'interval', true, sprintf( ...
        'power %.4g +/- %.4g (%.0f%% block t-interval, %d blocks)%s', ...
        ci.power.mean, ci.power.halfwidth, 100*L, B, local_freq_ci_note(ci)));
else
    C = local_check_add(C, 'interval', NaN, ciWhy);
end

% ---- verdict -------------------------------------------------------------
% Four states, and the distinction between them is the point:
%   pass          -- verified against the record
%   fail          -- contradicted by the record
%   na            -- the contract does not apply here; does NOT drag the verdict
%   undetermined  -- missing evidence or missing criterion; forces UNDETERMINED
% A check that could not be run is never silently promoted to a success.
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
notOk = strcmp(st, 'fail') | strcmp(st, 'undetermined');
r.detail = sprintf('%s: %d pass, %d fail, %d undetermined, %d na', ...
    r.verdict, r.nPass, r.nFail, r.nUndetermined, r.nNa);
if any(notOk)
    r.detail = sprintf('%s (%s)', r.detail, strjoin({C(notOk).id}, ', '));
end
end

% ===========================================================================
function L = local_level(claims)
L = 0.95;
if isfield(claims, 'level') && isscalar(claims.level), L = claims.level; end
end

function B = local_blocks(claims)
B = 12;
if isfield(claims, 'blocks') && isscalar(claims.blocks), B = claims.blocks; end
B = max(4, 2*floor(B/2));
end

function w = local_window(claims)
w = 'hann';
if isfield(claims, 'window') && ischar(claims.window) && ~isempty(claims.window)
    w = claims.window;
end
end

function g = local_regime(claims)
g = 'steady';
if isfield(claims, 'regime') && ischar(claims.regime) && ~isempty(claims.regime)
    g = lower(claims.regime);
end
end

function [fHz, fRad] = local_freq_pair(claims)
fHz = NaN; fRad = NaN;
if ~isfield(claims, 'freq') || ~isstruct(claims.freq), return; end
v = claims.freq.value;
u = 'Hz';
if isfield(claims.freq, 'unit') && ~isempty(claims.freq.unit), u = claims.freq.unit; end
switch lower(u)
    case 'hz',    fHz = v;             fRad = 2*pi*v;
    case 'rad/s', fRad = v;            fHz = v/(2*pi);
    otherwise, error('mas_measure_contract:unit', 'freq.unit must be Hz or rad/s');
end
end

function [pLin, pDb] = local_power_pair(claims)
pLin = NaN; pDb = NaN;
if ~isfield(claims, 'power') || ~isstruct(claims.power), return; end
v = claims.power.value;
u = 'linear';
if isfield(claims.power, 'unit') && ~isempty(claims.power.unit), u = claims.power.unit; end
switch lower(u)
    case 'linear'
        % Only a LINEAR power cannot be negative. A dB power is routinely
        % negative (-3.01 dB IS 0.5 linear) and rejecting it here would make
        % every correctly-written power claim below unity look like an error.
        if v < 0, error('mas_measure_contract:power', 'linear power cannot be negative'); end
        pLin = v; pDb = 10*log10(max(v, realmin));
    case 'db'
        pDb = v; pLin = 10^(v/10);
    otherwise
        error('mas_measure_contract:unit', 'power.unit must be linear or dB');
end
end

function t = local_tol(claims, fld, dflt)
t = dflt;
if isfield(claims, fld) && isstruct(claims.(fld)) && ...
        isfield(claims.(fld), 'tolRel') && isscalar(claims.(fld).tolRel)
    t = claims.(fld).tolRel;
end
end

function f = local_fold(f, fs)
fm = mod(f, fs);
if fm > fs/2, fm = fs - fm; end
f = fm;
end

function s = local_sine_note(ratio)
if abs(ratio - sqrt(2)) <= 0.05*sqrt(2)
    s = ' -- consistent with a sinusoid (sqrt 2)';
elseif ratio < 1.15
    s = ' -- ratio near 1: not a sinusoid, check the two labels describe the same signal';
else
    s = sprintf(' -- ratio implies a crest factor of %.2f', ratio);
end
end

function pk = local_block_power(x, B)
N = numel(x);
e = round(linspace(1, N+1, B+1));
pk = zeros(1, B);
for k = 1:B
    pk(k) = mean(x(e(k):e(k+1)-1).^2);
end
end

function [ci, ok, why] = local_ci(x, fs, pk, L, w, fPeak)
% Block t-interval on the power and, when each block can actually resolve the
% tone, on the dominant frequency. Two gates on the frequency interval, both
% learned from a measured failure: with 83 samples per block (4.15 cycles of a
% 50 Hz tone) the per-block peaks averaged 48.58 Hz -- biased 1.4 Hz LOW by
% window leakage around a fractional cycle -- and the t-interval was a
% confident-looking 48.58 +/- 0.13 Hz for a 50.00 Hz signal. An interval that
% misses the truth while looking tight is worse than no interval, so:
%   >= 64 samples per block  (spectral resolution) and
%   >= 10 cycles of the measured tone per block  (leakage bias below ~0.2 Hz).
% The interval is graded only when blocks hold >= 8 samples (t-statistic basis).
N = numel(x);
B = numel(pk);
ci = struct();
ci.level = L;
ci.blocks = B;
ci.method = 'block t-interval';
ci.power = struct('mean', mean(pk), 'halfwidth', ...
    local_tcrit(B-1, L)*std(pk)/sqrt(B), 'units', 'linear');
ok = N / B >= 8;
why = '';
if ~ok
    why = sprintf(['blocks hold only %.1f samples: the record is too short to ' ...
        'support a t-interval, so uncertainty cannot be quoted and the result ' ...
        'is not graded'], N/B);
    ci.power.note = why;
end
ci.freq = struct('mean', NaN, 'halfwidth', NaN, 'units', 'Hz');
cycPerBlock = fPeak * (N/B) / fs;
if N / B < 64
    ci.freq.note = sprintf(['blocks of %d samples cannot resolve frequency: ' ...
        'only the power interval is reported'], floor(N/B));
elseif cycPerBlock < 10
    ci.freq.note = sprintf(['blocks hold only %.1f cycles of the %.4g Hz tone: ' ...
        'per-block peaks are leakage-biased, so no frequency interval is quoted ' ...
        '(use a longer record or fewer blocks)'], cycPerBlock, fPeak);
else
    fk = zeros(1, B);
    e = round(linspace(1, N+1, B+1));
    for k = 1:B
        sk = mas_spectrum_check(x(e(k):e(k+1)-1), fs, struct('window', w));
        fk(k) = sk.fPeak;
    end
    ci.freq = struct('mean', mean(fk), 'halfwidth', ...
        local_tcrit(B-1, L)*std(fk)/sqrt(B), 'units', 'Hz');
end
end

function s = local_freq_ci_note(ci)
if isfield(ci, 'freq') && isfield(ci.freq, 'mean') && isfinite(ci.freq.mean)
    s = sprintf('; freq %.4g +/- %.4g Hz', ci.freq.mean, ci.freq.halfwidth);
else
    s = '; freq interval not resolvable at this block size';
end
end

function t = local_tcrit(nu, L)
% Two-sided t critical value. Exact table for the default 95% level at the
% small nu this tool actually uses (B/2 - 1 = 5, B - 1 = 11): the
% Cornish-Fisher closed form is 4% low at nu = 3 and a 4%-low threshold on a
% stationarity screen rejects correct records ~1 time in 20 -- the kind of
% flakiness that teaches people to ignore the check. Other levels use the
% closed form, accurate to ~0.1% for nu >= 5.
if abs(L - 0.95) < 1e-12 && nu >= 1 && nu <= 15
    tab = [12.706 4.303 3.182 2.776 2.571 2.447 2.365 2.306 2.262 ...
        2.228 2.201 2.179 2.160 2.145 2.131];
    t = tab(nu);
    return;
end
z = -sqrt(2) * erfcinv(1 + L);
t = z + (z^3 + z)/(4*nu) + (5*z^5 + 16*z^3 + 3*z)/(96*nu^2);
end

function C = local_check_empty()
C = struct('id', {}, 'status', {}, 'detail', {});
end

function C = local_check_add(C, id, pass, detail)
% One funnel for every check so the four-state model cannot drift per call site:
% logical true/false -> pass/fail, NaN -> undetermined, string -> taken as a
% status verbatim ('na').
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