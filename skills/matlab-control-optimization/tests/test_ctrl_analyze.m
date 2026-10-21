function res = test_ctrl_analyze(verbose)
%TEST_CTRL_ANALYZE  Pins the control analysis on three KNOWN systems plus edge cases.
%
%   res = test_ctrl_analyze()
%
% The three required cases are a known-stable loop, a known-unstable plant and a
% multi-crossing loop. The fourth case is the one that matters most: the multi-
% crossing loop must be reported as unstable even though its FIRST crossing has 83
% degrees of margin, because that is where `margin()` alone misleads.

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
addpath(fullfile(repo, 'skills', 'matlab-control-optimization', 'scripts'));

T = struct('name', {}, 'fn', {}, 'expect', {});

% ---- 1. known stable -------------------------------------------------------
T(end+1) = tc('C1 stable: PM 95.74 deg', @() begin(), 95.74);
T(end+1) = tc('C1 stable: one crossing', @() count_of(tf(10, [1 1])), 1);

% ---- 2. known unstable -----------------------------------------------------
T(end+1) = tc('C2 unstable: 1 RHP pole', @() rhp_of(tf(1, [1 1 -2])), 1);
T(end+1) = tc('C2 unstable: verdict', @() verdict_of(tf(1, [1 1 -2])), 'UNSTABLE');

% ---- 3. multi-crossing -----------------------------------------------------
s = tf('s');
L3 = 0.02*(s + 2)/(s*(s + 0.5)*(s^2 + 0.02*s + 1));
T(end+1) = tc('C3: two downward crossings', @() count_of(L3), 2);
T(end+1) = tc('C3: worst PM is negative', @() sign_of_worst(L3), 'negative');
T(end+1) = tc('C3: first crossing looks fine', @() first_pm_above(L3, 45), true);
T(end+1) = tc('C3: verdict UNSTABLE', @() verdict_of(L3), 'UNSTABLE');

% ---- 4. discrete loop ------------------------------------------------------
% A discretised version of the stable loop must still be stable and its poles must
% be inside the unit circle: if the discrete branch silently treated them as
% continuous, maxPole would be near 1 and the margin would move.
T(end+1) = tc('discrete: poles inside unit circle', @() max_pole_of(c2d(tf(10, [1 1]), 0.01)), 'lt1');
T(end+1) = tc('discrete: still stable', @() verdict_of(c2d(tf(10, [1 1]), 0.01)), 'STABLE');

% ---- 5. delay --------------------------------------------------------------
% A delay cannot change |L|, so it can only reduce the phase margin.
T(end+1) = tc('delay reduces PM', @() delay_reduces(tf(10, [1 1]), 0.05), true);

% ---- 6. PID design ---------------------------------------------------------
T(end+1) = tc('PID design meets PM target', @() pid_meets(tf(1, [1 1 0]), 50), true);
T(end+1) = tc('PID design refuses impossible target', @() pid_refuses(tf(1, [1 1 0]), 179), true);

% ---- 7. anti-windup --------------------------------------------------------
T(end+1) = tc('anti-windup reduces overshoot', @() aw_helps(), true);

nP = 0;
if verbose, fprintf('=== control analysis tests ===\n'); end
R = struct('case', {}, 'got', {}, 'pass', {});
for k = 1:numel(T)
    t = T(k);
    try
        got = t.fn();
    catch ME
        got = ['ERROR: ' ME.message];
    end
    if ischar(t.expect)
        ok = strcmp(char(string(got)), t.expect);
    else
        ok = isequal(got, t.expect);
    end
    nP = nP + ok;
    if verbose
        fprintf('  [%s] %-36s -> %s\n', tern(ok, 'PASS', 'FAIL'), t.name, strtrim(string(got)));
    end
    R(end+1) = struct('case', t.name, 'got', char(string(got)), 'pass', ok); %#ok<AGROW>
end

res = struct('nPass', nP, 'nTotal', numel(T), 'cases', R, 'pass', nP == numel(T));
if verbose
    fprintf('\n---- %d / %d control cases passed ----\n', nP, numel(T));
end
end

% ---------------------------------------------------------------------------
function v = begin()
r = mas_ctrl_analyze(tf(10, [1 1]));
v = round(r.pmWorst*100)/100;
end
function n = count_of(L)
r = mas_ctrl_analyze(L); n = r.nDown;
end
function n = rhp_of(L)
r = mas_ctrl_analyze(L); n = r.rhpPoles;
end
function s = verdict_of(L)
r = mas_ctrl_analyze(L); s = r.verdict;
end
function s = sign_of_worst(L)
r = mas_ctrl_analyze(L);
if r.pmWorst < 0, s = 'negative'; else, s = 'positive'; end
end
function tf_ = first_pm_above(L, lim)
r = mas_ctrl_analyze(L);
d = r.crossings(strcmp({r.crossings.kind}, 'down'));
[~, k] = min([d.f]);
tf_ = d(k).pm > lim;
end
function s = max_pole_of(L)
r = mas_ctrl_analyze(L);
if r.maxPole < 1, s = 'lt1'; else, s = 'ge1'; end
end
function ok = delay_reduces(L, Td)
% A delay leaves |L| untouched, so the temptation is to assert "GM unchanged". That
% is WRONG, and the first version of this test said so and failed:
% a first-order loop never reaches -180 deg, so its GM is Inf; add 0.05 s of delay
% and the phase now crosses -180 at 5.1 Hz where |L| = 0.31, i.e. a REAL gain margin
% of 10.1 dB. A delay does not change the magnitude, it changes how many times the
% phase passes -180 -- and therefore whether a gain margin exists at all.
a = mas_ctrl_analyze(L);
b = mas_ctrl_analyze(L, struct('delay', Td));
ok = (b.pmWorst < a.pmWorst - 1) && isinf(a.gmWorst) && isfinite(b.gmWorst) && b.gmWorst > 0;
end
function ok = pid_meets(P, pmT)
d = mas_ctrl_pid_design(P, struct('pmTarget', pmT, 'gmTarget', 6));
ok = d.feasible && d.pm >= pmT;
end
function ok = pid_refuses(P, pmT)
% 179 degrees is not achievable for this plant; the design must say so instead of
% returning the least-bad candidate as if it had met the target.
d = mas_ctrl_pid_design(P, struct('pmTarget', pmT, 'gmTarget', 6));
ok = ~d.feasible && isnan(d.Kp) && ~isempty(d.reason);
end
function ok = aw_helps()
P = tf(1, [1 1]);
base = struct('Kp', 6, 'Ki', 12, 'uMin', 0, 'uMax', 1.2, 'Ts', 0.01, 'Tt', 0.02);
o = struct('tEnd', 4, 'dt', 0.001, 'ref', 1, 'dist', -0.2, 'loadTime', 2);
a = base; a.aw = 'none';
b = base; b.aw = 'backcalc';
ra = mas_ctrl_aw_sim(P, a, o);
rb = mas_ctrl_aw_sim(P, b, o);
ok = (rb.overshootPct < ra.overshootPct) && (rb.windupExcursion < ra.windupExcursion);
end

function t = tc(name, fn, expect)
t = struct('name', name, 'fn', fn, 'expect', expect);
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
