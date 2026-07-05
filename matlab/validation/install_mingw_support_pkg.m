scriptPath = mfilename("fullpath");
repoRoot = fileparts(fileparts(fileparts(scriptPath)));
pkgPath = fullfile(repoRoot, "artifacts", "mingw.mlpkginstall");
outDir = fullfile(repoRoot, "artifacts", "validation");
if ~isfolder(outDir)
    mkdir(outDir);
end

summary = struct();
summary.generatedAt = string(datetime("now", "Format", "yyyy-MM-dd'T'HH:mm:ss"));
summary.packagePath = string(pkgPath);

try
    result = matlab.addons.install(pkgPath);
    summary.status = "installed";
    summary.resultClass = string(class(result));
catch ME
    summary.status = "failed";
    summary.error = string(ME.message);
    summary.identifier = string(ME.identifier);
end

jsonPath = fullfile(outDir, "install_mingw_support_pkg.json");
fid = fopen(jsonPath, "w");
cleanup = onCleanup(@() fclose(fid));
fprintf(fid, "%s", jsonencode(summary, "PrettyPrint", true));
clear cleanup

fprintf("MINGW_SUPPORT_INSTALL=%s\n", jsonPath);
fprintf("MINGW_SUPPORT_STATUS=%s\n", summary.status);
