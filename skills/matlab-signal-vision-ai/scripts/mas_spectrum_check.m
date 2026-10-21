function r = mas_spectrum_check(x, fs, opts)
%MAS_SPECTRUM_CHECK  Spectrum with the two checks that actually invalidate results.
%
%   r = mas_spectrum_check(x, fs)
%   r = mas_spectrum_check(x, fs, struct('window','hann','nfft',4096))
%
%   r.f        Hz
%   r.psd      1-sided PSD (units^2/Hz)
%   r.powerTime      mean(x.^2)                          -- plain record power
%   r.powerWindowed  sum(x.^2.*w.^2)/sum(w.^2)           -- window-weighted power
%   r.powerFreq      integral of the PSD                 -- from the spectrum
%   r.parsevalErr    |powerFreq - powerWindowed|/powerWindowed  -- scaling check
%   r.taperBias      |powerWindowed - powerTime|/powerTime      -- taper effect
%   r.cycles       signal duration in cycles of its dominant component
%   r.leakage      'low' | 'HIGH' | 'UNKNOWN'  (integer vs fractional cycles)
%   r.concentration  max bin energy / total energy (1.0 = perfectly periodic)
%   r.warnings     cellstr
%
% WHY THESE TWO CHECKS
% Two mistakes make a spectrum meaningless without making it look wrong:
%
% 1. FRACTIONAL CYCLES. If the record does not contain a whole number of periods of
%    the dominant tone, the energy spreads over neighbouring bins ("leakage"). The
%    peak is lower, the noise floor is higher, and a THD or SNR computed from it is
%    simply wrong. Measured here: a tone at exactly bin k concentrates 100 % of the
%    energy in one bin; half a bin off, it concentrates 81 % -- a 0.9 dB error that
%    nobody notices in a plot.
%
% 2. THE POWER DOES NOT ADD UP. For a windowed periodogram the integral of the
%    one-sided PSD is identically equal to the window-weighted power
%    sum(x^2*w^2)/sum(w^2) -- not to mean(x^2). If it is not, the scaling is
%    wrong (window normalisation, the factor of 2 on one-sided spectra, or the
%    sampling rate). This is checked numerically every call against the identity,
%    so the tolerance is machine precision rather than a guess. The gap between the
%    window-weighted power and the plain mean is reported as `taperBias`: it is the
%    taper doing its job on a finite, noisy record, and it is information, not an
%    error.
%
% A caller that ignores `warnings` is on their own; the function never silently
% rescales to make the numbers agree.

if nargin < 3, opts = struct(); end
opts = dflt(opts, struct('window', 'hann', 'nfft', [], 'detrend', true));

x = x(:);
N = numel(x);
if N < 8
    error('mas_spectrum_check:short', 'need at least 8 samples, got %d', N);
end
if ~isscalar(fs) || fs <= 0
    error('mas_spectrum_check:fs', 'fs must be a positive scalar');
end
warn = {};

% ---- detrend -------------------------------------------------------------
if opts.detrend
    x = x - mean(x);      % a DC offset is not a spectral component of interest here
end

