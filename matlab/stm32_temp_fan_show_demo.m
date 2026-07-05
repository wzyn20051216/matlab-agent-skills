%% STM32F103C8T6 闭环温控/风扇调速可视化演示
% @file stm32_temp_fan_show_demo.m
% @brief 在 MATLAB 桌面中打开模型并动态展示自动调参过程。

clear; clc;

scriptPath = mfilename("fullpath");
repoRoot = fileparts(fileparts(scriptPath));
modelPath = fullfile(repoRoot, "artifacts", "models", "stm32f103_temp_fan_closed_loop.slx");
dataPath = fullfile(repoRoot, "artifacts", "data", "simulation_results.mat");
reportPath = fullfile(repoRoot, "artifacts", "reports", "ACCEPTANCE_REPORT.md");

assert(isfile(modelPath), "找不到模型文件: %s", modelPath);
assert(isfile(dataPath), "找不到仿真数据: %s", dataPath);

loaded = load(dataPath, "history", "simData", "params", "bestIdx", "bestPid");
history = loaded.history;
simData = loaded.simData;
params = loaded.params;
bestIdx = loaded.bestIdx;
bestPid = loaded.bestPid;

fprintf("\n=== STM32F103C8T6 闭环温控/风扇调速可视化演示 ===\n");
fprintf("模型: %s\n", modelPath);
fprintf("数据: %s\n", dataPath);
fprintf("报告: %s\n", reportPath);
fprintf("最佳轮次: %d, Kp=%.6g, Ki=%.6g, Kd=%.6g\n", bestIdx, bestPid.Kp, bestPid.Ki, bestPid.Kd);

open_system(modelPath);
set_param(bdroot, "ZoomFactor", "FitSystem");

fig = figure( ...
    "Name", "STM32F103C8T6 自动建模-仿真-调参演示", ...
    "NumberTitle", "off", ...
    "Color", "w", ...
    "Position", [80 80 1280 760]);

layout = tiledlayout(fig, 2, 2, "TileSpacing", "compact", "Padding", "compact");

axTemp = nexttile(layout, 1);
grid(axTemp, "on"); hold(axTemp, "on");
xlabel(axTemp, "时间/s");
ylabel(axTemp, "温度/degC");
title(axTemp, "阶跃响应 + 扰动恢复");
xline(axTemp, params.setpointStepTime, ":", "阶跃");
xline(axTemp, params.disturbanceTime, ":", "扰动");

axControl = nexttile(layout, 3);
grid(axControl, "on"); hold(axControl, "on");
xlabel(axControl, "时间/s");
ylabel(axControl, "PWM/%");
title(axControl, "风扇控制量与限幅");
yline(axControl, params.uMin, "k--");
yline(axControl, params.uMax, "k--");

axMetric = nexttile(layout, 2);
axis(axMetric, "off");
title(axMetric, "当前轮次指标");

axScore = nexttile(layout, 4);
grid(axScore, "on"); hold(axScore, "on");
xlabel(axScore, "轮次");
ylabel(axScore, "综合评分，越低越好");
title(axScore, "自动调参收敛过程");

colors = lines(numel(history));
scoreLine = animatedline(axScore, "LineWidth", 1.8, "Marker", "o");

for idx = 1:numel(history)
    sig = simData{idx};
    m = history(idx).metrics;

    plot(axTemp, sig.time, sig.temperature.value, "Color", colors(idx, :), "LineWidth", 1.4);
    if idx == 1
        plot(axTemp, sig.setpoint.time, sig.setpoint.value, "k--", "LineWidth", 1.0);
    end
    plot(axControl, sig.control.time, sig.control.value, "Color", colors(idx, :), "LineWidth", 1.4);
    addpoints(scoreLine, idx, history(idx).score);

    cla(axMetric);
    axis(axMetric, "off");
    statusText = "未达标";
    if m.accepted
        statusText = "达标";
    end
    if idx == bestIdx
        statusText = statusText + " / 最终采用";
    end

    text(axMetric, 0.02, 0.95, sprintf("第 %d/%d 轮自动调参", idx, numel(history)), ...
        "FontSize", 18, "FontWeight", "bold", "Units", "normalized");
    text(axMetric, 0.02, 0.82, sprintf("Kp = %.6g   Ki = %.6g   Kd = %.6g", history(idx).Kp, history(idx).Ki, history(idx).Kd), ...
        "FontSize", 14, "Units", "normalized");
    text(axMetric, 0.02, 0.70, sprintf("状态: %s", statusText), ...
        "FontSize", 14, "FontWeight", "bold", "Units", "normalized");
    text(axMetric, 0.02, 0.58, sprintf("超调: %.3f%%", m.overshootPct), "FontSize", 13, "Units", "normalized");
    text(axMetric, 0.02, 0.48, sprintf("稳态误差: %.3f degC", m.steadyStateError), "FontSize", 13, "Units", "normalized");
    text(axMetric, 0.02, 0.38, sprintf("调节时间: %.3f s", m.settlingTime), "FontSize", 13, "Units", "normalized");
    text(axMetric, 0.02, 0.28, sprintf("控制峰值: %.3f%%", m.controlPeak), "FontSize", 13, "Units", "normalized");
    text(axMetric, 0.02, 0.18, sprintf("饱和占比: %.3f", m.saturationFraction), "FontSize", 13, "Units", "normalized");
    text(axMetric, 0.02, 0.08, sprintf("扰动恢复: %.3f s", m.disturbanceRecoveryTime), "FontSize", 13, "Units", "normalized");

    legend(axTemp, "show", "Location", "southeast");
    legend(axControl, "show", "Location", "southeast");
    drawnow;
    pause(1.2);
end

best = simData{bestIdx};
figure("Name", "最终采用参数 - 单独响应", "NumberTitle", "off", "Color", "w", "Position", [140 120 1100 620]);
tiledlayout(2, 1, "TileSpacing", "compact");
nexttile;
plot(best.time, best.temperature.value, "LineWidth", 1.8); hold on;
plot(best.setpoint.time, best.setpoint.value, "k--", "LineWidth", 1.1);
xline(params.setpointStepTime, ":", "阶跃");
xline(params.disturbanceTime, ":", "扰动");
grid on;
xlabel("时间/s");
ylabel("温度/degC");
title(sprintf("最终参数: Kp=%.6g, Ki=%.6g, Kd=%.6g", bestPid.Kp, bestPid.Ki, bestPid.Kd));
legend("温度", "设定值", "Location", "southeast");

nexttile;
plot(best.control.time, best.control.value, "LineWidth", 1.8); hold on;
yline(params.uMin, "k--");
yline(params.uMax, "k--");
grid on;
xlabel("时间/s");
ylabel("PWM/%");
title("最终控制量");

fprintf("演示窗口已打开：Simulink 模型、5 轮调参动态曲线、最终响应曲线。\n");
