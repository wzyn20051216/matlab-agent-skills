function S = p57_grade_v2_replay(evalDir)
%P57_GRADE_V2_REPLAY  Replay the frozen Phase 5.6 results under protocol v2.
%
%   S = p57_grade_v2_replay()
%   S = p57_grade_v2_replay(evaluationDirectory)
%
% Reads the sealed answers only through the frozen files and never writes to
% them. v1 grades are hashed before and after; if either the inputs or the v1
% outputs change, the replay fails. Outputs live under artifacts/phase57/grading.

here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
if nargin < 1 || isempty(evalDir)
    evalDir = fullfile(fileparts(repo), 'MATLAB-bench-phase56', 'eval');
end
outDir = fullfile(repo, 'artifacts', 'phase57', 'grading');
if ~isfolder(outDir), mkdir(outDir); end
addpath(fullfile(repo, 'benchmark'));

tasksFile = fullfile(evalDir, 'tasks_frozen.json');
answersFile = fullfile(evalDir, 'answers.json');
manifestFile = fullfile(evalDir, 'manifest.json');
scoringFile = fullfile(repo, 'benchmark', 'scoring_p56_retro.json');

v1files = [string({tasksFile, answersFile, manifestFile}) ...
    arrayfun(@(a) string(fullfile(evalDir, sprintf('grade_%s.json', a))), ...
    ["R1", "R2", "R3"])];
before = arrayfun(@(p) string(sha256_file(char(p))), v1files);

S = struct();
S.schema = 'mas-phase57-grade-replay/1';
S.generatedAt = datestr(now, 31);
S.replayOf = 'phase56';
S.kind = 'retrospective replay under protocol v2';
S.scoringFile = scoringFile;
S.scoringSha256 = sha256_file(scoringFile);
S.claimLimit = ['stored results rescored under v2; not a new experiment, not a new ' ...
    'sample, and not evidence of a Skill effect'];
S.arms = struct('arm', {}, 'v1Pass', {}, 'v2Pass', {}, 'nTasks', {}, ...
    'nFail', {}, 'nUndetermined', {}, 'nMissing', {}, 'dimensions', {}, 'gradeFile', {});
for a = ["R1", "R2", "R3"]
    rd = fullfile(evalDir, ['arm_' char(a)]);
    gf = fullfile(outDir, ['replay_' char(a) '.json']);
    G = benchmark_grade_v2(rd, tasksFile, answersFile, manifestFile, scoringFile, ...
        gf, 'arm', char(a));
    v1 = jsondecode(fileread(fullfile(evalDir, sprintf('grade_%s.json', a))));
    S.arms(end+1) = struct('arm', char(a), 'v1Pass', v1.nPass, ...
        'v2Pass', G.nPass, 'nTasks', G.nTasks, 'nFail', G.nFail, ...
        'nUndetermined', G.nUndetermined, 'nMissing', G.nMissing, ...
        'dimensions', G.dimensions, 'gradeFile', gf); %#ok<AGROW>
end
after = arrayfun(@(p) string(sha256_file(char(p))), v1files);
S.inputsAndV1Unchanged = isequal(before, after);
S.v1Files = cellstr(v1files);
S.v1Sha256 = cellstr(before);
S.explanation = [ ...
    'v1 required routeOk && toolOk for every task; the Phase 5.6 prompts asked ' ...
    'for neither and R1 had no Skills, so all three v1 pass counts are zero. ' ...
    'v2 scores route/tool only when required; for this replay they are NOT_REQUIRED, ' ...
    'so the v2 pass counts reflect verdict and field correctness only.'];
S.pass = S.inputsAndV1Unchanged && ...
    S.arms(1).v2Pass == 0 && S.arms(2).v2Pass == 2 && S.arms(3).v2Pass == 3;

fid = fopen(fullfile(outDir, 'replay_summary.json'), 'w');
fwrite(fid, jsonencode(S, 'PrettyPrint', true), 'char'); fclose(fid);

for k = 1:numel(S.arms)
    fprintf('%s: v1 %d/%d, v2 %d/%d (fail %d, undetermined %d, missing %d)\n', ...
        S.arms(k).arm, S.arms(k).v1Pass, S.arms(k).nTasks, S.arms(k).v2Pass, ...
        S.arms(k).nTasks, S.arms(k).nFail, S.arms(k).nUndetermined, S.arms(k).nMissing);
end
fprintf('v1 unchanged=%d pass=%d -> %s\n', S.inputsAndV1Unchanged, S.pass, ...
    fullfile(outDir, 'replay_summary.json'));
end

function h = sha256_file(p)
fid = fopen(p, 'r');
if fid < 0, error('p57_grade_v2_replay:hash', 'cannot open %s', p); end
b = fread(fid, Inf, '*uint8'); fclose(fid);
md = java.security.MessageDigest.getInstance('SHA-256');
d = typecast(md.digest(b), 'uint8');
h = lower(reshape(dec2hex(d)', 1, []));
end
