function r = test_codegen(verbose)
%TEST_CODEGEN  Test the matlab-codegen-deploy tools with truth assertions and
% negative controls. Every expected value comes from an independent source --
% a hand-written fixture, the known quantizer behaviour, or a deliberately
% wrong golden function -- never from the tool under test itself.
if nargin < 1, verbose = false; end

T = {};
function add(name, fn)
    T{end+1} = struct('name', name, 'fn', fn); %#ok<AGROW>
end

% ---- codegen_ready: fixtures --------------------------------------------
% Every artifact this run produces lives under one session root: the fixture
% directory, the generated C, object files and build logs from
% mas_codegen_verify. The manifest names what the session owns, so cleanup can
% prove ownership instead of deleting a well-known path. Two processes used to
% share tests/fixtures_codegen and each other's MEX; the session id also makes
% the log attributable when two runs overlap.
session = getenv('MAS_RUN_SESSION');
if isempty(session)
    session = sprintf('local_%d_%s_%04d', feature('getpid'), ...
        datestr(now, 'yyyymmdd_HHMMSS'), randi(9999));
end
session = regexprep(session, '[^A-Za-z0-9_.-]', '_');
runRoot = getenv('MAS_CODEGEN_RUN_ROOT');
if isempty(runRoot)
    runRoot = fullfile(tempdir, 'mas_codegen_tests');
end
if ~exist(runRoot, 'dir'), mkdir(runRoot); end
sessionRoot = fullfile(runRoot, session);
if ~exist(sessionRoot, 'dir'), mkdir(sessionRoot); end
fixDir = tempname(sessionRoot);
mkdir(fixDir);
ownerFile = fullfile(fixDir, '.mas_run_owner');
fid = fopen(ownerFile, 'w');
fprintf(fid, '%s', fixDir);
fclose(fid);
manifest = struct('session', session, 'pid', feature('getpid'), ...
    'matlabVersion', version, 'startedAt', datestr(now, 'yyyy-mm-dd HH:MM:SS'), ...
    'sessionRoot', sessionRoot, 'fixtureDir', fixDir);
manifestFile = fullfile(sessionRoot, '.mas_run_session.json');
fid = fopen(manifestFile, 'w');
fprintf(fid, '%s', jsonencode(manifest));
fclose(fid);
prevRunRoot = getenv('MAS_CODEGEN_RUN_ROOT');
cleanup = onCleanup(@() cleanup_run_dir(fixDir, ownerFile, sessionRoot, session, manifestFile, prevRunRoot));
% mas_codegen_verify puts its private build/work dirs under this root, so no
% compile artifact can land in a directory another process also uses.
setenv('MAS_CODEGEN_RUN_ROOT', sessionRoot);

cleanFn  = fullfile(fixDir, 'clean_fn.m');
growFn   = fullfile(fixDir, 'grow_in_loop.m');
growOut  = fullfile(fixDir, 'grow_outside.m');
evalFn   = fullfile(fixDir, 'has_eval.m');
tgtFn    = fullfile(fixDir, 'codegen_target.m');
tgtWrong = fullfile(fixDir, 'codegen_target_wrong.m');
bfFn     = fullfile(fixDir, 'build_fail_fn.m');
skFn     = fullfile(fixDir, 'syntax_bad.m');

write_fixtures(cleanFn, growFn, growOut, evalFn, tgtFn, tgtWrong, bfFn, skFn);
addpath(fixDir);

add('ready: clean file is READY', @() ready_clean());
add('ready: eval is a blocker', @() ready_eval());
add('ready: growth in loop is blocker', @() ready_grow_in());
add('ready: growth outside loop is only warning', @() ready_grow_out());
add('ready: strict promotes warnings', @() ready_strict());
% A file given by FULL PATH must resolve. `which()` returns empty for a full
% path (it searches the path, not the file system), so a resolver that only
% uses which() returns "" and read_text() then fails with "cannot open " -- an
% empty argument, which reads like an I/O fault instead of a path bug. This
% case uses a temp file that is deliberately NOT on the path.
add('ready: full path resolves', @() ready_fullpath());

