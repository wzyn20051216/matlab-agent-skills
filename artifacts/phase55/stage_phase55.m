function stage_phase55(root, force)
%STAGE_PHASE55  Build isolated arm workspaces for the Phase 5.5 benchmark.
%
%   stage_phase55()                    stage the default v2 workspaces
%   stage_phase55(root)                stage under a given root
%   stage_phase55(root, true)          rebuild every workspace
%
% Each workspace contains input.mat and a neutral prompt. R1 gets nothing
% else, R2 gets Skill docs/references only, R3 gets the full frozen skills
% tree. No answer file, scoring spec or expected verdict is written here.
%
% The prompt permits any file inside the workspace but names no skill, tool
% or route. A v1 prompt that said "only input.mat and the prompt" suppressed
% exploration and is kept only as a pilot under MATLAB-bench-phase55.

if nargin < 1 || isempty(root), root = 'E:\desktop\MATLAB-bench-phase55-v2'; end
if nargin < 2, force = false; end
repo = 'E:\desktop\MATLAB';
addpath(fullfile(repo, 'benchmark'));

T = load_tasks(repo);
armTasks = struct( ...
    'R1', {{'H-SIG-F'}}, ...
    'R2', {{'H-SIG-F'}}, ...
    'R3', {{'H-SIG-B', 'H-SIG-F', 'H-DATA-B', 'H-DATA-F', 'H-ROB-B', 'H-ROB-F', ...
            'H54-ODE-N', 'H54-ODE-B', 'H54-ODE-F', ...
            'H54-VIS-N', 'H54-VIS-B', 'H54-VIS-F'}});

arms = fieldnames(armTasks);
M = struct('schema', 'mas-phase55-stage/1', 'generatedAt', datestr(now, 31), ...
    'repoHead', git_head(repo), 'entries', struct('arm', {}, 'task', {}, ...
    'dir', {}, 'promptSha256', {}, 'inputSha256', {}, 'promptBytes', {}, ...
    'nFiles', {}, 'usesRepoSkills', {}));

for a = 1:numel(arms)
    arm = arms{a};
    for k = 1:numel(armTasks.(arm))
        id = armTasks.(arm){k};
        task = T(id);
        dst = fullfile(root, arm, id);
        if force && isfolder(dst), rmdir(dst, 's'); end
        if ~isfolder(dst), mkdir(dst); end

        [~, ~, inputs] = benchmark_fixtures(char(task.fixture), double(task.seed));
        save(fullfile(dst, 'input.mat'), '-struct', 'inputs', '-v7');
        write_prompt(dst, task, inputs);

        switch arm
            case 'R2', copy_docs(repo, dst);
            case 'R3', copy_skills(repo, dst);
        end

        files = dir(fullfile(dst, '**', '*'));
        files = files(~[files.isdir]);
        p = fullfile(dst, 'prompt.md');
        ip = fullfile(dst, 'input.mat');
        M.entries(end+1) = struct('arm', arm, 'task', id, 'dir', dst, ...
            'promptSha256', sha256_file(p), 'inputSha256', sha256_file(ip), ...
            'promptBytes', numel(fileread(p)), 'nFiles', numel(files), ...
            'usesRepoSkills', strcmp(arm, 'R3')); %#ok<AGROW>
        fprintf('%-3s %-12s files=%-4d %s\n', arm, id, numel(files), dst);
    end
end

mf = fullfile(root, 'stage_manifest.json');
fid = fopen(mf, 'w', 'n', 'UTF-8');
fwrite(fid, jsonencode(M, 'PrettyPrint', true), 'char'); fclose(fid);
fprintf('manifest: %s\n', mf);
end

% ---------------------------------------------------------------------------
function T = load_tasks(repo) %#ok<INUSD>
T = containers.Map('KeyType', 'char', 'ValueType', 'any');
for root = { 'E:\desktop\MATLAB-bench-holdout-phase53', ...
             'E:\desktop\MATLAB-bench-holdout-phase54' }
    d = jsondecode(fileread(fullfile(root{1}, 'tasks.json')));
    ts = d.tasks; if isstruct(ts), ts = num2cell(ts(:)); end
    for k = 1:numel(ts)
        T(char(ts{k}.id)) = ts{k};
    end
end
end

