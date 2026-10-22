function r = mas_repro_check(runFcn, opts)
%MAS_REPRO_CHECK  Test whether a stochastic computation is reproducible.
%
%   r = mas_repro_check(@() my_simulation(0.1), struct('seed', 7))
%
% runFcn  no-argument function handle returning a real numeric/logical array
% opts    .seed                  seed used for the repeated runs (default 20261021)
%         .tol                   absolute tolerance for "identical" (default 0 = bitwise)
%         .expectSeedDependence  true | false | [] (default []: measure, do not grade)
%
% r.verdict  PASS | FAIL | UNDETERMINED
% r.diffSameSeed, r.diffOtherSeed, r.digest, r.digest2
% r.checks   nonEmpty, sameSeed, shapeStable, seedEffect
%
% WHAT ONE SUCCESSFUL RUN DOES NOT PROVE
% A single run of a stochastic pipeline is an anecdote. Reproducibility means the
% same seed gives the same numbers, every time, and -- separately -- that a
% different seed actually changes them (otherwise "reproducible" may only mean
% "the randomness is not wired into the result", and the error bars are fiction).
% This tool runs the function three times:
%
%   seed S   -> v1
%   seed S   -> v2   must match v1 within tol
%   seed S+1 -> v3   measured, and graded only if expectSeedDependence is stated
%
% The caller's RNG stream is saved and restored: checking reproducibility must not
% itself perturb the experiment it is checking.
%
% LIMITS, STATED SO THEY ARE NOT MISTAKEN FOR PASSES
% Same-seed equality holds only for this MATLAB version on this platform with the
% same code path; it does not establish cross-platform or cross-release
% reproducibility, and it does not validate the model. r.notes says so. The digest
% is SHA-256 over the canonical text of the values (Java is available in desktop
% MATLAB; if it is not, the digest is empty and the check is unaffected).

if nargin < 2 || isempty(opts), opts = struct(); end
if ~isa(runFcn, 'function_handle')
    error('mas_repro_check:f', 'runFcn must be a no-argument function handle');
end
seed = local_field(opts, 'seed', 20261021);
tol = local_field(opts, 'tol', 0);
expectDep = [];
if isfield(opts, 'expectSeedDependence') && ~isempty(opts.expectSeedDependence)
    expectDep = logical(opts.expectSeedDependence);
end

C = local_check_empty();
notes = {'same-seed equality is necessary, not sufficient: cross-platform and cross-release reproducibility are not tested'};

st = rng;
cu = onCleanup(@() rng(st)); %#ok<NASGU>

rng(seed);   v1 = runFcn();
rng(seed);   v2 = runFcn();
rng(seed+1); v3 = runFcn();

vals = {v1, v2, v3};
for k = 1:3
    v = vals{k};
    if ~(isnumeric(v) || islogical(v)) || ~isreal(v)
        error('mas_repro_check:type', ...
            'runFcn must return a real numeric or logical array (run %d returned %s)', ...
            k, class(v));
    end
end

C = local_check_add(C, 'nonEmpty', ~isempty(v1), sprintf( ...
    'result has %d elements', numel(v1)));

if isequal(size(v1), size(v2))
    C = local_check_add(C, 'shapeStable', true, sprintf('both runs returned %s', mat2str(size(v1))));
else
    C = local_check_add(C, 'shapeStable', false, sprintf( ...
        'same seed produced different shapes: %s vs %s', mat2str(size(v1)), mat2str(size(v2))));
end

if isempty(v1) && isempty(v2)
    dSame = 0; dSeed = 0;
else
    dSame = local_maxdiff(v1, v2);
    dSeed = local_maxdiff(v1, v3);
end
C = local_check_add(C, 'sameSeed', dSame <= tol, sprintf( ...
    'same seed: max |difference| %.3e (tolerance %.3e)', dSame, tol));

if isempty(expectDep)
    C = local_check_add(C, 'seedEffect', 'na', sprintf( ...
        'seed S and S+1 differ by %.3e; dependence not asserted', dSeed));
elseif expectDep
    C = local_check_add(C, 'seedEffect', dSeed > tol, sprintf( ...
        'expected the result to depend on the seed; max difference %.3e (tol %.3e)', ...
        dSeed, tol));
else
    C = local_check_add(C, 'seedEffect', dSeed <= tol, sprintf( ...
        'expected the result NOT to depend on the seed; max difference %.3e (tol %.3e)', ...
        dSeed, tol));
end

digest1 = local_digest(v1);
digest2 = local_digest(v2);
if isempty(digest1)
    notes{end+1} = 'SHA-256 unavailable in this session: digest not recorded';
elseif ~strcmp(digest1, digest2)
    notes{end+1} = 'digests differ despite equal values: check the canonicalisation';
end

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
r.v1 = v1;
r.v2 = v2;
r.v3 = v3;
r.diffSameSeed = dSame;
r.diffOtherSeed = dSeed;
r.digest = digest1;
r.digest2 = digest2;
r.seed = seed;
r.tol = tol;
r.expectSeedDependence = expectDep;
r.nRuns = 3;
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
function d = local_maxdiff(a, b)
if ~isequal(size(a), size(b))
    d = Inf;
    return;
end
if isempty(a)
    d = 0;
    return;
end
d = max(abs(double(a(:)) - double(b(:))));
end

function h = local_digest(v)
h = '';
try
    s = sprintf('%.17g:', double(v(:)));
    md = java.security.MessageDigest.getInstance('SHA-256');
    md.update(uint8(s));
    b = typecast(md.digest(), 'uint8');
    h = lower(reshape(dec2hex(b, 2).', 1, []));
catch
    h = '';
end
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
