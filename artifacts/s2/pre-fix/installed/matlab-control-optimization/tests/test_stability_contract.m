function res = test_stability_contract(verbose)
%TEST_STABILITY_CONTRACT  Boundary tests for the stability / target / evidence split.
%
%   res = test_stability_contract()
%
% The cases are chosen so that each one fails for a DIFFERENT reason if the
% analysis collapses the three questions into one:
%
%   * a negative-gain loop whose 0 dB crossing looks healthy (PM +84 deg by the
%     naive formula) but whose closed loop has a pole at +9 -- `margin` reports
%     Pm=-84.26 and GM=0.1 at w=0; a frequency-only reader reports STABLE.
%   * a loop whose gain is exactly unity at DC: the only phase margin lives at
%     w=0, so a grid that starts just above DC reports "no crossing".
%   * a double integrator: angle() folds -180 to +180 and a naive PM becomes 360.
%   * a discrete loop whose -180 crossing is exactly at the Nyquist frequency.
%   * a loop with no 0 dB crossing at all: math is stable, the target is
%     undetermined, and that must not turn into a fabricated PASS.
%
% The official `margin`/`allmargin` results are used as an independent reference
% for the PM/GM values (not as the implementation).

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
addpath(fullfile(repo, 'skills', 'matlab-control-optimization', 'scripts'));
addpath(fullfile(repo, 'skills', 'matlab-testing-ci', 'scripts'));

T = struct('name', {}, 'fn', {}, 'expect', {});

s = tf('s');
Lstable = tf(10, [1 1]);
Lneg    = tf(-10, [1 1]);
Ldc     = tf(1, [1 1]);
Lstatic = tf(0.5, 1);
Lmulti  = 0.02*(s + 2)/(s*(s + 0.5)*(s^2 + 0.02*s + 1));
Lint2   = tf(1, [1 0 0]);
Ldisc   = c2d(Lstable, 0.01);

% ---- legacy analyzer: three real false conclusions ------------------------
T(end+1) = tc('A1 negative gain: not STABLE', @() ~strcmp(verdict_of(Lneg), 'STABLE'), true);
T(end+1) = tc('A2 negative gain: GM is negative at DC', @() signed_gm(Lneg), 'negative');
T(end+1) = tc('A3 negative gain: CL pole is in RHP', @() cl_rhp_count(Lneg), 1);
T(end+1) = tc('A4 DC-unity loop: PM is finite (evaluated at w=0)', @() isfinite(pm_of(Ldc)), true);
T(end+1) = tc('A5 double integrator: not STABLE', @() ~strcmp(verdict_of(Lint2), 'STABLE'), true);
T(end+1) = tc('A6 discrete loop: finite GM at Nyquist', @() finite_gm(Ldisc), true);
T(end+1) = tc('A7 discrete loop: GM matches |L(pi/Ts)| analytically', @() gm_matches_nyquist(Ldisc), true);
T(end+1) = tc('A8 C3 multi-cross: UNSTABLE', @() strcmp(verdict_of(Lmulti), 'UNSTABLE'), true);
T(end+1) = tc('A9 known stable: STABLE', @() strcmp(verdict_of(Lstable), 'STABLE'), true);

% ---- official API return-order contract (G1) -----------------------------
T(end+1) = tc('B1 margin(): Gm is an absolute ratio, not dB', @() margin_gm_ratio(Lstable), true);
T(end+1) = tc('B2 margin(): Pm sign at 0 dB crossing', @() margin_pm_sign(Lstable), 'positive');
T(end+1) = tc('B3 allmargin(): negative-gain Pm is negative', @() allmargin_pm(Lneg), 'negative');
T(end+1) = tc('B4 analyzer PM agrees with allmargin (negative gain)', @() pm_close(Lneg, -84.26082945, 0.05), true);
T(end+1) = tc('B5 analyzer worst PM agrees with allmargin (multi-cross)', @() pm_close(Lmulti, -95.43081443, 0.05), true);

% ---- three-dimensional contract ------------------------------------------
T(end+1) = tc('C1 stable loop: STABLE / PASS / VERIFIED', @() tri(Lstable, struct(), ...
    'STABLE', 'PASS', 'VERIFIED'), true);
T(end+1) = tc('C2 negative gain: UNSTABLE / FAIL / VERIFIED', @() tri(Lneg, struct(), ...
    'UNSTABLE', 'FAIL', 'VERIFIED'), true);
T(end+1) = tc('C3 multi-cross: UNSTABLE / FAIL / VERIFIED', @() tri(Lmulti, struct(), ...
    'UNSTABLE', 'FAIL', 'VERIFIED'), true);
