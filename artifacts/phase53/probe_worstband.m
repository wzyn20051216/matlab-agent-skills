function probe_worstband()
%PROBE_WORSTBAND  Hand-checkable worst-over-band case for mas_filter_check.
%
%   b = [1 1 1 1]/4 (4-tap moving sum), fs = 1000:
%     |H(f)| = |sin(4x)/(4 sin x)|, x = pi f/1000
%            = |cos x * cos 2x|      (after the double-angle identity)
%   Exact null at f = 250 Hz (4x = pi).
%   Max over [250, 500] at x = acos(1/sqrt(6)) = 1.1503 rad -> f = 366.12 Hz,
%   |H|max = 2/(3 sqrt 6) = 0.272166  ->  -20 log10(...) = 11.304 dB.
%
%   So an edge-only stopband rule sees ~70+ dB near fstop=250 and calls a
%   40 dB spec met; the worst-over-band rule sees 11.3 dB and fails it.

fs = 1000;
b = [1 1 1 1]/4;
x = @(f) pi*f/fs;
h = @(f) abs(cos(x(f)).*cos(2*x(f)));
f366 = fs/pi*acos(1/sqrt(6));
handMax = 2/(3*sqrt(6));
handAtt = -20*log10(handMax);
fprintf('hand: max |H| = %.6f at %.4f Hz, attenuation %.6f dB\n', handMax, f366, handAtt);
fprintf('check h(f366) = %.6f, null h(250) = %.3g\n', h(f366), h(250));

% the tool's own grid, finite values near the null
fgrid = linspace(0, fs/2, 4096).';
Hg = abs(freqz(b, 1, fgrid, fs));
near = abs(fgrid - 250) <= 0.2;
edgeAtt = -20*log10(max(Hg(near)));
band = fgrid >= 250;
worstAtt = -20*log10(max(Hg(band)));
[~, im] = max(Hg(band));
fprintf('grid: edge att near 250 Hz = %.2f dB; worst over [250,500] = %.4f dB at %.2f Hz\n', ...
    edgeAtt, worstAtt, fgrid(find(band, 1, 'first') + im - 1));

r = mas_filter_check(b, 1, struct('fs', fs, 'type', 'lowpass', ...
    'fpass', 200, 'fstop', 250, 'astopDb', 40));
fprintf('tool: verdict=%s stopbandDb=%.4f phase=%s ripple=%s\n', r.verdict, ...
    r.achieved.stopbandDb, ...
    r.checks(strcmp({r.checks.id}, 'phaseLinear')).status, ...
    r.checks(strcmp({r.checks.id}, 'passbandRipple')).status);
for k = 1:numel(r.checks)
    if ~strcmp(r.checks(k).status, 'pass')
        fprintf('  [%s] %s: %s\n', r.checks(k).status, r.checks(k).id, r.checks(k).detail);
    end
end

% independent worst-over-band recomputation for the kaiserord lowpass
[Nk, Wn, beta, ftype] = kaiserord([150 250], [1 0], [0.01 0.001], 1000);
bK = fir1(Nk, Wn, ftype, kaiser(Nk+1, beta), 'noscale');
rK = mas_filter_check(bK, 1, struct('fs', 1000, 'type', 'lowpass', ...
    'fpass', 150, 'fstop', 250, 'astopDb', 50, 'apassDb', 0.5));
fg2 = linspace(0, 500, 20001).';
H2 = abs(freqz(bK, 1, fg2, 1000));
indWorst = -20*log10(max(H2(fg2 >= 250)));
indEdge = -20*log10(max(abs(freqz(bK, 1, 250, 1000))));
fprintf('kaiser lp: tool=%.6f, independent=%.6f, edge=%.6f, diff=%.2e\n', ...
    rK.achieved.stopbandDb, indWorst, indEdge, abs(rK.achieved.stopbandDb - indWorst));
end