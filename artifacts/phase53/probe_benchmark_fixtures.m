function probe_benchmark_fixtures()
% Probe candidate holdout fixtures before freezing their answers.
repo = fileparts(fileparts(fileparts(mfilename('fullpath'))));
addpath(fullfile(repo, 'skills', 'matlab-signal-vision-ai', 'scripts'));
addpath(fullfile(repo, 'skills', 'matlab-data-analysis', 'scripts'));
addpath(fullfile(repo, 'skills', 'matlab-robotics-autonomy', 'scripts'));

% ---- signal normal ------------------------------------------------------
fs = 2000; N = 8192; t = (0:N-1).' / fs;
rng(53); x = 0.7*sin(2*pi*50*t) + 0.3*sin(2*pi*120*t) + 0.05*randn(N,1);
S = mas_measure_contract(x, fs, struct('freq', struct('value', 50), ...
    'power', struct('value', 0.2925, 'unit', 'linear'), ...
    'expected', struct('value', 0.2925, 'tolRel', 0.05), 'expectedOf', 'power'));
fprintf('S-normal  %-12s freq %.4f power %.6f\n', S.verdict, S.freqHz, S.powerLinear);
fprintf('  %s\n', strjoin(strcat({S.checks.id}, '=', {S.checks.status}), ', '));

% ---- signal boundary ----------------------------------------------------
B = mas_ber_check(0, 128, struct('scheme', 'QPSK', 'ebn0dB', 6));
fprintf('S-boundary %-12s %s\n', B.verdict, B.detail);
N2 = 32; t2 = (0:N2-1).' / fs; x2 = sin(2*pi*50*t2);
try
    B2 = mas_measure_contract(x2, fs, struct('freq', struct('value', 50)));
    fprintf('S-boundary2 %-12s %s\n', B2.verdict, B2.detail);
catch ME
    fprintf('S-boundary2 ERR %s\n', ME.message);
end

% ---- signal fault -------------------------------------------------------
F = mas_measure_contract(x, fs, struct('freq', struct('value', 60)));
fprintf('S-fault   %-12s freq %.4f\n', F.verdict, F.freqHz);

% ---- data normal --------------------------------------------------------
f = @(z) 4./(1+z.^2);
D = mas_quad_check(f, 0, 1, struct('value', pi, 'tolRel', 1e-8, ...
    'method', 'simpson', 'n', 64, 'derivAt', 0.5, 'derivValue', -2.56));
fprintf('D-normal  %-12s %s\n', D.verdict, D.detail);

% ---- data boundary ------------------------------------------------------
A = hilb(12); b = ones(12,1); xh = A\b;
DB = mas_linsolve_check(A, xh, b, struct('tolRel', 1e-10));
fprintf('D-bound   %-12s cond %.3e %s\n', DB.verdict, DB.cond, DB.detail);

% ---- data fault ---------------------------------------------------------
A3 = [4 -1 2; -1 4 -1; 2 -1 4]; b3 = [11; -16; 17]; x3 = A3\b3;
xw = x3; xw(1) = xw(1) + 1e-3;
DF = mas_linsolve_check(A3, xw, b3, struct('tolRel', 1e-8));
fprintf('D-fault   %-12s %s\n', DF.verdict, DF.detail);

% ---- robotics normal ----------------------------------------------------
a = 0.6; q = [cos(a/2);0;0;sin(a/2)];
Rz = @(z) [cos(z) -sin(z) 0; sin(z) cos(z) 0; 0 0 1];
qz = @(z) [cos(z/2);0;0;sin(z/2)];
ts = [0 0.25 0.5 0.75 1]; expq = zeros(4, numel(ts));
for k = 1:numel(ts), expq(:,k) = qz(a + ts(k)*(pi/2-a)); end
Q = mas_quat_check(q, struct('matrix', Rz(a), 'angle', a, 'axis', [0;0;1], ...
    'rotvec', [0;0;a], 'compose', qz(0.4), ...
    'interp', struct('qEnd', qz(pi/2), 't', ts, 'expected', expq)));
fprintf('R-normal  %-12s %s\n', Q.verdict, Q.detail);

% ---- robotics boundary --------------------------------------------------
QB = mas_quat_check([1;0;0;0], struct('axis', [0;0;1]));
fprintf('R-bound   %-12s %s\n', QB.verdict, QB.detail);

% ---- robotics fault -----------------------------------------------------
p = struct('m1',1.2,'m2',0.8,'l1',0.5,'l2',0.4,'lc1',0.25,'lc2',0.2, ...
    'I1',1.2*0.5^2/12,'I2',0.8*0.4^2/12,'g',9.81);
q0 = [0.4; -0.7]; qd0 = [0.3; 0.5];
M = M_hand(p, q0); C = C_hand(p, q0, qd0); Cw = -C; g = g_hand(p, q0);
RF = mas_dyn_check(p, q0, qd0, struct('M', M, 'C', Cw, 'g', g));
fprintf('R-fault   %-12s skew %.3e cor %.3e\n', RF.verdict, RF.skewErr, RF.coriolisErr);
end

function M = M_hand(p, q)
m1=p.m1; m2=p.m2; l1=p.l1; lc1=p.lc1; lc2=p.lc2; I1=p.I1; I2=p.I2;
M = zeros(2);
M(1,1) = m1*lc1^2 + I1 + m2*(l1^2 + lc2^2 + 2*l1*lc2*cos(q(2))) + I2;
M(1,2) = m2*(lc2^2 + l1*lc2*cos(q(2))) + I2;
M(2,1) = M(1,2);
M(2,2) = m2*lc2^2 + I2;
end

function C = C_hand(p, q, qd)
m2=p.m2; l1=p.l1; lc2=p.lc2;
h = m2*l1*lc2*sin(q(2));
C = [-h*qd(2), -h*(qd(1)+qd(2)); h*qd(1), 0];
end

function g = g_hand(p, q)
m1=p.m1; m2=p.m2; lc1=p.lc1; l1=p.l1; lc2=p.lc2; gg=p.g;
g = [gg*(m1*lc1 + m2*l1)*cos(q(1)) + gg*m2*lc2*cos(q(1)+q(2)); ...
     gg*m2*lc2*cos(q(1)+q(2))];
end
