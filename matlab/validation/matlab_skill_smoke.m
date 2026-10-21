scriptPath = mfilename("fullpath");
repoRoot = fileparts(fileparts(fileparts(scriptPath)));
scriptDir = fileparts(scriptPath);
addpath(scriptDir);

outDir = fullfile(repoRoot, "artifacts", "validation", "skill_smoke");
figDir = fullfile(outDir, "figures");
modelDir = fullfile(outDir, "models");
dataDir = fullfile(outDir, "data");
acceptanceDir = fullfile(repoRoot, "artifacts", "validation", "acceptance");
for folder = [string(outDir), string(figDir), string(modelDir), string(dataDir), string(acceptanceDir)]
    if ~isfolder(folder)
        mkdir(folder);
    end
end

rng(42, "twister");
report = masacc.new("skill-smoke", "matlab-batch");
report.limitations = [
    "数值验收使用固定随机种子与解析基准，可重复；不代表用户真实工程数据上的精度。"
    "Simulink 子项只验证模型能更新、能仿真、关键输出符合解析预期，不验证硬件部署。"
];

% ---------------- 数值拟合（L3） ----------------
x = linspace(0, 2*pi, 512)';
y = sin(x) + 0.05*cos(7*x);
p = polyfit(x, y, 7);
yFit = polyval(p, x);
rmse = sqrt(mean((y - yFit).^2));
rmseThreshold = 0.08;

% 独立基准：x(1)=0 时解析值应为 sin(0)+0.05*cos(0)=0.05。
analyticFirst = 0.05;
firstSampleError = abs(y(1) - analyticFirst);
firstSampleOk = firstSampleError <= 1e-12;

fitOk = (rmse < rmseThreshold) && firstSampleOk && all(isfinite(yFit));
fitMetrics = struct("rmse", rmse, "rmseThreshold", rmseThreshold, ...
    "firstSampleError", firstSampleError, "sampleCount", numel(x), "polyOrder", 7);

if fitOk
    report = masacc.addCheck(report, "skill.numeric-fit", "多项式拟合误差在容限内", "L3", "PASS", ...
        Command="polyfit/polyval + 解析基准点", Metrics=fitMetrics);
else
    if ~firstSampleOk
        reason = sprintf("首个采样点偏离解析基准 %.3e（容限 1e-12）", firstSampleError);
    else
        reason = sprintf("RMSE %.6f 超过阈值 %.3f", rmse, rmseThreshold);
    end
    report = masacc.addCheck(report, "skill.numeric-fit", "多项式拟合误差在容限内", "L3", "FAIL", ...
        Reason=reason, ErrorClass="VALIDATION_ERROR", Command="polyfit/polyval + 解析基准点", Metrics=fitMetrics);
end

% ---------------- 图像导出（L1） ----------------
figurePath = fullfile(figDir, "numeric_fit.png");
figureOk = false;
figureError = "";
try
    fig = figure("Visible", "off");
    cleanupFig = onCleanup(@() close(fig));
    plot(x, y, "b-", x, yFit, "r--", "LineWidth", 1.2);
    grid on;
    xlabel("x");
    ylabel("y");
    legend("signal", "fit", "Location", "best");
    title("MATLAB R2026a smoke fit");
    exportgraphics(fig, figurePath, "Resolution", 160);
    clear cleanupFig
    figureOk = isfile(figurePath) && dir(figurePath).bytes > 0;
catch ME
    figureError = string(ME.message);
end

if figureOk
    report = masacc.addCheck(report, "skill.figure-export", "导出 PNG 图表", "L1", "PASS", ...
        Metrics=struct("bytes", dir(figurePath).bytes), ArtifactPaths=[string(figurePath)]);
else
    report = masacc.addCheck(report, "skill.figure-export", "导出 PNG 图表", "L1", "FAIL", ...
        Reason="图像未生成或为空：" + figureError, ErrorClass="MATLAB_RUNTIME_ERROR", ...
        ArtifactPaths=[string(figurePath)]);
end

% ---------------- 数据导出（L1） ----------------
dataPath = fullfile(dataDir, "numeric_fit.mat");
dataOk = false;
try
    save(dataPath, "x", "y", "p", "yFit", "rmse");
    dataOk = isfile(dataPath) && dir(dataPath).bytes > 0;
catch ME
    dataError = string(ME.message);
end
if ~dataOk && exist("dataError", "var") == 0
    dataError = "文件未生成";
end

if dataOk
    report = masacc.addCheck(report, "skill.data-export", "保存 .mat 数据", "L1", "PASS", ...
        Metrics=struct("bytes", dir(dataPath).bytes), ArtifactPaths=[string(dataPath)]);
else
    report = masacc.addCheck(report, "skill.data-export", "保存 .mat 数据", "L1", "FAIL", ...
        Reason="数据文件未生成或为空：" + dataError, ErrorClass="MATLAB_RUNTIME_ERROR", ...
        ArtifactPaths=[string(dataPath)]);
end

% ---------------- Simulink 仿真（L3） ----------------
simulinkInfo = masacc.availability("Simulink");
modelName = "matlab_skill_smoke_model";
modelPath = fullfile(modelDir, modelName + ".slx");

