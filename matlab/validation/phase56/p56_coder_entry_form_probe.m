function S = p56_coder_entry_form_probe(outDir, tag, form)
%P56_CODER_ENTRY_FORM_PROBE  Vary the ENTRY FORM, not the channel.
%
%   S = p56_coder_entry_form_probe(outDir, 'F', 'scriptlocal')
%
% p56_coder_channel_probe fixed the entry form (a standalone .m file) and varied
% the channel; it found MATLAB Coder succeeding over the MCP dynamic-evaluation
% channel. Phase 5.5 had concluded the channel was the discriminating variable,
% but its failing case used an entry that exists only inside the evaluation
% frame. Those two shapes were never separated. This probe separates them:
%
%   form = 'file'        entry is a standalone .m found by which()
%   form = 'scriptlocal' entry is a local function at the end of a script
%   form = 'inline'      entry is an anonymous function in the calling frame
%
% Run from a batch process and from the MCP evaluation frame, so both factors are
% covered. Every row records how the entry resolved, the exact error identifier
% and message, the frames of the catch stack, and what artifacts exist afterwards.
% The only claim drawn is which factor flips the outcome; nothing here describes
% how MATLAB Coder resolves entries internally.

if nargin < 3, form = 'file'; end
entryName = 'p56coder_entry';
t0 = tic;
S = struct();
S.tag = char(tag); S.form = char(form); S.at = datestr(now, 31); S.release = version;

% The channel is identified by the frames under this function: the MCP tool runs
% payloads through mcpEval inside a LiveEditorEvaluationHelper script.
st = dbstack('-completenames');
S.channel = 'plain-caller';
frames = {};
for k = 1:numel(st)
    frames{end+1} = sprintf('%s:%d in %s', strrep(st(k).file, '\', '/'), st(k).line, st(k).name); %#ok<AGROW>
    if ~isempty(regexpi([st(k).name ' ' st(k).file], 'LiveEditorEvaluationHelper|mcpEval'))
        S.channel = 'mcp-dynamic-eval';
    end
end
S.callStack = frames(1:min(6, numel(frames)));

S.workDir = fullfile(outDir, ['form_' S.tag]);
if ~isfolder(S.workDir), mkdir(S.workDir); end
old = pwd;
cd(S.workDir);

srcDir = fullfile(outDir, 'src');
if ~isfolder(srcDir), mkdir(srcDir); end
addEntryFile(entryName, srcDir);
addpath(srcDir);
S.entryResolvedBy = '';
w = which(entryName);
if ~isempty(w), S.entryResolvedBy = strrep(w, filesep, '/'); end

switch S.form
    case 'file'
        S.expression = 'codegen p56coder_entry -args {0.5}   (entry = standalone .m)';
        body = {@() codegen(entryName, '-args', {0.5})};
    case 'scriptlocal'
        scr = fullfile(S.workDir, 'p56coder_script.m');
        writeScript(scr);
        S.expression = ['run(<script>) where the entry is a local function ' ...
            'p56coder_local at the end of that script'];
        body = {@() run(scr)};
    case 'inline'
        f = @(x) x * 2 + sin(x);
        S.expression = 'codegen f -args {0.5}   with f = @(x) x*2+sin(x)';
        body = {@() codegen(f, '-args', {0.5})};
    otherwise
        rmpath(srcDir); cd(old);
        error('p56coder_entry_form_probe:form', 'unknown form %s', S.form);
end

S.ok = false;
S.errorIdentifier = '';
S.errorMessage = '';
S.errorFrames = {};
try
    body{1}();
    S.ok = true;
catch ME
    S.errorIdentifier = char(ME.identifier);
    S.errorMessage = strtrim(char(ME.message));
    for k = 1:numel(ME.stack)
        S.errorFrames{end+1} = sprintf('%s:%d in %s', strrep(ME.stack(k).file, '\', '/'), ...
            ME.stack(k).line, ME.stack(k).name); %#ok<AGROW>
    end
    S.errorFrames = S.errorFrames(1:min(6, numel(S.errorFrames)));
end

S.artifacts = listGenerated(S.workDir);
S.generatedDirExists = isfolder(fullfile(S.workDir, 'codegen'));
rmpath(srcDir);
cd(old);
S.elapsedSeconds = round(toc(t0), 2);
S.pathEntriesAfter = numel(strsplit(path, pathsep));
S.claim = ['one channel x one entry form; records which combination fails and with ' ...
    'what identifier. No statement about MATLAB Coder internals.'];

fid = fopen(fullfile(outDir, ['form_' S.tag '.json']), 'w');
if fid >= 0
    fwrite(fid, jsonencode(S), 'char'); fclose(fid);
end
end

% ===========================================================================
function addEntryFile(name, dir_)
p = fullfile(dir_, [name '.m']);
if isfile(p), return; end
fid = fopen(p, 'w');
if fid < 0, error('p56coder_entry_form_probe:write', 'cannot write %s', p); end
fwrite(fid, sprintf('function y = %s(x)\ny = x * 2 + sin(x);\nend\n', name), 'char');
fclose(fid);
end

% ===========================================================================
function writeScript(p)
fid = fopen(p, 'w');
if fid < 0, error('p56coder_entry_form_probe:write', 'cannot write %s', p); end
fwrite(fid, ['% entry form probe: the callable is a LOCAL function of this script' newline ...
             'f = @p56coder_local;' newline ...
             'codegen(f, ''-args'', {0.5});' newline ...
             'scriptCodegenOk = true;' newline ...
             'function y = p56coder_local(x)' newline ...
             'y = x * 2 + sin(x);' newline ...
             'end' newline], 'char');
fclose(fid);
end

% ===========================================================================
function a = listGenerated(workDir)
a = {};
d = dir(fullfile(workDir, '**', '*'));
for k = 1:numel(d)
    if ~d(k).isdir
        rel = strrep(fullfile(d(k).folder, d(k).name), workDir, '');
        a{end+1} = strrep(rel, '\', '/'); %#ok<AGROW>
    end
end
if numel(a) > 25, a = a(1:25); end
end
