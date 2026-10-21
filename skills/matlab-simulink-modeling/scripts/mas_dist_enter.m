function r = mas_dist_enter(cfg)
%MAS_DIST_ENTER  Did the disturbance actually reach the plant?
%
%   r = mas_dist_enter(cfg)
%
%   cfg.name        label used in the report
%   cfg.base        struct of parameter values for the unperturbed run
%   cfg.perturbed   struct of parameter values for the perturbed run
%   cfg.tInject     time at which the disturbance should take effect
%   cfg.simFcn      @(p) -> struct with t, y, x (optional), plantParams,
%                   paramLog (optional), disturbanceLog (optional)
%   cfg.expect      struct with direction, delta, tol, insensitive, minRel,
%                   timeTol, maxResponseDelay, window
%   cfg.inputFields (optional) changed fields that are INPUTS, checked against
%                   disturbanceLog instead of plantParams
%   cfg.stateFields (optional) changed fields that are INITIAL STATES, checked
%                   against r.x0 or r.initialState
%
% WHY THIS EXISTS
% A disturbance can change the output without reaching the plant (a controller
% reads the new value and saturates), and it can fail to change the output while
% still being correctly applied (the output is insensitive by construction).
% Looking at the output curve alone cannot distinguish those cases. This
% verifier therefore walks the chain the user asked for:
%
%   requested change -> parameter/input/state change -> plant receipt ->
%   output or internal-state change -> independent prediction and timing
%
% Each arrow is a separate check with its own evidence. A missing arrow is
% UNDETERMINED, not PASS. An output that is expected to be insensitive does not
% excuse the verifier from looking at internal states.
%
% EVIDENCE SOURCES
%   plantParams     parameter values the PLANT used at the end of the run
%   paramLog        optional time series of parameter values (struct with t and
%                   one numeric vector per parameter)
%   disturbanceLog  optional time series of the signal at the plant input
%                   (struct with t and value, or t and one vector per input)
%   x               internal states, compared between the two runs
%
% The independent prediction is cfg.expect.delta. It must come from an
% independent calculation, not from the same simulation that is being checked.

if nargin < 1 || ~isstruct(cfg)
    r = undet('INVALID_CONFIG', 'cfg must be a struct');
    return;
end

need = {'name','base','perturbed','tInject','simFcn','expect'};
for k = 1:numel(need)
    if ~isfield(cfg, need{k})
        r = undet('INVALID_CONFIG', ['missing cfg.' need{k}]);
        return;
    end
end

e = defaults(cfg.expect);
base = cfg.base;
pert = cfg.perturbed;
changed = changed_fields(base, pert);
inputFields = {};
if isfield(cfg, 'inputFields'), inputFields = cellstr(cfg.inputFields); end
stateFields = {};
if isfield(cfg, 'stateFields'), stateFields = cellstr(cfg.stateFields); end
paramFields = setdiff(changed, [inputFields(:); stateFields(:)]);

checks = struct('id', {}, 'status', {}, 'detail', {});
reasons = {};
notes = {};

% ---- 1. run both experiments ---------------------------------------------
try
    B = normalise(cfg.simFcn(base));
    P = normalise(cfg.simFcn(pert));
catch ME
    checks(end+1) = chk('sim', 'UNDETERMINED', [ME.identifier ' :: ' ME.message]);
    r = finish(cfg, checks, {'SIM_ERROR'}, 'NOT VERIFIED', struct( ...
        'changedFields', {changed}, 'effectiveTime', NaN), ...
        ['simulation failed: ' ME.message]);
    return;
end
checks(end+1) = chk('sim', 'PASS', sprintf('base %d samples, perturbed %d samples', ...
    numel(B.t), numel(P.t)));

if any(~isfinite(B.t)) || any(~isfinite(P.t)) || numel(B.y) == 0 || numel(P.y) == 0
    checks(end+1) = chk('sim', 'UNDETERMINED', 'time or output is empty/non-finite');
    r = finish(cfg, checks, {'SIM_ERROR'}, 'NOT VERIFIED', struct( ...
        'changedFields', {changed}, 'effectiveTime', NaN), 'non-finite simulation output');
    return;
end

% ---- 2. requested change --------------------------------------------------
if isempty(changed)
    checks(end+1) = chk('request', 'FAIL', ...
        'base and perturbed are identical; there is nothing to propagate');
    r = finish(cfg, checks, {'NO_CHANGE_REQUESTED'}, 'NOT VERIFIED', struct( ...
        'changedFields', {changed}, 'effectiveTime', NaN), 'no change was requested');
    return;
