function probe_task1_tools()
%PROBE_TASK1_TOOLS  Ground the test_signal_contract expectations in measured numbers.
%
% Every expected value in tests/test_signal_contract.m must come from a
% computation that does NOT depend on the tool being tested: closed forms,
% hand-designed filters, published formulas. This probe prints those numbers.

here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(here));
addpath(fullfile(repo, 'skills', 'matlab-signal-vision-ai', 'scripts'));

fprintf('===== mas_measure_contract =====\n');
fs = 1000; N = 1000; n = (0:N-1).';
x = cos(2*pi*50*n/fs);
claims = struct('freq', struct('value', 50, 'unit', 'Hz'), ...
    'power', struct('value', 0.5, 'unit', 'linear'), ...
    'peak', 1, 'rms', sqrt(0.5), ...
    'expected', struct('value', 0.5, 'tolRel', 0.05));
r = mas_measure_contract(x, fs, claims);
fprintf('clean: verdict=%s ok=%d\n', r.verdict, r.ok);
for k = 1:numel(r.checks)
    fprintf('  [%s] %-18s %s\n', r.checks(k).status, r.checks(k).id, r.checks(k).detail);
end
fprintf('  detail: %s\n', r.detail);
fprintf('  ci.power mean=%.6g hw=%.6g | ci.freq mean=%.6g hw=%.6g\n', ...
    r.ci.power.mean, r.ci.power.halfwidth, r.ci.freq.mean, r.ci.freq.halfwidth);

% rad/s claim
c2 = struct('freq', struct('value', 2*pi*50, 'unit', 'rad/s'));
r2 = mas_measure_contract(x, fs, c2);
fprintf('rad/s claim: verdict=%s freqHz=%.6f freqRad=%.6f\n', r2.verdict, r2.freqHz, r2.freqRadPerSec);

% dB claim, correct (10log10)
c3 = struct('power', struct('value', 10*log10(0.5), 'unit', 'dB'));
r3 = mas_measure_contract(x, fs, c3);
fprintf('dB ok: verdict=%s powerLinear=%.6f\n', r3.verdict, r3.powerLinear);

% dB claim, 20log10 trap
c4 = struct('power', struct('value', 20*log10(0.5), 'unit', 'dB'));
r4 = mas_measure_contract(x, fs, c4);
fprintf('dB20 trap: verdict=%s powerLinear=%.6f\n', r4.verdict, r4.powerLinear);
for k = 1:numel(r4.checks)
    if strcmp(r4.checks(k).status, 'fail')
        fprintf('  FAIL %s: %s\n', r4.checks(k).id, r4.checks(k).detail);
    end
end

% wrong-unit frequency: 628.32 rad/s typed as Hz, fs=2000 so it passes Nyquist
fs2 = 2000; N2 = 2000; n2 = (0:N2-1).';
x2 = cos(2*pi*50*n2/fs2);
c5 = struct('freq', struct('value', 628.318, 'unit', 'Hz'));
r5 = mas_measure_contract(x2, fs2, c5);
fprintf('unit-mix: verdict=%s\n', r5.verdict);
for k = 1:numel(r5.checks)
    if strcmp(r5.checks(k).status, 'fail')
        fprintf('  FAIL %s: %s\n', r5.checks(k).id, r5.checks(k).detail);
    end
end

% rms > peak
c6 = struct('peak', 1.0, 'rms', 1.05);
r6 = mas_measure_contract(x, fs, c6);
fprintf('rms>peak: verdict=%s (checks: ', r6.verdict);
fprintf('%s ', r6.checks(strcmp({r6.checks.status}, 'fail')).id);
fprintf(')\n');

% drift: steady claimed, amplitude ramps 1 -> 2.5
xd = (1 + 1.5*n/N) .* cos(2*pi*50*n/fs);
r7 = mas_measure_contract(xd, fs, struct('power', struct('value', mean(xd.^2), 'unit', 'linear')));
fprintf('drift: verdict=%s\n', r7.verdict);
for k = 1:numel(r7.checks)
    if ~strcmp(r7.checks(k).status, 'pass')
        fprintf('  [%s] %s: %s\n', r7.checks(k).status, r7.checks(k).id, r7.checks(k).detail);
    end
end

