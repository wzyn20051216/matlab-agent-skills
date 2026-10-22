function A = benchmark_audit(repoRoot, holdoutRoot, manifestFile)
%BENCHMARK_AUDIT  Prove the agent-visible workspace does not contain the holdout.
%
%   A = benchmark_audit(repoRoot, holdoutRoot, manifestFile)
%
% Checks, in order:
%   1. the holdout root is OUTSIDE the repository (no path containment);
%   2. the manifest's task/answer hashes still match the frozen files;
%   3. no file under the repository is byte-identical to the sealed answers;
%   4. the holdout tasks and answers are complete and disjoint from the dev set.
%
% A failed check is recorded, never skipped; A.ok is true only if all pass.
% This is a procedural isolation proof: it can show the answers are not in the
% workspace, not that a determined process cannot read an absolute path.

checks = {};
repo = canonical(repoRoot);
holdout = canonical(holdoutRoot);
checks = addc(checks, 'holdoutOutsideRepo', ~startsWith(lower(holdout), [lower(repo) filesep]) && ...
    ~strcmpi(holdout, repo), sprintf('repo %s | holdout %s', repo, holdout));

A = struct();
if ~isfile(manifestFile)
    A.checks = [checks{:}]; A.ok = false; return;
end
M = jsondecode(fileread(manifestFile));
tasksFile = M.tasksFile; answersFile = M.answersFile;
if ~isfile(tasksFile) || ~isfile(answersFile)
    checks = addc(checks, 'filesExist', false, 'tasks or answers missing');
    A.checks = [checks{:}]; A.ok = false; return;
end
checks = addc(checks, 'filesExist', true, 'tasks and answers present');

hAns = sha256_file(answersFile);
checks = addc(checks, 'answersHash', strcmp(hAns, char(M.answersSha256)), ...
    sprintf('answers sha256 %s', hAns));
checks = addc(checks, 'tasksHash', strcmp(sha256_file(tasksFile), char(M.tasksSha256)), ...
    'tasks hash matches manifest');

% --- no byte-identical answer file anywhere under the repo ----------------
files = list_files(repo);
dup = {};
for k = 1:numel(files)
    try
        if strcmp(sha256_file(files{k}), hAns), dup{end+1} = files{k}; end %#ok<AGROW>
    catch
    end
end
checks = addc(checks, 'noAnswerCopy', isempty(dup), sprintf('%d byte-identical copy(ies)', numel(dup)));

% --- dev versus holdout ----------------------------------------------------
TF = jsondecode(fileread(tasksFile));
T = TF.tasks; if isstruct(T), T = num2cell(T(:)); end
htid = cellfun(@(s) char(s.id), T, 'UniformOutput', false);
devFile = fullfile(repo, 'benchmark', 'dev', 'tasks.json');
if isfile(devFile)
    DF = jsondecode(fileread(devFile));
    D = DF.tasks; if isstruct(D), D = num2cell(D(:)); end
    dtid = cellfun(@(s) char(s.id), D, 'UniformOutput', false);
    overlap = intersect(htid, dtid);
    checks = addc(checks, 'devHoldoutDisjoint', isempty(overlap), sprintf('%d overlapping id(s)', numel(overlap)));
else
    checks = addc(checks, 'devHoldoutDisjoint', false, 'dev task file missing');
end
checks = addc(checks, 'holdoutComplete', numel(htid) == M.nTasks && numel(unique(htid)) == numel(htid), ...
    sprintf('%d tasks, manifest says %d', numel(htid), M.nTasks));

A.schema = 'mas-benchmark-audit/1';
A.auditedAt = datestr(now, 31);
A.repoRoot = repo;
A.holdoutRoot = holdout;
A.checks = [checks{:}];
A.ok = all([A.checks.pass]);
end

% ===========================================================================
function C = addc(C, id, pass, detail)
if isnumeric(pass), pass = logical(pass); end
C{end+1} = struct('id', id, 'pass', pass, 'detail', detail);
end

function p = canonical(p)
p = char(java.io.File(p).getCanonicalPath());
p = strrep(p, '/', filesep);
end

function files = list_files(root)
files = {};
stack = {root};
skip = {'.git', 'node_modules'};
while ~isempty(stack)
    d = stack{end}; stack(end) = [];
    items = dir(d);
    for k = 1:numel(items)
        if items(k).isdir
            if any(strcmp(items(k).name, skip)) || strcmp(items(k).name, '.') || ...
                    strcmp(items(k).name, '..'), continue; end
            stack{end+1} = fullfile(items(k).folder, items(k).name); %#ok<AGROW>
        else
            files{end+1} = fullfile(items(k).folder, items(k).name); %#ok<AGROW>
        end
    end
end
end

function tf = is_binary(p)
[~, ~, ext] = fileparts(p);
tf = any(strcmpi(ext, {'.mat', '.slx', '.mexw64', '.png', '.jpg', '.pdf', '.zip', ...
    '.xlsx', '.fig', '.mdl', '.p'}));
end

function h = sha256_file(p)
fid = fopen(p, 'r');
if fid < 0, error('benchmark_audit:hash', 'cannot open %s', p); end
b = fread(fid, Inf, '*uint8'); fclose(fid);
md = java.security.MessageDigest.getInstance('SHA-256');
d = typecast(md.digest(b), 'uint8');
h = lower(reshape(dec2hex(d)', 1, []));
end
