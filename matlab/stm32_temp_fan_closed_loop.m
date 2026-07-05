%% STM32F103C8T6 闭环温控/风扇调速自动工程
% @file stm32_temp_fan_closed_loop.m
% @brief 自动建模、仿真、评价、调参、验收和代码生成准备。

clear; clc;
rng(2320194668);

scriptPath = mfilename("fullpath");
repoRoot = fileparts(fileparts(scriptPath));
dirs = makeArtifactDirs(repoRoot);
diaryPath = fullfile(dirs.logs, "stm32_temp_fan_closed_loop_matlab.log");
if isfile(diaryPath)
    delete(diaryPath);
end
diary(diaryPath);
diary on;
cleanupDiary = onCleanup(@() diary("off"));

fprintf("STM32_TEMP_FAN_WORKFLOW_START=%s\n", string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss")));

env = probeEnvironment();
env.keilExe = getenv("KEIL_EXE");
if strlength(env.keilExe) == 0
    env.keilExe = "E:\keil5\UV4\UV4.exe";
end
env.keilAvailable = isfile(env.keilExe);

params = defaultPlantParams();
assignParamsToBase(params, struct("Kp", 1.0, "Ki", 0.006, "Kd", 0.0));

modelName = "stm32f103_temp_fan_closed_loop";
modelPath = fullfile(dirs.models, modelName + ".slx");
buildClosedLoopModel(modelName, modelPath, true, params);
assertModelLoads(modelPath, modelName);

candidates = [
    struct("Kp", 1.0, "Ki", 0.006, "Kd", 0.0)
    struct("Kp", 4.2, "Ki", 0.050, "Kd", 0.18)
    struct("Kp", 5.0, "Ki", 0.080, "Kd", 0.10)
    struct("Kp", 5.0, "Ki", 0.120, "Kd", 0.10)
    struct("Kp", 6.0, "Ki", 0.150, "Kd", 0.20)
];

history = repmat(struct(), numel(candidates), 1);
simData = cell(numel(candidates), 1);
bestIdx = 1;
bestScore = inf;

for idx = 1:numel(candidates)
    fprintf("TUNING_ROUND=%d Kp=%.6g Ki=%.6g Kd=%.6g\n", idx, candidates(idx).Kp, candidates(idx).Ki, candidates(idx).Kd);
    simIn = Simulink.SimulationInput(modelName);
    simIn = setCommonVariables(simIn, params, candidates(idx));
    simIn = simIn.setModelParameter("StopTime", num2str(params.stopTime));
    simOut = sim(simIn);
    assertSimulationReachedStopTime(simOut, params.stopTime);

    signals = extractSignals(simOut);
    assertSignalsNonEmpty(signals);
    metrics = evaluateTemperatureControl(signals, params);
    score = scoreMetrics(metrics);

    history(idx).round = idx;
    history(idx).Kp = candidates(idx).Kp;
    history(idx).Ki = candidates(idx).Ki;
    history(idx).Kd = candidates(idx).Kd;
    history(idx).metrics = metrics;
    history(idx).score = score;
    history(idx).accepted = metrics.accepted;
    history(idx).betterThanPreviousBest = score < bestScore;
    simData{idx} = signals;

    roundDataPath = fullfile(dirs.data, sprintf("round_%02d_results.mat", idx));
    save(roundDataPath, "signals", "metrics", "params", "-v7.3");

    if score < bestScore
        bestScore = score;
        bestIdx = idx;
    end
end

bestPid = candidates(bestIdx);
assignParamsToBase(params, bestPid);
bestSignals = simData{bestIdx};
bestMetrics = history(bestIdx).metrics;
baselineMetrics = history(1).metrics;

save(fullfile(dirs.data, "simulation_results.mat"), "history", "simData", "params", "bestIdx", "bestPid", "bestMetrics", "env", "-v7.3");
writeTuningCsv(fullfile(dirs.data, "tuning_history.csv"), history);
writeJson(fullfile(dirs.data, "tuning_history.json"), historyToSerializable(history));
plotResponseComparison(fullfile(dirs.figures, "response_baseline_vs_tuned.png"), simData{1}, bestSignals, params, bestIdx);
plotBestRound(fullfile(dirs.figures, "response_best_round.png"), bestSignals, params, bestIdx);

codegen = runCodeGeneration(dirs, params, bestPid, env);
validation = validateArtifacts(dirs, modelPath, params, bestMetrics, codegen);

writeEngineeringReadme(fullfile(dirs.reports, "ENGINEERING_README.md"), env, params, bestPid, bestMetrics, codegen);
writeAcceptanceReport(fullfile(dirs.reports, "ACCEPTANCE_REPORT.md"), env, params, history, bestIdx, baselineMetrics, bestMetrics, codegen, validation);
writeJson(fullfile(dirs.validation, "validation_summary.json"), validation);

fprintf("BEST_ROUND=%d\n", bestIdx);
fprintf("BEST_PID Kp=%.6g Ki=%.6g Kd=%.6g\n", bestPid.Kp, bestPid.Ki, bestPid.Kd);
fprintf("ACCEPTED=%d\n", bestMetrics.accepted);
fprintf("MODEL_PATH=%s\n", modelPath);
fprintf("CODEGEN_STATUS=%s\n", codegen.status);
fprintf("VALIDATION_SUMMARY=%s\n", fullfile(dirs.validation, "validation_summary.json"));
fprintf("STM32_TEMP_FAN_WORKFLOW_DONE=%s\n", string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss")));

%% 本地函数

function dirs = makeArtifactDirs(repoRoot)
% @brief 创建统一产物目录。
names = ["models", "figures", "data", "codegen", "reports", "validation", "logs"];
for idx = 1:numel(names)
    dirs.(names(idx)) = fullfile(repoRoot, "artifacts", names(idx));
    if ~isfolder(dirs.(names(idx)))
        mkdir(dirs.(names(idx)));
    end
end
end

function env = probeEnvironment()
% @brief 探测 MATLAB、Simulink、Coder 和 STM32 Blockset。
products = ver;
names = string({products.Name});
env = struct();
env.generatedAt = string(datetime("now", "Format", "yyyy-MM-dd'T'HH:mm:ss"));
env.matlabVersion = string(version);
env.release = string(version("-release"));
env.simulinkInstalled = any(names == "Simulink");
env.controlSystemToolboxInstalled = any(names == "Control System Toolbox");
env.matlabCoderInstalled = any(names == "MATLAB Coder");
env.simulinkCoderInstalled = any(names == "Simulink Coder");
env.embeddedCoderInstalled = any(names == "Embedded Coder");
env.stm32BlocksetInstalled = any(names == "STM32 Microcontroller Blockset");
env.licenses = struct( ...
    "simulink", logical(license("test", "Simulink")), ...
    "matlabCoder", logical(license("test", "MATLAB_Coder")), ...
    "simulinkCoder", logical(license("test", "Real-Time_Workshop")), ...
    "embeddedCoder", logical(license("test", "RTW_Embedded_Coder")));
env.registeredHardware = strings(0, 1);
try
    hw = codertarget.targethardware.getRegisteredTargetHardware;
    env.registeredHardware = string({hw.Name});
catch err
    env.hardwareProbeNote = string(err.message);
end
end

function params = defaultPlantParams()
% @brief 定义热对象、采样周期、扰动和验收阈值。
params = struct();
params.Ts = 0.1;
params.stopTime = 240;
params.ambientTemp = 25;
params.initialSetpoint = 30;
params.finalSetpoint = 60;
params.setpointStepTime = 10;
params.disturbanceTime = 130;
params.disturbanceMagnitude = -4;
params.plantGain = 0.46;
params.plantTau = 28;
params.lpfTau = 1.2;
params.uMin = 0;
params.uMax = 100;
params.plantA = exp(-params.Ts / params.plantTau);
params.plantNum = params.plantGain * (1 - params.plantA);
params.plantDen = [1, -params.plantA];
params.lpfA = exp(-params.Ts / params.lpfTau);
params.lpfNum = 1 - params.lpfA;
params.lpfDen = [1, -params.lpfA];
params.acceptance = struct( ...
    "overshootPctMax", 8, ...
    "steadyStateErrorMax", 0.75, ...
    "settlingTimeMax", 100, ...
    "controlPeakMax", 100.0001, ...
    "saturationFractionMax", 0.35, ...
    "tailSaturationFractionMax", 0.05, ...
    "oscillationStdMax", 0.45, ...
    "disturbanceRecoveryTimeMax", 55, ...
    "disturbanceFinalErrorMax", 0.85);
end

function assignParamsToBase(params, pid)
% @brief 将模型参数注入 base workspace，便于保存后的模型直接加载仿真。
fields = fieldnames(params);
for idx = 1:numel(fields)
    assignin("base", fields{idx}, params.(fields{idx}));
end
assignin("base", "Kp", pid.Kp);
assignin("base", "Ki", pid.Ki);
assignin("base", "Kd", pid.Kd);
end

function simIn = setCommonVariables(simIn, params, pid)
% @brief 为每轮仿真设置独立参数。
fields = fieldnames(params);
for idx = 1:numel(fields)
    simIn = simIn.setVariable(fields{idx}, params.(fields{idx}));
end
simIn = simIn.setVariable("Kp", pid.Kp);
simIn = simIn.setVariable("Ki", pid.Ki);
simIn = simIn.setVariable("Kd", pid.Kd);
end

function buildClosedLoopModel(modelName, modelPath, includeLogging, params)
% @brief 使用 Simulink API 自动创建闭环温控模型。
if bdIsLoaded(modelName)
    close_system(modelName, 0);
end
if isfile(modelPath)
    delete(modelPath);
end

new_system(modelName);
load_system("simulink");
set_param(modelName, ...
    "StopTime", num2str(params.stopTime), ...
    "SolverType", "Fixed-step", ...
    "Solver", "FixedStepDiscrete", ...
    "FixedStep", num2str(params.Ts), ...
    "SignalLogging", "on", ...
    "ReturnWorkspaceOutputs", "on");

add_block("simulink/Sources/Step", modelName + "/Setpoint_Step", ...
    "Time", "setpointStepTime", "Before", "initialSetpoint", "After", "finalSetpoint", ...
    "Position", [40 90 90 120]);
add_block("simulink/Math Operations/Sum", modelName + "/Error_Calculation", ...
    "Inputs", "+-", "Position", [150 91 180 119]);
addPidSubsystem(modelName + "/PID_Controller");
set_param(modelName + "/PID_Controller", "Position", [230 65 360 145]);
add_block("simulink/Discontinuities/Saturation", modelName + "/Control_Saturation", ...
    "UpperLimit", "uMax", "LowerLimit", "uMin", "Position", [410 85 460 125]);
add_block("simulink/Discrete/Discrete Transfer Fcn", modelName + "/Thermal_FirstOrder_Plant", ...
    "Numerator", "plantNum", "Denominator", "plantDen", "SampleTime", "Ts", ...
    "Position", [520 85 620 125]);
add_block("simulink/Sources/Constant", modelName + "/Ambient_Temperature", ...
    "Value", "ambientTemp", "Position", [520 155 580 185]);
add_block("simulink/Sources/Step", modelName + "/Disturbance_Input", ...
    "Time", "disturbanceTime", "Before", "0", "After", "disturbanceMagnitude", ...
    "Position", [520 220 580 250]);
add_block("simulink/Math Operations/Sum", modelName + "/Plant_Output_Sum", ...
    "Inputs", "+++", "Position", [690 103 720 157]);
add_block("simulink/Discrete/Discrete Transfer Fcn", modelName + "/Measurement_Lowpass_Filter", ...
    "Numerator", "lpfNum", "Denominator", "lpfDen", "SampleTime", "Ts", ...
    "Position", [780 110 895 150]);

add_line(modelName, "Setpoint_Step/1", "Error_Calculation/1", "autorouting", "on");
add_line(modelName, "Error_Calculation/1", "PID_Controller/1", "autorouting", "on");
add_line(modelName, "PID_Controller/1", "Control_Saturation/1", "autorouting", "on");
add_line(modelName, "Control_Saturation/1", "Thermal_FirstOrder_Plant/1", "autorouting", "on");
add_line(modelName, "Thermal_FirstOrder_Plant/1", "Plant_Output_Sum/1", "autorouting", "on");
add_line(modelName, "Ambient_Temperature/1", "Plant_Output_Sum/2", "autorouting", "on");
add_line(modelName, "Disturbance_Input/1", "Plant_Output_Sum/3", "autorouting", "on");
add_line(modelName, "Plant_Output_Sum/1", "Measurement_Lowpass_Filter/1", "autorouting", "on");
add_line(modelName, "Measurement_Lowpass_Filter/1", "Error_Calculation/2", "autorouting", "on");

if includeLogging
    addToWorkspace(modelName, "Setpoint_Step/1", "setpoint_ts", [105 25 180 55]);
    addToWorkspace(modelName, "Error_Calculation/1", "error_ts", [235 165 310 195]);
    addToWorkspace(modelName, "Control_Saturation/1", "control_ts", [455 25 530 55]);
    addToWorkspace(modelName, "Plant_Output_Sum/1", "temperature_ts", [725 55 800 85]);
    addToWorkspace(modelName, "Measurement_Lowpass_Filter/1", "measurement_ts", [900 165 980 195]);
    addToWorkspace(modelName, "Disturbance_Input/1", "disturbance_ts", [600 260 680 290]);
else
    addOutport(modelName, "Setpoint_Step/1", "setpoint_out", [945 45 975 65]);
    addOutport(modelName, "Control_Saturation/1", "control_out", [945 80 975 100]);
    addOutport(modelName, "Plant_Output_Sum/1", "temperature_out", [945 115 975 135]);
    addOutport(modelName, "Error_Calculation/1", "error_out", [945 150 975 170]);
end

Simulink.BlockDiagram.arrangeSystem(modelName);
save_system(modelName, modelPath);
end

function addPidSubsystem(subsystemPath)
% @brief 创建离散 PID 控制器子系统。
add_block("simulink/Ports & Subsystems/Subsystem", subsystemPath);
Simulink.SubSystem.deleteContents(subsystemPath);
add_block("simulink/Sources/In1", subsystemPath + "/error", "Position", [30 105 60 125]);
add_block("simulink/Math Operations/Gain", subsystemPath + "/Kp_Gain", "Gain", "Kp", "Position", [105 35 160 65]);
add_block("simulink/Math Operations/Gain", subsystemPath + "/Ki_Gain", "Gain", "Ki", "Position", [105 105 160 135]);
add_block("simulink/Discrete/Discrete-Time Integrator", subsystemPath + "/Integral_State", ...
    "gainval", "1", "SampleTime", "Ts", "InitialCondition", "0", "Position", [190 102 245 138]);
add_block("simulink/Discrete/Unit Delay", subsystemPath + "/Previous_Error", ...
    "SampleTime", "Ts", "InitialCondition", "0", "Position", [105 185 160 215]);
add_block("simulink/Math Operations/Sum", subsystemPath + "/Derivative_Difference", ...
    "Inputs", "+-", "Position", [190 181 220 219]);
add_block("simulink/Math Operations/Gain", subsystemPath + "/Kd_over_Ts_Gain", ...
    "Gain", "Kd/Ts", "Position", [250 185 325 215]);
add_block("simulink/Math Operations/Sum", subsystemPath + "/PID_Sum", ...
    "Inputs", "+++", "Position", [380 94 410 156]);
add_block("simulink/Sinks/Out1", subsystemPath + "/u_raw", "Position", [470 110 500 130]);

add_line(subsystemPath, "error/1", "Kp_Gain/1", "autorouting", "on");
add_line(subsystemPath, "error/1", "Ki_Gain/1", "autorouting", "on");
add_line(subsystemPath, "Ki_Gain/1", "Integral_State/1", "autorouting", "on");
add_line(subsystemPath, "error/1", "Derivative_Difference/1", "autorouting", "on");
add_line(subsystemPath, "error/1", "Previous_Error/1", "autorouting", "on");
add_line(subsystemPath, "Previous_Error/1", "Derivative_Difference/2", "autorouting", "on");
add_line(subsystemPath, "Derivative_Difference/1", "Kd_over_Ts_Gain/1", "autorouting", "on");
add_line(subsystemPath, "Kp_Gain/1", "PID_Sum/1", "autorouting", "on");
add_line(subsystemPath, "Integral_State/1", "PID_Sum/2", "autorouting", "on");
add_line(subsystemPath, "Kd_over_Ts_Gain/1", "PID_Sum/3", "autorouting", "on");
add_line(subsystemPath, "PID_Sum/1", "u_raw/1", "autorouting", "on");
end

function addToWorkspace(modelName, sourcePort, variableName, position)
% @brief 添加 To Workspace 日志块。
blockName = modelName + "/" + variableName;
add_block("simulink/Sinks/To Workspace", blockName, ...
    "VariableName", variableName, "SaveFormat", "Timeseries", "Position", position);
add_line(modelName, sourcePort, variableName + "/1", "autorouting", "on");
end

function addOutport(modelName, sourcePort, name, position)
% @brief 为代码生成模型添加顶层输出端口。
add_block("simulink/Sinks/Out1", modelName + "/" + name, "Position", position);
add_line(modelName, sourcePort, name + "/1", "autorouting", "on");
end

function assertModelLoads(modelPath, modelName)
% @brief 验证模型可加载。
load_system(modelPath);
assert(bdIsLoaded(modelName), "模型加载失败: %s", modelPath);
end

function assertSimulationReachedStopTime(simOut, stopTime)
% @brief 验证仿真运行到设定停止时间。
tout = simOut.tout;
assert(~isempty(tout), "仿真时间向量为空。");
assert(abs(tout(end) - stopTime) <= 1e-9 || tout(end) >= stopTime, "仿真未运行到 StopTime。");
end

function signals = extractSignals(simOut)
% @brief 读取 To Workspace 导出的关键信号。
signals = struct();
names = ["setpoint", "error", "control", "temperature", "measurement", "disturbance"];
vars = ["setpoint_ts", "error_ts", "control_ts", "temperature_ts", "measurement_ts", "disturbance_ts"];
for idx = 1:numel(names)
    ts = simOut.get(vars(idx));
    signals.(names(idx)).time = ts.Time(:);
    signals.(names(idx)).value = ts.Data(:);
end
signals.time = signals.temperature.time;
end

function assertSignalsNonEmpty(signals)
% @brief 验证关键日志信号非空且有限。
names = ["setpoint", "error", "control", "temperature", "measurement", "disturbance"];
for idx = 1:numel(names)
    sig = signals.(names(idx));
    assert(~isempty(sig.time) && ~isempty(sig.value), "信号为空: %s", names(idx));
    assert(all(isfinite(sig.value)), "信号包含非有限值: %s", names(idx));
end
end

function metrics = evaluateTemperatureControl(signals, params)
% @brief 自动评价超调、稳态误差、调节时间、饱和、振荡与扰动恢复。
t = signals.time;
y = signals.temperature.value;
r = interp1(signals.setpoint.time, signals.setpoint.value, t, "previous", "extrap");
u = interp1(signals.control.time, signals.control.value, t, "previous", "extrap");

afterStep = t >= params.setpointStepTime;
stepWindow = t >= params.setpointStepTime & t < params.disturbanceTime;
target = params.finalSetpoint;
postY = y(afterStep);
postT = t(afterStep);
stepY = y(stepWindow);
stepT = t(stepWindow);

metrics = struct();
metrics.overshootDegC = max(0, max(postY) - target);
metrics.overshootPct = 100 * metrics.overshootDegC / max(abs(target - params.initialSetpoint), eps);
metrics.steadyStateError = abs(mean(y(t >= params.stopTime - 15)) - target);
metrics.controlPeak = max(abs(u));
metrics.saturationFraction = mean(u >= params.uMax - 1e-6 | u <= params.uMin + 1e-6);
tail = t >= params.stopTime - 40;
metrics.tailSaturationFraction = mean(u(tail) >= params.uMax - 1e-6 | u(tail) <= params.uMin + 1e-6);

band = 0.75;
inside = abs(stepY - target) <= band;
settleIdx = findSettlingIndex(inside);
if isempty(settleIdx)
    metrics.settlingTime = inf;
else
    metrics.settlingTime = stepT(settleIdx) - params.setpointStepTime;
end

tailErr = y(t >= params.stopTime - 30) - target;
metrics.oscillationStd = std(tailErr);
metrics.oscillationPeakToPeak = max(tailErr) - min(tailErr);

disturbanceMask = t >= params.disturbanceTime;
distT = t(disturbanceMask);
distErr = abs(y(disturbanceMask) - target);
recoverIdx = findSettlingIndex(distErr <= params.acceptance.disturbanceFinalErrorMax);
if isempty(recoverIdx)
    metrics.disturbanceRecoveryTime = inf;
else
    metrics.disturbanceRecoveryTime = distT(recoverIdx) - params.disturbanceTime;
end
metrics.disturbanceFinalError = abs(mean(y(t >= params.stopTime - 15)) - target);

acc = params.acceptance;
metrics.accepted = ...
    metrics.overshootPct <= acc.overshootPctMax && ...
    metrics.steadyStateError <= acc.steadyStateErrorMax && ...
    metrics.settlingTime <= acc.settlingTimeMax && ...
    metrics.controlPeak <= acc.controlPeakMax && ...
    metrics.saturationFraction <= acc.saturationFractionMax && ...
    metrics.tailSaturationFraction <= acc.tailSaturationFractionMax && ...
    metrics.oscillationStd <= acc.oscillationStdMax && ...
    metrics.disturbanceRecoveryTime <= acc.disturbanceRecoveryTimeMax && ...
    metrics.disturbanceFinalError <= acc.disturbanceFinalErrorMax;
end

function idx = findSettlingIndex(inside)
% @brief 查找进入并保持在误差带内的第一个样本。
idx = [];
for k = 1:numel(inside)
    if all(inside(k:end))
        idx = k;
        return;
    end
end
end

function score = scoreMetrics(metrics)
% @brief 将多指标压缩为调参排序分数。
score = 0;
score = score + metrics.overshootPct * 2.0;
score = score + metrics.steadyStateError * 20.0;
score = score + min(metrics.settlingTime, 300) * 0.4;
score = score + metrics.saturationFraction * 35.0;
score = score + metrics.tailSaturationFraction * 100.0;
score = score + metrics.oscillationStd * 30.0;
score = score + min(metrics.disturbanceRecoveryTime, 200) * 0.5;
if metrics.accepted
    score = score - 1000;
end
end

function writeTuningCsv(csvPath, history)
% @brief 导出每轮调参记录。
fid = fopen(csvPath, "w");
cleanup = onCleanup(@() fclose(fid));
fprintf(fid, "round,Kp,Ki,Kd,overshoot_pct,steady_state_error,settling_time,control_peak,saturation_fraction,tail_saturation_fraction,oscillation_std,disturbance_recovery_time,disturbance_final_error,accepted,score,better_than_previous_best\n");
for idx = 1:numel(history)
    m = history(idx).metrics;
    fprintf(fid, "%d,%.10g,%.10g,%.10g,%.10g,%.10g,%.10g,%.10g,%.10g,%.10g,%.10g,%.10g,%.10g,%d,%.10g,%d\n", ...
        history(idx).round, history(idx).Kp, history(idx).Ki, history(idx).Kd, ...
        m.overshootPct, m.steadyStateError, m.settlingTime, m.controlPeak, ...
        m.saturationFraction, m.tailSaturationFraction, m.oscillationStd, ...
        m.disturbanceRecoveryTime, m.disturbanceFinalError, m.accepted, ...
        history(idx).score, history(idx).betterThanPreviousBest);
end
end

function data = historyToSerializable(history)
% @brief 转换为 JSON 友好的调参结构。
data = struct("rounds", []);
for idx = 1:numel(history)
    data.rounds(idx).round = history(idx).round;
    data.rounds(idx).Kp = history(idx).Kp;
    data.rounds(idx).Ki = history(idx).Ki;
    data.rounds(idx).Kd = history(idx).Kd;
    data.rounds(idx).metrics = history(idx).metrics;
    data.rounds(idx).score = history(idx).score;
    data.rounds(idx).accepted = history(idx).accepted;
    data.rounds(idx).betterThanPreviousBest = history(idx).betterThanPreviousBest;
end
end

function plotResponseComparison(path, baseline, tuned, params, bestIdx)
% @brief 导出调参前后响应对比图。
fig = figure("Visible", "off", "Color", "w", "Position", [100 100 1100 760]);
tiledlayout(3, 1, "TileSpacing", "compact");

nexttile;
plot(baseline.time, baseline.temperature.value, "LineWidth", 1.2); hold on;
plot(tuned.time, tuned.temperature.value, "LineWidth", 1.5);
plot(tuned.setpoint.time, tuned.setpoint.value, "k--", "LineWidth", 1.0);
xline(params.disturbanceTime, ":", "Disturbance");
grid on; ylabel("温度/degC");
legend("调参前", sprintf("调参后 round %d", bestIdx), "设定值", "Location", "southeast");
title("STM32F103C8T6 闭环温控响应对比");

nexttile;
plot(baseline.control.time, baseline.control.value, "LineWidth", 1.2); hold on;
plot(tuned.control.time, tuned.control.value, "LineWidth", 1.5);
yline(params.uMax, "k--");
grid on; ylabel("PWM/%");
legend("调参前", "调参后", "限幅", "Location", "southeast");

nexttile;
plot(tuned.error.time, tuned.error.value, "LineWidth", 1.4); hold on;
plot(tuned.disturbance.time, tuned.disturbance.value, "LineWidth", 1.0);
grid on; xlabel("时间/s"); ylabel("误差/扰动");
legend("误差", "扰动", "Location", "southeast");

exportgraphics(fig, path, "Resolution", 180);
close(fig);
end

function plotBestRound(path, signals, params, bestIdx)
% @brief 导出最终采用参数的响应曲线。
fig = figure("Visible", "off", "Color", "w", "Position", [100 100 1000 680]);
tiledlayout(2, 1, "TileSpacing", "compact");
nexttile;
plot(signals.time, signals.temperature.value, "LineWidth", 1.5); hold on;
plot(signals.setpoint.time, signals.setpoint.value, "k--", "LineWidth", 1.0);
xline(params.setpointStepTime, ":");
xline(params.disturbanceTime, ":");
grid on; ylabel("温度/degC");
title(sprintf("最佳调参轮次 %d 温度响应", bestIdx));
legend("温度", "设定值", "Location", "southeast");
nexttile;
plot(signals.control.time, signals.control.value, "LineWidth", 1.5);
yline(params.uMin, "k--"); yline(params.uMax, "k--");
grid on; xlabel("时间/s"); ylabel("控制量 PWM/%");
exportgraphics(fig, path, "Resolution", 180);
close(fig);
end

function codegen = runCodeGeneration(dirs, params, pid, env)
% @brief 在最优参数上尝试 STM32/ERT 代码生成。
codegen = struct();
codegen.status = "not_started";
codegen.modelName = "stm32f103_temp_fan_codegen";
codegen.modelPath = fullfile(dirs.models, codegen.modelName + ".slx");
codegen.generatedDir = fullfile(dirs.codegen, codegen.modelName + "_ert_rtw");
codegen.genericModelName = "stm32f103_temp_fan_codegen_generic_ert";
codegen.genericModelPath = fullfile(dirs.models, codegen.genericModelName + ".slx");
codegen.genericGeneratedDir = fullfile(dirs.codegen, codegen.genericModelName + "_ert_rtw");
codegen.generatedFiles = strings(0, 1);
codegen.projectFiles = strings(0, 1);
codegen.binaryFiles = strings(0, 1);
codegen.notes = strings(0, 1);

buildClosedLoopModel(codegen.modelName, codegen.modelPath, false, params);
load_system(codegen.modelPath);
assignParamsToBase(params, pid);
configureCodegenModel(codegen.modelName, params, env);

currentFolder = pwd;
cleanupFolder = onCleanup(@() cd(currentFolder));
cd(dirs.codegen);

try
    slbuild(codegen.modelName);
    codegen.status = "generated";
catch firstErr
    codegen.notes(end + 1) = "STM32/ERT 首次构建失败: " + string(firstErr.message);
    try
        if bdIsLoaded(codegen.modelName)
            close_system(codegen.modelName, 0);
        end
        buildClosedLoopModel(codegen.genericModelName, codegen.genericModelPath, false, params);
        load_system(codegen.genericModelPath);
        assignParamsToBase(params, pid);
        set_param(codegen.genericModelName, ...
            "StopTime", num2str(params.stopTime), ...
            "SolverType", "Fixed-step", ...
            "Solver", "FixedStepDiscrete", ...
            "FixedStep", num2str(params.Ts), ...
            "SystemTargetFile", "ert.tlc", ...
            "GenCodeOnly", "on", ...
            "TargetLang", "C", ...
            "GenerateReport", "off", ...
            "LaunchReport", "off");
        trySetParam(codegen.genericModelName, "ProdHWDeviceType", "ARM Compatible->ARM Cortex-M3");
        slbuild(codegen.genericModelName);
        codegen.status = "generated_with_generic_ert_fallback";
        codegen.generatedDir = codegen.genericGeneratedDir;
        save_system(codegen.genericModelName, codegen.genericModelPath);
    catch finalErr
        codegen.status = "failed";
        codegen.notes(end + 1) = "通用 ERT 降级构建仍失败: " + string(finalErr.message);
    end
end

if codegen.status == "failed"
    codegen = runMatlabCoderCoreFallback(dirs, params, pid, codegen);
end

codegen.generatedFiles = collectFiles(codegen.generatedDir);

projectPatterns = ["*.uvprojx", "*.uvproj", "*.ewp"];
for idx = 1:numel(projectPatterns)
    found = dir(fullfile(dirs.codegen, "**", projectPatterns(idx)));
    codegen.projectFiles = [codegen.projectFiles; string(fullfile({found.folder}, {found.name}))'];
end
binaryPatterns = ["*.elf", "*.axf", "*.hex", "*.bin"];
for idx = 1:numel(binaryPatterns)
    found = dir(fullfile(dirs.codegen, "**", binaryPatterns(idx)));
    codegen.binaryFiles = [codegen.binaryFiles; string(fullfile({found.folder}, {found.name}))'];
end

codegen.generatedNonEmpty = anyNonEmpty(codegen.generatedFiles);
codegen.projectNonEmpty = anyNonEmpty(codegen.projectFiles);
codegen.binaryNonEmpty = anyNonEmpty(codegen.binaryFiles);

writeDeployReadme(fullfile(dirs.codegen, "STM32F103C8T6_DEPLOYMENT_NOTES.md"), codegen, env, pid);
writeJson(fullfile(dirs.codegen, "codegen_summary.json"), codegen);
if bdIsLoaded(codegen.modelName)
    save_system(codegen.modelName, codegen.modelPath);
    close_system(codegen.modelName, 0);
end
if bdIsLoaded(codegen.genericModelName)
    save_system(codegen.genericModelName, codegen.genericModelPath);
    close_system(codegen.genericModelName, 0);
end
end

function cg = runMatlabCoderCoreFallback(dirs, params, pid, cg)
% @brief 在模型级代码生成失败时导出可集成的 PID 控制器 C 代码。
repoRoot = fileparts(fileparts(dirs.codegen));
matlabDir = fullfile(repoRoot, "matlab");
addpath(matlabDir);

coreDir = fullfile(dirs.codegen, "matlab_coder_core");
if ~isfolder(coreDir)
    mkdir(coreDir);
end

state = struct( ...
    "integrator", 0.0, ...
    "previousError", 0.0, ...
    "Ts", params.Ts, ...
    "Kp", pid.Kp, ...
    "Ki", pid.Ki, ...
    "Kd", pid.Kd, ...
    "uMin", params.uMin, ...
    "uMax", params.uMax);

currentFolder = pwd;
cleanupFolder = onCleanup(@() cd(currentFolder));
cd(coreDir);

try
    cfg = coder.config("lib");
    cfg.GenCodeOnly = true;
    cfg.GenerateReport = false;
    codegen -config cfg stm32_temp_fan_control_step -args {0.0, 0.0, coder.typeof(state)};
    generatedDir = fullfile(coreDir, "codegen", "lib", "stm32_temp_fan_control_step");
    cg.status = "generated_matlab_coder_core_fallback";
    cg.generatedDir = generatedDir;
    cg.notes(end + 1) = "已降级生成 MATLAB Coder 控制器核心 C 代码，可集成到 Keil/STM32 工程。";
catch err
    cg.notes(end + 1) = "MATLAB Coder 控制器核心降级生成失败: " + string(err.message);
end
end

function files = collectFiles(rootDir)
% @brief 收集目录下全部文件路径。
files = strings(0, 1);
if isfolder(rootDir)
    listing = dir(fullfile(rootDir, "**", "*.*"));
    listing = listing(~[listing.isdir]);
    files = string(fullfile({listing.folder}, {listing.name}))';
end
end

function configureCodegenModel(modelName, params, env)
% @brief 配置离散求解器、ERT 与可能的 STM32 硬件目标。
set_param(modelName, ...
    "StopTime", num2str(params.stopTime), ...
    "SolverType", "Fixed-step", ...
    "Solver", "FixedStepDiscrete", ...
    "FixedStep", num2str(params.Ts), ...
    "SystemTargetFile", "ert.tlc", ...
    "GenCodeOnly", "on", ...
    "TargetLang", "C", ...
    "GenerateReport", "off", ...
    "LaunchReport", "off");
trySetParam(modelName, "ProdHWDeviceType", "ARM Compatible->ARM Cortex-M3");
if env.stm32BlocksetInstalled
    candidates = ["STM32F103C8Tx Based", "STM32F103C8T6 Based", "STM32F103C8Tx", "STM32F103C8T6"];
    if isfield(env, "registeredHardware") && ~isempty(env.registeredHardware)
        f103 = env.registeredHardware(contains(lower(env.registeredHardware), "f103"));
        candidates = unique([f103(:); candidates(:)], "stable");
    end
    for idx = 1:numel(candidates)
        try
            set_param(modelName, "HardwareBoard", candidates(idx));
            fprintf("CODEGEN_HARDWARE_BOARD=%s\n", candidates(idx));
            return;
        catch
        end
    end
end
end

function ok = trySetParam(modelName, name, value)
% @brief 容错设置模型参数。
ok = true;
try
    set_param(modelName, name, value);
catch
    ok = false;
end
end

function tf = anyNonEmpty(paths)
% @brief 检查文件集合中是否存在非空文件。
tf = false;
for idx = 1:numel(paths)
    if isfile(paths(idx))
        info = dir(paths(idx));
        if info.bytes > 0
            tf = true;
            return;
        end
    end
end
end

function validation = validateArtifacts(dirs, modelPath, params, bestMetrics, codegen)
% @brief 对模型、仿真、数据、图表、报告和代码生成产物做强制验收。
validation = struct();
validation.generatedAt = string(datetime("now", "Format", "yyyy-MM-dd'T'HH:mm:ss"));
validation.modelLoads = false;
try
    load_system(modelPath);
    validation.modelLoads = true;
catch err
    validation.modelLoadError = string(err.message);
end
validation.simulationReachedStopTime = true;
validation.signalsNonEmpty = true;
validation.figureFilesNonEmpty = allFilesNonEmpty([ ...
    fullfile(dirs.figures, "response_baseline_vs_tuned.png"), ...
    fullfile(dirs.figures, "response_best_round.png")]);
validation.dataFilesNonEmpty = allFilesNonEmpty([ ...
    fullfile(dirs.data, "simulation_results.mat"), ...
    fullfile(dirs.data, "tuning_history.csv"), ...
    fullfile(dirs.data, "tuning_history.json")]);
validation.codegenArtifactsNonEmpty = codegen.generatedNonEmpty;
validation.projectArtifactsNonEmpty = codegen.projectNonEmpty;
validation.binaryArtifactsNonEmpty = codegen.binaryNonEmpty;
validation.accepted = bestMetrics.accepted;
validation.allRequiredForCurrentEnvironment = validation.modelLoads && ...
    validation.simulationReachedStopTime && validation.signalsNonEmpty && ...
    validation.figureFilesNonEmpty && validation.dataFilesNonEmpty && ...
    validation.codegenArtifactsNonEmpty;
end

function tf = allFilesNonEmpty(paths)
% @brief 检查多个路径均存在且非空。
tf = true;
for idx = 1:numel(paths)
    info = dir(paths(idx));
    tf = tf && ~isempty(info) && info.bytes > 0;
end
end

function writeEngineeringReadme(path, env, params, pid, metrics, codegen)
% @brief 写入工程使用说明。
lines = [
    "# STM32F103C8T6 闭环温控/风扇调速工程说明"
    ""
    "## 目标硬件"
    "- 开发板：STM32F103C8T6 最小系统板"
    "- MCU：STM32F103C8T6，ARM Cortex-M3"
    "- 优先工具链：STM32 Microcontroller Blockset + Keil"
    ""
    "## 模型结构"
    "- 设定值输入：Setpoint_Step"
    "- 误差计算：Error_Calculation"
    "- PID 控制器：PID_Controller 子系统"
    "- 控制量限幅：Control_Saturation，0~100%"
    "- 被控对象：Thermal_FirstOrder_Plant，一阶惯性热系统"
    "- 测量反馈：Measurement_Lowpass_Filter"
    "- 扰动输入：Disturbance_Input"
    ""
    "## 最终参数"
    sprintf("- Kp = %.6g, Ki = %.6g, Kd = %.6g", pid.Kp, pid.Ki, pid.Kd)
    sprintf("- 采样周期 Ts = %.3f s，停止时间 = %.1f s", params.Ts, params.stopTime)
    ""
    "## 最终指标"
    sprintf("- 超调 = %.3f%%", metrics.overshootPct)
    sprintf("- 稳态误差 = %.3f degC", metrics.steadyStateError)
    sprintf("- 调节时间 = %.3f s", metrics.settlingTime)
    sprintf("- 控制峰值 = %.3f%%", metrics.controlPeak)
    sprintf("- 饱和占比 = %.3f", metrics.saturationFraction)
    sprintf("- 扰动恢复时间 = %.3f s", metrics.disturbanceRecoveryTime)
    sprintf("- 是否达标 = %d", metrics.accepted)
    ""
    "## 环境"
    "- MATLAB：" + env.matlabVersion
    sprintf("- Simulink 可用：%d", env.simulinkInstalled)
    sprintf("- STM32 Microcontroller Blockset 可用：%d", env.stm32BlocksetInstalled)
    sprintf("- Simulink Coder 可用：%d", env.simulinkCoderInstalled)
    sprintf("- Embedded Coder 可用：%d", env.embeddedCoderInstalled)
    sprintf("- Keil 可用：%d，路径：%s", env.keilAvailable, env.keilExe)
    ""
    "## 代码生成"
    "- 状态：" + codegen.status
    "- 代码生成模型：" + codegen.modelPath
    "- 代码生成摘要：artifacts/codegen/codegen_summary.json"
    "- 部署说明：artifacts/codegen/STM32F103C8T6_DEPLOYMENT_NOTES.md"
];
writeLines(path, lines);
end

function writeAcceptanceReport(path, env, params, history, bestIdx, baseline, best, codegen, validation)
% @brief 写入验收报告。
lines = [
    "# STM32F103C8T6 闭环温控/风扇调速验收报告"
    ""
    "## 验收标准"
    sprintf("- 超调 <= %.3f%%", params.acceptance.overshootPctMax)
    sprintf("- 稳态误差 <= %.3f degC", params.acceptance.steadyStateErrorMax)
    sprintf("- 调节时间 <= %.3f s", params.acceptance.settlingTimeMax)
    sprintf("- 控制峰值 <= %.3f%%", params.acceptance.controlPeakMax)
    sprintf("- 总饱和占比 <= %.3f，末段饱和占比 <= %.3f", params.acceptance.saturationFractionMax, params.acceptance.tailSaturationFractionMax)
    sprintf("- 末段振荡标准差 <= %.3f degC", params.acceptance.oscillationStdMax)
    sprintf("- 扰动恢复时间 <= %.3f s，扰动后最终误差 <= %.3f degC", params.acceptance.disturbanceRecoveryTimeMax, params.acceptance.disturbanceFinalErrorMax)
    ""
    "## 自动调参记录"
    "| 轮次 | Kp | Ki | Kd | 超调% | 稳态误差 | 调节时间/s | 饱和占比 | 扰动恢复/s | 达标 | 分数 |"
    "|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
];
for idx = 1:numel(history)
    m = history(idx).metrics;
    lines(end + 1) = sprintf("| %d | %.4g | %.4g | %.4g | %.3f | %.3f | %.3f | %.3f | %.3f | %d | %.3f |", ...
        idx, history(idx).Kp, history(idx).Ki, history(idx).Kd, m.overshootPct, ...
        m.steadyStateError, m.settlingTime, m.saturationFraction, ...
        m.disturbanceRecoveryTime, m.accepted, history(idx).score);
end
lines = [lines
    ""
    "## 调参前 vs 调参后"
    sprintf("- 调参前：超调 %.3f%%，稳态误差 %.3f degC，调节时间 %.3f s，扰动恢复 %.3f s", baseline.overshootPct, baseline.steadyStateError, baseline.settlingTime, baseline.disturbanceRecoveryTime)
    sprintf("- 调参后：第 %d 轮，超调 %.3f%%，稳态误差 %.3f degC，调节时间 %.3f s，扰动恢复 %.3f s", bestIdx, best.overshootPct, best.steadyStateError, best.settlingTime, best.disturbanceRecoveryTime)
    sprintf("- 最终是否达标：%d", best.accepted)
    ""
    "## 工具链状态"
    "- MATLAB：" + env.matlabVersion
    sprintf("- Simulink：%d，MATLAB Coder：%d，Simulink Coder：%d，Embedded Coder：%d", env.simulinkInstalled, env.matlabCoderInstalled, env.simulinkCoderInstalled, env.embeddedCoderInstalled)
    sprintf("- STM32 Microcontroller Blockset：%d", env.stm32BlocksetInstalled)
    sprintf("- Keil：%d，路径：%s", env.keilAvailable, env.keilExe)
    ""
    "## 代码生成与部署"
    "- 代码生成状态：" + codegen.status
    sprintf("- 代码生成文件非空：%d", codegen.generatedNonEmpty)
    sprintf("- Keil/工程文件非空：%d", codegen.projectNonEmpty)
    sprintf("- elf/axf/hex/bin 非空：%d", codegen.binaryNonEmpty)
    ""
    "## 强制验收项"
    sprintf("- 模型可加载：%d", validation.modelLoads)
    sprintf("- 仿真运行到 StopTime：%d", validation.simulationReachedStopTime)
    sprintf("- 关键信号非空：%d", validation.signalsNonEmpty)
    sprintf("- 图表已导出且非空：%d", validation.figureFilesNonEmpty)
    sprintf("- 数据文件已导出且非空：%d", validation.dataFilesNonEmpty)
    sprintf("- 代码生成产物存在且非空：%d", validation.codegenArtifactsNonEmpty)
    sprintf("- 当前环境必需项通过：%d", validation.allRequiredForCurrentEnvironment)
];
if strlength(strjoin(codegen.notes, "")) > 0
    lines(end + 1) = "";
    lines(end + 1) = "## 代码生成备注";
    for idx = 1:numel(codegen.notes)
        lines(end + 1) = "- " + codegen.notes(idx);
    end
end
writeLines(path, lines);
end

function writeDeployReadme(path, codegen, env, pid)
% @brief 写入 STM32 后续编译/烧录说明。
lines = [
    "# STM32F103C8T6 部署准备说明"
    ""
    sprintf("- Keil 检测：%d，路径：%s", env.keilAvailable, env.keilExe)
    sprintf("- 最终 PID：Kp=%.6g, Ki=%.6g, Kd=%.6g", pid.Kp, pid.Ki, pid.Kd)
    "- 代码生成状态：" + codegen.status
    "- 生成模型：" + codegen.modelPath
    "- 生成目录：" + codegen.generatedDir
    ""
    "## 当前可交付"
    "- Simulink 代码生成模型可作为后续 STM32 硬件映射入口。"
    "- 若已生成 .c/.h，可将控制算法集成到 Keil 工程或继续配置 STM32 Microcontroller Blockset 硬件板。"
    "- 若未生成 .uvprojx/.hex/.bin，说明当前批处理未打通硬件工程导出或烧录阶段。"
    ""
    "## 后续编译/烧录"
    "- 打开生成的 Keil 工程文件（如存在 .uvprojx），选择 STM32F103C8T6 目标后编译。"
    "- 若仅有 ERT C 代码，需在 STM32CubeMX/Keil 工程中接入 ADC/PWM/定时器驱动，并调用生成的 step 函数。"
];
if ~isempty(codegen.projectFiles)
    lines(end + 1) = "";
    lines(end + 1) = "## 工程文件";
    for idx = 1:numel(codegen.projectFiles)
        lines(end + 1) = "- " + codegen.projectFiles(idx);
    end
end
if ~isempty(codegen.binaryFiles)
    lines(end + 1) = "";
    lines(end + 1) = "## 二进制文件";
    for idx = 1:numel(codegen.binaryFiles)
        lines(end + 1) = "- " + codegen.binaryFiles(idx);
    end
end
writeLines(path, lines);
end

function writeJson(path, value)
% @brief 写入 JSON 文件。
fid = fopen(path, "w");
cleanup = onCleanup(@() fclose(fid));
fprintf(fid, "%s", jsonencode(value, "PrettyPrint", true));
end

function writeLines(path, lines)
% @brief 写入 UTF-8 文本。
fid = fopen(path, "w", "n", "UTF-8");
cleanup = onCleanup(@() fclose(fid));
for idx = 1:numel(lines)
    fprintf(fid, "%s\n", lines(idx));
end
end
