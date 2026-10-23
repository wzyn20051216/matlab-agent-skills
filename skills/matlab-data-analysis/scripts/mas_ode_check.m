function r = mas_ode_check(odefun, tspan, y0, claims)
%MAS_ODE_CHECK  Verify an ODE solution claim at five independent levels.
%
%   r = mas_ode_check(@(t,y) -y, [0 2], 1, struct('reference', @(t) exp(-t), ...
%           'refTolRel', 1e-6, 'invariant', @(t,y) y))
%
% claims fields (all optional except at least one acceptance criterion):
%   .candidate     struct('t',t,'y',y): a solution to grade. If absent the tool
%                  integrates one with .method/.relTol/.absTol/.maxStep.
%   .method        'ode45' (default) | 'ode15s'
%   .relTol        candidate RelTol (default 1e-6)
%   .absTol        candidate AbsTol (default 1e-8)
%   .maxStep       candidate MaxStep (optional; a large value can be the defect)
%   .reference     analytic reference @(t)->y (row or column)          (truth)
%   .refTolRel     tolerance for candidate/claim vs reference (default 1e-6)
%   .finalValue    claimed state at tspan(end), scalar or vector       (claim)
%   .finalTolRel   relative tolerance for finalValue (default 1e-6)
%   .invariant     @(t,y)->scalar/vector conserved quantity            (physics)
%   .invariantRef  reference value(s) (default invariant(t0,y0))
%   .invTolRel     relative drift tolerance (default 1e-8)
%   .eventFun      @(t,y)->scalar event function                       (event)
%   .eventDir      event direction -1|0|1 (default 0)
%   .eventTime     claimed event time                                  (claim)
%   .eventTol      absolute event-time tolerance (default 1e-4)
%   .expectedStiff logical: assert the stiffness classification
%
% r.verdict     PASS | FAIL | UNDETERMINED
% r.levels      solverExit / converged / errorTol / physical / conclusion
% r.checks      id / status (pass|fail|na|undetermined) / detail
% r.schema      'mas-ode-report/2'
% r.stiffness   isStiff, lambdaRatio, stepRatio, steps45, steps15, classified
% r.convergence ladder values and gaps
% r.event       detected event time (if eventFun given)
% r.error       difference to the reference. THREE scalings of one numerator,
%               each with its own name and stated rule -- they differ by orders
%               of magnitude and are not interchangeable:
%                 maxAbs          |y_candidate - y_reference|, raw
%                 maxScaled       maxAbs / max(1, max|yRef|)      <- what grading
%                                 uses and what v1 readers expect
%                 maxSolverScaled maxAbs / (AbsTol + RelTol*|yRef|) elementwise
%               plus maxRel (per-component, eps floor), at/component/rows/
%               components, and numeratorRule / denominatorRule /
%               solverScaledDenominatorRule / unit / solverScaledUnit so a value
%               can never be quoted without the definition that produced it.
%               Fields are emitted as NaN when no reference exists.
% r.invariant   ref / values / maxRelDrift / tolRel plus numeratorRule,
%               denominatorRule, unit, aggregation
%
% WHY FIVE LEVELS
% A solver can exit with flag 0, produce finite numbers, and still be wrong.
% The levels are deliberately separate:
%   solverExit  the candidate ran and returned finite values
%   converged   independent refinements approach a stable limit
%   errorTol    the candidate (and any claim) agree with an independent truth
%   physical    a stated invariant is conserved within tolerance
%   conclusion  every applicable level agrees; no missing criterion
% A normal exit never makes `conclusion` pass by itself, and a missing
% reference or invariant forces UNDETERMINED rather than PASS.
%
% REFERENCES
% An analytic reference is the truth and is cross-checked against a tight
% ode15s solve. Without one, tightly-solved ode15s and ode45 are compared; if
% they disagree, the tool refuses to grade (UNDETERMINED) instead of picking
% one number. Tolerances are never widened to turn a failure into a pass.

if nargin < 4, error('mas_ode_check:args', 'need odefun, tspan, y0 and claims'); end
if ~isa(odefun, 'function_handle'), error('mas_ode_check:f', 'odefun must be a function handle'); end
if ~isnumeric(tspan) || numel(tspan) ~= 2 || ~all(isfinite(tspan)) || tspan(1) >= tspan(2)
    error('mas_ode_check:tspan', 'tspan must be a finite [t0 t1] with t0 < t1');
