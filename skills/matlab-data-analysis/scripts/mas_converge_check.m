function r = mas_converge_check(hist, claims)
%MAS_CONVERGE_CHECK  Grade an iteration's convergence claim against its own history.
%
%   r = mas_converge_check(err, struct('tolFinal', 1e-10))
%   r = mas_converge_check(err, struct('order', 2, 'tolFinal', 1e-12))
%
% hist   per-iteration error (or residual) norms, one value per iteration
% claims .tolFinal  final error must be at or below this       (optional)
%        .order     claimed asymptotic order p                (optional)
%        .rate      claimed linear contraction factor q <= 1  (optional)
%   At least one claim is required; with none there is nothing to grade.
%
% r.verdict  PASS | FAIL | UNDETERMINED
% r.checks   id / status (pass|fail|na|undetermined) / detail
% r.observed order, spread, rate, final error, tail values used
%
% WHAT "CONVERGES QUADRATICALLY" ACTUALLY CLAIMS
% An order-p method obeys e(k+1) ~ C*e(k)^p, so
%
%     p ~= log(e(k+1)/e(k)) / log(e(k)/e(k-1))
%
% The order is MEASURED from the tail of the history, not trusted from the label.
% If the tail is not in the asymptotic regime (the estimates scatter), the order
% is reported undetermined rather than averaged into a plausible-looking number.
%
% Three failure modes are separated because they call for different repairs:
%   - divergence: the error grows (FAIL);
%   - stagnation: the error stops falling above the target (FAIL on tolFinal);
%   - roundoff floor: the error stops falling because it has hit ~eps and further
%     iterations cannot improve it. Then the ORDER is not measurable
%     (undetermined), while a tolFinal at or above the floor is still gradable.
%
% A history that is non-finite (Inf/NaN) is itself the diagnosis: divergence.
% It is graded as FAIL rather than thrown, because a diverged run is a result.

if nargin < 2, claims = struct(); end
if ~isnumeric(hist) || ~isvector(hist)
    error('mas_converge_check:hist', 'hist must be a numeric vector of per-iteration norms');
end
if numel(hist) < 3
    error('mas_converge_check:hist', 'need at least 3 iterations to talk about order (got %d)', numel(hist));
end
if any(hist < 0)
    error('mas_converge_check:hist', 'error norms cannot be negative');
end
hasTol = isfield(claims, 'tolFinal') && isscalar(claims.tolFinal);
hasOrder = isfield(claims, 'order') && isscalar(claims.order);
hasRate = isfield(claims, 'rate') && isscalar(claims.rate);
if ~hasTol && ~hasOrder && ~hasRate
    error('mas_converge_check:claims', ...
        'state at least one of tolFinal, order, rate -- otherwise there is no claim to grade');
end
if hasRate && claims.rate <= 0
    error('mas_converge_check:claims', 'rate must be positive');
end

C = local_check_empty();
notes = {};
e = hist(:);
nIter = numel(e);

finiteOK = all(isfinite(e));
if finiteOK
    C = local_check_add(C, 'finite', true, sprintf('all %d iterates finite', nIter));
    eEff = e;
else
    bad = find(~isfinite(e), 1);
    C = local_check_add(C, 'finite', false, sprintf( ...
        'non-finite error at iteration %d: the iteration diverged', bad));
    eEff = e(isfinite(e));
    notes{end+1} = 'non-finite iterate: divergence';
end

if numel(eEff) < 3
    % not enough usable history for anything else
    obs = struct('order', NaN, 'orderSpread', NaN, 'rate', NaN, 'rateSpread', NaN, ...
        'final', eEff(end), 'initial', eEff(1), 'nIter', nIter, 'tailOrder', [], 'tailRate', []);
    r = local_finish(C, notes, obs, NaN);
    return;
end
if eEff(1) == 0
    notes{end+1} = 'initial error is zero: there is nothing to converge';
end

C = local_check_add(C, 'towardZero', eEff(end) < eEff(1), sprintf( ...
    'error %.3e -> %.3e over %d usable iterates (ratio %.3e)', ...
    eEff(1), eEff(end), numel(eEff), eEff(end)/max(eEff(1), realmin)));

floorE = 100*eps*max(1, eEff(1));

% ---- asymptotic order from the tail --------------------------------------
pAll = [];
for k = 2:numel(eEff)-1
    a = eEff(k-1); b = eEff(k); c = eEff(k+1);
    if a > floorE && b > floorE && c > floorE && abs(b - a) > 0 && abs(c - b) > 0
        pAll(end+1) = log(c/b)/log(b/a); %#ok<AGROW>
    end
