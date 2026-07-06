%{
@file stm32_codegen_stack_probe.m
@brief 探测 MATLAB 侧 STM32 Embedded Coder 代码生成链路。
@details
  输出 STM32 支持包、目标硬件、CubeMX 注册路径、推荐版本信息和常见
  STM32Cube Repository 状态。该脚本只做轻量探测，不默认启动长时间构建。
%}

scriptPath = mfilename("fullpath");
repoRoot = fileparts(fileparts(fileparts(scriptPath)));
outDir = fullfile(repoRoot, "artifacts", "validation");
if ~isfolder(outDir)
    mkdir(outDir);
end

report = struct();
report.generatedAt = string(datetime("now", "Format", "yyyy-MM-dd'T'HH:mm:ss"));
report.matlabVersion = string(version);
report.release = string(version("-release"));

report.products = struct();
v = ver;
productNames = string({v.Name});
hasProduct = @(name) any(strcmp(productNames, string(name)));
report.products.simulink = hasProduct("Simulink");
report.products.simulinkCoder = hasProduct("Simulink Coder");
report.products.embeddedCoder = hasProduct("Embedded Coder");
report.products.stm32SupportHits = productNames(contains(lower(productNames), "stm32"));

report.targetHardware = struct("names", strings(0, 1), "stm32Hits", strings(0, 1), "queryError", "");
try
    names = string(codertarget.targethardware.getRegisteredTargetHardwareNames);
    report.targetHardware.names = names(:);
    report.targetHardware.stm32Hits = names(contains(lower(names), "stm32"));
catch ME
    report.targetHardware.queryError = string(ME.message);
end

report.cubeMx = struct();
report.cubeMx.registeredPath = "";
report.cubeMx.registeredVersion = "";
report.cubeMx.rawInstalledInfo = struct();
report.cubeMx.queryError = "";
try
    installedInfo = stm32cube.hwsetup.stm32Tools.getInstalledSTM32CubeMX();
    report.cubeMx.rawInstalledInfo = installedInfo;
    [registeredPath, registeredVersion] = parseCubeMxInstalledInfo(installedInfo);
    report.cubeMx.registeredPath = registeredPath;
    report.cubeMx.registeredVersion = registeredVersion;
catch ME
    report.cubeMx.queryError = string(ME.message);
end

report.cubeMx.recommendedVersion = getMessageText("stm32:setup:CubeMXReqVersion");
report.cubeMx.minSupportedVersion = getMessageText("stm32:setup:CubeMXMinSupportedVersion");
report.cubeMx.downloadHint = getMessageText("stm32:setup:CubeMXReqVersionLink_" + string(computer("arch")));
report.cubeMx.registeredPathExists = strlength(report.cubeMx.registeredPath) > 0 && isfolder(report.cubeMx.registeredPath);

report.repository = struct();
repoRootGuess = fullfile(char(java.lang.System.getProperty("user.home")), "STM32Cube", "Repository");
report.repository.path = string(repoRootGuess);
report.repository.exists = isfolder(repoRootGuess);
report.repository.f1Packages = strings(0, 1);
if report.repository.exists
    listing = dir(fullfile(repoRootGuess, "STM32Cube_FW_F1*"));
    report.repository.f1Packages = string({listing([listing.isdir]).name});
end

report.functions = struct();
report.functions.stm32ToolsClass = string(which("stm32cube.hwsetup.stm32Tools"));
report.functions.getCubeMxProject = string(which("stm32cube.utils.getSTM32CubeMXProject"));
report.functions.codertargetData = string(which("codertarget.data.setParameterValue"));

ready = report.products.simulink && report.products.simulinkCoder && ...
    report.products.embeddedCoder && ~isempty(report.targetHardware.stm32Hits) && ...
    report.cubeMx.registeredPathExists && report.repository.exists && ...
    ~isempty(report.repository.f1Packages);

report.overall = struct();
report.overall.ready = ready;
if ready
    report.overall.status = "ready";
else
    report.overall.status = "incomplete";
end

jsonPath = fullfile(outDir, "stm32_codegen_stack_probe.json");
fid = fopen(jsonPath, "w");
cleanup = onCleanup(@() fclose(fid));
fprintf(fid, "%s", jsonencode(report, "PrettyPrint", true));
clear cleanup

fprintf("STM32_CODEGEN_STACK_PROBE=%s\n", jsonPath);
fprintf("STM32_CODEGEN_STACK_READY=%s\n", string(report.overall.ready));

function text = getMessageText(id)
    try
        text = string(message(char(id)).getString);
    catch ME
        text = "unavailable: " + string(ME.message);
    end
end

function [registeredPath, registeredVersion] = parseCubeMxInstalledInfo(info)
    registeredPath = "";
    registeredVersion = "";

    if isstring(info) || ischar(info)
        registeredPath = string(info);
        return
    end

    if iscell(info) && ~isempty(info)
        [registeredPath, registeredVersion] = parseCubeMxInstalledInfo(info{1});
        return
    end

    if isstruct(info)
        if isfield(info, "Location")
            registeredPath = string(info.Location);
        elseif isfield(info, "Path")
            registeredPath = string(info.Path);
        elseif isfield(info, "InstallLocation")
            registeredPath = string(info.InstallLocation);
        end

        if isfield(info, "Version")
            registeredVersion = string(info.Version);
        end
    end
end
