scriptPath = mfilename("fullpath");
repoRoot = fileparts(fileparts(fileparts(scriptPath)));
scriptDir = fileparts(scriptPath);
addpath(scriptDir);

outDir = fullfile(repoRoot, "artifacts", "validation");
acceptanceDir = fullfile(outDir, "acceptance");
if ~isfolder(outDir)
    mkdir(outDir);
end
if ~isfolder(acceptanceDir)
    mkdir(acceptanceDir);
end

report = masacc.new("feature-probe", "matlab-batch");
report.limitations = [
    "本脚本只做能力探测（L1），不证明任何模型训练、代码生成或硬件部署可用。"
    "外部技能目录通过环境变量 MATLAB_AGENT_SKILLS_EMBEDDED_ROOT 注入，未设置时该子项为 SKIP。"
];

v = ver;
products = string({v.Name});
report.toolboxInventory = masacc.inventory();

hasProduct = @(name) any(strcmp(products, string(name)));
hasFunction = @(name) exist(name, "file") > 0 || exist(name, "builtin") > 0;

% 安装 ≠ 授权 ≠ 可执行：这里用 availability 拿三态事实，避免"已安装就放行"。
coderAvail = masacc.availability("MATLAB Coder");
dltbAvail = masacc.availability("Deep Learning Toolbox");
simulinkAvail = masacc.availability("Simulink");
embeddedCoderAvail = masacc.availability("Embedded Coder");

% ---------------- 直接导入能力 ----------------
directImport = struct();
directImport.claim = "Direct import of PyTorch/TensorFlow Lite style models and C/C++ generation";
directImport.hasMATLABCoder = hasProduct("MATLAB Coder");
directImport.hasDLTbx = hasProduct("Deep Learning Toolbox");
directImport.hasGPUCoder = hasProduct("GPU Coder");
directImport.hasImporterFunction = hasFunction("loadPyTorchExportedProgram");
directImport.hasLiteRTFunction = hasFunction("loadLiteRTModel");
directImport.matlabCoder = localAvailabilityFacts(coderAvail);
directImport.dltbx = localAvailabilityFacts(dltbAvail);
directImport.status = "missing_prerequisites";
if coderAvail.available && dltbAvail.available
    if directImport.hasImporterFunction || directImport.hasLiteRTFunction
        directImport.status = "present";
    else
        directImport.status = "not_detected";
    end
elseif coderAvail.installed && dltbAvail.installed
    % 装了但授权/执行不可用：这是"无法验证"，不是"缺产品"。
    directImport.status = "unavailable";
end

switch directImport.status
    case "present"
        report = masacc.addCheck(report, "feature.direct-import", "PyTorch/TFLite 直接导入 API 可用", "L1", "PASS", ...
            Metrics=directImport);
    case "not_detected"
        report = masacc.addCheck(report, "feature.direct-import", "PyTorch/TFLite 直接导入 API 可用", "L1", "SKIP", ...
            Reason="已安装且可用 MATLAB Coder 与 Deep Learning Toolbox，但未检测到 loadPyTorchExportedProgram / loadLiteRTModel", ...
            Metrics=directImport);
    case "unavailable"
        report = masacc.addCheck(report, "feature.direct-import", "PyTorch/TFLite 直接导入 API 可用", "L1", "SKIP", ...
            Reason="产品已安装但不可用：" + coderAvail.reason + " / " + dltbAvail.reason, ...
            ErrorClass="LICENSE_ERROR", Metrics=directImport);
    otherwise
        report = masacc.addCheck(report, "feature.direct-import", "PyTorch/TFLite 直接导入 API 可用", "L1", "SKIP", ...
            Reason="缺少前置产品：MATLAB Coder 或 Deep Learning Toolbox", Metrics=directImport);
end

% ---------------- 硬件块集 ----------------
blocksets = struct();
blocksets.claim = "Official STM32 and Raspberry Pi Blockset availability";
blocksets.hasSimulink = hasProduct("Simulink");
blocksets.hasEmbeddedCoder = hasProduct("Embedded Coder");
blocksets.hasC2000Blockset = hasProduct("C2000 Microcontroller Blockset");
blocksets.hasSTM32Product = hasProduct("STM32 Blockset") || hasProduct("STM32 Microcontroller Blockset");
blocksets.hasRaspiProduct = hasProduct("Raspberry Pi Blockset");
blocksets.simulink = localAvailabilityFacts(simulinkAvail);
blocksets.embeddedCoder = localAvailabilityFacts(embeddedCoderAvail);
blocksets.status = "not_installed";
if blocksets.hasSTM32Product || blocksets.hasRaspiProduct
    blocksets.status = "installed";
    % 块集本身装上还不够：模型代码生成依赖 Simulink 与 Embedded Coder 真的可用。
    if ~(simulinkAvail.available && embeddedCoderAvail.available)
        blocksets.status = "installed_but_unavailable";
    end
