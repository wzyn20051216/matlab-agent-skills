rng(42, "twister");

scriptPath = mfilename("fullpath");
repoRoot = fileparts(fileparts(fileparts(scriptPath)));
timestamp = string(datetime("now", "Format", "yyyyMMdd_HHmmss"));
outDir = fullfile(repoRoot, "artifacts", "validation", "smoke_" + timestamp);
figDir = fullfile(outDir, "figures");
modelDir = fullfile(outDir, "models");
dataDir = fullfile(outDir, "data");

mkdir(outDir);
mkdir(figDir);
mkdir(modelDir);
mkdir(dataDir);

summary = struct();
summary.generatedAt = string(datetime("now", "Format", "yyyy-MM-dd'T'HH:mm:ss"));
summary.matlabVersion = string(version);
summary.release = string(version("-release"));
summary.checks = struct();

x = linspace(0, 2*pi, 512)';
y = sin(x) + 0.05*cos(7*x);
p = polyfit(x, y, 7);
yFit = polyval(p, x);
rmse = sqrt(mean((y - yFit).^2));

summary.checks.numericFit.rmse = rmse;
summary.checks.numericFit.passed = rmse < 0.08;
assert(summary.checks.numericFit.passed, "Numeric fit smoke check failed.");

figurePath = fullfile(figDir, "numeric_fit.png");
fig = figure("Visible", "off");
plot(x, y, "b-", x, yFit, "r--", "LineWidth", 1.2);
grid on;
xlabel("x");
ylabel("y");
legend("signal", "fit", "Location", "best");
title("MATLAB R2026a smoke fit");
exportgraphics(fig, figurePath, "Resolution", 160);
close(fig);

summary.checks.figureExport.path = string(figurePath);
summary.checks.figureExport.passed = isfile(figurePath) && dir(figurePath).bytes > 0;
assert(summary.checks.figureExport.passed, "Figure export smoke check failed.");

dataPath = fullfile(dataDir, "numeric_fit.mat");
save(dataPath, "x", "y", "p", "yFit", "rmse");
summary.checks.dataExport.path = string(dataPath);
summary.checks.dataExport.passed = isfile(dataPath) && dir(dataPath).bytes > 0;
assert(summary.checks.dataExport.passed, "Data export smoke check failed.");

hasSimulink = license("test", "Simulink") || license("test", "SIMULINK");
summary.checks.simulink.available = hasSimulink;

if hasSimulink
    modelName = "matlab_skill_smoke_model";
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
    set_param(modelName, "StopTime", "1", "Solver", "ode45", "ReturnWorkspaceOutputs", "on");

    simOut = sim(modelName);
    yout = simOut.get("yout");
    modelPath = fullfile(modelDir, modelName + ".slx");
    save_system(modelName, modelPath);
    close_system(modelName, 0);

    summary.checks.simulink.modelPath = string(modelPath);
    summary.checks.simulink.sampleCount = size(yout, 1);
    summary.checks.simulink.passed = isfile(modelPath) && ~isempty(yout) && all(isfinite(yout(:)));
    assert(summary.checks.simulink.passed, "Simulink smoke check failed.");
else
    summary.checks.simulink.passed = false;
    summary.checks.simulink.reason = "Simulink unavailable or unlicensed.";
end

summaryPath = fullfile(outDir, "summary.json");
fid = fopen(summaryPath, "w");
cleanup = onCleanup(@() fclose(fid));
fprintf(fid, "%s", jsonencode(summary, "PrettyPrint", true));
clear cleanup

fprintf("VALIDATION_ARTIFACTS=%s\n", outDir);
fprintf("NUMERIC_RMSE=%.12f\n", rmse);
fprintf("FIGURE_PATH=%s\n", figurePath);
if hasSimulink
    fprintf("SIMULINK_MODEL=%s\n", modelPath);
end
