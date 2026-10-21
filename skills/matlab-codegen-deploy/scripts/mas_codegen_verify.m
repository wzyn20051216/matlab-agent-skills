function r = mas_codegen_verify(fcn, args, opts)
%MAS_CODEGEN_VERIFY  Generate, build, run, and compare against MATLAB golden output.
%
%   r = mas_codegen_verify('myAlg', {x, y})
%
%   r.verdict     'PASS' | 'FAIL' | 'SKIP'
%   r.stage       how far it got: 'probe' | 'codegen' | 'build' | 'run' | 'compare'
%   r.maxAbsErr, r.maxRelErr, r.tol
%   r.mexName, r.buildDir
%   r.log         cellstr of stage messages
%   r.detail
%
% STAGES, REPORTED SEPARATELY
%   probe    is `codegen` present and is a C compiler configured?
%   codegen  does `codegen` accept the function and the argument types?
%   build    did the C compile and link?
%   run      did both the MATLAB function and the MEX produce output?
%   compare  do they agree within tolerance?
%
% Reporting the stage is the point. "The build failed" and "the generated code
% returns different numbers than MATLAB" are different problems with different
% fixes, and a single boolean throws that away.
%
% SKIP IS AN HONEST OUTCOME, NOT A SOFT PASS
% If no compiler is configured the function returns `verdict = 'SKIP'` with the
% reason in `r.log`. It never returns PASS, and it is counted separately from
% FAIL by the runner -- an environment without a compiler is not the same as an
% algorithm that is wrong.
%
% Cleanup always runs: the build directory is removed and the MEX unloaded, so
% repeated verification runs cannot accumulate stale binaries that would mask a
% broken rebuild.

if nargin < 3, opts = struct(); end
opts = dflt(opts, struct('tol', 1e-9, 'outDir', '', 'keep', false, ...
    'verbose', false, 'goldenFcn', ''));

% `goldenFcn` exists so the comparison can be exercised on a KNOWN difference.
% The default path (compare fcn against its own MEX) can only ever agree, and a
% harness that can only ever agree has not been shown to detect anything.
if isempty(opts.goldenFcn)
    goldenFcn = fcn;
else
    goldenFcn = opts.goldenFcn;
end

log = {};
r = struct();

% ---------------- stage: probe --------------------------------------------
% `codegen` is shipped as a P-coded file, so `exist('codegen','file')` returns 6,
% not 2. The presence check must accept any nonzero file/builtin/pcode result;
% testing for `== 2` would report "not available" on a perfectly good install.
cgExists = (exist('codegen', 'file') ~= 0) || (exist('codegen', 'builtin') == 5);
ccOk = false;
ccName = '';
if cgExists
    try
        cc = mex.getCompilerConfigurations('C');
        if ~isempty(cc)
            ccOk = true;
            ccName = cc(1).Name;
        end
    catch ME
        log{end+1} = sprintf('compiler probe failed: %s', ME.message); %#ok<AGROW>
    end
end
if ~cgExists
    r.verdict = 'SKIP'; r.stage = 'probe'; r.log = {'MATLAB Coder not available'};
    r.detail = 'SKIP: MATLAB Coder not available';
    return;
end
if ~ccOk
    r.verdict = 'SKIP'; r.stage = 'probe'; r.log = {'no C compiler configured (mex -setup)'};
    r.detail = 'SKIP: no C compiler configured';
    return;
end
log{end+1} = sprintf('compiler: %s', ccName);

buildDir = opts.outDir;
if isempty(buildDir), buildDir = tempname; end
if ~exist(buildDir, 'dir'), mkdir(buildDir); end
cleanupObj = onCleanup(@() cleanup(buildDir, fcn));

% ---------------- stage: codegen ------------------------------------------
try
    cfg = coder.config('mex');
    cfg.GenerateReport = true;
    out = evalc('codegen(''-config'', cfg, fcn, ''-args'', args, ''-d'', buildDir)');
    log{end+1} = 'codegen: generated';
    r.codegenOutput = out;
catch ME
    r.verdict = 'FAIL'; r.stage = 'codegen'; r.log = [log, {ME.message}];
    r.detail = sprintf('FAIL at codegen: %s', ME.message);
    return;
end

% ---------------- stage: build --------------------------------------------
mexName = [fcn '_mex'];
mexFile = fullfile(buildDir, [mexName '.' mexext]);
if exist(mexFile, 'file') ~= 3 && exist(mexFile, 'file') ~= 2
    r.verdict = 'FAIL'; r.stage = 'build'; r.log = [log, {'MEX file not produced'}];
    r.detail = 'FAIL at build: MEX file not produced';
    return;
