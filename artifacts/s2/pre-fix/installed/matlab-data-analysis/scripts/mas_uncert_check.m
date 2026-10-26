function r = mas_uncert_check(f, x0, sigma, claims)
%MAS_UNCERT_CHECK  Check an uncertainty claim against direct sampling.
%
%   r = mas_uncert_check(@(x) x(1).*x(2), [2; 3], [0.02; 0.03], ...
%                        struct('sigma', 0.078, 'sigmaTolRel', 0.02))
%
% f       scalar function of a k-vector
% x0      k-vector of nominal values
% sigma   k-vector of independent 1-sigma input uncertainties
% claims  .value        claimed f(x0)                (optional)
%         .sigma        claimed output uncertainty   (optional)
%         .sigmaTolRel  relative tolerance for it    (default 0.05)
%         .usedMethod   'montecarlo' (default) | 'linearized' -- what produced
%                       the claim, reported for diagnosis, not trusted
%         .nMC          Monte Carlo draws            (default 10000)
%         .seed         RNG seed                     (default 20261021)
%
% r.verdict  PASS | FAIL | UNDETERMINED
% r.sigmaLin, r.sigmaMC, r.mcSE, r.mcCI, r.mcBias, r.J, r.sensitivity
%
% WHY THE FIRST-ORDER FORMULA IS NOT THE ANSWER
% The textbook propagation sigma_y = sqrt(sum((df/dxi * sigma_i)^2)) is a
% first-order Taylor approximation. It is exact for a linear f and can be wrong
% by tens of percent for a curved one -- and nothing in the formula announces
% when it has stopped applying. This tool therefore computes BOTH routes:
%
%   linearized: a Jacobian (complex step when f is analytic, verified against
%               central differences; central differences otherwise);
%   Monte Carlo: sampled f(x0 + sigma.*randn), whose own sampling error is
%               reported as mcSE and gated against the tolerance being asked of
%               the claim. A Monte Carlo reference that is noisier than the
%               tolerance cannot certify anything: that is UNDETERMINED, not
%               PASS, and the fix is more draws.
%
% The claim is graded against the Monte Carlo value, because that is the honest
% estimate of the output distribution; the linearized value is reported beside
% it and the gap is surfaced as the nonlinearity diagnosis. Correlated inputs are
% NOT supported -- with a covariance matrix the linearized route is J*C*J' and the
% sampling route must draw correlated normals; pretending independence here would
% understate the output uncertainty, so the limitation is stated in r.notes.
%
% The RNG state is saved and restored, so checking an uncertainty does not move
% the caller's random stream.

if nargin < 4 || isempty(claims), claims = struct(); end
if ~isa(f, 'function_handle'), error('mas_uncert_check:f', 'f must be a function handle'); end
if ~isnumeric(x0) || ~isvector(x0) || ~isnumeric(sigma) || ~isvector(sigma)
    error('mas_uncert_check:args', 'x0 and sigma must be numeric vectors');
end
x0 = x0(:); sigma = sigma(:);
if numel(x0) ~= numel(sigma)
    error('mas_uncert_check:args', 'x0 and sigma must have the same length (got %d and %d)', ...
        numel(x0), numel(sigma));
end
if any(~isfinite(x0)) || any(~isfinite(sigma))
    error('mas_uncert_check:args', 'x0 and sigma must be finite');
end
if any(sigma < 0)
    error('mas_uncert_check:args', 'sigma entries must be non-negative');
end

tolS = local_field(claims, 'sigmaTolRel', 0.05);
N = round(local_field(claims, 'nMC', 10000));
seed = local_field(claims, 'seed', 20261021);
usedMethod = 'montecarlo';
if isfield(claims, 'usedMethod') && ischar(claims.usedMethod)
    usedMethod = lower(claims.usedMethod);
end
if ~any(strcmp(usedMethod, {'montecarlo', 'linearized'}))
    error('mas_uncert_check:claims', 'usedMethod must be montecarlo or linearized');
end
if N < 100
    error('mas_uncert_check:claims', 'nMC must be at least 100');
