function res = test_phase43_grade(verbose)
%TEST_PHASE43_GRADE  回归验证证据解析、独立数值比较及完整性分母。
%   res = test_phase43_grade(); assert(res.pass);
%   全部样本写入独立临时目录；不读取或覆盖历史基准原始结果。
if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
addpath(fullfile(fileparts(here), 'scripts'));
tmp = tempname; mkdir(tmp);
cleaner = onCleanup(@() rmdir(tmp, 's')); %#ok<NASGU>
R = struct('case', {}, 'got', {}, 'pass', {});

% 正例与负例必须成对：特别防止 logical true 或异常数组被误判。
T = {
    'JSON logical true', 'B2', '{"pmDeg":55.862239880,"loopStable":true}', 'PASS';
    'legacy numeric one', 'B2', '{"pmDeg":55.862239880,"loopStable":1}', 'PASS';
    'logical false', 'B2', '{"pmDeg":55.862239880,"loopStable":false}', 'FAIL';
    'numeric two is not true', 'B2', '{"pmDeg":55.862239880,"loopStable":2}', 'FAIL';
    'text true rejected', 'B2', '{"pmDeg":55.862239880,"loopStable":"true"}', 'FAIL';
    'boolean array rejected', 'B2', '{"pmDeg":55.862239880,"loopStable":[true,true]}', 'FAIL';
    'singleton boolean array rejected', 'B2', '{"pmDeg":55.862239880,"loopStable":[true]}', 'FAIL';
    'scalar numeric array rejected', 'B2', '{"pmDeg":[55.862239880,55.862239880],"loopStable":true}', 'FAIL';
    'singleton numeric array rejected', 'B2', '{"pmDeg":[55.862239880],"loopStable":true}', 'FAIL';
    'numeric string rejected', 'B2', '{"pmDeg":"55.862239880","loopStable":true}', 'FAIL';
    'null rejected', 'B2', '{"pmDeg":null,"loopStable":true}', 'FAIL';
    'missing field is undetermined', 'B2', '{"loopStable":true}', 'UNDETERMINED';
    'wrong numeric value', 'B2', '{"pmDeg":45,"loopStable":true}', 'FAIL';
    'known vector accepted', 'B1', '{"x":[0.3181818181818182,-3.090909090909091,3.318181818181818],"residual":0}', 'PASS';
    'vector length rejected', 'B1', '{"x":[0.3181818181818182,-3.090909090909091],"residual":0}', 'FAIL';
    'string equality accepted', 'B6', '{"verdict":"READY"}', 'PASS';
    'string equality differs', 'B6', '{"verdict":"READY_WITH"}', 'FAIL';
    'string array rejected', 'B6', '{"verdict":["READY"]}', 'FAIL';
    'payload array rejected', 'B2', '[{"pmDeg":55.862239880,"loopStable":true}]', 'ERROR';
    'invalid payload JSON', 'B2', '{"pmDeg":', 'ERROR';
    'unknown task rejected', 'B99', '{"verdict":"READY"}', 'ERROR'
    };
for k = 1:size(T, 1)
    root = new_root(tmp);
    source = write_result(root, 'R1', 1, T{k,2}, ['MAS_RESULT ' T{k,3}]);
    before = fileread(source);
    g = mas_phase43_grade(root);
    ok = strcmp(g.runs(1).status, T{k,4}) && numel(g.runs) == 1 && ...
        g.groups.nRuns == 1 && counts_match(g) && strcmp(before, fileread(source));
    if strcmp(T{k,4}, 'UNDETERMINED')
        ok = ok && g.groups.nUndetermined == 1 && g.groups.perTask.undetermined == 1 && ...
            g.groups.passRate == 0 && contains(g.verdict, '1 undetermined over 1 run(s)');
    end
    R(end+1) = result(T{k,1}, ok, g.runs(1).status); %#ok<AGROW>
end