end
checks(end+1) = chk('request', 'PASS', ['changed: ' strjoin(changed, ', ')]);

% ---- 3. did the change reach the PLANT? ----------------------------------
plantParams = getfielddef(P, 'plantParams', []);
paramLog = getfielddef(P, 'paramLog', []);
distLog = getfielddef(P, 'disturbanceLog', []);
x0 = getfielddef(P, 'x0', getfielddef(P, 'initialState', []));

receipt = struct('field', {}, 'status', {}, 'detail', {}, ...
    'requested', {}, 'observed', {}, 'time', {});
for k = 1:numel(paramFields)
    f = paramFields{k};
    [st, det, obs, tt] = check_receipt(f, base.(f), pert.(f), ...
        plantParams, paramLog, e);
    receipt(end+1) = struct('field', f, 'status', st, 'detail', det, ...
        'requested', pert.(f), 'observed', obs, 'time', tt); %#ok<AGROW>
end
for k = 1:numel(inputFields)
    f = inputFields{k};
    [st, det, obs, tt] = check_input_receipt(f, base.(f), pert.(f), distLog, e);
    receipt(end+1) = struct('field', f, 'status', st, 'detail', det, ...
        'requested', pert.(f), 'observed', obs, 'time', tt); %#ok<AGROW>
end
for k = 1:numel(stateFields)
    f = stateFields{k};
    [st, det, obs] = check_state_receipt(f, base.(f), pert.(f), x0, e);
    receipt(end+1) = struct('field', f, 'status', st, 'detail', det, ...
        'requested', pert.(f), 'observed', obs, 'time', 0); %#ok<AGROW>
end

receiptStatus = aggregate({receipt.status});
switch receiptStatus
    case 'UNDETERMINED'
        checks(end+1) = chk('param_entered_plant', 'UNDETERMINED', ...
            join_details(receipt));
        miss = {receipt(strcmp({receipt.status}, 'UNDETERMINED')).field};
        if ~isempty(miss) && all(ismember(miss, inputFields))
            reasons{end+1} = 'INPUT_EVIDENCE_MISSING';
        elseif ~isempty(miss) && all(ismember(miss, stateFields))
            reasons{end+1} = 'STATE_EVIDENCE_MISSING';
        else
            reasons{end+1} = 'PARAM_EVIDENCE_MISSING';
        end
    case 'FAIL'
        checks(end+1) = chk('param_entered_plant', 'FAIL', join_details(receipt));
        reasons{end+1} = 'PARAM_NOT_ENTERED_PLANT';
    otherwise
        checks(end+1) = chk('param_entered_plant', 'PASS', join_details(receipt));
end

% ---- 4. output, states, timing, prediction -------------------------------
[tRef, yB, yP, xB, xP] = align(B, P);
delta = window_delta(tRef, yB, yP, e.window);
outChanged = isfinite(delta) && abs(delta) > e.minRel;

if e.insensitive
    checks(end+1) = chk('output_changed', 'SKIP', ...
        sprintf('output is expected to be insensitive; measured delta %.3g', delta));
elseif outChanged
    checks(end+1) = chk('output_changed', 'PASS', ...
        sprintf('output changed by %.6g', delta));
else
    checks(end+1) = chk('output_changed', 'FAIL', ...
        sprintf('output did not change (delta %.3g <= minRel %.3g)', delta, e.minRel));
    reasons{end+1} = 'OUTPUT_UNCHANGED';
end

[stateStatus, stateDetail, affectedStates] = check_states(xB, xP, e);
if ~e.insensitive
    if strcmp(stateStatus, 'PASS')
        stateStatus = 'SKIP';
        stateDetail = ['recorded for evidence: ' stateDetail];
    else
        stateStatus = 'SKIP';
        stateDetail = 'not required: the output is expected to respond';
    end
end
checks(end+1) = chk('internal_state', stateStatus, stateDetail);
if strcmp(stateStatus, 'FAIL') || strcmp(stateStatus, 'UNDETERMINED')
    reasons{end+1} = 'INTERNAL_EVIDENCE';
end

[timeStatus, timeDetail, effectiveTime, timeSource] = check_timing( ...
    tRef, yB, yP, xB, xP, B, P, cfg.tInject, e, e.insensitive);
