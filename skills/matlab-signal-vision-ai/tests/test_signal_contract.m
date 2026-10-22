function res = test_signal_contract(verbose)
%TEST_SIGNAL_CONTRACT  Measurement-contract tools: grading numbers against the
%                      record, the spec, and closed forms -- never against themselves.
%
%   res = test_signal_contract()
%
% Tools under test: mas_measure_contract, mas_filter_check, mas_sample_check,
% mas_ber_check.
%
% Every expected value here is computed from something that does NOT come from
% the tool being tested:
%   - hand algebra on paper (4-tap |cos x cos 2x| = 2/(3 sqrt 6) = 11.3033 dB)
%   - closed forms (erfc, 10 log10 vs 20 log10, -ln(1-L)/n Poisson bound)
%   - MATLAB design functions used as generators, not graders (kaiserord, buttord)
%   - an independent recomputation inside the test (Wilson interval, dense-grid
%     worst-attenuation search)
%
% Every metric that could pass vacuously has a negative control: a wrong dB
% convention, swapped peak/rms labels, a drifting record claiming steady-state,
% an unstable IIR, an aliased record, a 3 dB Eb/N0 convention error, a BER
% label that shifts the SNR by 2 dB. The point of each is that the tool must
% FAIL exactly then.

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
addpath(fullfile(repo, 'skills', 'matlab-signal-vision-ai', 'scripts'));

T = struct('name', {}, 'fn', {}, 'expect', {});

% ---------------- mas_measure_contract -----------------------------------
T(end+1) = tc('contract: clean tone passes',    @() mc_clean(),       'PASS');
T(end+1) = tc('contract: rad/s == Hz pair',      @() mc_rads(),        'PASS/50.0000');
T(end+1) = tc('contract: dB via 10 log10',       @() mc_dbOk(),        'PASS/0.5000');
T(end+1) = tc('contract: CI covers truth',       @() mc_ci(),          true);
T(end+1) = tc('neg: 20 log10 applied to power',  @() mc_db20(),        'FAIL/powerVsData');
T(end+1) = tc('neg: rad/s value typed as Hz',    @() mc_unitMix(),     'FAIL/freqVsData');
T(end+1) = tc('neg: rms > peak impossible',      @() mc_rmsPeak(),     'FAIL/peakRms');
T(end+1) = tc('neg: drift breaks steady claim',  @() mc_drift(),       'FAIL/stationarity');
T(end+1) = tc('transient: stationarity na only', @() mc_transient(),   'PASS/na');
T(end+1) = tc('no criterion: no tolRel',         @() mc_noTol(),       'UNDETERMINED/expectedVsMeasured');
T(end+1) = tc('short record: no interval',       @() mc_shortRec(),    'UNDETERMINED/interval');
T(end+1) = tc('too-short input rejected',        @() mc_tiny(),        'ERR');
T(end+1) = tc('bad fs rejected',                 @() mc_badFs(),       'ERR');

% ---------------- mas_filter_check ---------------------------------------
T(end+1) = tc('filter: kaiser FIR meets spec',   @() fc_firLp(),       'PASS');
T(end+1) = tc('filter: IIR passes, na reported', @() fc_iir(),         'PASS/na/na');
T(end+1) = tc('filter: hp meets spec, gd (N-1)/2', @() fc_hp(),        'PASS/13.0000');
T(end+1) = tc('filter: worst-over-band = hand',  @() fc_combNull(),    'FAIL/11.3033');
T(end+1) = tc('neg: edge-only rule would pass',  @() fc_edgeWouldPass(), true);
T(end+1) = tc('filter: resize matches hand',     @() fc_ma(),          '0.4359/passbandRipple');
T(end+1) = tc('neg: unstable IIR',               @() fc_unstable(),    'fail/1.0247');
T(end+1) = tc('neg: asymmetric + require',       @() fc_asymReq(),     'FAIL/fail');
T(end+1) = tc('neg: IIR + require linear',       @() fc_iirReq(),      'FAIL/fail');
T(end+1) = tc('filter: worst matches indep.',    @() fc_worstRoute(),  true);
T(end+1) = tc('neg: spec unmet by 5 dB',         @() fc_specMissed(),  'FAIL/stopband');
T(end+1) = tc('bad filter spec rejected',        @() fc_badSpec(),     'ERR');