end

switch blocksets.status
    case "installed"
        report = masacc.addCheck(report, "feature.blocksets", "STM32 / Raspberry Pi 官方块集可用", "L1", "PASS", ...
            Metrics=blocksets);
    case "installed_but_unavailable"
        report = masacc.addCheck(report, "feature.blocksets", "STM32 / Raspberry Pi 官方块集可用", "L1", "SKIP", ...
            Reason="块集已安装，但 Simulink / Embedded Coder 不可用：" + ...
                simulinkAvail.reason + " / " + embeddedCoderAvail.reason, ...
            ErrorClass="LICENSE_ERROR", Metrics=blocksets);
    otherwise
        report = masacc.addCheck(report, "feature.blocksets", "STM32 / Raspberry Pi 官方块集可用", "L1", "SKIP", ...
            Reason="未检测到 STM32 或 Raspberry Pi 官方块集；硬件部署相关验收只能 SKIP", Metrics=blocksets);
end

% ---------------- 本地技能目录 ----------------
agentic = struct();
agentic.claim = "Agentic Toolkit / Embedded AI skill style workflow";
agentic.localSkillRepo = isfolder(fullfile(repoRoot, "skills", "matlab-orchestrator"));
embeddedSkillRoot = string(getenv("MATLAB_AGENT_SKILLS_EMBEDDED_ROOT"));
agentic.embeddedSkillRoot = embeddedSkillRoot;
agentic.localEmbeddedSkill = false;
if strlength(embeddedSkillRoot) > 0
    agentic.localEmbeddedSkill = isfolder(fullfile(embeddedSkillRoot, "matlab-orchestrator"));
end
agentic.hasLocalAutomation = agentic.localSkillRepo || agentic.localEmbeddedSkill;
if agentic.hasLocalAutomation
    agentic.status = "local_skill_available";
else
    agentic.status = "not_available";
end

if agentic.localSkillRepo
    report = masacc.addCheck(report, "feature.agentic", "本地技能目录可用", "L1", "PASS", Metrics=agentic);
elseif agentic.localEmbeddedSkill
    report = masacc.addCheck(report, "feature.agentic", "本地技能目录可用", "L1", "PASS", ...
        Metrics=agentic);
else
    report = masacc.addCheck(report, "feature.agentic", "本地技能目录可用", "L1", "SKIP", ...
        Reason="仓库内未找到 skills/matlab-orchestrator，且未设置 MATLAB_AGENT_SKILLS_EMBEDDED_ROOT", Metrics=agentic);
end

% ---------------- addons ----------------
addonsInfo = struct();
addonsInfo.success = false;
addonsInfo.names = strings(0, 1);
try
    T = matlab.addons.installedAddons;
    if any(strcmp("Name", T.Properties.VariableNames))
        addonsInfo.names = string(T.Name);
    end
    addonsInfo.success = true;
catch ME
    addonsInfo.error = string(ME.message);
end

% 兼容旧版明细文件（文档与 CI 仍在引用）。
legacy = struct();
legacy.schemaVersion = "1.0.0";
legacy.generatedAt = masacc.timestamp();
legacy.matlabVersion = string(version);
legacy.release = string(version("-release"));
legacy.installedProducts = products;
legacy.addons = addonsInfo;
legacy.features = struct("directImport", directImport, "blocksets", blocksets, "agentic", agentic);

legacyPath = fullfile(outDir, "feature_probe.json");
fid = fopen(legacyPath, "w");
cleanupLegacy = onCleanup(@() fclose(fid));
fprintf(fid, "%s", jsonencode(legacy, "PrettyPrint", true));
clear cleanupLegacy

acceptancePath = fullfile(acceptanceDir, "feature_probe.json");
report = masacc.write(report, acceptancePath);

fprintf("FEATURE_PROBE=%s\n", legacyPath);
fprintf("FEATURE_PROBE_ACCEPTANCE=%s\n", acceptancePath);
fprintf("DIRECT_IMPORT_STATUS=%s\n", directImport.status);
fprintf("STM32_BLOCKSET_STATUS=%s\n", blocksets.status);
fprintf("AGENTIC_STATUS=%s\n", agentic.status);

function facts = localAvailabilityFacts(info)
%LOCALAVAILABILITYFACTS 把 availability 结构裁成适合写进 metrics 的精简形状。
facts = struct( ...
    "installed", info.installed, ...
    "licenseFeature", info.licenseFeature, ...
    "licenseExists", info.licenseExists, ...
    "executionProven", info.executionProven, ...
    "available", info.available, ...
    "provenBy", info.provenBy, ...
    "reason", info.reason);
end
