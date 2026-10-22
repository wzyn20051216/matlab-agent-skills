function out = p55_probe2(tag)
%P55_PROBE2  Phase 5.5 Task 7 control: the exact codegen call form used by
% mas_codegen_verify, run outside the MATLAB MCP session.
repoFix = 'E:\desktop\MATLAB\matlab\validation\crossdomain\tasks';
addpath(repoFix);
addpath('E:\desktop\MATLAB\skills\matlab-codegen-deploy\scripts');
buildDir = fullfile(tempdir, 'mas_p55_build_fresh');
if ~exist(buildDir, 'dir'), mkdir(buildDir); end
fprintf('TAG=%s which=[%s]\n', tag, which('codegen_target'));
cfg = coder.config('mex');
try
    codegen('-config', cfg, 'codegen_target', '-args', {1:10}, '-d', buildDir);
    fprintf('FRESH_PROCESS_CODEGEN=OK\n');
catch ME
    fprintf('FRESH_PROCESS_CODEGEN=ERR id=[%s] msg=[%s]\n', ME.identifier, ME.message);
end
d = dir(fullfile(buildDir, '*'));
fprintf('artifacts: %s\n', strjoin({d(3:end).name}, ', '));
r = mas_codegen_verify('codegen_target', {1:10});
fprintf('mas_codegen_verify verdict=%s stage=%s detail=[%s]\n', r.verdict, r.stage, r.detail);
out = r;
end
