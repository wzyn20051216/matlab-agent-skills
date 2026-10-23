function r = test_two_phase_seal(verbose)
%TEST_TWO_PHASE_SEAL  The two-phase seal must fail when it is not honest.
%
%   r = test_two_phase_seal()
%
% The whole Phase 5.6 gain design rests on one claim: while an arm runs, no
% answer key exists to read, and the key that is later produced was fixed before
% the run. If the tooling lets you publish twice, seal before the episodes
% finish, edit a prompt after publishing, or swap the answer generator after the
% fact, that claim is theatre. These cases try to break it.

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(here));
addpath(here); addpath(fullfile(repo, 'benchmark'));

C = {};
tt = tempname; mkdir(tt);
cleaner = onCleanup(@() rmdir(tt, 's'));

tasksFile = fullfile(repo, 'benchmark', 'tasks_p56.json');
refFile = fullfile(repo, 'benchmark', 'reference_p56.m');
bundle = fullfile(tt, 'bundle');  evalDir = fullfile(tt, 'eval');
epFile = fullfile(tt, 'episodes.json');

% ---- 1. publish writes a bundle that contains no expectations ------------
P = benchmark_publish(tasksFile, bundle, refFile);
chk('publishPhase', strcmp(P.phase, 'PUBLISHED'), P.phase);
chk('noAnswersYet', ~isfile(fullfile(bundle, 'answers.json')), 'answers.json must not exist');
chk('referenceHash', numel(P.referenceSha256) == 64, P.referenceSha256);

txt = fileread(fullfile(bundle, 'tasks_public.json'));
chk('bundleNoRoute', ~contains(txt, 'mas_ber_check') && ~contains(txt, 'mas_ode_check'), ...
    'published bundle must not name the expected tool');
chk('bundleNoVerdict', ~contains(txt, 'UNDETERMINED') && ~contains(txt, '"ref"'), ...
    'published bundle must not contain an expected verdict or reference value');
% the five-state answer for the boundary task must be absent from every file
% in the bundle, by content, not by name
allTxt = '';
d = dir(fullfile(bundle, '**', '*'));
for k = 1:numel(d)
    if d(k).isdir, continue; end
    try %#ok<TRYNC>
        if ~endsWith(d(k).name, '.mat'), allTxt = [allTxt fileread(fullfile(d(k).folder, d(k).name))]; end
    end
end
chk('bundleNoState', ~contains(allTxt, 'insufficient-sample'), 'answer leaked into the bundle');

% ---- 2. re-publishing after a run is refused ------------------------------
ok = false;
try
    benchmark_publish(tasksFile, bundle, refFile);
catch ME
    ok = strcmp(ME.identifier, 'benchmark_publish:republish');
end
chk('republishRefused', ok, 'second publish into the same bundle');

% ---- 3. a bundle seeded with an answer file cannot be published -----------
dirty = fullfile(tt, 'dirty'); mkdir(dirty);
fid = fopen(fullfile(dirty, 'answers.json'), 'w');
fwrite(fid, '{"tasks":[]}', 'char'); fclose(fid);
ok = false;
try
    benchmark_publish(tasksFile, dirty, refFile);
catch ME
    ok = strcmp(ME.identifier, 'benchmark_publish:leak');
end
chk('dirtyBundleRefused', ok, 'publish into a bundle that already has an answer key');

% ---- 4. sealing without finished episodes is refused ---------------------
ok = false;
try
    benchmark_seal(fullfile(bundle, 'publish_manifest.json'), tasksFile, refFile, evalDir, '');
catch ME
    ok = strcmp(ME.identifier, 'benchmark_seal:noEpisodes');
end
chk('sealNeedsEpisodes', ok, 'seal with no episode record');

writeEpisodes(epFile, {  ...
    {'P56-SIG-B', 'R1', '1', '2026-10-22 09:00:00', 'E-x1.json'}, ...
    {'P56-SIG-B', 'R2', '1', '2026-10-22 09:10:00', 'E-x2.json'}, ...
    {'P56-SIG-B', 'R3', '1', '2026-10-22 09:20:00', 'E-x3.json'}, ...
    {'P56-ODE-N', 'R1', '1', '2026-10-22 09:30:00', 'E-x4.json'}, ...
    {'P56-ODE-N', 'R2', '1', '2026-10-22 09:40:00', 'E-x5.json'}, ...
    {'P56-ODE-N', 'R3', '1', '2026-10-22 09:50:00', 'E-x6.json'}, ...
    {'P56-SIG-F', 'R1', '1', '2026-10-22 10:00:00', 'E-x7.json'}, ...
    {'P56-SIG-F', 'R2', '1', '2026-10-22 10:10:00', 'E-x8.json'}, ...
    {'P56-SIG-F', 'R3', '1', '2026-10-22 10:20:00', 'E-x9.json'}});

S = benchmark_seal(fullfile(bundle, 'publish_manifest.json'), tasksFile, refFile, evalDir, epFile);
chk('sealPhase', strcmp(S.phase, 'SEALED'), S.sealedAt);
chk('answersExist', isfile(fullfile(evalDir, 'answers.json')), 'answers written at seal');
chk('manifestSealed', isfile(fullfile(evalDir, 'manifest.json')), 'freeze ran');
A = jsondecode(fileread(fullfile(evalDir, 'answers.json')));
AT = A.tasks; if isstruct(AT), AT = num2cell(AT(:)); end
ids = cellfun(@(s) char(s.id), AT, 'UniformOutput', false);
vds = cellfun(@(s) char(s.verdict), AT, 'UniformOutput', false);
chk('answerBoundary', strcmp(vds{strcmp(ids, 'P56-SIG-B')}, 'UNDETERMINED'), ...
    vds{strcmp(ids, 'P56-SIG-B')});
