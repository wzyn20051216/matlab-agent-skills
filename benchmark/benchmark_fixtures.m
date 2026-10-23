function [args, spec, inputs] = benchmark_fixtures(id, seed)
%BENCHMARK_FIXTURES  Deterministic inputs for a benchmark task.
%
%   [args, spec, inputs] = benchmark_fixtures(id)
%
% The fixture is the ONLY place task inputs are constructed. It contains no
% expected verdict and no reference value: those live in the sealed answer file
% on the evaluation side. `spec` is a JSON-safe description (so a trajectory can
% record exactly which input was used); `inputs` is a struct saved to a MAT file.
%
% Every fixture seeds the RNG it uses and restores the caller's stream.

if nargin < 2 || isempty(seed), seed = 53; end
if nargin < 1 || isempty(id), error('benchmark_fixtures:id', 'need a fixture id'); end

old = rng(); cleaner = onCleanup(@() rng(old));
switch id
    case 'sig_normal'
        fs = 2000; N = 8192; t = (0:N-1).' / fs;
        rng(seed);
        x = 0.7*sin(2*pi*50*t) + 0.3*sin(2*pi*120*t) + 0.05*randn(N,1);
        claims = struct('freq', struct('value', 50), ...
            'power', struct('value', 0.2925, 'unit', 'linear'), ...
            'expected', struct('value', 0.2925, 'tolRel', 0.05), ...
            'expectedOf', 'power');
        args = {x, fs, claims};
        spec = struct('fixture', id, 'fs', fs, 'N', N, 'seed', seed, ...
            'tonesHz', [50 120], 'amps', [0.7 0.3], 'noiseSigma', 0.05, ...
            'claimFreqHz', 50, 'claimPower', 0.2925);
        inputs = struct('x', x, 'fs', fs, 'claims', claims);

    case 'sig_boundary'
        nErr = 0; nBits = 128;
        specIn = struct('scheme', 'QPSK', 'ebn0dB', 6);
        args = {nErr, nBits, specIn};
        spec = struct('fixture', id, 'nErr', nErr, 'nBits', nBits, ...
            'scheme', 'QPSK', 'ebn0dB', 6);
        inputs = struct('nErr', nErr, 'nBits', nBits, 'spec', specIn);

    case 'sig_fault'
        fs = 2000; N = 8192; t = (0:N-1).' / fs;
        rng(seed);
        x = 0.7*sin(2*pi*50*t) + 0.3*sin(2*pi*120*t) + 0.05*randn(N,1);
        claims = struct('freq', struct('value', 60));
        args = {x, fs, claims};
        spec = struct('fixture', id, 'fs', fs, 'N', N, 'seed', seed, ...
            'tonesHz', [50 120], 'amps', [0.7 0.3], 'noiseSigma', 0.05, ...
            'claimFreqHz', 60);
        inputs = struct('x', x, 'fs', fs, 'claims', claims);

    case 'data_normal'
        f = @(z) 4./(1+z.^2);
        claims = struct('value', pi, 'tolRel', 1e-8, 'method', 'simpson', ...
            'n', 32, 'derivAt', 0.5, 'derivValue', -2.56);
        args = {f, 0, 1, claims};
        spec = struct('fixture', id, 'integrand', '4/(1+x^2)', 'a', 0, 'b', 1, ...
            'value', pi, 'tolRel', 1e-8, 'method', 'simpson', 'n', 32, ...
            'derivAt', 0.5, 'derivValue', -2.56);
        inputs = struct('f', f, 'a', 0, 'b', 1, 'claims', claims);

    case 'data_boundary'
        A = hilb(12); b = ones(12,1); x = A\b;
        claims = struct('tolRel', 1e-10);
        args = {A, x, b, claims};
        spec = struct('fixture', id, 'matrix', 'hilb(12)', 'b', 'ones(12,1)', ...
            'tolRel', 1e-10);
        inputs = struct('A', A, 'x', x, 'b', b, 'claims', claims);

    case 'data_fault'
        A = [4 -1 2; -1 4 -1; 2 -1 4]; b = [11; -16; 17];
        xTrue = A\b; x = xTrue; x(1) = x(1) + 1e-3;
        claims = struct('tolRel', 1e-8);
        args = {A, x, b, claims};
        spec = struct('fixture', id, 'A', A, 'b', b, 'x', x, 'tolRel', 1e-8);
        inputs = struct('A', A, 'x', x, 'b', b, 'claims', claims);

    case 'rob_normal'
        a = 0.6; q = [cos(a/2);0;0;sin(a/2)];
        Rz = @(z) [cos(z) -sin(z) 0; sin(z) cos(z) 0; 0 0 1];
        qz = @(z) [cos(z/2);0;0;sin(z/2)];
        ts = [0 0.25 0.5 0.75 1]; expq = zeros(4, numel(ts));
        for k = 1:numel(ts), expq(:,k) = qz(a + ts(k)*(pi/2-a)); end
        claims = struct('matrix', Rz(a), 'angle', a, 'axis', [0;0;1], ...
            'rotvec', [0;0;a], 'compose', qz(0.4), ...
            'interp', struct('qEnd', qz(pi/2), 't', ts, 'expected', expq));
        args = {q, claims};
        spec = struct('fixture', id, 'angle', a, 'axis', '[0;0;1]', ...
            'composeAngle', 0.4, 'interpTo', pi/2, 't', ts);
        inputs = struct('q', q, 'claims', claims);

    case 'rob_boundary'
        q = [1;0;0;0];
        claims = struct('axis', [0;0;1]);
        args = {q, claims};
        spec = struct('fixture', id, 'q', q, 'claimedAxis', '[0;0;1]');
        inputs = struct('q', q, 'claims', claims);

    case 'rob_fault'
        p = struct('m1',1.2,'m2',0.8,'l1',0.5,'l2',0.4,'lc1',0.25,'lc2',0.2, ...
            'I1',1.2*0.5^2/12,'I2',0.8*0.4^2/12,'g',9.81);
        q = [0.4; -0.7]; qd = [0.3; 0.5];
        M = M_hand(p, q); C = -C_hand(p, q, qd); g = g_hand(p, q);
        claims = struct('M', M, 'C', C, 'g', g);
        args = {p, q, qd, claims};
        spec = struct('fixture', id, 'params', p, 'q', q, 'qd', qd, ...
            'defect', 'C sign flipped');
        inputs = struct('p', p, 'q', q, 'qd', qd, 'claims', claims);

    case 'ode_normal'
        % Harmonic oscillator: analytic truth, conserved energy, exact final state.
        f = @(t,y) [y(2); -y(1)];
        ref = @(t) [cos(t); -sin(t)];
        invf = @(t,y) y(1)^2 + y(2)^2;
        claims = struct('relTol', 1e-9, 'absTol', 1e-11, ...
            'reference', ref, 'refTolRel', 1e-8, ...
            'invariant', invf, 'invTolRel', 1e-8, ...
            'finalValue', [1; 0], 'finalTolRel', 1e-8);
        args = {f, [0 2*pi], [1; 0], claims};
        spec = struct('fixture', id, 'ode', 'y''=[y2;-y1]', ...
            'tspan', [0 2*pi], 'y0', [1;0], ...
            'reference', '[cos(t);-sin(t)]', 'invariant', 'y1^2+y2^2', ...
            'finalValue', [1;0], 'relTol', 1e-9, 'refTolRel', 1e-8, ...
            'invTolRel', 1e-8);
        inputs = struct('odefun', f, 'tspan', [0 2*pi], 'y0', [1;0], 'claims', claims);

    case 'ode_boundary'
        % Solver exits successfully but no acceptance criterion is stated.
        f = @(t,y) -y;
        claims = struct('method', 'ode45');
        args = {f, [0 2], 1, claims};
        spec = struct('fixture', id, 'ode', 'y''=-y', 'tspan', [0 2], 'y0', 1, ...
            'claims', 'solver configuration only; no reference, final value, invariant or event');
        inputs = struct('odefun', f, 'tspan', [0 2], 'y0', 1, 'claims', claims);

    case 'ode_fault'
        % Stiff decay integrated with a coarse explicit step: finite output, wrong
        % trajectory. The final value is correct; its consistency with the
        % candidate and the reference error are not.
        f = @(t,y) -1000*y;
        claims = struct('method', 'ode45', 'relTol', 1e-3, 'absTol', 1e-5, ...
            'maxStep', 0.02, 'finalValue', exp(-20), 'finalTolRel', 1e-8);
        args = {f, [0 0.02], 1, claims};
        spec = struct('fixture', id, 'ode', 'y''=-1000y', 'tspan', [0 0.02], ...
            'y0', 1, 'method', 'ode45', 'relTol', 1e-3, 'maxStep', 0.02, ...
            'finalValue', exp(-20), 'finalTolRel', 1e-8, ...
            'defect', 'explicit solver with a step far larger than the 1e-3 time scale');
        inputs = struct('odefun', f, 'tspan', [0 0.02], 'y0', 1, 'claims', claims);

    case 'vis_normal'
        % One foreground pixel removed from a square: f1 = 30/31, object IoU 15/16.
        T = zeros(8, 8); T(2:5, 2:5) = 1;
        P = T; P(5, 5) = 0;
        claims = struct('iouThreshold', 0.5, 'metrics', struct( ...
            'name', {'f1', 'objectIouMean'}, ...
            'value', {30/31, 15/16}, 'tolRel', {1e-9, 1e-9}));
        args = {P, T, claims};
        spec = struct('fixture', id, 'size', [8 8], ...
            'truth', 'rows 2:5, cols 2:5', 'defect', 'pixel (5,5) removed', ...
            'iouThreshold', 0.5, 'claims', 'f1=30/31, objectIouMean=15/16');
        inputs = struct('pred', P, 'truth', T, 'claims', claims);

    case 'vis_boundary'
        % An object metric is claimed without an explicit IoU threshold: the
        % number matches at the default, but matching is not a stated criterion.
        T = zeros(8, 8); T(2:5, 2:5) = 1;
        P = T; P(5, 5) = 0;
        claims = struct('metrics', struct('name', 'objectIouMean', ...
            'value', 15/16, 'tolRel', 1e-9));
        args = {P, T, claims};
        spec = struct('fixture', id, 'size', [8 8], ...
            'truth', 'rows 2:5, cols 2:5', 'defect', 'pixel (5,5) removed', ...
            'claims', 'objectIouMean=15/16 without an iouThreshold');
        inputs = struct('pred', P, 'truth', T, 'claims', claims);

    case 'vis_fault'
        % The mask is shifted one column: pixel accuracy 0.875 hides f1 = 0.75,
        % yet the claim states 0.9.
        T = zeros(8, 8); T(2:5, 2:5) = 1;
        P = zeros(8, 8); P(2:5, 3:6) = 1;
        claims = struct('iouThreshold', 0.5, 'metrics', struct( ...
            'name', 'f1', 'value', 0.9, 'tolRel', 1e-9));
        args = {P, T, claims};
        spec = struct('fixture', id, 'size', [8 8], ...
            'truth', 'rows 2:5, cols 2:5', ...
            'defect', 'prediction shifted one column; f1 is 0.75, claimed 0.9', ...
            'iouThreshold', 0.5);
        inputs = struct('pred', P, 'truth', T, 'claims', claims);

    case 'dev_sig'
        fs = 1000; N = 4000; t = (0:N-1).' / fs;
        x = sin(2*pi*80*t);
        claims = struct('freq', struct('value', 80));
        args = {x, fs, claims};
        spec = struct('fixture', id, 'fs', fs, 'N', N, 'toneHz', 80);
        inputs = struct('x', x, 'fs', fs, 'claims', claims);

    case 'dev_data'
        A = [4 -1 2; -1 4 -1; 2 -1 4]; b = [11; -16; 17]; x = A\b;
        claims = struct('tolRel', 1e-10);
        args = {A, x, b, claims};
        spec = struct('fixture', id, 'A', A, 'b', b, 'tolRel', 1e-10);
        inputs = struct('A', A, 'x', x, 'b', b, 'claims', claims);

    case 'dev_rob'
        th = 0.3;
        T = [cos(th) -sin(th) 0 1; sin(th) cos(th) 0 2; 0 0 1 3; 0 0 0 1];
        args = {T};
        spec = struct('fixture', id, 'yaw', th, 'translation', [1 2 3]);
        inputs = struct('T', T);

    case 'p56_sig_boundary'
        % Phase 5.6 causal-gain task. Zero errors over 26624 bits against a
        % target of 1e-4: the 95% Wilson upper bound is 1.44e-4, so the run can
        % neither certify nor refute the target. Tolerances and bit counts are
        % deliberately unlike the frozen sig_boundary fixture -- this is a new
        % task, not an old holdout re-labelled.
        nErr = 0; nBits = 26624;
        specIn = struct('scheme', 'QPSK', 'ebn0dB', 8.8, 'targetBer', 1e-4, 'level', 0.95);
        args = {nErr, nBits, specIn};
        spec = struct('fixture', id, 'nErr', nErr, 'nBits', nBits, 'scheme', 'QPSK', ...
            'ebn0dB', 8.8, 'targetBer', 1e-4, 'level', 0.95);
        inputs = struct('nErr', nErr, 'nBits', nBits, 'spec', specIn);

    case 'p56_sig_fault'
        % 550 errors in 1e6 bits where the textbook QPSK rate at 8.8 dB predicts
        % 49: an 11x excess with both counts far above the power floor. The
        % honest answer is a powered refutation, not a soft "not conclusive".
        nErr = 550; nBits = 1000000;
        specIn = struct('scheme', 'QPSK', 'ebn0dB', 8.8, 'level', 0.95);
        args = {nErr, nBits, specIn};
        spec = struct('fixture', id, 'nErr', nErr, 'nBits', nBits, 'scheme', 'QPSK', ...
            'ebn0dB', 8.8, 'level', 0.95);
        inputs = struct('nErr', nErr, 'nBits', nBits, 'spec', specIn);

    case 'p56_ode_normal'
        % Same oscillator family as ode_normal but with different tolerances and
        % a different acceptance level, and the deliverable names the scaling
        % convention: the graded field must be the magnitude-scaled error, not
        % the solver-tolerance-scaled one (the Phase 5.5 H54-ODE-N defect).
        f = @(t,y) [y(2); -y(1)];
        ref = @(t) [cos(t); -sin(t)];
        invf = @(t,y) y(1)^2 + y(2)^2;
        claims = struct('relTol', 1e-8, 'absTol', 1e-10, ...
            'reference', ref, 'refTolRel', 1e-6, ...
            'invariant', invf, 'invTolRel', 1e-6, ...
            'finalValue', [1; 0], 'finalTolRel', 1e-6);
        args = {f, [0 2*pi], [1; 0], claims};
        spec = struct('fixture', id, 'ode', 'y''=[y2;-y1]', ...
            'tspan', [0 2*pi], 'y0', [1;0], ...
            'reference', '[cos(t);-sin(t)]', 'invariant', 'y1^2+y2^2', ...
            'finalValue', [1;0], 'relTol', 1e-8, 'absTol', 1e-10, ...
            'refTolRel', 1e-6, 'invTolRel', 1e-6, 'finalTolRel', 1e-6);
        inputs = struct('odefun', f, 'tspan', [0 2*pi], 'y0', [1;0], 'claims', claims);

    otherwise
        error('benchmark_fixtures:id', 'unknown fixture "%s"', id);
end
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
