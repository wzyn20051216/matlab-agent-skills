function S = benchmark_seal(publishManifestFile, tasksFile, referenceFile, evalDir, episodesFile)
%BENCHMARK_SEAL  Phase two of the two-phase seal: create the answers, then freeze.
%
%   S = benchmark_seal(publishManifestFile, tasksFile, referenceFile, evalDir, episodesFile)
%
% Run on the evaluation side AFTER every episode has finished. Four things are
% enforced, in this order:
%
%   1. the task file still hashes to what was published (no silent re-write of a
%      prompt after seeing how an arm behaved);
%   2. the reference implementation still hashes to the value committed at
%      publish time (no post-hoc fitting of expectations to results);
%   3. every declared episode is present and FINISHED, and the seal timestamp is
%      later than the last finish time (so answers cannot be generated midway
%      and reused);
%   4. no answers file exists yet -- sealing is single-use per bundle.
%
% Then reference_p56.m derives the expectations from closed forms, a frozen
% task/answer pair is written, and benchmark_freeze.m seals both hashes.
%
% The seal is a proof about ordering, not about access: it shows the arm could
% not have read an answer key because none existed while it ran.

P = jsondecode(fileread(publishManifestFile));
if ~strcmp(char(P.phase), 'PUBLISHED')
    error('benchmark_seal:phase', 'publish manifest says phase %s', char(P.phase));
end
if ~strcmp(sha256_file(tasksFile), char(P.tasksSha256))
    error('benchmark_seal:tamper', 'tasks file changed after publish');
end
if ~isfield(P, 'referenceCommitted') || ~P.referenceCommitted
    error('benchmark_seal:noCommitment', 'publish did not commit a reference hash');
end
if ~strcmp(sha256_file(referenceFile), char(P.referenceSha256))
    error('benchmark_seal:commitment', ['reference implementation changed after publish: ' ...
        'expectations would no longer be pre-registered']);
end

TF = jsondecode(fileread(tasksFile));
T = TF.tasks; if isstruct(T), T = num2cell(T(:)); end
ids = cellfun(@(s) char(s.id), T, 'UniformOutput', false);

% ---- episodes must all be finished before sealing -------------------------
if isempty(episodesFile) || ~isfile(episodesFile)
    error('benchmark_seal:noEpisodes', ['an episodes file listing every completed episode is ' ...
        'required; refusing to seal answers that could be generated before the runs']);
end
E = jsondecode(fileread(episodesFile));
EP = E.episodes; if isstruct(EP), EP = num2cell(EP(:)); end
if isempty(EP), error('benchmark_seal:noEpisodes', 'episodes file is empty'); end
fin = {};
for k = 1:numel(EP)
    if ~isfield(EP{k}, 'finishedAt') || isempty(EP{k}.finishedAt)
        error('benchmark_seal:unfinished', 'episode %d has no finishedAt', k);
    end
    fin{end+1} = char(EP{k}.finishedAt); %#ok<AGROW>
end
lastFinish = char(max(datetime(fin, 'InputFormat', 'yyyy-MM-dd HH:mm:ss')));
sealAt = datetime('now');
sealTime = datestr(sealAt, 31);
if sealAt <= datetime(lastFinish, 'InputFormat', 'yyyy-MM-dd HH:mm:ss')
    error('benchmark_seal:order', 'last episode finished at %s, not before the seal at %s', ...
        lastFinish, sealTime);
end
missingIds = setdiff(ids, unique(cellfun(@(s) char(s.task), EP, 'UniformOutput', false)));
if ~isempty(missingIds)
    error('benchmark_seal:coverage', 'no episode recorded for %s', strjoin(missingIds, ', '));
end

% ---- single-use -----------------------------------------------------------
if ~isfolder(evalDir), mkdir(evalDir); end
answersFile = fullfile(evalDir, 'answers.json');
if isfile(answersFile)
    error('benchmark_seal:replay', '%s already exists; a bundle is sealed once', answersFile);
end

A = reference_p56(tasksFile, answersFile);
AT = A.tasks; if isstruct(AT), AT = num2cell(AT(:)); end

% benchmark_freeze.m grades the old single-phase schema, which wants the route
% expectation on the task side too. Re-join it here, at seal time, from the
% answers: the published task file stays route-free.
frozenT = struct(); frozenT.tasks = {};
for k = 1:numel(T)
    q = find(cellfun(@(s) strcmp(char(s.id), ids{k}), AT));
    if numel(q) ~= 1
        error('benchmark_seal:answer', 'answers cover %s %d times', ids{k}, numel(q));
    end
    a = AT{q};
    t = T{k};
    t.skill = a.skill; t.tool = a.tool;
    frozenT.tasks{end+1} = t; %#ok<AGROW>
end
tasksFrozen = fullfile(evalDir, 'tasks_frozen.json');
fid = fopen(tasksFrozen, 'w');
if fid < 0, error('benchmark_seal:write', 'cannot write %s', tasksFrozen); end
fwrite(fid, jsonencode(frozenT), 'char'); fclose(fid);

manifestFile = fullfile(evalDir, 'manifest.json');
M = benchmark_freeze(tasksFrozen, answersFile, manifestFile); %#ok<NASGU>

S = struct();
S.schema = 'mas-benchmark-seal/1';
S.phase = 'SEALED';
S.sealedAt = sealTime;
S.lastEpisodeFinishedAt = lastFinish;
S.nEpisodes = numel(EP);
S.tasksPublishedSha256 = char(P.tasksSha256);
S.referenceSha256 = char(P.referenceSha256);
S.answersFile = answersFile;
S.answersSha256 = sha256_file(answersFile);
S.tasksFrozenFile = tasksFrozen;
S.verdicts = cellfun(@(s) char(s.verdict), AT, 'UniformOutput', false);
S.fieldNames = cellfun(@(s) strjoin({s.fields.name}, '+'), AT, 'UniformOutput', false);
S.meaning = ['answers existed only after the last episode: an arm could not have read them, ' ...
    'and the expectations were fixed by hash before the first one ran'];
S.limitation = ['this proves ordering and pre-registration, not access control. See ' ...
    'docs/PHASE5_6_ISOLATION_ZH.md: strong isolation on this host is BLOCKED.'];
fid = fopen(fullfile(evalDir, 'seal_manifest.json'), 'w');
fwrite(fid, jsonencode(S), 'char'); fclose(fid);

fprintf('sealed after %d episodes (last finish %s)\n', S.nEpisodes, lastFinish);
fprintf('  answers sha256 %s\n', S.answersSha256);
end

% ===========================================================================
function h = sha256_file(p)
fid = fopen(p, 'r');
if fid < 0, error('benchmark_seal:hash', 'cannot open %s', p); end
b = fread(fid, Inf, '*uint8'); fclose(fid);
md = java.security.MessageDigest.getInstance('SHA-256');
d = typecast(md.digest(b), 'uint8');
h = lower(reshape(dec2hex(d)', 1, []));
end
