% probe_task1_extra.m -- supplementary grounding numbers for test_signal_contract.m.
%
% Every line here is a value the TEST asserts, recomputed from a source that is
% not the code under test: MATLAB design generators (kaiserord/buttord), a
% literal normal quantile, and a closed form. The point of the log is provenance:
% a reader can see where the expected numbers came from without opening the test.

repo = fileparts(fileparts(fileparts(mfilename('fullpath'))));   % ...\artifacts\phase53 -> repo
addpath(fullfile(repo, 'skills', 'matlab-signal-vision-ai', 'scripts'));

fprintf('=== design generators (generators, not graders) ===\n');
fs = 1000;
[Nk, Wn, beta, ftype] = kaiserord([150 250], [1 0], [0.01 0.001], fs);
bK = fir1(Nk, Wn, ftype, kaiser(Nk+1, beta), 'noscale');
fprintf('kaiserord: N=%d (order %d), beta=%.4f, ftype=%s\n', Nk, Nk, beta, ftype);
rK = mas_filter_check(bK, 1, struct('fs', fs, 'type', 'lowpass', ...
    'fpass', 150, 'fstop', 250, 'astopDb', 50, 'apassDb', 0.5));
fg2 = linspace(0, 500, 20001).';            % contains 250 exactly
H2 = abs(freqz(bK, 1, fg2, 1000));
indWorst = -20*log10(max(H2(fg2 >= 250)));
edge = -20*log10(H2(fg2 == 250));
fprintf('  tool worst-over-band %.4f dB | independent 20001-grid %.4f dB | diff %.2e\n', ...
    rK.achieved.stopbandDb, indWorst, abs(rK.achieved.stopbandDb - indWorst));
fprintf('  edge-only value at 250 Hz: %.4f dB (the rule that would pass a bad design)\n', edge);
fprintf('  ripple %.4f dB vs hand 20*log10(1/cos(pi*150/1000)) = %.4f dB\n', ...
    rK.achieved.passbandRippleDb, 20*log10(1/cos(pi*150/1000)));

[Nb, Wb] = buttord(200/(fs/2), 300/(fs/2), 1, 30);
[bB, aB] = butter(Nb, Wb);
rB = mas_filter_check(bB, aB, struct('fs', fs, 'type', 'lowpass', ...
    'fpass', 200, 'fstop', 300, 'astopDb', 25));
fprintf('buttord: order %d -> tool stopband %.2f dB vs spec 25 dB | max pole %.4f\n', ...
    Nb, rB.achieved.stopbandDb, rB.achieved.maxPoleMag);

[Hh, Wnh, betah, ftypeh] = kaiserord([250 400], [0 1], [0.001 0.05], 1000);
bH = fir1(Hh, Wnh, ftypeh, kaiser(Hh+1, betah), 'noscale');
rH = mas_filter_check(bH, 1, struct('fs', 1000, 'type', 'highpass', ...
    'fpass', 400, 'fstop', 250, 'astopDb', 50, 'apassDb', 1));
fprintf('highpass kaiserord: N=%d, group delay %.4f (expected (N-1)/2 = %.1f)\n', ...
    Hh, rH.achieved.groupDelaySamples, (Hh-1)/2);

fprintf('\n=== closed forms ===\n');
zqLit = 1.959963984540054;
zqComputed = sqrt(2)*erfcinv(2*(1 - (1+0.95)/2));
fprintf('Wilson zq: literal %.15f vs erfcinv %.15f | diff %.1e\n', ...
    zqLit, zqComputed, abs(zqLit - zqComputed));
fprintf('Poisson zero-error bound: -ln(0.05)/1e6 = %.6e\n', -log(0.05)/1e6);

fprintf('\n=== comb-null hand algebra (worst-over-band ground truth) ===\n');
fprintf('|cos x * cos 2x| min = 2/(3 sqrt 6) = %.6f -> %.4f dB\n', ...
    2/(3*sqrt(6)), -20*log10(2/(3*sqrt(6))));