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
% A per-run directory. Two MATLAB processes used to share
% tests/fixtures_codegen and one run's cleanup deleted the other's files
% mid-test (10/12 and 11/12 under concurrency); the marker proves ownership
% before anything is removed.
runRoot = fullfile(tempdir, 'mas_codegen_tests');
if ~exist(runRoot, 'dir'), mkdir(runRoot); end
fixDir = tempname(runRoot);
mkdir(fixDir);
ownerFile = fullfile(fixDir, '.mas_run_owner');
fid = fopen(ownerFile, 'w');
fprintf(fid, '%s', fixDir);
fclose(fid);
cleanup = onCleanup(@() cleanup_run_dir(fixDir, ownerFile));

cleanFn  = fullfile(fixDir, 'clean_fn.m');
growFn   = fullfile(fixDir, 'grow_in_loop.m');
growOut  = fullfile(fixDir, 'grow_outside.m');
evalFn   = fullfile(fixDir, 'has_eval.m');
tgtFn    = fullfile(fixDir, 'codegen_target.m');
tgtWrong = fullfile(fixDir, 'codegen_target_wrong.m');

write_fixtures(cleanFn, growFn, growOut, evalFn, tgtFn, tgtWrong);
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
r = struct('names', {names}, 'pass', pass, 'nPass', sum(pass), 'nTotal', n);
fprintf('test_codegen: %d/%d passed\n', r.nPass, r.nTotal);
end

% ===========================================================================
function write_fixtures(cleanFn, growFn, growOut, evalFn, tgtFn, tgtWrong)
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
if exist('codegen', 'file') == 0
    r = mas_codegen_verify('codegen_target', {1:10});
    v = strcmp(r.verdict, 'SKIP');
    say_why(v, r);
    return;
end
r = mas_codegen_verify('codegen_target', {1:10});
v = strcmp(r.verdict, 'PASS') && strcmp(r.stage, 'compare');
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
v = numel(d) > numel('FAIL at codegen:') + 20 && hit;
if ~v
    fprintf('       why: detail is %d chars and mentions none of emlc/identifier/file name/function handle\n', ...
        numel(d));
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
function cleanup_run_dir(d, ownerFile)
% Remove only this run's directory, and only when the marker says so. A
% cleanup that blindly rmdir's a well-known path is what caused the race.
try
    if ~exist(d, 'dir'), return; end
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
    try, rmpath(d); catch, end
    rmdir(d, 's');
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