% ---------------- mas_sample_check ---------------------------------------
T(end+1) = tc('sampling: bandlimited passes',    @() sc_clean(),       'PASS');
T(end+1) = tc('sampling: recon err < 1e-10',     @() sc_recon(),       true);
T(end+1) = tc('neg: alias fold printed',         @() sc_alias(),       'FAIL/200');
T(end+1) = tc('neg: peak above claimed band',    @() sc_peak(),        'FAIL/peakVsClaim');
T(end+1) = tc('neg: wrong truth reference',      @() sc_wrongTruth(),  'FAIL/truthMatches');
T(end+1) = tc('no truth: recon undetermined',    @() sc_noTruth(),     'UNDETERMINED/undetermined');
T(end+1) = tc('nothing claimed: all undetermined', @() sc_none(),      'UNDETERMINED/3/3');
T(end+1) = tc('too-short input rejected',        @() sc_tiny(),        'ERR');

% ---------------- mas_ber_check ------------------------------------------
T(end+1) = tc('ber: QPSK vs closed form',        @() bc_ok(),          'PASS');
T(end+1) = tc('ber: Wilson CI round-trip',       @() bc_wilson(),      true);
T(end+1) = tc('ber: Es-only converts by k',      @() bc_esOnly(),      'PASS/6.0000');
T(end+1) = tc('ber: QAM16 approx flagged',       @() bc_qam16(),       'PASS/0');
T(end+1) = tc('ber: theory override honoured',   @() bc_theoryOv(),    'PASS/1');
T(end+1) = tc('neg: Es labelled as Eb',          @() bc_convTrap(),    'FAIL/convention');
T(end+1) = tc('neg: zero errors, noise missing', @() bc_zero(),        true);
T(end+1) = tc('neg: 4 dB data under 6 dB tag',   @() bc_labelShift(),  true);
T(end+1) = tc('resolution: few bits undet.',     @() bc_lowBits(),     'UNDETERMINED/resolution');

nP = 0;
if verbose, fprintf('=== signal measurement contract tests ===\n'); end
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
        fprintf('  [%s] %-38s -> %s\n', tern(ok, 'PASS', 'FAIL'), t.name, ...
            char(string(got)));
    end
    R(end+1) = struct('case', t.name, 'got', char(string(got)), 'pass', ok); %#ok<AGROW>
end
res = struct('nPass', nP, 'nTotal', numel(T), 'cases', R, 'pass', nP == numel(T));
if verbose
    fprintf('\n---- %d / %d contract cases passed ----\n', nP, numel(T));
end
end

% ===========================================================================
% mas_measure_contract
% ===========================================================================
function [x, fs] = mc_tone()
fs = 1000; N = 1000; n = (0:N-1).';
x = cos(2*pi*50*n/fs);            % 50 integer cycles: no leakage
end

function v = mc_clean()
[x, fs] = mc_tone();
r = mas_measure_contract(x, fs, struct( ...
    'freq', struct('value', 50, 'unit', 'Hz'), ...
    'power', struct('value', 0.5, 'unit', 'linear'), ...
    'peak', 1, 'rms', sqrt(0.5), ...
    'expected', struct('value', 0.5, 'tolRel', 0.05)));