% NaN/Inf 允许由 JSON 解码器拒绝为 ERROR，但任何情况下都不能通过。
for token = {'NaN', 'Inf'}
    root = new_root(tmp);
    write_result(root, 'R1', 1, 'B2', ...
        ['MAS_RESULT {"pmDeg":' token{1} ',"loopStable":true}']);
    g = mas_phase43_grade(root);
    R(end+1) = result(['nonfinite ' token{1}], ...
        any(strcmp(g.runs.status, {'FAIL','ERROR'})) && counts_match(g), g.runs.status); %#ok<AGROW>
end

% 外层证据及标记损坏均必须留下有原因的 ERROR 行。
badNames = {'broken file', 'outer array', 'missing taskId', 'mismatched taskId', ...
    'missing ms', 'array ms', 'negative ms', 'wrong group', 'wrong repeat', ...
    'nontext masLine', 'no marker', 'two markers'};
for k = 1:numel(badNames)
    root = new_root(tmp);
    source = write_result(root, 'R1', 1, 'B2', 'MAS_RESULT {"pmDeg":55.862239880,"loopStable":true}');
    d = jsondecode(fileread(source));
    switch k
        case 1, raw = '{broken';
        case 2, raw = ['[' jsonencode(d) ']'];
        case 3, d = rmfield(d, 'taskId'); raw = jsonencode(d);
        case 4, d.taskId = 'B1'; raw = jsonencode(d);
        case 5, d = rmfield(d, 'ms'); raw = jsonencode(d);
        case 6, d.ms = [1 2]; raw = jsonencode(d);
        case 7, d.ms = -1; raw = jsonencode(d);
        case 8, d.group = 'R2'; raw = jsonencode(d);
        case 9, d.repeat = 2; raw = jsonencode(d);
        case 10, d.masLine = 1; raw = jsonencode(d);
        case 11, d.masLine = '{"loopStable":true}'; raw = jsonencode(d);
        case 12, d.masLine = [d.masLine newline d.masLine]; raw = jsonencode(d);
    end
    write_text(source, raw, false);
    g = mas_phase43_grade(root);
    ok = numel(g.runs) == 1 && strcmp(g.runs.status, 'ERROR') && ...
        g.groups.nError == 1 && g.groups.nRuns == 1 && ...
        ~isempty(g.runs.reason) && strcmp(g.runs.sourceFile, source) && counts_match(g);
    R(end+1) = result(badNames{k}, ok, g.runs.status); %#ok<AGROW>
end

root = new_root(tmp);
source = write_result(root, 'R1', 1, 'B2', 'MAS_RESULT {"pmDeg":55.862239880,"loopStable":true}');
write_text(source, fileread(source), true);
g = mas_phase43_grade(root);
R(end+1) = result('UTF-8 BOM accepted', strcmp(g.runs.status, 'PASS'), g.runs.status);

% 未给计划时保持旧的发现模式；给计划后缺文件和缺目录均占分母。
root = new_root(tmp);
write_result(root, 'R1', 1, 'B2', 'MAS_RESULT {"pmDeg":55.862239880,"loopStable":true}');
g = mas_phase43_grade(root);
R(end+1) = result('legacy no-plan discovery', numel(g.runs) == 1 && isempty(g.plan), g.verdict);
plan = struct('groups', {{'R1','R2'}}, 'repeats', 2, 'taskIds', {{'B2','B6'}});
g = mas_phase43_grade(root, plan);
ok = numel(g.runs) == 8 && nnz([g.runs.missing]) == 7 && ...
    sum([g.groups.nError]) == 7 && sum([g.groups.nRuns]) == 8 && ...
    all([g.groups.nRuns] == 4) && counts_match(g);
R(end+1) = result('plan includes missing runs and groups', ok, g.verdict);

