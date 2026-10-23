function r = test_p56_stage(verbose)
%TEST_P56_STAGE  The arm workspaces must differ only in what they are allowed to.
%
%   r = test_p56_stage()
%
% The Phase 5.6 gain contrast is R1 (no skill files) / R2 (docs only) / R3 (docs +
% executable tools). If staging leaks -- an executable into R1, a different prompt
% per arm, a hint in the environment note -- then any later difference in
% behaviour is an artefact of the staging, not of the skills. And the absence scan
% that claims "no answer is readable" is only worth something if it catches an
% answer when one is planted, without crying wolf on the episode's own result.json.
%
% The self-test workspace lives on E:, next to the other evaluation roots and
% outside both the repository and the phase56 bundle, so its planted canaries can
% never be seen by a real run. It is removed on exit.

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
addpath(here); addpath(fullfile(repo, 'benchmark'));

C = {};
tt = fullfile('E:', 'desktop', sprintf('p56-selftest-%s', ...
    char(java.util.UUID.randomUUID().toString().substring(0, 8))));
if ~exist('E:\desktop', 'dir'), tt = tempname; end
mkdir(tt);
cleaner = onCleanup(@() rmdir(tt, 's')); %#ok<NASGU>
root = fullfile(tt, 'bench');

S = p56_stage(root);
AR = S.arms;
r1 = AR(strcmp({AR.arm}, 'R1'));
r2 = AR(strcmp({AR.arm}, 'R2'));
r3 = AR(strcmp({AR.arm}, 'R3'));
ids = unique({r1.task});

chk('stagedAllTasks', numel(AR) == 3 * numel(ids), sprintf('%d rows for %d tasks', numel(AR), numel(ids)));

% ---- 1. arm contents ------------------------------------------------------
chk('r1NoExecutable', all([r1.nM] == 0) && all([r1.masScripts] == 0), ...
    sprintf('R1 .m files: %d', sum([r1.nM])));
chk('r1NoSkillDoc', all([r1.nSkillMd] == 0), 'a SKILL.md reached R1');
chk('r2NoExecutable', all([r2.nM] == 0) && all([r2.masScripts] == 0), ...
    sprintf('R2 .m files: %d', sum([r2.nM])));
chk('r2HasDocs', all([r2.nSkillMd] > 0) && all([r2.nMd] > 9), ...
    sprintf('R2 skill docs %d, md %d', min([r2.nSkillMd]), min([r2.nMd])));
chk('r3HasTools', all([r3.masScripts] > 0), sprintf('R3 mas_* count %d', min([r3.masScripts])));
chk('r3SupersetOfR2', all([r3.nFiles] > [r2.nFiles]), 'R3 must see strictly more than R2');
chk('inputsPerArm', all([AR.nMat] == 1), sprintf('mat per arm: %s', mat2str([AR.nMat])));

% ---- 2. the prompt is the same bytes in every arm -------------------------
for q = 1:numel(ids)
    id = ids{q};
    hs = {};
    for k = 1:numel(AR)
        if strcmp(AR(k).task, id)
            hs{end+1} = sha256_file(fullfile(AR(k).dir, 'prompt.txt')); %#ok<AGROW>
        end
    end
    chk(sprintf('samePrompt_%s', id), numel(hs) == 3 && numel(unique(hs)) == 1, ...
        sprintf('%d arm prompts, %d distinct', numel(hs), numel(unique(hs))));
end

% ---- 3. no prompt or environment note names a tool or a route -------------
allText = '';
for k = 1:numel(AR)
    allText = [allText fileread(fullfile(AR(k).dir, 'prompt.txt')) ...
        fileread(fullfile(AR(k).dir, 'ENVIRONMENT.md'))]; %#ok<AGROW>
end
chk('noToolNamed', ~contains(allText, 'mas_'), 'a mas_* tool was named in a prompt');
chk('noRouteNamed', ~contains(lower(allText), 'routing'), 'routing vocabulary leaked into a prompt');
r1env = '';
for k = 1:numel(r1)
    r1env = [r1env lower(fileread(fullfile(r1(k).dir, 'ENVIRONMENT.md')))]; %#ok<AGROW>
