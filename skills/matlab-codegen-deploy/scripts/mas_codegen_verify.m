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
%   r.session     value of MAS_RUN_SESSION when the call was made ('' if unset)
%   r.compilerLog struct array (name, bytes, text) with every .log/.err under
%                 the build tree -- retained in memory even though the build
%                 directory is cleaned up. `text` is the raw byte stream as
%                 chars (one char per byte), so uint8(text) reproduces the
%                 compiler's file byte for byte; it is not a text decoding.
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
% broken rebuild. `opts.keep = true` retains the build tree instead, which is how
% the complete compiler log (`build/win64/buildLog.log`) is preserved for a
% failure that needs post-mortem inspection.
%
% SESSION-SCOPED TEMP DIRS
% When `MAS_CODEGEN_RUN_ROOT` is set, the private build and working directories
% are created under it instead of the global temp root. The test harness sets it
% to the session directory, so every artifact one run produces -- generated C,
% object files, build log, MEX copy -- lives under an ownership marker the
% driver can check.

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
r.session = getenv('MAS_RUN_SESSION');
r.buildDirRetained = logical(opts.keep);

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

% `codegen -d` also drops a MEX copy into the CURRENT directory. Two
% concurrent verifications in one cwd therefore overwrite and delete each
% other's binary. Run in a private cwd and restore the caller's folder.
oldDir = pwd;
runRoot = getenv('MAS_CODEGEN_RUN_ROOT');
if isempty(runRoot), runRoot = tempdir; end
if ~exist(runRoot, 'dir'), mkdir(runRoot); end
buildDir = opts.outDir;
if isempty(buildDir), buildDir = tempname(runRoot); end
if ~is_abs_path(buildDir), buildDir = fullfile(oldDir, buildDir); end
if ~exist(buildDir, 'dir'), mkdir(buildDir); end
workDir = tempname(runRoot);
mkdir(workDir);
r.buildDir = buildDir;
cleanupObj = onCleanup(@() cleanup(buildDir, workDir, fcn, oldDir, opts.keep));
cd(workDir);

% ---------------- stage: codegen ------------------------------------------
try
    cfg = coder.config('mex');
    cfg.GenerateReport = true;
    out = evalc('codegen(''-config'', cfg, fcn, ''-args'', args, ''-d'', buildDir)');
    log{end+1} = 'codegen: generated';
    r.codegenOutput = out;
    r.compilerLog = collect_logs(buildDir);
catch ME
    % A build/link failure arrives through the same emlc:compilationError as a
    % rejected entry, and both can carry NO message text. The build log is the
    % only thing that tells them apart: if the compiler ran, a .log exists, so
    % the stage is build and the log supplies the diagnostic. Blaming the entry
    % form for a linker error would send the caller to fix the wrong thing.
    logs = collect_logs(buildDir);
    r.compilerLog = logs;
    id = char(ME.identifier);
    msg = strtrim(char(ME.message));
    if ~isempty(logs)
        stage = 'build';
        if isempty(msg)
            msg = sprintf(['%s with an empty message; the compiler log reports: %s ' ...
                '(full text in r.compilerLog)'], id, log_highlights(logs));
        end
    else
        stage = 'codegen';
        if isempty(msg)
            if isa(fcn, 'function_handle')
                % An entry given as a function handle makes codegen reject its
                % option list with emlc:compilationError and NO message text
                % (measured on this install in both a batch process and the MCP
                % evaluation frame). Report the identifier and the fix rather
                % than a detail that ends in a colon.
                msg = sprintf(['%s with an empty message: the entry was a function ' ...
                    'handle, not a file name. Pass the function NAME ' ...
                    '(mas_codegen_verify(''myAlg'', ...)) instead of a function handle ' ...
                    'or an anonymous function.'], id);
            else
                % A string entry can also fail before the build (undefined name,
                % parse error, unsupported construct) with the same empty message.
                % Do not blame the entry form here: say what is known.
                msg = sprintf(['%s with an empty message while compiling ''%s'': ' ...
                    'codegen rejected the entry before the build, so no compiler log ' ...
                    'was produced. Check that the function is on the path and uses ' ...
                    'only Coder-supported syntax.'], id, char(fcn));
            end
        end
    end
    r.errorIdentifier = id;
    r.errorMessage = msg;
    r.verdict = 'FAIL'; r.stage = stage; r.log = [log, {msg}];
    r.detail = sprintf('FAIL at %s: %s', stage, msg);
    return;
end

% ---------------- stage: build --------------------------------------------
mexName = [fcn '_mex'];
mexFile = fullfile(buildDir, [mexName '.' mexext]);
if exist(mexFile, 'file') ~= 3 && exist(mexFile, 'file') ~= 2
    r.compilerLog = collect_logs(buildDir);
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
function cleanup(buildDir, workDir, fcn, oldDir, keepBuild)
try
    clear([fcn '_mex']);
catch
end
try
    if ~strcmp(pwd, oldDir), cd(oldDir); end
catch
end
try
    if exist(workDir, 'dir'), rmdir(workDir, 's'); end
catch
end
try
    % Never delete the caller's folder or an output path that aliases it.
    if ~keepBuild && ~isempty(buildDir) && exist(buildDir, 'dir') && ...
            ~strcmp(buildDir, oldDir) && ~strcmp(buildDir, workDir)
        rmdir(buildDir, 's');
    end
catch
end
end

function L = collect_logs(root)
%COLLECT_LOGS  Full text of every build/compiler log under the build tree.
% Collected before cleanup because the build directory is deleted on the way
% out; a FAIL at the build stage without its compiler output is not actionable.
L = struct('name', {}, 'bytes', {}, 'text', {});
if isempty(root) || ~isfolder(root), return; end
d = dir(fullfile(root, '**', '*'));
for k = 1:numel(d)
    if d(k).isdir, continue; end
    [~, ~, ext] = fileparts(d(k).name);
    if ~any(strcmpi(ext, {'.log', '.err'}))
        continue;
    end
    p = fullfile(d(k).folder, d(k).name);
    txt = read_text(p);
    rel = p;
    if strncmpi(rel, root, numel(root)), rel = rel(numel(root)+1:end); end
    rel = regexprep(rel, '^[\\/]+', '');
    L(end+1) = struct('name', rel, 'bytes', d(k).bytes, 'text', txt); %#ok<AGROW>
end
[~, order] = sort({L.name});
L = L(order);
end

function s = log_highlights(L)
% The lines that name a compiler/linker error, so the detail is actionable
% without opening a five-thousand-line log.
parts = {};
for k = 1:numel(L)
    lines = regexp(L(k).text, '\r?\n', 'split');
    for j = 1:numel(lines)
        if ~isempty(regexpi(lines{j}, 'error|fatal', 'once'))
            parts{end+1} = sprintf('%s: %s', L(k).name, strtrim(lines{j})); %#ok<AGROW>
        end
    end
end
if isempty(parts)
    s = sprintf('%s (no line containing "error" was found)', L(1).name);
else
    s = strjoin(parts, ' | ');
    if numel(s) > 400, s = [s(1:400) '...']; end
end
end

function t = read_text(p)
% Byte-preserving: one char per byte. Reading with '*char' applies a text
% decoding, so a localized compiler message no longer round-trips and the
% "complete log" cannot be reproduced exactly.
t = '';
fid = fopen(p, 'r');
if fid < 0, return; end
b = fread(fid, Inf, '*uint8')';
fclose(fid);
t = char(b);
end

function tf = is_abs_path(p)
tf = ~isempty(p) && (p(1) == filesep || ...
    (ispc && numel(p) > 1 && p(2) == ':'));
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
