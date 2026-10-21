function res = test_robotics(verbose)
%TEST_ROBOTICS  Kinematics, Jacobian, IK, estimator consistency, frame hygiene.
%
%   res = test_robotics()
%
% Each case is graded against a value that does not come from the code under test:
% a finite-difference Jacobian, a closed-form 2R IK, the chi-square distribution,
% or the MathWorks rotation implementation where it is licensed. Every metric that
% could pass vacuously carries a negative control.

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
addpath(fullfile(repo, 'skills', 'matlab-robotics-autonomy', 'scripts'));

T = struct('name', {}, 'fn', {}, 'expect', {});

% ---------------- mas_kin_check ------------------------------------------
T(end+1) = tc('FK matches hand computation',   @() kc_fk(),        true);
T(end+1) = tc('Jacobian vs finite difference', @() kc_jac(),       true);
T(end+1) = tc('Jacobian holds for 4 links',    @() kc_jac4(),      true);
T(end+1) = tc('singular when fully extended',  @() kc_sing(),     true);
T(end+1) = tc('regular at generic pose',       @() kc_reg(),      true);
% negative control: the analytic J must NOT be the naive per-link derivative,
% which is the form you get by dropping the outer sum
T(end+1) = tc('neg: J differs from naive form', @() kc_negNaive(), true);
T(end+1) = tc('reach bound not exceeded',      @() kc_reach(),    true);
T(end+1) = tc('joint/link count mismatch',     @() kc_badSize(),  'ERR');
T(end+1) = tc('non-positive link rejected',   @() kc_badL(),     'ERR');

% ---------------- mas_kin_ik ---------------------------------------------
T(end+1) = tc('IK converges to interior target', @() ik_conv(),     true);
T(end+1) = tc('IK tip reaches the target',       @() ik_reach(),    true);
T(end+1) = tc('neg: normal eq blows up',         @() ik_neg(),      true);
T(end+1) = tc('infeasible target reported',      @() ik_infeas(),   true);
T(end+1) = tc('joint limits respected',          @() ik_limits(),   true);
T(end+1) = tc('neg: unreachable-under-limit fails', @() ik_negLim(), true);

% ---------------- mas_ekf_check ------------------------------------------
T(end+1) = tc('tuned filter is consistent',      @() ek_ok(),       true);
T(end+1) = tc('NIS matches measurement dim',     @() ek_nis(),      true);
T(end+1) = tc('neg: over-confident R rejected', @() ek_negR(),     true);
T(end+1) = tc('neg: over-confident Q rejected', @() ek_negQ(),     true);
T(end+1) = tc('seed reproduces the metric',      @() ek_repro(),    true);
% negative control: the band must be narrow enough to actually discriminate
T(end+1) = tc('neg: band separates the cases',   @() ek_negBand(),  true);

% ---------------- mas_frame_check -----------------------------------------
T(end+1) = tc('valid rotation passes',           @() fc_ok(),       true);
T(end+1) = tc('neg: near-orthonormal rejected', @() fc_near(),      true);
T(end+1) = tc('neg: reflection rejected',        @() fc_refl(),     true);
T(end+1) = tc('eul ZYX agrees with eul2rotm',   @() fc_eul(),      true);
T(end+1) = tc('eul ZYX differs from XYZ',        @() fc_seq(),      true);
T(end+1) = tc('quat agrees with quat2rotm',     @() fc_quat(),     true);
T(end+1) = tc('neg: unnormalised quat warned',  @() fc_quatNorm(), true);
T(end+1) = tc('neg: degrees-as-radians blocked', @() fc_deg(),     'ERR');
T(end+1) = tc('chain closes',                    @() fc_chain(),    true);
T(end+1) = tc('neg: broken chain rejected',      @() fc_negChain(), true);

nP = 0;
if verbose, fprintf('=== robotics tests ===\n'); end
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
    fprintf('\n---- %d / %d robotics cases passed ----\n', nP, numel(T));
end
end

% ===========================================================================
% mas_kin_check
% ===========================================================================
function v = kc_fk()
% 2R, L = [1 1], q = [0; pi/2] -> link1 along +x, link2 along +y -> tip (1,1)
r = mas_kin_check([1 1], [0; pi/2]);
v = norm(r.pos - [1; 1]) < 1e-12;
end

