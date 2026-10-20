function result = desktop_control_task(outDir)
% @brief Desktop Agent 为双端同题验收生成的控制分析任务。
% @param outDir 原始 MATLAB 日志、代码版本及结果的输出目录。
% @return result 实测裕度、闭环极点及稳定性；不读取评测参考值。
% @details 本文件必须由 Desktop 的官方 MATLAB MCP 工具实际执行。
% 文件存在或其他客户端执行成功，均不能证明 Desktop 执行通过。

if nargin < 1 || isempty(outDir)
    error('mas:phase44:OutputRequired', '请明确指定本次验收输出目录。');
end
if ~isfolder(outDir), mkdir(outDir); end
diary(fullfile(outDir, 'matlab_output.log'));
diaryCleanup = onCleanup(@() diary('off')); %#ok<NASGU>
t0 = tic;

% 从当前系统用户的共享安装读取工具，不改变 MATLAB 的现有 MCP 路径。
profileDir = getenv('USERPROFILE');
if isempty(profileDir), profileDir = getenv('HOME'); end
skillRoot = fullfile(profileDir, '.agents', 'skills');
names = {'matlab-orchestrator', 'matlab-runner', ...
    'matlab-control-optimization'};
for k = 1:numel(names)
    addpath(fullfile(skillRoot, names{k}, 'scripts'));
end
prompt = ['分析单位负反馈系统，开环 L(s)=10/((s+1)*(s+2))。' ...
    '报告0 dB交越处相位裕度、增益裕度、闭环是否稳定及闭环极点。'];
route = mas_route(prompt);
assert(strcmp(route.decision, 'ROUTE'), '任务路由未通过。');
assert(any(strcmp(route.loadOrder, 'matlab-control-optimization')), ...
    '控制任务未选中控制技能。');
precheck = mas_precheck('toolbox', 'Control System Toolbox');
assert(precheck.pass, '%s', precheck.detail);

s = tf('s');
L = 10 / ((s + 1) * (s + 2));
[gm, pm, ~, wc] = margin(L);
closedLoop = feedback(L, 1);
p = pole(closedLoop);
analysis = mas_ctrl_analyze(L);
assert(isfinite(pm) && abs(pm - analysis.pmWorst) < 0.05, ...
    '内置 margin 与技能的频域扫描不一致。');

result = struct();
result.client = 'Codex Desktop';
result.taskId = 'B2';
result.pmDeg = pm;
if isinf(gm), result.gainMargin = 'Inf'; else, result.gainMargin = gm; end
result.loopStable = isstable(closedLoop);
result.poles = [real(p), imag(p)];
result.crossoverRadS = wc;
result.matlabVersion = version;
result.matlabRelease = version('-release');
result.productCount = numel(ver);
result.matlabPid = feature('getpid');
result.timestamp = char(datetime('now', 'TimeZone', 'local', 'Format', 'yyyy-MM-dd''T''HH:mm:ssXXX'));
result.elapsedMs = toc(t0) * 1000;
result.skillRoot = skillRoot;
result.route = route;
result.analyzerPhaseMargin = analysis.pmWorst;
fid = fopen(fullfile(outDir, 'result.json'), 'w', 'n', 'UTF-8');
assert(fid >= 0, '无法写入实测结果。');
fileCleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
fprintf(fid, '%s', jsonencode(result, 'PrettyPrint', true));
save(fullfile(outDir, 'control_analysis.mat'), 'L', 'closedLoop', 'analysis', 'result');
% 所有产物保存完成后才发布结果行，避免后续保存失败留下过早的成功证据。
fprintf('MAS_RESULT %s\n', jsonencode(result));
end