if ~simulinkInfo.available
    report = masacc.addCheck(report, "skill.simulink-sim", "最小 Simulink 模型仿真输出正确", "L3", "SKIP", ...
        Reason=simulinkInfo.reason + "；仿真验收无法执行", ErrorClass="ENVIRONMENT_ERROR");
else
    started = masacc.timestamp();
    elapsed = tic;
    try
        if bdIsLoaded(modelName)
            close_system(modelName, 0);
        end
        new_system(modelName);
        add_block("simulink/Sources/Sine Wave", modelName + "/Sine", "Position", [100 100 160 140]);
        add_block("simulink/Math Operations/Gain", modelName + "/Gain", "Gain", "2", "Position", [220 100 280 140]);
        add_block("simulink/Sinks/To Workspace", modelName + "/Y", ...
            "VariableName", "yout", "SaveFormat", "Array", "Position", [340 100 420 140]);
        add_line(modelName, "Sine/1", "Gain/1");
        add_line(modelName, "Gain/1", "Y/1");
        set_param(modelName, "StopTime", "5", "Solver", "ode45", "MaxStep", "0.01", ...
            "SaveOutput", "on", "SaveFormat", "Array", "ReturnWorkspaceOutputs", "on");

        simOut = sim(modelName);
        yout = simOut.get("yout");
        save_system(modelName, modelPath);

        sampleCount = numel(yout);
        peak = max(yout(:));
        trough = min(yout(:));
        finiteOk = all(isfinite(yout(:)));
        % 解析预期：Sine Wave 默认 1 rad/s，乘 2 之后峰值出现在 pi/2、谷值出现在 3*pi/2。
        % 仿真时长必须覆盖 3*pi/2，否则谷值永远到不了 -2：
        % 第一次把 StopTime 设成 1，实测峰值 1.6829 = 2*sin(1)；
        % 第二次设成 2，峰值到了 1.9999 但谷值仍是 0.0000。两次都是这条断言抓出来的。
        peakTime = pi / 2;
        troughTime = 3 * pi / 2;
        requiredStopTime = troughTime;
        coversExtrema = str2double(get_param(modelName, "StopTime")) >= requiredStopTime;
        amplitudeOk = abs(peak - 2) <= 0.01 && abs(trough + 2) <= 0.01;
        simOk = sampleCount > 100 && finiteOk && amplitudeOk && isfile(modelPath);

        simMetrics = struct("sampleCount", sampleCount, "peak", peak, "trough", trough, ...
            "expectedAmplitude", 2, "tolerance", 0.01, "stopTime", get_param(modelName, "StopTime"), ...
            "peakTimeRad", peakTime, "troughTimeRad", troughTime, "coversExtrema", coversExtrema, ...
            "modelPath", string(modelPath));
        if simOk
            report = masacc.addCheck(report, "skill.simulink-sim", "最小 Simulink 模型仿真输出正确", "L3", "PASS", ...
                Command="new_system/sim", Metrics=simMetrics, StartedAt=started, ...
                FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed), ...
                ArtifactPaths=[string(modelPath)]);
        else
            if ~coversExtrema
                failureReason = sprintf("仿真时长 %s 秒未覆盖谷值时刻 3*pi/2≈%.3f 秒：samples=%d peak=%.4f trough=%.4f", ...
                    get_param(modelName, "StopTime"), troughTime, sampleCount, peak, trough);
            else
                failureReason = sprintf("仿真输出不符合预期：samples=%d peak=%.4f trough=%.4f finite=%d", ...
                    sampleCount, peak, trough, finiteOk);
            end
            report = masacc.addCheck(report, "skill.simulink-sim", "最小 Simulink 模型仿真输出正确", "L3", "FAIL", ...
                Reason=failureReason, ErrorClass="VALIDATION_ERROR", ...
                Command="new_system/sim", Metrics=simMetrics, StartedAt=started, ...
                FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed), ...
                ArtifactPaths=[string(modelPath)]);
        end
    catch ME
        report = masacc.addCheck(report, "skill.simulink-sim", "最小 Simulink 模型仿真输出正确", "L3", "FAIL", ...
            Reason=string(ME.message), ErrorClass=masacc.classifyError(ME), ...
            Command="new_system/sim", StartedAt=started, FinishedAt=masacc.timestamp(), ...
            DurationSeconds=toc(elapsed), ArtifactPaths=[string(modelPath)]);
    end
    if bdIsLoaded(modelName)
        close_system(modelName, 0);
    end
end

acceptancePath = fullfile(acceptanceDir, "skill_smoke.json");
report = masacc.write(report, acceptancePath);

fprintf("VALIDATION_ARTIFACTS=%s\n", outDir);
fprintf("SKILL_SMOKE_ACCEPTANCE=%s\n", acceptancePath);
fprintf("NUMERIC_RMSE=%.12f\n", rmse);
fprintf("FIGURE_PATH=%s\n", figurePath);
fprintf("SKILL_SMOKE_OVERALL=%s\n", report.overallStatus);
fprintf("SKILL_SMOKE_LEVEL=%s\n", report.achievedLevel);
