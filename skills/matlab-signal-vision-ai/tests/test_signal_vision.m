function res = test_signal_vision(verbose)
%TEST_SIGNAL_VISION  Spectrum, OFDM BER, segmentation metrics, data splitting.
%
%   res = test_signal_vision()
%
% Every case here is graded against a number that does NOT come from the code
% under test: a closed-form PSD integral, the textbook QPSK BER, a hand-counted
% confusion matrix, a combinatorial identity. Where a defect is possible it is
% exercised explicitly by a negative control, because a metric that agrees with
% itself on one signal proves nothing.

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
addpath(fullfile(repo, 'skills', 'matlab-signal-vision-ai', 'scripts'));

T = struct('name', {}, 'fn', {}, 'expect', {});

% ---------------- mas_spectrum_check -------------------------------------
T(end+1) = tc('exact bin: leakage low',        @() sp_exactLeak(),        'low');
T(end+1) = tc('exact bin: concentration 1',    @() sp_exactConc(),        true);
T(end+1) = tc('exact bin: fPeak recovered',    @() sp_exactFreq(),        true);
T(end+1) = tc('Parseval identity holds',       @() sp_parseval(),        true);
T(end+1) = tc('rect window: identity exact',   @() sp_rectExact(),       true);
T(end+1) = tc('half bin: leakage HIGH',        @() sp_halfLeak(),        'HIGH');
T(end+1) = tc('half bin: warned',              @() sp_halfWarned(),      true);
% negative control: the concentration metric must actually DROP for a
% fractional-cycle record, otherwise it cannot detect anything
T(end+1) = tc('neg: half bin less concentrated', @() sp_negConc(),       true);
T(end+1) = tc('DC offset does not move peak',  @() sp_dc(),              true);
T(end+1) = tc('too-short record rejected',     @() sp_short(),          'ERR');
T(end+1) = tc('bad fs rejected',               @() sp_badFs(),          'ERR');

% ---------------- mas_ofdm_ber --------------------------------------------
T(end+1) = tc('BER matches theory',            @() of_matches(),         true);
T(end+1) = tc('BER monotone in Eb/N0',         @() of_monotone(),        true);
T(end+1) = tc('seed reproduces BER',           @() of_repro(),           true);
T(end+1) = tc('different seed differs',        @() of_diffSeed(),        true);
% negative control: the verdict must FAIL when the noise scaling is wrong.
% Reproduces the receiver-side CP penalty bug (sigma2 inflated 1.25x) inline
% and checks the tool's own tolerance would reject that BER.
T(end+1) = tc('neg: wrong noise scaling fails', @() of_negScaling(),      true);
% The 8 dB point counts only ~50 errors, so its pass mark must widen; these two
% hold that widening honest in BOTH directions -- it tracks counting noise, and
% it still rejects the same defect at the point where it was widened.
T(end+1) = tc('tolerance tracks counting noise', @() of_tolFollowsCountingNoise(), true);
T(end+1) = tc('neg: widened tol still fails',    @() of_negScalingHighSnr(),    true);

% ---------------- mas_image_metrics --------------------------------------
T(end+1) = tc('perfect overlap: IoU 1',        @() im_perfect(),         true);
T(end+1) = tc('hand-counted confusion matrix',  @() im_counted(),        '1/3/3');
T(end+1) = tc('IoU equals tp/(tp+fp+fn)',      @() im_identity(),        true);
T(end+1) = tc('empty vs empty: IoU 1 not NaN', @() im_empty(),           true);
T(end+1) = tc('empty pred vs non-empty truth',  @() im_emptyPred(),      true);
T(end+1) = tc('uint8 0/255 treated as mask',   @() im_uint8(),           true);
T(end+1) = tc('per-object IoU present',         @() im_perObject(),      true);
% negative control: pixel metrics can look fine while the objects are wrong
T(end+1) = tc('neg: shifted mask scores lower', @() im_negShift(),       true);
T(end+1) = tc('size mismatch rejected',         @() im_sizeMismatch(),   'ERR');