% transient regime: same drifting record, labelled transient
r8 = mas_measure_contract(xd, fs, struct('regime', 'transient'));
fprintf('transient: verdict=%s stationarity status=%s\n', r8.verdict, ...
    r8.checks(strcmp({r8.checks.id}, 'stationarity')).status);

% expected without tolRel
c9 = struct('expected', struct('value', 0.5));
r9 = mas_measure_contract(x, fs, c9);
fprintf('no-tol expected: verdict=%s (undet ids: ', r9.verdict);
fprintf('%s ', r9.checks(strcmp({r9.checks.status}, 'undetermined')).id);
fprintf(')\n');

% short record: interval must be refused
xs = randn(32, 1);
rS = mas_measure_contract(xs, fs, struct());
ev = rS.checks(strcmp({rS.checks.id}, 'interval'));
fprintf('short record: verdict=%s interval status=%s\n', rS.verdict, ev.status);

fprintf('\n===== mas_filter_check =====\n');
% FIR via kaiserord meeting the spec
fsc = 1000;
[Nk, Wn, beta, ftype] = kaiserord([150 250], [1 0], [0.01 0.001], fsc);
bFir = fir1(Nk, Wn, ftype, kaiser(Nk+1, beta), 'noscale');
fprintf('kaiserord: order=%d beta=%.4f\n', Nk, beta);
rF = mas_filter_check(bFir, 1, struct('fs', fsc, 'type', 'lowpass', ...
    'fpass', 150, 'fstop', 250, 'astopDb', 50, 'apassDb', 0.5));
fprintf('FIR lp: verdict=%s stopbandDb=%.2f rippleDb=%.4f\n', rF.verdict, ...
    rF.achieved.stopbandDb, rF.achieved.passbandRippleDb);
for k = 1:numel(rF.checks)
    if ~strcmp(rF.checks(k).status, 'pass')
        fprintf('  [%s] %s: %s\n', rF.checks(k).status, rF.checks(k).id, rF.checks(k).detail);
    end
end

% IIR via buttord meeting the spec
fsc2 = 1000; Wp = 200/(fsc2/2); Ws = 300/(fsc2/2);
[Nb, Wb] = buttord(Wp, Ws, 1, 30);
[bIir, aIir] = butter(Nb, Wb);
fprintf('buttord: order=%d Wn=%.4f\n', Nb, Wb);
rI = mas_filter_check(bIir, aIir, struct('fs', fsc2, 'type', 'lowpass', ...
    'fpass', 200, 'fstop', 300, 'astopDb', 25));
fprintf('IIR lp: verdict=%s stopbandDb=%.2f maxPole=%.6f | phase status=%s ripple status=%s\n', ...
    rI.verdict, rI.achieved.stopbandDb, rI.achieved.maxPoleMag, ...
    rI.checks(strcmp({rI.checks.id}, 'phaseLinear')).status, ...
    rI.checks(strcmp({rI.checks.id}, 'passbandRipple')).status);

% moving average: hand-computable ripple 20log10(1/cos(pi/10)) and stopband
bMA = [0.5 0.5];
rippleMA = 20*log10(1/cos(pi*100/1000));
attenMA = -20*log10(abs(cos(pi*450/1000)));
fprintf('moving avg: hand ripple=%.4f dB, hand atten@450=%.4f dB\n', rippleMA, attenMA);
rMA = mas_filter_check(bMA, 1, struct('fs', 1000, 'type', 'lowpass', ...
    'fpass', 100, 'fstop', 450, 'astopDb', 10, 'apassDb', 0.1));
fprintf('moving avg: verdict=%s rippleDb=%.4f stopbandDb=%.4f\n', rMA.verdict, ...
    rMA.achieved.passbandRippleDb, rMA.achieved.stopbandDb);
for k = 1:numel(rMA.checks)
    if strcmp(rMA.checks(k).status, 'fail')
        fprintf('  FAIL %s: %s\n', rMA.checks(k).id, rMA.checks(k).detail);
    end
end

% unstable IIR
rU = mas_filter_check([0.1], [1 -2 1.05], struct('fs', 1000, 'type', 'lowpass', ...
    'fpass', 100, 'fstop', 300, 'astopDb', 5));
fprintf('unstable: verdict=%s stability status=%s maxPole=%.4f\n', rU.verdict, ...
    rU.checks(strcmp({rU.checks.id}, 'stability')).status, rU.achieved.maxPoleMag);