chk('answerFault', strcmp(vds{strcmp(ids, 'P56-SIG-F')}, 'FAIL'), ...
    vds{strcmp(ids, 'P56-SIG-F')});
chk('answerNormal', strcmp(vds{strcmp(ids, 'P56-ODE-N')}, 'PASS'), ...
    vds{strcmp(ids, 'P56-ODE-N')});
% the route expectation must live only in the answers, never in the bundle
pubTxt = fileread(fullfile(bundle, 'tasks_public.json'));
skills = cellfun(@(s) char(s.skill), AT, 'UniformOutput', false);
chk('routeOnlyInAnswers', ~any(cellfun(@(p) contains(pubTxt, p), skills)), 'skill name leaked');

% the closed forms in reference_p56.m must agree with an independent hand value
F = AT{strcmp(ids, 'P56-SIG-B')};
b = F.fields(strcmp({F.fields.name}, 'ciWilsonUpper95'));
chk('wilsonHandValue', abs(b.ref - 1.4426475e-4) < 1e-11, sprintf('%.7e', b.ref));

% ---- 5. sealing twice into the same eval dir is refused ------------------
ok = false;
try
    benchmark_seal(fullfile(bundle, 'publish_manifest.json'), tasksFile, refFile, evalDir, epFile);
catch ME
    ok = strcmp(ME.identifier, 'benchmark_seal:replay');
end
chk('singleUseSeal', ok, 'second seal into the same directory');

% ---- 6. a prompt edited after publish cannot be sealed -------------------
t2 = jsondecode(fileread(tasksFile));
tt1 = t2.tasks(1);
tt1.prompt = [char(tt1.prompt) ' (edited afterwards)'];
t2.tasks(1) = tt1;
edited = fullfile(tt, 'tasks_edited.json');
fid = fopen(edited, 'w'); fwrite(fid, jsonencode(t2), 'char'); fclose(fid);
ok = false;
try
    benchmark_seal(fullfile(bundle, 'publish_manifest.json'), edited, refFile, ...
        fullfile(tt, 'eval2'), epFile);
catch ME
    ok = strcmp(ME.identifier, 'benchmark_seal:tamper');
end
chk('promptEditRefused', ok, 'sealed a task file edited after publish');

% ---- 7. a swapped answer generator breaks the commitment ----------------
fakeRef = fullfile(tt, 'reference_evil.m');
copyfile(refFile, fakeRef);
fid = fopen(fakeRef, 'a'); fprintf(fid, '\n%% touched after publish\n'); fclose(fid);
ok = false;
d = 'no error raised';
try
    benchmark_seal(fullfile(bundle, 'publish_manifest.json'), tasksFile, fakeRef, ...
        fullfile(tt, 'eval3'), epFile);
catch ME
    ok = startsWith(ME.identifier, 'benchmark_seal:commitment');
    d = ME.identifier;
end
chk('commitmentEnforced', ok, d);

% ---- 8. an episode still running blocks the seal ------------------------
epOpen = fullfile(tt, 'episodes_open.json');
writeEpisodes(epOpen, {{'P56-SIG-B', 'R1', '1', '', 'E-x1.json'}});
ok = false;
try
    benchmark_seal(fullfile(bundle, 'publish_manifest.json'), tasksFile, refFile, ...
        fullfile(tt, 'eval4'), epOpen);
catch ME
    ok = strcmp(ME.identifier, 'benchmark_seal:unfinished');
end
chk('unfinishedEpisodeBlocks', ok, 'seal with an episode that has no finishedAt');

% ---- 9. the answers must not be reachable from the published bundle -----
% (the design claim, stated as a test so it cannot silently rot)
chk('bundleStillClean', ~isfile(fullfile(bundle, 'answers.json')), ...
    'sealing wrote answers into the arm-visible bundle');

ps = cellfun(@(s) strcmp(s.status, 'pass'), C);
nP = nnz(ps);
r = struct('nPass', nP, 'nTotal', numel(C), 'checks', {C}, 'pass', nP == numel(C));
if verbose
    for k = 1:numel(C)
        fprintf('  [%s] %-24s %s\n', upper(string(C{k}.status)), C{k}.id, C{k}.detail);
    end
    fprintf('\n---- %d / %d two-phase seal checks passed ----\n', nP, numel(C));
end

function writeEpisodes(p, rows)
E = struct(); E.schema = 'mas-phase56-episodes/1'; E.episodes = {};
for k = 1:numel(rows)
    rr = rows{k};
    E.episodes{end+1} = struct('task', rr{1}, 'arm', rr{2}, 'repeat', rr{3}, ...
        'finishedAt', rr{4}, 'resultFile', rr{5}, 'episodeStatus', 'COMPLETED'); %#ok<AGROW>
end
fid = fopen(p, 'w');
fwrite(fid, jsonencode(E), 'char'); fclose(fid);
end

function pass = chk(id, cond, detail)
if cond, st = 'pass'; else, st = 'fail'; end
C{end+1} = struct('id', id, 'status', st, 'detail', detail);
pass = cond;
end
end
