function P = benchmark_publish(tasksFile, bundleDir, referenceFile)
%BENCHMARK_PUBLISH  Phase one of the two-phase seal: publish tasks, not answers.
%
%   P = benchmark_publish(tasksFile, bundleDir, referenceFile)
%
% The Phase 5.5 holdouts could not support a causal gain claim because their
% expected answers already existed on disk (the Phase 5.6 isolation probe read
% them from a sibling arm's directory). This function removes that threat by
% construction: at publish time the answer file DOES NOT EXIST and cannot be
% found by reading, searching or guessing. It is generated only at grade time by
% benchmark_seal.m, from a reference implementation that is committed here as a
% HASH -- so the expectations are fixed before any episode runs, but their
% contents are not readable by one.
%
% What the arm-visible bundle contains: id, domain, kind, prompt, seed, the
% report field names, and the materialised inputs as a .mat file. What it never
% contains: expected verdict, reference values, tolerances against a key, route
% (skill/tool), or any other arm's results.
%
% P.phase is 'PUBLISHED'; P.answersPresent must be false; P.referenceSha256 is
% the pre-commitment. Publishing twice into the same bundle is refused, because
% a re-publish after seeing results would be post-hoc fitting.

if nargin < 3, referenceFile = ''; end

TF = jsondecode(fileread(tasksFile));
T = TF.tasks; if isstruct(T), T = num2cell(T(:)); end
if isempty(T), error('benchmark_publish:empty', 'no tasks in %s', tasksFile); end
ids = cellfun(@(s) char(s.id), T, 'UniformOutput', false);
if numel(unique(ids)) ~= numel(ids), error('benchmark_publish:dup', 'duplicate task id'); end

req = {'id', 'domain', 'kind', 'prompt', 'fixture', 'report'};
for k = 1:numel(T)
    for q = 1:numel(req)
        if ~isfield(T{k}, req{q}) || isempty(T{k}.(req{q}))
            error('benchmark_publish:task', 'task %s misses %s', ids{k}, req{q});
        end
    end
    if ~any(strcmp(ids{k}, {'P56-SIG-B', 'P56-ODE-N', 'P56-SIG-F'})) && ...
            ~startsWith(ids{k}, 'P56-')
        error('benchmark_publish:id', 'task %s is not a Phase 5.6 id', ids{k});
    end
end

if ~isfolder(bundleDir), mkdir(bundleDir); end
pubFile = fullfile(bundleDir, 'publish_manifest.json');
if isfile(pubFile)
    error('benchmark_publish:republish', ['a publish manifest already exists at %s. Refusing to ' ...
        're-publish: if any episode has already run, a new task bundle would be fitted to ' ...
        'those results. Use a new bundle directory.'], pubFile);
end

% ---- the answers must not exist anywhere inside the bundle ----------------
addens = benchmark_scan_for_answers(bundleDir, ids, 'bundle');
if ~isempty(addens)
    error('benchmark_publish:leak', 'answer-like files already in the bundle: %s', ...
        strjoin(addens(:, 1)', ', '));
end

% ---- materialise inputs, strip expectations ------------------------------
strip = {'skill', 'tool', 'verdict', 'fields', 'ref', 'answer', 'expect'};
pub = struct('id', {}, 'domain', {}, 'kind', {}, 'prompt', {}, 'seed', {}, ...
    'report', {}, 'inputFile', {}, 'fixtureSpec', {});
listing = {};
for k = 1:numel(T)
    t = rmfield_safe(T{k}, strip);
    [~, spec, inputs] = benchmark_fixtures(char(t.fixture), local_seed(t));
    inFile = fullfile(bundleDir, sprintf('inputs_%s.mat', char(t.id)));
    save(inFile, '-struct', 'inputs');
    listing{end+1} = inFile; %#ok<AGROW>
    if isfield(t, 'fixture'), t = rmfield(t, 'fixture'); end
    % cellstr(char(...)) normalises a cell array, a char matrix or a string array
    % into a cell of trimmed names, so the report field names survive JSON exactly
    rpt = cellstr(char(t.report));
    pub(end+1) = struct('id', char(t.id), 'domain', char(t.domain), 'kind', char(t.kind), ...
        'prompt', char(t.prompt), 'seed', local_seed(t), 'report', {rpt}, ...
        'inputFile', [char(t.id) '.mat'], 'fixtureSpec', spec); %#ok<AGROW>
    clear args
end
publicFile = fullfile(bundleDir, 'tasks_public.json');
fid = fopen(publicFile, 'w');
if fid < 0, error('benchmark_publish:write', 'cannot write %s', publicFile); end
fwrite(fid, jsonencode(struct('schema', 'mas-benchmark-tasks-public/1', ...
    'suite', TF.suite, 'tasks', pub)), 'char');
fclose(fid);

P = struct();
P.schema = 'mas-benchmark-publish/1';
P.phase = 'PUBLISHED';
P.publishedAt = datestr(now, 31);
P.tasksFile = tasksFile;
P.tasksSha256 = sha256_file(tasksFile);
P.publicFile = publicFile;
P.publicSha256 = sha256_file(publicFile);
P.nTasks = numel(T);
P.ids = ids;
P.bundleDir = bundleDir;
P.filesInBundle = listing(:).';
P.answersPresent = false;
if ~isempty(referenceFile)
    P.referenceFile = referenceFile;
    P.referenceSha256 = sha256_file(referenceFile);
    P.referenceCommitted = true;
    P.referenceNote = ['content NOT copied into the bundle; the hash commits the expectation ' ...
        'generator before any episode runs'];
else
    P.referenceCommitted = false;
end
P.strip = strip;
P.limitation = ['absence is not access control: a process on this host can still read ' ...
    'reference_p56.m by absolute path (Phase 5.6 probe vectors V1/V11). What the commitment ' ...
    'does prove is that the expectations were fixed before the results were seen.'];
fid = fopen(pubFile, 'w');
fwrite(fid, jsonencode(P), 'char'); fclose(fid);

fprintf('published %d tasks into %s\n', P.nTasks, bundleDir);
fprintf('  tasks   sha256 %s\n  public  sha256 %s\n  answers present: false\n', ...
    P.tasksSha256, P.publicSha256);
if P.referenceCommitted
    fprintf('  reference committed by hash %s\n', P.referenceSha256);
end
end

% ===========================================================================
function s = local_seed(t)
if isfield(t, 'seed') && ~isempty(t.seed), s = double(t.seed); else, s = 56; end
end

function t = rmfield_safe(t, names)
for k = 1:numel(names)
    if isfield(t, names{k}), t = rmfield(t, names{k}); end
end
end

function h = sha256_file(p)
fid = fopen(p, 'r');
if fid < 0, error('benchmark_publish:hash', 'cannot open %s', p); end
b = fread(fid, Inf, '*uint8'); fclose(fid);
md = java.security.MessageDigest.getInstance('SHA-256');
d = typecast(md.digest(b), 'uint8');
h = lower(reshape(dec2hex(d)', 1, []));
end