end

C = local_check_empty();
notes = {'independent inputs assumed; correlated inputs require the covariance form and are not supported'};

y0 = f(x0);
if ~isnumeric(y0) || ~isscalar(y0) || ~isreal(y0) || ~isfinite(y0)
    error('mas_uncert_check:f', 'f must return a finite real scalar');
end
C = local_check_add(C, 'dims', true, sprintf('%d inputs, %d draws, f(x0) = %.10g', ...
    numel(x0), N, y0));

% ---- Jacobian: complex step, verified against central differences ---------
k = numel(x0);
Jc = zeros(k, 1); Jd = zeros(k, 1);
csOK = true;
for i = 1:k
    h = max(abs(x0(i)), 1)*1e-20;
    xc = x0; xc(i) = xc(i) + 1i*h;
    try
        Jc(i) = imag(f(xc))/h;
        if ~isfinite(Jc(i)), csOK = false; end
    catch
        csOK = false;
        Jc(i) = NaN;
    end
end
for i = 1:k
    h = max(abs(x0(i)), 1)*1e-5;
    xp = x0; xm = x0;
    xp(i) = xp(i) + h;
    xm(i) = xm(i) - h;
    Jd(i) = (f(xp) - f(xm))/(2*h);
end
jacGap = NaN;
if csOK && all(isfinite(Jc))
    jacGap = max(abs(Jc - Jd))/max(1, max(abs(Jd)));
end
if csOK && jacGap <= 1e-4
    J = Jc; jacHow = 'complex step';
else
    J = Jd; jacHow = 'central differences';
    if csOK
        notes{end+1} = sprintf(['complex step and central differences disagree by %.2e: ' ...
            'f is not analytic here, central differences used'], jacGap);
    else
        notes{end+1} = 'complex step unavailable: central differences used';
    end
end
sigmaLin = sqrt(sum((J.*sigma).^2));

% ---- Monte Carlo with a seeded, restored stream --------------------------
st = rng;
rng(seed);
Y = zeros(N, 1);
for i = 1:N
    yi = f(x0 + sigma.*randn(k, 1));
    if ~isnumeric(yi) || ~isscalar(yi) || ~isreal(yi)
        rng(st);
        error('mas_uncert_check:f', 'f must return a finite real scalar (draw %d)', i);
    end
    Y(i) = yi;
end
rng(st);
mY = mean(Y);
sigmaMC = std(Y);
seS = sigmaMC/sqrt(2*(N - 1));
ciMC = sigmaMC + [-1 1]*1.96*seS;
bias = mY - y0;

floorS = 100*eps*max(1, abs(y0));
if sigmaMC <= floorS
    C = local_check_add(C, 'mcPrecision', true, ...
        'sampled output is constant at the roundoff floor');
else
    precRatio = 3*seS/sigmaMC;
    if precRatio <= tolS
        C = local_check_add(C, 'mcPrecision', true, sprintf( ...
            'Monte Carlo standard error is %.2f%% of sigma (3*SE = %.1f%% of sigma, tolerance %.1f%%)', ...
            100*seS/sigmaMC, 100*precRatio, 100*tolS));
    else
        % Not the claimant's fault: the reference is too noisy to decide at this
        % tolerance. That is undetermined, not a failure of the claim.
        C = local_check_add(C, 'mcPrecision', NaN, sprintf( ...
            ['Monte Carlo standard error is %.2f%% of sigma (3*SE = %.1f%% of sigma, ' ...
             'tolerance %.1f%%): increase nMC -- this reference cannot certify that tolerance'], ...
            100*seS/sigmaMC, 100*precRatio, 100*tolS));
        notes{end+1} = 'Monte Carlo reference is noisier than the tolerance: more draws required';
    end
end

% ---- the claim ------------------------------------------------------------
if isfield(claims, 'value') && isscalar(claims.value)
    relV = abs(y0 - claims.value)/max(1, abs(y0));
    C = local_check_add(C, 'valueVsClaim', relV <= 1e-9, sprintf( ...
        'f(x0) = %.10g vs reported %.10g (dev %.2e)', y0, claims.value, relV));
