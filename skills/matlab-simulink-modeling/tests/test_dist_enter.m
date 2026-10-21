function res = test_dist_enter(verbose)
%TEST_DIST_ENTER  The disturbance must reach the PLANT, not merely the chart.
%
%   res = test_dist_enter()
%
% Five required scenarios:
%   A  correct propagation (parameter and input both reach the plant)
%   B  disturbance input disconnected (output looks smooth, but nothing entered)
%   C  controller-only update (the controller reads the new value, the plant does not)
%   D  wrong injection time (the step is late)
%   E  output is legitimately insensitive; internal state must still change
%
% Plus negative controls: wrong amplitude, wrong direction, missing plant
% evidence, a simulation error, and four real Simulink variants.

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
addpath(fullfile(repo, 'skills', 'matlab-simulink-modeling', 'scripts'));

base = struct('R', 1);
pert = struct('R', 2);
expC = struct('direction', 'increase', 'delta', 1.0, 'tol', 0.02, ...
    'insensitive', false, 'minRel', 1e-8, 'timeTol', 0.02, ...
    'maxResponseDelay', 0.2, 'window', 0.1);
expE = expC; expE.insensitive = true; expE.delta = 0; expE.tol = 1e-6;
expE.direction = 'any';

T = struct('name', {}, 'fn', {}, 'verdict', {}, 'reason', {}, 'check', {});

% ---- A: correct -----------------------------------------------------------
ca = cse(true, true, 'ok', 1, false, true);
T(end+1) = tc('A proper propagation', @() mas_dist_enter(cfg('A', base, pert, 0.5, ca, expC)), ...
    'PASS', '', 'param_entered_plant');

% ---- B: disturbance disconnected -----------------------------------------
cb = cse(true, false, 'ok', 1, false, true);
T(end+1) = tc('B disturbance disconnected', @() mas_dist_enter(cfg('B', base, pert, 0.5, cb, expC)), ...
    'FAIL', 'OUTPUT_UNCHANGED', 'output_changed');

% ---- C: controller-only update -------------------------------------------
cc = cse(false, true, 'ok', 1, false, true);   % plant ignores p.R
T(end+1) = tc('C controller-only update', @() mas_dist_enter(cfg('C', base, pert, 0.5, cc, expC)), ...
    'FAIL', 'PARAM_NOT_ENTERED_PLANT', 'param_entered_plant');

% ---- D: wrong injection time ---------------------------------------------
cd = cse(true, true, 'late', 1, false, true);
T(end+1) = tc('D wrong injection time', @() mas_dist_enter(cfg('D', base, pert, 0.5, cd, expC)), ...
    'FAIL', 'TIMING', 'effective_time');

% ---- E: insensitive output, internal state changes ------------------------
ce = cse(true, true, 'ok', 1, true, true);
T(end+1) = tc('E insensitive output / state changes', @() mas_dist_enter(cfg('E', base, pert, 0.5, ce, expE)), ...
    'PASS', '', 'internal_state');

% ---- E-negative: nothing changes inside either ----------------------------
ce2 = cse(true, false, 'ok', 1, true, true);
T(end+1) = tc('E-neg insensitive but state unchanged', @() mas_dist_enter(cfg('E-neg', base, pert, 0.5, ce2, expE)), ...
    'FAIL', 'INTERNAL_EVIDENCE', 'internal_state');

% ---- F: wrong amplitude ---------------------------------------------------
cf = cse(true, true, 'ok', 2, false, true);
T(end+1) = tc('F wrong amplitude', @() mas_dist_enter(cfg('F', base, pert, 0.5, cf, expC)), ...
    'FAIL', 'PREDICTION_MISMATCH', 'prediction');

% ---- G: wrong direction ---------------------------------------------------
cg = cse(true, true, 'ok', 1, false, true);
expG = expC; expG.direction = 'decrease'; expG.delta = -1;
T(end+1) = tc('G wrong direction', @() mas_dist_enter(cfg('G', base, pert, 0.5, cg, expG)), ...
    'FAIL', 'DIRECTION_MISMATCH', 'direction');

% ---- H: plant evidence missing -------------------------------------------
ch = cse(true, true, 'ok', 1, false, false);
T(end+1) = tc('H missing plant evidence is UNDETERMINED', @() mas_dist_enter(cfg('H', base, pert, 0.5, ch, expC)), ...
    'UNDETERMINED', 'PARAM_EVIDENCE_MISSING', 'param_entered_plant');

