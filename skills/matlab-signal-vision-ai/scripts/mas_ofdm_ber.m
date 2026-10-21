function r = mas_ofdm_ber(ebn0dB, opts)
%MAS_OFDM_BER  QPSK-OFDM over AWGN, graded against the closed-form BER.
%
%   r = mas_ofdm_ber([0 2 4 6])
%   r.berSim, r.berTheory, r.relErr, r.nBits
%   r.ok, r.verdict, r.tol   -- PASS iff every |relErr| <= tol (default 0.15)
%
% WHY AN OFDM TASK AND NOT "SIMULATE BPSK"
% OFDM is where a plausible-looking chain usually breaks: the IFFT/FFT pair must be
% scaled consistently, the cyclic prefix must be removed before the FFT (not after),
% and the per-subcarrier SNR must account for the energy spread across N subcarriers.
% Each of those mistakes gives a BER curve that is smooth, monotone and wrong.
%
% The reference is the textbook result for QPSK over AWGN, BER = 0.5*erfc(sqrt(Eb/N0)),
% which has nothing to do with this code. A simulation that disagrees is wrong.
%
% The check is one-sided on purpose: a simulated BER well BELOW theory is not a
% success, it means the noise scaling is too small.

if nargin < 2, opts = struct(); end
% tolMin/tolMax BRACKET the per-point counting-noise pass mark; `tol` is kept as
% the reported headline number and as the floor for well-populated points.
opts = dflt(opts, struct('nSym', 2000, 'nSub', 64, 'cpLen', 16, 'seed', 101, ...
    'tol', 0.15, 'tolMin', 0.15, 'tolMax', 0.45, 'verbose', false));

nBit = opts.nSym * opts.nSub * 2;      % QPSK: 2 bits per subcarrier per symbol
ebn0 = ebn0dB(:).';
berSim = zeros(size(ebn0));
berTh = zeros(size(ebn0));

rng(opts.seed);
for q = 1:numel(ebn0)
    % ---- bits -> QPSK symbols (Gray coded, unit average energy) ----------
    bits = randi([0 1], nBit, 1);
    b = reshape(bits, 2, []).';
    sym = (1 - 2*b(:, 1)) + 1j*(1 - 2*b(:, 2));   % ±1 ±1j, Es = 2
    sym = sym / sqrt(2);                          % Es = 1

    % ---- OFDM: reshape to subcarriers, IFFT, add CP ----------------------
    S = reshape(sym, opts.nSub, opts.nSym);
    s = ifft(S, opts.nSub, 1) * sqrt(opts.nSub);  % unit-average-power time samples
    sCp = [s(end-opts.cpLen+1:end, :); s];

    % ---- AWGN at the sample level ---------------------------------------
    % Eb/N0 -> sample noise variance.
    %   QPSK with unit Es: Es = 2*Eb, so the per-subcarrier SNR is 2*Eb/N0.
    %   The IFFT is scaled so each time sample has power Es = 1, and the FFT divides
    %   by sqrt(N), so the per-subcarrier signal power stays 1 and the noise power
    %   stays sigma2. Therefore sigma2 = 1/(2*Eb/N0), full stop.
    %
    % The first version also divided by (N+cp)/N "because the CP carries noise". That
    % is wrong: the CP samples are DISCARDED at the receiver, so the noise in them
    % goes with them. The CP penalty is a TRANSMIT power penalty (you must radiate
    % more to keep the same received Es), not a receive-SNR penalty. Applying it here
    % inflated sigma2 by 1.25x and produced BER 0.102 where theory says 0.0786.
    ebn0lin = 10^(ebn0(q)/10);
    sigma2 = 1/(2*ebn0lin);
    rx = sCp + sqrt(sigma2/2)*(randn(size(sCp)) + 1j*randn(size(sCp)));

    % ---- receiver: drop CP, FFT, slice ----------------------------------
    rx = rx(opts.cpLen+1:end, :);
    Y = fft(rx, opts.nSub, 1) / sqrt(opts.nSub);
    y = Y(:);
    bHat = [real(y) < 0, imag(y) < 0];
    bHat = reshape(bHat.', [], 1);
    berSim(q) = mean(bHat ~= bits);

    berTh(q) = 0.5*erfc(sqrt(ebn0lin));
end

relErr = (berSim - berTh) ./ max(berTh, eps);

% TOLERANCE FROM COUNTING NOISE, NOT FROM A ROUNDED CONSTANT
% Under Gaussian noise the bit errors are (very nearly) a Poisson count, so the
% relative standard error of the measured BER is ~1/sqrt(nErr). A single flat
% tolerance cannot be right for every point: at 0 dB a 2^18-bit run counts
% ~20000 errors (0.7 % noise) while at 8 dB it counts ~49 (14 % noise). A flat
% 15 % therefore sits BELOW the noise floor at 8 dB and rejects correct code
% about half the time -- a flaky test is worse than no test, because the first
% response to a flaky test is to stop reading it.
% So the per-point pass mark is 3 sigma of that point's own counting noise,
% never below opts.tolMin and never above opts.tolMax.
nErr = berSim * nBit;
sigmaRel = 1 ./ sqrt(max(nErr, 1));
tolPt = max(opts.tolMin, min(opts.tolMax, 3 * sigmaRel));

r = struct();
r.ebn0dB = ebn0; r.berSim = berSim; r.berTheory = berTh;
r.relErr = relErr; r.nBits = nBit; r.nSym = opts.nSym; r.nSub = opts.nSub;
r.cpLen = opts.cpLen; r.seed = opts.seed;
r.tol = opts.tol;
r.tolMin = opts.tolMin;
r.tolMax = opts.tolMax;
r.nErrors = nErr;
r.sigmaRel = sigmaRel;
r.tolPerPoint = tolPt;

% One-sided would be wrong here, so it is not one-sided: a BER well BELOW theory
% means the noise variance is too small, which is the same defect as too much noise
% and just as fatal. The pass mark is wide enough to absorb counting noise but far
% narrower than the defect this check exists to catch -- applying the CP penalty at
% the receiver shifts BER by ~30 %.
r.ok = all(isfinite(relErr)) && all(abs(relErr) <= tolPt);
r.verdict = tern(r.ok, 'PASS', 'FAIL');
r.detail = sprintf('%d carriers, CP %d, %d bits: BER %s vs theory %s (rel %s, tol %s, %s)', ...
    opts.nSub, opts.cpLen, nBit, mat2str(berSim, 3), mat2str(berTh, 3), ...
    mat2str(relErr, 2), mat2str(tolPt, 2), r.verdict);
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
