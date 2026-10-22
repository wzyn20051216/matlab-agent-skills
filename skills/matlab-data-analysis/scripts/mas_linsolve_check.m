function r = mas_linsolve_check(A, x, b, claims)
%MAS_LINSOLVE_CHECK  Verify a linear-solve claim with the criterion that applies.
%
%   r = mas_linsolve_check(A, x, b, struct('tolRel', 1e-10))
%   r = mas_linsolve_check(A, x, b, struct('tolRel', 1e-10, 'xTrue', xt))
%
% claims fields:
%   .tolRel   claimed relative accuracy of x   (optional; without it the forward
%                                             accuracy is measured but not graded)
%   .xTrue    known exact solution              (optional; the only true reference)
%
% r.verdict  PASS | FAIL | UNDETERMINED
% r.checks   id / status (pass|fail|na|undetermined) / detail
% r.backwardError, r.cond, r.rank, r.errorBound, r.xQr
%
% WHY A SMALL RESIDUAL IS NOT AN ACCURATE ANSWER
% The backward error
%
%     eta = ||b - A*x|| / (||A||*||x|| + ||b||)
%
% says "x solves a slightly perturbed system". It says nothing about how close x
% is to the true solution of the system you actually posed. The forward error is
% bounded by cond(A)*eta (approximately), so a backward-stable solve of an
% ill-conditioned system has a tiny residual and may still be nowhere near the
% true answer. Reporting "residual 1e-16, looks fine" for hilb(12) is the classic
% way a numerical result is presented as correct when it is not.
%
% So the tool grades two different things separately:
%   residual          against 10*n*eps -- a mathematical property of the solve,
%                     no user criterion needed;
%   certifiable       kappa*eta against the claimed tolerance -- if the bound is
%                     above the claim, the answer is UNDETERMINED, not passed.
%
% A rank-deficient A has no unique solution at all: x is one of many, the forward
% error is undefined and every accuracy claim is unanswerable. That is reported
% as undetermined rather than as a failure of the arithmetic.
%
% The second route is a Householder QR solve (MATLAB's backslash uses LU with
% pivoting). Agreement between two factorisations is cross-algorithm evidence,
% not an exact reference; with a truly ill-conditioned A they may legitimately
% differ, and then the difference is reported instead of being turned into PASS.

if nargin < 4 || isempty(claims), claims = struct(); end
if ~isnumeric(A) || ~isnumeric(x) || ~isnumeric(b)
    error('mas_linsolve_check:type', 'A, x and b must be numeric');
end
[n, m] = size(A);
if n ~= m, error('mas_linsolve_check:square', 'A must be square (got %dx%d)', n, m); end
if size(b, 1) ~= n
    error('mas_linsolve_check:shape', ...
        'b must have %d rows (got %dx%d); a row vector is usually a transposition mistake', ...
        n, size(b, 1), size(b, 2));
end
if ~isequal(size(x), size(b))
    error('mas_linsolve_check:shape', ...
        'x is %dx%d but b is %dx%d: the claimed solution must match the right-hand side', ...
        size(x, 1), size(x, 2), size(b, 1), size(b, 2));
end

C = local_check_empty();
notes = {};

% ---- finite inputs --------------------------------------------------------
finiteOK = all(isfinite(A(:))) && all(isfinite(x(:))) && all(isfinite(b(:)));
C = local_check_add(C, 'finite', finiteOK, ternary(finiteOK, ...
    'A, x and b are all finite', 'non-finite entries present: no residual is meaningful'));

resid = b - A*x;
nRes = norm(resid, 2);
nA = norm(A, 2);
nX = norm(x, 2);
nB = norm(b, 2);
den = nA*nX + nB;
if den == 0
    if nRes == 0, eta = 0; else, eta = Inf; end
else
    eta = nRes/den;
end
etaBound = 10*n*eps;

% ---- conditioning and rank ----------------------------------------------
sv = svd(A);
if isempty(sv) || sv(1) == 0
    kappa = Inf; rnk = 0;
else
    tolRank = max(n, 1)*eps*sv(1);
    rnk = nnz(sv > tolRank);
    if sv(end) == 0 || ~isfinite(sv(end))
        kappa = Inf;
    else
        kappa = sv(1)/sv(end);
    end
end
fullRank = (rnk == n);

C = local_check_add(C, 'residual', finiteOK && eta <= etaBound, sprintf( ...
    'backward error %.3e (bound 10*n*eps = %.3e, residual norm %.3e)', ...
    eta, etaBound, nRes));
if ~finiteOK
    C(end) = local_set_undet(C(end), 'non-finite inputs: backward error undefined');
end

if fullRank
    C = local_check_add(C, 'rank', true, sprintf( ...
        'A is full rank (rank %d of %d, cond %.3e)', rnk, n, kappa));