T(end+1) = tc('C4 DC-unity: STABLE / PASS / VERIFIED', @() tri(Ldc, struct(), ...
    'STABLE', 'PASS', 'VERIFIED'), true);
T(end+1) = tc('C5 no crossing: STABLE / UNDETERMINED / PARTIAL', @() tri(Lstatic, struct(), ...
    'STABLE', 'UNDETERMINED', 'PARTIAL'), true);
T(end+1) = tc('C6 target not met: STABLE / FAIL / VERIFIED', @() tri(Lstable, ...
    struct('pmTarget', 120), 'STABLE', 'FAIL', 'VERIFIED'), true);
T(end+1) = tc('C7 discrete loop: STABLE / PASS / VERIFIED', @() tri(Ldisc, struct(), ...
    'STABLE', 'PASS', 'VERIFIED'), true);
T(end+1) = tc('C8 marginal poles: UNSTABLE with marginal flag', @() marginal_flag(Lint2), true);
T(end+1) = tc('C9 empty input: UNDETERMINED / UNDETERMINED / NOT VERIFIED', @() tri([], struct(), ...
    'UNDETERMINED', 'UNDETERMINED', 'NOT VERIFIED'), true);
T(end+1) = tc('C10 NaN model never passes', @() tri(tf(NaN, [1 1]), struct(), ...
    'UNDETERMINED', 'UNDETERMINED', 'NOT VERIFIED'), true);
T(end+1) = tc('C11 Inf model never passes', @() tri(tf(Inf, [1 1]), struct(), ...
    'UNDETERMINED', 'UNDETERMINED', 'NOT VERIFIED'), true);
T(end+1) = tc('C12 non-result struct is rejected', @() tri(struct('x', 1), struct(), ...
    'UNDETERMINED', 'UNDETERMINED', 'NOT VERIFIED'), true);

% ---- units ----------------------------------------------------------------
T(end+1) = tc('D1 Hz vs rad/s bounds describe the same loop', @() unit_equiv(Lstable), true);
T(end+1) = tc('D2 crossing frequencies obey w = 2*pi*f', @() unit_consistency(Lmulti), true);
T(end+1) = tc('D3 unit tag is echoed', @() unit_tag(Lstable), 'rad/s');

% ---- grading cannot pass on missing evidence ------------------------------
T(end+1) = tc('E1 empty domain value is not a PASS', @() grade_case('domain', [], NaN, 0.5), 'notpass');
T(end+1) = tc('E2 NaN numeric value fails', @() grade_case('numeric', NaN, 1, 0.01), 'FAIL');
T(end+1) = tc('E3 Inf reference is rejected', @() grade_case('numeric', 1, Inf, 0.01), 'FAIL');

nP = 0;
if verbose, fprintf('=== stability contract tests ===\n'); end
R = struct('case', {}, 'got', {}, 'pass', {});
for k = 1:numel(T)
    t = T(k);
    try
        got = t.fn();
    catch ME
        got = ['ERROR: ' ME.identifier ' :: ' ME.message];
    end
    ok = false;
    if ischar(t.expect)
        if strcmp(t.expect, 'notpass')
            ok = ~strcmp(char(string(got)), 'PASS');
        else
            ok = strcmp(char(string(got)), t.expect);
        end
    else
        ok = isequal(got, t.expect);
    end
    nP = nP + ok;
    if verbose
        fprintf('  [%s] %-52s -> %s\n', tern(ok, 'PASS', 'FAIL'), t.name, strtrim(string(got)));
    end
    R(end+1) = struct('case', t.name, 'got', char(string(got)), 'pass', ok); %#ok<AGROW>
end

res = struct('nPass', nP, 'nTotal', numel(T), 'cases', R, 'pass', nP == numel(T));
if verbose
    fprintf('\n---- %d / %d stability-contract cases passed ----\n', nP, numel(T));
end
end

% ---------------------------------------------------------------------------
function v = verdict_of(L)
r = mas_ctrl_analyze(L); v = r.verdict;
end
function s = signed_gm(L)
r = mas_ctrl_analyze(L);
if r.gmWorst < 0, s = 'negative'; else, s = 'notnegative'; end
end
function n = cl_rhp_count(L)
r = mas_ctrl_analyze(L);
if isfield(r, 'closedLoopPoles')
    if L.Ts > 0, n = sum(abs(r.closedLoopPoles) > 1);
    else, n = sum(real(r.closedLoopPoles) > 0); end
else
    error('closedLoopPoles field missing');
