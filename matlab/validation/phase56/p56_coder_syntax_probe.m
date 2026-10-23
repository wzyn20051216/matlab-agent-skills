function R = p56_coder_syntax_probe(outDir)
%P56_CODER_SYNTAX_PROBE  Is the codegen failure call syntax or channel?
%
%   R = p56_coder_syntax_probe('E:\desktop\MATLAB\artifacts\phase56\coder_channel')
%
% before blaming Coder, the documented handle syntax has to be tried: codegen
% accepts codegen(f, {0.5}) for a function handle, while codegen(f, '-args',
% {0.5}) is the file-name form. The probe therefore runs
%
%   O  anonymous handle, '-args' form        (the shape that failed everywhere)
%   Q  anonymous handle, codegen(f, {0.5})   (documented handle form)
%   P  function-handle reference to the file entry, codegen(@p56coder_entry, {0.5})
%
% and records the identifier, message and stack for each. Called from batch and
% from the MCP frame so the two channels see identical code. A true top-level
% script-local entry (no wrapping function) is run separately, because calling
% run() from inside a function raises MATLAB:err_static_workspace_violation and
% that would confound the comparison.

tags = {'O', 'Q', 'P'};
forms = {'anon-handle-args', 'anon-handle-naive', 'file-handle'};
srcDir = fullfile(outDir, 'src');
if ~isfolder(srcDir), mkdir(srcDir); end
p = fullfile(srcDir, 'p56coder_entry.m');
if ~isfile(p)
    fid = fopen(p, 'w');
    % newline is a function, so it cannot sit between string literals in an
    % argument list; the whole body is built with sprintf instead.
    fwrite(fid, sprintf('function y = p56coder_entry(x)\ny = x * 2 + sin(x);\nend\n'), 'char');
    fclose(fid);
end
addpath(srcDir);
workDir = fullfile(outDir, 'syntax');
if ~isfolder(workDir), mkdir(workDir); end
old = pwd; cd(workDir);
R = struct('tag', {}, 'form', {}, 'channel', {}, 'ok', {}, 'errorIdentifier', {}, ...
           'errorMessage', {}, 'errorStack', {}, 'artifacts', {}, 'at', {});
for k = 1:numel(tags)
    row = struct();
    row.tag = tags{k}; row.form = forms{k}; row.at = datestr(now, 31);
    st = dbstack('-completenames');
    row.channel = 'plain-caller';
    for q = 1:numel(st)
        if ~isempty(regexpi([st(q).name ' ' st(q).file], 'LiveEditorEvaluationHelper|mcpEval'))
            row.channel = 'mcp-dynamic-eval';
        end
    end
    row.ok = false; row.errorIdentifier = ''; row.errorMessage = ''; row.errorStack = {};
    try
        switch row.tag
            case 'O'
                f = @(x) x * 2 + sin(x);
                codegen(f, '-args', {0.5});
            case 'Q'
                f = @(x) x * 2 + sin(x);
                codegen(f, {0.5});
            case 'P'
                codegen(@p56coder_entry, {0.5});
        end
        row.ok = true;
    catch ME
        row.errorIdentifier = char(ME.identifier);
        row.errorMessage = strtrim(char(ME.message));
        for q = 1:numel(ME.stack)
            row.errorStack{end+1} = sprintf('%s:%d in %s', strrep(ME.stack(q).file, '\', '/'), ...
                ME.stack(q).line, ME.stack(q).name); %#ok<AGROW>
        end
        row.errorStack = row.errorStack(1:min(5, numel(row.errorStack)));
    end
    d = dir(fullfile(workDir, '**', '*'));
    keep = ~[d.isdir];
    row.artifacts = cellfun(@(s) strrep(s, '\', '/'), ...
        cellstr(fullfile({d(keep).folder}, {d(keep).name})).', 'UniformOutput', false);
    if numel(row.artifacts) > 8, row.artifacts = row.artifacts(1:8); end
    R(end+1) = row; %#ok<AGROW>
    fprintf('[%s] %-22s %-17s ok=%-5s id=[%s] msg=[%s]\n', row.tag, row.form, row.channel, ...
        mat2str(row.ok), row.errorIdentifier, strrep(row.errorMessage(1:min(end, 90)), newline, ' / '));
end
cd(old);
rmpath(srcDir);
fid = fopen(fullfile(outDir, ['syntax_' strrep(row.channel, '-', '') ...
    '_' datestr(now, 'yyyymmdd_HHMMSS') '.json']), 'w');
if fid >= 0
    fwrite(fid, jsonencode(R), 'char'); fclose(fid);
end
end
