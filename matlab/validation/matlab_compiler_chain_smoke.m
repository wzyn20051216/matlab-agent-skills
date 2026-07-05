%{
@file matlab_compiler_chain_smoke.m
@brief 验证 MATLAB 编译器链是否可用，包括 MEX 配置与 MATLAB Coder MEX 生成。
@details
  该脚本用于闭环验收本机编译器环境，覆盖以下检查：
  1. `mex -setup` 是否已经成功配置 C/C++ 编译器；
  2. `codegen -config mex` 是否能够成功生成并执行 MEX；
  3. 生成后的数值结果是否与 MATLAB 参考结果一致。
%}

scriptPath = mfilename("fullpath");
repoRoot = fileparts(fileparts(fileparts(scriptPath)));
scriptDir = fileparts(scriptPath);
outDir = fullfile(repoRoot, "artifacts", "validation", "compiler_chain_smoke");
if ~isfolder(outDir)
    mkdir(outDir);
end

addpath(scriptDir);

state = struct("integrator", 0.2, "Ts", 1e-3, "Kp", 0.8, "Ki", 10.0);
inputRef = 1.0;
inputMeas = 0.6;
gold = pi_control_step(inputRef, inputMeas, state);

summary = struct();
summary.generatedAt = string(datetime("now", "Format", "yyyy-MM-dd'T'HH:mm:ss"));
summary.matlabVersion = string(version);
summary.release = string(version("-release"));

summary.mexConfig = struct();
summary.mexConfig.c = string(mex.getCompilerConfigurations("C", "Selected").Name);
summary.mexConfig.cpp = string(mex.getCompilerConfigurations("C++", "Selected").Name);

cfg = coder.config("mex");
cfg.GenerateReport = false;

workDir = fullfile(outDir, "codegen");
if ~isfolder(workDir)
    mkdir(workDir);
end

currentFolder = pwd;
cleanupFolder = onCleanup(@() cd(currentFolder));
cd(workDir);

codegen -config cfg pi_control_step -args {inputRef, inputMeas, coder.typeof(state)};

mexName = "pi_control_step_mex";
if ispc
    mexBinary = fullfile(workDir, mexName + "." + mexext);
else
    mexBinary = fullfile(workDir, mexName + "." + mexext);
end

assert(isfile(mexBinary), "Compiler chain smoke check failed: MEX binary not generated.");

compiledOutput = pi_control_step_mex(inputRef, inputMeas, state);
absErr = abs(compiledOutput - gold);

summary.referenceOutput = gold;
summary.compiledOutput = compiledOutput;
summary.absoluteError = absErr;
summary.generatedMex = string(mexBinary);
summary.passed = absErr < 1e-12;

assert(summary.passed, "Compiler chain smoke check failed: compiled result deviates from MATLAB result.");

summaryPath = fullfile(outDir, "summary.json");
fid = fopen(summaryPath, "w");
cleanupFile = onCleanup(@() fclose(fid));
fprintf(fid, "%s", jsonencode(summary, "PrettyPrint", true));
clear cleanupFile

fprintf("COMPILER_CHAIN_SMOKE=%s\n", summaryPath);
fprintf("GENERATED_MEX=%s\n", mexBinary);