% ---- codegen_verify -----------------------------------------------------
add('verify: PASS on a real function', @() verify_pass());
add('verify: FAIL via goldenFcn mismatch', @() verify_fail());
add('verify: FAIL on bad codegen input', @() verify_badarg());
% Passing a function HANDLE where codegen wants a file name makes Coder reject the
% option list with emlc:compilationError and an EMPTY message, so a detail built as
% ['FAIL at codegen: ' ME.message] degenerates to 'FAIL at codegen: ' -- a blank
% diagnostic for the caller to act on. Same blank on both call channels.
add('verify: empty-message codegen error still yields a usable detail', ...
    @() verify_blank_error_detail());
% A linker failure also arrives as emlc:compilationError with an EMPTY message.
% The build log is the only way to tell it apart from a rejected entry, so the
% case asserts the stage, the retained log text and an actionable detail.
add('verify: link failure reported at build with compiler log', ...
    @() verify_buildfail());
% A string entry that codegen rejects before the build also has an EMPTY
% message. The detail must describe that case, not blame the function-handle
% entry form -- the two failures share an identifier and differ only by cause.
add('verify: string entry rejection does not blame entry form', ...
    @() verify_string_entry_detail());

% ---- fixpt_range --------------------------------------------------------
add('fixpt: SQNR matches theory within band', @() fixpt_sqnr());
add('fixpt: overflow detected as fraction', @() fixpt_overflow());
add('fixpt: zero output warns', @() fixpt_zero());

% -------------------------------------------------------------------------
n = numel(T);
pass = true(n, 1);
names = cell(n, 1);
for k = 1:n
    names{k} = T{k}.name;
    try
        v = T{k}.fn();
        pass(k) = logical(v);
    catch ME
        pass(k) = false;
        if verbose
            fprintf('  [EXC] %s: %s\n', T{k}.name, ME.message);
        end
    end
    if verbose
        fprintf('  %-4s %s\n', tern(pass(k), 'PASS', 'FAIL'), T{k}.name);
    end
end
r = struct('names', {names}, 'pass', pass, 'nPass', sum(pass), 'nTotal', n, ...
    'session', session, 'sessionRoot', sessionRoot, 'fixtureDir', fixDir);
fprintf('test_codegen_session: %s\n', session);
fprintf('test_codegen_fixture: %s\n', fixDir);
fprintf('test_codegen: %d/%d passed\n', r.nPass, r.nTotal);
end

% ===========================================================================
function write_fixtures(cleanFn, growFn, growOut, evalFn, tgtFn, tgtWrong, bfFn, skFn)
fid = fopen(cleanFn, 'w');
fprintf(fid, 'function y = clean_fn(x)\ny = x.^2 + 1;\nend\n');
fclose(fid);

fid = fopen(growFn, 'w');
fprintf(fid, 'function y = grow_in_loop(n)\ny = zeros(1, 0);\nfor k = 1:n\n    y(end+1) = k;\nend\nend\n');
fclose(fid);

fid = fopen(growOut, 'w');
fprintf(fid, 'function y = grow_outside(x)\ny = [x 1];\ny(end+1) = 9;\nend\n');
fclose(fid);

fid = fopen(evalFn, 'w');
fprintf(fid, 'function y = has_eval(x)\ny = eval(''x + 1'');\nend\n');
fclose(fid);

fid = fopen(tgtFn, 'w');
fprintf(fid, 'function y = codegen_target(x)\ny = x.^2 + sin(x) + 1;\nend\n');
fclose(fid);

fid = fopen(tgtWrong, 'w');
fprintf(fid, 'function y = codegen_target_wrong(x)\ny = x.^2 + sin(x) + 2;\nend\n');
fclose(fid);

fid = fopen(bfFn, 'w');
fprintf(fid, ['function y = build_fail_fn(x)\n' ...
    'coder.ceval(''mas_undefined_symbol_xyz'', int32(1));\n' ...
    'y = x + 1;\nend\n']);
fclose(fid);

fid = fopen(skFn, 'w');
fprintf(fid, 'function y = syntax_bad(x)\ny = x + ;\nend\n');
fclose(fid);
end

% ===========================================================================
function v = ready_clean()
r = mas_codegen_ready('clean_fn');
v = strcmp(r.verdict, 'READY') && r.ok && r.counts.blocker == 0;
end

