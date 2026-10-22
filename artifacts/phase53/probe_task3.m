%% Probe: ground the four robotics contract tools.
clear functions; rehash;
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(here));
addpath(fullfile(repo, 'skills', 'matlab-robotics-autonomy', 'scripts'));

disp('===== QUAT =====');
a = 0.6;
q = [cos(a/2); 0; 0; sin(a/2)];
qz = @(x) [cos(x/2); 0; 0; sin(x/2)];
q2 = qz(0.4);
Rz = @(x) [cos(x) -sin(x) 0; sin(x) cos(x) 0; 0 0 1];
qe = qz(pi/2);
ts = [0 0.25 0.5 0.75 1];
expq = zeros(4, numel(ts));
for k = 1:numel(ts), expq(:,k) = qz(a + ts(k)*(pi/2 - a)); end
Q1 = mas_quat_check(q, struct('matrix', Rz(a), 'angle', a, 'axis', [0;0;1], ...
    'rotvec', [0;0;a], 'compose', q2, 'interp', struct('qEnd',qe,'t',ts,'expected',expq)));
rep('Q1 full', Q1);
Q2 = mas_quat_check(2*q);
rep('Q2 non-unit', Q2);
Q3 = mas_quat_check(q, struct('matrix', Rz(a+0.1)));
rep('Q3 wrong R', Q3);
Q4 = mas_quat_check(q, struct('angle', a+0.1, 'axis', [1;0;0], 'rotvec', [0;0;a+0.1]));
rep('Q4 wrong angle/axis', Q4);
Q5 = mas_quat_check(q, struct('interp', struct('qEnd',qe,'t',ts, ...
    'expected', [expq(:,1:4) expq(:,5)*0.9+0.1])));
rep('Q5 wrong slerp', Q5);
Q6 = mas_quat_check([1;0;0;0], struct('axis', [1;0;0]));
rep('Q6 identity axis', Q6);
Q7 = mas_quat_check(-q);
rep('Q7 -q', Q7);
Q8 = mas_quat_check([0;1;0;0], struct('angle', pi, 'axis', [-1;0;0], 'rotvec', [pi;0;0]));
rep('Q8 180 axis sign', Q8);
try, mas_quat_check([0;0;0;0]); catch, disp('Q9 zero -> ERR'); end
Q10 = mas_quat_check(q, struct('compose', 2*q2));
rep('Q10 non-unit compose', Q10);

disp('===== TRAJ =====');
t = (0:0.01:1).';
Qc = [sin(pi*t), cos(pi*t)];
V = [pi*cos(pi*t), -pi*sin(pi*t)];
A = [-pi^2*sin(pi*t), -pi^2*cos(pi*t)];
wp = struct('t', {0, 0.5, 1}, 'q', {Qc(1,:), Qc(51,:), Qc(end,:)});
T1 = mas_traj_check(t, Qc, struct('waypoints', wp, 'vel', V, 'acc', A, ...
    'vMax', 4, 'aMax', 12, 'qMin', -2, 'qMax', 2));
rep('T1 good', T1);
T2 = mas_traj_check(t, Qc, struct('waypoints', wp, 'vel', V, 'acc', A, 'vMax', 2));
rep('T2 v limit', T2);
Qbad = Qc; Qbad(51,1) = Qbad(51,1) + 0.1;
T3 = mas_traj_check(t, Qbad, struct('waypoints', wp, 'vel', V, 'acc', A));
rep('T3 miss wp', T3);
tb = t; tb(30) = tb(29);
T4 = mas_traj_check(tb, Qc, struct('vMax', 4));
rep('T4 backwards time', T4);
T5 = mas_traj_check(t, Qc, struct('vel', 2*V, 'acc', A));
rep('T5 wrong analytic vel', T5);
T6 = mas_traj_check(t, Qc, struct('vMax', 4, 'aMax', 12, 'qMin', -2, 'qMax', 2));
rep('T6 sampled only', T6);
T7 = mas_traj_check(t, Qc, struct('qMin', 0.5));
rep('T7 position limit', T7);
try, mas_traj_check(t, Qc, struct()); catch, disp('T8 no claims -> ERR'); end
try, mas_traj_check(t(1), Qc(1,:), struct('vMax', 1)); catch, disp('T9 one sample -> ERR'); end