else
    C = local_check_add(C, 'rank', NaN, sprintf( ...
        ['rank %d < %d: the solution is not unique, so x is one of infinitely many ' ...
         'and no forward-accuracy claim can be answered'], rnk, n));
    notes{end+1} = 'rank-deficient system: forward error is undefined, not small';
end

% ---- tolerance certification --------------------------------------------
if isfield(claims, 'tolRel') && isscalar(claims.tolRel) && claims.tolRel > 0
    tol = claims.tolRel;
    errBound = kappa*eta;
    fwdFloor = kappa*eps;
    if ~fullRank
        C = local_check_add(C, 'certifiable', NaN, ...
            'rank-deficient: the bound kappa*eta does not exist');
    elseif tol < fwdFloor
        C = local_check_add(C, 'certifiable', NaN, sprintf( ...
            ['claimed tolerance %.3e is below the attainable floor kappa*eps = %.3e ' ...
             'for this A: even the exact solution rounded to double cannot meet it'], ...
            tol, fwdFloor));
    elseif errBound <= tol
        C = local_check_add(C, 'certifiable', true, sprintf( ...
            'cond*eta = %.3e <= claimed %.3e: the claimed accuracy is certified', ...
            errBound, tol));
    else
        C = local_check_add(C, 'certifiable', NaN, sprintf( ...
            ['small residual (eta %.3e) does NOT certify %.3e accuracy: ' ...
             'cond(A)*eta = %.3e, and the forward error can be that large'], ...
            eta, tol, errBound));
    end
else
    tol = NaN;
    errBound = NaN;
    C = local_check_add(C, 'certifiable', 'na', ...
        'no tolRel stated: residual verified, forward accuracy neither claimed nor certified');
end

% ---- true-solution comparison (optional) --------------------------------
if isfield(claims, 'xTrue') && isequal(size(claims.xTrue), size(x))
    fwdErr = norm(x - claims.xTrue, 2)/(norm(claims.xTrue, 2) + realmin);
    if isfinite(tol)
        C = local_check_add(C, 'xVsTrue', fwdErr <= tol, sprintf( ...
            'relative error vs xTrue %.3e (tol %.3e)', fwdErr, tol));
    else
        C = local_check_add(C, 'xVsTrue', NaN, sprintf( ...
            'relative error vs xTrue is %.3e, but no tolRel was stated', fwdErr));
    end
elseif isfield(claims, 'xTrue')
    C = local_check_add(C, 'xVsTrue', NaN, ...
        'xTrue has the wrong shape: cannot compare');
else
    C = local_check_add(C, 'xVsTrue', 'na', 'no xTrue supplied');
end

% ---- cross-algorithm route ----------------------------------------------
xQr = NaN(size(b));
if fullRank
    [Q, Rr] = qr(A);
    xQr = Rr\(Q'*b);
    dRoute = norm(xQr - x, 2)/(norm(x, 2) + realmin);
    routeTol = max(1e-9, 1000*eps*kappa);
    if dRoute <= routeTol
        C = local_check_add(C, 'crossRoute', true, sprintf( ...
            'LU and QR routes agree to %.3e (threshold %.3e)', dRoute, routeTol));
    else
        C = local_check_add(C, 'crossRoute', NaN, sprintf( ...
            ['LU and QR routes differ by %.3e, above the conditioning-adjusted ' ...
             'threshold %.3e: the answer is not reproducible across algorithms'], ...
            dRoute, routeTol));
    end
else
    dRoute = NaN;
    C = local_check_add(C, 'crossRoute', 'na', 'rank-deficient: no unique route to compare');
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
r.checks = C;
r.notes = notes;
r.x = x;
r.residual = resid;
r.backwardError = eta;
r.errorBound = errBound;
r.cond = kappa;
r.rank = rnk;
r.xQr = xQr;
r.routeDiff = dRoute;
r.nChecks = numel(C);
r.nPass = nnz(strcmp(st, 'pass'));
r.nFail = nnz(strcmp(st, 'fail'));
r.nUndetermined = nnz(strcmp(st, 'undetermined'));
r.nNa = nnz(strcmp(st, 'na'));
r.detail = sprintf('%s: %d pass, %d fail, %d undetermined, %d na', ...
    r.verdict, r.nPass, r.nFail, r.nUndetermined, r.nNa);
if any(strcmp(st, 'fail') | strcmp(st, 'undetermined'))
    bad = strcmp(st, 'fail') | strcmp(st, 'undetermined');
    r.detail = sprintf('%s (%s)', r.detail, strjoin({C(bad).id}, ', '));
end
end

% ===========================================================================
function c = local_set_undet(c, detail)
c.status = 'undetermined';
c.detail = detail;
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

function v = ternary(c, a, b)
if c, v = a; else, v = b; end
end
