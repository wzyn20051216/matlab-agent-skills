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
hasFunction = @(name) exist(name, "file") > 0 || exist(name, "builtin") > 0;

feature = struct();

feature.directImport = struct();
feature.directImport.claim = "Direct import of PyTorch/TensorFlow Lite style models and C/C++ generation";
feature.directImport.hasMATLABCoder = hasProduct("MATLAB Coder");
feature.directImport.hasEmbeddedCoder = hasProduct("Embedded Coder");
feature.directImport.hasDLTbx = hasProduct("Deep Learning Toolbox");
feature.directImport.hasGPUCoder = hasProduct("GPU Coder");
feature.directImport.hasImporterFunction = hasFunction("loadPyTorchExportedProgram");
feature.directImport.hasLiteRTFunction = hasFunction("loadLiteRTModel");
feature.directImport.hasTorchSetup = hasFunction("coder.loadDeepLearningNetwork");
feature.directImport.status = "unknown";
if feature.directImport.hasMATLABCoder && feature.directImport.hasDLTbx
    if feature.directImport.hasImporterFunction || feature.directImport.hasLiteRTFunction
        feature.directImport.status = "present";
    else
        feature.directImport.status = "not_detected";
    end
else
    feature.directImport.status = "missing_prerequisites";
end

feature.blocksets = struct();
feature.blocksets.claim = "Official STM32 and Raspberry Pi Blockset availability";
feature.blocksets.hasSimulink = hasProduct("Simulink");
feature.blocksets.hasEmbeddedCoder = hasProduct("Embedded Coder");
feature.blocksets.hasC2000Blockset = hasProduct("C2000 Microcontroller Blockset");
feature.blocksets.hasSTM32Product = hasProduct("STM32 Blockset") || hasProduct("STM32 Microcontroller Blockset");
feature.blocksets.hasRaspiProduct = hasProduct("Raspberry Pi Blockset");
feature.blocksets.status = "not_installed";
if feature.blocksets.hasSTM32Product || feature.blocksets.hasRaspiProduct
    feature.blocksets.status = "installed";
end

feature.agentic = struct();
feature.agentic.claim = "Agentic Toolkit / Embedded AI skill style workflow";
feature.agentic.localSkillRepo = isfolder(fullfile(repoRoot, "skills", "matlab-orchestrator"));
feature.agentic.localEmbeddedSkill = isfolder("E:\desktop\CAD\.agents\skills\matlab-orchestrator");
feature.agentic.hasLocalAutomation = feature.agentic.localSkillRepo && feature.agentic.localEmbeddedSkill;
feature.agentic.status = "local_skill_available";

addonsInfo = struct();
addonsInfo.success = false;
addonsInfo.names = strings(0,1);
try
    T = matlab.addons.installedAddons;
    if any(strcmp("Name", T.Properties.VariableNames))
        addonsInfo.names = string(T.Name);
    end
    addonsInfo.success = true;
catch ME
    addonsInfo.error = string(ME.message);
end
report.addons = addonsInfo;

report.features = feature;

jsonPath = fullfile(outDir, "feature_probe.json");
fid = fopen(jsonPath, "w");
cleanup = onCleanup(@() fclose(fid));
fprintf(fid, "%s", jsonencode(report, "PrettyPrint", true));
clear cleanup

fprintf("FEATURE_PROBE=%s\n", jsonPath);
fprintf("DIRECT_IMPORT_STATUS=%s\n", feature.directImport.status);
fprintf("STM32_BLOCKSET_STATUS=%s\n", feature.blocksets.status);
fprintf("AGENTIC_STATUS=%s\n", feature.agentic.status);
