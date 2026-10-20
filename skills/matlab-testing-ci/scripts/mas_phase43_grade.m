function r = mas_phase43_grade(rootDir, plan)
%MAS_PHASE43_GRADE  使用冻结参考独立评定 Phase 4.3 原始结果。
%   r = mas_phase43_grade(rootDir) 只汇总发现的结果文件。
%   r = mas_phase43_grade(rootDir, plan) 接受计划结构体或 JSON 文件路径。
%   默认读取 rootDir/plan.json（如果存在），计划示例：
%   struct('groups',{{'R1','R2','R3'}},'repeats',3,'taskIds',{{'B1','B2'}})
%   repeats 标量 N 表示 1:N；向量表示指定的重复编号。
%   不执行被测任务，不修改原始结果；缺失与损坏证据均保留为 ERROR。

here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
if nargin < 1 || isempty(rootDir)
    rootDir = fullfile(repo, 'artifacts', 'validation', 'phase43');
end
if ~isfolder(rootDir)
    error('mas:phase43:RootMissing', 'Result directory does not exist: %s', rootDir);
end
CFG = jsondecode(strip_bom(fileread(fullfile(repo, 'evals', 'phase43_benchmark.json'))));
T = CFG.tasks;
if isstruct(T), T = num2cell(T(:)); end
if nargin < 2
    planFile = fullfile(rootDir, 'plan.json');
    if isfile(planFile), plan = planFile; else, plan = []; end
end
plan = read_plan(plan, T);

% 每个文件保留一行；解析失败也不能从分母中消失。
runs = struct('group', {}, 'repeat', {}, 'taskId', {}, 'status', {}, ...
    'ms', {}, 'masLine', {}, 'reason', {}, 'sourceFile', {}, 'missing', {});
dirs = dir(rootDir);
for k = 1:numel(dirs)
    if ~dirs(k).isdir, continue; end
    nm = dirs(k).name;
    m = regexp(nm, '^(R[123])_run(\d+)$', 'tokens', 'once');
    if isempty(m), continue; end
    g = m{1}; rep = str2double(m{2});
    files = dir(fullfile(dirs(k).folder, nm, '*_result.json'));
    for q = 1:numel(files)
        source = fullfile(files(q).folder, files(q).name);
        tid = regexprep(files(q).name, '_result\.json$', '');
        row = make_run(g, rep, tid, source, false);
        try
            raw = strtrim(strip_bom(fileread(source)));
            if isempty(raw) || raw(1) ~= '{'
                error('mas:phase43:BadResult', 'Result must be one JSON object.');
            end
            d = jsondecode(raw);
            if ~isstruct(d) || ~isscalar(d)
                error('mas:phase43:BadResult', 'Result must be one JSON object.');
            end
            if ~isfield(d, 'taskId') || ~is_text(d.taskId) || ~strcmp(d.taskId, tid)
                error('mas:phase43:BadResult', 'taskId must match the result filename.');
            end
            if isfield(d, 'group') && (~is_text(d.group) || ~strcmp(d.group, g))
                error('mas:phase43:BadResult', 'group must match the run directory.');
            end
            if isfield(d, 'repeat') && (~finite_scalar(d.repeat) || d.repeat ~= rep)
                error('mas:phase43:BadResult', 'repeat must match the run directory.');
            end
            if ~isfield(d, 'ms') || ~finite_scalar(d.ms) || d.ms < 0
                error('mas:phase43:BadResult', 'ms must be a finite nonnegative number.');
            end
            row.ms = d.ms;
            if ~isfield(d, 'masLine') || ~is_text(d.masLine)
                error('mas:phase43:BadResult', 'masLine must be text.');
            end
            row.masLine = char(d.masLine);
            [row.status, row.reason] = grade_task(T, tid, row.masLine);
        catch ex
            row.status = 'ERROR';
            row.reason = ex.message;
        end
        runs(end+1) = row; %#ok<AGROW>
    end
end

% 有计划时将每个未产生结果文件的预期运行显式补入，包括整个缺失的目录。
if ~isempty(plan)
    for gi = 1:numel(plan.groups)
        for rep = plan.repeats
            for ti = 1:numel(plan.taskIds)
                g = plan.groups{gi}; tid = plan.taskIds{ti};
                found = strcmp({runs.group}, g) & [runs.repeat] == rep & strcmp({runs.taskId}, tid);
                if any(found), continue; end
                source = fullfile(rootDir, sprintf('%s_run%d', g, rep), [tid '_result.json']);
                row = make_run(g, rep, tid, source, true);
                row.reason = 'Expected result file is missing.';
                runs(end+1) = row; %#ok<AGROW>
            end
        end
    end
end

% 四类状态共同构成分母，UNDETERMINED 不会被折叠或遗漏。
groups = {'R1','R2','R3'};
G = struct('group', {}, 'perTask', {}, 'nPass', {}, 'nFail', {}, ...
    'nError', {}, 'nUndetermined', {}, 'nRuns', {}, 'passRate', {}, 'totalMs', {});
