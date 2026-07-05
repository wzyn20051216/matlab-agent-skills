scriptPath = mfilename("fullpath");
repoRoot = fileparts(fileparts(fileparts(scriptPath)));
outDir = fullfile(repoRoot, "artifacts", "validation");
if ~isfolder(outDir)
    mkdir(outDir);
end

summary = struct();
summary.generatedAt = string(datetime("now", "Format", "yyyy-MM-dd'T'HH:mm:ss"));
summary.matlabVersion = string(version);
summary.release = string(version("-release"));
summary.addonsInstallPath = string(which("matlab.addons.install"));
summary.showHardwareSupportPath = string(which("matlab.addons.supportpackage.internal.explorer.showAllHardwareSupportPackages"));

jsonPath = fullfile(outDir, "addon_api_probe.json");
fid = fopen(jsonPath, "w");
cleanup = onCleanup(@() fclose(fid));
fprintf(fid, "%s", jsonencode(summary, "PrettyPrint", true));
clear cleanup

fprintf("ADDON_API_PROBE=%s\n", jsonPath);
fprintf("ADDONS_INSTALL=%s\n", summary.addonsInstallPath);