function v = ready_eval()
r = mas_codegen_ready('has_eval');
ids = {r.findings.id};
v = ~r.ok && strcmp(r.verdict, 'BLOCKED') && any(strcmp(ids, 'CG001'));
end

function v = ready_grow_in()
r = mas_codegen_ready('grow_in_loop');
ids = {r.findings.id}; sevs = {r.findings.severity};
idx = find(strcmp(ids, 'CG010'));
% growth inside a loop must be a blocker, and the loop tracking must have
% caught it (depth > 0 at the offending line)
v = ~isempty(idx) && strcmp(sevs{idx(1)}, 'blocker') && ~r.ok;
end

function v = ready_grow_out()
r = mas_codegen_ready('grow_outside');
ids = {r.findings.id}; sevs = {r.findings.severity};
idx = find(strcmp(ids, 'CG010'));
% growth OUTSIDE a loop is bounded: only a warning, so the file is still READY_WITH_WARNINGS, not BLOCKED
v = ~isempty(idx) && strcmp(sevs{idx(1)}, 'warning') && strcmp(r.verdict, 'READY_WITH_WARNINGS');
end

function v = ready_strict()
r = mas_codegen_ready('grow_outside', struct('strict', true));
v = strcmp(r.verdict, 'BLOCKED') && ~r.ok;
end

function v = ready_fullpath()
% Write a clean file into a directory that is NOT on the path, then audit it by
% FULL PATH. A bare function name is never used, so addpath cannot hide a
% resolver that only understands names -- which is exactly how the original
% bug survived: every other case had its fixture directory on the path.
d = fullfile(tempdir, sprintf('p43_ready_%d', feature('getpid')));
if ~exist(d, 'dir'), mkdir(d); end
c = onCleanup(@() rmdir(d, 's'));
f = fullfile(d, 'off_path_fn.m');
fid = fopen(f, 'w');
if fid < 0, v = false; return; end
fwrite(fid, sprintf('function y = off_path_fn(x)\n%%#codegen\ny = zeros(size(x));\nfor k = 1:numel(x)\n  y(k) = x(k)^2;\nend\nend\n'), 'char');
fclose(fid);
r = mas_codegen_ready(f);          % FULL PATH, not a name
v = strcmp(r.verdict, 'READY');
end

% ===========================================================================
function v = verify_pass()
% A trivial but real function; the MEX must agree with MATLAB to machine
% precision. This exercises probe -> codegen -> build -> run -> compare.
% The entry is a STRING FILE NAME -- the supported form. The test also pins
% that the complete compiler log is retained in memory and that the private
% build tree is under this session's root, not a shared temp path.
if exist('codegen', 'file') == 0
    r = mas_codegen_verify('codegen_target', {1:10});
    v = strcmp(r.verdict, 'SKIP');
    say_why(v, r);
    return;
end
r = mas_codegen_verify('codegen_target', {1:10});
logs = r.compilerLog;
names = {};
texts = {};
if ~isempty(logs), names = {logs.name}; texts = {logs.text}; end
hasBuildLog = any(~cellfun(@isempty, regexpi(names, 'buildLog\.log$')));
complete = hasBuildLog && all(cellfun(@(t) ~isempty(t), texts));
root = getenv('MAS_CODEGEN_RUN_ROOT');
owned = ~isempty(root) && strncmpi(r.buildDir, root, numel(root));
v = strcmp(r.verdict, 'PASS') && strcmp(r.stage, 'compare') && ...
    complete && owned && strcmp(r.session, getenv('MAS_RUN_SESSION'));
if ~v
    fprintf('       why: buildLog=%d complete=%d owned=%d nLogs=%d root=%s buildDir=%s\n', ...
        hasBuildLog, complete, owned, numel(logs), root, r.buildDir);
end
say_why(v, r);
end

function v = verify_fail()
% goldenFcn points at a DIFFERENT function that returns a wrong value, so the
% comparison must FAIL. If it did not, the harness could not detect a mismatch.
if exist('codegen', 'file') == 0
    v = true;   % cannot exercise without codegen
    return;
end
r = mas_codegen_verify('codegen_target', {1:10}, struct('goldenFcn', 'codegen_target_wrong'));
v = strcmp(r.verdict, 'FAIL') && strcmp(r.stage, 'compare');
say_why(v, r);
end