checks(end+1) = chk('effective_time', timeStatus, timeDetail);
if strcmp(timeStatus, 'FAIL')
    reasons{end+1} = 'TIMING';
end

% direction first: a wrong sign makes a numeric delta comparison redundant
if isempty(e.direction) || strcmpi(e.direction, 'any')
    dirStatus = 'SKIP'; dirDetail = 'no direction requested';
elseif ~outChanged
    dirStatus = 'SKIP'; dirDetail = 'no output change to judge';
elseif (strcmpi(e.direction, 'increase') && delta > 0) || ...
        (strcmpi(e.direction, 'decrease') && delta < 0)
    dirStatus = 'PASS'; dirDetail = sprintf('%s, delta %.6g', e.direction, delta);
else
    dirStatus = 'FAIL';
    dirDetail = sprintf('requested %s, measured delta %.6g', e.direction, delta);
    reasons{end+1} = 'DIRECTION_MISMATCH';
end
checks(end+1) = chk('direction', dirStatus, dirDetail);

if isempty(e.delta) || ~isnumeric(e.delta) || ~isscalar(e.delta) || ~isfinite(e.delta)
    predStatus = 'SKIP';
    predDetail = 'no independent prediction (expect.delta empty or non-finite)';
    notes{end+1} = 'NO_INDEPENDENT_PREDICTION';
elseif strcmp(dirStatus, 'FAIL')
    predStatus = 'SKIP';
    predDetail = 'not judged: the direction already failed';
elseif ~outChanged && ~e.insensitive
    predStatus = 'SKIP';
    predDetail = 'not judged: the output did not change';
else
    err = abs(delta - e.delta);
    if err <= e.tol
        predStatus = 'PASS';
        predDetail = sprintf('measured %.6g vs predicted %.6g (|err| %.3g <= %.3g)', ...
            delta, e.delta, err, e.tol);
    else
        predStatus = 'FAIL';
        predDetail = sprintf('measured %.6g vs predicted %.6g (|err| %.3g > %.3g)', ...
            delta, e.delta, err, e.tol);
        reasons{end+1} = 'PREDICTION_MISMATCH';
    end
end
checks(end+1) = chk('prediction', predStatus, predDetail);

% ---- 5. verdict -----------------------------------------------------------
statuses = {checks.status};
reasons = unique(reasons, 'stable');

if any(strcmp(statuses, 'FAIL'))
    verdict = 'FAIL';
elseif any(strcmp(statuses, 'UNDETERMINED'))
    verdict = 'UNDETERMINED';
else
    verdict = 'PASS';
end

hasPlant = any(strcmp(receiptStatus, {'PASS','FAIL'}));
hasTiming = any(strcmp(timeStatus, {'PASS','FAIL'}));
hasEffect = outChanged || strcmp(stateStatus, 'PASS') || ...
    (e.insensitive && strcmp(stateStatus, 'FAIL'));
hasPrediction = strcmp(predStatus, 'PASS') || strcmp(predStatus, 'FAIL');

if strcmp(verdict, 'UNDETERMINED')
    quality = 'NOT VERIFIED';
elseif strcmp(verdict, 'FAIL')
    quality = 'PARTIAL';
    if hasPlant && hasEffect
        quality = 'VERIFIED';
    end
else
    quality = 'PARTIAL';
    if hasPlant && hasTiming && hasEffect && hasPrediction
        quality = 'VERIFIED';
    end
end

record = struct();
record.changedFields = changed;
record.before = struct('params', base, 'plantParams', plantParams, ...
    'outputLevel', window_mean(yB, e.window), 'states', final_row(xB));
record.after = struct('params', pert, ...
    'plantParams', getfielddef(P, 'plantParams', []), ...
    'outputLevel', window_mean(yP, e.window), 'states', final_row(xP));
record.measuredDelta = delta;
record.independentPrediction = struct('delta', e.delta, 'tol', e.tol, ...
    'direction', e.direction, 'source', 'caller-supplied');
record.effectiveTime = effectiveTime;
record.effectiveTimeSource = timeSource;
record.affectedStates = affectedStates;
record.receipt = receipt;

notes{end+1} = ['evidence sources: plant=' ternary(hasPlant,'yes','no') ...
    ', timing=' ternary(hasTiming,'yes','no') ...
    ', effect=' ternary(hasEffect,'yes','no') ...
    ', prediction=' ternary(hasPrediction,'yes','no')];

