function r = mas_bench_record(action, opt, outDir)
%MAS_BENCH_RECORD  Machine-readable benchmark ledger for R1 / R2 / R3.
%
%   r = mas_bench_record('collect')            % gather every R1 report found
%   r = mas_bench_record('collect','latest')   % newest report only
%   r = mas_bench_record('session')            % what THIS session can reach
%   r = mas_bench_record('report')             % full ledger + honest verdict
%   r = mas_bench_record('report', 0)          % declare 0 mcp__matlab* tools bound
%   r = mas_bench_record('report', 0, d)       % write the ledger into folder d
%
% `matlab -batch` CANNOT see which MCP tools the host agent has. Passing the
% count as a second argument is how that fact gets in; without it the R2/R3
% verdict is UNKNOWN, never a guessed SKIP.
%
% `outDir` exists so a test run does not litter the benchmark folder with a
% ledger per assertion. Reports always go under artifacts/validation/benchmark.
%
%   r.runs      struct array of R1 runs found under artifacts/validation/benchmark
%   r.r1        struct: status, nRuns, bestRun, evidence
%   r.r2        struct: status, reason, evidence
%   r.r3        struct: status, reason, evidence
%   r.overall   'PASS' | 'PARTIAL' -- never 'PASS' unless all three are DONE
%
% WHY A LEDGER AND NOT A LINE IN THE REPORT
% Three failure modes make a prose claim worthless:
%
%   1. SKIP quietly becoming PASS. "R2/R3: N/A" next to a green overall number
%      reads as "everything ran". Here a SKIP is a first-class state and
%      `overall` can never be PASS while any of R1/R2/R3 is SKIP.
%   2. SKIP for the wrong reason. "no MCP" is ambiguous between the server
%      being absent from the machine and the server being absent from THIS
%      conversation. Those need different fixes -- install vs bind -- so
%      `r.r2.reason` is one of a fixed set and `evidence` says which.
%   3. A benchmark that cannot be re-run. Each R1 run carries the file it came
%      from and its SHA-256, so a claim in a report can be traced to bytes.

if nargin < 1, action = 'report'; end
if nargin < 2, opt = []; end
if nargin < 3, outDir = ''; end

here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
benchDir = fullfile(repo, 'artifacts', 'validation', 'benchmark');
if ~exist(benchDir, 'dir'), mkdir(benchDir); end
writeDir = benchDir;
if ~isempty(outDir)
    if ~exist(outDir, 'dir'), mkdir(outDir); end
    writeDir = outDir;
end

switch lower(action)
    case 'collect'
        r = collect_runs(benchDir, ischar(opt) && strcmpi(opt, 'latest'), repo);
    case 'session'
        r = probe_session(numeric_opt(opt));
    case 'report'
        runs = collect_runs(benchDir, true, repo);
        sess = probe_session(numeric_opt(opt));
        r = build_ledger(runs, sess, repo);
        r.ledgerFile = write_json(r, writeDir);
    otherwise
        error('mas_bench_record:action', 'unknown action "%s"', action);
end
end

function v = numeric_opt(opt)
if isnumeric(opt) && isscalar(opt)
    v = double(opt);
else
    v = [];
end
end

% ===========================================================================
function runs = collect_runs(benchDir, latestOnly, repo)
files = dir(fullfile(benchDir, 'benchmark_report_*.json'));
runs = struct('file', {}, 'sha256', {}, 'generatedAt', {}, 'overallStatus', {}, ...
    'nTasks', {}, 'nPassed', {}, 'nChecks', {}, 'nChecksPassed', {}, ...
    'nToolCalls', {}, 'serverStartOk', {}, 'handshakeOk', {}, 'tools', {});
