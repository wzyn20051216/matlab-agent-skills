%{
@file matlab_compiler_chain_smoke.m
@brief 编译器链验收：MEX 构建（L2）、数值一致性（L3）、多工况与异常场景（L4）。

@details
  与旧版的差异：
  1. 旧版只比较一个输入组合，且固定使用 `absErr < 1e-12`，大数值工况会误判；
  2. 新版用绝对/相对误差双判据，覆盖多组输入，并单独验证异常输入被拒绝；
  3. 未配置编译器时输出 SKIP 并写明原因，而不是直接报错退出；
  4. 每条检查都带 command、exitCode、metrics、duration，便于审计。
%}

scriptPath = mfilename("fullpath");
repoRoot = fileparts(fileparts(fileparts(scriptPath)));
scriptDir = fileparts(scriptPath);
addpath(scriptDir);

artifactDir = fullfile(repoRoot, "artifacts", "validation", "compiler_chain_smoke");
acceptanceDir = fullfile(repoRoot, "artifacts", "validation", "acceptance");
for folder = [string(artifactDir), string(acceptanceDir)]
    if ~isfolder(folder)
        mkdir(folder);
    end
end

report = masacc.new("compiler-chain-smoke", "matlab-batch");
report.limitations = [
    "MEX 与 MATLAB 使用同一份双精度算术，误差容限设在 1e-12 量级；这不等于目标硬件上的定点/浮点误差。"
    "L5（实际硬件运行）未覆盖：仓库没有真实 STM32 板卡回读通道。"
];

state = struct("integrator", 0.2, "Ts", 1e-3, "Kp", 0.8, "Ki", 10.0);
zeroState = struct("integrator", 0.0, "Ts", 1e-3, "Kp", 0.8, "Ki", 10.0);
atol = 1e-12;
rtol = 1e-12;

coderInfo = masacc.availability("MATLAB Coder");
compilers = mex.getCompilerConfigurations("C", "Selected");
hasCompiler = ~isempty(compilers) && strlength(string(compilers(1).Name)) > 0;

mexDir = fullfile(artifactDir, "mex");
mexPath = "";
mexBuilt = false;

% ---------------- L2：MEX 构建 ----------------
if ~coderInfo.available
    report = masacc.addCheck(report, "compiler.mex-build", "生成并构建 MEX", "L2", "SKIP", ...
        Reason=coderInfo.reason, ErrorClass="ENVIRONMENT_ERROR");
elseif ~hasCompiler
    report = masacc.addCheck(report, "compiler.mex-build", "生成并构建 MEX", "L2", "SKIP", ...
        Reason="未配置 C 编译器（mex.getCompilerConfigurations 为空）：代码生成可做，真实编译不可做", ...
        ErrorClass="ENVIRONMENT_ERROR");
else
    started = masacc.timestamp();
    elapsed = tic;
    try
        cfg = coder.config("mex");
        cfg.GenerateReport = false;
        codegen -config cfg pi_control_step -args {1.0, 0.6, coder.typeof(state)} -d mexDir

        hits = dir(fullfile(mexDir, "**", "pi_control_step_mex.*"));
        hits = hits(~[hits.isdir]);
        if ~isempty(hits)
            mexPath = string(fullfile(hits(1).folder, hits(1).name));
            addpath(hits(1).folder);
            mexBuilt = true;
        end

        metrics = struct("compilerName", string(compilers(1).Name), ...
            "compilerVersion", string(compilers(1).Version), "mexPath", mexPath, ...
            "mexBytes", 0);
        if mexBuilt
            metrics.mexBytes = dir(mexPath).bytes;
            report = masacc.addCheck(report, "compiler.mex-build", "生成并构建 MEX", "L2", "PASS", ...
                Command="codegen -config:mex pi_control_step", Metrics=metrics, ...
                StartedAt=started, FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed), ...
                ArtifactPaths=[mexPath]);
        else
            report = masacc.addCheck(report, "compiler.mex-build", "生成并构建 MEX", "L2", "FAIL", ...
                Reason="codegen 未报错但未找到 MEX 二进制", ErrorClass="CODEGEN_ERROR", ...
                Command="codegen -config:mex pi_control_step", Metrics=metrics, ...
                StartedAt=started, FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed));
        end
    catch ME
        report = masacc.addCheck(report, "compiler.mex-build", "生成并构建 MEX", "L2", "FAIL", ...
            Reason=string(ME.message), ErrorClass=masacc.classifyError(ME), ...
            Command="codegen -config:mex pi_control_step", ...
            StartedAt=started, FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed));
    end
end

% ---------------- L3：数值一致性 ----------------
cases = struct( ...
    "name", {"nominal", "no-error", "negative-error", "large-reference", "zero-state"}, ...
    "ref", {1.0, 0.5, -1.0, 1.0e6, 1.0}, ...
    "meas", {0.6, 0.5, 1.0, 0.0, 0.6}, ...
    "state", {state, state, state, state, zeroState});