% asymmetric FIR with requireLinearPhase
rA = mas_filter_check([0.1 0.5 0.3], 1, struct('fs', 1000, 'type', 'lowpass', ...
    'fpass', 100, 'fstop', 300, 'astopDb', 5, 'requireLinearPhase', true));
fprintf('asym required: verdict=%s phase status=%s\n', rA.verdict, ...
    rA.checks(strcmp({rA.checks.id}, 'phaseLinear')).status);

fprintf('\n===== mas_sample_check =====\n');
fss = 1000; Ns = 1000; ts = (0:Ns-1).'/fss;
truth150 = @(t) sin(2*pi*150*t);
xsig = truth150(ts);
rS1 = mas_sample_check(xsig, fss, struct('fMax', 200, 'truth', struct('f', truth150)));
fprintf('clean: verdict=%s reconErr=%.3e\n', rS1.verdict, rS1.measured.reconRelErr);
for k = 1:numel(rS1.checks)
    fprintf('  [%s] %-14s %s\n', rS1.checks(k).status, rS1.checks(k).id, rS1.checks(k).detail);
end

% aliased: 300 Hz sampled at 500 Hz folds to 200 Hz
fsa = 500; Na = 500; ta = (0:Na-1).'/fsa;
truth300 = @(t) sin(2*pi*300*t);
xalias = truth300(ta);
rS2 = mas_sample_check(xalias, fsa, struct('fMax', 300, 'truth', struct('f', truth300)));
fprintf('aliased: verdict=%s aliasFold=%.4g reconErr=%.3e\n', rS2.verdict, ...
    rS2.measured.aliasFoldHz, rS2.measured.reconRelErr);
for k = 1:numel(rS2.checks)
    if ~strcmp(rS2.checks(k).status, 'pass')
        fprintf('  [%s] %s: %s\n', rS2.checks(k).status, rS2.checks(k).id, rS2.checks(k).detail);
    end
end

% peak above claimed band
rS3 = mas_sample_check(xsig, fss, struct('fMax', 100));
fprintf('peak-above: verdict=%s peak status=%s\n', rS3.verdict, ...
    rS3.checks(strcmp({rS3.checks.id}, 'peakVsClaim')).status);

% wrong truth
truth200 = @(t) sin(2*pi*200*t);
rS4 = mas_sample_check(xsig, fss, struct('fMax', 200, 'truth', struct('f', truth200)));
fprintf('wrong truth: verdict=%s truthMatches=%s\n', rS4.verdict, ...
    rS4.checks(strcmp({rS4.checks.id}, 'truthMatches')).status);

% no truth
rS5 = mas_sample_check(xsig, fss, struct('fMax', 200));
fprintf('no truth: verdict=%s recon status=%s\n', rS5.verdict, ...
    rS5.checks(strcmp({rS5.checks.id}, 'reconstruction')).status);

fprintf('\n===== mas_ber_check =====\n');
p6 = 0.5*erfc(sqrt(10^(0.6)));
nB = 2^18; nE = round(p6*nB);
fprintf('QPSK 6dB: theory=%.6g nErr=%d nBits=%d\n', p6, nE, nB);
rB1 = mas_ber_check(nE, nB, struct('scheme', 'QPSK', 'ebn0dB', 6));
fprintf('ok: verdict=%s z=%+.2f ci=[%.3g, %.3g]\n', rB1.verdict, rB1.z, rB1.ci.lo, rB1.ci.hi);
for k = 1:numel(rB1.checks)
    fprintf('  [%s] %-14s %s\n', rB1.checks(k).status, rB1.checks(k).id, rB1.checks(k).detail);
end

% low-resolution: same rate, few bits
rB2 = mas_ber_check(round(p6*500), 500, struct('scheme', 'QPSK', 'ebn0dB', 6));
fprintf('lowBits: verdict=%s resolution=%s width=%.4g\n', rB2.verdict, ...
    rB2.checks(strcmp({rB2.checks.id}, 'resolution')).status, rB2.ci.hi - rB2.ci.lo);

% convention defect
rB3 = mas_ber_check(nE, nB, struct('scheme', 'QPSK', 'ebn0dB', 6, 'esn0dB', 6));
fprintf('convention: verdict=%s\n', rB3.verdict);

