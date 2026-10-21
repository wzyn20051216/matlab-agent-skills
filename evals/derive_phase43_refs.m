% Derive the Phase 4.3 benchmark references INDEPENDENTLY, by two routes each.
% Nothing here is taken on faith: every value is computed two ways and the two
% must agree, because a benchmark whose reference is wrong measures nothing.
%
% The first draft of evals/phase43_benchmark.json was written FROM MEMORY and
% five of its six references were wrong. This script is the correction, and it
% stays in the repository so the numbers can be re-derived rather than trusted.
fprintf('=== B1: 3x3 linear system ===\n');
A = [4 -1 2; -1 4 -1; 2 -1 4]; b = [11; -16; 17];
x1 = A\b;
x2 = pinv(A)*b;                     % independent route
fprintf('  x = [%.15g %.15g %.15g]\n', x1);
fprintf('  pinv route agrees: %d\n', norm(x1-x2) < 1e-12);
fprintf('  residual norm = %.3e\n', norm(A*x1-b));

fprintf('=== B2: L(s) = 10/((s+1)(s+2)) ===\n');
L = tf(10, [1 3 2]);
[gm, pm] = margin(L);
fprintf('  margin(): gm=%.9g pm=%.9f\n', gm, pm);
% exact 0 dB crossing: 10/sqrt((w^2+1)(w^2+4)) = 1 -> w^4 + 5w^2 - 96 = 0
w2 = (-5 + sqrt(409))/2;  w = sqrt(w2);
pmExact = 180 - atan2d(w,1) - atan2d(w,2);
fprintf('  exact w0 = %.9f  analytic pm = %.9f  (diff %.3e)\n', w, pmExact, abs(pmExact-pm));
fprintf('  closed-loop poles: %s\n', mat2str(pole(feedback(L,1))));
fprintf('  closed-loop stable: %d\n', all(real(pole(feedback(L,1))) < 0));
fprintf('  gm is Inf (phase never reaches -180): %d\n', isinf(gm));

fprintf('=== B3: 10 Hz sine, fs = 1000, 1 s ===\n');
fs = 1000; t = 0:1/fs:1-1/fs; x = sin(2*pi*10*t);
N = numel(t);
X = abs(fft(x))/N*2;
[~, ib] = max(X);
fprintf('  N=%d  peak bin (1-based) = %d  amplitude = %.9f\n', N, ib, X(ib));
fprintf('  bin 11 corresponds to %.4f Hz\n', (ib-1)*fs/N);
c = sum(x .* exp(-2i*pi*10*t)) / N;      % independent route
fprintf('  direct DFT projection amplitude = %.9f\n', 2*abs(c));

fprintf('=== B4: linear fit ===\n');
xv = [1 2 3 4 5]; yv = [2.1 4.0 6.1 7.9 10.2];
p1 = polyfit(xv, yv, 1);
p2 = fitlm(xv', yv');
fprintf('  polyfit: slope=%.10f intercept=%.10f\n', p1(1), p1(2));
fprintf('  fitlm  : slope=%.10f intercept=%.10f\n', ...
    p2.Coefficients.Estimate(2), p2.Coefficients.Estimate(1));
fprintf('  hand formula agrees: %d\n', ...
    abs(p1(1) - sum((xv-mean(xv)).*(yv-mean(yv)))/sum((xv-mean(xv)).^2)) < 1e-12);

fprintf('=== B5: 2-link planar arm ===\n');
L1 = 1.0; L2 = 0.5; q1 = deg2rad(30); q2 = deg2rad(45);
x5 = L1*cos(q1) + L2*cos(q1+q2);
y5 = L1*sin(q1) + L2*sin(q1+q2);
fprintf('  x=%.15f y=%.15f\n', x5, y5);
A1 = [cos(q1) -sin(q1) L1*cos(q1); sin(q1) cos(q1) L1*sin(q1); 0 0 1];
A2 = [cos(q2) -sin(q2) L2*cos(q2); sin(q2) cos(q2) L2*sin(q2); 0 0 1];
T = A1*A2;
fprintf('  transform route: x=%.15f y=%.15f  agrees=%d\n', T(1,3), T(2,3), ...
    abs(T(1,3)-x5) < 1e-12 && abs(T(2,3)-y5) < 1e-12);