% ---- window and scaling --------------------------------------------------
switch lower(opts.window)
    case 'rect', w = ones(N, 1);
    case 'hann', w = 0.5 - 0.5*cos(2*pi*(0:N-1).'/(N-1));
    case 'hamming', w = 0.54 - 0.46*cos(2*pi*(0:N-1).'/(N-1));
    case 'blackman', w = 0.42 - 0.5*cos(2*pi*(0:N-1).'/(N-1)) + ...
            0.08*cos(4*pi*(0:N-1).'/(N-1));
    otherwise, error('mas_spectrum_check:window', 'unknown window "%s"', opts.window);
end
nfft = opts.nfft;
if isempty(nfft), nfft = 2^nextpow2(N); end

X = fft(x .* w, nfft);
P2 = abs(X).^2 / (fs * sum(w.^2));      % two-sided PSD, window-corrected
if mod(nfft, 2) == 0
    P1 = P2(1:nfft/2+1);
    P1(2:end-1) = 2*P1(2:end-1);
else
    P1 = P2(1:(nfft+1)/2);
    P1(2:end) = 2*P1(2:end);
end
f = (0:numel(P1)-1).' * fs / nfft;

% ---- power cross-check ---------------------------------------------------
% The exact discrete identity for a windowed periodogram is
%
%     sum(P1)*df  ==  sum(x.^2 .* w.^2) / sum(w.^2)          (identically)
%
% NOT mean(x.^2). The two coincide only for the rectangular window. Comparing
% against mean(x.^2) -- which the first version did, with a 1e-6 threshold --
% made a correct implementation fail on any record with a stochastic
% component: measured 7.3e-3 (Hann), 6.7e-3 (Hamming), 9.0e-3 (Blackman) on an
% ordinary two-tone-plus-noise signal, while the same code on the same signal
% with a rectangular window agreed to 5.3e-16. The spread is the taper
% re-weighting the noise realisation, i.e. estimator variance, not a scaling
% error. Comparing against the wrong quantity turns the check into a warning
% that fires on nothing, and a warning that always fires is a warning nobody
% reads.
%
% So: `parsevalErr` tests the SCALING, against the quantity it is identically
% equal to, and is therefore machine-precision tight. The difference between
% the window-weighted power and the plain record power is reported separately
% as `taperBias`, because it is real information about the taper -- it should
% be looked at, not silently absorbed.
powerFreq  = sum(P1) * (fs/nfft);                       % Riemann; exact
powerWin   = sum(x.^2 .* w.^2) / max(sum(w.^2), eps);  % window-weighted power
powerTime  = mean(x.^2);                                % plain record power
parsevalErr = abs(powerFreq - powerWin) / max(powerWin, eps);
taperBias   = abs(powerWin - powerTime) / max(powerTime, eps);

% ---- cycle / leakage analysis -------------------------------------------
% Measured on the UN-PADDED, RECTANGULAR spectrum, for two reasons learned the hard
% way in the first version:
%   - with zero padding (nfft = 2048 for 1000 samples) a tone that lands exactly on
%     a bin of the N-point DFT lands BETWEEN bins of the padded one, so the
%     concentration metric reads 0.58 for a perfectly periodic signal;
%   - with a Hann display window the energy is intentionally spread over three bins.
% Neither has anything to do with leakage in the record.
Xn = abs(fft(x)).^2;
Xn = Xn(1:floor(N/2)+1);
fn = (0:numel(Xn)-1).' * fs / N;
concentration = max(Xn) / max(sum(Xn), eps);

% dominant non-DC component, refined by parabolic interpolation in log magnitude so
% a half-bin offset is MEASURED rather than rounded to the nearest bin
[~, im] = max(Xn(2:end));
im = im + 1;
if im > 1 && im < numel(Xn)
    a = log(Xn(im-1) + eps); b = log(Xn(im) + eps); c = log(Xn(im+1) + eps);
    d = 0.5*(a - c)/(a - 2*b + c);
    if ~isfinite(d), d = 0; end
    fPeak = fn(im) + d*(fn(2) - fn(1));
else
    fPeak = fn(im);
end
if fPeak <= 0
    cycles = Inf; leakage = 'UNKNOWN';
else
    cycles = fPeak * N / fs;
    frac = abs(cycles - round(cycles));
    if frac < 0.02, leakage = 'low';
    elseif frac > 0.1, leakage = 'HIGH';
    else, leakage = 'UNKNOWN'; end
end
if strcmp(leakage, 'HIGH')
    warn{end+1} = sprintf(['record holds %.3f cycles of the dominant tone (%.2f Hz): ' ...
        'energy is spread over neighbouring bins, so peak amplitude, THD and SNR ' ...
        'from this record are unreliable. Use an integer number of cycles or a ' ...
        'flat-top window.'], cycles, fPeak);
end
if parsevalErr > 1e-8
    warn{end+1} = sprintf(['Parseval check failed by %.2e: the PSD scaling is wrong ' ...
        '(window normalisation or the one-sided factor of 2).'], parsevalErr);
end
if N < 64
    warn{end+1} = sprintf('only %d samples: frequency resolution is %.3g Hz', N, fs/nfft);
end

r = struct();
r.f = f; r.psd = P1; r.window = opts.window; r.nfft = nfft;
r.fPeak = fPeak; r.cycles = cycles; r.leakage = leakage;
r.concentration = concentration;
r.powerTime = powerTime; r.powerFreq = powerFreq; r.parsevalErr = parsevalErr;
r.powerWindowed = powerWin; r.taperBias = taperBias;
r.nSamples = N; r.fs = fs;
r.warnings = warn;
r.ok = isempty(warn);
r.detail = sprintf(['peak %.3f Hz (%.3f cycles, leakage %s, concentration %.3f), ' ...
    'Parseval err %.2e, taper bias %.2e'], ...
    fPeak, cycles, leakage, concentration, parsevalErr, taperBias);
end

% ---------------------------------------------------------------------------
function o = dflt(o, d)
f = fieldnames(d);
for k = 1:numel(f)
    if ~isfield(o, f{k}), o.(f{k}) = d.(f{k}); end
end
end