% Es-only input, correct conversion
rB4 = mas_ber_check(nE, nB, struct('scheme', 'QPSK', 'esn0dB', 6 + 10*log10(2)));
fprintf('es-only: verdict=%s ebn0dB=%.4f\n', rB4.verdict, rB4.ebn0dB);

% zero errors: measured noise far below the label
rB5 = mas_ber_check(0, 1e6, struct('scheme', 'QPSK', 'ebn0dB', 6));
fprintf('zero: verdict=%s z=%+.2f poisson=%.3g\n', rB5.verdict, rB5.z, rB5.ci.poissonUpper);

% wrong SNR label: measured at 4 dB reported as 6 dB
p4 = 0.5*erfc(sqrt(10^0.4));
rB6 = mas_ber_check(round(p4*nB), nB, struct('scheme', 'QPSK', 'ebn0dB', 6));
fprintf('label-shift: verdict=%s z=%+.2f\n', rB6.verdict, rB6.z);

% 16QAM with the Gray approximation
p16 = (4/4)*(1 - 1/4)*0.5*erfc(sqrt(3*4/(2*15)*10^(1.0)));
nE16 = round(p16*nB);
rB7 = mas_ber_check(nE16, nB, struct('scheme', 'QAM16', 'ebn0dB', 10));
fprintf('qam16: verdict=%s theory=%.6g exact=%d z=%+.2f\n', rB7.verdict, ...
    rB7.berTheory, rB7.theoryIsExact, rB7.z);

fprintf('\n===== extra spot checks =====\n');
% sample_check: nothing claimed, nothing given -> all undetermined
rS6 = mas_sample_check(xsig, fss, struct());
fprintf('no-fMax-no-truth: verdict=%s (statuses: ', rS6.verdict);
fprintf('%s ', rS6.checks.status);
fprintf(')\n');

% IIR with requireLinearPhase -> fail (the earlier defect direction)
rIL = mas_filter_check(bIir, aIir, struct('fs', fsc2, 'type', 'lowpass', ...
    'fpass', 200, 'fstop', 300, 'astopDb', 25, 'requireLinearPhase', true));
fprintf('IIR required linear: verdict=%s phase status=%s\n', rIL.verdict, ...
    rIL.checks(strcmp({rIL.checks.id}, 'phaseLinear')).status);

% IIR without the requirement -> phase na, verdict driven by the rest
rIN = mas_filter_check(bIir, aIir, struct('fs', fsc2, 'type', 'lowpass', ...
    'fpass', 200, 'fstop', 300, 'astopDb', 25));
fprintf('IIR default: verdict=%s phase status=%s\n', rIN.verdict, ...
    rIN.checks(strcmp({rIN.checks.id}, 'phaseLinear')).status);

% highpass FIR positive: kaiserord-guaranteed design
[Nh, Wnh, betah, ftypeh] = kaiserord([250 400], [0 1], [0.001 0.05], 1000);
bHp = fir1(Nh, Wnh, ftypeh, kaiser(Nh+1, betah), 'noscale');
fprintf('kaiserord hp: order=%d ftype=%s\n', Nh, ftypeh);
rHP = mas_filter_check(bHp, 1, struct('fs', 1000, 'type', 'highpass', ...
    'fpass', 400, 'fstop', 250, 'astopDb', 50, 'apassDb', 1));
fprintf('FIR hp: verdict=%s stopbandDb=%.2f gd=%.4f\n', rHP.verdict, ...
    rHP.achieved.stopbandDb, rHP.achieved.groupDelaySamples);
for k = 1:numel(rHP.checks)
    if ~strcmp(rHP.checks(k).status, 'pass')
        fprintf('  [%s] %s: %s\n', rHP.checks(k).status, rHP.checks(k).id, rHP.checks(k).detail);
    end
end

% short input error
try
    mas_measure_contract(randn(16, 1), 100, struct());
    fprintf('short input: NO_ERROR\n');
catch
    fprintf('short input: ERR (expected)\n');
end

% ber: exercise the theory-handle override
rBO = mas_ber_check(626, nB, struct('scheme', 'QPSK', 'ebn0dB', 6, ...
    'theory', @(x) 0.5*erfc(sqrt(x))));
fprintf('theory override: verdict=%s exact=%d\n', rBO.verdict, rBO.theoryIsExact);
end