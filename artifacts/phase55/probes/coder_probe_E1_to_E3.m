function out = p55_probe(tag)
%P55_PROBE  Phase 5.5 Task 7 diagnosis probe (throwaway, lives outside the repo).
if nargin < 1, tag = 'unset'; end
fixDir = fullfile(tempdir, 'mas_p55_codegen_probe');
if ~exist(fixDir, 'dir'), mkdir(fixDir); end
fid = fopen(fullfile(fixDir, 'p55_tgt.m'), 'w');
fprintf(fid, 'function y = p55_tgt(x)\ny = x.^2 + sin(x);\nend\n');
fclose(fid);
if ~isempty(strfind(path, fixDir)), rmpath(fixDir); end
addpath(fixDir);

out = struct('tag', tag, 'whichTarget', which('p55_tgt'), ...
    'callByChar', '', 'callByCharErr', '', ...
    'callByHandle', '', 'callByHandleErr', '', ...
    'cwd', pwd, 'artifacts', '');

try
    codegen('p55_tgt', {1:10});
    out.callByChar = 'OK';
catch ME
    out.callByChar = 'ERR';
    out.callByCharErr = sprintf('id=[%s] msg=[%s]', ME.identifier, ME.message);
end

try
    codegen(@p55_tgt, {1:10});
    out.callByHandle = 'OK';
catch ME
    out.callByHandle = 'ERR';
    out.callByHandleErr = sprintf('id=[%s] msg=[%s]', ME.identifier, ME.message);
end

d = dir(fullfile(fixDir, '*.mex*'));
names = cellfun(@(s) s, {d.name}, 'UniformOutput', false);
out.artifacts = strjoin(names, ',');
end
