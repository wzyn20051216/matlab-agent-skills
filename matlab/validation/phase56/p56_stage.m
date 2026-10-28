function S = p56_stage(rootDir, taskIds)
%P56_STAGE  Build the Phase 5.6 arm workspaces from the published task bundle.
%
%   S = p56_stage(evaluationRoot)
%
% One publish, three arm directories per task, and a machine-readable record of
% exactly which files each arm can see. The arm definitions are the ones frozen
% in docs/PHASE5_6_ISOLATION_ZH.md section 1:
%
%   R1  no Skill files at all (inputs + prompt only)
%   R2  SKILL.md + references/*.md, no executable .m
%   R3  the whole skill tree, scripts included
%
% Nothing outside those rules is copied: no benchmark/, no artifacts/, no other
% arm's directory, no answers (there are none yet -- this is phase one).
%
% Repeats re-stage the same root: each pass therefore starts from arm directories
% with no previous repeat's result.json in them. The evidence that survives a
% re-stage is the copy archived on the evaluation side, so archive before staging.

% .../matlab/validation/phase56 -> .../matlab/validation -> .../matlab -> repo root
repo = fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
addpath(fullfile(repo, 'benchmark'));
addpath(fullfile(repo, 'skills', 'matlab-signal-vision-ai', 'scripts'));
addpath(fullfile(repo, 'skills', 'matlab-data-analysis', 'scripts'));

bundle = fullfile(rootDir, 'bundle');
if ~isfile(fullfile(bundle, 'publish_manifest.json'))
    P = benchmark_publish(fullfile(repo, 'benchmark', 'tasks_p56.json'), bundle, ...
        fullfile(repo, 'benchmark', 'reference_p56.m'));
else
    P = jsondecode(fileread(fullfile(bundle, 'publish_manifest.json')));
end
PT = jsondecode(fileread(fullfile(bundle, 'tasks_public.json')));
T = PT.tasks; if isstruct(T), T = num2cell(T(:)); end
if nargin < 2, taskIds = cellfun(@(s) char(s.id), T, 'UniformOutput', false); end

arms = {'R1', 'R2', 'R3'};
rows = {};
for k = 1:numel(T)
    id = char(T{k}.id);
    if ~any(strcmp(id, taskIds)), continue; end
    for q = 1:numel(arms)
        arm = arms{q};
        d = fullfile(rootDir, 'arms', arm, id);
        % every staging run starts from an EMPTY directory: a leftover file from a
        % wider arm must not silently become part of a narrower arm. delete('*')
        % would miss subdirectories, so the directory itself is rebuilt.
        if isfolder(d), rmdir(d, 's'); end
        mkdir(d);
        copyfile(fullfile(bundle, sprintf('inputs_%s.mat', id)), d);
        writePrompt(d, T{k});
        stageFiles(arm, repo, d);
        fid = fopen(fullfile(d, 'ENVIRONMENT.md'), 'w');
        fwrite(fid, envText(arm, id), 'char'); fclose(fid);
        files = list_files(d);
        rows{end+1} = struct('task', id, 'arm', arm, 'dir', d, 'nFiles', numel(files), ...
            'nMat', nnz(endsWith(files, '.mat')), 'nM', nnz(endsWith(files, '.m')), ...
            'nMd', nnz(endsWith(files, '.md')), ...
            'masScripts', nnz(cellfun(@(s) ~isempty(regexpi(s, 'mas_[a-z0-9_]+\.m$')), files)), ...
            'nSkillMd', nnz(endsWith(lower(files), 'skill.md')), 'files', {files}); %#ok<AGROW>
    end
end
R = [rows{:}];
r1 = strcmp({R.arm}, 'R1');
r2 = strcmp({R.arm}, 'R2');
r3 = strcmp({R.arm}, 'R3');
% the arm invariants that decide whether the contrast means anything at all
assert(all([R(r1).masScripts] == 0), 'stage:R1hasScripts: an executable mas_* tool reached arm R1');
assert(all([R(r2).masScripts] == 0), 'stage:R2hasScripts: an executable mas_* tool reached arm R2');
assert(all([R(r1).nSkillMd] == 0), 'stage:R1hasSkillFile: a SKILL.md reached arm R1');
assert(all([R(r2).nSkillMd] > 0), 'stage:noR2Docs: R2 staging copied no skill documentation');
assert(all([R(r3).nSkillMd] > 0), 'stage:noR3Docs: R3 staging copied no skill documentation');

S = struct();
S.schema = 'mas-phase56-stage/1';
S.stagedAt = datestr(now, 31);
S.rootDir = rootDir;
S.publish = P;
S.arms = R;
fid = fopen(fullfile(rootDir, 'stage_manifest.json'), 'w');
fwrite(fid, jsonencode(S), 'char'); fclose(fid);
fprintf('%-12s %-4s %6s %5s %5s %5s %11s\n', 'task', 'arm', 'files', '.mat', '.m', '.md', 'mas_*.m');
for k = 1:numel(R)
    fprintf('%-12s %-4s %6d %5d %5d %5d %11d\n', R(k).task, R(k).arm, R(k).nFiles, ...
        R(k).nMat, R(k).nM, R(k).nMd, R(k).masScripts);
end
fprintf('stage manifest: %s\n', fullfile(rootDir, 'stage_manifest.json'));
end

% ===========================================================================
function stageFiles(arm, repo, d)
% Each skill keeps its own subfolder inside the arm directory. Flattening them
% would collide: nine skills, nine SKILL.md files, one overwritten by the next.
skillsDir = fullfile(repo, 'skills');
sk = dir(skillsDir);
for k = 1:numel(sk)
    if ~sk(k).isdir || strcmp(sk(k).name, '.') || strcmp(sk(k).name, '..'), continue; end
    if ~startsWith(sk(k).name, 'matlab-'), continue; end
    src = fullfile(sk(k).folder, sk(k).name);
    switch arm
        case 'R1'
            % nothing: no Skill file of any kind
        case 'R2'
            dst = fullfile(d, sk(k).name);
            mkdir(dst);
            copyMatching(src, dst, {'.md'});
            if isfolder(fullfile(src, 'references'))
                refdst = fullfile(dst, 'references');
                mkdir(refdst);
                copyMatching(fullfile(src, 'references'), refdst, {'.md'});
            end
        case 'R3'
            copyTree(src, fullfile(d, sk(k).name));
    end
end
end

function copyMatching(srcDir, dstDir, exts)
if ~isfolder(srcDir), return; end
f = dir(fullfile(srcDir, '*'));
for k = 1:numel(f)
    if f(k).isdir, continue; end
    [~, ~, e] = fileparts(f(k).name);
    if any(strcmpi(e, exts))
        copyfile(fullfile(f(k).folder, f(k).name), fullfile(dstDir, f(k).name), 'f');
    end
end
end

function copyTree(srcDir, dstDir)
if ~isfolder(srcDir), return; end
if ~isfolder(dstDir), mkdir(dstDir); end
d = dir(srcDir);
for k = 1:numel(d)
    if d(k).isdir
        if any(strcmp(d(k).name, {'.', '..', 'tests'})), continue; end
        copyTree(fullfile(srcDir, d(k).name), fullfile(dstDir, d(k).name));
    else
        [~, ~, e] = fileparts(d(k).name);
        if any(strcmpi(e, {'.md', '.m', '.json'}))
            copyfile(fullfile(srcDir, d(k).name), fullfile(dstDir, d(k).name), 'f');
        end
    end
end
end

function writePrompt(d, t)
% Identical in all three arms, by design: the prompt must not name a skill, a
% mas_* tool or a routing decision, and must not hint that a skill exists. Only
% ENVIRONMENT.md differs, and it describes the folder, not what to use.
fid = fopen(fullfile(d, 'prompt.txt'), 'w');
fprintf(fid, '%s\n', char(t.prompt));
fprintf(fid, ['\nDeliverable: write result.json in this directory with a "verdict" ' ...
    '("PASS", "FAIL" or "UNDETERMINED") and a "fields" object containing exactly ' ...
    'these names: %s.\n'], strjoin(cellchar(t.report), ', '));
fprintf(fid, ['\nYou have a MATLAB session available over MCP. Environment rules ' ...
    'for this run are in ENVIRONMENT.md.\n']);
fclose(fid);
end

function s = envText(arm, id)
switch arm
    case 'R1'
        s = sprintf(['# Workspace (arm R1)\n\nTask %s. This folder contains the input ' ...
            'data file and this note. Solve the task with MATLAB over MCP.\n'], id);
    case 'R2'
        s = sprintf(['# Workspace (arm R2)\n\nTask %s. This folder contains the input data ' ...
            'file, the published skill documentation and reference notes. There are no ' ...
            'executable .m tools here; write your own MATLAB code.\n'], id);
    otherwise
        s = sprintf(['# Workspace (arm R3)\n\nTask %s. This folder contains the input data ' ...
            'file and the full skill tree, scripts included.\n'], id);
end
end

function c = cellchar(x)
if iscell(x)
    c = cellfun(@(s) strtrim(char(s)), x(:).', 'UniformOutput', false);
else
    c = cellstr(x);   % a char matrix or a string array -> trimmed cell of char
end
end

function files = list_files(root)
% dir('<root>/**') reports .name WITHOUT the subpath, so nine skills collapse into
% nine identical "SKILL.md" entries. Rebuild the path relative to the arm root --
% the absence scan verifies the staged set file by file and needs real paths.
files = {};
if ~isfolder(root), return; end
rootN = strtrim(char(java.io.File(root).getCanonicalPath()));
d = dir(fullfile(root, '**', '*'));
for k = 1:numel(d)
    if d(k).isdir, continue; end
    full = strtrim(char(java.io.File(fullfile(d(k).folder, d(k).name)).getCanonicalPath()));
    if startsWith(full, [rootN filesep])
        rel = full(numel(rootN) + 2:end);
    else
        rel = d(k).name;
    end
    files{end+1} = strrep(rel, filesep, '/'); %#ok<AGROW>
end
end
