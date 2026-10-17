%{
@file matlab_codegen_smoke.m
@brief MATLAB Coder 代码生成与编译验收（L1 代码生成 / L2 编译构建）。

@details
  与旧版的差异：
  1. 旧版仅用 `isfile(pi_control_step.c)` 判 passed，本质是“文件存在=成功”；
  2. 新版拆成两条检查：L1 生成 C 源码，L2 调用真实编译器构建静态库；
  3. 缺少 MATLAB Coder 或未配置编译器时输出 SKIP 并写明原因，不伪造 PASS；
  4. 数值一致性（L3）不在本脚本内，由 matlab_compiler_chain_smoke.m 用 MEX 与 golden 对照。
%}

scriptPath = mfilename("fullpath");
repoRoot = fileparts(fileparts(fileparts(scriptPath)));
scriptDir = fileparts(scriptPath);
addpath(scriptDir);

artifactDir = fullfile(repoRoot, "artifacts", "validation", "codegen_smoke");
acceptanceDir = fullfile(repoRoot, "artifacts", "validation", "acceptance");
for folder = [string(artifactDir), string(acceptanceDir)]
    if ~isfolder(folder)
        mkdir(folder);
    end
end

report = masacc.new("codegen-smoke", "matlab-batch");
report.limitations = [
    "本脚本只覆盖 L1（源码生成）与 L2（静态库编译）。"
    "数值一致性（L3）由 matlab_compiler_chain_smoke.m 用 MEX 与 MATLAB golden 对照验证。"
    "生成通用 C 代码不代表 STM32 等目标硬件部署成功（L5 需要真实硬件与 CubeMX 链路）。"
];

state = struct("integrator", 0.2, "Ts", 1e-3, "Kp", 0.8, "Ki", 10.0);
args = {0.0, 0.0, coder.typeof(state)};
coderInfo = masacc.availability("MATLAB Coder");

% ---------------- L1：代码生成 ----------------
genDir = fullfile(artifactDir, "codegen_only");
sourcePath = "";
headerPath = "";
generatedOk = false;

if ~coderInfo.available
    report = masacc.addCheck(report, "codegen.generate", "MATLAB Coder 生成 C 源码", "L1", "SKIP", ...
        Reason=coderInfo.reason, ErrorClass="ENVIRONMENT_ERROR");
else
    started = masacc.timestamp();
    elapsed = tic;
    try
        cfg = coder.config("lib");
        cfg.GenerateReport = false;
        cfg.GenCodeOnly = true;
        cfg.TargetLang = "C";
        codegen -config cfg pi_control_step -args args -d genDir

        sourceHits = dir(fullfile(genDir, "**", "pi_control_step.c"));
        headerHits = dir(fullfile(genDir, "**", "pi_control_step.h"));
        if ~isempty(sourceHits)
            sourcePath = string(fullfile(sourceHits(1).folder, sourceHits(1).name));
        end
        if ~isempty(headerHits)
            headerPath = string(fullfile(headerHits(1).folder, headerHits(1).name));
        end

        generatedOk = strlength(sourcePath) > 0 && strlength(headerPath) > 0 && ...
            isfile(sourcePath) && isfile(headerPath) && ...
            dir(sourcePath).bytes > 0 && dir(headerPath).bytes > 0;

        sourceBytes = 0;
        headerBytes = 0;
        if strlength(sourcePath) > 0 && isfile(sourcePath)
            sourceBytes = dir(sourcePath).bytes;
        end
        if strlength(headerPath) > 0 && isfile(headerPath)
            headerBytes = dir(headerPath).bytes;
        end
        metrics = struct("sourcePath", sourcePath, "headerPath", headerPath, ...
            "sourceBytes", sourceBytes, "headerBytes", headerBytes);
        if generatedOk
            report = masacc.addCheck(report, "codegen.generate", "MATLAB Coder 生成 C 源码", "L1", "PASS", ...
                Command="codegen -config lib (GenCodeOnly) pi_control_step", Metrics=metrics, ...
                StartedAt=started, FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed), ...
                ArtifactPaths=[sourcePath, headerPath]);
        else
            report = masacc.addCheck(report, "codegen.generate", "MATLAB Coder 生成 C 源码", "L1", "FAIL", ...
                Reason="codegen 未报错，但未找到非空的 C 源码/头文件", ErrorClass="CODEGEN_ERROR", ...
                Command="codegen -config lib (GenCodeOnly) pi_control_step", Metrics=metrics, ...
                StartedAt=started, FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed), ...
                ArtifactPaths=[sourcePath, headerPath]);
        end
    catch ME
        report = masacc.addCheck(report, "codegen.generate", "MATLAB Coder 生成 C 源码", "L1", "FAIL", ...
            Reason=string(ME.message), ErrorClass=masacc.classifyError(ME), ...
            Command="codegen -config lib (GenCodeOnly) pi_control_step", ...
            StartedAt=started, FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed));
    end