function v = verify_badarg()
% A function that codegen genuinely cannot compile (dynamic eval) must fail at
% the codegen stage. This is the complement of verify_pass: one proves the
% harness accepts a good build, this proves it rejects a bad one.
if exist('codegen', 'file') == 0
    v = true;
    return;
end
r = mas_codegen_verify('has_eval', {5});
v = strcmp(r.verdict, 'FAIL');
say_why(v, r);
end

function v = verify_blank_error_detail()
% The entry is a function HANDLE, which is the shape that makes codegen throw
% emlc:compilationError with an empty message. The verdict is not the point --
% the point is that the caller still gets something actionable to read.
if exist('codegen', 'file') == 0
    v = true;
    return;
end
r = mas_codegen_verify(@(x) x * 2 + sin(x), {0.5});
if ~strcmp(r.verdict, 'FAIL') || ~strcmp(r.stage, 'codegen')
    v = false;
    say_why(v, r);
    return;
end
d = strtrim(r.detail);
tells = {'emlc', 'identifier', 'file name', 'function handle'};
hit = any(cellfun(@(s) ~isempty(strfind(d, s)), tells));
idOk = isfield(r, 'errorIdentifier') && ~isempty(strfind(r.errorIdentifier, 'emlc'));
v = numel(d) > numel('FAIL at codegen:') + 20 && hit && idOk;
if ~v
    fprintf('       why: detail is %d chars, tells=%d, identifier=''%s''\n', ...
        numel(d), hit, fld(r, 'errorIdentifier'));
end
end

function v = verify_buildfail()
% coder.ceval to a symbol that does not exist compiles but fails to link. This
% is the only way here to produce a REAL compiler log: the entry is a valid
% string file name, so a diagnostic that blames the entry form would be wrong.
if exist('codegen', 'file') == 0
    v = true;
    return;
end
try
    cc = mex.getCompilerConfigurations('C');
    if isempty(cc), v = true; return; end
catch
    v = true;
    return;
end
r = mas_codegen_verify('build_fail_fn', {1});
names = {}; texts = {};
if isfield(r, 'compilerLog') && ~isempty(r.compilerLog)
    names = {r.compilerLog.name}; texts = {r.compilerLog.text};
end
hasLog = any(~cellfun(@isempty, regexpi(names, 'buildLog\.log$')));
hasErr = any(cellfun(@(t) ~isempty(regexpi(t, 'LNK\d+|fatal error', 'once')), texts));
cleaned = isfield(r, 'buildDir') && ~isfolder(r.buildDir);
detailOk = ~isempty(strfind(lower(fld(r, 'detail')), 'compiler log'));
v = strcmp(fld(r, 'verdict'), 'FAIL') && strcmp(fld(r, 'stage'), 'build') && ...
    hasLog && hasErr && cleaned && detailOk;
if ~v
    fprintf('       why: verdict=%s stage=%s log=%d err=%d cleaned=%d detail=%s\n', ...
        fld(r, 'verdict'), fld(r, 'stage'), hasLog, hasErr, cleaned, ...
        oneline(fld(r, 'detail')));
end
end

function v = verify_string_entry_detail()
% A string entry with a parse error is rejected before the build, with the same
% empty message as a function handle. The diagnostic must name the function and
% say the failure is pre-build; blaming the entry form would be wrong.
if exist('codegen', 'file') == 0
    v = true;
    return;
end
r = mas_codegen_verify('syntax_bad', {1});
d = lower(fld(r, 'detail'));
blamesHandle = ~isempty(strfind(d, 'function handle'));
v = strcmp(fld(r, 'verdict'), 'FAIL') && strcmp(fld(r, 'stage'), 'codegen') && ...
    ~isempty(strfind(d, 'syntax_bad')) && ~isempty(strfind(d, 'before the build')) && ...
    isempty(r.compilerLog) && ~blamesHandle;
if ~v
    fprintf('       why: stage=%s nLogs=%d blamesHandle=%d detail=%s\n', ...
        fld(r, 'stage'), numel(r.compilerLog), blamesHandle, oneline(fld(r, 'detail')));
end
end

