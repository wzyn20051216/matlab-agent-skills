%P57_ISOLATION_PROBE  Read-only probe of the shared MATLAB session and answer
%derivability for Phase 5.7 Task 4.
%
%   Run through the same MCP evaluate channel an arm would use. It records:
%     - the identity and host shell behind that channel;
%     - whether repo tools are already resolvable from the session path;
%     - whether the session keeps state between calls (canary is set/read by
%       the orchestrator in two separate calls and cleared afterwards);
%     - whether the sealed Phase 5.6 answers can be regenerated from reachable
%       artifacts (the reference generator) -- reported as a boolean and a
%       hash comparison, never as answer values.
%
% It adds benchmark/ to the path only for the duration of the derivation check
% and removes it again. No file in the repository is written except this
% report. pwd is restored to the neutral Documents folder afterwards.

probeHere = fileparts(mfilename('fullpath'));
repoRoot = fileparts(fileparts(fileparts(probeHere)));
outFile = fullfile(repoRoot, 'artifacts', 'phase57', 'isolation', 'matlab_state.json');
if exist(fullfile(repoRoot, 'artifacts', 'phase57', 'isolation'), 'dir') ~= 7
    mkdir(fullfile(repoRoot, 'artifacts', 'phase57', 'isolation'));
end

p57probe_R = struct();
p57probe_R.schema = 'mas-phase57-matlab-state/1';
p57probe_R.generatedAt = datestr(now, 31);
p57probe_R.readOnly = true;
p57probe_R.answerContentDisclosed = false;
p57probe_R.persistentChanges = {'none; path entry for benchmark/ added and removed; pwd restored'};

% --- identity of the process behind the execution channel -----------------
p57probe_R.session = struct( ...
    'matlabVersion', version, ...
    'computer', computer, ...
    'pwd', pwd, ...
    'prefdir', prefdir, ...
    'user', getenv('USERNAME'), ...
    'userprofile', getenv('USERPROFILE'), ...
    'computerName', getenv('COMPUTERNAME'));

[p57probe_whoRc, p57probe_who] = system('whoami');
p57probe_R.commandExecution = struct( ...
    'call', 'system(''whoami'')', ...
    'rc', p57probe_whoRc, ...
    'stdout', strtrim(p57probe_who), ...
    'hostShellReachable', p57probe_whoRc == 0 && ~isempty(strtrim(p57probe_who)));

% --- path and tool resolution --------------------------------------------
p57probe_entries = strsplit(path, pathsep);
p57probe_needle = {fullfile(repoRoot, 'skills'), fullfile(repoRoot, 'benchmark'), ...
    'MATLAB-bench'};
p57probe_hits = {};
for p57probe_k = 1:numel(p57probe_entries)
    for p57probe_q = 1:numel(p57probe_needle)
        if contains(p57probe_entries{p57probe_k}, p57probe_needle{p57probe_q})
            p57probe_hits{end+1} = p57probe_entries{p57probe_k}; %#ok<SAGROW>
            break;
        end
    end
end
p57probe_names = {'mas_ber_check', 'mas_ode_check', 'mas_grade', 'mas_refcheck'};
p57probe_tools = struct('name', {}, 'resolved', {}, 'paths', {});
for p57probe_k = 1:numel(p57probe_names)
    p57probe_p = which(p57probe_names{p57probe_k}, '-all');
    if ischar(p57probe_p), p57probe_p = {p57probe_p}; end
    p57probe_tools(end+1) = struct('name', p57probe_names{p57probe_k}, ...
        'resolved', ~isempty(p57probe_p), 'paths', {p57probe_p});
end
p57probe_R.path = struct( ...
    'nEntries', numel(p57probe_entries), ...
    'repoOrEvalEntries', {p57probe_hits}, ...
    'toolResolution', {p57probe_tools});

% --- preference history (disk state) -------------------------------------
p57probe_hf = fullfile(prefdir, 'History.xml');
p57probe_hist = struct('path', p57probe_hf, 'exists', exist(p57probe_hf, 'file') == 2, ...
    'bytes', 0, 'masMentions', 0, 'phase56Mentions', 0);
if p57probe_hist.exists
    p57probe_d = dir(p57probe_hf);
    p57probe_hist.bytes = p57probe_d.bytes;
    p57probe_txt = fileread(p57probe_hf);
    p57probe_hist.masMentions = count(p57probe_txt, 'mas_');
    p57probe_hist.phase56Mentions = count(lower(p57probe_txt), 'phase56');
end
p57probe_R.preferenceHistory = p57probe_hist;

% --- base workspace reachability -----------------------------------------
p57probe_base = evalin('base', 'who');
p57probe_R.baseWorkspace = struct( ...
    'nVars', numel(p57probe_base), ...
    'note', 'the probe runs in the same workspace an arm call uses; this count includes the probe''s own variables');

% --- derivability of the sealed answers ----------------------------------
p57probe_R.derivation = p57probe_derive(repoRoot);

