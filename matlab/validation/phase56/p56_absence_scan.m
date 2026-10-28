function A = p56_absence_scan(rootDir, repoDir)
%P56_ABSENCE_SCAN  Prove the phase-one claim by searching, not by asserting.
%
%   A = p56_absence_scan(evaluationRoot, repositoryRoot)
%
% The two-phase seal says: while an episode runs, the Phase 5.6 answer key does
% not exist anywhere. "Does not exist" is checkable -- this scans the agent-visible
% workspace, the evaluation root, and every sibling benchmark root (the older
% sealed holdouts included, because the probe showed an episode can read them by
% absolute path) for anything that names a Phase 5.6 task id next to an
% expectation.
%
% Two findings are reported separately and must not be merged:
%
%   p56AnswersAbsent   no Phase 5.6 expectation exists yet. This is the control
%                      the experiment relies on, and it is verified here.
%   historicalKeys     Phase 5.3/5.4/5.5 answer keys DO exist on this volume and
%                      are reachable. That is the documented reason strong
%                      isolation is BLOCKED; it is not cured by this scan.
%
% A.ok is true only if the Phase 5.6 scan is clean in every root AND the seal
% artifacts are absent AND the committed generator still hashes to the committed
% value. A hit is never dropped: it is reported with its path and reason.

if nargin < 2, repoDir = fileparts(fileparts(fileparts(fileparts(mfilename('fullpath'))))); end
if nargin < 1, rootDir = fullfile(fileparts(repoDir), 'MATLAB-bench-phase56'); end
benchDir = fileparts(rootDir);

pubFile = fullfile(rootDir, 'bundle', 'tasks_public.json');
if ~isfile(pubFile)
    error('p56_absence_scan:notPublished', 'publish %s first', pubFile);
end
P = jsondecode(fileread(fullfile(rootDir, 'bundle', 'publish_manifest.json')));
PT = jsondecode(fileread(pubFile));
ids = cellfun(@(s) char(s.id), num2cell(PT.tasks), 'UniformOutput', false);

