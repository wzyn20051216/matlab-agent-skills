repo = 'E:\desktop\MATLAB';
addpath(fullfile(repo, 'skills', 'matlab-data-analysis', 'scripts'));

% A: analytic, default ode45
r1 = mas_ode_check(@(t,y) -y, [0 2], 1, struct( ...
    'reference', @(t) exp(-t), 'refTolRel', 1e-6, ...
    'finalValue', exp(-2), 'finalTolRel', 1e-6));
fprintf('A analytic: %s | err %.2e | %s\n', r1.verdict, r1.error.maxRel, r1.detail);

% B: conserved energy, harmonic oscillator
r2 = mas_ode_check(@(t,y) [y(2); -y(1)], [0 10], [1;0], struct( ...
    'reference', @(t) [cos(t); -sin(t)], 'refTolRel', 1e-6, ...
    'invariant', @(t,y) 0.5*(y(1)^2 + y(2)^2), 'invTolRel', 1e-8));
fprintf('B energy: %s | drift %.2e | %s\n', r2.verdict, r2.invariant.maxRelDrift, r2.detail);

% E: coarse Euler, finite but wrong
h = 0.5; t = (0:h:2).'; y = zeros(size(t)); y(1) = 1;
for k = 1:numel(t)-1, y(k+1) = y(k) - h*y(k); end
r3 = mas_ode_check(@(t,y) -y, [0 2], 1, struct( ...
    'candidate', struct('t', t, 'y', y), 'reference', @(t) exp(-t), ...
    'refTolRel', 1e-6));
fprintf('E coarse: %s | err %.2e | %s\n', r3.verdict, r3.error.maxRel, r3.detail);

% C: stiff linear system, ode15s
A = [-1000 1; 0 -1];
r4 = mas_ode_check(@(t,y) A*y, [0 1], [1;1], struct( ...
    'method', 'ode15s', 'expectedStiff', true));
fprintf('C stiff: %s | ratio %.1f | stiff=%d | %s\n', r4.verdict, ...
    r4.stiffness.ratio, r4.stiffness.isStiff, r4.detail);

% D: event, analytic truth
r5 = mas_ode_check(@(t,y) [y(2); -y(1)], [0 4], [0;1], struct( ...
    'reference', @(t) [sin(t); cos(t)], 'refTolRel', 1e-6, ...
    'eventFun', @(t,y) y(1), 'eventDir', -1, 'eventTime', pi));
fprintf('D event: %s | te %.6f | %s\n', r5.verdict, r5.event.times(1), r5.detail);

% F: finite but wrong sign, no candidate
r6 = mas_ode_check(@(t,y) +y, [0 2], 1, struct( ...
    'reference', @(t) exp(-t), 'refTolRel', 1e-6));
fprintf('F wrong: %s | err %.2e | %s\n', r6.verdict, r6.error.maxRel, r6.detail);

% no criterion at all
r7 = mas_ode_check(@(t,y) -y, [0 1], 1, struct());
fprintf('G none: %s | %s\n', r7.verdict, r7.detail);