v = r.verdict;                     % must be exactly PASS
end
function v = mc_rads()
[x, fs] = mc_tone();
r = mas_measure_contract(x, fs, struct('freq', struct('value', 2*pi*50, 'unit', 'rad/s')));
v = sprintf('%s/%.4f', r.verdict, r.freqHz);
end
function v = mc_dbOk()
[x, fs] = mc_tone();
% hand: 0.5 linear is 10*log10(0.5) = -3.0103 dB, NOT 20*log10(0.5) = -6.0206
r = mas_measure_contract(x, fs, struct('power', struct('value', 10*log10(0.5), 'unit', 'dB')));
v = sprintf('%s/%.4f', r.verdict, r.powerLinear);
end
function v = mc_ci()
[x, fs] = mc_tone();
r = mas_measure_contract(x, fs, struct('power', struct('value', 0.5, 'unit', 'linear')));
% the interval must bracket the true power 0.5 and be quoted; the FREQUENCY
% interval must NOT be (83-sample blocks hold 4.15 cycles -- biased)
lo = r.ci.power.mean - r.ci.power.halfwidth;
hi = r.ci.power.mean + r.ci.power.halfwidth;
v = (lo <= 0.5) && (0.5 <= hi) && (r.ci.power.halfwidth > 0) && ...
    (r.ci.power.halfwidth < 0.05) && isnan(r.ci.freq.mean);
end
function v = mc_db20()
[x, fs] = mc_tone();
% the 20 log10 amplitude convention applied to a power: 0.25 instead of 0.5
r = mas_measure_contract(x, fs, struct('power', struct('value', 20*log10(0.5), 'unit', 'dB')));
bad = r.checks(strcmp({r.checks.status}, 'fail'));
v = sprintf('%s/%s', r.verdict, bad(1).id);
end
function v = mc_unitMix()
% 628.318 rad/s typed as Hz on a fs = 2000 record: passes Nyquist (628 < 1000)
% but the record holds 50 Hz, so the data check must catch it
fs = 2000; N = 2000; n = (0:N-1).';
x = cos(2*pi*50*n/fs);
r = mas_measure_contract(x, fs, struct('freq', struct('value', 628.318, 'unit', 'Hz')));
bad = r.checks(strcmp({r.checks.status}, 'fail'));
v = sprintf('%s/%s', r.verdict, bad(1).id);
end
function v = mc_rmsPeak()
[x, fs] = mc_tone();
r = mas_measure_contract(x, fs, struct('peak', 1.0, 'rms', 1.05));
ids = {r.checks(strcmp({r.checks.status}, 'fail')).id};
% the label swap must be named, not just numerically off
v = sprintf('%s/%s', r.verdict, tern(any(strcmp(ids, 'peakRms')), 'peakRms', 'other'));
end
function v = mc_drift()
fs = 1000; N = 1000; n = (0:N-1).';
x = (1 + 1.5*n/N) .* cos(2*pi*50*n/fs);       % amplitude ramps 1 -> 2.5
r = mas_measure_contract(x, fs, struct());
bad = r.checks(strcmp({r.checks.status}, 'fail'));
% measured 5.45 sigma vs the 2.57 limit -- far past any table-arithmetic doubt
v = sprintf('%s/%s', r.verdict, bad(1).id);
end
function v = mc_transient()
fs = 1000; N = 1000; n = (0:N-1).';
x = (1 + 1.5*n/N) .* cos(2*pi*50*n/fs);
r = mas_measure_contract(x, fs, struct('regime', 'transient'));
st = r.checks(strcmp({r.checks.id}, 'stationarity')).status;
% labelled transient: stationarity is not asserted (na) and must not FAIL,
% but every other check still runs
v = sprintf('%s/%s', r.verdict, st);
end
function v = mc_noTol()
[x, fs] = mc_tone();
% a theoretical value with NO tolerance is not a criterion: report the
% deviation but never grade it as a success
r = mas_measure_contract(x, fs, struct('expected', struct('value', 0.51)));
bad = r.checks(strcmp({r.checks.status}, 'undetermined'));
v = sprintf('%s/%s', r.verdict, bad(1).id);
end
function v = mc_shortRec()
% 32 samples in 12 blocks = 2.7 samples per block: no t-interval can be
% graded, so the verdict must be UNDETERMINED even though nothing failed
x = 0.5*ones(32, 1);                 % flat DC: block powers identical
r = mas_measure_contract(x, 1000, struct());
bad = r.checks(strcmp({r.checks.status}, 'undetermined'));
v = sprintf('%s/%s', r.verdict, bad(1).id);
end
function v = mc_tiny()
try
    mas_measure_contract(randn(16, 1), 1000, struct());
    v = 'NO_ERROR';
