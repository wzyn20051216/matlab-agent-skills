function out = cd_c1_stable()
%CD_C1_STABLE  Control: a plant whose margins are known in closed form.
%
% REFERENCE (frozen in evals/references/reference_manifest.json, id C1)
%   L(s) = 10/(s+1). |L|=1 at w = sqrt(100-1), phase = -atan(w), so
%   PM = 180 - atan(9.9499) = 95.739 deg at 1.5836 Hz, one crossing, no GM limit.
%   Two independent routes (closed form and a numeric sweep) agree to 9e-12.

cd_setup();

L = tf(10, [1 1]);
r = mas_ctrl_analyze(L);

out.values = struct('fcHz', lowestCross(r), 'pmDeg', r.pmWorst, ...
    'nCross', r.nDown, 'closedLoopStable', double(strcmp(r.verdict, 'STABLE')));
out.reference = struct('note', 'analytic first-order loop');
out.status = tern(strcmp(r.verdict, 'STABLE'), 'PASS', 'FAIL');
out.detail = r.detail;
end

function f = lowestCross(r)
d = r.crossings(strcmp({r.crossings.kind}, 'down'));
if isempty(d), f = NaN; else, f = min([d.f]); end
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