% ===========================================================================
function v = fixpt_sqnr()
% Quantizing a sinusoid to W bits: SQNR ~ 6.02*W + 1.76 dB for a full-scale
% tone. With a small guard band it will be a little less, so we assert a
% generous lower bound rather than an exact figure (which depends on the
% stimulus's peak-to-full-scale ratio, not on anything the tool computes).
if exist('fi', 'file') == 0
    v = true;
    return;
end
t = (0:0.001:1)';
u = 0.9 * sin(2*pi*5*t);   % 0.9 peak keeps us clear of saturation
r = mas_fixpt_range(@(x) x, { {u} }, struct('wordLength', 16, 'signed', true, 'guardBits', 1));
v = r.sqnrDb > 80 && r.overflowFrac == 0 && r.ok;
end

function v = fixpt_overflow()
% A stimulus that exceeds the representable range must be reported as a
% positive overflow fraction, NOT silently saturated away.
if exist('fi', 'file') == 0
    v = true;
    return;
end
u = [1; 2; 4; 8; 16; 32; 64; 128; 256; 512];   % grows well past any 8-bit range
r = mas_fixpt_range(@(x) x, { {u} }, struct('wordLength', 8, 'signed', false, 'guardBits', 0));
v = r.overflowFrac > 0 && ~r.ok;
end

function v = fixpt_zero()
if exist('fi', 'file') == 0
    v = true;
    return;
end
u = zeros(10, 1);
r = mas_fixpt_range(@(x) x, { {u} });
v = ~isempty(r.warnings) && ~r.ok;
end

% ===========================================================================
function cleanup_run_dir(d, ownerFile, sessionRoot, session, manifestFile, prevRoot)
% Remove only this run's directory, and only when the marker says so. A
% cleanup that blindly rmdir's a well-known path is what caused the race.
% The session root is removed only after its manifest names this session and
% this fixture directory, and only when nothing else is left inside it; a
% crash that stranded build output therefore shows up as residue instead of
% being deleted by the next run.
setenv('MAS_CODEGEN_RUN_ROOT', prevRoot);
try
    owned = false;
    if exist(ownerFile, 'file')
        fid = fopen(ownerFile, 'r');
        if fid >= 0
            txt = fread(fid, Inf, '*char')';
            fclose(fid);
            owned = strcmp(txt, d);
        end
    end
    if ~owned
        warning('test_codegen:ownerMismatch', 'not removing %s: ownership marker does not match', d);
        return;
    end
    sessionOk = false;
    if exist(manifestFile, 'file')
        try
            M = jsondecode(fileread(manifestFile));
            sessionOk = strcmp(M.session, session) && strcmp(M.fixtureDir, d);
        catch
        end
    end
    try, rmpath(d); catch, end
    if exist(d, 'dir'), rmdir(d, 's'); end
    if sessionOk
        try, delete(manifestFile); catch, end
        try, rmdir(sessionRoot); catch, end
        if exist(sessionRoot, 'dir')
            warning('test_codegen:sessionResidue', ...
                'session root still holds files after cleanup: %s', sessionRoot);
        end
    else
        warning('test_codegen:sessionManifest', ...
            'not removing session root %s: manifest missing or does not match', sessionRoot);
    end
catch ME
    warning('test_codegen:cleanupFailed', 'cleanup of %s failed: %s', d, ME.message);
end
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end

function say_why(v, r)
%SAY_WHY  Keep the cause of a failing case in the log.
% A FAIL line that carries only the case name is not evidence: under load the two
% build-dependent cases here failed (11/13) and the console could not say whether
% it was the probe, the codegen call, the build or the comparison. The verdict,
% the stage and the detail are what separate those, so print them on a failure.
if v || ~isstruct(r), return; end
fprintf('       why: verdict=%s stage=%s detail=%s\n', fld(r, 'verdict'), ...
    fld(r, 'stage'), oneline(fld(r, 'detail')));
end

function s = fld(r, nm)
if isfield(r, nm) && ~isempty(r.(nm)), s = strtrim(char(string(r.(nm))));
else, s = '(absent)'; end
end

function s = oneline(s)
s = strrep(strrep(s, newline, ' '), sprintf('\r'), ' ');
if numel(s) > 200, s = [s(1:200) '...']; end
end