end

% ---------------- L2：真实编译（静态库） ----------------
compilers = mex.getCompilerConfigurations("C", "Selected");
hasCompiler = ~isempty(compilers) && strlength(string(compilers(1).Name)) > 0;

if ~coderInfo.available
    report = masacc.addCheck(report, "codegen.compile", "生成代码可被 C 编译器编译", "L2", "SKIP", ...
        Reason=coderInfo.reason, ErrorClass="ENVIRONMENT_ERROR");
elseif ~hasCompiler
    report = masacc.addCheck(report, "codegen.compile", "生成代码可被 C 编译器编译", "L2", "SKIP", ...
        Reason="未配置 C 编译器（mex.getCompilerConfigurations 为空）；代码生成不等于编译成功", ...
        ErrorClass="ENVIRONMENT_ERROR");
else
    started = masacc.timestamp();
    elapsed = tic;
    buildDir = fullfile(artifactDir, "compiled_lib");
    try
        cfgBuild = coder.config("lib");
        cfgBuild.GenerateReport = false;
        cfgBuild.GenCodeOnly = false;
        cfgBuild.TargetLang = "C";
        codegen -config cfgBuild pi_control_step -args args -d buildDir

        libHits = [dir(fullfile(buildDir, "**", "*.lib")); dir(fullfile(buildDir, "**", "*.a"))];
        buildOk = ~isempty(libHits);
        libPaths = strings(0, 1);
        for idx = 1:numel(libHits)
            libPaths(end + 1) = string(fullfile(libHits(idx).folder, libHits(idx).name));
        end

        metrics = struct("compilerName", string(compilers(1).Name), ...
            "compilerVersion", string(compilers(1).Version), "libraryCount", numel(libHits), ...
            "libraries", libPaths);
        if buildOk
            report = masacc.addCheck(report, "codegen.compile", "生成代码可被 C 编译器编译", "L2", "PASS", ...
                Command="codegen -config lib (GenCodeOnly=false) pi_control_step", Metrics=metrics, ...
                StartedAt=started, FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed), ...
                ArtifactPaths=libPaths);
        else
            report = masacc.addCheck(report, "codegen.compile", "生成代码可被 C 编译器编译", "L2", "FAIL", ...
                Reason="编译命令未报错但未产生 .lib/.a 静态库产物", ErrorClass="CODEGEN_ERROR", ...
                Command="codegen -config lib (GenCodeOnly=false) pi_control_step", Metrics=metrics, ...
                StartedAt=started, FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed));
        end
    catch ME
        report = masacc.addCheck(report, "codegen.compile", "生成代码可被 C 编译器编译", "L2", "FAIL", ...
            Reason=string(ME.message), ErrorClass=masacc.classifyError(ME), ...
            Command="codegen -config lib (GenCodeOnly=false) pi_control_step", ...
            StartedAt=started, FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed));
    end
end

acceptancePath = fullfile(acceptanceDir, "codegen_smoke.json");
report = masacc.write(report, acceptancePath);

fprintf("CODEGEN_SMOKE=%s\n", acceptancePath);
fprintf("GENERATED_SOURCE=%s\n", sourcePath);
fprintf("CODEGEN_SMOKE_OVERALL=%s\n", report.overallStatus);
fprintf("CODEGEN_SMOKE_LEVEL=%s\n", report.achievedLevel);
