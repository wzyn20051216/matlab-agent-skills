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

try
    mex('-setup', 'C');
    summary.mexC = "configured";
catch ME
    summary.mexC = "failed";
    summary.mexCError = string(ME.message);
end

try
    mex('-setup', 'C++');
    summary.mexCpp = "configured";
catch ME
    summary.mexCpp = "failed";
    summary.mexCppError = string(ME.message);
end

jsonPath = fullfile(outDir, "mex_probe.json");
fid = fopen(jsonPath, "w");
cleanup = onCleanup(@() fclose(fid));
fprintf(fid, "%s", jsonencode(summary, "PrettyPrint", true));
clear cleanup

fprintf("MEX_PROBE=%s\n", jsonPath);
fprintf("MEX_C=%s\n", summary.mexC);
fprintf("MEX_CPP=%s\n", summary.mexCpp);
