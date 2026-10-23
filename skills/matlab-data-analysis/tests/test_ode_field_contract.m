function res = test_ode_field_contract(verbose)
%TEST_ODE_FIELD_CONTRACT  Every reported observable field means exactly one thing.
%
%   res = test_ode_field_contract()
%
% Why this suite exists: the frozen H54-ODE-N contract asks for
% `error.maxScaled` against a reference of 1e-8. Three different quantities in
% solver work answer to that name -- error over solution magnitude, error over
% the solver's own AbsTol+RelTol*|y| scaling, and error over the acceptance
% tolerance. A Phase 5.5 episode produced the solver-convention number (2.66,
% including a degenerate denominator where |yRef| ~ 2.4e-16 at a zero crossing)
% and was graded against the magnitude convention (3.3e-10). Both numbers were
% "correct"; only the field name was a lie.
%
% The contract fixes each definition explicitly and makes the tool emit the
% ambiguous old name with the magnitude convention plus unambiguous new names,
% so a v1 reader still gets the value the frozen answers expect.
%
% Expected values are hand-computed from 4*exp(-t) in this file, never read back
% from the tool.

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
addpath(fullfile(repo, 'skills', 'matlab-data-analysis', 'scripts'));

T = struct('name', {}, 'fn', {}, 'expect', {});
T(end+1) = tc('schema is versioned',                @() fd_schema(),        'mas-ode-report/2');
T(end+1) = tc('maxAbs is the raw numerator',        @() fd_maxAbs(),        true);
T(end+1) = tc('maxScaled divides solution magnitude', @() fd_maxScaled(),   true);
T(end+1) = tc('solver-scaled error is its own field', @() fd_solverScaled(), true);
T(end+1) = tc('the three scalings are distinguishable', @() fd_distinct(),  true);
T(end+1) = tc('argmax location is reported',        @() fd_where(),         '0.500000/1');
T(end+1) = tc('sample set and aggregation stated',  @() fd_aggregation(),   '5/1');
T(end+1) = tc('denominator rules are machine-readable', @() fd_rules(),     true);
T(end+1) = tc('units are stated per field',         @() fd_units(),         true);
T(end+1) = tc('zero reference keeps maxRel finite', @() fd_zeroRef(),       true);
T(end+1) = tc('NaN candidate: no invented error',   @() fd_nan(),           true);
T(end+1) = tc('invariant drift denominator stated', @() fd_invDrift(),      true);
T(end+1) = tc('compat: magnitude field unchanged',  @() fd_compatValue(),   true);
T(end+1) = tc('compat: frozen osc fixture still PASS', @() fd_compatVerdict(), 'PASS');

nP = 0;
if verbose, fprintf('=== ODE field-contract tests ===\n'); end
R = struct('case', {}, 'got', {}, 'pass', {});
for k = 1:numel(T)
    t = T(k);
    try
        got = t.fn();
    catch e
        got = sprintf('ERR/%s', e.identifier);
    end
    if ischar(t.expect)
        ok = strcmp(char(string(got)), t.expect);
    else
        ok = isequal(got, t.expect);
    end
    nP = nP + ok;
    if verbose
        fprintf('  [%s] %-40s -> %s\n', tern(ok, 'PASS', 'FAIL'), t.name, char(string(got)));
    end
    R(end+1) = struct('case', t.name, 'got', char(string(got)), 'pass', ok); %#ok<AGROW>
end
res = struct('nPass', nP, 'nTotal', numel(T), 'cases', R, 'pass', nP == numel(T));
if verbose, fprintf('\n---- %d / %d cases passed ----\n', nP, numel(T)); end
end

% ===========================================================================
% synthetic case with an exactly known error
% ===========================================================================
function [t, yTrue, delta, atRow] = truth()
t = (0:4).'/4;                     % 0, 0.25, 0.5, 0.75, 1
yTrue = 4*exp(-t);                 % y' = -y, y0 = 4  -> max|y| = 4
delta = 1e-9;
atRow = 3;                         % error placed at t = 0.5
end
function r = run_case()
[t, yTrue, delta, atRow] = truth();
y = yTrue;
y(atRow) = y(atRow) + delta;
r = mas_ode_check(@(tt, yy) -yy, [0 1], 4, struct( ...
    'candidate', struct('t', t, 'y', y), ...
    'relTol', 1e-6, 'absTol', 1e-8, ...
    'reference', @(tt, yy0) 4*exp(-tt)));
end
function ok = close(a, b, relTol)
ok = isfinite(a) && isfinite(b) && abs(a - b) <= relTol*max(abs(b), realmin);
end