end
log{end+1} = sprintf('build: %s', just_name(mexFile));

% ---------------- stage: run ----------------------------------------------
try
    gold = feval(goldenFcn, args{:});
    actual = feval(mexName, args{:});
catch ME
    r.verdict = 'FAIL'; r.stage = 'run'; r.log = [log, {ME.message}];
    r.detail = sprintf('FAIL at run: %s', ME.message);
    return;
end
log{end+1} = 'run: both executed';

% ---------------- stage: compare ------------------------------------------
[maxAbs, maxRel, cmpOk, cmpMsg] = compare_out(gold, actual, opts.tol);
r.maxAbsErr = maxAbs;
r.maxRelErr = maxRel;
r.tol = opts.tol;
if cmpOk
    r.verdict = 'PASS'; r.stage = 'compare';
else
    r.verdict = 'FAIL'; r.stage = 'compare';
    r.log = [log, {cmpMsg}];
end
r.mexName = mexName;
r.buildDir = buildDir;
r.log = log;
r.detail = sprintf('%s: maxAbs %.3e, maxRel %.3e (tol %.1e) -- %s', ...
    fcn, maxAbs, maxRel, opts.tol, r.verdict);
end

% ===========================================================================
function [maxAbs, maxRel, ok, msg] = compare_out(gold, actual, tol)
maxAbs = 0; maxRel = 0; ok = true; msg = '';

if isstruct(gold)
    if ~isstruct(actual) || ~isequal(sort(fieldnames(gold)), sort(fieldnames(actual)))
        ok = false; msg = 'struct outputs have different fields'; return;
    end
    flds = fieldnames(gold);
    for k = 1:numel(flds)
        [a, r2, okk, m2] = compare_out(gold.(flds{k}), actual.(flds{k}), tol);
        maxAbs = max(maxAbs, a); maxRel = max(maxRel, r2);
        if ~okk, ok = false; msg = [flds{k} ': ' m2]; end
    end
    return;
end

if iscell(gold)
    if ~iscell(actual) || ~isequal(size(gold), size(actual))
        ok = false; msg = 'cell outputs differ in size'; return;
    end
    for k = 1:numel(gold)
        [a, r2, okk, m2] = compare_out(gold{k}, actual{k}, tol);
        maxAbs = max(maxAbs, a); maxRel = max(maxRel, r2);
        if ~okk, ok = false; msg = sprintf('cell{%d}: %s', k, m2); end
    end
    return;
end

if ~isnumeric(gold) || ~isnumeric(actual)
    % non-numeric: fall back to exact equality, and say that is what was used
    ok = isequal(gold, actual);
    if ~ok, msg = 'non-numeric outputs differ'; end
    return;
end

if ~isequal(size(gold), size(actual))
    ok = false;
    msg = sprintf('size mismatch: MATLAB %s vs MEX %s', mat2str(size(gold)), ...
        mat2str(size(actual)));
    return;
end

d = abs(gold(:) - actual(:));
maxAbs = max([d; 0]);
den = max(abs(gold(:)), eps);
% `d ./ den` is element-wise relative error; `d / den` would be matrix right-
% division, which for two column vectors produces a full outer-product matrix
% and then max() returns a row vector, breaking every downstream scalar use.
maxRel = max([d ./ den; 0]);
ok = (maxAbs <= tol) || (maxRel <= tol);
if ~ok
    msg = sprintf('maxAbs %.3e / maxRel %.3e exceed tol %.1e', maxAbs, maxRel, tol);
end
end

% ===========================================================================
function cleanup(buildDir, fcn)
try
    if ~isempty(buildDir) && exist(buildDir, 'dir')
        rmdir(buildDir, 's');
    end
catch
end
try
    clear([fcn '_mex']);
catch
end
% `codegen -d buildDir` still drops the MEX binary into the current working
% directory; leaving it there pollutes the caller's tree and lets a stale binary
% mask a later rebuild. Remove it explicitly.
mexFiles = {[fcn '_mex.' mexext]};
for k = 1:numel(mexFiles)
    if exist(mexFiles{k}, 'file'), delete(mexFiles{k}); end
end
end

function n = just_name(p)
[~, n, e] = fileparts(p);
n = [n e];
end

% ===========================================================================
function o = dflt(o, d)
f = fieldnames(d);
for k = 1:numel(f)
    if ~isfield(o, f{k}), o.(f{k}) = d.(f{k}); end
end
end
