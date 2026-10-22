function res = probe_dist_models()
%PROBE_DIST_MODELS  Cross-model applicability probe for mas_dist_enter.
%
%   The Phase 5.2 suite exercises one scalar recurrences shape plus real .slx
%   models. This probe adds three different shapes and records the outcome:
%     M1  matrix-form discrete plant, parameter change, explicit paramLog
%     M2  two-input plant, input-amplitude change, per-input disturbanceLog
%     M3  decoupled 2-state plant, initial-state change, insensitive output
%
%   Analytic predictions are computed here, not read back from the runs.

here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
addpath(fullfile(repo, 'skills', 'matlab-simulink-modeling', 'scripts'));

R = struct('case', {}, 'verdict', {}, 'evidence', {}, 'delta', {}, 'detail', {}, 'pass', {});

% ---- M1: matrix form, parameter change, paramLog ------------------------
exp1 = struct('direction', 'decrease', 'delta', -0.8, 'tol', 0.01, ...
    'insensitive', false, 'minRel', 1e-10, 'timeTol', 0.02, ...
    'maxResponseDelay', 0.05, 'window', 0.05);
c1 = struct('name', 'M1 matrix-form paramLog', ...
    'base', struct('a', 0.9), 'perturbed', struct('a', 0.5), ...
    'tInject', 0, 'simFcn', @(p) m1(p), 'expect', exp1);
r1 = mas_dist_enter(c1);
R(end+1) = pack('M1', r1, exp1.delta);

% ---- M2: two inputs, amplitude change, per-input log --------------------
exp2 = struct('direction', 'increase', 'delta', 2.5, 'tol', 0.02, ...
    'insensitive', false, 'minRel', 1e-10, 'timeTol', 0.02, ...
    'maxResponseDelay', 0.05, 'window', 0.05);
c2 = struct('name', 'M2 two-input amplitude', ...
    'base', struct('u1', 0), 'perturbed', struct('u1', 1), ...
    'tInject', 0.5, 'simFcn', @(p) m2(p), 'expect', exp2, ...
    'inputFields', {{'u1'}});
r2 = mas_dist_enter(c2);
R(end+1) = pack('M2', r2, exp2.delta);

% ---- M3: decoupled states, initial-state change, insensitive output -----
exp3 = struct('direction', 'any', 'delta', 0, 'tol', 1e-9, ...
    'insensitive', true, 'minRel', 1e-10, 'timeTol', 0.02, ...
    'maxResponseDelay', 0.05, 'window', 0.05);
c3 = struct('name', 'M3 decoupled initial state', ...
    'base', struct('x2_0', 0), 'perturbed', struct('x2_0', 1), ...
    'tInject', 0, 'simFcn', @(p) m3(p), 'expect', exp3, ...
    'stateFields', {{'x2_0'}});
r3 = mas_dist_enter(c3);
R(end+1) = pack('M3', r3, 0);

res = struct('level', 'phase53-dist-models', 'cases', R, ...
    'nPass', nnz([R.pass]), 'nTotal', numel(R), ...
    'matlabVersion', version, 'timestamp', datestr(now, 31));

ev = fullfile(repo, 'artifacts', 'phase53', 'evidence');
if ~isfolder(ev), mkdir(ev); end
fid = fopen(fullfile(ev, 'task0_dist_models.json'), 'w');
fwrite(fid, jsonencode(res), 'char');
fclose(fid);
fprintf('DIST_MODELS %d/%d\n', res.nPass, res.nTotal);
for k = 1:numel(R)
    fprintf('  [%s] %-34s -> %-13s ev=%s delta=%.6g %s\n', ...
        tern(R(k).pass, 'PASS', 'FAIL'), R(k).case, R(k).verdict, ...
        R(k).evidence, R(k).delta, R(k).detail);
end
end

% ---------------------------------------------------------------------------
function s = pack(id, r, wantDelta)
ok = strcmp(r.verdict, 'PASS') && strcmp(r.evidenceQuality, 'VERIFIED') && ...
    abs(r.measuredDelta - wantDelta) < max(0.05, 0.05*abs(wantDelta));
s = struct('case', id, 'verdict', r.verdict, 'evidence', r.evidenceQuality, ...
    'delta', r.measuredDelta, 'detail', strjoin(r.reasons, '|'), 'pass', ok);
end

% ---------------------------------------------------------------------------
function r = m1(p)
dt = 0.01; t = (0:dt:2).'; N = numel(t);
% x(k+1) = A x(k) + B u, A = [a 0; 0 0.5], B = [0.1; 0.2], u = 1 since t=0
A = [p.a 0; 0 0.5]; B = [0.1; 0.2];
x = [0; 0]; y = zeros(N,1); X = zeros(N,2);
for k = 1:N
    x = A*x + B;
    y(k) = x(1); X(k,:) = x.';
end
r = struct('t', t, 'y', y, 'x', X, ...
    'plantParams', struct('a', p.a), ...
    'paramLog', struct('t', t, 'a', p.a*ones(N,1)));
end

% ---------------------------------------------------------------------------
function r = m2(p)
dt = 0.01; t = (0:dt:1.5).'; N = numel(t);
a = 0.8; b = [0.5 0.2];
x = 0; y = zeros(N,1); u1t = zeros(N,1); u2t = ones(N,1);
for k = 1:N
    u1 = (t(k) >= 0.5) * p.u1;
    u1t(k) = u1;
    x = a*x + b(1)*u1 + b(2)*u2t(k);
    y(k) = x;
end
r = struct('t', t, 'y', y, 'x', x, ...
    'disturbanceLog', struct('t', t, 'u1', u1t, 'u2', u2t));
end

% ---------------------------------------------------------------------------
function r = m3(p)
dt = 0.01; t = (0:dt:1.5).'; N = numel(t);
% x1 driven by u=1 only; x2 decays from its initial value and feeds nothing.
x1 = 0; x2 = p.x2_0;
y = zeros(N,1); X = zeros(N,2);
for k = 1:N
    x1 = 0.9*x1 + 0.1;
    x2 = 0.95*x2;
    y(k) = x1; X(k,:) = [x1 x2];
end
r = struct('t', t, 'y', y, 'x', X, 'x0', struct('x2_0', p.x2_0));
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end