% ---- I: simulation error --------------------------------------------------
T(end+1) = tc('I simulation error is UNDETERMINED', @() mas_dist_enter(cfg('I', base, pert, 0.5, ca, expC, @(p) error('boom'))), ...
    'UNDETERMINED', 'SIM_ERROR', 'sim');

% ---- J: no prediction is partial, not verified ----------------------------
expJ = expC; expJ.delta = [];
T(end+1) = tc('J no independent prediction is PARTIAL', @() quality_of(mas_dist_enter(cfg('J', base, pert, 0.5, ca, expJ))), ...
    'PARTIAL', '', '');

% ---- K/L: input amplitude and initial state are changes too --------------
expK = expC; expK.delta = 1.0;
cfgK = struct('name', 'K', 'base', struct('u0', 0), 'perturbed', struct('u0', 1), ...
    'tInject', 0.5, 'simFcn', @(p) sim_input(p, true), 'expect', expK, ...
    'inputFields', {{'u0'}});
T(end+1) = tc('K input amplitude reaches the plant', @() mas_dist_enter(cfgK), ...
    'PASS', '', 'param_entered_plant');

expL = expC; expL.delta = []; expL.tInject = 0;
cfgL = struct('name', 'L', 'base', struct('x0', 0), 'perturbed', struct('x0', 1), ...
    'tInject', 0, 'simFcn', @(p) sim_state(p, true), 'expect', expL, ...
    'stateFields', {{'x0'}});
T(end+1) = tc('L initial state reaches the plant', @() mas_dist_enter(cfgL), ...
    'PASS', '', 'param_entered_plant');

cfgM = cfgK; cfgM.name = 'M'; cfgM.simFcn = @(p) sim_input(p, false);
T(end+1) = tc('M input evidence missing is UNDETERMINED', @() mas_dist_enter(cfgM), ...
    'UNDETERMINED', 'INPUT_EVIDENCE_MISSING', 'param_entered_plant');

cfgN = cfgL; cfgN.name = 'N'; cfgN.simFcn = @(p) sim_state(p, false);
T(end+1) = tc('N state evidence missing is UNDETERMINED', @() mas_dist_enter(cfgN), ...
    'UNDETERMINED', 'STATE_EVIDENCE_MISSING', 'param_entered_plant');

nP = 0; nSkip = 0;
if verbose, fprintf('=== disturbance propagation tests ===\n'); end
R = struct('case', {}, 'verdict', {}, 'detail', {}, 'pass', {}, 'skipped', {});
for k = 1:numel(T)
    t = T(k);
    try
        r = t.fn();
        if ischar(r)          % J returns the evidence quality directly
            got = r;
            detail = '';
            ok = strcmp(got, t.verdict);
        else
            got = r.verdict;
            ok = strcmp(got, t.verdict);
            detail = strjoin(r.reasons, ' | ');
            if ~isempty(t.reason)
                ok = ok && any(contains(r.reasons, t.reason));
            end
            if ~isempty(t.check)
                hit = find(strcmp({r.checks.id}, t.check), 1);
                ok = ok && ~isempty(hit) && strcmp(r.checks(hit).status, 'PASS') == strcmp(t.verdict, 'PASS');
            end
        end
    catch ME
        got = 'ERROR';
        ok = false;
        detail = [ME.identifier ' :: ' ME.message];
    end
    nP = nP + ok;
    if verbose
        fprintf('  [%s] %-44s -> %-13s %s\n', tern(ok, 'PASS', 'FAIL'), t.name, got, detail);
    end
    R(end+1) = struct('case', t.name, 'verdict', got, 'detail', detail, 'pass', ok, 'skipped', false); %#ok<AGROW>
end