catch
    v = 'ERR';
end
end
function v = mc_badFs()
try
    mas_measure_contract(randn(64, 1), 0, struct());
    v = 'NO_ERROR';
catch
    v = 'ERR';
end
end

% ===========================================================================
% mas_filter_check
% ===========================================================================
function [b, fs] = fc_kaiser()
% design generator, not grader: kaiserord targets 0.01 ripple / 60 dB
fs = 1000;
[Nk, Wn, beta, ftype] = kaiserord([150 250], [1 0], [0.01 0.001], fs);
b = fir1(Nk, Wn, ftype, kaiser(Nk+1, beta), 'noscale');
end
function v = fc_firLp()
[b, fs] = fc_kaiser();
r = mas_filter_check(b, 1, struct('fs', fs, 'type', 'lowpass', ...
    'fpass', 150, 'fstop', 250, 'astopDb', 50, 'apassDb', 0.5));
v = r.verdict;
end
function v = fc_iir()
fs = 1000;
[Nb, Wb] = buttord(200/(fs/2), 300/(fs/2), 1, 30);
[b, a] = butter(Nb, Wb);
r = mas_filter_check(b, a, struct('fs', fs, 'type', 'lowpass', ...
    'fpass', 200, 'fstop', 300, 'astopDb', 25));
% IIR: phase is 'na' (linear phase never claimed), no apassDb -> ripple 'na';
% both must NOT drag the verdict, and must NOT be silent passes either
v = sprintf('%s/%s/%s', r.verdict, ...
    r.checks(strcmp({r.checks.id}, 'phaseLinear')).status, ...
    r.checks(strcmp({r.checks.id}, 'passbandRipple')).status);
end
function v = fc_hp()
% highpass via kaiserord: stopband 60 dB below 250 Hz, passband from 400 Hz
[Nh, Wnh, betah, ftypeh] = kaiserord([250 400], [0 1], [0.001 0.05], 1000);
b = fir1(Nh, Wnh, ftypeh, kaiser(Nh+1, betah), 'noscale');
r = mas_filter_check(b, 1, struct('fs', 1000, 'type', 'highpass', ...
    'fpass', 400, 'fstop', 250, 'astopDb', 50, 'apassDb', 1));
% group delay must be exactly (N-1)/2 = 13 for this 27-tap design
v = sprintf('%s/%.4f', r.verdict, r.achieved.groupDelaySamples);
end
function v = fc_combNull()
% 4-tap moving sum, fs = 1000: |H(f)| = |cos x cos 2x|, x = pi f/1000.
% Exactly zero at 250 Hz; the max over [250, 500] is 2/(3 sqrt 6) = 0.272166
% at f = acos(1/sqrt 6)*fs/pi = 366.14 Hz -> worst attenuation 11.3033 dB.
% A 40 dB spec: the point AT fstop is a null (~+70 dB), the band is 11.3 dB.
b = [1 1 1 1]/4;
r = mas_filter_check(b, 1, struct('fs', 1000, 'type', 'lowpass', ...
    'fpass', 200, 'fstop', 250, 'astopDb', 40));
v = sprintf('%s/%.4f', r.verdict, r.achieved.stopbandDb);
end
function v = fc_edgeWouldPass()
% the same filter and spec: prove the negative control is real -- the
% attenuation right at fstop is far above the 40 dB spec, so a check that
% only looked at fstop would have PASSED this filter
b = [1 1 1 1]/4;
fgrid = linspace(0, 500, 4096).';
Hg = abs(freqz(b, 1, fgrid, 1000));
near = abs(fgrid - 250) <= 0.2;
edgeDb = -20*log10(max(Hg(near)));
r = mas_filter_check(b, 1, struct('fs', 1000, 'type', 'lowpass', ...
    'fpass', 200, 'fstop', 250, 'astopDb', 40));
