function result = design_pid()
% @brief 为 P(s)=1/(s+1) 设计连续时间并联 PID，并验证单位阶跃指标。
% @return result 包含 PID 增益、百分比超调量及按 2% 误差带计算的调节时间。
% @details 采用单位负反馈和理想微分项；闭环极点配置为 -3 的双极点。

projectRoot = fileparts(mfilename('fullpath'));
logDir = fullfile(projectRoot, 'artifacts', 'logs');
figureDir = fullfile(projectRoot, 'artifacts', 'figures');
dataDir = fullfile(projectRoot, 'artifacts', 'data');
validationDir = fullfile(projectRoot, 'artifacts', 'validation');
folders = {logDir, figureDir, dataDir, validationDir};
for k = 1:numel(folders)
    if ~isfolder(folders{k})
        mkdir(folders{k});
    end
end
[logFile, logMessage] = fopen(fullfile(logDir, 'pid_simulation.log'), 'w', 'n', 'UTF-8');
assert(logFile ~= -1, '无法打开仿真日志：%s', logMessage);
logCleanup = onCleanup(@() fclose(logFile));
fprintf(logFile, 'MATLAB: %s\nProject: %s\n', version, projectRoot);
fprintf('MATLAB: %s\nProject: %s\n', version, projectRoot);
assert(license('test', 'Control_Toolbox'), '需要 Control System Toolbox 许可证。');
addpath(fullfile(projectRoot, '.agents', 'skills', ...
    'matlab-control-optimization', 'scripts'));

% 特征多项式为 (1+Kd)s^2+(1+Kp)s+Ki，令其等于 1.1(s+3)^2。
plant = tf(1, [1, 1]);
Kd = 0.1;
poleRate = 3;
Kp = 2 * (1 + Kd) * poleRate - 1;
Ki = (1 + Kd) * poleRate^2;
controller = pid(Kp, Ki, Kd);
openLoop = controller * plant;
closedLoop = feedback(openLoop, 1);
stability = mas_stability_verdict(openLoop);
assert(isstable(closedLoop), '闭环极点未通过稳定性检查。');
assert(strcmp(stability.math.stability, 'STABLE'), '稳定性证据不一致。');
assert(abs(dcgain(closedLoop) - 1) < 1e-12, '单位阶跃稳态误差非零。');

% 仿真 10 秒，以 0.1 毫秒间隔采样，并明确指定阶跃前输出和最终值。
sampleInterval = 1e-4;
time = (0:sampleInterval:10).';
[response, time] = step(closedLoop, time);
metrics = stepinfo(response, time, 1, 0, 'SettlingTimeThreshold', 0.02);
assert(all(isfinite(response)), '阶跃响应包含非有限值。');

% 独立解析校核：y(t)=1+(20t-10)exp(-3t)/11，包括理想微分的初始跃变。
referenceResponse = 1 + (20 * time - 10) .* exp(-3 * time) / 11;
maxAbsoluteError = max(abs(response - referenceResponse));
absoluteTolerance = 1e-9;
relativeTolerance = 1e-9;
assert(maxAbsoluteError <= absoluteTolerance + ...
    relativeTolerance * max(abs(referenceResponse)), '仿真与解析响应不符。');
referenceOvershoot = 100 * (20 / 33) * exp(-2.5);
referenceSettlingTime = fzero(@(t) (20*t - 10)*exp(-3*t)/11 - 0.02, [1, 2]);
assert(abs(metrics.Overshoot - referenceOvershoot) < 1e-5, '超调量校核失败。');
assert(abs(metrics.SettlingTime - referenceSettlingTime) < ...
    2 * sampleInterval, '调节时间校核失败。');
assert(metrics.Overshoot < 10, '超调量未满足严格小于 10%% 的要求。');
assert(metrics.SettlingTime < 2, '调节时间未满足严格小于 2 秒的要求。');
assert(abs(response(end) - 1) < 1e-9, '仿真终点尚未收敛。');

result = struct('Kp', Kp, 'Ki', Ki, 'Kd', Kd, ...
    'overshootPercent', metrics.Overshoot, ...
    'settlingTimeSeconds', metrics.SettlingTime);
% 重根的数值计算可能产生微小虚部，JSON 中分别保存实部与虚部。
closedLoopPoles = pole(closedLoop);
poleEvidence = struct('real', real(closedLoopPoles), 'imag', imag(closedLoopPoles));
evidence = struct('matlabVersion', version, 'toolboxes', ver('control'), ...
    'sampleIntervalSeconds', sampleInterval, 'simulationDurationSeconds', time(end), ...
    'settlingThreshold', 0.02, 'closedLoopPoles', poleEvidence, ...
    'dcGain', dcgain(closedLoop), 'maxAbsoluteError', maxAbsoluteError, ...
    'absoluteTolerance', absoluteTolerance, 'relativeTolerance', relativeTolerance, ...
    'referenceOvershootPercent', referenceOvershoot, ...
    'referenceSettlingTimeSeconds', referenceSettlingTime, ...
    'stability', rmfield(stability, 'analysis'), ...
    'metrics', metrics, 'requirementsPassed', true);
save(fullfile(dataDir, 'pid_step.mat'), 'plant', 'controller', ...
    'closedLoop', 'time', 'response', 'metrics', 'result');

responseFigure = figure('Name', 'PID 闭环单位阶跃响应', 'Color', 'w');
responseTrace = plot(time, response, 'LineWidth', 1.5);
hold on;
targetTrace = yline(1, '--');
bandTrace = yline(1.02, ':');
yline(0.98, ':');
settlingTrace = xline(metrics.SettlingTime, '--');
legend([responseTrace, targetTrace, bandTrace, settlingTrace], ...
    {'闭环响应', '目标值', '±2% 误差带', '调节时间'}, 'Location', 'southeast');
grid on;
xlim([0, 3]);
ylim([0, 1.12]);
xlabel('时间 (s)');
ylabel('输出 y(t)');
title(sprintf('Kp = %.1f, Ki = %.1f, Kd = %.1f', Kp, Ki, Kd));
exportgraphics(responseFigure, fullfile(figureDir, 'pid_step.png'), 'Resolution', 150);

writeJson(fullfile(validationDir, 'simulation_evidence.json'), evidence);
resultPath = fullfile(projectRoot, 'result.json');
writeJson(resultPath, result);
assert(isequal(jsondecode(fileread(resultPath)), result), 'result.json 回读校核失败。');
fprintf('%s\n', jsonencode(result, 'PrettyPrint', true));
fprintf('PASS: 2%% settling band; simulation agrees with analytical response.\n');
fprintf(logFile, '%s\n', jsonencode(result, 'PrettyPrint', true));
fprintf(logFile, 'Maximum absolute simulation error: %.16g\n', maxAbsoluteError);
fprintf(logFile, 'PASS: stability, unit DC gain, analytical response, performance, JSON read-back.\n');
end

function writeJson(filePath, value)
% @brief 将结构体保存为 UTF-8 JSON，并确保文件句柄在异常时关闭。
% @param filePath 输出文件的绝对路径。
% @param value 待编码的结构体。
[fileId, message] = fopen(filePath, 'w', 'n', 'UTF-8');
assert(fileId ~= -1, '无法写入 %s：%s', filePath, message);
fileCleanup = onCleanup(@() fclose(fileId));
fprintf(fileId, '%s\n', jsonencode(value, 'PrettyPrint', true));
end