% ---- 1. no seal artifact may exist anywhere in scope ----------------------
roots = uniq([{rootDir}, {repoDir}, sibling_roots(benchDir)]);
sealNames = {'answers.json', 'seal_manifest.json', 'tasks_frozen.json', 'answers*.mat'};
sealHits = {};
for k = 1:numel(roots)
    isHere = strcmp(strrep(roots{k}, '\', '/'), strrep(rootDir, '\', '/'));
    for q = 1:numel(sealNames)
        d = dir(fullfile(roots{k}, '**', sealNames{q}));
        for r = 1:numel(d)
            if ~d(r).isdir
                sealHits(end+1, :) = {relpath(fullfile(d(r).folder, d(r).name), roots{k}), ...
                    roots{k}, isHere};
            end
        end
    end
end
if isempty(sealHits)
    inNew = false(0, 1);
else
    inNew = logical([sealHits{:, 3}]).';
end

% ---- 2. no Phase 5.6 expectation may be readable FROM A WORKSPACE ---------
% Two passes over the workspaces, because they answer different questions:
%   bundle + whole arm tree  -- is any expectation READABLE from what an episode
%                              is handed? Only the episode's own result.json is
%                              allowed to bind a verdict to a value.
%   the staged file list     -- is every file staging promised still there, and
%                              does each one individually carry no expectation?
% The repo is not scanned for shapes: the committed generator, its unit tests and
% this round's docs quote the shapes they detect. Reading the generator by
% absolute path is the documented BLOCKED finding (probe V10/V11), not a bug.
rows = {};
nScanned = 0;
h = benchmark_scan_for_answers(fullfile(rootDir, 'bundle'), ids, 'workspace');
for q = 1:size(h, 1)
    rows(end+1, :) = {'bundle', h{q, 1}, h{q, 2}};
end
if isfolder(fullfile(rootDir, 'arms'))
    h = benchmark_scan_for_answers(fullfile(rootDir, 'arms'), ids, 'workspace', 'result.json');
    for q = 1:size(h, 1)
        rows(end+1, :) = {'arms', h{q, 1}, h{q, 2}};
    end
end
stageFile = fullfile(rootDir, 'stage_manifest.json');
if isfile(stageFile)
    SM = jsondecode(fileread(stageFile));
    AR = SM.arms; if isstruct(AR), AR = num2cell(AR(:)); end
    for k = 1:numel(AR)
        d = char(AR{k}.dir);
        id = char(AR{k}.task);
        files = toCell(AR{k}.files);
        for q = 1:numel(files)
            nScanned = nScanned + 1;
            p = fullfile(d, strrep(char(files{q}), '/', filesep));
            if ~isfile(p)
                rows(end+1, :) = {d, char(files{q}), 'staged file is missing'};
                continue;
            end
            try
                txt = fileread(p);
            catch
                continue;
            end
            [tf, why] = benchmark_expectation_shape(txt);
            if tf && contains(txt, id)
                rows(end+1, :) = {d, char(files{q}), why};
            end
        end
    end
end

% ---- 3. the committed generator is still the committed one ---------------
genHash = '';
genOk = false;
if isfile(char(P.referenceFile))
    genHash = sha256_file(char(P.referenceFile));
    genOk = strcmp(genHash, char(P.referenceSha256));
end

A = struct();
A.schema = 'mas-phase56-absence/1';
A.scannedAt = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
A.roots = roots;
A.taskIds = ids;
A.nStagedFilesScanned = nScanned;
A.p56AnswersAbsent = isempty(rows);
A.sealArtifactsInPhase56Root = nnz(inNew);
A.historicalSealArtifacts = size(sealHits, 1) - nnz(inNew);
A.generatorHashMatchesCommitment = genOk;
A.generatorSha256 = genHash;
A.commitmentSha256 = char(P.referenceSha256);
A.publicSha256 = char(P.publicSha256);
A.hits = toStruct(rows, {'scope', 'path', 'reason'});
A.sealArtifacts = toStruct(sealHits, {'path', 'root', 'inPhase56Root'});
A.findings = struct( ...
    'p56AnswersAbsent', A.p56AnswersAbsent, ...
    'historicalKeys', struct('present', A.historicalSealArtifacts > 0, ...
    'n', A.historicalSealArtifacts, ...
    'note', 'Phase 5.3/5.4/5.5 keys exist on this volume and are readable by absolute path (probe V1/V2/V11). This is why strong isolation is BLOCKED and why the Phase 5.6 gain runs can only be labelled EXPLORATORY.'));
A.ok = A.p56AnswersAbsent && A.sealArtifactsInPhase56Root == 0 && ...
    A.generatorHashMatchesCommitment;
A.claim = 'absence verified for Phase 5.6 only; absence is not access control';

outFile = fullfile(rootDir, 'absence_report.json');
fid = fopen(outFile, 'w');
if fid < 0, error('p56_absence_scan:write', 'cannot write %s', outFile); end
fwrite(fid, jsonencode(A), 'char'); fclose(fid);

fprintf('scanned %d staged arm files + the published bundle for expectation shapes\n', nScanned);
if isempty(rows)
    fprintf('  expectation scan: clean (no readable Phase 5.6 answer)\n');
else
    for q = 1:size(rows, 1)
        fprintf('  HIT %s :: %s :: %s\n', rows{q, 1}, rows{q, 2}, rows{q, 3});
    end
end
for k = 1:numel(roots)
    n = 0;
    if ~isempty(sealHits), n = nnz(strcmp(sealHits(:, 2), roots{k})); end
    if n > 0, fprintf('  %s: %d seal artifact(s)\n', roots{k}, n); end
end
fprintf(['seal artifacts under the phase56 root: %d | in other (historical) roots: %d\n' ...
    'generator hash matches commitment: %d | Phase 5.6 answers absent: %d\n' ...
    'report: %s\n'], A.sealArtifactsInPhase56Root, A.historicalSealArtifacts, ...
    A.generatorHashMatchesCommitment, A.p56AnswersAbsent, outFile);
if ~A.ok
    error('p56_absence_scan:dirty', ...
        'Phase 5.6 expectations are readable or the commitment broke; refusing to run');
end
end

% ===========================================================================
function S = toStruct(C, names)
% jsonencode FLATTENS an NxK cell array into one long array, which destroys the
% row/column pairing a reader needs. Report records as struct arrays instead --
% and an EMPTY result must be a 0x0 struct array, not a 1x1 struct holding empty
% cells, or numel(hits) reads as 1 and a clean scan looks like one leak.
if isempty(C)
    args = cell(1, 2 * numel(names));
    args(1:2:end) = names;
    args(2:2:end) = {{}};   % struct('a',{}) is a 0x0 array; struct('a',[]) is 1x1
    S = struct(args{:});
    return;
end
S = cell2struct(C, names, 2);
end

function c = toCell(x)
% jsondecode returns a cell for a JSON string array, but a char matrix when every
% string has the same length -- accept either shape.
if iscell(x)
    c = x(:);
else
    c = cellstr(x);
end
end

function rs = sibling_roots(benchDir)
% a ROW cell, so [{rootDir}, {repoDir}, sibling_roots(...)] concatenates
d = dir(fullfile(benchDir, 'MATLAB-bench-*'));
rs = {};
for k = 1:numel(d)
    if d(k).isdir, rs{end+1} = fullfile(d(k).folder, d(k).name); end %#ok<AGROW>
end
end

function c = uniq(c)
[~, ia] = unique(strrep(c, '\', '/'), 'stable');
c = c(ia);
end

function p = relpath(p, root)
root = strrep(root, '\', '/');
pp = strrep(p, '\', '/');
if startsWith(pp, [root '/']), pp = pp(numel(root) + 2:end); end
p = pp;
end

function h = sha256_file(p)
fid = fopen(p, 'r');
if fid < 0, error('p56_absence_scan:hash', 'cannot open %s', p); end
b = fread(fid, Inf, '*uint8'); fclose(fid);
md = java.security.MessageDigest.getInstance('SHA-256');
d = typecast(md.digest(b), 'uint8');
h = lower(reshape(dec2hex(d)', 1, []));
end