% ---- real Simulink model: one right and three wrong variants -------------
if ~isempty(ver('simulink')) && license('test', 'Simulink')
    try
        [mdl, mdlFile] = make_simulink_model();
        sb = struct('R', 0); sp = struct('R', 1); sK = struct('R', 1, 'K', 1);
        spK = struct('R', 1, 'K', 2);
        % 1/(s+1) step at t=0.5, measured at t=1.5: 1-exp(-1) = 0.632121.
        % The prediction is analytic, not read back from the simulation.
        simExp = expC; simExp.maxResponseDelay = 0.25;
        simExp.delta = 0.6321205588; simExp.tol = 0.02;
        simExp.window = 0.001;   % one sample at t=1.5, where the prediction holds
        S = struct('name', {}, 'fn', {}, 'verdict', {}, 'reason', {}, 'check', {});
        S(end+1) = tc('S-A Simulink proper step', @() mas_dist_enter(sim_cfg('S-A', mdl, sb, sp, 0.5, simExp, 0.5, 1, 1)), ...
            'PASS', '', '');
        S(end+1) = tc('S-B Simulink zero-amplitude step', @() mas_dist_enter(sim_cfg('S-B', mdl, sb, sp, 0.5, simExp, 0.5, 0, 1)), ...
            'FAIL', 'OUTPUT_UNCHANGED', '');
        S(end+1) = tc('S-C Simulink controller-only update', @() mas_dist_enter(sim_cfg('S-C', mdl, sK, spK, 0.5, simExp, 0.5, 1, 1)), ...
            'FAIL', 'PARAM_NOT_ENTERED_PLANT', '');
        S(end+1) = tc('S-D Simulink wrong step time', @() mas_dist_enter(sim_cfg('S-D', mdl, sb, sp, 0.5, simExp, 0.8, 1, 1)), ...
            'FAIL', 'TIMING', '');
        for k = 1:numel(S)
            t = S(k);
            r = t.fn();
            got = r.verdict;
            ok = strcmp(got, t.verdict) && (isempty(t.reason) || any(contains(r.reasons, t.reason)));
            detail = strjoin(r.reasons, ' | ');
            nP = nP + ok;
            if verbose
                fprintf('  [%s] %-44s -> %-13s %s\n', tern(ok, 'PASS', 'FAIL'), t.name, got, detail);
            end
            R(end+1) = struct('case', t.name, 'verdict', got, 'detail', detail, 'pass', ok, 'skipped', false); %#ok<AGROW>
        end
        close_system(mdl, 0);
        if isfile(mdlFile), delete(mdlFile); end
    catch ME
        nSkip = nSkip + 4;
        if verbose, fprintf('  [SKIP] Simulink cases: %s\n', ME.message); end
    end
else
    nSkip = 4;
    if verbose, fprintf('  [SKIP] Simulink not available\n'); end
end

res = struct('nPass', nP, 'nTotal', numel(R) + nSkip, 'nSkip', nSkip, ...
    'cases', R, 'pass', nP == numel(R) && nSkip == 0);
if verbose
    fprintf('\n---- %d passed, %d skipped, %d run ----\n', nP, nSkip, numel(R));
end
end

% ===========================================================================
function c = cse(plantUsesR, distConnected, applyMode, ampScale, insensitive, reportParams)
c = struct('plantUsesR', plantUsesR, 'distConnected', distConnected, ...
    'applyMode', applyMode, 'ampScale', ampScale, ...
    'insensitive', insensitive, 'reportParams', reportParams);
end

function cfg = cfg(name, base, pert, tInject, c, expect, simFcn)
if nargin < 7, simFcn = @(p) sim_discrete(p, c); end
cfg = struct('name', name, 'base', base, 'perturbed', pert, ...
    'tInject', tInject, 'simFcn', simFcn, 'expect', expect);
end

function s = quality_of(r)
s = r.evidenceQuality;
end

function t = tc(name, fn, verdict, reason, check)
t = struct('name', name, 'fn', fn, 'verdict', verdict, 'reason', reason, 'check', check);
end

% ---------------------------------------------------------------------------
function r = sim_discrete(p, c)
dt = 0.01;
t = (0:dt:1.5).';
a = 0.9; cd = 0.1;
N = numel(t);
if c.plantUsesR, Rp = p.R; else, Rp = 1; end
x1 = 0; x2 = 0;
y = zeros(N,1); X = zeros(N,2); d = zeros(N,1);
for k = 1:N
    tk = t(k);
    switch c.applyMode
        case 'ok',    active = tk >= 0.5;
        case 'late',  active = tk >= 0.8;
        case 'early', active = tk >= 0.2;
        otherwise, error('bad applyMode');
    end
    d(k) = active;
    u = d(k);
    if ~c.distConnected, u = 0; end
    u = u * c.ampScale;
    x1 = a*x1 + cd*Rp*u;      % state that carries the disturbance
    x2 = a*x2;                % untouched state
    X(k,:) = [x1 x2];
    if c.insensitive, y(k) = x2; else, y(k) = x1; end
end
r = struct('t', t, 'y', y, 'x', X, 'plantParams', struct('R', Rp), ...
    'disturbanceLog', struct('t', t, 'value', d));