v = (edgeDb > 40) && strcmp(r.verdict, 'FAIL');
end
function v = fc_ma()
% 2-tap moving average: |H(f)| = |cos(pi f/fs)|.
% hand ripple = 20 log10(1/cos(pi*100/1000)) = 0.4359 dB; spec 0.1 dB -> FAIL
b = [0.5 0.5];
r = mas_filter_check(b, 1, struct('fs', 1000, 'type', 'lowpass', ...
    'fpass', 100, 'fstop', 450, 'astopDb', 10, 'apassDb', 0.1));
hand = 20*log10(1/cos(pi*100/1000));
bad = r.checks(strcmp({r.checks.status}, 'fail'));
ok = abs(r.achieved.passbandRippleDb - hand) < 1e-3;
v = sprintf('%.4f/%s', r.achieved.passbandRippleDb, tern(ok && ~isempty(bad) && ...
    strcmp(bad(1).id, 'passbandRipple'), 'passbandRipple', 'other'));
end
function v = fc_unstable()
% a = [1 -2 1.05]: poles 1 +/- 0.2236i, |p| = sqrt(1.05) = 1.0247 > 1
r = mas_filter_check([0.1], [1 -2 1.05], struct('fs', 1000, 'type', 'lowpass', ...
    'fpass', 100, 'fstop', 300, 'astopDb', 5));
st = r.checks(strcmp({r.checks.id}, 'stability')).status;
v = sprintf('%s/%.4f', st, r.achieved.maxPoleMag);
end
function v = fc_asymReq()
r = mas_filter_check([0.1 0.5 0.3], 1, struct('fs', 1000, 'type', 'lowpass', ...
    'fpass', 100, 'fstop', 300, 'astopDb', 5, 'requireLinearPhase', true));
st = r.checks(strcmp({r.checks.id}, 'phaseLinear')).status;
v = sprintf('%s/%s', r.verdict, st);
end
function v = fc_iirReq()
fs = 1000;
[Nb, Wb] = buttord(200/(fs/2), 300/(fs/2), 1, 30);
[b, a] = butter(Nb, Wb);
r = mas_filter_check(b, a, struct('fs', fs, 'type', 'lowpass', ...
    'fpass', 200, 'fstop', 300, 'astopDb', 25, 'requireLinearPhase', true));
st = r.checks(strcmp({r.checks.id}, 'phaseLinear')).status;
v = sprintf('%s/%s', r.verdict, st);
end
function v = fc_worstRoute()
% independent worst-over-band recomputation on a 5x denser grid; the tool's
% number must agree, and worst must be <= the value at fstop itself
% (a minimum over the band can never exceed one point of the band).
% NOTE: freqz(b, a, f, fs) needs f as a VECTOR -- a scalar third argument is
% read as the number of points, not as a frequency, which is exactly the trap
% mas_filter_check's dual-route design exists to expose.
[b, fs] = fc_kaiser();
r = mas_filter_check(b, 1, struct('fs', fs, 'type', 'lowpass', ...
    'fpass', 150, 'fstop', 250, 'astopDb', 50, 'apassDb', 0.5));
fg2 = linspace(0, 500, 20001).';     % contains 250 exactly
H2 = abs(freqz(b, 1, fg2, 1000));
indWorst = -20*log10(max(H2(fg2 >= 250)));
edge = -20*log10(H2(fg2 == 250));
v = (abs(r.achieved.stopbandDb - indWorst) < 0.05) && ...
    (r.achieved.stopbandDb <= edge + 1e-9);
end
function v = fc_specMissed()
[b, fs] = fc_kaiser();               % achieves ~60.1 dB
r = mas_filter_check(b, 1, struct('fs', fs, 'type', 'lowpass', ...
    'fpass', 150, 'fstop', 250, 'astopDb', 65, 'apassDb', 0.5));
