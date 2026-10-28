function S = p56_coder_channel_probe(outDir, channel)
%P56_CODER_CHANNEL_PROBE  Run one MATLAB Coder build through one call channel.
%
%   S = p56_coder_channel_probe(outputDirectory, 'B')
%
% Phase 5.5 established that codegen fails over the MCP dynamic-evaluation
% channel and passes in a real process, but it tested only one shape: an entry
% function defined inside the evaluation frame. That cannot separate two different
% explanations -- "the MCP channel breaks Coder" and "Coder cannot resolve an
% entry that has no file". This probe varies ONE thing at a time:
%
%   A  batch process  + entry is a standalone .m on the path
%   B  MCP eval       + entry is a standalone .m on the path     <- decisive
%   D  MCP run_matlab_file + standalone entry                     <- 5.5 untested
%   E  batch process  + entry is a local function of a script    <- 5.5 untested
%
% For every channel the same facts are recorded: release and license, whether the
% entry resolves and to what, the working directory the build ran in, the exact
% error identifier and message, the first frames of the catch stack, and which
% artifacts exist afterwards. Nothing here draws a conclusion about MathWorks
% internals; it only fixes which variable flips the outcome.
%
% Side rules honoured: the global path is not modified (addpath is limited to this
% probe's own directory and is removed again), no restoredefaultpath is called, and
% every build writes under outDir only.

if nargin < 1, outDir = fileparts(mfilename('fullpath')); end
if nargin < 2, channel = 'A'; end
entryName = 'p56coder_entry';
t0 = tic;

S = struct();
S.channel = char(channel);
S.at = datestr(now, 31);
S.release = version;
S.matlabroot = matlabroot;
% The channel argument is a label written by whoever launched this probe; the raw
% frames below are what was actually on the stack, so the label can be checked.
fs = dbstack('-completenames');
S.callFrames = cell(1, min(6, numel(fs)));
for q = 1:numel(S.callFrames)
    S.callFrames{q} = sprintf('%s:%d in %s', strrep(fs(q).file, '\', '/'), fs(q).line, fs(q).name);
end
S.coderLicenseTest = -1;
try %#ok<TRYNC>
    S.coderLicenseTest = double(license('test', 'Matlab_Coder'));
end
S.codegenExists = ~isempty(which('codegen'));
S.toolboxes = toolboxNamesContaining({'Coder'});

S.workDir = fullfile(outDir, ['ch' S.channel]);
if ~isfolder(S.workDir), mkdir(S.workDir); end
srcDir = fullfile(outDir, 'src');
if ~isfolder(srcDir), mkdir(srcDir); end
% the standalone entry lives in its own directory, added only for this call
writeEntry(entryName, srcDir);
addpath(srcDir);
old = pwd;
cd(S.workDir);

S.entryResolvedBy = '';
try %#ok<TRYNC>
    S.entryResolvedBy = strrep(which(entryName), filesep, '/');
end
S.buildCmd = sprintf('codegen %s -args {0.5}', entryName);
S.ok = false; S.errorIdentifier = ''; S.errorMessage = ''; S.stack = {};
try
    codegen(entryName, '-args', {0.5});
    S.ok = true;
catch ME
    S.errorIdentifier = char(ME.identifier);
    S.errorMessage = strtrim(char(ME.message));
    for q = 1:numel(ME.stack)
        S.stack{end+1} = sprintf('%s:%d in %s', strrep(ME.stack(q).file, '\', '/'), ...
            ME.stack(q).line, ME.stack(q).name); %#ok<AGROW>
    end
    S.stack = S.stack(1:min(6, numel(S.stack)));
end

% artifacts, judged by what is on disk, not by what the call returned
S.artifacts = listGenerated(S.workDir);
S.generatedDirExists = isfolder(fullfile(S.workDir, 'codegen'));
cd(old);
rmpath(srcDir);
S.elapsedSeconds = round(toc(t0), 2);
S.pathAfter = numel(strsplit(path, pathsep));

S.claim = ['this row records one channel with one entry shape; it says nothing about ' ...
    'why the difference exists inside MATLAB Coder'];

fid = fopen(fullfile(outDir, ['channel_' S.channel '.json']), 'w');
if fid >= 0
    fwrite(fid, jsonencode(S), 'char'); fclose(fid);
end
end

% ===========================================================================
function writeEntry(name, dir_)
p = fullfile(dir_, [name '.m']);
fid = fopen(p, 'w');
if fid < 0, error('p56coder_channel_probe:write', 'cannot write %s', p); end
fwrite(fid, sprintf(['function y = %s(x)\n%%#codegen trivial fixed-point-free entry\n' ...
    'y = x * 2 + sin(x);\nend\n'], name), 'char');
fclose(fid);
end

% ===========================================================================
function a = listGenerated(workDir)
a = {};
d = dir(fullfile(workDir, '**', '*'));
for k = 1:numel(d)
    if ~d(k).isdir
        a{end+1} = strrep(strrep(fullfile(d(k).folder, d(k).name), workDir, ''), '\', '/'); %#ok<AGROW>
    end
end
a = sortRows(a);
if numel(a) > 25, a = a(1:25); end
end

% ===========================================================================
function t = toolboxNamesContaining(needles)
% licensedmatrix is not on the path in this release, so the installed-product list
% from ver() is used instead.
t = {};
V = ver();
for k = 1:numel(V)
    nm = lower(strtrim(char(V(k).Name)));
    for q = 1:numel(needles)
        if ~isempty(strfind(nm, lower(needles{q})))
            t{end+1} = sprintf('%s (%s)', V(k).Name, V(k).Version); %#ok<AGROW>
        end
    end
end
t = unique(t);
end

% ===========================================================================
function s = sortRows(c)
if isempty(c), s = c; return; end
strs = string(c);
[~, o] = sort(strs);
s = c(o);
end