r = finish(cfg, checks, reasons, quality, record, strjoin(notes, '; '));
r.environment = environment();
r.schemaVersion = '1.0';
end

% ===========================================================================
function e = defaults(x)
e = struct('direction', 'any', 'delta', [], 'tol', 0.02, 'insensitive', false, ...
    'minRel', 1e-8, 'timeTol', 0.02, 'maxResponseDelay', 0.2, 'window', 0.1);
if ~isstruct(x), return; end
f = fieldnames(x);
for k = 1:numel(f), e.(f{k}) = x.(f{k}); end
end

function c = changed_fields(a, b)
c = {};
if ~isstruct(a) || ~isstruct(b), return; end
fn = union(fieldnames(a), fieldnames(b));
for k = 1:numel(fn)
    f = fn{k};
    if ~isfield(a,f) || ~isfield(b,f) || ~isequaln(a.(f), b.(f))
        c{end+1} = f; %#ok<AGROW>
    end
end
end

function [st, det, obs, tt] = check_receipt(f, bv, pv, plantParams, paramLog, e)
st = 'UNDETERMINED'; det = ''; obs = []; tt = NaN;
if isstruct(plantParams) && isfield(plantParams, f)
    obs = plantParams.(f);
    if values_match(obs, pv, e.minRel)
        st = 'PASS';
        det = sprintf('%s reached the plant (%.6g -> %.6g)', f, bv, pv);
    else
        st = 'FAIL';
        det = sprintf('%s did NOT reach the plant: requested %.6g, plant used %.6g', ...
            f, pv, obs);
    end
    return;
end
if isstruct(paramLog) && isfield(paramLog, 't') && isfield(paramLog, f) && ...
        isnumeric(paramLog.(f)) && numel(paramLog.(f)) == numel(paramLog.t)
    v = paramLog.(f)(:);
    if ~isempty(v) && values_match(v(end), pv, e.minRel)
        st = 'PASS';
        idx = find(abs(v - bv) > e.minRel, 1);
        if ~isempty(idx), tt = paramLog.t(idx); end
        obs = v(end);
        det = sprintf('%s reached the plant at t=%.4g (log)', f, tt);
    else
        st = 'FAIL';
        obs = v(end);
        det = sprintf('%s log ends at %.6g, requested %.6g', f, obs, pv);
    end
    return;