disp('===== DYN =====');
p = struct('m1', 1.2, 'm2', 0.8, 'l1', 0.5, 'l2', 0.4);
pf = struct('m1', 1.2, 'm2', 0.8, 'l1', 0.5, 'l2', 0.4, 'lc1', 0.25, 'lc2', 0.2, ...
    'I1', 1.2*0.5^2/12, 'I2', 0.8*0.4^2/12, 'g', 9.81);
q0 = [0.4; -0.7]; qd0 = [0.3; -0.2];
D1 = mas_dyn_check(p, q0, qd0);
rep('D1 reference', D1);
D2 = mas_dyn_check(p, q0, qd0, struct('M', D1.Mref + [0 0.1; 0.1 0]));
rep('D2 wrong M', D2);
D3 = mas_dyn_check(p, q0, qd0, struct('C', -D1.Cref));
rep('D3 wrong C', D3);
D4 = mas_dyn_check(p, q0, qd0, struct('g', -D1.gref));
rep('D4 wrong g', D4);
Ms = D1.Mref; Ms(1,2) = Ms(1,2) + 1e-3;
D5 = mas_dyn_check(p, q0, qd0, struct('M', Ms));
rep('D5 asym M', D5);
D6 = mas_dyn_check(p, q0, qd0, struct('M', [1 2; 2 1]));
rep('D6 non-PD M', D6);
D7 = mas_dyn_check(p, q0, qd0, struct('M', D1.Mref, 'C', D1.Cref, 'g', D1.gref));
rep('D7 exact claims', D7);
D10 = mas_dyn_check(p, q0, qd0, struct('model', @(qq, qqd) dyn_wrongC(pf, qq, qqd)));
rep('D10 wrong C model', D10);
try, mas_dyn_check(struct('m1',1,'m2',1,'l1',1), q0, qd0); catch, disp('D8 missing param -> ERR'); end
try, mas_dyn_check(struct('m1',-1,'m2',1,'l1',1,'l2',1), q0, qd0); catch, disp('D9 negative mass -> ERR'); end
fprintf('D1 vals: M11 %.6f M12 %.6f M22 %.6f | C11 %.6f C12 %.6f C21 %.6f | g %.6f %.6f\n', ...
    D1.Mref(1,1), D1.Mref(1,2), D1.Mref(2,2), D1.Cref(1,1), D1.Cref(1,2), ...
    D1.Cref(2,1), D1.gref(1), D1.gref(2));

disp('===== EST =====');
[truth, est, P, nu, S] = kf_data(20261021, 50, 100, 10);
E1 = mas_estimate_check(truth, est, P);
rep('E1 correct', E1);
E2 = mas_estimate_check(truth, est, P/100);
rep('E2 overconfident', E2);
E3 = mas_estimate_check(truth, est, P*100);
rep('E3 underconfident', E3);
Pnp = P; Pnp(:,:,20,1) = [1 2; 2 1];
E4 = mas_estimate_check(truth, est, Pnp);
rep('E4 non-PD', E4);
Pas = P; Pas(1,2,20,1) = Pas(1,2,20,1) + 0.01;
E5 = mas_estimate_check(truth, est, Pas);
rep('E5 asym', E5);
E6 = mas_estimate_check(truth, est + 0.5, P, struct('maxBias', 0.1));
rep('E6 biased', E6);
E7 = mas_estimate_check(truth(:,:,1:5), est(:,:,1:5), P(:,:,:,1:5));
rep('E7 too few runs', E7);
E8 = mas_estimate_check(truth, est, P, struct('burnIn', 46));
rep('E8 burnIn', E8);
rng(7);
nw = zeros(50,1,100);
for rr = 1:100
    nw(1,1,rr) = randn;
    for k = 2:50, nw(k,1,rr) = 0.8*nw(k-1,1,rr) + randn; end