for k = 1:numel(files)
    f = fullfile(files(k).folder, files(k).name);
    try
        d = jsondecode(fileread(f));
    catch
        continue;                      % a truncated report must not kill the ledger
    end
    if ~isfield(d, 'benchmarks') || ~isfield(d, 'summary'), continue; end
    s = d.summary;
    tk = {};
    if isfield(d, 'discoveredTools')
        v = d.discoveredTools;
        if iscell(v), tk = v; elseif isstring(v), tk = cellstr(v); end
    end
    runs(end+1) = struct( ...
        'file', short_path(f, repo), ...
        'sha256', file_sha256(f), ...
        'generatedAt', tern(isfield(d, 'generatedAt'), d.generatedAt, ''), ...
        'overallStatus', tern(isfield(d, 'overallStatus'), d.overallStatus, 'UNKNOWN'), ...
        'nTasks', geti(s, 'benchmarkTotal'), ...
        'nPassed', geti(s, 'benchmarkPassed'), ...
        'nChecks', geti(s, 'totalChecks'), ...
        'nChecksPassed', geti(s, 'passedChecks'), ...
        'nToolCalls', geti(s, 'totalToolCalls'), ...
        'serverStartOk', getb(d, 'serverStartOk'), ...
        'handshakeOk', getb(d, 'handshakeOk'), ...
        'tools', {tk});
end
if latestOnly && ~isempty(runs)
    % runs is a struct array, not a cell array. ISO-8601 timestamps sort
    % lexicographically in chronological order, and an empty timestamp sorts
    % first so a malformed report never wins "latest".
    ts = {runs.generatedAt};
    [~, ord] = sort(ts);
    runs = runs(ord(end));
end
end

% ===========================================================================
function s = probe_session(declared)
% What THIS conversation can actually reach. The distinction that matters:
% the server binary being on disk is an environment fact; the tools being
% callable here is a session fact. Only the second one gates R2/R3.
%
% A MATLAB process CANNOT enumerate the host agent's tool bindings. So this does
% not pretend to know: it returns 'unknown' unless the caller declares the count.
% Reporting a hard 0 from here would be a fabricated negative -- the exact
% failure mode this whole framework exists to prevent.
if nargin < 1, declared = []; end
s = struct();
s.mcpMatlabToolCount = 'unknown';
s.countSource = 'not observable from inside a MATLAB process';
if ~isempty(declared)
    s.mcpMatlabToolCount = double(declared);
    s.countSource = 'declared by the calling agent, which CAN see its own tools';
end
s.serverBinaryOnDisk = has_server_binary();
if strcmp(s.mcpMatlabToolCount, 'unknown')
    s.detail = sprintf(['matlab MCP tool count: UNKNOWN from inside MATLAB ' ...
        '(a MATLAB process cannot see the host agent''s tool bindings); ' ...
        'server binary on disk: %d'], s.serverBinaryOnDisk);
else
    s.detail = sprintf('%d matlab MCP tool(s) callable in this session (%s); server binary on disk: %d', ...
        s.mcpMatlabToolCount, s.countSource, s.serverBinaryOnDisk);
end
end

function tf = has_server_binary()
persistent cached
if ~isempty(cached), tf = cached; return; end
hereDir = fileparts(mfilename('fullpath'));
repoDir = fileparts(fileparts(fileparts(hereDir)));
cands = dir(fullfile(repoDir, 'bin', 'matlab-mcp-server*'));
tf = ~isempty(cands);
cached = tf;
end

% ===========================================================================
function r = build_ledger(runs, sess, repo)
r = struct();
r.schema = 'mas-benchmark-ledger/1';
r.generatedAt = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
r.matlabVersion = version;

% ---- R1: agent + CLI, through the real MCP server --------------------
if isempty(runs)
    r.r1 = struct('status', 'SKIP', 'reason', 'NO_REPORT_FOUND', ...
        'evidence', sprintf('no benchmark_report_*.json under %s', short_path(benchDir_of(repo), repo)), ...
        'nRuns', 0);
else
    ok = strcmp({runs.overallStatus}, 'PASS');
    best = runs(find(ok, 1, 'first'));
    r.r1 = struct('status', tern(any(ok), 'DONE', 'FAIL'), ...
        'nRuns', numel(runs), 'nRunsPassing', nnz(ok), ...
        'bestRun', best.file, 'sha256', best.sha256, ...
        'evidence', sprintf('%d/%d task(s), %d/%d checks, %d tool call(s), handshake=%d', ...
            best.nPassed, best.nTasks, best.nChecksPassed, best.nChecks, ...
            best.nToolCalls, best.handshakeOk), ...
        'runs', runs);
end