function write_prompt(dst, task, inputs)
id = char(task.id);
fs = field_spec(id);
vars = strjoin(fieldnames(inputs).', ', ');
lines = {
    '# 任务'
    ''
    char(task.prompt)
    ''
    '## 输入'
    ''
    sprintf('当前工作目录中的 `input.mat` 包含变量：%s。', vars)
    '只使用当前工作目录中的文件与本题面信息（工作目录中的其他文件如有也可以使用）；不要读取其他目录、参考答案、评分记录或历史结果。'
    ''
    '## 执行要求'
    ''
    '1. 通过 MATLAB MCP 工具执行 MATLAB 代码（不要另起本地 MATLAB 进程）。'
    '2. MATLAB MCP 调用不超过 25 次，总时长不超过 15 分钟。'
    '3. 不要修改 `input.mat`。'
    ''
    '## 判定口径'
    ''
    '- PASS：被核查的声明/结果被数据与计算证据支持。'
    '- FAIL：被核查的声明/结果被证据否定。'
    '- UNDETERMINED：判据缺失或证据不足，不能下结论；不得用 PASS 代替。'
    ''
    '## 输出'
    ''
    '在当前工作目录写入 `result.json`（UTF-8），格式：'
    ''
    '```json'
    '{"verdict":"PASS|FAIL|UNDETERMINED","fields":{...},"notes":"简要依据"}'
    '```'
    ''
    '`fields` 必须包含：'
    ''};
if isempty(fs)
    lines{end+1} = '（本题无强制数值字段；`fields` 可为空对象 `{}`）';
else
    for k = 1:size(fs, 1)
        lines{end+1} = sprintf('- `%s`：%s', fs{k, 1}, fs{k, 2}); %#ok<AGROW>
    end
end
lines = [lines; {
    ''
    '完成后只回复一句结论。'
    ''}];
fid = fopen(fullfile(dst, 'prompt.md'), 'w', 'n', 'UTF-8');
fprintf(fid, '%s\n', lines{:});
fclose(fid);
end

function fs = field_spec(id)
switch id
    case 'H-SIG-F'
        fs = {'measured_fPeak', '实测主频（Hz，数值）'};
    case 'H-DATA-B'
        fs = {'cond', '系数矩阵 A 的 2-范数条件数（数值）'};
    case 'H-ROB-F'
        fs = {'skewErr', '用 S = Mdot - 2C 的反对称性残差 max|S + S''| 检查科里奥利矩阵（数值）'};
    case 'H54-ODE-N'
        fs = {'error_maxScaled', 'max|y - yref| / (absTol + relTol*|yref|)（数值）'
              'invariant_maxRelDrift', 'y1^2 + y2^2 的最大相对漂移（数值）'
              'stiffness_classified', '"stiff" 或 "nonstiff"（字符串）'};
    case 'H54-ODE-F'
        fs = {'error_maxScaled', 'max|y - yref| / (absTol + relTol*|yref|)（数值）'};
    case 'H54-VIS-N'
        fs = {'metrics_f1', '像素级 F1（数值）'
              'objectMetrics_objectIouMean', '对象级平均 IoU（数值）'};
    case 'H54-VIS-F'
        fs = {'metrics_f1', '像素级 F1（数值）'
              'metrics_accuracy', '像素级准确率（数值）'
              'objectMetrics_objectIouMean', '对象级平均 IoU（数值）'};
    otherwise
        fs = {};
end
end

function copy_docs(repo, dst)
src = fullfile(repo, 'skills');
out = fullfile(dst, 'skills-docs');
if ~isfolder(out), mkdir(out); end
d = dir(src); d = d([d.isdir] & ~ismember({d.name}, {'.', '..'}));
for k = 1:numel(d)
    s = fullfile(src, d(k).name);
    if ~isfile(fullfile(s, 'SKILL.md')), continue; end
    t = fullfile(out, d(k).name);
    if ~isfolder(t), mkdir(t); end
    copyfile(fullfile(s, 'SKILL.md'), fullfile(t, 'SKILL.md'));
    if isfolder(fullfile(s, 'references'))
        copyfile(fullfile(s, 'references'), fullfile(t, 'references'));
    end
end
copyfile(fullfile(src, 'capability-matrix.json'), fullfile(out, 'capability-matrix.json'));
end

function copy_skills(repo, dst)
src = fullfile(repo, 'skills');
out = fullfile(dst, 'skills');
if ~isfolder(out), mkdir(out); end
d = dir(src); d = d([d.isdir] & ~ismember({d.name}, {'.', '..'}));
for k = 1:numel(d)
    copyfile(fullfile(src, d(k).name), fullfile(out, d(k).name));
end
copyfile(fullfile(src, 'capability-matrix.json'), fullfile(out, 'capability-matrix.json'));
end

function h = git_head(repo)
[st, txt] = system(sprintf('git -C "%s" rev-parse HEAD', repo));
if st == 0, h = strtrim(txt); else, h = 'UNKNOWN'; end
end

function h = sha256_file(p)
fid = fopen(p, 'r');
if fid < 0, error('stage_phase55:hash', 'cannot open %s', p); end
b = fread(fid, Inf, '*uint8'); fclose(fid);
md = java.security.MessageDigest.getInstance('SHA-256');
d = typecast(md.digest(b), 'uint8');
h = lower(reshape(dec2hex(d)', 1, []));
end
