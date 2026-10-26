function r = mas_quad_check(f, a, b, claims)
%MAS_QUAD_CHECK  Verify a numerical integration or differentiation claim.
%
%   r = mas_quad_check(@(x) 4./(1+x.^2), 0, 1, struct('value', pi, 'tolRel', 1e-6))
%
% claims fields:
%   .value        claimed integral of f on [a,b]                (required)
%   .tolRel       relative tolerance for that claim             (required to grade)
%   .method       'trapz' | 'simpson' -- how the claim was made (optional)
%   .n            number of intervals used by that method       (default 64)
%   .derivAt      point x0 where a derivative claim is made     (optional)
%   .derivValue   claimed f'(x0)                                (optional)
%   .derivTolRel  relative tolerance for the derivative claim   (default 1e-4)
%
% r.verdict  PASS | FAIL | UNDETERMINED
% r.checks   id / status (pass|fail|na|undetermined) / detail
% r.ref      quadgk value, Richardson-extrapolated trapezoid value, and their gap
% r.orders   observed order of the claimed method and of central differences
%
% WHAT IS VERIFIED, AND AGAINST WHAT
% The reference is established by TWO schemes that share no code: adaptive
% Gauss-Kronrod (quadgk) and a Richardson-extrapolated composite trapezoid
% sequence. If they disagree, the reference is `undetermined` -- a kinked or
% oscillatory integrand makes both estimates doubtful and the tool says so
% instead of grading the claim against one shaky number.
%
% The order of accuracy is MEASURED, not assumed: for a method of order p the
% error obeys e(n) ~ C h^p, so halving h multiplies the error by 2^-p and
% p = log2(e(n)/e(2n)). The check is ONE-SIDED: a measured order at or above the
% nominal order is acceptable, a measured order clearly below it is not. The
% asymmetry is deliberate. On a particular smooth integrand the leading error
% term can cancel (Simpson on 4/(1+x^2) measures order ~6 on some grids); that is
% luck, not fraud. But an order below nominal means the error is not behaving
% like the claimed method at all -- a kink, a singularity, or a different method.
% When the error sequence has hit the double-precision floor the order cannot be
% measured and is reported `undetermined`.
%
% The tolerance is checked for ACHIEVABILITY: if the claim states a tolerance
% finer than the method's measured error at the stated n (and above the
% roundoff floor), the number cannot have come from that method at that grid --
% `undetermined`, because the provenance is missing, not because the value is
% necessarily wrong.
%
% Derivative claims are checked the same way: complex-step when f is analytic
% (near machine precision), otherwise a Richardson-extrapolated central
% difference, with the measured order ~2 and the eps^(1/3) roundoff floor
% made explicit.

if nargin < 4, error('mas_quad_check:args', 'need f, a, b and claims'); end
if ~isa(f, 'function_handle'), error('mas_quad_check:f', 'f must be a function handle'); end
if ~isscalar(a) || ~isscalar(b) || ~isfinite(a) || ~isfinite(b) || a >= b
    error('mas_quad_check:bounds', 'need finite a < b');
end
if ~isstruct(claims) || ~isfield(claims, 'value') || ~isscalar(claims.value)
    error('mas_quad_check:claims', 'claims.value (scalar integral) is required');
end

C = local_check_empty();
notes = {};

% ---- reference: two independent quadrature schemes -----------------------
Iref = quadgk(f, a, b);
n0 = local_field(claims, 'n', 64);
n0 = max(2, round(n0));
T1 = local_trapz(f, a, b, n0);
T2 = local_trapz(f, a, b, 2*n0);
T4 = local_trapz(f, a, b, 4*n0);
R2 = (4*T2 - T1)/3;                    % order-4 extrapolation of the h-series
R4 = (4*T4 - T2)/3;
refScale = max(1, abs(Iref));
floorI = 100*eps*refScale;
refGap = abs(Iref - R4);
refTol = max(1e-9, 1e-6*refScale);
refOK = refGap <= refTol;
if refOK
    C = local_check_add(C, 'refAgreement', true, sprintf( ...
        'quadgk %.10g vs Richardson-extrapolated trapezoid %.10g (gap %.2e)', ...
        Iref, R4, refGap));
else
    C = local_check_add(C, 'refAgreement', NaN, sprintf( ...
        ['quadgk %.10g and Richardson trapezoid %.10g disagree by %.2e: the ' ...
         'integrand is not smooth enough for either estimate to be a reference'], ...
        Iref, R4, refGap));
    notes{end+1} = 'reference not established: a kink or oscillation defeats both schemes';