end
chk('r1EnvBlind', ~contains(r1env, 'skill') && ~contains(r1env, 'doc'), ...
    'R1 was told a skill or documentation exists');

% ---- 4. the absence scan says clean on a fresh staging --------------------
A = p56_absence_scan(root);
chk('absenceClean', A.ok, sprintf('%d hit(s) on fresh staging', numel(A.hits)));
chk('absenceScansStaged', A.nStagedFilesScanned > 100, int2str(A.nStagedFilesScanned));
chk('noAnswersOnDisk', ~isfile(fullfile(root, 'answers.json')) && ...
    ~isfile(fullfile(root, 'bundle', 'answers.json')), 'answers.json must not exist yet');

% ---- 5. a planted answer key IS caught ------------------------------------
plant = fullfile(r1(1).dir, 'answer_key.json');
fid = fopen(plant, 'w');
fwrite(fid, sprintf('{"id":"%s","verdict":"PASS","ref":0.5}', ids{1}), 'char');
fclose(fid);
caught = false; why = '';
try
    p56_absence_scan(root);
catch ME
    caught = strcmp(ME.identifier, 'p56_absence_scan:dirty');
    why = ME.message;
end
R = jsondecode(fileread(fullfile(root, 'absence_report.json')));
paths = paths_of(R.hits);
chk('canaryCaught', caught, why);
chk('canaryIdentified', any(cellfun(@(s) contains(s, 'answer_key'), paths)), ...
    join_or(paths, '(no hits reported)'));

% ---- 6. the episode's own result.json is NOT a false positive -------------
delete(plant);
res = fullfile(r1(1).dir, 'result.json');
fid = fopen(res, 'w');
fwrite(fid, sprintf('{"task":"%s","verdict":"PASS","fields":{"state":"x"}}', ids{1}), 'char');
fclose(fid);
clean = false; detail = '';
try
    A2 = p56_absence_scan(root);
    clean = A2.ok; detail = sprintf('hits: %d', numel(A2.hits));
catch ME
    detail = ['scan refused: ' ME.message];
end
chk('resultJsonNotALeak', clean, ['episode deliverable treated as a leak -- ' detail]);
delete(res);

% ---- 7. clean again after the artefacts are removed -----------------------
A3 = p56_absence_scan(root);
chk('cleanAfterRemoval', A3.ok, sprintf('%d hit(s)', numel(A3.hits)));

ps = cellfun(@(s) strcmp(s.status, 'pass'), C);
nP = nnz(ps);
r = struct('nPass', nP, 'nTotal', numel(C), 'checks', {C}, 'pass', nP == numel(C));
if verbose
    for k = 1:numel(C)
        fprintf('  [%s] %-24s %s\n', upper(string(C{k}.status)), C{k}.id, C{k}.detail);
    end
    fprintf('\n---- %d / %d phase56 staging checks passed ----\n', nP, numel(C));
end

function chk(id, cond, detail)
if cond, st = 'pass'; else, st = 'fail'; end
C{end+1} = struct('id', id, 'status', st, 'detail', detail);
end

function p = paths_of(H)
% jsondecode turns a JSON array of objects into a struct array, and [] into an
% empty double -- accept both so a clean report never crashes the canary check.
p = {};
if isstruct(H)
    rec = num2cell(H(:));
    for k = 1:numel(rec)
        if isfield(rec{k}, 'path'), p{end+1} = char(rec{k}.path); end %#ok<AGROW>
    end
end
p = unique(p);
end

function s = join_or(cells, dflt)
if isempty(cells), s = dflt; else, s = strjoin(cells(:)', ' | '); end
end

function h = sha256_file(p)
fid = fopen(p, 'r');
if fid < 0, error('test_p56_stage:hash', 'cannot open %s', p); end
b = fread(fid, Inf, '*uint8'); fclose(fid);
md = java.security.MessageDigest.getInstance('SHA-256');
d = typecast(md.digest(b), 'uint8');
h = lower(reshape(dec2hex(d)', 1, []));
end
end
