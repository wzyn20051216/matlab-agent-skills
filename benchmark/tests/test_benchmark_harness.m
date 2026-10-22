function r = test_benchmark_harness(verbose)
%TEST_BENCHMARK_HARNESS  Independent tests for the isolation benchmark harness.
%
%   r = test_benchmark_harness()
%
% The cases are about the harness, not about any MATLAB tool: a freeze that can
% be edited after the fact, a grader that grades a missing result as PASS, or an
% audit that cannot see an answers copy is worse than no benchmark at all.

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(here));
addpath(here);
addpath(repo);

C = {};
function pass = chk(id, cond, detail)
    if cond, st = 'pass'; else, st = 'fail'; end
    C{end+1} = struct('id', id, 'status', st, 'detail', detail);
    pass = cond;
end

tt = tempname; mkdir(tt);
cleaner = onCleanup(@() rmdir(tt, 's'));

% ---- build a fake workspace and a disjoint evaluation root ---------------
fakeRepo = fullfile(tt, 'repo');
mkdir(fullfile(fakeRepo, 'benchmark', 'dev'));
copyfile(fullfile(repo, 'benchmark', 'dev', 'tasks.json'), ...
    fullfile(fakeRepo, 'benchmark', 'dev', 'tasks.json'));
copyfile(fullfile(repo, 'benchmark', 'dev', 'answers.json'), ...
    fullfile(fakeRepo, 'benchmark', 'dev', 'answers.json'));

holdout = fullfile(tt, 'holdout'); mkdir(holdout);
% Derive a disjoint holdout textually: ids differ, so both the task file and the
% answers file differ byte-for-byte from the public dev copies.
tTxt = strrep(fileread(fullfile(repo, 'benchmark', 'dev', 'tasks.json')), ...
    '"id": "dev-', '"id": "H-dev-');
aTxt = strrep(fileread(fullfile(repo, 'benchmark', 'dev', 'answers.json')), ...
    '"id": "dev-', '"id": "H-dev-');
fid = fopen(fullfile(holdout, 'tasks.json'), 'w');
fwrite(fid, tTxt, 'char'); fclose(fid);
fid = fopen(fullfile(holdout, 'answers.json'), 'w');
fwrite(fid, aTxt, 'char'); fclose(fid);

hT = fullfile(holdout, 'tasks.json');
hA = fullfile(holdout, 'answers.json');
hM = fullfile(holdout, 'manifest.json');
benchmark_freeze(hT, hA, hM);
M = jsondecode(fileread(hM));
chk('freeze hashes', strcmp(char(M.answersSha256), sha256(hA)) && ...
    strcmp(char(M.tasksSha256), sha256(hT)), 'both hashes recorded');

% ---- audit: an answers copy inside the workspace must be caught ---------
mkfiles = {'copyA.json'};
copyfile(hA, fullfile(fakeRepo, mkfiles{1}));
Aud = benchmark_audit(fakeRepo, holdout, hM);
chk('audit catches copy', ~Aud.ok && ~getcheck(Aud, 'noAnswerCopy'), ...
    'answers copy inside repo flagged');
delete(fullfile(fakeRepo, mkfiles{1}));

% A copy hidden in the artifacts tree is still a copy: the audit must not have
% a directory blind spot.
sub = fullfile(fakeRepo, 'artifacts', 'phase53');
mkdir(sub);
copyfile(hA, fullfile(sub, 'copyA.json'));
Aud = benchmark_audit(fakeRepo, holdout, hM);
chk('audit catches hidden copy', ~Aud.ok && ~getcheck(Aud, 'noAnswerCopy'), ...
    'answers copy under artifacts/phase53 flagged');
delete(fullfile(sub, 'copyA.json'));

Aud = benchmark_audit(fakeRepo, holdout, hM);
chk('audit passes clean', Aud.ok, sprintf('%d checks, all pass', numel(Aud.checks)));

% ---- run + grade the public dev tasks -----------------------------------
resDir = fullfile(tt, 'results');
benchmark_run(fullfile(repo, 'benchmark', 'dev', 'tasks.json'), resDir);
G = benchmark_grade(resDir, fullfile(repo, 'benchmark', 'dev', 'tasks.json'), ...
    fullfile(repo, 'benchmark', 'dev', 'answers.json'), ...
    fullfile(repo, 'benchmark', 'dev', 'manifest.json'), fullfile(resDir, 'grade.json'));
