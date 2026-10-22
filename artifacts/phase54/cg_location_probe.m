repo = 'E:\desktop\MATLAB';
addpath(fullfile(repo, 'skills', 'matlab-codegen-deploy', 'scripts'));
d = fullfile(tempdir, 'cg_location_probe_54');
if exist(d, 'dir'), rmdir(d, 's'); end
mkdir(d);
fid = fopen(fullfile(d, 'locprobe_fn.m'), 'w');
fprintf(fid, 'function y = locprobe_fn(x)\ny = x.^2 + 1;\nend\n');
fclose(fid);
addpath(d);
out = fullfile(tempdir, 'cg_location_out_54');
if exist(out, 'dir'), rmdir(out, 's'); end
cfg = coder.config('mex');
cfg.GenerateReport = true;
evalc('codegen(''-config'', cfg, ''locprobe_fn'', ''-args'', {1:5}, ''-d'', out)');
mexname = ['locprobe_fn_mex.' mexext];
fprintf('cwd=%s\nout=%s\n', pwd, out);
fprintf('mex in out: %d | mex in cwd: %d\n', exist(fullfile(out, mexname), 'file'), exist(fullfile(pwd, mexname), 'file'));
w = which('locprobe_fn_mex');
fprintf('which: %s\n', w);
fprintf('out listing:\n');
listing = dir(out);
for k = 1:numel(listing)
    fprintf('  %s\n', listing(k).name);
end
clear locprobe_fn_mex;
if exist(fullfile(pwd, mexname), 'file'), delete(fullfile(pwd, mexname)); end
rmpath(d);
rmdir(d, 's');
rmdir(out, 's');
