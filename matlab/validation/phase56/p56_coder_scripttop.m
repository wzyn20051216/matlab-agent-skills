%P56_CODER_SCRIPTTOP  The Phase 5.5 failing shape, measured at true top level.
%
%   run('E:\desktop\MATLAB\matlab\validation\phase56\p56_coder_scripttop.m')
%
% Phase 5.5's codegen failure came from an entry that exists only as a local
% function of the code being evaluated. p56_coder_entry_form_probe.m tried to
% reproduce that, but a function cannot host a top-level script-local entry: the
% probe had to call run(), which raises MATLAB:err_static_workspace_violation
% before codegen is reached. That measured the harness, not Coder.
%
% This file removes the wrapper. It IS a script, the entry below IS a local
% function of the script, and the handle refers to it -- the shape under question,
% with no run() inside a function.
%
% Launch is recorded through the P56_LAUNCHER environment variable so the two
% channels that can run this file stay distinguishable: the MCP session sets it to
% 'mcpfile' before calling run_matlab_file, and a batch process sets it to 'batch'
% inside its own -batch command. Frames are recorded too, so a label can be
% checked rather than trusted. Writes
% <repo>/artifacts/phase56/coder_channel/scripttop_<launcher>.json.

t0 = tic;
here = fileparts(mfilename('fullpath'));
% <repo>/matlab/validation/phase56 -> three levels up is the repo root.
repo = fileparts(fileparts(fileparts(here)));
outDir = fullfile(repo, 'artifacts', 'phase56', 'coder_channel');
if ~isfolder(outDir), mkdir(outDir); end
launcher = getenv('P56_LAUNCHER');
if isempty(launcher), launcher = 'unlabelled'; end

S = struct();
S.tag = 'E';
S.channel = launcher;
S.form = 'scriptlocal-top-level';
S.at = datestr(now, 31);
S.release = version;
S.workDir = fullfile(outDir, ['top_' launcher]);
if ~isfolder(S.workDir), mkdir(S.workDir); end
oldPwd = pwd;
cd(S.workDir);

fs = dbstack('-completenames');
S.callFrames = cell(1, min(6, numel(fs)));
for q = 1:numel(S.callFrames)
    S.callFrames{q} = sprintf('%s:%d in %s', strrep(fs(q).file, '\', '/'), fs(q).line, fs(q).name);
end

S.entryResolvedBy = '';
try %#ok<TRYNC>
    w = which('p56coder_local');
    if ~isempty(w), S.entryResolvedBy = strrep(w, filesep, '/'); end
end

S.expression = 'codegen(f, ''-args'', {0.5})  with f = @p56coder_local, a local function of this script';
S.ok = false;
S.errorIdentifier = '';
S.errorMessage = '';
S.errorFrames = {};
try
    f = @p56coder_local;
    codegen(f, '-args', {0.5});
    S.ok = true;
catch ME
    S.errorIdentifier = char(ME.identifier);
    S.errorMessage = strtrim(char(ME.message));
    for q = 1:numel(ME.stack)
        S.errorFrames{end + 1} = sprintf('%s:%d in %s', strrep(ME.stack(q).file, '\', '/'), ...
            ME.stack(q).line, ME.stack(q).name); %#ok<AGROW>
    end
    S.errorFrames = S.errorFrames(1:min(6, numel(S.errorFrames)));
end

S.artifacts = {};
d = dir(fullfile(S.workDir, '**', '*'));
for q = 1:numel(d)
    if ~d(q).isdir
        S.artifacts{end + 1} = strrep(strrep(fullfile(d(q).folder, d(q).name), S.workDir, ''), '\', '/'); %#ok<AGROW>
    end
end
if numel(S.artifacts) > 25, S.artifacts = S.artifacts(1:25); end
S.generatedDirExists = isfolder(fullfile(S.workDir, 'codegen'));
S.elapsedSeconds = round(toc(t0), 2);
S.claim = ['one launcher x the script-local entry at top level; says which ' ...
    'identifier appears, nothing about MATLAB Coder internals'];

cd(oldPwd);
fid = fopen(fullfile(outDir, ['scripttop_' launcher '.json']), 'w');
if fid >= 0
    fwrite(fid, jsonencode(S), 'char');
    fclose(fid);
end
fprintf('[%s/%s] ok=%d id=[%s] artifacts=%d\n', S.tag, S.channel, S.ok, ...
    S.errorIdentifier, numel(S.artifacts));

% ===========================================================================
function y = p56coder_local(x)
y = x * 2 + sin(x);
end