bad = r.checks(strcmp({r.checks.status}, 'fail'));
v = sprintf('%s/%s', r.verdict, bad(1).id);
end
function v = fc_badSpec()
try
    mas_filter_check([0.5 0.5], 1, struct('fs', 1000, 'type', 'lowpass', ...
        'fpass', 400, 'fstop', 200, 'astopDb', 40));
    v = 'NO_ERROR';
catch
    v = 'ERR';
end
end

% ===========================================================================
% mas_sample_check
% ===========================================================================
function [x, fs, truth] = sc_sig()
fs = 1000; N = 1000;
truth = @(t) sin(2*pi*150*t);        % 150 integer cycles: exact reconstruction
x = truth((0:N-1).'/fs);
end
function v = sc_clean()
[x, fs, truth] = sc_sig();
r = mas_sample_check(x, fs, struct('fMax', 200, 'truth', struct('f', truth)));
v = r.verdict;
end
function v = sc_recon()
[x, fs, truth] = sc_sig();
r = mas_sample_check(x, fs, struct('fMax', 200, 'truth', struct('f', truth)));
v = r.measured.reconRelErr < 1e-10;   % measured 4.5e-14
end
function v = sc_alias()
% 300 Hz sampled at 500 Hz: folds to |300 - 500| = 200 Hz
fs = 500; N = 500;
truth = @(t) sin(2*pi*300*t);
x = truth((0:N-1).'/fs);
r = mas_sample_check(x, fs, struct('fMax', 300, 'truth', struct('f', truth)));
v = sprintf('%s/%.4g', r.verdict, r.measured.aliasFoldHz);
end
function v = sc_peak()
[x, fs] = sc_sig();                  % holds 150 Hz
r = mas_sample_check(x, fs, struct('fMax', 100));
bad = r.checks(strcmp({r.checks.status}, 'fail'));
v = sprintf('%s/%s', r.verdict, bad(1).id);
end
function v = sc_wrongTruth()
[x, fs] = sc_sig();
wrong = @(t) sin(2*pi*200*t);        % record is NOT samples of this
r = mas_sample_check(x, fs, struct('fMax', 200, 'truth', struct('f', wrong)));
bad = r.checks(strcmp({r.checks.status}, 'fail'));
v = sprintf('%s/%s', r.verdict, bad(1).id);
end
function v = sc_noTruth()
[x, fs] = sc_sig();
r = mas_sample_check(x, fs, struct('fMax', 200));
st = r.checks(strcmp({r.checks.id}, 'reconstruction')).status;
v = sprintf('%s/%s', r.verdict, st);
end
function v = sc_none()
[x, fs] = sc_sig();
r = mas_sample_check(x, fs, struct());
% no fMax, no truth: every check is a missing-evidence case, none may pass
v = sprintf('%s/%d/%d', r.verdict, r.nUndetermined, r.nChecks);
end
function v = sc_tiny()
try
    mas_sample_check(randn(16, 1), 1000);
    v = 'NO_ERROR';
catch
    v = 'ERR';
end
end

% ===========================================================================
% mas_ber_check
% ===========================================================================
function [nE, nB, pH] = bc_counts()
pH = 0.5*erfc(sqrt(10^0.6));         % closed form, exact for QPSK
nB = 2^18;
nE = round(pH*nB);                   % 626 errors
end
function v = bc_ok()
[nE, nB, pH] = bc_counts();
r = mas_ber_check(nE, nB, struct('scheme', 'QPSK', 'ebn0dB', 6));
% theory must equal the hand closed form, and z must be within rounding of
% zero (the count was generated FROM the formula, so any drift is the tool's)
v = tern(strcmp(r.verdict, 'PASS') && abs(r.berTheory - pH) < 1e-12 && ...
    abs(r.z) < 0.01, 'PASS', sprintf('FAIL/z=%.3f', r.z));
end
function v = bc_wilson()
[nE, nB, ~] = bc_counts();
r = mas_ber_check(nE, nB, struct('scheme', 'QPSK', 'ebn0dB', 6));
% independent Wilson score interval, textbook form
phat = nE/nB;
zq = 1.959963984540054;              % normal quantile at 95%, literal
den = 1 + zq^2/nB;
center = (phat + zq^2/(2*nB)) / den;
half = zq/den * sqrt(phat*(1-phat)/nB + zq^2/(4*nB^2));
lo = max(0, center - half); hi = min(1, center + half);
v = abs(r.ci.lo - lo) < 1e-12 && abs(r.ci.hi - hi) < 1e-12;
end
function v = bc_esOnly()
[nE, nB, ~] = bc_counts();
% Es/N0 = Eb/N0 + 10 log10(2) for QPSK; the tool must invert it back to 6 dB
r = mas_ber_check(nE, nB, struct('scheme', 'QPSK', 'esn0dB', 6 + 10*log10(2)));
v = sprintf('%s/%.4f', r.verdict, r.ebn0dB);
end
function v = bc_qam16()
p16 = (4/4)*(1 - 1/4)*0.5*erfc(sqrt(3*4/(2*15)*10^(1.0)));   % Gray approx
nB = 2^18; nE = round(p16*nB);
r = mas_ber_check(nE, nB, struct('scheme', 'QAM16', 'ebn0dB', 10));
% the approximation must be FLAGGED, not silently called exact
v = sprintf('%s/%d', r.verdict, r.theoryIsExact);
end
function v = bc_theoryOv()
[nE, nB, ~] = bc_counts();
r = mas_ber_check(nE, nB, struct('scheme', 'QPSK', 'ebn0dB', 6, ...
    'theory', @(x) 0.5*erfc(sqrt(x))));
v = sprintf('%s/%d', r.verdict, r.theoryIsExact);
end
function v = bc_convTrap()
[nE, nB, ~] = bc_counts();
% the classic: Es/N0 value (9.01 dB) entered as Eb/N0 (6 dB) -- a 3.01 dB
% gap that must be caught when both are stated
r = mas_ber_check(nE, nB, struct('scheme', 'QPSK', 'ebn0dB', 6, 'esn0dB', 6));
bad = r.checks(strcmp({r.checks.status}, 'fail'));
v = sprintf('%s/%s', r.verdict, bad(1).id);
end
function v = bc_zero()
% 0 errors in 1e6 bits at 6 dB: theory expects ~2400, so the measured noise
% is FAR below the label. The Poisson upper bound must equal -ln(1-L)/n.
r = mas_ber_check(0, 1e6, struct('scheme', 'QPSK', 'ebn0dB', 6));
hand = -log(1 - 0.95)/1e6;           % 2.9957e-6
v = r.z < -3 && strcmp(r.verdict, 'FAIL') && ...
    abs(r.ci.poissonUpper - hand)/hand < 1e-9;
end
function v = bc_labelShift()
% data measured at 4 dB, reported as 6 dB: hand z = (p4 - p6)/sqrt(p6(1-p6)/n)
% with p4 = 0.5*erfc(sqrt(10^0.4)) ~ 0.01254 -> z ~ 106
[nB, p4, p6] = deal(2^18, 0.5*erfc(sqrt(10^0.4)), 0.5*erfc(sqrt(10^0.6)));
nE = round(p4*nB);
r = mas_ber_check(nE, nB, struct('scheme', 'QPSK', 'ebn0dB', 6));
handZ = (nE/nB - p6)/sqrt(p6*(1-p6)/nB);
v = strcmp(r.verdict, 'FAIL') && abs(r.z - handZ) < 0.5 && r.z > 50;
end
function v = bc_lowBits()
% 500 bits cannot separate the theory from a 2x-different one
[nE, ~, pH] = bc_counts();
r = mas_ber_check(round(pH*500), 500, struct('scheme', 'QPSK', 'ebn0dB', 6));
bad = r.checks(strcmp({r.checks.status}, 'undetermined'));
v = sprintf('%s/%s', r.verdict, bad(1).id);
end

% ===========================================================================
function t = tc(name, fn, expect)
t = struct('name', name, 'fn', fn, 'expect', expect);
end
function s = tern(c, a, b)
if c, s = a; else, s = b; end
end