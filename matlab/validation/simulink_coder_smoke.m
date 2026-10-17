%{
@file simulink_coder_smoke.m
@brief Simulink 模型验收：加载/更新（L1、L2）、仿真数值（L3）、多工况与代码生成（L4）。

@details
  与旧版的差异：
  1. 旧版只要 `<model>.c` 存在就判 passed，把“文件存在”当成“构建成功”；
  2. 新版把模型保存、模型更新（编译）、仿真数值、多工况/代码生成拆成独立检查；
  3. 仿真结果与解析预期（增益 3 × 阶跃 1 = 3.0）对照，容限 1e-9；
  4. 缺少 Simulink / Simulink Coder / 编译器时输出 SKIP 并写明原因。
%}

scriptPath = mfilename("fullpath");
repoRoot = fileparts(fileparts(fileparts(scriptPath)));
scriptDir = fileparts(scriptPath);
addpath(scriptDir);

artifactDir = fullfile(repoRoot, "artifacts", "validation", "simulink_coder_smoke");
acceptanceDir = fullfile(repoRoot, "artifacts", "validation", "acceptance");
for folder = [string(artifactDir), string(acceptanceDir)]
    if ~isfolder(folder)
        mkdir(folder);
    end
end

report = masacc.new("simulink-coder-smoke", "matlab-batch");
report.limitations = [
    "模型为最小 Step→Gain→Outport，只证明 Simulink 编译/仿真/代码生成链路可用。"
    "GRT 目标生成的可执行文件不等于 STM32 固件，也不等于硬件在环验证（L5）。"
];

simInfo = masacc.availability("Simulink");
coderInfo = masacc.availability("Simulink Coder");
compilers = mex.getCompilerConfigurations("C", "Selected");
hasCompiler = ~isempty(compilers) && strlength(string(compilers(1).Name)) > 0;

modelName = "simulink_coder_smoke_model";
modelPath = fullfile(artifactDir, modelName + ".slx");
expectedFinal = 3.0;
tolerance = 1e-9;

if ~simInfo.available
    report = masacc.addCheck(report, "simulink.model-artifact", "生成可加载的 .slx 模型", "L1", "SKIP", ...
        Reason=simInfo.reason, ErrorClass="ENVIRONMENT_ERROR");
    report = masacc.addCheck(report, "simulink.model-update", "模型更新（编译）成功", "L2", "SKIP", ...
        Reason=simInfo.reason, ErrorClass="ENVIRONMENT_ERROR");
    report = masacc.addCheck(report, "simulink.simulation", "仿真输出与解析预期一致", "L3", "SKIP", ...
        Reason=simInfo.reason, ErrorClass="ENVIRONMENT_ERROR");
    report = masacc.addCheck(report, "simulink.parameter-sweep", "多工况增益扫描一致", "L4", "SKIP", ...
        Reason=simInfo.reason, ErrorClass="ENVIRONMENT_ERROR");
    report = masacc.addCheck(report, "simulink.codegen-build", "Simulink Coder 真实构建", "L4", "SKIP", ...
        Reason=simInfo.reason, ErrorClass="ENVIRONMENT_ERROR");
