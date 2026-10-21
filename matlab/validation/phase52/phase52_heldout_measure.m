function v = phase52_heldout_measure(id)
%PHASE52_HELDOUT_MEASURE  Produce measured values for one held-out case.
%   The measured side uses the repository tool under test (H3/H4/H5/H6/H7) or
%   an independent numeric method (H1/H2). It never reads the frozen reference.

repo = fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
addpath(fullfile(repo, 'skills', 'matlab-control-optimization', 'scripts'));
addpath(fullfile(repo, 'skills', 'matlab-simulink-modeling', 'scripts'));
addpath(fullfile(repo, 'skills', 'matlab-signal-vision-ai', 'scripts'));
addpath(fullfile(repo, 'skills', 'matlab-orchestrator', 'scripts'));

switch upper(id)
    case 'H1'
        A = [1 1 1 1; 1 2 4 8; 1 3 9 27; 1 4 16 64];
        xt = [2; -1; 0.5; 3];
        b = A * xt;
        v = struct();
        v.x = A \ b;
        v.I = gauss_legendre_64(0, 1);
    case 'H2'
        dt = 1e-4; T = 2; n = round(T/dt);
        x = 0; t = 0; got = [NaN NaN]; qi = 1; targets = [1 2];
        f = @(x) -3*x + 3;
        for k = 1:n
            k1 = f(x); k2 = f(x + 0.5*dt*k1);
            k3 = f(x + 0.5*dt*k2); k4 = f(x + dt*k3);
            x = x + dt/6*(k1 + 2*k2 + 2*k3 + k4);
            t = t + dt;
            if qi <= 2 && t >= targets(qi) - 1e-12
                got(qi) = x; qi = qi + 1;
            end
        end
        v = struct('x1', got(1), 'x2', got(2));
    case 'H3'
        s = tf('s');
        L = -4/((s + 1)*(s + 3));
        r = mas_stability_verdict(L);
        v = struct();
        v.maxRealPole = max(real(r.analysis.closedLoopPoles));
        v.math = r.math.stability;
        v.target = r.target.status;
        v.evidence = r.evidence.quality;
    case 'H4'
        s = tf('s');
        Ld = tf(0.4, [1 -0.8], 0.1);
        rd = mas_stability_verdict(Ld);
        Lnc = 0.5/(s + 1);
        rn = mas_stability_verdict(Lnc);
        v = struct();
        v.discGmDb = rd.target.gm;
        v.discMath = rd.math.stability;
        v.discTarget = rd.target.status;
        v.discEvidence = rd.evidence.quality;
        v.ncMath = rn.math.stability;
        v.ncTarget = rn.target.status;
        v.ncEvidence = rn.evidence.quality;
        v.ncPmIsNaN = isnan(rn.target.pm);
    case 'H5'
        v = measure_simulink();
    case 'H6'
        r = mas_ofdm_ber(6);
        v = struct('ber6', r.berSim);
    case 'H7'
        prompt = ['用 Simulink 建立模型并仿真，然后对信号做低通滤波器处理'];
        r = mas_route(prompt);
        v = struct();
        v.decision = r.decision;
        v.primary = r.primary;
        if any(strcmp(r.secondary, 'matlab-signal-vision-ai'))
            v.hasSecondary = 'matlab-signal-vision-ai';
        else
            v.hasSecondary = '';
        end
        v.loadOrder = strjoin(r.loadOrder, '>');
    otherwise
        error('phase52:heldout:id', 'no measurement for "%s"', id);
end
end

% ---------------------------------------------------------------------------
function v = measure_simulink()
mdl = 'phase52_heldout_dist';
f = fullfile(tempdir, [mdl '.slx']);
if bdIsLoaded(mdl), close_system(mdl, 0); end
if isfile(f), delete(f); end
new_system(mdl);
cleanup = onCleanup(@() close_and_delete(mdl, f));
add_block('simulink/Sources/Constant', [mdl '/One'], 'Value', '1');
add_block('simulink/Math Operations/Gain', [mdl '/K'], 'Gain', '2');
add_block('simulink/Continuous/Transfer Fcn', [mdl '/Plant'], ...
    'Numerator', '[1]', 'Denominator', '[1 1]');
add_block('simulink/Sinks/To Workspace', [mdl '/Y'], ...
    'VariableName', 'yout', 'SaveFormat', 'Timeseries');
add_line(mdl, 'One/1', 'K/1');
add_line(mdl, 'K/1', 'Plant/1');
add_line(mdl, 'Plant/1', 'Y/1');
set_param(mdl, 'StopTime', '2', 'Solver', 'ode4', 'FixedStep', '0.01');
save_system(mdl, f);

base = struct('K', 2);
pert = struct('K', 5);
expc = struct('direction', 'increase', 'delta', 3*(1 - exp(-2)), ...
    'tol', 2e-3, 'insensitive', false, 'minRel', 1e-8, ...
    'timeTol', 0.02, 'maxResponseDelay', 0.1, 'window', 0.001);
cfg = struct('name', 'H5', 'base', base, 'perturbed', pert, ...
    'tInject', 0, 'simFcn', @(p) run_model(p, mdl), 'expect', expc);
r = mas_dist_enter(cfg);
v = struct('delta', r.measuredDelta, 'effectiveTime', r.effectiveTime, ...
    'verdict', r.verdict, 'evidence', r.evidenceQuality);
clear cleanup;
end

function r = run_model(p, mdl)
set_param([mdl '/K'], 'Gain', num2str(p.K));
so = sim(mdl);
y = so.yout;
if isa(y, 'timeseries')
    tt = y.Time; yy = y.Data;
else
    tt = y(:, 1); yy = y(:, 2);
end
Ks = str2double(get_param([mdl '/K'], 'Gain'));
r = struct('t', tt, 'y', yy, 'plantParams', struct('K', Ks), ...
    'paramLog', struct('t', 0, 'field', 'K', 'value', Ks));
end

function close_and_delete(mdl, f)
if bdIsLoaded(mdl), close_system(mdl, 0); end
if isfile(f), delete(f); end
end

% ---------------------------------------------------------------------------
function I = gauss_legendre_64(a, b)
% 64-point Gauss-Legendre for exp(-t^2). Shares no code with erf/integral.
n = 64; m = floor((n + 1)/2);
xm = 0.5*(b + a); xl = 0.5*(b - a);
I = 0;
for i = 1:m
    z = cos(pi*(i - 0.25)/(n + 0.5));
    for it = 1:100
        p1 = 1; p2 = 0;
        for j = 1:n
            p3 = p2; p2 = p1;
            p1 = ((2*j - 1)*z*p2 - (j - 1)*p3)/j;
        end
        pp = n*(z*p1 - p2)/(z^2 - 1);
        z1 = z; z = z1 - p1/pp;
        if abs(z - z1) < 1e-15, break; end
    end
    w = 2*xl/((1 - z^2)*pp^2);
    I = I + w*(exp(-(xm - xl*z)^2) + exp(-(xm + xl*z)^2));
end
end