function v = kc_jac()
rng(5);
for t = 1:20
    q = 2*pi*rand(2,1) - pi;
    r = mas_kin_check([0.7 0.4], q);
    if ~(r.jacErr < 1e-6), v = false; return; end
end
v = true;
end

function v = kc_jac4()
rng(9);
for t = 1:10
    q = 2*pi*rand(4,1) - pi;
    r = mas_kin_check([0.5 0.4 0.3 0.2], q);
    if ~(r.jacErr < 1e-6), v = false; return; end
end
v = true;
end

function v = kc_sing()
% q = [0;0] puts both links along +x: tip at max reach, Jacobian rank 1
r = mas_kin_check([0.6 0.5], [0; 0]);
v = r.singular && r.condJ > 1e10;
end

function v = kc_reg()
r = mas_kin_check([0.6 0.5], [0.4; -1.1]);
v = ~r.singular && r.condJ < 1e6 && r.jacErr < 1e-6;
end

function v = kc_negNaive()
% The naive Jacobian differentiates each link's OWN angle only, forgetting that
% joint j also rotates every link beyond j. It must disagree with the numeric one.
L = [0.6 0.5 0.4];
q = [0.3; -0.7; 0.5];
r = mas_kin_check(L, q);
th = cumsum(q);
% Column 1 is -L.*sin(theta) (2 x n after transposing the n x 2 concatenation).
% Writing [-L(:).*sin(th(:))'; ...] instead makes L(:) (n x 1) meet a row vector
% and silently produces an n x n outer product -- the exact class of bug this
% test exists to catch, so the construction has to keep its orientations straight.
Jnaive = [-L(:).*sin(th(:)), L(:).*cos(th(:))].';   % outer sum dropped
errNaive = max(max(abs(Jnaive - r.Jnum)));
errReal  = max(max(abs(r.J - r.Jnum)));
v = (errNaive > 1e-3) && (errReal < 1e-9);
end

function v = kc_reach()
L = [0.5 0.4 0.3];
rng(17);
for t = 1:3000
    q = 2*pi*rand(3,1) - pi;
    rr = mas_kin_check(L, q);
    if norm(rr.pos) > rr.maxReach + 1e-9, v = false; return; end
end
v = true;
end

function v = kc_badSize()
try
    mas_kin_check([1 1], [0.1; 0.2; 0.3]);
    v = 'NO_ERROR';
catch
    v = 'ERR';
end
end

function v = kc_badL()
try
    mas_kin_check([1 -1], [0.1; 0.2]);
    v = 'NO_ERROR';
catch
    v = 'ERR';
end
end

% ===========================================================================
% mas_kin_ik
% ===========================================================================
function M = ik_model()
M.L = [0.6 0.5];
M.q0 = [0.3; -0.8];
M.p = [0.7; 0.35];
end

function v = ik_conv()
m = ik_model();
r = mas_kin_ik(m.L, m.p, m.q0);
v = r.converged && r.err <= 1e-10 && r.ok;
end

function v = ik_reach()
m = ik_model();
r = mas_kin_ik(m.L, m.p, m.q0);
v = norm(r.pos - m.p) < 1e-8;
end

function v = ik_neg()
% Measured on a near-singular configuration (q2 = 1e-4, arm almost straight) with
% a target demanding radial motion, i.e. motion in the direction the Jacobian
% cannot produce:
%     DLS raw step ~ 0.12 rad, normal-equations raw step ~ 6.4e3 rad
% and the ratio grows like 1/q2 as the configuration approaches the boundary.
% If stepRawMax stayed flat the metric would not be measuring conditioning at all.
L = [0.6; 0.5];
p = [0.95; 0.05];
o1 = struct('method','normal','maxIter',1);
o2 = struct('method','dls','lambda',1e-2,'maxIter',1);
a = mas_kin_ik(L, p, [0.2; 1e-4], o1);
b = mas_kin_ik(L, p, [0.2; 1e-4], o2);
v = isfinite(a.stepRawMax) && isfinite(b.stepRawMax) && ...
    (a.stepRawMax > 100 * b.stepRawMax);
end

function v = ik_infeas()
m = ik_model();
r = mas_kin_ik(m.L, [5; 0], m.q0);
v = ~r.feasible && r.nIter == 0 && ~r.ok && ~isempty(r.warnings);
end

function v = ik_limits()
% The target must be reachable INSIDE the limits, otherwise the honest answer is
% a failure and this test would be asserting the wrong thing. q* = [0.5; 0.4] sits
% within +/-1 rad, so a converged solution must also sit within them.
L = [0.6; 0.5];
qTrue = [0.5; 0.4];
th = cumsum(qTrue);
pT = [sum(L(:).*cos(th)); sum(L(:).*sin(th))];
r = mas_kin_ik(L, pT, [0.4; 0.3], struct('qMin', [-1; -1], 'qMax', [1; 1]));
v = r.converged && all(r.q >= -1 - 1e-12) && all(r.q <= 1 + 1e-12) && ...
    (norm(r.q - qTrue) < 1e-6);
end

function v = ik_negLim()
% A target the arm can only reach by violating the limits must FAIL, not return
% the nearest clamped pose as if it had succeeded. Straight up needs q1 = pi/2,
% which the +/-0.1 rad limits forbid, and the clamped result must be reported as
% a limit violation rather than passed off as a solution.
L = [0.6; 0.5];
p = [0.0; 1.0];
r = mas_kin_ik(L, p, [0.2; 0.2], struct('qMin', [-0.1; -0.1], 'qMax', [0.1; 0.1]));
v = ~r.converged && ~r.ok && r.limitHit && ~isempty(r.warnings);
end

% ===========================================================================
% mas_ekf_check
% ===========================================================================
function M = ek_model()
dt = 0.1;
q = 0.5;
M = struct('A', [1 dt; 0 1], 'H', [1 0], ...
           'Q', q*[dt^3/3 dt^2/2; dt^2/2 dt], 'R', 0.4, ...
           'x0', [0; 1], 'P0', eye(2));
end

function v = ek_ok()
r = mas_ekf_check(ek_model(), struct('nRuns', 120, 'nSteps', 60, 'seed', 7));
v = r.ok && ...
    (r.aneesMean >= r.aneesBand(1)) && (r.aneesMean <= r.aneesBand(2)) && ...
    (r.inBandFrac >= 0.90);
end

function v = ek_nis()
r = mas_ekf_check(ek_model(), struct('nRuns', 120, 'nSteps', 60, 'seed', 7));
% NIS targets the measurement dimension m = 1; allow generous count noise.
v = (r.nisMean > 0.5) && (r.nisMean < 2.0);
end

function v = ek_negR()
M = ek_model();
M.Rtrue = M.R;  M.R = M.R/100;      % filter believes the sensor is 100x better
r = mas_ekf_check(M, struct('nRuns', 120, 'nSteps', 60, 'seed', 7));
v = ~r.ok && (r.aneesMean > r.aneesBand(2));
end

function v = ek_negQ()
M = ek_model();
M.Qtrue = M.Q;  M.Q = M.Q/100;      % filter believes the model is 100x better
r = mas_ekf_check(M, struct('nRuns', 120, 'nSteps', 60, 'seed', 7));
v = ~r.ok && (r.aneesMean > r.aneesBand(2));
end

function v = ek_repro()
o = struct('nRuns', 60, 'nSteps', 40, 'seed', 31);
a = mas_ekf_check(ek_model(), o);
b = mas_ekf_check(ek_model(), o);
v = isequal(a.aneesMean, b.aneesMean);
end

function v = ek_negBand()
o = struct('nRuns', 120, 'nSteps', 60, 'seed', 7);
good = mas_ekf_check(ek_model(), o);
M = ek_model();  M.Rtrue = M.R;  M.R = M.R/100;
bad = mas_ekf_check(M, o);
% If the band were loose enough to contain both, the test would prove nothing.
v = (bad.aneesMean > 5 * good.aneesMean) && (bad.aneesMean > good.aneesBand(2));
end

% ===========================================================================
% mas_frame_check
% ===========================================================================
function v = fc_ok()
R = rotz(0.3)*roty(-0.2)*rotx(0.7);
r = mas_frame_check(R);
v = r.ok && (r.orthErr < 1e-12) && (abs(r.detR - 1) < 1e-12);
end

function v = fc_near()
% Stretch one column by 0.1 %: det barely moves, orthogonality does not survive.
R = rotz(0.3)*roty(-0.2)*rotx(0.7);
Rp = R;  Rp(:,2) = Rp(:,2)*1.001;
r = mas_frame_check(Rp);
v = ~r.ok && (r.orthErr > 1e-6) && (abs(r.detR - 1) < 1e-2);
end

function v = fc_refl()
R = rotz(0.4)*roty(0.3);
Rm = R;  Rm(:,3) = -Rm(:,3);           % mirror: still orthonormal, det = -1
r = mas_frame_check(Rm);
v = ~r.ok && (r.detR < 0) && (r.orthErr < 1e-12);
end

function v = fc_eul()
e = [0.31; -0.22; 0.75];
r = mas_frame_check(struct('eul', e, 'seq', 'ZYX'));
if ~r.crossCheck.checked
    v = r.ok;                            % no toolbox: at least it is a rotation
    return
end
v = r.ok && (r.crossCheck.maxDev < 1e-12);
end

function v = fc_seq()
e = [0.31; -0.22; 0.75];
a = mas_frame_check(struct('eul', e, 'seq', 'ZYX'));
b = mas_frame_check(struct('eul', e, 'seq', 'XYZ'));
v = a.ok && b.ok && (max(max(abs(a.R - b.R))) > 1e-3);
end

function v = fc_quat()
a = 0.6;
q = [cos(a/2); 0; 0; sin(a/2)];          % [w x y z], pure z rotation
r = mas_frame_check(struct('quat', q));
expected = rotz(a);
same = max(max(abs(r.R - expected))) < 1e-12;
if ~r.crossCheck.checked
    v = r.ok && same;
    return
end
v = r.ok && same && (r.crossCheck.maxDev < 1e-12);
end

function v = fc_quatNorm()
q = 2*[cos(0.3); 0; 0; sin(0.3)];
r = mas_frame_check(struct('quat', q));
v = ~r.ok && any(contains(r.warnings, 'norm'));
end

function v = fc_deg()
try
    mas_frame_check(struct('eul', [10; 20; 30], 'seq', 'ZYX'));
    v = 'NO_ERROR';
catch
    v = 'ERR';
end
end

function v = fc_chain()
% T_ab * T_bc * T_ca must be I when T_ca is the inverse of the first two.
T1 = se3(rotz(0.4), [1; 0.2; 0]);
T2 = se3(roty(-0.3), [0.1; 0; 0.5]);
T3 = inv(T1*T2);
r = mas_frame_check(cat(3, T1, T2, T3), struct('closedLoop', true));
v = r.ok && (r.closureErr < 1e-10);
end

function v = fc_negChain()
T1 = se3(rotz(0.4), [1; 0.2; 0]);
T2 = se3(roty(-0.3), [0.1; 0; 0.5]);
T3 = inv(T1*T2);
T3(1:3,4) = T3(1:3,4) + [0.05; 0; 0];   % one link mis-specified
r = mas_frame_check(cat(3, T1, T2, T3), struct('closedLoop', true));
v = ~r.ok && (r.closureErr > 1e-3);
end

function T = se3(R, p)
T = eye(4);
T(1:3,1:3) = R;
T(1:3,4) = p;
end

function R = rotx(a)
R = [1 0 0; 0 cos(a) -sin(a); 0 sin(a) cos(a)];
end
function R = roty(a)
R = [cos(a) 0 sin(a); 0 1 0; -sin(a) 0 cos(a)];
end
function R = rotz(a)
R = [cos(a) -sin(a) 0; sin(a) cos(a) 0; 0 0 1];
end

% ===========================================================================
function t = tc(name, fn, expect)
t = struct('name', name, 'fn', fn, 'expect', expect);
end
function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
