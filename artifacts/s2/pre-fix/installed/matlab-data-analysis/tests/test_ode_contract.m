function res = test_ode_contract(verbose)
%TEST_ODE_CONTRACT  Five-level verification contract for ODE solutions.
%
%   res = test_ode_contract()
%
% The cases cover what a solver exit flag cannot: analytic truth, conserved
% quantities, stiff and non-stiff dynamics, unsuitable solver settings, a step
% size large enough to reverse the engineering conclusion, and finite numbers
% that are simply wrong. Every expected value is recomputed from the raw data by
% a route independent of the tool (hand formulas, the exact solution, or a
% property of the contract); none is "the tool returned what the tool returned".
%
% Symbolic Math Toolbox is probed and reported, but the contract never depends
% on it: references are analytic functions and tight numerical cross-solves.

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
addpath(fullfile(repo, 'skills', 'matlab-data-analysis', 'scripts'));

% =========================================================================
% FIXTURES
% =========================================================================
fDecay = @(t, y) -y;
refDecay = @(t) exp(-t);
fOsc = @(t, y) [y(2); -y(1)];
refOsc = @(t) [cos(t); -sin(t)];
fPend = @(t, y) [y(2); -sin(y(1))];

% A: analytic truth, accuracy claim and final-value claim
A = mas_ode_check(fDecay, [0 2], 1, struct( ...
    'reference', refDecay, 'refTolRel', 1e-6, ...
    'finalValue', exp(-2), 'finalTolRel', 1e-6));

% A2: the solver exits cleanly but no criterion was stated
A2 = mas_ode_check(fDecay, [0 2], 1, struct());

% A3: a false final-value claim against a valid reference
A3 = mas_ode_check(fDecay, [0 2], 1, struct( ...
    'reference', refDecay, 'refTolRel', 1e-6, ...
    'finalValue', 1, 'finalTolRel', 1e-6));

% B: conserved energy, two spellings of the same invariant
B = mas_ode_check(fOsc, [0 10], [1; 0], struct( ...
    'reference', refOsc, 'refTolRel', 1e-6, ...
    'invariant', @(t, y) 0.5*(y(1)^2 + y(2)^2), 'invTolRel', 1e-5));
Bv = mas_ode_check(fOsc, [0 10], [1; 0], struct( ...
    'reference', refOsc, 'refTolRel', 1e-6, ...
    'invariant', @(t, y) 0.5*(y(:,1).^2 + y(:,2).^2), 'invTolRel', 1e-5));

% B2: same solution, a physical tolerance the method cannot honour
B2 = mas_ode_check(fOsc, [0 10], [1; 0], struct( ...
    'reference', refOsc, 'refTolRel', 1e-6, ...
    'invariant', @(t, y) 0.5*(y(1)^2 + y(2)^2), 'invTolRel', 1e-9));

% P: nonlinear conservative dynamics with no analytic reference
P = mas_ode_check(fPend, [0 10], [1; 0], struct( ...
    'invariant', @(t, y) 0.5*y(2)^2 - cos(y(1)), 'invTolRel', 1e-5));

% E: a too-large fixed step; finite but wrong
hE = 0.5; tE = (0:hE:2).'; yE = zeros(size(tE)); yE(1) = 1;
for k = 1:numel(tE) - 1
    yE(k + 1) = yE(k) - hE*yE(k);
end
E = mas_ode_check(fDecay, [0 2], 1, struct( ...
    'candidate', struct('t', tE, 'y', yE), ...
    'reference', refDecay, 'refTolRel', 1e-6));

% D: an unsuitable solver setting for the stated tolerance
D = mas_ode_check(fDecay, [0 10], 1, struct( ...
    'relTol', 1e-3, 'absTol', 1e-3, ...
    'reference', refDecay, 'refTolRel', 1e-6));

% C: stiff linear system, correctly solved; C45: same claim via ode45
C = mas_ode_check(@(t, y) [-1000*y(1) + y(2); -y(2)], [0 1], [1; 1], struct( ...
    'method', 'ode15s', 'expectedStiff', true));