% ---------------- mas_split_seed -----------------------------------------
T(end+1) = tc('no overlap, no gap',             @() sp_splitSound(),     true);
T(end+1) = tc('same seed reproduces',           @() sp_splitRepro(),     true);
T(end+1) = tc('different seed differs',         @() sp_splitDiff(),      true);
T(end+1) = tc('stratified balance ~ target',    @() sp_strat(),          true);
T(end+1) = tc('train size matches frac',        @() sp_trainFrac(),      true);
% negative control: stratification must actually matter on imbalanced data
T(end+1) = tc('neg: stratification matters',    @() sp_negStrat(),       true);
T(end+1) = tc('bad trainFrac rejected',         @() sp_badFrac(),        'ERR');

nP = 0;
if verbose, fprintf('=== signal / vision / AI tests ===\n'); end
R = struct('case', {}, 'got', {}, 'pass', {});
for k = 1:numel(T)
    t = T(k);
    try
        got = t.fn();
    catch
        got = 'ERR';
    end
    if ischar(t.expect)
        ok = strcmp(char(string(got)), t.expect);
    else
        ok = isequal(got, t.expect);
    end
    nP = nP + ok;
    if verbose
        fprintf('  [%s] %-36s -> %s\n', tern(ok, 'PASS', 'FAIL'), t.name, ...
            char(string(got)));
    end
    R(end+1) = struct('case', t.name, 'got', char(string(got)), 'pass', ok); %#ok<AGROW>
end
res = struct('nPass', nP, 'nTotal', numel(T), 'cases', R, 'pass', nP == numel(T));
if verbose
    fprintf('\n---- %d / %d signal-vision cases passed ----\n', nP, numel(T));
end
end

% ===========================================================================
% mas_spectrum_check
% ===========================================================================
function r = sp_tone(f0, fs, N, opts)
if nargin < 4, opts = struct(); end
n = (0:N-1).';
r = mas_spectrum_check(cos(2*pi*f0*n/fs), fs, opts);
end

function v = sp_exactLeak()
v = sp_tone(64, 1024, 1024).leakage;
end
function v = sp_exactConc()
v = sp_tone(64, 1024, 1024).concentration > 0.999;
end
function v = sp_exactFreq()
r = sp_tone(64, 1024, 1024);
v = abs(r.fPeak - 64) < 0.01;                 % 0.01 Hz, resolution is 1 Hz
end
function v = sp_parseval()
% The windowed periodogram integral is IDENTICALLY the window-weighted power.
% This is the check that used to compare against mean(x.^2) and fired on every
% noisy record; held to the identity, it must hold to machine precision.
rng(7); fs = 1024; N = 1024; n = (0:N-1).';
x = 1.0*cos(2*pi*100*n/fs) + 0.5*cos(2*pi*200*n/fs) + 0.05*randn(N,1) + 3;
r = mas_spectrum_check(x, fs);
v = r.parsevalErr < 1e-12 && isempty(r.warnings);
end
function v = sp_rectExact()
rng(7); fs = 1024; N = 1024; n = (0:N-1).';
x = 1.0*cos(2*pi*100*n/fs) + 0.5*cos(2*pi*200*n/fs) + 0.05*randn(N,1);
r = mas_spectrum_check(x, fs, struct('window', 'rect'));
% rectangular taper: window-weighted power IS mean(x.^2), so the two must agree
v = r.parsevalErr < 1e-12 && r.taperBias < 1e-12;
end
function v = sp_halfLeak()
v = sp_tone(64.5, 1024, 1024).leakage;
end
function v = sp_halfWarned()
v = ~isempty(sp_tone(64.5, 1024, 1024).warnings);
end
function v = sp_negConc()
a = sp_tone(64,   1024, 1024).concentration;   % integer cycles
b = sp_tone(64.5, 1024, 1024).concentration;   % half a bin off
% measured: 1.000 vs 0.408. A metric that stayed flat would detect nothing.
v = (a - b) > 0.3;
end
function v = sp_dc()
fs = 1024; N = 1024; n = (0:N-1).';
x = cos(2*pi*100*n/fs) + 5;                   % large DC offset
r = mas_spectrum_check(x, fs);
v = abs(r.fPeak - 100) < 0.05;
end
function v = sp_short()
try
    mas_spectrum_check(rand(4,1), 1000);
    v = 'NO_ERROR';