% 自动计划文件带 BOM，损坏结果不能被补成第二条缺失记录。
root = new_root(tmp);
source = write_result(root, 'R1', 1, 'B2', '');
write_text(source, '{broken', false);
plan = struct('groups', {{'R1'}}, 'repeats', 1, 'taskIds', {{'B2','B6'}});
planPath = fullfile(root, 'plan.json');
write_text(planPath, jsonencode(plan), true);
g = mas_phase43_grade(root);
ok = numel(g.runs) == 2 && nnz([g.runs.missing]) == 1 && ...
    g.groups.nError == 2 && g.groups.nRuns == 2 && counts_match(g);
R(end+1) = result('BOM plan and corrupt evidence counted once', ok, g.verdict);
g = mas_phase43_grade(root, planPath);
R(end+1) = result('explicit plan path', numel(g.runs) == 2 && counts_match(g), g.verdict);

root = new_root(tmp);
plan.repeats = [2 4];
g = mas_phase43_grade(root, plan);
ok = numel(g.runs) == 4 && isequal(unique([g.runs.repeat]), [2 4]) && counts_match(g);
R(end+1) = result('explicit repeat identifiers', ok, g.verdict);

root = new_root(tmp);
plan.repeats = 0;
rejected = false;
try, mas_phase43_grade(root, plan); catch ex, rejected = strcmp(ex.identifier, 'mas:phase43:BadPlan'); end
R(end+1) = result('invalid plan rejected', rejected && ~isfile(fullfile(root, 'grade.json')), 'BadPlan');
root = new_root(tmp);
write_text(fullfile(root, 'plan.json'), '{broken', false);
rejected = false;
try, mas_phase43_grade(root); catch, rejected = true; end
R(end+1) = result('corrupt plan cannot silently fall back', ...
    rejected && ~isfile(fullfile(root, 'grade.json')), 'rejected');

if verbose
    for k = 1:numel(R)
        fprintf('  [%s] %s -> %s\n', string(R(k).pass), R(k).case, R(k).got);
    end
    fprintf('---- %d / %d Phase 4.3 grading cases passed ----\n', nnz([R.pass]), numel(R));
end
res = struct('nPass', nnz([R.pass]), 'nTotal', numel(R), 'cases', R, 'pass', all([R.pass]));
end

function root = new_root(tmp)
%NEW_ROOT  每个场景使用独立目录，防止前一场景的 grade.json 影响后续结果。
root = tempname(tmp); mkdir(root);
end

function source = write_result(root, group, rep, tid, line)
%WRITE_RESULT  构造与驱动器相同的最小原始结果信封。
folder = fullfile(root, sprintf('%s_run%d', group, rep));
if ~isfolder(folder), mkdir(folder); end
source = fullfile(folder, [tid '_result.json']);
d = struct('group', group, 'repeat', rep, 'taskId', tid, 'ms', 12, 'masLine', line);
write_text(source, jsonencode(d), false);
end

function write_text(path, value, bom)
%WRITE_TEXT  用真实 UTF-8 字节覆盖样本，BOM 用例不能只测试普通文本。
fid = fopen(path, 'w');
assert(fid >= 0, 'Cannot write test fixture.');
closer = onCleanup(@() fclose(fid)); %#ok<NASGU>
if bom, fwrite(fid, uint8([239 187 191]), 'uint8'); end
fwrite(fid, unicode2native(value, 'UTF-8'), 'uint8');
end

function ok = counts_match(g)
%COUNTS_MATCH  每一条证据必须恰好进入一个状态计数和汇总分母。
ok = sum([g.groups.nRuns]) == numel(g.runs);
for k = 1:numel(g.groups)
    s = g.groups(k);
    ok = ok && s.nRuns == s.nPass + s.nFail + s.nError + s.nUndetermined && ...
        sum([s.perTask.nRuns]) == s.nRuns;
end
end

function row = result(name, ok, got)
%RESULT  保持与同目录其他回归入口一致的结果结构。
row = struct('case', name, 'got', got, 'pass', logical(ok));
end
