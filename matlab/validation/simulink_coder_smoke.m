scriptPath = mfilename("fullpath");
repoRoot = fileparts(fileparts(fileparts(scriptPath)));
scriptDir = fileparts(scriptPath);
outDir = fullfile(repoRoot, "artifacts", "validation", "simulink_coder_smoke");
if ~isfolder(outDir)
    mkdir(outDir);
end

modelName = "simulink_coder_smoke_model";
if bdIsLoaded(modelName)
    close_system(modelName, 0);
end

new_system(modelName);
load_system("simulink");
add_block("simulink/Sources/Step", modelName + "/Step", "Position", [80 80 120 120]);
add_block("simulink/Math Operations/Gain", modelName + "/Gain", "Gain", "3", "Position", [170 80 230 120]);
add_block("simulink/Sinks/Out1", modelName + "/Out1", "Position", [290 80 330 120]);
add_line(modelName, "Step/1", "Gain/1");
add_line(modelName, "Gain/1", "Out1/1");

set_param(modelName, ...
    "StopTime", "1", ...
    "Solver", "FixedStepAuto", ...
    "SystemTargetFile", "grt.tlc", ...
    "GenCodeOnly", "on");

modelPath = fullfile(outDir, modelName + ".slx");
save_system(modelName, modelPath);

currentFolder = pwd;
cleanupFolder = onCleanup(@() cd(currentFolder));
cd(scriptDir);
slbuild(modelName);

generatedC = fullfile(scriptDir, modelName + "_grt_rtw", modelName + ".c");
summary = struct();
summary.generatedAt = string(datetime("now", "Format", "yyyy-MM-dd'T'HH:mm:ss"));
summary.modelPath = string(modelPath);
summary.generatedC = string(generatedC);
summary.passed = isfile(generatedC);
assert(summary.passed, "Simulink Coder smoke check failed.");

summaryPath = fullfile(outDir, "summary.json");
fid = fopen(summaryPath, "w");
cleanup = onCleanup(@() fclose(fid));
fprintf(fid, "%s", jsonencode(summary, "PrettyPrint", true));
clear cleanup

close_system(modelName, 0);

fprintf("SIMULINK_CODER_SMOKE=%s\n", summaryPath);
fprintf("GENERATED_C=%s\n", generatedC);
