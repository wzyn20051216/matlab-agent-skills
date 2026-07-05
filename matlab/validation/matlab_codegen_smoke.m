scriptPath = mfilename("fullpath");
repoRoot = fileparts(fileparts(fileparts(scriptPath)));
scriptDir = fileparts(scriptPath);
outDir = fullfile(repoRoot, "artifacts", "validation", "codegen_smoke");
if ~isfolder(outDir)
    mkdir(outDir);
end

addpath(scriptDir);

state = struct("integrator", 0.2, "Ts", 1e-3, "Kp", 0.8, "Ki", 10.0);
gold = pi_control_step(1.0, 0.6, state);

cfg = coder.config("lib");
cfg.GenerateReport = false;
cfg.GenCodeOnly = true;
codegenFolder = fullfile(outDir, "codegen");
if ~isfolder(codegenFolder)
    mkdir(codegenFolder);
end

currentFolder = pwd;
cleanupFolder = onCleanup(@() cd(currentFolder));
cd(codegenFolder);

codegen -config cfg pi_control_step -args {0.0, 0.0, coder.typeof(state)};

generatedSource = fullfile(codegenFolder, "codegen", "lib", "pi_control_step", "pi_control_step.c");
generatedHeader = fullfile(codegenFolder, "codegen", "lib", "pi_control_step", "pi_control_step.h");

summary = struct();
summary.generatedAt = string(datetime("now", "Format", "yyyy-MM-dd'T'HH:mm:ss"));
summary.matlabVersion = string(version);
summary.release = string(version("-release"));
summary.goldenOutput = gold;
summary.generatedSource = string(generatedSource);
summary.generatedHeader = string(generatedHeader);
summary.passed = isfile(generatedSource) && isfile(generatedHeader);
assert(summary.passed, "MATLAB Coder smoke check failed.");

summaryPath = fullfile(outDir, "summary.json");
fid = fopen(summaryPath, "w");
cleanupFile = onCleanup(@() fclose(fid));
fprintf(fid, "%s", jsonencode(summary, "PrettyPrint", true));
clear cleanupFile

fprintf("CODEGEN_SMOKE=%s\n", summaryPath);
fprintf("GENERATED_SOURCE=%s\n", generatedSource);