if ~mexBuilt
    report = masacc.addCheck(report, "compiler.numeric", "MEX 输出与 MATLAB golden 一致", "L3", "SKIP", ...
        Reason="MEX 未构建成功，无法做数值对照");
else
    started = masacc.timestamp();
    elapsed = tic;
    maxAbs = 0;
    maxRel = 0;
    worstCase = "";
    compareOk = true;
    details = struct("name", {}, "ref", {}, "meas", {}, "golden", {}, "compiled", {}, "absError", {}, "relError", {});

    for idx = 1:numel(cases)
        golden = pi_control_step(cases(idx).ref, cases(idx).meas, cases(idx).state);
        compiled = pi_control_step_mex(cases(idx).ref, cases(idx).meas, cases(idx).state);
        absError = abs(compiled - golden);
        denominator = max(abs(golden), 1.0);
        relError = absError / denominator;

        details(idx).name = string(cases(idx).name);
        details(idx).ref = cases(idx).ref;
        details(idx).meas = cases(idx).meas;
        details(idx).golden = golden;
        details(idx).compiled = compiled;
        details(idx).absError = absError;
        details(idx).relError = relError;

        if absError > maxAbs; maxAbs = absError; end
        if relError > maxRel; maxRel = relError; end
        if absError > atol && relError > rtol
            compareOk = false;
            if strlength(worstCase) == 0
                worstCase = string(cases(idx).name);
            end
        end
    end

    metrics = struct("atol", atol, "rtol", rtol, "caseCount", numel(cases), ...
        "maxAbsError", maxAbs, "maxRelError", maxRel, "worstCase", worstCase, "cases", details);
    if compareOk
        report = masacc.addCheck(report, "compiler.numeric", "MEX 输出与 MATLAB golden 一致", "L3", "PASS", ...
            Command="pi_control_step vs pi_control_step_mex（5 组输入）", Metrics=metrics, ...
            StartedAt=started, FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed));
    else
        report = masacc.addCheck(report, "compiler.numeric", "MEX 输出与 MATLAB golden 一致", "L3", "FAIL", ...
            Reason=sprintf("工况 %s 超出容限：maxAbs=%.3e maxRel=%.3e", worstCase, maxAbs, maxRel), ...
            ErrorClass="VALIDATION_ERROR", ...
            Command="pi_control_step vs pi_control_step_mex（5 组输入）", Metrics=metrics, ...
            StartedAt=started, FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed));
    end
end

% ---------------- L4：异常场景 ----------------
if ~mexBuilt
    report = masacc.addCheck(report, "compiler.robustness", "异常输入被正确处理", "L4", "SKIP", ...
        Reason="MEX 未构建成功，无法验证异常输入");
else
    started = masacc.timestamp();
    elapsed = tic;
    nanPropagated = false;
    shapeRejected = false;
    largeFinite = false;
    detail = struct();

    try
        nanOutput = pi_control_step_mex(NaN, 0.6, state);
        nanPropagated = isnan(nanOutput);
        detail.nanOutput = nanOutput;
    catch ME
        detail.nanError = string(ME.message);
    end

    try
        pi_control_step_mex([1 2; 3 4], 0.6, state);
        shapeRejected = false;
    catch
        shapeRejected = true;
    end

    try
        largeOutput = pi_control_step_mex(1.0e6, -1.0e6, state);
        largeFinite = isfinite(largeOutput);
        detail.largeOutput = largeOutput;
    catch ME
        detail.largeError = string(ME.message);
    end

    detail.nanPropagated = nanPropagated;
    detail.shapeRejected = shapeRejected;
    detail.largeFinite = largeFinite;

    if nanPropagated && shapeRejected && largeFinite
        report = masacc.addCheck(report, "compiler.robustness", "异常输入被正确处理", "L4", "PASS", ...
            Command="NaN 传播 / 非法形状拒绝 / 大数值有限性", Metrics=detail, ...
            StartedAt=started, FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed));
    else
        report = masacc.addCheck(report, "compiler.robustness", "异常输入被正确处理", "L4", "FAIL", ...
            Reason=sprintf("NaN 传播=%d，非法形状被拒绝=%d，大数值有限=%d", ...
            nanPropagated, shapeRejected, largeFinite), ErrorClass="VALIDATION_ERROR", ...
            Command="NaN 传播 / 非法形状拒绝 / 大数值有限性", Metrics=detail, ...
            StartedAt=started, FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed));
    end
end

acceptancePath = fullfile(acceptanceDir, "compiler_chain_smoke.json");
report = masacc.write(report, acceptancePath);

fprintf("COMPILER_CHAIN_SMOKE=%s\n", acceptancePath);
fprintf("GENERATED_MEX=%s\n", mexPath);
fprintf("COMPILER_CHAIN_OVERALL=%s\n", report.overallStatus);
fprintf("COMPILER_CHAIN_LEVEL=%s\n", report.achievedLevel);