function v = fd_schema()
r = run_case();
if isfield(r, 'schema'), v = r.schema; else, v = 'NONE'; end
end
function v = fd_maxAbs()
r = run_case();
[~, ~, delta, ~] = truth();
v = close(r.error.maxAbs, delta, 1e-3);
end
function v = fd_maxScaled()
r = run_case();
[~, yTrue, delta, ~] = truth();
want = delta/max(1, max(abs(yTrue)));        % magnitude convention, hand-computed
v = close(r.error.maxScaled, want, 1e-3);
end
function v = fd_solverScaled()
r = run_case();
[~, yTrue, delta, atRow] = truth();
% MATLAB's own solver scaling: |y-yref| / (AbsTol + RelTol*|yref|), elementwise max
den = 1e-8 + 1e-6*abs(yTrue(atRow));
v = close(r.error.maxSolverScaled, delta/den, 1e-3);
end
function v = fd_distinct()
r = run_case();
a = r.error.maxAbs; b = r.error.maxScaled; c = r.error.maxSolverScaled;
v = (abs(a - b) > 1e-12) && (abs(b - c) > 1e-6) && (abs(a - c) > 1e-6);
end
function v = fd_where()
r = run_case();
v = sprintf('%.6f/%d', r.error.at, r.error.component);
end
function v = fd_aggregation()
r = run_case();
v = sprintf('%d/%d', r.error.rows, r.error.components);
end
function v = fd_rules()
r = run_case();
% Canary: each scaling must carry an explicit, greppable denominator formula
% written in the report's own vocabulary (y_reference, not an internal name).
v = contains(r.error.numeratorRule, 'max |y_candidate - y_reference|') && ...
    contains(r.error.denominatorRule, 'max(1, max|y_reference|)') && ...
    contains(r.error.solverScaledDenominatorRule, 'AbsTol + RelTol');
end
function v = fd_units()
r = run_case();
v = ~isempty(r.error.unit) && contains(r.error.unit, 'fraction') && ...
    contains(r.error.solverScaledUnit, 'solver-tolerance');
end
function v = fd_zeroRef()
% cos(t) crosses zero: elementwise relative error must stay finite because the
% denominator has a floor, and the graded magnitude-scaled field must not blow up.
o = mas_ode_check(@(t, y) [y(2); -y(1)], [0 2*pi], [1; 0], struct( ...
    'reference', @(t, y0) [cos(t); -sin(t)], 'relTol', 1e-9, 'absTol', 1e-11));
v = all(isfinite([o.error.maxAbs, o.error.maxRel, o.error.maxScaled]));
end
function v = fd_nan()
o = mas_ode_check(@(t, y) -y, [0 1], 4, struct( ...
    'candidate', struct('t', (0:2).'/2, 'y', [4; NaN; 1.4715]), ...
    'reference', @(t, y0) 4*exp(-t)));
v = strcmp(o.verdict, 'FAIL') && isnan(o.error.maxAbs);
end
function v = fd_invDrift()
[t, yTrue, ~, atRow] = truth();
y = yTrue; y(atRow) = y(atRow) + 1e-7;
o = mas_ode_check(@(tt, yy) -yy, [0 1], 4, struct( ...
    'candidate', struct('t', t, 'y', y), ...
    'reference', @(tt, yy0) 4*exp(-tt), ...
    'invariant', @(tt, yy) yy.*exp(tt), 'invTolRel', 1e-5));
% I = y*exp(t) is conserved by y' = -y, so the only drift is the injected offset
% at t = 0.5, divided by the floor-clipped reference value I(0) = 4.
want = 1e-7*exp(0.5)/max(1, abs(4));
v = close(o.invariant.maxRelDrift, want, 1e-3) && ...
    contains(o.invariant.denominatorRule, 'max(|invariantRef|, 1)');
end
function v = fd_compatValue()
o = run_case();
% v1 consumers read error.maxScaled; it must still be the magnitude-scaled value
% and equal to maxAbs/scale as before this change.
v = close(o.error.maxScaled, o.error.maxAbs/o.error.scale, 1e-12);
end
function v = fd_compatVerdict()
% the frozen H54-ODE-N fixture: harmonic oscillator, analytic reference,
% conserved energy, relTol 1e-9 / absTol 1e-11, refTolRel 1e-8.
o = mas_ode_check(@(t, y) [y(2); -y(1)], [0 2*pi], [1; 0], struct( ...
    'relTol', 1e-9, 'absTol', 1e-11, ...
    'reference', @(t, y0) [cos(t); -sin(t)], 'refTolRel', 1e-8, ...
    'invariant', @(t, y) y(1).^2 + y(2).^2, 'invTolRel', 1e-8, ...
    'finalValue', [1; 0], 'finalTolRel', 1e-8));
v = o.verdict;
end

% ===========================================================================
function t = tc(name, fn, expect)
t = struct('name', name, 'fn', fn, 'expect', expect);
end
function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