end
r.ref = struct('quadgk', Iref, 'trapzRichardson', R4, 'gap', refGap, 'floor', floorI);

% ---- the claim vs the reference -----------------------------------------
dClaim = abs(claims.value - Iref);
if isfield(claims, 'tolRel') && isscalar(claims.tolRel)
    tolAbs = claims.tolRel * refScale;
    refQuality = max(refGap, 10*eps*refScale);
    if ~refOK
        C = local_check_add(C, 'valueVsRef', NaN, sprintf( ...
            ['claimed %.10g differs from quadgk by %.3e, but the two reference ' ...
             'schemes do not agree: the claim cannot be graded'], claims.value, dClaim));
    elseif tolAbs < refQuality
        % A tolerance finer than the agreement between the two reference schemes
        % cannot be certified by those schemes, even when the claim happens to be
        % right. This is the kink case: quadgk stops at ~1e-8 and the claim asks
        % for 1e-9, so "fail" would blame the claim for the reference's limit.
        C = local_check_add(C, 'valueVsRef', NaN, sprintf( ...
            ['claimed %.10g vs reference %.10g (dev %.3e), but the claimed tolerance ' ...
             '%.3e is finer than the reference agreement %.3e: not certifiable'], ...
            claims.value, Iref, dClaim, tolAbs, refQuality));
    else
        C = local_check_add(C, 'valueVsRef', dClaim <= tolAbs, sprintf( ...
            'claimed %.10g vs reference %.10g: dev %.3e (tol %.3e)', ...
            claims.value, Iref, dClaim, tolAbs));
    end
    if tolAbs < floorI
        C = local_check_add(C, 'toleranceAchievable', NaN, sprintf( ...
            ['claimed tolerance %.3e is below the double-precision floor %.3e ' ...
             'for this integral: no quadrature can certify it'], tolAbs, floorI));
    else
        C = local_check_add(C, 'toleranceAchievable', true, sprintf( ...
            'claimed tolerance %.3e is above the roundoff floor %.3e', tolAbs, floorI));
    end
else
    C = local_check_add(C, 'valueVsRef', NaN, sprintf( ...
        ['claimed %.10g differs from the reference by %.3e, but no tolRel was stated: ' ...
         'no acceptance criterion, no PASS'], claims.value, dClaim));
    tolAbs = NaN;
end

% ---- order of the claimed method (measured, not assumed) ----------------
r.orders = struct('method', NaN, 'methodName', '', 'derivative', NaN);
if isfield(claims, 'method') && ischar(claims.method)
    m = lower(claims.method);
    switch m
        case 'trapz'
            fh = @(nn) local_trapz(f, a, b, nn); expP = 2;
        case 'simpson'
            fh = @(nn) local_simpson(f, a, b, nn); expP = 4;
        otherwise
            error('mas_quad_check:method', 'method must be trapz or simpson');
    end
    v1 = fh(n0); v2 = fh(2*n0);
    e1 = abs(v1 - Iref); e2 = abs(v2 - Iref);
    r.orders.methodName = m;
    if e2 <= floorI || e1 <= floorI
        C = local_check_add(C, 'methodOrder', NaN, sprintf( ...
            ['error at n=%d is %.2e, already at the roundoff floor %.2e: ' ...
             'the order cannot be measured on this grid'], 2*n0, e2, floorI));
    else
        p = log2(e1/e2);
        r.orders.method = p;
        C = local_check_add(C, 'methodOrder', p >= expP - 0.25, sprintf( ...
            'measured order %.2f for %s (nominal %.0f; only a LOWER order is treated as a defect)', ...
            p, m, expP));
    end
    if isfinite(tolAbs)
        eAtN = abs(v1 - Iref);
        if isfinite(tolAbs) && tolAbs < eAtN/2 && eAtN > floorI
            C = local_check_add(C, 'methodSupportsTol', NaN, sprintf( ...
                ['the %s error at n=%d is %.2e, larger than the claimed tolerance ' ...
                 '%.2e: the value cannot have come from this method at this grid'], ...
                m, n0, eAtN, tolAbs));
        else
            C = local_check_add(C, 'methodSupportsTol', true, sprintf( ...
                '%s error at n=%d is %.2e, consistent with the claimed tolerance %.2e', ...
                m, n0, eAtN, tolAbs));
        end
    end
