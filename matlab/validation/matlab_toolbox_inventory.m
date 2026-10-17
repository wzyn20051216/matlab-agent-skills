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

products = ver;
inventory = struct();
inventory.schemaVersion = "1.0.0";
inventory.generatedAt = masacc.timestamp();
inventory.matlabVersion = string(version);
inventory.release = string(version("-release"));
inventory.products = struct("name", {}, "version", {}, "licensed", {});

for idx = 1:numel(products)
    name = string(products(idx).Name);
    licensed = [];
    try
        licensed = logical(license("test", char(name)));
    catch
        licensed = [];
    end
    inventory.products(idx).name = name;
    inventory.products(idx).version = string(products(idx).Version);
    inventory.products(idx).licensed = licensed;
end

legacyPath = fullfile(outDir, "toolbox_inventory.json");
fid = fopen(legacyPath, "w");
cleanupLegacy = onCleanup(@() fclose(fid));
fprintf(fid, "%s", jsonencode(inventory, "PrettyPrint", true));
clear cleanupLegacy

% 同时产出验收形状报告，供总控脚本合并；清单非空才有意义，因此只有一条 L1 检查。
report = masacc.new("toolbox-inventory", "matlab-batch");
report.toolboxInventory = inventory.products;
metrics = struct("productCount", numel(products), "legacyReport", string(legacyPath));
if numel(products) > 0
    report = masacc.addCheck(report, "inventory.products", "读取已安装产品清单", "L1", "PASS", ...
        Command="ver / license test", Metrics=metrics, ArtifactPaths=[string(legacyPath)]);
else
    report = masacc.addCheck(report, "inventory.products", "读取已安装产品清单", "L1", "FAIL", ...
        Reason="ver 返回空列表，MATLAB 安装可能损坏", ErrorClass="ENVIRONMENT_ERROR", ...
        Command="ver / license test", Metrics=metrics, ArtifactPaths=[string(legacyPath)]);
end

acceptancePath = fullfile(acceptanceDir, "toolbox_inventory.json");
report = masacc.write(report, acceptancePath);

fprintf("TOOLBOX_INVENTORY=%s\n", legacyPath);
fprintf("TOOLBOX_INVENTORY_ACCEPTANCE=%s\n", acceptancePath);
fprintf("MATLAB_RELEASE=%s\n", version("-release"));
fprintf("PRODUCT_COUNT=%d\n", numel(products));