end
pTail = local_tail(pAll);
obs = struct('order', NaN, 'orderSpread', NaN, 'rate', NaN, 'rateSpread', NaN, ...
    'final', eEff(end), 'initial', eEff(1), 'nIter', nIter, ...
    'tailOrder', pTail, 'tailRate', []);
if ~isempty(pTail)
    obs.order = median(pTail);
    obs.orderSpread = median(abs(pTail - obs.order));
end

% ---- contraction rate from the tail --------------------------------------
rAll = [];
for k = 1:numel(eEff)-1
    if eEff(k) > floorE && eEff(k+1) > floorE
        rAll(end+1) = eEff(k+1)/eEff(k); %#ok<AGROW>
    end
end
rTail = local_tail(rAll);
obs.tailRate = rTail;
if ~isempty(rTail)
    obs.rate = median(rTail);
    obs.rateSpread = median(abs(rTail - obs.rate));
end

if eEff(end) <= floorE
    notes{end+1} = sprintf(['final error %.3e is at the roundoff floor %.3e: further ' ...
        'iterations cannot improve it and the order is not measurable there'], ...
        eEff(end), floorE);
end

% ---- tolFinal ------------------------------------------------------------
if hasTol
    C = local_check_add(C, 'finalTol', eEff(end) <= claims.tolFinal, sprintf( ...
        'final error %.3e vs required %.3e', eEff(end), claims.tolFinal));
    if ~(eEff(end) <= claims.tolFinal) && numel(rTail) >= 2
        notes{end+1} = sprintf('last contraction ratios: %.2f, %.2f', ...
            rTail(max(1, end-1)), rTail(end));
    end
else
    C = local_check_add(C, 'finalTol', 'na', 'no tolFinal claimed');
end

% ---- order claim ---------------------------------------------------------
if hasOrder
    if numel(pTail) < 3
        C = local_check_add(C, 'orderClaim', NaN, sprintf( ...
            ['only %d usable order estimates above the floor %.3e: at least 3 are ' ...
             'required before an order can be claimed'], numel(pTail), floorE));
    elseif obs.orderSpread > 0.5
        C = local_check_add(C, 'orderClaim', NaN, sprintf( ...
            'order estimates scatter (median %.2f, MAD %.2f): the tail is not asymptotic', ...
            obs.order, obs.orderSpread));
    else
        pTol = max(0.30, 0.15*abs(claims.order));
        C = local_check_add(C, 'orderClaim', abs(obs.order - claims.order) <= pTol, sprintf( ...
            'measured order %.2f (MAD %.2f) vs claimed %.2f (tolerance %.2f)', ...
            obs.order, obs.orderSpread, claims.order, pTol));
    end
else
    C = local_check_add(C, 'orderClaim', 'na', 'no order claimed');
end

% ---- rate claim ----------------------------------------------------------
if hasRate
    if isempty(rTail) || numel(rTail) < 2
        C = local_check_add(C, 'rateClaim', NaN, ...
            'not enough above-floor ratios to measure a contraction rate');
    else
        C = local_check_add(C, 'rateClaim', obs.rate <= claims.rate*1.1, sprintf( ...
            'measured contraction %.3f (MAD %.3f) vs claimed at most %.3f', ...
            obs.rate, obs.rateSpread, claims.rate));
    end
else
    C = local_check_add(C, 'rateClaim', 'na', 'no rate claimed');
end

r = local_finish(C, notes, obs, floorE);
end

% ===========================================================================
function t = local_tail(v)
% last three estimates: enough to see scatter, short enough to be asymptotic
if isempty(v)
    t = v;
    return;
end
n = min(3, numel(v));
t = v(max(1, end-n+1):end);
end

function r = local_finish(C, notes, obs, floorE)
st = {C.status};
if any(strcmp(st, 'fail'))
    r.verdict = 'FAIL';
elseif any(strcmp(st, 'undetermined'))
    r.verdict = 'UNDETERMINED';
else
    r.verdict = 'PASS';
end
r.checks = C;
r.notes = notes;
r.observed = obs;
r.floor = floorE;
r.nChecks = numel(C);
r.nPass = nnz(strcmp(st, 'pass'));
r.nFail = nnz(strcmp(st, 'fail'));
r.nUndetermined = nnz(strcmp(st, 'undetermined'));
r.nNa = nnz(strcmp(st, 'na'));
r.detail = sprintf('%s: %d pass, %d fail, %d undetermined, %d na', ...
    r.verdict, r.nPass, r.nFail, r.nUndetermined, r.nNa);
bad = strcmp(st, 'fail') | strcmp(st, 'undetermined');
if any(bad)
    r.detail = sprintf('%s (%s)', r.detail, strjoin({C(bad).id}, ', '));
end
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