else
    C = local_check_add(C, 'valueVsClaim', 'na', 'no output value reported');
end

if isfield(claims, 'sigma') && isscalar(claims.sigma)
    if sigmaMC <= floorS
        den = max(1, abs(y0));
        C = local_check_add(C, 'claimedVsRef', ...
            abs(claims.sigma) <= 100*eps*den, sprintf( ...
            'sampled sigma is zero (floor %.2e); reported sigma %.3e', floorS, claims.sigma));
    else
        relS = abs(claims.sigma - sigmaMC)/sigmaMC;
        precOK = true;
        if sigmaMC > floorS
            precOK = 3*seS/sigmaMC <= tolS;
        end
        if precOK
            C = local_check_add(C, 'claimedVsRef', relS <= tolS, sprintf( ...
                ['reported sigma %.6g vs Monte Carlo %.6g (dev %.2f%%, tolerance %.1f%%); ' ...
                 'linearized route would give %.6g'], ...
                claims.sigma, sigmaMC, 100*relS, 100*tolS, sigmaLin));
        else
            C = local_check_add(C, 'claimedVsRef', NaN, sprintf( ...
                ['reported sigma %.6g and Monte Carlo %.6g differ by %.2f%%, but the ' ...
                 'sampled reference is too noisy at this tolerance to decide'], ...
                claims.sigma, sigmaMC, 100*relS));
        end
    end
else
    C = local_check_add(C, 'claimedVsRef', NaN, sprintf( ...
        ['no sigma reported; Monte Carlo sigma is %.6g and the linearized value ' ...
         'is %.6g'], sigmaMC, sigmaLin));
end

if sigmaMC > floorS
    gapPct = 100*abs(sigmaLin - sigmaMC)/sigmaMC;
    if gapPct > 100*tolS
        notes{end+1} = sprintf(['linearized propagation (%.6g) differs from Monte Carlo ' ...
            '(%.6g) by %.1f%%: nonlinearity is significant over these 1-sigma ranges'], ...
            sigmaLin, sigmaMC, gapPct);
    end
end
if strcmp(usedMethod, 'linearized')
    notes{end+1} = 'claim states a linearized method: acceptable only where the gap above is small';
end

sens = (J.*sigma).^2;
if sigmaLin > 0
    sens = sens/sum(sens);
end
sensTbl = table((1:k).', x0, sigma, J, sens, ...
    'VariableNames', {'index', 'x0', 'sigma', 'dfdx', 'share'});

stc = {C.status};
if any(strcmp(stc, 'fail'))
    r.verdict = 'FAIL';
elseif any(strcmp(stc, 'undetermined'))
    r.verdict = 'UNDETERMINED';
else
    r.verdict = 'PASS';
end
r.checks = C;
r.notes = notes;
r.y0 = y0;
r.sigmaLin = sigmaLin;
r.sigmaMC = sigmaMC;
r.mcSE = seS;
r.mcCI = ciMC;
r.mcBias = bias;
r.mcMean = mY;
r.sigmaRef = sigmaMC;
r.usedMethod = usedMethod;
r.J = J;
r.jacobianMethod = jacHow;
r.sensitivity = sensTbl;
r.relUncert = sigmaMC/max(abs(y0), realmin);
r.nMC = N;
r.seed = seed;
r.nChecks = numel(C);
r.nPass = nnz(strcmp(stc, 'pass'));
r.nFail = nnz(strcmp(stc, 'fail'));
r.nUndetermined = nnz(strcmp(stc, 'undetermined'));
r.nNa = nnz(strcmp(stc, 'na'));
r.detail = sprintf('%s: %d pass, %d fail, %d undetermined, %d na', ...
    r.verdict, r.nPass, r.nFail, r.nUndetermined, r.nNa);
bad = strcmp(stc, 'fail') | strcmp(stc, 'undetermined');
if any(bad)
    r.detail = sprintf('%s (%s)', r.detail, strjoin({C(bad).id}, ', '));
end
end

% ===========================================================================
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