else
    modelReady = false;
    started = masacc.timestamp();
    elapsed = tic;

    % ---------------- L1：建模 + 保存 + 重新加载 ----------------
    try
        if bdIsLoaded(modelName)
            close_system(modelName, 0);
        end
        new_system(modelName);
        % Step 块设置阶跃时刻的参数名是 Time，不是 StepTime。
        % 实测 R2026a：get_param(blk,"DialogParameters") 返回
        % Time, InitialValue, FinalValue, OutDataTypeStr, SampleTime, VectorParams1D, ZeroCross；
        % 写 StepTime 会直接报 "Step block 没有名为 'StepTime' 的参数"。
        add_block("simulink/Sources/Step", modelName + "/Step", ...
            "Position", [80 80 120 120], "SampleTime", "0.01", "Time", "1");
        add_block("simulink/Math Operations/Gain", modelName + "/Gain", ...
            "Gain", "3", "Position", [170 80 230 120]);
        add_block("simulink/Sinks/Out1", modelName + "/Out1", "Position", [290 80 330 120]);
        add_line(modelName, "Step/1", "Gain/1");
        add_line(modelName, "Gain/1", "Out1/1");
        set_param(modelName, "StopTime", "2", "Solver", "FixedStepDiscrete", "FixedStep", "0.01", ...
            "SaveOutput", "on", "SaveFormat", "Array", "ReturnWorkspaceOutputs", "on", ...
            "SystemTargetFile", "grt.tlc");
        save_system(modelName, modelPath);

        % 重新加载，证明 .slx 可被 Simulink 解析，而不是只判断文件存在。
        close_system(modelName, 0);
        load_system(modelPath);
        modelReady = bdIsLoaded(modelName) && isfile(modelPath);

        metrics = struct("modelPath", string(modelPath), "modelBytes", dir(modelPath).bytes);
        if modelReady
            report = masacc.addCheck(report, "simulink.model-artifact", "生成可加载的 .slx 模型", "L1", "PASS", ...
                Command="new_system/save_system/load_system", Metrics=metrics, ...
                StartedAt=started, FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed), ...
                ArtifactPaths=[string(modelPath)]);
        else
            report = masacc.addCheck(report, "simulink.model-artifact", "生成可加载的 .slx 模型", "L1", "FAIL", ...
                Reason="保存后无法重新加载 .slx", ErrorClass="VALIDATION_ERROR", ...
                Command="new_system/save_system/load_system", Metrics=metrics, ...
                StartedAt=started, FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed), ...
                ArtifactPaths=[string(modelPath)]);
        end
    catch ME
        report = masacc.addCheck(report, "simulink.model-artifact", "生成可加载的 .slx 模型", "L1", "FAIL", ...
            Reason=string(ME.message), ErrorClass=masacc.classifyError(ME), ...
            Command="new_system/save_system/load_system", ...
            StartedAt=started, FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed));
    end

    % ---------------- L2：模型更新（编译） ----------------
    if ~modelReady
        report = masacc.addCheck(report, "simulink.model-update", "模型更新（编译）成功", "L2", "SKIP", ...
            Reason="模型未成功加载，无法执行更新");
    else
        started = masacc.timestamp();
        elapsed = tic;
        try
            set_param(modelName, "SimulationCommand", "update");
            status = string(get_param(modelName, "SimulationStatus"));
            metrics = struct("simulationStatus", status, "solver", string(get_param(modelName, "Solver")));
            report = masacc.addCheck(report, "simulink.model-update", "模型更新（编译）成功", "L2", "PASS", ...
                Command="set_param(SimulationCommand='update')", Metrics=metrics, ...
                StartedAt=started, FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed));
        catch ME
            report = masacc.addCheck(report, "simulink.model-update", "模型更新（编译）成功", "L2", "FAIL", ...
                Reason=string(ME.message), ErrorClass=masacc.classifyError(ME), ...
                Command="set_param(SimulationCommand='update')", ...
                StartedAt=started, FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed));
        end
    end

    % ---------------- L3：仿真数值 ----------------
    if ~modelReady
        report = masacc.addCheck(report, "simulink.simulation", "仿真输出与解析预期一致", "L3", "SKIP", ...
            Reason="模型未成功加载，无法仿真");
    else
        started = masacc.timestamp();
        elapsed = tic;
        try
            simOut = sim(modelName);
            yout = simOut.get("yout");
            y = yout(:);
            sampleCount = numel(y);
            finalValue = y(end);
            finiteOk = all(isfinite(y));
            delta = abs(finalValue - expectedFinal);
            % 多工况前置：数值必须命中解析稳态值。
            simOk = sampleCount >= 100 && finiteOk && delta <= tolerance;

            metrics = struct("sampleCount", sampleCount, "finalValue", finalValue, ...
                "expectedFinal", expectedFinal, "tolerance", tolerance, ...
                "absoluteError", delta, "allFinite", finiteOk);
            if simOk
                report = masacc.addCheck(report, "simulink.simulation", "仿真输出与解析预期一致", "L3", "PASS", ...
                    Command="sim(model)", Metrics=metrics, StartedAt=started, ...
                    FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed));
            else
                report = masacc.addCheck(report, "simulink.simulation", "仿真输出与解析预期一致", "L3", "FAIL", ...
                    Reason=sprintf("稳态值 %.9f 偏离预期 %.1f（容限 %.0e），samples=%d", ...
                    finalValue, expectedFinal, tolerance, sampleCount), ErrorClass="VALIDATION_ERROR", ...
                    Command="sim(model)", Metrics=metrics, StartedAt=started, ...
                    FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed));
            end
        catch ME
            report = masacc.addCheck(report, "simulink.simulation", "仿真输出与解析预期一致", "L3", "FAIL", ...
                Reason=string(ME.message), ErrorClass=masacc.classifyError(ME), ...
                Command="sim(model)", StartedAt=started, ...
                FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed));
        end
    end

    % ---------------- L4a：多工况增益扫描 ----------------
    if ~modelReady
        report = masacc.addCheck(report, "simulink.parameter-sweep", "多工况增益扫描一致", "L4", "SKIP", ...
            Reason="模型未成功加载，无法做工况扫描");
    else
        started = masacc.timestamp();
        elapsed = tic;
        gains = [2 3 5];
        results = struct("gain", {}, "finalValue", {}, "expected", {}, "absoluteError", {});
        sweepOk = true;
        try
            for idx = 1:numel(gains)
                gain = gains(idx);
                set_param(modelName + "/Gain", "Gain", num2str(gain));
                simOut = sim(modelName);
                y = simOut.get("yout");
                finalValue = y(end);
                results(idx).gain = gain;
                results(idx).finalValue = finalValue;
                results(idx).expected = gain * 1.0;
                results(idx).absoluteError = abs(finalValue - gain);
                if results(idx).absoluteError > tolerance
                    sweepOk = false;
                end
            end
            set_param(modelName + "/Gain", "Gain", "3");

            metrics = struct("tolerance", tolerance, "cases", results, "caseCount", numel(gains));
            if sweepOk
                report = masacc.addCheck(report, "simulink.parameter-sweep", "多工况增益扫描一致", "L4", "PASS", ...
                    Command="for gain in [2 3 5] sim(model)", Metrics=metrics, ...
                    StartedAt=started, FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed));
            else
                report = masacc.addCheck(report, "simulink.parameter-sweep", "多工况增益扫描一致", "L4", "FAIL", ...
                    Reason="至少一个增益工况的稳态输出偏离预期", ErrorClass="VALIDATION_ERROR", ...
                    Command="for gain in [2 3 5] sim(model)", Metrics=metrics, ...
                    StartedAt=started, FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed));
            end
        catch ME
            report = masacc.addCheck(report, "simulink.parameter-sweep", "多工况增益扫描一致", "L4", "FAIL", ...
                Reason=string(ME.message), ErrorClass=masacc.classifyError(ME), ...
                Command="for gain in [2 3 5] sim(model)", ...
                StartedAt=started, FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed));
        end
    end

    % ---------------- L4b：Simulink Coder 真实构建 ----------------
    if ~coderInfo.available
        report = masacc.addCheck(report, "simulink.codegen-build", "Simulink Coder 真实构建", "L4", "SKIP", ...
            Reason=coderInfo.reason, ErrorClass="ENVIRONMENT_ERROR");
    elseif ~hasCompiler
        report = masacc.addCheck(report, "simulink.codegen-build", "Simulink Coder 真实构建", "L4", "SKIP", ...
            Reason="未配置 C 编译器，slbuild 无法完成真实构建", ErrorClass="ENVIRONMENT_ERROR");
    elseif ~modelReady
        report = masacc.addCheck(report, "simulink.codegen-build", "Simulink Coder 真实构建", "L4", "SKIP", ...
            Reason="模型未成功加载，无法构建");
    else
        started = masacc.timestamp();
        elapsed = tic;
        currentFolder = pwd;
        restoreFolder = onCleanup(@() cd(currentFolder));
        buildOk = false;
        try
            cd(artifactDir);
            set_param(modelName, "GenCodeOnly", "off");
            slbuild(modelName);

            generatedC = dir(fullfile(artifactDir, "**", modelName + ".c"));
            generatedC = generatedC(~[generatedC.isdir]);
            executables = [dir(fullfile(artifactDir, "**", modelName + ".exe")); ...
                dir(fullfile(artifactDir, "**", modelName))];
            executables = executables(~[executables.isdir]);

            generatedCPath = "";
            generatedCBytes = 0;
            if ~isempty(generatedC)
                generatedCPath = string(fullfile(generatedC(1).folder, generatedC(1).name));
                generatedCBytes = generatedC(1).bytes;
            end

            buildOk = strlength(generatedCPath) > 0 && ~isempty(executables);
            metrics = struct( ...
                "generatedC", generatedCPath, ...
                "generatedCBytes", generatedCBytes, ...
                "executableCount", numel(executables), ...
                "compilerName", string(compilers(1).Name));
            if buildOk
                report = masacc.addCheck(report, "simulink.codegen-build", "Simulink Coder 真实构建", "L4", "PASS", ...
                    Command="slbuild(model) with grt.tlc", Metrics=metrics, ...
                    StartedAt=started, FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed), ...
                    ArtifactPaths=[generatedCPath]);
            else
                report = masacc.addCheck(report, "simulink.codegen-build", "Simulink Coder 真实构建", "L4", "FAIL", ...
                    Reason="slbuild 未报错但未同时产出 C 源码与可执行文件", ErrorClass="CODEGEN_ERROR", ...
                    Command="slbuild(model) with grt.tlc", Metrics=metrics, ...
                    StartedAt=started, FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed));
            end
        catch ME
            report = masacc.addCheck(report, "simulink.codegen-build", "Simulink Coder 真实构建", "L4", "FAIL", ...
                Reason=string(ME.message), ErrorClass=masacc.classifyError(ME), ...
                Command="slbuild(model) with grt.tlc", ...
                StartedAt=started, FinishedAt=masacc.timestamp(), DurationSeconds=toc(elapsed));
        end
        clear restoreFolder
    end

    if bdIsLoaded(modelName)
        close_system(modelName, 0);
    end
end

acceptancePath = fullfile(acceptanceDir, "simulink_coder_smoke.json");
report = masacc.write(report, acceptancePath);

fprintf("SIMULINK_CODER_SMOKE=%s\n", acceptancePath);
fprintf("SIMULINK_CODER_OVERALL=%s\n", report.overallStatus);
fprintf("SIMULINK_CODER_LEVEL=%s\n", report.achievedLevel);
