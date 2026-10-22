function manifest = benchmark_freeze(tasksFile, answersFile, manifestFile)
%BENCHMARK_FREEZE  Seal tasks and answers before any evaluation run.
%
%   manifest = benchmark_freeze(tasksFile, answersFile, manifestFile)
%
% Refuses to freeze when the two files do not describe exactly the same tasks,
% or when any task/answer is missing a field the grader needs. The manifest
% stores SHA-256 hashes; benchmark_grade.m refuses to grade if either file
% changed after this call. Run this on the evaluation side.

TF = jsondecode(fileread(tasksFile));
AF = jsondecode(fileread(answersFile));
T = TF.tasks; if isstruct(T), T = num2cell(T(:)); end
A = AF.tasks; if isstruct(A), A = num2cell(A(:)); end
if isempty(T) || isempty(A), error('benchmark_freeze:empty', 'need non-empty tasks and answers'); end

tid = cellfun(@(s) char(s.id), T, 'UniformOutput', false);
aid = cellfun(@(s) char(s.id), A, 'UniformOutput', false);
if numel(unique(tid)) ~= numel(tid), error('benchmark_freeze:dup', 'duplicate task id'); end
if numel(unique(aid)) ~= numel(aid), error('benchmark_freeze:dup', 'duplicate answer id'); end
if ~isempty(setxor(tid, aid))
    error('benchmark_freeze:cover', 'tasks/answers differ: %s', ...
        strjoin(setxor(tid, aid), ', '));
end

requiredT = {'id','domain','kind','prompt','skill','tool','fixture','report'};
for k = 1:numel(T)
    for q = 1:numel(requiredT)
        if ~isfield(T{k}, requiredT{q}) || isempty(T{k}.(requiredT{q}))
            error('benchmark_freeze:task', 'task %s misses %s', tid{k}, requiredT{q});
        end
    end
    if ~any(strcmp(char(T{k}.kind), {'normal','boundary','fault'}))
        error('benchmark_freeze:kind', 'task %s has kind %s', tid{k}, char(T{k}.kind));
    end
end
requiredA = {'id','skill','tool','verdict','fields'};
for k = 1:numel(A)
    for q = 1:numel(requiredA)
        if ~isfield(A{k}, requiredA{q}) || isempty(A{k}.(requiredA{q})) && ...
                ~strcmp(requiredA{q}, 'fields')
            error('benchmark_freeze:answer', 'answer %s misses %s', aid{k}, requiredA{q});
        end
    end
    if ~any(strcmp(char(A{k}.verdict), {'PASS','FAIL','UNDETERMINED'}))
        error('benchmark_freeze:verdict', 'answer %s has verdict %s', aid{k}, char(A{k}.verdict));
    end
end

manifest = struct();
manifest.schema = 'mas-benchmark-manifest/1';
manifest.frozenAt = datestr(now, 31);
manifest.tasksFile = tasksFile;
manifest.tasksSha256 = sha256_file(tasksFile);
manifest.answersFile = answersFile;
manifest.answersSha256 = sha256_file(answersFile);
manifest.nTasks = numel(T);
manifest.ids = tid;
manifest.domains = unique(cellfun(@(s) char(s.domain), T, 'UniformOutput', false));
manifest.kinds = unique(cellfun(@(s) char(s.kind), T, 'UniformOutput', false));
fid = fopen(manifestFile, 'w');
if fid < 0, error('benchmark_freeze:write', 'cannot write %s', manifestFile); end
fwrite(fid, jsonencode(manifest), 'char'); fclose(fid);
fprintf('frozen %d tasks\n  tasks  %s\n  sha256 %s\n  answers sha256 %s\n  manifest %s\n', ...
    manifest.nTasks, tasksFile, manifest.tasksSha256, manifest.answersSha256, manifestFile);
end

function h = sha256_file(p)
fid = fopen(p, 'r');
if fid < 0, error('benchmark_freeze:hash', 'cannot open %s', p); end
b = fread(fid, Inf, '*uint8'); fclose(fid);
md = java.security.MessageDigest.getInstance('SHA-256');
d = typecast(md.digest(b), 'uint8');
h = lower(reshape(dec2hex(d)', 1, []));
end