for gi = 1:numel(groups)
    g = groups{gi};
    gr = runs(strcmp({runs.group}, g));
    if isempty(gr), continue; end
    ids = unique({gr.taskId});
    perTask = struct('taskId', {}, 'pass', {}, 'fail', {}, 'error', {}, ...
        'undetermined', {}, 'nRuns', {}, 'ms', {});
    for q = 1:numel(ids)
        sub = gr(strcmp({gr.taskId}, ids{q}));
        perTask(end+1) = struct('taskId', ids{q}, ...
            'pass', nnz(strcmp({sub.status}, 'PASS')), ...
            'fail', nnz(strcmp({sub.status}, 'FAIL')), ...
            'error', nnz(strcmp({sub.status}, 'ERROR')), ...
            'undetermined', nnz(strcmp({sub.status}, 'UNDETERMINED')), ...
            'nRuns', numel(sub), 'ms', mean([sub.ms], 'omitnan')); %#ok<AGROW>
    end
    nPass = nnz(strcmp({gr.status}, 'PASS'));
    G(end+1) = struct('group', g, 'perTask', perTask, 'nPass', nPass, ...
        'nFail', nnz(strcmp({gr.status}, 'FAIL')), ...
        'nError', nnz(strcmp({gr.status}, 'ERROR')), ...
        'nUndetermined', nnz(strcmp({gr.status}, 'UNDETERMINED')), ...
        'nRuns', numel(gr), 'passRate', nPass/numel(gr), ...
        'totalMs', sum([gr.ms], 'omitnan')); %#ok<AGROW>
end

r = struct();
r.schema = 'mas-phase43-grade/2';
r.generatedAt = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
r.rootDir = rootDir;
r.plan = plan;
r.groups = G;
r.runs = runs;
r.verdict = build_verdict(G);
r.scope = ['The task programs are FIXED, so this measures the execution channel ' ...
    'and the availability of the skill tooling -- not an agent''s ability to ' ...
    'author the code, choose a tool, or recover from an error.'];
if isempty(plan)
    r.completeness = 'No plan supplied: counts cover discovered result files only.';
else
    r.completeness = 'Expected runs from the plan are included; missing files count as ERROR.';
end

fid = fopen(fullfile(rootDir, 'grade.json'), 'w');
if fid < 0, error('mas:phase43:WriteFailed', 'Cannot write grade.json.'); end
closer = onCleanup(@() fclose(fid)); %#ok<NASGU>
fwrite(fid, jsonencode(r, 'PrettyPrint', true), 'char');
end

function row = make_run(g, rep, tid, source, missing)
%MAKE_RUN  为成功、损坏或缺失的证据使用同一审计结构。
row = struct('group', g, 'repeat', rep, 'taskId', tid, 'status', 'ERROR', ...
    'ms', NaN, 'masLine', '', 'reason', '', 'sourceFile', source, 'missing', missing);
end

function plan = read_plan(plan, T)
%READ_PLAN  校验计划；坏计划必须报错，不能退化成仅发现文件的模式。
if isempty(plan), plan = []; return; end
if is_text(plan), plan = jsondecode(strip_bom(fileread(char(plan)))); end
if ~isstruct(plan) || ~isscalar(plan) || ...
        ~all(isfield(plan, {'groups','repeats','taskIds'}))
    error('mas:phase43:BadPlan', 'Plan requires groups, repeats and taskIds.');
end
plan.groups = text_list(plan.groups);
plan.taskIds = text_list(plan.taskIds);
validIds = cellfun(@(t) t.id, T, 'UniformOutput', false);
if ~all(ismember(plan.groups, {'R1','R2','R3'})) || ~all(ismember(plan.taskIds, validIds))
    error('mas:phase43:BadPlan', 'Plan contains an unknown group or taskId.');
end
v = plan.repeats;
if ~isnumeric(v) || ~isreal(v) || isempty(v) || ~isvector(v) || ...
        any(~isfinite(v)) || any(v < 1) || any(v ~= fix(v)) || numel(unique(v)) ~= numel(v)
    error('mas:phase43:BadPlan', 'repeats must be positive integers.');
end
if isscalar(v), v = 1:v; end
plan.repeats = reshape(v, 1, []);
end

function out = text_list(value)
%TEXT_LIST  统一 JSON 数组与 MATLAB 字符串输入，拒绝空列表和重复项。
if is_text(value), value = {char(value)};
elseif isstring(value), value = cellstr(value(:)); end
if ~iscell(value) || isempty(value) || ~isvector(value) || ~all(cellfun(@is_text, value))
    error('mas:phase43:BadPlan', 'groups and taskIds must be nonempty text lists.');
end
out = reshape(cellfun(@char, value, 'UniformOutput', false), 1, []);
if any(cellfun(@isempty, out)) || numel(unique(out)) ~= numel(out)
    error('mas:phase43:BadPlan', 'groups and taskIds must be nonempty and unique.');
end
end