end
end
function tf_ = isfinite_local(x), tf_ = isfinite(x); end %#ok<DEFNU>
function p = pm_of(L), r = mas_ctrl_analyze(L); p = r.pmWorst; end
function tf_ = finite_gm(L), r = mas_ctrl_analyze(L); tf_ = isfinite(r.gmWorst); end
function tf_ = gm_close(L, target, tol), r = mas_ctrl_analyze(L); tf_ = abs(r.gmWorst - target) <= tol; end
function tf_ = gm_matches_nyquist(L)
% Independent reference: evaluate the sampled loop at z = -1 directly. For this
% system |L(pi/Ts)| = 0.05, i.e. GM = 26.0207 dB. `allmargin` reports
% GainMargin = 20.0002, which is the ABSOLUTE ratio 1/0.05, not dB -- the exact
% unit confusion this test exists to prevent.
ref = -20*log10(abs(freqresp(L, pi/L.Ts)));
r = mas_ctrl_analyze(L);
tf_ = isfinite(r.gmWorst) && abs(r.gmWorst - ref) < 1e-6;
end

function tf_ = margin_gm_ratio(L) %#ok<INUSD>
% MATLAB returns Gm as an ABSOLUTE ratio, while a report in dB must take
% 20*log10(Gm). For L=30/((s+1)(s+2)(s+3)): at phase -180, w=sqrt(11) and
% |L|=30/60=0.5, so Gm=2 (6.02 dB). Reading the returned 2 AS dB understates the
% margin by 4 dB.
L2 = tf(30, [1 6 11 6]);
[G2, P2, Wg2, Wp2] = margin(L2);
tf_ = (abs(G2 - 2) < 0.01) && (abs(20*log10(G2) - 6.0206) < 0.02) && ...
      (abs(G2 - 6.0206) > 1) && ...
      (abs(Wg2 - sqrt(11)) < 0.01) && (P2 > 20) && (P2 < 30) && (Wp2 < Wg2);
end
function s = margin_pm_sign(L)
[~, Pm] = margin(L);
if Pm > 0, s = 'positive'; else, s = 'negative'; end
end
function s = allmargin_pm(L)
S = allmargin(L);
if min(S.PhaseMargin) < 0, s = 'negative'; else, s = 'positive'; end
end
function tf_ = pm_close(L, ref, tol)
r = mas_ctrl_analyze(L);
tf_ = isfinite(r.pmWorst) && abs(r.pmWorst - ref) <= tol;
end

function tf_ = tri(L, opts, wantMath, wantTarget, wantEvidence)
r = mas_stability_verdict(L, opts);
tf_ = strcmp(r.math.stability, wantMath) && ...
      strcmp(r.target.status, wantTarget) && ...
      strcmp(r.evidence.quality, wantEvidence);
if ~tf_
    error('got math=%s target=%s evidence=%s notes=%s', r.math.stability, ...
        r.target.status, r.evidence.quality, strjoin(r.notes, ' | '));
end
end
function tf_ = marginal_flag(L)
r = mas_stability_verdict(L);
tf_ = strcmp(r.math.stability, 'UNSTABLE') && r.math.marginal;
end
function tf_ = unit_equiv(L)
a = mas_stability_verdict(L, struct('wmin', 0.1, 'wmax', 1000, 'freqUnit', 'rad/s'));
b = mas_stability_verdict(L, struct('wmin', 0.1/(2*pi), 'wmax', 1000/(2*pi), 'freqUnit', 'Hz'));
tf_ = strcmp(a.math.stability, b.math.stability) && ...
      strcmp(a.target.status, b.target.status) && ...
      abs(a.target.pm - b.target.pm) < 1e-6;
end
function tf_ = unit_consistency(L)
r = mas_ctrl_analyze(L);
f = [r.crossings.f];
w = [r.crossings.wRadPerSec];
tf_ = all(abs(w - 2*pi*f) <= 1e-9*max(1, abs(w)));
end
function s = unit_tag(L)
r = mas_stability_verdict(L, struct('freqUnit', 'rad/s'));
s = r.evidence.freqUnit;
end
function s = grade_case(kind, value, ref, tol)
if strcmp(kind, 'domain')
    c = struct('id', 'd', 'executed', true, 'kind', 'domain', 'value', value, ...
        'reference', NaN, 'tol', NaN, 'limit', ref, 'cmp', 'le', 'reason', '');
else
    c = struct('id', 'n', 'executed', true, 'kind', 'numeric', 'value', value, ...
        'reference', ref, 'tol', tol, 'limit', NaN, 'cmp', 'le', 'reason', '');
end
r = mas_grade(c);
s = r.overall;
end

function t = tc(name, fn, expect)
t = struct('name', name, 'fn', fn, 'expect', expect);
end
function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