C45 = mas_ode_check(@(t, y) [-1000*y(1) + y(2); -y(2)], [0 1], [1; 1], struct( ...
    'method', 'ode45', 'expectedStiff', true));

% Osc: a non-stiff oscillator must not be labelled stiff
Osc = mas_ode_check(fOsc, [0 2*pi], [1; 0], struct('expectedStiff', false));

% Ev: event detection at t = pi; EvWrong: a false event-time claim
Ev = mas_ode_check(fOsc, [0 4], [0; 1], struct( ...
    'reference', @(t) [sin(t); cos(t)], 'refTolRel', 1e-6, ...
    'eventFun', @(t, y) y(1), 'eventDir', -1, 'eventTime', pi));
EvWrong = mas_ode_check(fOsc, [0 4], [0; 1], struct( ...
    'eventFun', @(t, y) y(1), 'eventDir', -1, 'eventTime', 3.0, 'eventTol', 1e-3));

% F: unstable dynamics, a claim that they decay (the sign is the defect)
F = mas_ode_check(@(t, y) +y, [0 2], 1, struct( ...
    'finalValue', exp(-2), 'finalTolRel', 1e-6));

% S: candidate stops before tspan(end); the final claim is still gradable
tS = (0:0.1:1).'; yS = exp(-tS);
S = mas_ode_check(fDecay, [0 2], 1, struct( ...
    'candidate', struct('t', tS, 'y', yS), ...
    'reference', refDecay, 'finalValue', exp(-2), 'finalTolRel', 1e-6));

% R: a mistyped analytic "reference" must not grade anything
R = mas_ode_check(fDecay, [0 2], 1, struct( ...
    'reference', @(t) exp(t), 'finalValue', exp(-2), 'finalTolRel', 1e-6));

% =========================================================================
% INDEPENDENT RECOMPUTATIONS
% =========================================================================
tA = A.candidate.t(:);
errA = max(abs(A.candidate.y - exp(-tA)) ./ exp(-tA));
eulerEnd = (1 - hE)^(2/hE);
errE = abs(eulerEnd - exp(-2))/exp(-2);
energyRef = 0.5*(1^2 + 0^2);
energyDrift = max(abs(Bv.invariant.values - energyRef)) / max(1, abs(energyRef));
pendRef = 0.5*0^2 - cos(1);
pendDrift = max(abs(P.invariant.values - pendRef)) / max(1, abs(pendRef));
tightFinal = 7.38905609893065;   % e^2, the true y(2) for y' = +y

% =========================================================================
% CASES
% =========================================================================
T = struct('name', {}, 'fn', {}, 'expect', {});

% --- analytic truth and the five levels ----------------------------------
T(end+1) = tc('analytic: PASS', @() A.verdict, 'PASS');
T(end+1) = tc('analytic: all levels agree', @() ...
    strcmp(A.levels.solverExit, 'pass') && strcmp(A.levels.converged, 'pass') && ...
    strcmp(A.levels.errorTol, 'pass') && strcmp(A.levels.conclusion, 'pass'), true);
T(end+1) = tc('analytic: error recomputed from exp(-t)', ...
    @() near(A.error.maxRel, errA, 1e-12), true);
T(end+1) = tc('analytic: error below 1e-6', @() A.error.maxRel < 1e-6, true);
T(end+1) = tc('analytic: reference cross-checked', @() ...
    strcmp(A.reference.kind, 'analytic') && A.reference.ok && A.reference.crossGap < 1e-9, true);
T(end+1) = tc('analytic: final claim accepted', @() st(A, 'claimVsRef'), 'pass');
T(end+1) = tc('analytic: physical level na', @() A.levels.physicalInvariant, 'na');