end
if isstruct(plantParams) && ~isempty(fieldnames(plantParams))
    % The plant reported parameters, but not this one: the plant does not
    % consume it. That is a finding, not missing evidence.
    st = 'FAIL';
    det = sprintf('%s is absent from plantParams (plant fields: %s)', ...
        f, strjoin(fieldnames(plantParams).', ', '));
else
    det = sprintf('%s cannot be verified: the simulation returned no plantParams', f);
end
end

function [st, det, obs, tt] = check_input_receipt(f, bv, pv, distLog, e)
st = 'UNDETERMINED'; det = ''; obs = []; tt = NaN;
[v, tv] = log_vector(distLog);
if isempty(v)
    det = sprintf('%s cannot be verified: no disturbanceLog', f);
    return;
end
obs = v(end);
[idx, ~] = first_change(v, e.minRel);
if ~isempty(idx), tt = tv(idx); end
if values_match(obs, pv, e.minRel)
    st = 'PASS';
    det = sprintf('%s reached the plant input at t=%.4g (log ends at %.6g)', f, tt, obs);
else
    st = 'FAIL';
    det = sprintf('%s log ends at %.6g, requested %.6g', f, obs, pv);
end
end

function [st, det, obs] = check_state_receipt(f, bv, pv, x0, e)
st = 'UNDETERMINED'; det = ''; obs = [];
if isstruct(x0) && isfield(x0, f)
    obs = x0.(f);
    if values_match(obs, pv, e.minRel)
        st = 'PASS';
        det = sprintf('%s initial state %.6g -> %.6g', f, bv, pv);
    else
        st = 'FAIL';
        det = sprintf('%s initial state is %.6g, requested %.6g', f, obs, pv);
    end
else
    det = sprintf('%s cannot be verified: the simulation returned no initial-state evidence', f);
end
end

function tf = values_match(a, b, tol)
if isnumeric(a) && isnumeric(b)
    if ~isequal(size(a), size(b))
        tf = false; return;
    end
    d = abs(double(a(:)) - double(b(:)));
    tf = all(isfinite(d)) && all(d <= max(tol, tol*max(1, abs(double(b(:))))));
else
    tf = isequaln(a, b);
end
end

function [t, y1, y2, x1, x2] = align(B, P)
t = B.t(:);
y1 = as_matrix(B.y);
y2 = as_matrix(P.y);
if numel(P.t) ~= numel(B.t) || max(abs(P.t(:) - t)) > 1e-12 * max(1, max(abs(t)))
    y2 = interp1(P.t(:), y2, t, 'linear', 'extrap');
    if isfield(P, 'x') && ~isempty(P.x)
        P.x = interp1(P.t(:), as_matrix(P.x), t, 'linear', 'extrap');
    end
end
x1 = []; x2 = [];
if isfield(B, 'x') && ~isempty(B.x), x1 = as_matrix(B.x); end
if isfield(P, 'x') && ~isempty(P.x), x2 = as_matrix(P.x); end
if ~isempty(x1) && ~isempty(x2) && size(x1,1) ~= size(x2,1)
    error('mas_dist_enter:stateLength', 'state traces have different lengths');
end
end

function m = as_matrix(v)
if isa(v, 'timeseries'), v = v.Data; end
if isvector(v), m = v(:); else, m = double(v); end
end

function [status, detail, affected] = check_states(xB, xP, e)
affected = {};
if isempty(xB) || isempty(xP)
    status = 'UNDETERMINED';
    detail = 'no internal-state trace; an insensitive output cannot be certified';
    return;
end
n = min(size(xB,2), size(xP,2));
d = zeros(1,n);
for k = 1:n
    d(k) = abs(mean(xP(max(1,end-round(e.window*size(xP,1))+1):end,k)) - ...
        mean(xB(max(1,end-round(e.window*size(xB,1))+1):end,k)));
end
for k = 1:n
    if d(k) > e.minRel, affected{end+1} = sprintf('x%d', k); end %#ok<AGROW>
end
if isempty(affected)
    status = 'FAIL';
    detail = sprintf('no internal state changed (max |delta| %.3g)', max(d));
else
    status = 'PASS';
    detail = sprintf('internal state changed: %s', strjoin(affected, ', '));
end
end

function [status, detail, tEff, source] = check_timing(t, yB, yP, xB, xP, B, P, tInject, e, insensitive)
status = 'UNDETERMINED'; detail = 'no timing evidence'; tEff = NaN; source = 'none';
tol = e.timeTol;

[v, tv] = log_vector(getfielddef(P, 'disturbanceLog', []));
if isempty(v), [v, tv] = log_vector(getfielddef(P, 'paramLog', [])); end
if ~isempty(v)
    [idx, ~] = first_change(v, e.minRel);
    if ~isempty(idx)
        tEff = tv(idx);
        source = 'log';
    end
end

if isnan(tEff)
    % Fall back to the first divergence of the measured trajectory. This is a
    % RESPONSE time, so it is allowed to lag the injection by maxResponseDelay.
    if insensitive && ~isempty(xB) && ~isempty(xP)
        d = max(abs(xP - xB), [], 2);
    else
        ny = min(size(yB,1), size(yP,1));
        d = max(abs(yP(1:ny,:) - yB(1:ny,:)), [], 2);
    end
    idx = find(d > e.minRel, 1);
    if ~isempty(idx)
        tEff = t(idx);
        source = 'response';
    end
end

if isnan(tEff)
    detail = 'the change never appears in the log, output, or states';
    return;
end

lag = tEff - tInject;
limit = tol;
if strcmp(source, 'response'), limit = tol + e.maxResponseDelay; end
if lag < -tol
    status = 'FAIL';
    detail = sprintf('change is EARLY: t=%.4g, expected %.4g', tEff, tInject);
elseif lag > limit
    status = 'FAIL';
    detail = sprintf('change is LATE: t=%.4g, expected %.4g (lag %.4g > %.4g)', ...
        tEff, tInject, lag, limit);
else
    status = 'PASS';
    detail = sprintf('effective t=%.4g (%s), expected %.4g', tEff, source, tInject);
end
end

function [v, tv] = log_vector(log)
v = []; tv = [];
if ~isstruct(log) || ~isfield(log, 't'), return; end
tv = log.t(:);
if isfield(log, 'value') && isnumeric(log.value) && numel(log.value) == numel(tv)
    v = log.value(:);
    return;
end
fn = fieldnames(log);
for k = 1:numel(fn)
    if strcmp(fn{k}, 't'), continue; end
    if isnumeric(log.(fn{k})) && numel(log.(fn{k})) == numel(tv)
        v = log.(fn{k})(:);
        return;
    end
end
end

function [idx, level] = first_change(v, tol)
idx = [];
level = v(1);
base = v(1);
idx = find(abs(v - base) > tol, 1);
if ~isempty(idx), level = v(idx); end
end

function d = window_delta(t, yB, yP, frac) %#ok<INUSD>
if isempty(yB) || isempty(yP) || any(~isfinite(yB(:))) || any(~isfinite(yP(:)))
    d = NaN; return;
end
n = min(size(yB,1), size(yP,1));
w = max(1, round(frac*n));
a = mean(yB(n-w+1:n,:), 1);
b = mean(yP(n-w+1:n,:), 1);
d = b(1) - a(1);
end

function m = window_mean(y, frac)
if isempty(y), m = NaN; return; end
n = size(y,1); w = max(1, round(frac*n));
m = mean(y(n-w+1:n,:), 1);
end

function row = final_row(x)
if isempty(x), row = []; else, row = x(end,:); end
end

function s = aggregate(st)
s = 'PASS';
if any(strcmp(st, 'UNDETERMINED')), s = 'UNDETERMINED'; end
if any(strcmp(st, 'FAIL')), s = 'FAIL'; end
end

function s = join_details(receipt)
if isempty(receipt), s = 'no fields to check'; return; end
parts = cell(1, numel(receipt));
for k = 1:numel(receipt)
    parts{k} = sprintf('[%s] %s (%s)', receipt(k).field, receipt(k).status, receipt(k).detail);
end
s = strjoin(parts, '; ');
end

function c = chk(id, status, detail)
c = struct('id', id, 'status', status, 'detail', detail);
end

function v = getfielddef(s, f, d)
if isstruct(s) && isfield(s, f), v = s.(f); else, v = d; end
end

function n = normalise(s)
if ~isstruct(s) || ~isfield(s, 't') || ~isfield(s, 'y')
    error('mas_dist_enter:badSim', 'simFcn must return struct with t and y');
end
n = s;
n.t = double(s.t(:));
if isa(n.y, 'timeseries'), n.y = n.y.Data; end
n.y = double(n.y);
if numel(n.t) ~= size(n.y,1)
    error('mas_dist_enter:badSim', 't and y have different lengths');
end
if isfield(n, 'x') && isa(n.x, 'timeseries'), n.x = n.x.Data; end
end

function env = environment()
env = struct('matlab', version, 'release', version('-release'), ...
    'platform', computer, 'timestamp', datestr(now, 30));
end

function r = finish(cfg, checks, reasons, quality, record, summary)
r = struct();
r.schemaVersion = '1.0';
r.name = cfg.name;
r.verdict = '';
statuses = {checks.status};
if any(strcmp(statuses, 'FAIL'))
    r.verdict = 'FAIL';
elseif any(strcmp(statuses, 'UNDETERMINED'))
    r.verdict = 'UNDETERMINED';
else
    r.verdict = 'PASS';
end
r.reasons = reasons(:).';
r.checks = checks;
r.evidenceQuality = quality;
if isfield(record, 'changedFields'), r.changedFields = record.changedFields; end
if isfield(record, 'before'), r.before = record.before; end
if isfield(record, 'after'), r.after = record.after; end
if isfield(record, 'measuredDelta'), r.measuredDelta = record.measuredDelta; end
if isfield(record, 'independentPrediction'), r.independentPrediction = record.independentPrediction; end
if isfield(record, 'effectiveTime'), r.effectiveTime = record.effectiveTime; end
if isfield(record, 'effectiveTimeSource'), r.effectiveTimeSource = record.effectiveTimeSource; end
if isfield(record, 'affectedStates'), r.affectedStates = record.affectedStates; end
if isfield(record, 'receipt'), r.receipt = record.receipt; end
r.summary = sprintf('%s: verdict=%s evidence=%s | %s', cfg.name, r.verdict, quality, summary);
r.environment = environment();
end

function r = undet(code, detail)
r = struct();
r.schemaVersion = '1.0';
r.name = '';
r.verdict = 'UNDETERMINED';
r.reasons = {code};
r.checks = chk('config', 'FAIL', detail);
r.evidenceQuality = 'NOT VERIFIED';
r.summary = [code ': ' detail];
r.environment = environment();
end

function s = ternary(c, a, b)
if c, s = a; else, s = b; end
end