if ~c.reportParams, r = rmfield(r, 'plantParams'); end
end

% ---------------------------------------------------------------------------
function r = sim_input(p, reportLog)
dt = 0.01; t = (0:dt:1.5).'; a = 0.9; cd = 0.1;
N = numel(t); x = 0; y = zeros(N,1); uu = zeros(N,1);
for k = 1:N
    u = (t(k) >= 0.5) * p.u0;
    uu(k) = u;
    x = a*x + cd*u;
    y(k) = x;
end
r = struct('t', t, 'y', y, 'x', x);
if reportLog, r.disturbanceLog = struct('t', t, 'value', uu); end
end

function r = sim_state(p, reportX0)
dt = 0.01; t = (0:dt:1.5).'; a = 0.999;
N = numel(t); x = zeros(N,1); x(1) = p.x0;
for k = 2:N, x(k) = a*x(k-1); end
r = struct('t', t, 'y', x, 'x', x);
if reportX0, r.x0 = struct('x0', p.x0); end
end

% ---------------------------------------------------------------------------
function [mdl, f] = make_simulink_model()
mdl = 'mas_dist_probe';
if bdIsLoaded(mdl), close_system(mdl, 0); end
f = fullfile(tempdir, [mdl '.slx']);
if isfile(f), delete(f); end
new_system(mdl);
add_block('simulink/Sources/Step', [mdl '/Step'], ...
    'Time', '0.5', 'Before', '0', 'After', '1', 'SampleTime', '0.01');
add_block('simulink/Math Operations/Gain', [mdl '/D'], 'Gain', '1');
add_block('simulink/Math Operations/Gain', [mdl '/R'], 'Gain', '1');
add_block('simulink/Math Operations/Sum', [mdl '/Sum'], 'Inputs', '++');
add_block('simulink/Continuous/Transfer Fcn', [mdl '/Plant'], ...
    'Numerator', '[1]', 'Denominator', '[1 1]');
add_block('simulink/Sinks/To Workspace', [mdl '/Y'], ...
    'VariableName', 'yout', 'SaveFormat', 'Timeseries');
add_block('simulink/Sinks/To Workspace', [mdl '/Dlog'], ...
    'VariableName', 'dout', 'SaveFormat', 'Timeseries');
add_block('simulink/Sources/Constant', [mdl '/One'], 'Value', '1');
add_block('simulink/Math Operations/Gain', [mdl '/Ctrl'], 'Gain', '1');
add_block('simulink/Sinks/Terminator', [mdl '/Term']);
add_line(mdl, 'Step/1', 'D/1');
add_line(mdl, 'D/1', 'R/1');
add_line(mdl, 'R/1', 'Sum/2');
add_line(mdl, 'Sum/1', 'Plant/1');
add_line(mdl, 'Plant/1', 'Y/1');
add_line(mdl, 'Step/1', 'Dlog/1');
add_line(mdl, 'One/1', 'Ctrl/1');
add_line(mdl, 'Ctrl/1', 'Term/1');
set_param(mdl, 'StopTime', '1.5', 'Solver', 'ode4', 'FixedStep', '0.01');
save_system(mdl, f);
end

function cfg = sim_cfg(name, mdl, base, pert, tInject, expect, stepTime, after, gainD)
simFcn = @(p) sim_simulink(p, mdl, stepTime, after, gainD);
cfg = struct('name', name, 'base', base, 'perturbed', pert, ...
    'tInject', tInject, 'simFcn', simFcn, 'expect', expect);
end

function r = sim_simulink(p, mdl, stepTime, after, gainD)
set_param([mdl '/R'], 'Gain', num2str(p.R));
if isfield(p, 'K'), set_param([mdl '/Ctrl'], 'Gain', num2str(p.K)); end
set_param([mdl '/D'], 'Gain', num2str(gainD));
set_param([mdl '/Step'], 'Time', num2str(stepTime), 'After', num2str(after));
so = sim(mdl);
y = so.yout;
if isa(y, 'timeseries'), tt = y.Time; yy = y.Data;
else, tt = y(:,1); yy = y(:,2); end
d = so.dout;
if isa(d, 'timeseries'), dt = d.Time; dd = d.Data;
else, dt = d(:,1); dd = d(:,2); end
R = str2double(get_param([mdl '/R'], 'Gain'));
r = struct('t', tt, 'y', yy, 'plantParams', struct('R', R), ...
    'disturbanceLog', struct('t', dt, 'value', dd));
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
