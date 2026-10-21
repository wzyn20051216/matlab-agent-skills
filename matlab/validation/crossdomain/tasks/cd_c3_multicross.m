function out = cd_c3_multicross()
%CD_C3_MULTICROSS  Control: a loop that crosses 0 dB TWICE, with a bad second margin.
%
% REFERENCE (id C3)
%   L(s) = 0.02*(s+2)/(s*(s+0.5)*(s^2+0.02s+1)).  The Q=50 resonance at 1 rad/s
%   lifts |L| back above 0 dB after the first crossing, so there are two downward
%   crossings: 12.7 mHz with PM +83 deg, and 162 mHz with PM -95 deg.
%   The loop is UNSTABLE, and a report that keeps only the first crossing (as
%   `margin()` does) calls it healthy with 83 degrees.
%
% This case exists because that exact mistake happened on the Boost converter in
% Phase 3B.2: the single-loop PI reported +38 deg at its first crossing and -18 deg
% at the second.

cd_setup();

s = tf('s');
L = 0.02*(s+2)/(s*(s+0.5)*(s^2+0.02*s+1));
r = mas_ctrl_analyze(L);

out.values = struct('nCross', r.nDown, 'pmWorst', r.pmWorst, ...
    'loopStable', double(strcmp(r.verdict, 'STABLE')), ...
    'firstPm', firstPm(r), 'nUp', r.nUp);
out.reference = struct('note', 'two downward crossings, worst margin is negative');
out.status = tern(r.nDown == 2 && r.pmWorst < 0, 'PASS', 'FAIL');
out.detail = sprintf('%d down-crossings, first PM %.1f, worst PM %.1f, %s', ...
    r.nDown, firstPm(r), r.pmWorst, r.verdict);
end

function v = firstPm(r)
d = r.crossings(strcmp({r.crossings.kind}, 'down'));
if isempty(d), v = NaN; else, [~, k] = min([d.f]); v = d(k).pm; end
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
