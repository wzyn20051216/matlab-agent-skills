%{
@file matlab_toolbox_inventory.m
@brief 产品清单与授权清点（L1）：产品名 / 版本 / license feature / 授权三态。

@details
  与旧版的差异：
  1. 旧版直接对 ver 返回的**产品显示名**调 license('test')，对 MATLAB Coder、
     Simulink Coder、Embedded Coder 一律返回 0，把"查错键"当成"没授权"；
  2. 旧版把异常吞成 []，连 Statistics and Machine Learning Toolbox 触发的
     MATLAB:license:toomanychars 都没有留下任何原因；
  3. 新版改用 masacc.inventory()，每个产品都带 licenseFeature 与 licenseSource，
     授权结论是三态（true / false / 无法判定），不再把"测不了"写成"没授权"；
  4. 新增一条检查：被验收门禁依赖的核心产品必须给出**确定**的授权结论，
     不能停留在"无法判定"。
%}

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

% 这些产品决定 Coder / Simulink 验收能否执行，授权结论必须是确定的布尔值。
gatedProducts = ["MATLAB", "Simulink", "MATLAB Coder", "Simulink Coder", "Embedded Coder"];

started = masacc.timestamp();
elapsed = tic;
items = masacc.inventory();
elapsedSeconds = toc(elapsed);

licensedCount = 0;
unlicensedCount = 0;
unknownCount = 0;
unknownNames = strings(0, 1);
for idx = 1:numel(items)
    if isempty(items(idx).licensed)
        unknownCount = unknownCount + 1;
        unknownNames(end + 1) = items(idx).name;
    elseif items(idx).licensed
        licensedCount = licensedCount + 1;
    else
        unlicensedCount = unlicensedCount + 1;
    end
end

inventory = struct();
inventory.schemaVersion = "1.0.0";
inventory.generatedAt = masacc.timestamp();
inventory.matlabVersion = string(version);
inventory.release = string(version("-release"));
inventory.products = items;
inventory.counts = struct( ...
    "total", numel(items), ...
    "licensed", licensedCount, ...
    "unlicensed", unlicensedCount, ...
    "unknown", unknownCount);

legacyPath = fullfile(outDir, "toolbox_inventory.json");
fid = fopen(legacyPath, "w");
cleanupLegacy = onCleanup(@() fclose(fid));
% 与验收报告保持同一套空值约定：无法判定的 licensed 写成 null，而不是 []。
fprintf(fid, "%s", masacc.jsonNulls(jsonencode(inventory, "PrettyPrint", true)));
clear cleanupLegacy

% ---------------- L1：清单非空 ----------------
report = masacc.new("toolbox-inventory", "matlab-batch");
report.toolboxInventory = items;
metrics = struct( ...
    "productCount", numel(items), ...
    "licensedCount", licensedCount, ...
    "unlicensedCount", unlicensedCount, ...
    "unknownCount", unknownCount, ...
    "legacyReport", string(legacyPath));
if numel(items) > 0
    report = masacc.addCheck(report, "inventory.products", "读取已安装产品清单", "L1", "PASS", ...
        Command="ver + masacc.licenseState", Metrics=metrics, ...
        StartedAt=started, FinishedAt=masacc.timestamp(), DurationSeconds=elapsedSeconds, ...
        ArtifactPaths=[string(legacyPath)]);
else
    report = masacc.addCheck(report, "inventory.products", "读取已安装产品清单", "L1", "FAIL", ...
        Reason="ver 返回空列表，MATLAB 安装可能损坏", ErrorClass="ENVIRONMENT_ERROR", ...
        Command="ver + masacc.licenseState", Metrics=metrics, ArtifactPaths=[string(legacyPath)]);
end

% ---------------- L1：核心产品的授权结论必须确定 ----------------
gatedDetails = struct("product", {}, "licenseFeature", {}, "licenseExists", {}, "installed", {});
undetermined = strings(0, 1);
for idx = 1:numel(gatedProducts)
    name = gatedProducts(idx);
    state = masacc.licenseState(name);
    gatedDetails(idx).product = name;
    gatedDetails(idx).licenseFeature = state.feature;
    gatedDetails(idx).licenseExists = state.exists;
    gatedDetails(idx).installed = masacc.hasProduct(name);
    if isempty(state.exists)
        undetermined(end + 1) = name;
    end
end

gatedMetrics = struct( ...
    "gatedProducts", gatedProducts, ...
    "undetermined", undetermined, ...
    "details", gatedDetails, ...
    "unknownProductNames", unknownNames);
if isempty(undetermined)
    report = masacc.addCheck(report, "inventory.gated-license", ...
        "核心产品授权结论确定（不允许停留在无法判定）", "L1", "PASS", ...
        Command="license('test', <feature>) for MATLAB/Simulink/*Coder", Metrics=gatedMetrics);
else
    report = masacc.addCheck(report, "inventory.gated-license", ...
        "核心产品授权结论确定（不允许停留在无法判定）", "L1", "FAIL", ...
        Reason="以下核心产品无法判定授权：" + strjoin(undetermined, ", ") + ...
            "；需要把它们的 license feature 名补进 masacc.featureName 映射表", ...
        ErrorClass="LICENSE_ERROR", ...
        Command="license('test', <feature>) for MATLAB/Simulink/*Coder", Metrics=gatedMetrics);
end

acceptancePath = fullfile(acceptanceDir, "toolbox_inventory.json");
report = masacc.write(report, acceptancePath);

fprintf("TOOLBOX_INVENTORY=%s\n", legacyPath);
fprintf("TOOLBOX_INVENTORY_ACCEPTANCE=%s\n", acceptancePath);
fprintf("MATLAB_RELEASE=%s\n", version("-release"));
fprintf("PRODUCT_COUNT=%d\n", numel(items));
fprintf("LICENSED_COUNT=%d UNLICENSED_COUNT=%d UNKNOWN_COUNT=%d\n", ...
    licensedCount, unlicensedCount, unknownCount);
