scriptPath = mfilename("fullpath");
repoRoot = fileparts(fileparts(fileparts(scriptPath)));
outDir = fullfile(repoRoot, "artifacts", "validation");
if ~isfolder(outDir)
    mkdir(outDir);
end

products = ver;
inventory = struct();
inventory.generatedAt = string(datetime("now", "Format", "yyyy-MM-dd'T'HH:mm:ss"));
inventory.matlabVersion = string(version);
inventory.release = string(version("-release"));
inventory.products = struct("name", {}, "version", {});

for idx = 1:numel(products)
    inventory.products(idx).name = string(products(idx).Name);
    inventory.products(idx).version = string(products(idx).Version);
end

jsonPath = fullfile(outDir, "toolbox_inventory.json");
fid = fopen(jsonPath, "w");
cleanup = onCleanup(@() fclose(fid));
fprintf(fid, "%s", jsonencode(inventory, "PrettyPrint", true));
clear cleanup

fprintf("TOOLBOX_INVENTORY=%s\n", jsonPath);
fprintf("MATLAB_RELEASE=%s\n", version("-release"));
fprintf("PRODUCT_COUNT=%d\n", numel(products));