function [status, reason] = grade_task(T, tid, masLine)
%GRADE_TASK  每份证据只接受一个 MAS_RESULT 和一个 JSON 对象。
status = 'ERROR'; reason = 'Unknown taskId.';
t = [];
for k = 1:numel(T)
    if strcmp(T{k}.id, tid), t = T{k}; break; end
end
if isempty(t), return; end
masLine = strip_bom(masLine);
positions = strfind(masLine, 'MAS_RESULT');
if numel(positions) ~= 1 || ~isempty(strtrim(masLine(1:positions(1)-1)))
    reason = 'Expected exactly one MAS_RESULT marker.'; return;
end
payload = strtrim(masLine(positions + numel('MAS_RESULT'):end));
payload = strip_bom(payload);
if isempty(payload) || payload(1) ~= '{'
    reason = 'MAS_RESULT must contain one JSON object.'; return;
end
try
    vals = jsondecode(payload);
catch
    reason = 'Invalid MAS_RESULT JSON.'; return;
end
if ~isstruct(vals) || ~isscalar(vals)
    reason = 'MAS_RESULT must contain one JSON object.'; return;
end
nMiss = 0; nPass = 0;
for k = 1:numel(t.checks)
    c = t.checks(k);
    if ~isfield(vals, c.field), nMiss = nMiss + 1; continue; end
    % jsondecode 会把单元素 JSON 数组降为标量；按原始语法保留形状约束。
    arrayField = ['(?<!\\)"' regexptranslate('escape', c.field) '"\s*:\s*\['];
    if ~strcmpi(c.op, 'maxabsdiff') && ~isempty(regexp(payload, arrayField, 'once'))
        continue;
    end
    nPass = nPass + compare_op(vals.(c.field), c.ref, c.op, c.tol);
end
if nMiss > 0
    status = 'UNDETERMINED'; reason = 'Required result fields are missing.';
elseif nPass == numel(t.checks)
    status = 'PASS'; reason = '';
else
    status = 'FAIL'; reason = 'A value, type, shape or tolerance check failed.';
end
end

function s = strip_bom(s)
%STRIP_BOM  兼容已解码 U+FEFF 以及按字节读入的 UTF-8 BOM。
if ~isempty(s) && double(s(1)) == 65279
    s = s(2:end);
elseif numel(s) >= 3 && isequal(double(s(1:3)), [239 187 191])
    s = s(4:end);
end
end

function ok = compare_op(got, ref, op, tol)
%COMPARE_OP  只产生标量逻辑结果；非有限数、错类型与意外数组均不能通过。
ok = false;
if ischar(ref) || isstring(ref)
    ok = strcmpi(op, 'eq') && is_text(got) && strcmp(got, char(ref)); return;
end
if ~(isnumeric(got) || islogical(got)) || ~isreal(got) || isempty(got) || ...
        any(~isfinite(double(got(:))))
    return;
end
if strcmpi(op, 'maxabsdiff')
    if ~isnumeric(got) || ~isvector(got) || numel(got) ~= numel(ref), return; end
    ok = all(abs(double(got(:)) - double(ref(:))) <= tol); return;
end
if ~isscalar(got) || ~isscalar(ref), return; end
switch lower(op)
    case 'true',       ok = got == 1;
    case 'false',      ok = got == 0;
    case 'eq',         ok = double(got) == double(ref);
    case 'absdiff',    ok = isnumeric(got) && abs(double(got) - double(ref)) <= tol;
    case 'reldiff',    ok = isnumeric(got) && abs(double(got) - double(ref)) <= tol*max(1, abs(double(ref)));
    case 'le',         ok = isnumeric(got) && double(got) <= double(ref);
    case 'ge',         ok = isnumeric(got) && double(got) >= double(ref);
end
end

function ok = is_text(value)
%IS_TEXT  字符向量或标量 string 才能作为文本字段。
ok = (ischar(value) && (isrow(value) || isempty(value))) || ...
    (isstring(value) && isscalar(value) && ~ismissing(value));
end

function ok = finite_scalar(value)
%FINITE_SCALAR  时间与编号不接受 logical、数组、NaN 或 Inf。
ok = isnumeric(value) && isreal(value) && isscalar(value) && isfinite(value);
end

function v = build_verdict(G)
%BUILD_VERDICT  将不确定状态及其分母一并展示。
lines = {};
for k = 1:numel(G)
    g = G(k);
    lines{end+1} = sprintf(['%s: %d pass / %d fail / %d error / %d undetermined ' ...
        'over %d run(s), %.1f s'], g.group, g.nPass, g.nFail, g.nError, ...
        g.nUndetermined, g.nRuns, g.totalMs/1000); %#ok<AGROW>
end
b6 = {};
for k = 1:numel(G)
    hit = find(strcmp({G(k).perTask.taskId}, 'B6'), 1);
    if isempty(hit), b6{end+1} = sprintf('%s: n/a', G(k).group); %#ok<AGROW>
    else, b6{end+1} = sprintf('%s: %d pass', G(k).group, G(k).perTask(hit).pass); end %#ok<AGROW>
end
v = [strjoin(lines, '; ') sprintf(' | B6 (needs the skill tool): %s', strjoin(b6, ', '))];
end