% ---- R2 / R3: need callable MCP tools in THIS session ------------------
nTools = sess.mcpMatlabToolCount;
if ischar(nTools)
    % Unknown must not collapse into either verdict. If a caller can see its own
    % tools (an agent can; a MATLAB process cannot) it should pass the count via
    % opt, e.g. mas_bench_record('report', 0) when it has confirmed there are none.
    r2r = 'SESSION_TOOL_COUNT_UNKNOWN';
    ev = sprintf(['The number of mcp__matlab* tools bound to this session cannot be ' ...
        'determined from inside a MATLAB process, so R2/R3 are UNKNOWN rather than ' ...
        'SKIP. Server binary on disk: %d. Re-run from an agent that can see its own ' ...
        'tool list and pass the count to convert this into a real SKIP.'], ...
        sess.serverBinaryOnDisk);
    r2s = 'UNKNOWN';
elseif nTools == 0
    r2r = 'NO_MATLAB_MCP_TOOL_IN_SESSION';
    ev = sprintf(['0 mcp__matlab* tool is callable in this conversation (%s). ' ...
        'The server binary IS present on disk (%d), so this is a BINDING gap, ' ...
        'not a missing install. Fix by binding the MCP server to the session, ' ...
        'not by reinstalling.'], sess.countSource, sess.serverBinaryOnDisk);
    r2s = 'SKIP';
else
    r2r = 'TOOLS_AVAILABLE_NOT_EXERCISED';
    ev = sprintf('%d matlab MCP tool(s) present (%s); this build does not drive them', ...
        nTools, sess.countSource);
    r2s = 'NOT_RUN';
end
r.r2 = struct('status', r2s, 'reason', r2r, 'evidence', ev);
r.r3 = struct('status', r2s, 'reason', r2r, 'evidence', ev);

st = {r.r1.status, r.r2.status, r.r3.status};
if all(strcmp(st, 'DONE')), r.overall = 'PASS';
elseif any(strcmp(st, 'SKIP')), r.overall = 'PARTIAL';
else, r.overall = 'PARTIAL'; end
% A SKIP can never be laundered into a PASS, whatever the arithmetic above says.
if ~strcmp(r.r1.status, 'DONE'), r.overall = 'PARTIAL'; end

r.session = sess;
r.honesty = struct( ...
    'planningLayer', 'R1 报告声明为规则路由 + 固定步骤序列，不是 LLM 自主规划', ...
    'skipIsNotPass', 'R2/R3 为 SKIP 时 overall 只能是 PARTIAL', ...
    'bindingVsInstall', 'server 二进制在盘上但会话未绑定工具 => BINDING gap，不是缺安装');
r.verdict = sprintf('R1 %s | R2 %s | R3 %s -> %s', r.r1.status, r.r2.status, ...
    r.r3.status, r.overall);
end

function d = benchDir_of(repo)
d = fullfile(repo, 'artifacts', 'validation', 'benchmark');
end

% ===========================================================================
function f = write_json(r, benchDir)
f = '';
out = r; out = rmfield_safe(out);
if isfield(r, 'ledgerFile'), out = rmfield(out, 'ledgerFile'); end
f = fullfile(benchDir, sprintf('benchmark_ledger_%s.json', ...
    char(datetime('now', 'Format', 'yyyyMMdd-HHmmss'))));
fid = fopen(f, 'w');
if fid < 0, f = ''; return; end
try
    fwrite(fid, jsonencode(out, 'PrettyPrint', true), 'char');
catch
    % jsonencode rejects complex values and some handles; a plain dump is
    % better than losing the ledger because one field was not encodable.
    fwrite(fid, jsonencode(out), 'char');
end
fclose(fid);
end

function s = rmfield_safe(s)
for f = fieldnames(s)'
    v = s.(f{1});
    if isnumeric(v) && ~isreal(v), s.(f{1}) = real(v); end
end
end

% ===========================================================================
function h = file_sha256(p)
try
    md = java.security.MessageDigest.getInstance('SHA-256');
    fid = fopen(p, 'r');
    d = md.digest(fread(fid, inf, 'uint8=>uint8').');
    fclose(fid);
    h = lower(reshape(dec2hex(typecast(d, 'uint8'), 2).', 1, []));
catch
    h = '';
end
end

function p = short_path(p, repo)
p = strrep(p, [repo filesep], '');
p = strrep(p, repo, '');
end

function v = geti(s, f)
v = 0;
if isstruct(s) && isfield(s, f) && isnumeric(s.(f)), v = double(s.(f)); end
end

function v = getb(d, f)
v = false;
if isfield(d, f) && (islogical(d.(f)) || isnumeric(d.(f))), v = logical(d.(f)); end
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end