end

% ---- derivative claim (optional) ----------------------------------------
if isfield(claims, 'derivAt') && isscalar(claims.derivAt)
    x0 = claims.derivAt;
    hc = max(abs(x0), 1)*1e-20;
    dCS = NaN; csValid = false;
    try
        yCS = f(x0 + 1i*hc);
        dCS = imag(yCS)/hc;
        csValid = isfinite(dCS);
    catch
        csValid = false;
    end
    h0 = max(abs(x0), 1)*1e-4;
    D = zeros(1, 3);
    for k = 1:3
        h = h0/2^(k-1);
        D(k) = (f(x0 + h) - f(x0 - h))/(2*h);
    end
    dR = (4*D(3) - D(2))/3;            % Richardson on central differences
    if csValid && abs(dCS - dR) <= 1e-5*max(1, abs(dR))
        dRef = dCS; refName = 'complex step';
        C = local_check_add(C, 'derivRef', true, sprintf( ...
            'complex step %.10g and Richardson central %.10g agree (gap %.2e)', ...
            dCS, dR, abs(dCS - dR)));
    elseif csValid
        dRef = dR; refName = 'Richardson central';
        C = local_check_add(C, 'derivRef', true, sprintf( ...
            ['complex step %.10g disagrees with Richardson central %.10g: f is ' ...
             'not analytic at x0 (abs/max?), so the central difference is the reference'], ...
            dCS, dR));
    else
        dRef = dR; refName = 'Richardson central';
        C = local_check_add(C, 'derivRef', true, sprintf( ...
            'complex step unavailable; Richardson central %.10g is the reference', dR));
    end
    eD2 = abs(D(2) - D(1)); eD3 = abs(D(3) - D(2));
    floorD = 100*eps*max(1, abs(f(x0)))/h0;
    if eD3 > floorD && eD2 > 0
        pD = log2(eD2/eD3);
        r.orders.derivative = pD;
        C = local_check_add(C, 'derivOrder', abs(pD - 2) <= 0.35, sprintf( ...
            'measured central-difference order %.2f (expected 2, tolerance 0.35)', pD));
    else
        C = local_check_add(C, 'derivOrder', NaN, sprintf( ...
            'difference-of-differences %.2e is at the eps^(1/3) floor %.2e: order not measurable', ...
            eD3, floorD));
    end
    if isfield(claims, 'derivValue') && isscalar(claims.derivValue)
        tolD = 1e-4;
        if isfield(claims, 'derivTolRel') && isscalar(claims.derivTolRel)
            tolD = claims.derivTolRel;
        end
        dRefScale = max(1, abs(dRef));
        C = local_check_add(C, 'derivVsRef', ...
            abs(claims.derivValue - dRef) <= tolD*dRefScale, sprintf( ...
            'claimed f''(%.6g) = %.10g vs %s reference %.10g (dev %.3e, tol %.3e)', ...
            x0, claims.derivValue, refName, dRef, ...
            abs(claims.derivValue - dRef), tolD*dRefScale));
    else
        C = local_check_add(C, 'derivVsRef', NaN, ...
            'derivAt given without derivValue: nothing to grade');
    end
end

% ---- verdict -------------------------------------------------------------
st = {C.status};
if any(strcmp(st, 'fail'))
    r.verdict = 'FAIL';
elseif any(strcmp(st, 'undetermined'))
    r.verdict = 'UNDETERMINED';
else
    r.verdict = 'PASS';
end
r.ok = strcmp(r.verdict, 'PASS');
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
function T = local_trapz(f, a, b, n)
x = linspace(a, b, n+1);
y = local_eval(f, x);
T = (b-a)/n * (sum(y) - 0.5*(y(1) + y(end)));
end

function S = local_simpson(f, a, b, n)
if mod(n, 2) ~= 0, n = n + 1; end
x = linspace(a, b, n+1);
y = local_eval(f, x);
h = (b-a)/n;
S = h/3 * (y(1) + 4*sum(y(2:2:end-1)) + 2*sum(y(3:2:end-2)) + y(end));
end

function y = local_eval(f, x)
% arrayfun keeps scalar-only integrands working; a vectorised f still works
% because arrayfun calls it element by element.
y = arrayfun(f, x);
end

function v = local_field(s, f, dflt)
v = dflt;
if isfield(s, f) && isscalar(s.(f)), v = s.(f); end
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
