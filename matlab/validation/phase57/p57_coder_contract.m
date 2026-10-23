function R = p57_coder_contract()
%P57_CODER_CONTRACT  Task 7 evidence for the Coder entry contract.
%
%   R = p57_coder_contract()
%
% Three entry shapes, three outcomes that must not be confused:
%   string file name  -> PASS through probe/codegen/build/run/compare
%   function handle   -> FAIL at codegen with the entry-form fix in the detail
%   link failure      -> FAIL at BUILD with the complete compiler log retained
%
% The third one matters: MATLAB reports it through the same
% emlc:compilationError with an EMPTY message as a rejected handle. Without the
% build log the tool would blame the entry form; the log is what distinguishes
% them. This script writes that log, byte for byte, to
% artifacts/phase57/task7/build_failure_compiler.log.
%
% No official MCP server code is touched; this drives the documented
% mas_codegen_verify entry point only. No new large codegen case is added.
%
% R.pass is false when the environment lacks Coder or a C compiler; the reason
% is recorded rather than turned into a PASS.
repo = fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
scripts = fullfile(repo, 'skills', 'matlab-codegen-deploy', 'scripts');
outDir = fullfile(repo, 'artifacts', 'phase57', 'task7');
if ~isfolder(outDir), mkdir(outDir); end
addpath(scripts);
fixture = tempname;
mkdir(fixture);
addpath(fixture);
fixtureCleanup = onCleanup(@() remove_fixture(fixture));

write_fn(fullfile(fixture, 'p57_cg_ok.m'), ...
    'function y = p57_cg_ok(x)\ny = x.^2 + sin(x) + 1;\nend\n');
write_fn(fullfile(fixture, 'p57_build_fail.m'), ...
    ['function y = p57_build_fail(x)\n' ...
     'coder.ceval(''mas_undefined_symbol_xyz'', int32(1));\n' ...
     'y = x + 1;\nend\n']);

R = struct();
R.generatedAt = datestr(now, 'yyyy-mm-dd HH:MM:SS');
R.matlabVersion = version;
R.compiler = '';
R.status = 'RUN';
R.entries = struct();
R.pass = false;

try
    cc = mex.getCompilerConfigurations('C');
    if ~isempty(cc), R.compiler = cc(1).Name; end
catch
end
if exist('codegen', 'file') == 0 || isempty(R.compiler)
    R.status = 'SKIP';
    R.reason = 'MATLAB Coder or a configured C compiler is unavailable';
    save_evidence(R, outDir);
    fprintf('p57_coder_contract: SKIP (%s)\n', R.reason);
    return;
end

% 1. Supported entry: string file name. keep=true is exercised here so the
%    retained build tree can be checked, then removed by the caller.
r1 = mas_codegen_verify('p57_cg_ok', {1:5}, struct('keep', true));
logs = r1.compilerLog;
okLog = ~isempty(logs) && any(~cellfun(@isempty, ...
    regexpi({logs.name}, 'buildLog\.log$'))) && all(cellfun(@(t) ~isempty(t), {logs.text}));
okKept = isfolder(r1.buildDir) && logical(r1.buildDirRetained);
ok1 = strcmp(r1.verdict, 'PASS') && strcmp(r1.stage, 'compare') && okLog && okKept;
R.entries.stringFileName = summarize(r1, ok1);
R.entries.stringFileName.buildDirRetained = okKept;
R.entries.stringFileName.compilerLogBytes = sum([logs.bytes]);
if okKept, try, rmdir(r1.buildDir, 's'); catch, end; end

% 2. Unsupported entry: function handle.
bad = mas_codegen_verify(@(x) x * 2 + sin(x), {0.5});
handleDetail = strtrim(char(bad.detail));
handleOk = strcmp(bad.verdict, 'FAIL') && strcmp(bad.stage, 'codegen') && ...
    ~isempty(strfind(lower(handleDetail), 'function handle')) && ...
    ~isempty(strfind(handleDetail, 'emlc'));
