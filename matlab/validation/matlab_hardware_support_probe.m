%{
@file matlab_hardware_support_probe.m
@brief 探测 MATLAB 侧硬件支持包与嵌入式能力是否满足一键验收要求。
@details
  该脚本面向 STM32 / Raspberry Pi / Simulink / Codegen 联调链闭环验收，
  输出可复用 JSON 报告，供 PowerShell 总控脚本聚合。
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

v = ver;
products = string({v.Name});
report.installedProducts = products;

hasProduct = @(name) any(strcmp(products, string(name)));
containsProduct = @(pattern) any(contains(lower(products), lower(string(pattern))));

addons = strings(0, 1);
addonsError = "";
try
    addonTable = matlab.addons.installedAddons;
    if any(strcmp("Name", addonTable.Properties.VariableNames))
        addons = string(addonTable.Name);
    end
catch ME
    addonsError = string(ME.message);
end

report.installedAddons = addons;
report.addonsQueryError = addonsError;

report.functionProbe = struct();
report.functionProbe.raspiPath = string(which("raspi"));
report.functionProbe.raspiAvailable = strlength(report.functionProbe.raspiPath) > 0;
report.functionProbe.simulinkPath = string(which("sim"));
report.functionProbe.simulinkAvailable = strlength(report.functionProbe.simulinkPath) > 0;
report.functionProbe.codegenPath = string(which("codegen"));
report.functionProbe.codegenAvailable = strlength(report.functionProbe.codegenPath) > 0;

support = struct();

support.simulink = struct();
support.simulink.installed = hasProduct("Simulink");
support.simulink.status = "missing";
if support.simulink.installed
    support.simulink.status = "installed";
end

support.matlabCoder = struct();
support.matlabCoder.installed = hasProduct("MATLAB Coder");
support.matlabCoder.status = "missing";
if support.matlabCoder.installed
    support.matlabCoder.status = "installed";
end

support.embeddedCoder = struct();
support.embeddedCoder.installed = hasProduct("Embedded Coder");
support.embeddedCoder.status = "missing";
if support.embeddedCoder.installed
    support.embeddedCoder.status = "installed";
end

support.stm32 = struct();
support.stm32.productHits = products(contains(lower(products), "stm32"));
support.stm32.addonHits = addons(contains(lower(addons), "stm32"));
support.stm32.hasProduct = ~isempty(support.stm32.productHits);
support.stm32.hasAddon = ~isempty(support.stm32.addonHits);
support.stm32.status = "missing";
if support.stm32.hasProduct || support.stm32.hasAddon
    support.stm32.status = "installed";
end

support.raspberryPi = struct();
support.raspberryPi.productHits = products(contains(lower(products), "raspberry pi"));
support.raspberryPi.addonHits = addons(contains(lower(addons), "raspberry"));
support.raspberryPi.hasProduct = ~isempty(support.raspberryPi.productHits);
support.raspberryPi.hasAddon = ~isempty(support.raspberryPi.addonHits);
support.raspberryPi.status = "missing";
if support.raspberryPi.hasProduct || support.raspberryPi.hasAddon || report.functionProbe.raspiAvailable
    support.raspberryPi.status = "installed";
end

support.integration = struct();
support.integration.hasCorePrerequisites = support.simulink.installed && ...
    support.matlabCoder.installed && support.embeddedCoder.installed;
support.integration.hasBoardSupport = strcmp(support.stm32.status, "installed") && ...
    strcmp(support.raspberryPi.status, "installed");
support.integration.ready = support.integration.hasCorePrerequisites && ...
    support.integration.hasBoardSupport;
support.integration.status = "incomplete";
if support.integration.ready
    support.integration.status = "ready";
end

report.support = support;
report.overall = struct("ready", support.integration.ready, "status", support.integration.status);

jsonPath = fullfile(outDir, "hardware_support_probe.json");
fid = fopen(jsonPath, "w");
cleanup = onCleanup(@() fclose(fid));
fprintf(fid, "%s", jsonencode(report, "PrettyPrint", true));
clear cleanup

fprintf("HARDWARE_SUPPORT_PROBE=%s\n", jsonPath);
fprintf("STM32_SUPPORT_STATUS=%s\n", support.stm32.status);
fprintf("RASPBERRY_PI_SUPPORT_STATUS=%s\n", support.raspberryPi.status);
fprintf("HARDWARE_SUPPORT_READY=%s\n", string(report.overall.ready));