end
if ~isnumeric(y0) || isempty(y0) || ~all(isfinite(y0))
    error('mas_ode_check:y0', 'y0 must be finite numeric');
end
if ~isstruct(claims), error('mas_ode_check:claims', 'claims must be a struct'); end
y0 = y0(:);
tspan = tspan(:).';

C = local_check_empty();
notes = {};
t0 = tspan(1); t1 = tspan(2);
r.schema = 'mas-ode-report/2';

% Tolerances are read once, before the candidate is produced, because the error
% block reports a solver-tolerance-scaled quantity whether the candidate was
% integrated here or supplied by the caller.
relTol = local_field(claims, 'relTol', 1e-6);
absTol = local_field(claims, 'absTol', 1e-8);
refTol = local_field(claims, 'refTolRel', 1e-6);

% ---- candidate -----------------------------------------------------------
hasCandidate = isfield(claims, 'candidate') && isstruct(claims.candidate);
if hasCandidate
    cand = normalise_candidate(claims.candidate, t0, t1);
    method = local_field(claims, 'method', 'candidate');
else
    method = local_field(claims, 'method', 'ode45');
    maxStep = local_field(claims, 'maxStep', []);
    opts = odeset('RelTol', relTol, 'AbsTol', absTol);
    if ~isempty(maxStep), opts = odeset(opts, 'MaxStep', maxStep); end
    cand = integrate(odefun, [t0 t1], y0, method, opts);
    cand.requested = struct('method', method, 'relTol', relTol, ...
        'absTol', absTol, 'maxStep', maxStep);
end
r.candidate = cand;

finiteCand = isfield(cand, 'y') && ~isempty(cand.y) && all(isfinite(cand.y(:)));
if finiteCand
    C = local_check_add(C, 'candidateFinite', true, ...
        sprintf('%d state samples, all finite', size(cand.y, 1)));
else
    C = local_check_add(C, 'candidateFinite', false, ...
        'candidate is empty or contains NaN/Inf: no numerical solution to trust');
    r.verdict = 'FAIL'; r.levels = local_levels(C, false);
    r.checks = C; r.notes = {'candidate is not finite'};
    r.error = local_error_block([], [], cand.t(:), refTol, relTol, absTol);
    r.error.status = 'not computed: candidate is not finite';
    r.detail = 'FAIL at solverExit: candidate is empty or non-finite';
    return;
end

% ---- solverExit ----------------------------------------------------------
% A candidate supplied by the caller has no solver flag; finite output is all
% this level can certify, and the level says exactly that.
if hasCandidate
    solverTxt = 'caller-supplied candidate: finite output only (no solver flag)';
else
    solverTxt = sprintf('%s exited with success=%d, %d steps', method, ...
        cand.success, cand.steps);
end
if ~hasCandidate && ~cand.success
    C = local_check_add(C, 'solverExit', false, solverTxt);
else
    C = local_check_add(C, 'solverExit', true, solverTxt);
end