end
E9 = mas_estimate_check(truth, est, P, struct('innovation', nw, 'S', 1));
rep('E9 correlated nu', E9);
rng(8);
ww = randn(50,1,100);
E10 = mas_estimate_check(truth, est, P, struct('innovation', ww, 'S', 1));
rep('E10 white nu', E10);
fprintf('E1 anees %.4f meanBand [%.4f %.4f] stepBand [%.4f %.4f] inFrac %.2f neesN %d\n', ...
    E1.aneesMean, E1.aneesBand(1), E1.aneesBand(2), E1.aneesStepBand(1), ...
    E1.aneesStepBand(2), E1.inBandFrac, E1.neesSamples);
fprintf('E1 bias norm %.4f, E10 maxAc %.4f thr %.4f, E9 maxAc %.4f\n', ...
    E1.biasNorm, E10.maxAutocorr, E10.whitenessThreshold, E9.maxAutocorr);
fprintf('E4 minEig %.3f, E2 anees %.1f, E3 anees %.4f\n', E4.minEigP, E2.aneesMean, E3.aneesMean);

% -------------------------------------------------------------------------
function rep(label, r)
st = 'PASS';
if strcmp(r.verdict, 'FAIL'), st = 'FAIL'; elseif strcmp(r.verdict, 'UNDETERMINED'), st = 'UNDET'; end
fprintf('%-24s %-5s : %s\n', label, st, r.detail);
for k = 1:numel(r.checks)
    c = r.checks(k);
    fprintf('    %-28s %-13s %s\n', c.id, c.status, c.detail);
end
end

function [M, C, g] = dyn_wrongC(p, q, qd)
c2 = cos(q(2)); s2 = sin(q(2));
M11 = p.I1 + p.I2 + p.m1*p.lc1^2 + p.m2*(p.l1^2 + p.lc2^2 + 2*p.l1*p.lc2*c2);
M12 = p.I2 + p.m2*(p.lc2^2 + p.l1*p.lc2*c2);
M = [M11 M12; M12 p.I2 + p.m2*p.lc2^2];
h = p.m2*p.l1*p.lc2*s2;
C = [h*qd(2), h*(qd(1)+qd(2)); -h*qd(1), 0];
g = [(p.m1*p.lc1 + p.m2*p.l1)*p.g*cos(q(1)) + p.m2*p.lc2*p.g*cos(q(1)+q(2)); ...
     p.m2*p.lc2*p.g*cos(q(1)+q(2))];
end

function [truth, est, P, nu, S] = kf_data(seed, N, R, burn)
dt = 0.1; Q = 0.05*[dt^3/3 dt^2/2; dt^2/2 dt]; Rm = 0.4;
A = [1 dt; 0 1]; H = [1 0];
truth = zeros(N,2,R); est = zeros(N,2,R); P = zeros(2,2,N,R);
nu = zeros(N,1,R); S = zeros(1,1,N,R);
rng(seed);
for rr = 1:R
    x = [1; -0.5] + chol([1 0;0 1]).'*randn(2,1);
    xh = [1; -0.5]; Pk = eye(2);
    for k = 1:N
        x = A*x + chol(Q).'*randn(2,1);
        xh = A*xh; Pk = A*Pk*A.' + Q;
        z = H*x + sqrt(Rm)*randn;
        innov = z - H*xh; Sk = H*Pk*H.' + Rm;
        K = Pk*H.'/Sk; xh = xh + K*innov; Pk = (eye(2)-K*H)*Pk;
        truth(k,:,rr) = x.'; est(k,:,rr) = xh.';
        P(:,:,k,rr) = Pk; nu(k,1,rr) = innov; S(1,1,k,rr) = Sk;
    end
end
end