R.entries.functionHandle = summarize(bad, handleOk);
R.entries.functionHandle.detail = handleDetail;

% 3. Real build/link failure: the compiler log must survive cleanup.
bf = mas_codegen_verify('p57_build_fail', {1});
bfLogs = bf.compilerLog;
bfText = '';
sourceBytes = 0;
if ~isempty(bfLogs)
    [~, idx] = max([bfLogs.bytes]);
    bfText = bfLogs(idx).text;
    sourceBytes = bfLogs(idx).bytes;
end
logFile = fullfile(outDir, 'build_failure_compiler.log');
onDiskBytes = 0;
if ~isempty(bfText)
    fid = fopen(logFile, 'w');
    if fid >= 0
        % uint8, not 'char': the latter applies a text encoding and can expand
        % bytes above 127, so the copy would no longer be the compiler's log.
        fwrite(fid, uint8(bfText), 'uint8');
        fclose(fid);
    end
    d = dir(logFile);
    if ~isempty(d), onDiskBytes = d(1).bytes; end
else
    logFile = '';
end
byteExact = ~isempty(bfText) && onDiskBytes == numel(bfText) && numel(bfText) == sourceBytes;
bfOk = strcmp(bf.verdict, 'FAIL') && strcmp(bf.stage, 'build') && ...
    ~isempty(regexpi(bfText, 'LNK\d+|fatal error', 'once')) && ...
    ~isfolder(bf.buildDir) && byteExact;
R.entries.linkFailure = summarize(bf, bfOk);
R.entries.linkFailure.logCount = numel(bfLogs);
R.entries.linkFailure.compilerLogFile = logFile;
R.entries.linkFailure.compilerLogBytes = numel(bfText);
R.entries.linkFailure.compilerLogBytesOnDisk = onDiskBytes;
R.entries.linkFailure.sourceLogBytes = sourceBytes;
R.entries.linkFailure.byteExact = byteExact;
R.entries.linkFailure.compilerLogSha256 = sha256_file(logFile);
R.entries.linkFailure.buildDirRemoved = ~isfolder(bf.buildDir);

R.pass = ok1 && handleOk && bfOk;
R.status = ternary(R.pass, 'PASS', 'FAIL');
save_evidence(R, outDir);
fprintf('p57_coder_contract: %s (string=%d handle=%d link=%d)\n', ...
    R.status, ok1, handleOk, bfOk);
end

% ===========================================================================
function S = summarize(r, check)
S = struct('verdict', r.verdict, 'stage', r.stage, ...
    'detail', strtrim(char(r.detail)), 'check', logical(check));
S.errorIdentifier = '';
if isfield(r, 'errorIdentifier'), S.errorIdentifier = r.errorIdentifier; end
S.returnedSession = '';
if isfield(r, 'session'), S.returnedSession = r.session; end
end

function save_evidence(R, outDir)
f = fullfile(outDir, 'coder_contract.json');
fid = fopen(f, 'w');
if fid >= 0
    fprintf(fid, '%s', jsonencode(R, 'PrettyPrint', true));
    fclose(fid);
end
end

function write_fn(p, txt)
fid = fopen(p, 'w');
if fid < 0, error('p57_coder_contract:write', 'cannot write %s', p); end
fprintf(fid, '%s', strrep(txt, '\n', newline));
fclose(fid);
end

function remove_fixture(d)
try
    if isfolder(d), rmpath(d); rmdir(d, 's'); end
catch
end
end

function h = sha256_file(p)
h = '';
if isempty(p) || ~isfile(p), return; end
fid = fopen(p, 'r');
if fid < 0, return; end
b = fread(fid, Inf, '*uint8');
fclose(fid);
if isempty(b), return; end
md = java.security.MessageDigest.getInstance('SHA-256');
d = typecast(md.digest(b), 'uint8');
h = lower(reshape(dec2hex(d)', 1, []));
end

function s = ternary(c, a, b)
if c, s = a; else, s = b; end
end