% --- exit status is not a conclusion -------------------------------------
T(end+1) = tc('exit only: UNDETERMINED, not PASS', @() A2.verdict, 'UNDETERMINED');
T(end+1) = tc('exit only: solver did exit', @() A2.levels.solverExit, 'pass');
T(end+1) = tc('exit only: conclusion undetermined', @() A2.levels.conclusion, 'undetermined');
T(end+1) = tc('exit only: conclusion names the missing evidence', ...
    @() contains(A2.detail, 'conclusion'), true);

% --- finite numbers that are wrong ---------------------------------------
T(end+1) = tc('false final claim: FAIL', @() A3.verdict, 'FAIL');
T(end+1) = tc('false final claim: claimVsRef fails', @() st(A3, 'claimVsRef'), 'fail');
T(end+1) = tc('false final claim: candidate matches itself', ...
    @() st(A3, 'claimVsCandidate'), 'fail');

% --- conservation ---------------------------------------------------------
T(end+1) = tc('energy: PASS', @() B.verdict, 'PASS');
T(end+1) = tc('energy: invariant drift below 1e-5', @() B.invariant.maxRelDrift < 1e-5, true);
T(end+1) = tc('energy: drift recomputed from raw values', ...
    @() near(B.invariant.maxRelDrift, energyDrift, 1e-15), true);
T(end+1) = tc('energy: vectorised invariant not fed a matrix', @() ...
    Bv.invariant.maxRelDrift < 1e-5 && all(abs(Bv.invariant.values - 0.5) < 1e-5), true);
T(end+1) = tc('energy: impossible tolerance FAIL', @() B2.verdict, 'FAIL');
T(end+1) = tc('energy: physics fails while accuracy passes', @() ...
    strcmp(st(B2, 'physicalInvariant'), 'fail') && strcmp(st(B2, 'errorTol'), 'pass'), true);
T(end+1) = tc('pendulum: nonlinear energy PASS', @() P.verdict, 'PASS');
T(end+1) = tc('pendulum: no analytic reference used', @() P.reference.kind, 'tight-ode15s');
T(end+1) = tc('pendulum: drift recomputed', @() near(P.invariant.maxRelDrift, pendDrift, 1e-15), true);

% --- step size and solver settings ---------------------------------------
T(end+1) = tc('coarse Euler: FAIL', @() E.verdict, 'FAIL');
T(end+1) = tc('coarse Euler: errorTol fails', @() st(E, 'errorTol'), 'fail');
T(end+1) = tc('coarse Euler: relative error ~0.538', @() near(E.error.maxRel, errE, 1e-12), true);
T(end+1) = tc('coarse Euler: solver exit still passes', @() E.levels.solverExit, 'pass');
T(end+1) = tc('coarse Euler: convergence undetermined (no method)', ...
    @() E.levels.converged, 'undetermined');
T(end+1) = tc('loose tolerance: FAIL', @() D.verdict, 'FAIL');
T(end+1) = tc('loose tolerance: exit and convergence pass', @() ...
    strcmp(D.levels.solverExit, 'pass') && strcmp(D.levels.converged, 'pass'), true);
T(end+1) = tc('loose tolerance: errorTol exposes the setting', @() st(D, 'errorTol'), 'fail');

% --- stiffness ------------------------------------------------------------
T(end+1) = tc('stiff ode15s: PASS', @() C.verdict, 'PASS');
T(end+1) = tc('stiff ode15s: classified stiff', @() C.stiffness.isStiff, true);
T(end+1) = tc('stiff ode15s: Jacobian ratio ~1000', ...
    @() C.stiffness.lambdaRatio > 500 && C.stiffness.lambdaRatio < 2000, true);
T(end+1) = tc('stiff ode45: stiffness claim still verified', @() C45.verdict, 'PASS');
T(end+1) = tc('stiff ode45: more steps than ode15s', ...
    @() C45.stiffness.stepRatio > 1.5, true);
T(end+1) = tc('oscillator: not stiff', @() Osc.stiffness.isStiff, false);
T(end+1) = tc('oscillator: non-stiff claim PASS', @() Osc.verdict, 'PASS');
T(end+1) = tc('oscillator: Jacobian ratio 1 (imaginary modes)', ...
    @() near(Osc.stiffness.lambdaRatio, 1, 1e-9), true);