chk('grade 3/3', G.nPass == 3 && G.nTasks == 3, sprintf('%d/%d', G.nPass, G.nTasks));
chk('labels tool-level', G.agentRuns == 0 && strcmp(G.agentLevel, 'NOT TESTED') && ...
    contains(G.baseline, 'NOT an Agent benchmark'), G.baseline);

% ---- tamper with the frozen tasks ---------------------------------------
tampered = fullfile(tt, 'tampered.json');
copyfile(fullfile(repo, 'benchmark', 'dev', 'tasks.json'), tampered);
fid = fopen(tampered, 'a'); fwrite(fid, ' ', 'char'); fclose(fid);
didError = false;
try
    benchmark_grade(resDir, tampered, fullfile(repo, 'benchmark', 'dev', 'answers.json'), ...
        fullfile(repo, 'benchmark', 'dev', 'manifest.json'), fullfile(tt, 'x.json'));
catch
    didError = true;
end
chk('tampered tasks refused', didError, 'grader throws on hash mismatch');

% ---- missing evidence is a failure, not a pass --------------------------
res2 = fullfile(tt, 'results2');
copyfile(resDir, res2);
delete(fullfile(res2, 'result_dev-data-normal.json'));
G2 = benchmark_grade(res2, fullfile(repo, 'benchmark', 'dev', 'tasks.json'), ...
    fullfile(repo, 'benchmark', 'dev', 'answers.json'), ...
    fullfile(repo, 'benchmark', 'dev', 'manifest.json'), fullfile(res2, 'grade.json'));
row = G2.rows(strcmp({G2.rows.taskId}, 'dev-data-normal'));
chk('missing result fails', ~row.pass && contains(row.note, 'missing'), row.note);
chk('missing counted', G2.nPass == 2, sprintf('%d/3', G2.nPass));

% ---- a wrong verdict is a failure --------------------------------------
res3 = fullfile(tt, 'results3');
copyfile(resDir, res3);
rf = fullfile(res3, 'result_dev-sig-normal.json');
d = jsondecode(fileread(rf)); d.verdict = 'FAIL';
fid = fopen(rf, 'w'); fwrite(fid, jsonencode(d), 'char'); fclose(fid);
G3 = benchmark_grade(res3, fullfile(repo, 'benchmark', 'dev', 'tasks.json'), ...
    fullfile(repo, 'benchmark', 'dev', 'answers.json'), ...
    fullfile(repo, 'benchmark', 'dev', 'manifest.json'), fullfile(res3, 'grade.json'));
row = G3.rows(strcmp({G3.rows.taskId}, 'dev-sig-normal'));
chk('wrong verdict fails', ~row.pass && ~row.verdictOk, row.note);

% ---- a field outside tolerance is a failure -----------------------------
res4 = fullfile(tt, 'results4');
copyfile(resDir, res4);
rf = fullfile(res4, 'result_dev-rob-normal.json');
d = jsondecode(fileread(rf)); d.fields.detR = 1.1;
fid = fopen(rf, 'w'); fwrite(fid, jsonencode(d), 'char'); fclose(fid);
G4 = benchmark_grade(res4, fullfile(repo, 'benchmark', 'dev', 'tasks.json'), ...
    fullfile(repo, 'benchmark', 'dev', 'answers.json'), ...
    fullfile(repo, 'benchmark', 'dev', 'manifest.json'), fullfile(res4, 'grade.json'));
row = G4.rows(strcmp({G4.rows.taskId}, 'dev-rob-normal'));
chk('out-of-tolerance field fails', ~row.pass, row.note);

% ---- report -------------------------------------------------------------
st = cellfun(@(s) s.status, C, 'UniformOutput', false);
r = struct('nPass', nnz(strcmp(st, 'pass')), 'nTotal', numel(C), ...
    'pass', all(strcmp(st, 'pass')), 'checks', {C});
if verbose
    fprintf('=== benchmark harness tests ===\n');
    for k = 1:numel(C)
        fprintf('  [%s] %-28s -> %s\n', upper(C{k}.status), C{k}.id, C{k}.detail);
    end
    fprintf('\n---- %d / %d benchmark-harness cases passed ----\n', r.nPass, r.nTotal);
end
end

% ===========================================================================
function tf = getcheck(A, id)
tf = any(strcmp({A.checks.id}, id) & [A.checks.pass]);
end

function h = sha256(p)
fid = fopen(p, 'r'); b = fread(fid, Inf, '*uint8'); fclose(fid);
md = java.security.MessageDigest.getInstance('SHA-256');
d = typecast(md.digest(b), 'uint8');
h = lower(reshape(dec2hex(d)', 1, []));
end