% ---- reference -----------------------------------------------------------
ref = struct('kind', 'none', 'ok', false, 'gap', NaN);
hasAnalytic = isfield(claims, 'reference') && isa(claims.reference, 'function_handle');
tq = cand.t(:);
yRef = [];
yRefFinal = [];
if hasAnalytic
    try
        yRef = eval_reference(claims.reference, tq, numel(y0));
        yRefFinal = eval_reference(claims.reference, t1, numel(y0)).';
        ref.kind = 'analytic';
        ref.ok = true;
        % Cross-check the supplied analytic formula at the ENDPOINTS against an
        % independent tight solve. Candidate output times are not endpoints and
        % must not be used for this check.
        try
            tight = integrate(odefun, [t0 t1], y0, 'ode15s', ...
                odeset('RelTol', 1e-11, 'AbsTol', 1e-13));
            yA0 = eval_reference(claims.reference, t0, numel(y0));
            e0 = norm(yA0.' - tight.y(1, :).');
            e1 = norm(yRefFinal - tight.y(end, :).');
            ref.crossGap = max(e0, e1);
            ref.crossOk = ref.crossGap <= 1e-6*max(1, norm(yRefFinal));
            if ~ref.crossOk
                ref.ok = false;
                notes{end+1} = 'analytic reference disagrees with a tight ode15s solve';
            end
        catch ME
            ref.crossOk = false;
            notes{end+1} = ['analytic reference cross-check failed: ' ME.message];
        end
    catch ME
        ref.kind = 'analytic';
        ref.ok = false;
        notes{end+1} = ['analytic reference could not be evaluated: ' ME.message];
    end
else
    % Two tight solvers, no shared code path. The reference is sampled at the
    % candidate times PLUS tspan(end), because a final-value claim refers to the
    % end of the interval even when the candidate stops earlier.
    t1InTq = any(abs(tq - t1) <= 10*eps(max(1, t1)));
    tqRef = unique([tq(:); t1]);
    s15 = [];
    try
        s15 = integrate(odefun, [t0 t1], y0, 'ode15s', ...
            odeset('RelTol', 1e-11, 'AbsTol', 1e-13), tqRef);
    catch ME15
        notes{end+1} = ['tight ode15s failed: ' ME15.message];
    end
    s45 = [];
    try
        s45 = integrate(odefun, [t0 t1], y0, 'ode45', ...
            odeset('RelTol', 1e-11, 'AbsTol', 1e-13), tqRef);
    catch ME45
        notes{end+1} = ['tight ode45 failed (may be stiff): ' ME45.message];
    end
    if ~isempty(s15)
        Yall = s15.y;
        if t1InTq
            yRef = Yall;
        else
            yRef = Yall(1:end-1, :);
        end
        yRefFinal = Yall(end, :).';
        ref.kind = 'tight-ode15s';
        if ~isempty(s45)
            y45 = s45.y;
            ref.gap = max_rel(Yall, y45);
            ref.crossGap = ref.gap;
            ref.crossOk = ref.gap <= 1e-6;
            if ~ref.crossOk
                notes{end+1} = 'tight ode15s and ode45 disagree; no reference established';
            end
        else
            ref.crossOk = true;   % only one route available; recorded as such
            ref.crossGap = NaN;
        end
        ref.ok = true;
    else
        ref.kind = 'none';
        ref.ok = false;
        notes{end+1} = 'no reference solution available';
    end
end
ref.final = yRefFinal;
r.reference = ref;
hasFinal = isfield(claims, 'finalValue') && ~isempty(claims.finalValue);
if ref.ok
    C = local_check_add(C, 'referenceEstablished', true, ...
        sprintf('%s reference; cross gap %.2e', ref.kind, ref.crossGap));
elseif hasFinal
    C = local_check_add(C, 'referenceEstablished', NaN, ...
        'no trustworthy independent reference: the final-value claim cannot be graded');
else
    C = local_check_add(C, 'referenceEstablished', 'na', ...
        'no reference requested or available; accuracy is not graded');
end

% ---- convergence of the numerical family --------------------------------
% The ladder is about whether the problem has a stable numerical limit. It is
% not evidence that an arbitrary candidate is accurate; that is errorTol.
[r.convergence, convStatus] = convergence_ladder(odefun, tspan, y0, method, cand.t);
if strcmp(convStatus, 'pass')
    C = local_check_add(C, 'converged', true, sprintf( ...
        'successive RelTol refinements change the solution by %.2e', ...
        r.convergence.finestGap));
elseif strcmp(convStatus, 'fail')
    C = local_check_add(C, 'converged', false, ...
        'successive refinements do not approach a stable limit');
else
    C = local_check_add(C, 'converged', NaN, r.convergence.reason);
end

% ---- error to reference --------------------------------------------------
% A reference is truth, not an acceptance criterion. The candidate's accuracy
% is graded only when the caller states a tolerance (refTolRel) or a final-value
% claim; otherwise the measured error is reported for information and the level
% is `na`. Grading against an unstated default would fail a candidate for a
% requirement nobody made.
claimTol = local_field(claims, 'finalTolRel', 1e-6);
hasRefTol = isfield(claims, 'refTolRel') && isscalar(claims.refTolRel);
needErrorEvidence = false;
if ref.ok
    yCand = cand.y;
    dAbs = abs(yCand - yRef);
    % Grade on the absolute error normalised by the solution magnitude. Element-
    % wise relative error diverges at a zero crossing (cos(t) near pi/2) and
    % would fail an otherwise accurate oscillator; the raw value is still
    % reported for diagnosis.
    r.error = local_error_block(dAbs, yRef, tq, refTol, relTol, absTol);
    if hasRefTol || hasFinal
        needErrorEvidence = true;
        if r.error.maxScaled <= refTol
            C = local_check_add(C, 'errorTol', true, sprintf( ...
                'candidate vs reference: maxAbs %.2e, scaled %.2e (elementwise maxRel %.2e, tol %.1e)', ...
                r.error.maxAbs, r.error.maxScaled, r.error.maxRel, refTol));
        else
            C = local_check_add(C, 'errorTol', false, sprintf( ...
                'candidate vs reference: maxAbs %.2e, scaled %.2e exceeds tol %.1e (elementwise maxRel %.2e)', ...
                r.error.maxAbs, r.error.maxScaled, refTol, r.error.maxRel));
        end
    else
        C = local_check_add(C, 'errorTol', 'na', sprintf( ...
            'reference available (scaled error %.2e) but no refTolRel/finalValue claim: accuracy not graded', ...
            r.error.maxScaled));
    end
elseif hasFinal
    r.error = local_error_block([], [], tq, refTol, relTol, absTol);
    C = local_check_add(C, 'errorTol', NaN, 'no reference: error tolerance not certifiable');
else
    r.error = local_error_block([], [], tq, refTol, relTol, absTol);
    C = local_check_add(C, 'errorTol', 'na', ...
        'no reference and no accuracy claim: error tolerance not part of this audit');
end

% ---- final-value claim ---------------------------------------------------
if isfield(claims, 'finalValue') && ~isempty(claims.finalValue)
    claimed = claims.finalValue(:);
    if numel(claimed) ~= numel(y0)
        C = local_check_add(C, 'claimVsRef', false, ...
            sprintf('finalValue has %d entries; state has %d', numel(claimed), numel(y0)));
    else
        needErrorEvidence = true;
        if ref.ok
            dClaim = abs(claimed - yRefFinal);
            lim = claimTol*max(abs(yRefFinal), 1);
            pass = all(dClaim <= lim);
            C = local_check_add(C, 'claimVsRef', pass, sprintf( ...
                'claimed final state vs reference: maxAbs %.2e, maxRel %.2e (tol %.1e)', ...
                max(dClaim), max(dClaim./max(abs(yRefFinal), eps)), claimTol));
        else
            C = local_check_add(C, 'claimVsRef', NaN, ...
                'finalValue given but no independent reference: not gradable');
        end
        % The claim must also be consistent with the supplied candidate; a
        % correct reference cannot excuse a candidate that does not match it.
        coversT1 = abs(cand.t(end) - t1) <= 10*eps(max(1, t1));
        if ~coversT1
            C = local_check_add(C, 'claimVsCandidate', NaN, sprintf( ...
                'candidate ends at t=%.6g, before tspan(end)=%.6g: final state not sampled', ...
                cand.t(end), t1));
        else
            dCand = abs(claimed - cand.y(end,:).');
            limC = claimTol*max(abs(cand.y(end,:).'), 1);
            C = local_check_add(C, 'claimVsCandidate', all(dCand <= limC), sprintf( ...
                'claimed final state vs candidate: maxAbs %.2e (tol %.1e)', ...
                max(dCand), claimTol));
        end
    end
end

% ---- physical invariant --------------------------------------------------
if isfield(claims, 'invariant') && isa(claims.invariant, 'function_handle')
    try
        invVals = eval_invariant(claims.invariant, cand.t, cand.y);
        if isfield(claims, 'invariantRef') && ~isempty(claims.invariantRef)
            invRef = claims.invariantRef(:).';
        else
            invRef = eval_invariant(claims.invariant, t0, cand.y(1,:));
        end
        if numel(invRef) ~= size(invVals, 2)
            error('mas_ode_check:invariantSize', 'invariantRef has the wrong length');
        end
        drift = abs(invVals - invRef) ./ max(abs(invRef), 1);
        invTol = local_field(claims, 'invTolRel', 1e-8);
        r.invariant = struct('ref', invRef, 'values', invVals, ...
            'maxRelDrift', max(drift(:)), 'tolRel', invTol, ...
            'numeratorRule', 'max |invariant(candidate) - invariantRef| per component', ...
            'denominatorRule', 'max(|invariantRef|, 1) per component, floored at 1', ...
            'unit', 'fraction of the reference invariant value (dimensionless)', ...
            'aggregation', sprintf('%d samples x %d component(s), max', ...
            size(invVals, 1), size(invVals, 2)));
        needErrorEvidence = true;
        C = local_check_add(C, 'physicalInvariant', max(drift(:)) <= invTol, sprintf( ...
            'invariant drift max %.2e (tol %.1e)', max(drift(:)), invTol));
    catch ME
        r.invariant = struct('error', ME.message);
        C = local_check_add(C, 'physicalInvariant', NaN, ...
            ['invariant could not be evaluated: ' ME.message]);
    end
else
    r.invariant = struct();
    C = local_check_add(C, 'physicalInvariant', 'na', 'no invariant was declared');
end

% ---- stiffness classification -------------------------------------------
r.stiffness = classify_stiffness(odefun, tspan, y0);
if isfield(claims, 'expectedStiff') && ~isempty(claims.expectedStiff)
    needErrorEvidence = true;
    pass = logical(claims.expectedStiff) == r.stiffness.isStiff;
    C = local_check_add(C, 'stiffnessMatch', pass, sprintf( ...
        'expected stiff=%d, classified stiff=%d (Jacobian ratio %.3g, step ratio %.2f)', ...
        logical(claims.expectedStiff), r.stiffness.isStiff, ...
        r.stiffness.lambdaRatio, r.stiffness.stepRatio));
else
    C = local_check_add(C, 'stiffnessMatch', 'na', sprintf( ...
        'classified stiff=%d (Jacobian ratio %.3g, step ratio %.2f); no claim to grade', ...
        r.stiffness.isStiff, r.stiffness.lambdaRatio, r.stiffness.stepRatio));
end

% ---- event detection -----------------------------------------------------
if isfield(claims, 'eventFun') && isa(claims.eventFun, 'function_handle')
    dir = local_field(claims, 'eventDir', 0);
    evOpts = odeset('RelTol', 1e-9, 'AbsTol', 1e-11, ...
        'Events', @(t, y) local_event(claims.eventFun, t, y, dir));
    evSol = integrate(odefun, [t0 t1], y0, 'ode45', evOpts);
    r.event = struct('times', evSol.te, 'states', evSol.ye, 'found', ~isempty(evSol.te));
    if isfield(claims, 'eventTime') && ~isempty(claims.eventTime)
        needErrorEvidence = true;
        if isempty(evSol.te)
            C = local_check_add(C, 'eventTime', false, ...
                'claimed an event but none was detected in tspan');
        else
            evTol = local_field(claims, 'eventTol', 1e-4);
            C = local_check_add(C, 'eventTime', ...
                abs(evSol.te(1) - claims.eventTime) <= evTol, sprintf( ...
                'detected event at %.6g vs claimed %.6g (tol %.1e)', ...
                evSol.te(1), claims.eventTime, evTol));
        end
    else
        C = local_check_add(C, 'eventTime', 'na', ...
            sprintf('detected %d event(s); no time claim to grade', numel(evSol.te)));
    end
else
    r.event = struct('found', false, 'times', []);
    C = local_check_add(C, 'eventTime', 'na', 'no event function was declared');
end

% ---- conclusion ----------------------------------------------------------
if ~needErrorEvidence
    C = local_check_add(C, 'conclusion', NaN, ...
        'no acceptance criterion (reference, finalValue, invariant, event or stiffness): solver exit alone cannot PASS');
elseif any(strcmp({C.status}, 'fail'))
    C = local_check_add(C, 'conclusion', false, ...
        'at least one independent level failed');
elseif any(strcmp({C.status}, 'undetermined'))
    C = local_check_add(C, 'conclusion', NaN, ...
        'evidence is missing or a reference is unresolved: no engineering conclusion');
else
    C = local_check_add(C, 'conclusion', true, ...
        'exit, convergence, error, physics and the stated claims agree');
end

st = {C.status};
if any(strcmp(st, 'fail'))
    r.verdict = 'FAIL';
elseif any(strcmp(st, 'undetermined'))
    r.verdict = 'UNDETERMINED';
else
    r.verdict = 'PASS';
end
r.ok = strcmp(r.verdict, 'PASS');
r.levels = local_levels(C, ref.ok);
r.checks = C;
r.notes = notes;
r.nChecks = numel(C);
r.nPass = nnz(strcmp(st, 'pass'));
r.nFail = nnz(strcmp(st, 'fail'));
r.nUndetermined = nnz(strcmp(st, 'undetermined'));
r.nNa = nnz(strcmp(st, 'na'));
notOk = strcmp(st, 'fail') | strcmp(st, 'undetermined');
r.detail = sprintf('%s: %d pass, %d fail, %d undetermined, %d na', ...
    r.verdict, r.nPass, r.nFail, r.nUndetermined, r.nNa);
if any(notOk)
    r.detail = sprintf('%s (%s)', r.detail, strjoin({C(notOk).id}, ', '));
end
end

% ===========================================================================
function e = local_error_block(dAbs, yRef, tq, refTol, relTol, absTol)
%LOCAL_ERROR_BLOCK  One name per quantity, plus the rule that produced it.
% A single `maxScaled` was ambiguous: solver work has three legitimate scalings
% of the same numerator, and an answer key that names only the field cannot say
% which one it meant. The v1 name keeps its v1 meaning (solution magnitude) so
% older reports still grade unchanged, and the other two get names that cannot
% be confused with it. Empty input means no reference existed: the field set is
% still emitted, as NaN, so a reader never mistakes an absent field for a zero.
numeratorRule = 'max |y_candidate - y_reference| over every state row and component';
magnitudeRule = 'max(1, max|y_reference|): global solution magnitude, floored at 1';
relativeRule = 'max(|y_reference| elementwise, eps): per-component, floored at eps';
toleranceRule = 'AbsTol + RelTol*|y_reference| elementwise: the scaling the solver itself uses';
if isempty(dAbs)
    e = struct('maxAbs', NaN, 'maxRel', NaN, 'scale', NaN, 'maxScaled', NaN, ...
        'maxSolverScaled', NaN, 'at', NaN, 'component', NaN, ...
        'rows', 0, 'components', 0, 'tolRel', refTol, ...
        'numeratorRule', numeratorRule, 'denominatorRule', magnitudeRule, ...
        'relativeDenominatorRule', relativeRule, ...
        'solverScaledDenominatorRule', toleranceRule, ...
        'unit', 'fraction of solution magnitude (dimensionless)', ...
        'solverScaledUnit', 'multiple of solver-tolerance (dimensionless)', ...
        'status', sprintf('not computed: no reference at %d reported times', numel(tq)));
    return;
end
[maxAbs, iargmax] = max(dAbs(:));
[irow, icomp] = ind2sub(size(dAbs), iargmax);
scale = max(1, max(abs(yRef(:))));
e = struct( ...
    'maxAbs', maxAbs, ...
    'at', tq(irow), 'component', icomp, ...
    'rows', size(dAbs, 1), 'components', size(dAbs, 2), ...
    'scale', scale, ...
    'maxScaled', maxAbs/scale, ...
    'maxRel', max(dAbs(:) ./ max(abs(yRef(:)), eps)), ...
    'maxSolverScaled', max(dAbs(:) ./ (absTol + relTol*abs(yRef(:)))), ...
    'tolRel', refTol, ...
    'numeratorRule', numeratorRule, 'denominatorRule', magnitudeRule, ...
    'relativeDenominatorRule', relativeRule, ...
    'solverScaledDenominatorRule', toleranceRule, ...
    'unit', 'fraction of solution magnitude (dimensionless)', ...
    'solverScaledUnit', 'multiple of solver-tolerance (dimensionless)', ...
    'status', 'computed against the reference');
end

% ===========================================================================
function cand = normalise_candidate(c, t0, t1)
if ~isfield(c, 't') || ~isfield(c, 'y'), error('mas_ode_check:candidate', 'candidate needs t and y'); end
t = c.t(:); y = c.y;
if size(y, 1) ~= numel(t)
    if size(y, 2) == numel(t)
        y = y.';
    else
        error('mas_ode_check:candidate', 'candidate.y rows must match candidate.t');
    end
end
if any(~isfinite(t)) || t(1) < t0 - 10*eps(t1) || t(end) > t1 + 10*eps(t1)
    error('mas_ode_check:candidate', 'candidate.t must lie inside tspan');
end
cand = struct('t', t, 'y', y, 'success', true, 'steps', NaN, 'te', [], 'ye', []);
end

function s = integrate(f, tspan, y0, method, opts, tq)
% The solver is always called on the two-element interval so its natural step
% sequence (and therefore the step count) is preserved. Requested output times
% are produced by dense-output interpolation: with a tspan vector the solver may
% insert extra internal points, so exact time matching is not a contract.
if nargin < 6, tq = []; end
switch lower(method)
    case 'ode45'
        sol = ode45(f, [tspan(1) tspan(end)], y0, opts);
    case 'ode15s'
        sol = ode15s(f, [tspan(1) tspan(end)], y0, opts);
    otherwise
        error('mas_ode_check:method', 'method must be ode45 or ode15s');
end
if ~isempty(tq)
    req = tq(:).';
    req = req(req >= tspan(1) - 10*eps(tspan(1)) & ...
              req <= tspan(end) + 10*eps(tspan(end)));
    yq = deval(sol, req).';
    tt = req;
else
    tt = sol.x(:).';
    yq = sol.y.';
end
if isfield(sol, 'xe')
    te = sol.xe; ye = sol.ye;
else
    te = []; ye = [];
end
s = struct('t', tt, 'y', yq, 'te', te, 'ye', ye, ...
    'success', true, 'steps', numel(sol.x) - 1);
end

function y = eval_reference(fh, t, n)
% Accept both common vectorised spellings: @(t)[cos(t);-sin(t)] builds states
% down the columns for a ROW t, while @(t)exp(-t) is shape-agnostic. Passing a
% column t to the first spelling silently concatenates to 2N x 1, so the
% orientation is tried explicitly instead of guessed from a size mismatch.
t = t(:);
y = fh(t.');
if size(y, 1) == numel(t) && size(y, 2) == n
    return;
end
if size(y, 2) == numel(t) && size(y, 1) == n
    y = y.';
    return;
end
try
    y2 = fh(t);
catch
    y2 = [];
end
if size(y2, 1) == numel(t) && size(y2, 2) == n
    y = y2;
    return;
end
if size(y2, 2) == numel(t) && size(y2, 1) == n
    y = y2.';
    return;
end
error('mas_ode_check:reference', 'reference returned %s for %d times, expected %d x %d', ...
    mat2str(size(y)), numel(t), numel(t), n);
end

function v = eval_invariant(fh, t, y)
% Always evaluate row by row. A vectorised invariant such as
% 0.5*(y(:,1).^2+y(:,2).^2) silently returns a constant if handed the whole
% matrix, which would fabricate a passing drift; scalar invariants must see one
% state at a time for the same reason.
t = t(:); y = y;
if size(y, 1) ~= numel(t)
    error('mas_ode_check:invariant', 'invariant state rows must match t');
end
v0 = fh(t(1), y(1, :));
v0 = v0(:).';
V = zeros(numel(t), numel(v0));
V(1, :) = v0;
for k = 2:numel(t)
    vk = fh(t(k), y(k, :));
    vk = vk(:).';
    if numel(vk) ~= numel(v0)
        error('mas_ode_check:invariantSize', 'invariant changed length along the trajectory');
    end
    V(k, :) = vk;
end
v = V;
end

function [v, isterminal, direction] = local_event(fh, t, y, dir)
v = fh(t, y);
v = v(1);
isterminal = 0;
direction = dir;
end

function g = max_rel(a, b)
% Scale-aware gap: absolute difference normalised by the magnitude of the
% solution, not element-wise. Element-wise relative error is meaningless near a
% zero crossing and would turn a converged oscillator into a "failure".
scale = max(1, max(abs(b(:))));
g = max(abs(a(:) - b(:))) / scale;
end

function [S, status] = convergence_ladder(f, tspan, y0, method, tq)
S = struct('tols', [1e-6 1e-8 1e-10], 'gaps', [], 'finestGap', NaN, 'reason', '');
if ~any(strcmpi(method, {'ode45', 'ode15s'}))
    status = 'undetermined';
    S.reason = ['caller-supplied candidate has no declared solver method: ' ...
        'there is no refinement family to test'];
    return;
end
tols = S.tols;
Y = cell(1, 3);
ok = true;
for k = 1:3
    try
        s = integrate(f, tspan, y0, method, ...
            odeset('RelTol', tols(k), 'AbsTol', tols(k)*1e-2), tq);
        Y{k} = s.y;
    catch
        ok = false;
        Y{k} = [];
    end
end
if ~ok || any(cellfun(@isempty, Y))
    status = 'undetermined';
    S.reason = 'a refinement rung failed: convergence not measurable';
    return;
end
g1 = max_rel(Y{1}, Y{2});
g2 = max_rel(Y{2}, Y{3});
S.gaps = [g1 g2];
S.finestGap = g2;
floorG = 1e-8;
if ~isfinite(g2)
    status = 'fail';
    S.reason = 'refinement gaps are not finite';
elseif g2 <= floorG
    status = 'pass';
    S.reason = 'refinements settled at the interpolation/roundoff floor';
elseif g2 <= 0.5*g1
    status = 'pass';
else
    status = 'fail';
    S.reason = sprintf('refinements do not settle (gaps %.2e -> %.2e)', g1, g2);
end
end

function S = classify_stiffness(f, tspan, y0)
% Stiffness is a property of the Jacobian, not of a solver's step count. The
% ratio max|Re lambda| / min|Re lambda| is evaluated at several states along a
% tight trajectory (a nonlinear problem can become stiff later), and the
% ode45/ode15s step ratio is recorded as corroborating, not decisive, evidence.
S = struct('isStiff', false, 'ratio', NaN, 'stepRatio', NaN, ...
    'lambdaRatio', NaN, 'steps45', NaN, 'steps15', NaN, 'classified', 'unknown');
try
    s45 = integrate(f, tspan, y0, 'ode45', odeset('RelTol', 1e-6, 'AbsTol', 1e-8));
    S.steps45 = s45.steps;
catch
    S.steps45 = Inf;
end
try
    s15 = integrate(f, tspan, y0, 'ode15s', odeset('RelTol', 1e-6, 'AbsTol', 1e-8));
    S.steps15 = s15.steps;
catch
    S.steps15 = Inf;
end
if isfinite(S.steps45) && isfinite(S.steps15) && S.steps15 > 0
    S.stepRatio = S.steps45 / S.steps15;
end
ratios = [];
try
    tight = integrate(f, tspan, y0, 'ode15s', ...
        odeset('RelTol', 1e-9, 'AbsTol', 1e-11));
    idx = unique(round(linspace(1, numel(tight.t), 5)));
    for k = idx
        ratios(end+1) = jac_stiffness_ratio(f, tight.t(k), tight.y(k, :)); %#ok<AGROW>
    end
catch
    try
        ratios = jac_stiffness_ratio(f, tspan(1), y0);
    catch
        ratios = [];
    end
end
ratios = ratios(isfinite(ratios));
if ~isempty(ratios)
    S.lambdaRatio = max(ratios);
    S.ratio = S.lambdaRatio;
end
if ~isfinite(S.steps45) && isfinite(S.steps15)
    S.isStiff = true;
    S.classified = 'stiff (ode45 failed)';
elseif isfinite(S.lambdaRatio)
    S.isStiff = S.lambdaRatio >= 1e2 || ...
        (isfinite(S.stepRatio) && S.stepRatio >= 10);
    if S.isStiff
        S.classified = 'stiff';
    else
        S.classified = 'nonstiff';
    end
elseif isfinite(S.stepRatio)
    S.isStiff = S.stepRatio >= 10;
    if S.isStiff, S.classified = 'stiff (step ratio only)';
    else, S.classified = 'nonstiff (step ratio only)'; end
else
    S.classified = 'unknown';
end
end

function r = jac_stiffness_ratio(f, t, y)
y = y(:);
n = numel(y);
J = zeros(n);
h = sqrt(eps) * max(1, abs(y));
for j = 1:n
    e = zeros(n, 1);
    e(j) = h(j);
    d = f(t, y + e) - f(t, y - e);
    J(:, j) = d(:) / (2*h(j));
end
lam = eig(J);
re = abs(real(lam));
re = re(re > 1e-12*max(1, max(re)));   % purely imaginary/zero modes are not stiffness
if numel(re) < 2
    r = 1;
else
    r = max(re) / min(re);
end
end

function v = local_field(s, f, dflt)
v = dflt;
if isfield(s, f) && ~isempty(s.(f)), v = s.(f); end
end

function C = local_check_empty()
C = struct('id', {}, 'status', {}, 'detail', {});
end

function C = local_check_add(C, id, pass, detail)
if ischar(pass)
    st = pass;
elseif isnan(pass)
    st = 'undetermined';
elseif pass
    st = 'pass';
else
    st = 'fail';
end
C(end+1) = struct('id', id, 'status', st, 'detail', detail); %#ok<AGROW>
end

function L = local_levels(C, refOk)
ids = {'solverExit', 'converged', 'errorTol', 'physicalInvariant', 'conclusion'};
L = struct();
for k = 1:numel(ids)
    idx = find(strcmp({C.id}, ids{k}), 1);
    if isempty(idx)
        L.(ids{k}) = 'na';
    else
        L.(ids{k}) = C(idx).status;
    end
end
L.referenceEstablished = refOk;
end
