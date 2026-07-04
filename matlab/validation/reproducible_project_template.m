function manifestPath = reproducible_project_template(projectName, sourceUrl, outputRoot)
% reproducible_project_template Create a minimal manifest for MATLAB paper reproduction.
%
% manifestPath = reproducible_project_template(projectName, sourceUrl, outputRoot)
% creates a reproducible folder layout and records MATLAB version, products,
% source URL, random seed, and timestamp. Extend the generated manifest while
% reproducing paper figures or tables.

arguments
    projectName (1,1) string
    sourceUrl (1,1) string = ""
    outputRoot (1,1) string = "repro"
end

rng(42, "twister");

projectDir = fullfile(outputRoot, matlab.lang.makeValidName(projectName));
subdirs = ["source", "scripts", "figures", "results", "logs"];
for idx = 1:numel(subdirs)
    target = fullfile(projectDir, subdirs(idx));
    if ~isfolder(target)
        mkdir(target);
    end
end

products = ver;
manifest = struct();
manifest.projectName = projectName;
manifest.sourceUrl = sourceUrl;
manifest.generatedAt = string(datetime("now", "Format", "yyyy-MM-dd'T'HH:mm:ss"));
manifest.matlabVersion = string(version);
manifest.release = string(version("-release"));
manifest.randomSeed = 42;
manifest.products = string({products.Name});
manifest.acceptance = ["Run baseline example", "Reproduce one figure", "Record numeric delta"];

manifestPath = fullfile(projectDir, "manifest.json");
fid = fopen(manifestPath, "w");
cleanup = onCleanup(@() fclose(fid));
fprintf(fid, "%s", jsonencode(manifest, "PrettyPrint", true));
clear cleanup
end