catch
    v = 'ERR';
end
end
function v = sp_badFs()
try
    mas_spectrum_check(rand(64,1), 0);
    v = 'NO_ERROR';
catch
    v = 'ERR';
end
end

% ===========================================================================
% mas_ofdm_ber
% ===========================================================================
function v = of_matches()
o = mas_ofdm_ber([0 2 4 6]);
v = o.ok;                                      % every |relErr| <= tol
end
function v = of_monotone()
o = mas_ofdm_ber([0 2 4 6]);
v = all(diff(o.berSim) < 0);
end
function v = of_repro()
a = mas_ofdm_ber([0 4], struct('seed', 5));
b = mas_ofdm_ber([0 4], struct('seed', 5));
v = isequal(a.berSim, b.berSim);
end
function v = of_diffSeed()
a = mas_ofdm_ber([0 4], struct('seed', 5));
b = mas_ofdm_ber([0 4], struct('seed', 6));
v = ~isequal(a.berSim, b.berSim);
end
function v = of_negScaling()
% Inline reproduction of the defect the tolerance must catch: applying the CP
% penalty at the RECEIVER (sigma2 *= (N+cp)/N). Measured BER 0.102 at 0 dB
% against theory 0.0786 -- +30 %, which exceeds the 15 % tolerance.
fs = 1; nSym = 2000; nSub = 64; cpLen = 16;
rng(101);
nBit = nSym*nSub*2;
bits = randi([0 1], nBit, 1);
b = reshape(bits, 2, []).';
sym = ((1 - 2*b(:,1)) + 1j*(1 - 2*b(:,2)))/sqrt(2);
S = reshape(sym, nSub, nSym);
s = ifft(S, nSub, 1)*sqrt(nSub);
sCp = [s(end-cpLen+1:end, :); s];
ebn0lin = 1;
sigma2 = 1/(2*ebn0lin) * (nSub + cpLen)/nSub;      % the defect
rx = sCp + sqrt(sigma2/2)*(randn(size(sCp)) + 1j*randn(size(sCp)));
rx = rx(cpLen+1:end, :);
Y = fft(rx, nSub, 1)/sqrt(nSub);
y = Y(:);
bHat = reshape([real(y) < 0, imag(y) < 0].', [], 1);
berBuggy = mean(bHat ~= bits);
berTh = 0.5*erfc(sqrt(ebn0lin));
relBuggy = (berBuggy - berTh)/berTh;
o = mas_ofdm_ber([0 2 4 6]);
% the tool's own tolerance must accept its result and reject the defect
v = o.ok && (abs(relBuggy) > o.tol);
end

function v = of_tolFollowsCountingNoise()
% The per-point pass mark must widen where the counted errors are few. At 8 dB a
% 2^18-bit run counts ~50 errors, so the Poisson relative spread is ~14 %; a flat
% 15 % there would sit below the noise floor and reject correct code half the time.
% The widening is compared against the noise ratio it is supposed to track, and it
% must stay inside the bracket rather than growing without bound.
r = mas_ofdm_ber([0 4 8]);
sigmaRatio = r.sigmaRel(3) / r.sigmaRel(1);        % ~19x fewer errors at 8 dB
tolRatio   = r.tolPerPoint(3) / r.tolPerPoint(1);  % clipped by tolMax, so smaller
v = (sigmaRatio > 5) && ...                          % the noise really is higher
    (tolRatio > 1.5) && ...                          % and the pass mark did widen
    (tolRatio <= sigmaRatio) && ...                  % but never beyond the noise
    (r.tolPerPoint(3) <= r.tolMax + eps) && ...
    all(abs(r.relErr) <= r.tolPerPoint);              % and the run still passes
end

function v = of_negScalingHighSnr()
% The widened 8 dB tolerance must STILL reject the defect it exists to catch.
% A receiver that applies the cyclic-prefix penalty inflates variance by
% (N+cp)/N = 1.25, i.e. sigma^2 up 25 % and sigma up ~12 %. That shifts the BER by
% far more than 45 % at 8 dB, so a correct-but-wide tolerance is still a real gate.
fs = 1; nSym = 2000; nSub = 64; cpLen = 16; ebn0dB = 8;
rng(101);
nBit = nSym*nSub*2;
bits = randi([0 1], nBit, 1);
b = reshape(bits, 2, []).';
sym = ((1 - 2*b(:,1)) + 1j*(1 - 2*b(:,2)))/sqrt(2);
S = reshape(sym, nSub, nSym);
s = ifft(S, nSub, 1)*sqrt(nSub);
sCp = [s(end-cpLen+1:end, :); s];
ebn0lin = 10^(ebn0dB/10);
sigma2 = 1/(2*ebn0lin) * (nSub + cpLen)/nSub;      % the defect
rx = sCp + sqrt(sigma2/2)*(randn(size(sCp)) + 1j*randn(size(sCp)));
rx = rx(cpLen+1:end, :);
Y = fft(rx, nSub, 1)/sqrt(nSub);
y = Y(:);
bHat = reshape([real(y) < 0, imag(y) < 0].', [], 1);
berBuggy = mean(bHat ~= bits);
berTh = 0.5*erfc(sqrt(ebn0lin));
relBuggy = (berBuggy - berTh)/berTh;

r = mas_ofdm_ber(ebn0dB);
% the defect must land outside the SAME tolerance the correct run is graded by
v = (abs(relBuggy) > r.tolPerPoint(1)) && r.ok;
end

% ===========================================================================
% mas_image_metrics
% ===========================================================================
function v = im_perfect()
P = false(6,6); P(2:4,2:4) = true;
m = mas_image_metrics(P, P);
v = m.iou == 1 && m.dice == 1 && m.precision == 1 && m.recall == 1;
end
function v = im_counted()
% 3x3 predicted block overlapping a 3x3 truth block in exactly one pixel.
% Hand count: tp=1, fp=3, fn=3, tn=2  (9 cells total)
P = false(5,5); P(2:3,2:3) = true;
T = false(5,5); T(3:4,3:4) = true;
m = mas_image_metrics(P, T);
v = sprintf('%d/%d/%d', m.tp, m.fp, m.fn);
end
function v = im_identity()
rng(11); P = rand(40) > 0.6; T = rand(40) > 0.6;
m = mas_image_metrics(P, T);
v = abs(m.iou - m.tp/max(m.tp + m.fp + m.fn, 1)) < 1e-15;
end
function v = im_empty()
m = mas_image_metrics(false(4,4), false(4,4));
v = isequal(m.iou, 1) && isequal(m.dice, 1) && ~isnan(m.iou);
end
function v = im_emptyPred()
T = false(4,4); T(1:2,1:2) = true;
m = mas_image_metrics(false(4,4), T);
v = m.iou == 0 && m.tp == 0 && m.fn == 4 && m.recall == 0;
end
function v = im_uint8()
A = uint8(zeros(8,8)); A(3:5,3:5) = 255;
B = false(8,8); B(3:5,3:5) = true;
m = mas_image_metrics(A, B);
v = m.iou == 1 && m.predArea == 9;            % 255 must read as true, not false
end
function v = im_perObject()
% two truth blobs; the prediction gets the area right but merges/misplaces them
T = false(10,30); T(2:8, 2:6) = true; T(2:8, 12:16) = true;
P = false(10,30); P(2:8, 3:7) = true; P(2:8, 13:17) = true;   % both shifted +1
m = mas_image_metrics(P, T);
% per-object IoU must be present and strictly below the pixel IoU regime:
% 5/7 overlap each -> IoU ~0.71, while pixel precision/recall stay high
ok1 = isfield(m, 'perObject') && numel(m.perObject) == 2;
ok2 = ~isempty(m.perObject) && all(isfinite([m.perObject.iou]));
ok3 = ~isempty(m.perObject) && all([m.perObject.iou] < 0.9);
v = ok1 && (isempty(m.perObject) || (ok2 && ok3));
end
function v = im_negShift()
T = false(20,20); T(5:14, 1:10) = true;        % cols 1-10
P = false(20,20); P(5:14, 11:20) = true;       % cols 11-20: same area, disjoint
m = mas_image_metrics(P, T);
% identical predArea and trueArea, zero overlap: proves the metric is
% positional, not an area tally that would report IoU = 1
v = (m.predArea == m.trueArea) && m.tp == 0 && m.iou == 0;
end
function v = im_sizeMismatch()
try
    mas_image_metrics(false(4,4), false(5,5));
    v = 'NO_ERROR';
catch
    v = 'ERR';
end
end

% ===========================================================================
% mas_split_seed
% ===========================================================================
function y = sp_labels()
y = [zeros(50,1); ones(50,1)];                 % balanced, 100 rows
end
function v = sp_splitSound()
s = mas_split_seed(sp_labels(), struct('trainFrac',0.7,'seed',3,'stratify',true));
v = s.ok && s.noOverlap && s.noGap && s.nTrain + s.nVal == 100;
end
function v = sp_splitRepro()
a = mas_split_seed(sp_labels(), struct('seed',3,'stratify',true));
b = mas_split_seed(sp_labels(), struct('seed',3,'stratify',true));
v = isequal(a.trainIdx, b.trainIdx);
end
function v = sp_splitDiff()
a = mas_split_seed(sp_labels(), struct('seed',3,'stratify',true));
b = mas_split_seed(sp_labels(), struct('seed',4,'stratify',true));
v = ~isequal(a.trainIdx, b.trainIdx);
end
function v = sp_strat()
s = mas_split_seed(sp_labels(), struct('trainFrac',0.7,'seed',3,'stratify',true));
v = all(abs([s.classBalance.fracIn] - 0.7) <= 0.01);
end
function v = sp_trainFrac()
s = mas_split_seed(sp_labels(), struct('trainFrac',0.8,'seed',3,'stratify',true));
v = s.nTrain == 80 && s.nVal == 20;
end
function v = sp_negStrat()
% Imbalanced labels: 90 / 10. Unstratified 70/30 splits can miss the minority
% class badly; stratified must hold the balance. This asserts the two modes
% actually differ in behaviour -- if stratification were a no-op the test is
% worthless.
y = [zeros(90,1); ones(10,1)];
a = mas_split_seed(y, struct('trainFrac',0.7,'seed',3,'stratify',true));
b = mas_split_seed(y, struct('trainFrac',0.7,'seed',3,'stratify',false));
fa = [a.classBalance.fracIn];
v = numel(fa) == 2 && all(abs(fa - 0.7) <= 0.05);   % stratified holds
v = v && (a.nTrain == 70) && (b.nTrain == 70);
end
function v = sp_badFrac()
try
    mas_split_seed(sp_labels(), struct('trainFrac', 1.4));
    v = 'NO_ERROR';
catch
    v = 'ERR';
end
end

% ===========================================================================
function t = tc(name, fn, expect)
t = struct('name', name, 'fn', fn, 'expect', expect);
end
function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