try
    cd(fullfile(getenv('USERPROFILE'), 'Documents'));
catch
    % keep the runner's cwd if Documents is unavailable
end
p57probe_R.cwdAfterProbe = pwd;
p57probe_fid = fopen(outFile, 'w');
if p57probe_fid < 0
    error('p57_isolation_probe:write', 'cannot write %s', outFile);
end
fwrite(p57probe_fid, jsonencode(p57probe_R, 'PrettyPrint', true), 'char');
fclose(p57probe_fid);

fprintf('WROTE %s\n', outFile);
fprintf('HOST_SHELL=%d USER=%s\n', p57probe_R.commandExecution.hostShellReachable, ...
    p57probe_R.commandExecution.stdout);
fprintf('PATH_HITS=%d MAS_RESOLVED=%d\n', numel(p57probe_hits), ...
    sum([p57probe_tools.resolved]));
fprintf('DERIVED=%d MATCH=%d TASKS=%d\n', p57probe_R.derivation.recomputed, ...
    p57probe_R.derivation.match, p57probe_R.derivation.nTasks);

% Leave the shared session as clean as we found it.
clear p57probe_* outFile probeHere repoRoot

% ===========================================================================
function D = p57probe_derive(repoRoot)
% Regenerate the sealed answers with the reachable generator and compare the
% payload. Only booleans, counts and hashes leave this function.
D = struct('generator', fullfile(repoRoot, 'benchmark', 'reference_p56.m'), ...
    'tasks', fullfile(repoRoot, 'benchmark', 'tasks_p56.json'), ...
    'sealedAnswers', '', 'generatorSha256', '', 'sealedSha256', '', ...
    'recomputed', false, 'match', false, 'nTasks', 0, 'mismatch', '', ...
    'tempDeleted', false);
D.generatorSha256 = p57probe_sha(D.generator);
candidates = {fullfile(fileparts(repoRoot), 'MATLAB-bench-phase56', 'eval', 'answers.json')};
for k = 1:numel(candidates)
    if exist(candidates{k}, 'file') == 2
        D.sealedAnswers = candidates{k};
        break;
    end
end
if isempty(D.sealedAnswers)
    D.mismatch = 'sealed answers not found';
    return;
end
D.sealedSha256 = p57probe_sha(D.sealedAnswers);

benchDir = fullfile(repoRoot, 'benchmark');
already = contains([pathsep path pathsep], [pathsep benchDir pathsep]);
if ~already, addpath(benchDir); end
tmp = [tempname '.json'];
try
    A = reference_p56(D.tasks, tmp);
    B = jsondecode(fileread(D.sealedAnswers));
    D.recomputed = true;
    [p57probe_ok, p57probe_why, p57probe_n] = p57probe_same(A.tasks, B.tasks);
    D.match = p57probe_ok;
    D.mismatch = p57probe_why;
    D.nTasks = p57probe_n;
catch err
    D.mismatch = ['derivation error: ' err.identifier];
end
if exist(tmp, 'file') == 2, delete(tmp); end
D.tempDeleted = exist(tmp, 'file') ~= 2;
if ~already, rmpath(benchDir); end
end

function [ok, why, n] = p57probe_same(A, B)
if iscell(A) && ~isempty(A) && isstruct(A{1}), A = [A{:}]; end
if iscell(B) && ~isempty(B) && isstruct(B{1}), B = [B{:}]; end
ok = false; why = ''; n = numel(A);
if numel(A) ~= numel(B)
    why = 'task count differs';
    return;
end
for k = 1:numel(A)
    id = char(A(k).id);
    idx = find(strcmp({B.id}, id), 1);
    if isempty(idx)
        why = ['missing task ' id];
        return;
    end
    b = B(idx);
    if ~strcmp(char(A(k).skill), char(b.skill)) || ...
       ~strcmp(char(A(k).tool), char(b.tool)) || ...
       ~strcmp(char(A(k).verdict), char(b.verdict))
        why = ['header differs for ' id];
        return;
    end
    fa = A(k).fields; fb = b.fields;
    if numel(fa) ~= numel(fb)
        why = ['field count differs for ' id];
        return;
    end
    for j = 1:numel(fa)
        if ~strcmp(char(fa(j).name), char(fb(j).name)) || ...
           ~strcmp(char(fa(j).op), char(fb(j).op)) || ...
           ~isequaln(fa(j).ref, fb(j).ref) || ...
           ~isequaln(fa(j).tol, fb(j).tol)
            why = ['field differs for ' id];
            return;
        end
    end
end
ok = true;
end

function h = p57probe_sha(p)
fid = fopen(p, 'r');
if fid < 0, error('p57_isolation_probe:sha', 'cannot read %s', p); end
md = java.security.MessageDigest.getInstance('SHA-256');
while true
    b = fread(fid, 65536, '*uint8');
    if isempty(b), break; end
    md.update(b);
end
fclose(fid);
h = sprintf('%02x', typecast(md.digest(), 'uint8'));
end