% --- events ---------------------------------------------------------------
T(end+1) = tc('event: PASS', @() Ev.verdict, 'PASS');
T(end+1) = tc('event: time within 1e-4 of pi', @() abs(Ev.event.times(1) - pi) < 1e-4, true);
T(end+1) = tc('event: event function is zero there', @() abs(sin(Ev.event.times(1))) < 1e-4, true);
T(end+1) = tc('event: false event time FAIL', @() EvWrong.verdict, 'FAIL');
T(end+1) = tc('event: eventTime fails', @() st(EvWrong, 'eventTime'), 'fail');

% --- defects and reference integrity -------------------------------------
T(end+1) = tc('unstable dynamics: FAIL', @() F.verdict, 'FAIL');
T(end+1) = tc('unstable dynamics: reference is e^2', ...
    @() near(F.reference.final, tightFinal, 1e-6), true);
T(end+1) = tc('unstable dynamics: claimVsRef fails', @() st(F, 'claimVsRef'), 'fail');
T(end+1) = tc('short candidate: UNDETERMINED', @() S.verdict, 'UNDETERMINED');
T(end+1) = tc('short candidate: final claim vs reference passes', @() st(S, 'claimVsRef'), 'pass');
T(end+1) = tc('short candidate: candidate coverage undetermined', ...
    @() st(S, 'claimVsCandidate'), 'undetermined');
T(end+1) = tc('bad analytic reference: UNDETERMINED', @() R.verdict, 'UNDETERMINED');
T(end+1) = tc('bad analytic reference: referenceEstablished fails', ...
    @() st(R, 'referenceEstablished'), 'undetermined');

% --- input validation -----------------------------------------------------
T(end+1) = tc('validation: reversed tspan rejected', ...
    @() err_of(@() mas_ode_check(fDecay, [2 0], 1, struct())), 'ERR');
T(end+1) = tc('validation: non-function rejected', ...
    @() err_of(@() mas_ode_check(1, [0 1], 1, struct())), 'ERR');
T(end+1) = tc('validation: unknown method rejected', ...
    @() err_of(@() mas_ode_check(fDecay, [0 1], 1, struct('method', 'ode23'))), 'ERR');
T(end+1) = tc('validation: candidate without y rejected', ...
    @() err_of(@() mas_ode_check(fDecay, [0 1], 1, struct( ...
        'candidate', struct('t', [0; 1])))), 'ERR');

% =========================================================================
nP = 0;
if verbose, fprintf('=== ODE contract tests ===\n'); end
Rres = struct('case', {}, 'got', {}, 'pass', {});
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
        fprintf('  [%s] %-52s -> %s\n', tern(ok, 'PASS', 'FAIL'), t.name, ...
            char(string(got)));
    end
    Rres(end+1) = struct('case', t.name, 'got', char(string(got)), 'pass', ok); %#ok<AGROW>
end
res = struct('nPass', nP, 'nTotal', numel(T), 'cases', Rres, ...
    'pass', nP == numel(T), ...
    'symbolicToolbox', license('test', 'Symbolic_Toolbox') > 0, ...
    'symbolicUsed', false);
if verbose
    fprintf('\n---- %d / %d ODE-contract cases passed ----\n', nP, numel(T));
    fprintf('Symbolic Math Toolbox available: %d (not used; references are analytic/numerical)\n', ...
        res.symbolicToolbox);
end
end

% ===========================================================================
function v = st(r, id)
v = 'MISSING';
for k = 1:numel(r.checks)
    if strcmp(r.checks(k).id, id)
        v = r.checks(k).status;
        return;
    end
end
end

function v = near(a, b, tol)
v = abs(double(a) - b) <= tol;
end

function s = err_of(fn)
try
    fn();
    s = 'NO_ERROR';
catch
    s = 'ERR';
end
end

function t = tc(name, fn, expect)
t = struct('name', name, 'fn', fn, 'expect', expect);
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
