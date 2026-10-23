function E = p58_trace_evidence(taskDir, repoRoot)
%P58_TRACE_EVIDENCE  Rebuild client stage evidence from its own event stream.
%
%   E = p58_trace_evidence(taskDir)
%   E = p58_trace_evidence(taskDir, repoRoot)
%
% taskDir holds the native events.jsonl written by `codex exec --json` plus the
% probe's verification.json. Only items of type command_execution and
% mcp_tool_call are inspected:
%   skillSelected     a command read a SKILL.md from the isolated project copy
%   referencesLoaded  a command read a non-SKILL.md file from the same copy
%   mcpExecuted       an mcp_tool_call reached status completed
%   checksRun         a completed check_matlab_code call
%   repaired          a failed mcp_tool_call was followed by a completed one
%
% repoRoot, when given, additionally counts reads that go outside the installed
% Skill directory and into the source repository -- the fingerprint of a Skill
% whose instructions assume they run from a clone.
%
% Every path mention is classified against the skill root the probe installed
% and the project cwd the client was launched with, so a read of a user-level
% Skills root is reported as userRootSkillReads instead of being counted as
% proof that the installed copy was used.
%
% toolCalls counts distinct call ids, so the started/completed pairs the client
% emits for one call are not double-counted. Only the command string is
% scanned for path mentions: a path that merely appears in captured output is
% not evidence that the client read it.

if nargin < 2, repoRoot = ''; end
if ~ischar(taskDir), taskDir = char(taskDir); end
taskDir = char(java.io.File(taskDir).getCanonicalPath());
evFile = fullfile(taskDir, 'events.jsonl');
if ~isfile(evFile)
    error('p58_trace_evidence:input', 'no events.jsonl under %s', taskDir);
end

[skillRoot, cwd] = probe_context(fullfile(taskDir, 'verification.json'));

E = struct('skillSelected', false, 'referencesLoaded', false, 'mcpExecuted', false, ...
    'checksRun', false, 'repaired', false, 'toolCalls', 0, ...
    'skillPaths', {{}}, 'referencePaths', {{}}, 'mcpTools', {{}}, ...
    'mcpFailures', 0, 'mcpCompleted', 0, 'commandCalls', 0, 'projectScoped', false, ...
    'userRootSkillReads', 0, 'otherSkillReads', 0, 'pathClasses', {{}}, ...
    'repoSourceReads', {{}}, ...
    'skillRoot', skillRoot, 'cwd', cwd, 'eventCount', 0);

events = read_events(evFile);
E.eventCount = numel(events);
seenIds = containers.Map('KeyType', 'char', 'ValueType', 'logical');
for k = 1:numel(events)
    it = events(k).item;
    if ~isstruct(it) || ~isfield(it, 'type'), continue; end
    switch char(it.type)
        case 'command_execution'
            E.commandCalls = E.commandCalls + 1;
            cmd = char(getf_or(it, 'command', ''));
            hits = regexp(cmd, '[^"''\s;|]*\.agents[/\\]+skills[/\\]+[A-Za-z0-9._/\\-]+', 'match');
            for q = 1:numel(hits)
                % The client records its commands with escaped path separators,
                % so a Windows path can arrive with every separator doubled
                % (.agents\\skills\\...). Collapse them so
                % classification compares like-for-like with the installed root.
                raw = strrep(char(hits{q}), '\', '/');
                raw = regexprep(raw, '/{2,}', '/');
                cls = classify(raw, skillRoot, cwd);
                E.pathClasses{end+1} = {raw, cls}; %#ok<AGROW>
                isSkill = contains(lower(raw), 'skill.md');
                if isSkill && ~strcmp(cls, 'projectCopy')
                    % A user-level root read is a finding about precedence, not
                    % evidence that the installed copy was loaded.
                    if strcmp(cls, 'userRoot'), E.userRootSkillReads = E.userRootSkillReads + 1;
                    else, E.otherSkillReads = E.otherSkillReads + 1;
                    end
                end
                if ~strcmp(cls, 'projectCopy'), continue; end
                if isSkill
                    E.skillSelected = true;
                    E.skillPaths{end+1} = raw; %#ok<AGROW>
                else
                    E.referencesLoaded = true;
                    E.referencePaths{end+1} = raw; %#ok<AGROW>
                end
            end
            if ~isempty(repoRoot)
                rr = regexprep(strrep(char(repoRoot), '\', '/'), '/{2,}', '/');
                pat = sprintf('%s/[^"''\\s;|]*', regexptranslate('escape', rr));
                rh = regexp(cmd, pat, 'match');
                for q = 1:numel(rh)
                    h = regexprep(strrep(char(rh{q}), '\', '/'), '/{2,}', '/');
                    if contains(lower(h), '/.agents/skills'), continue; end
                    if ~any(strcmp(h, E.repoSourceReads))
                        E.repoSourceReads{end+1} = h; %#ok<AGROW>
                    end
                end
            end
        case 'mcp_tool_call'
            id = char(getf_or(it, 'id', sprintf('ev%d', k)));
            tool = char(getf_or(it, 'tool', ''));
            status = char(getf_or(it, 'status', ''));
            if ~isKey(seenIds, id)
                E.toolCalls = E.toolCalls + 1;
                E.mcpTools{end+1} = tool; %#ok<AGROW>
                seenIds(id) = true;
            end
            if strcmp(status, 'completed')
                E.mcpCompleted = E.mcpCompleted + 1;
                if strcmp(tool, 'check_matlab_code')
                    E.checksRun = true;
                end
                E.mcpExecuted = true;
                if E.mcpFailures > 0
                    E.repaired = true;
                end
            elseif strcmp(status, 'failed')
                E.mcpFailures = E.mcpFailures + 1;
            end
    end
end
E.skillPaths = unique(E.skillPaths);
E.referencePaths = unique(E.referencePaths);
E.projectScoped = ~isempty(E.skillPaths) && E.userRootSkillReads == 0 && ...
    E.otherSkillReads == 0;
end

% ===========================================================================
function [skillRoot, cwd] = probe_context(verFile)
skillRoot = ''; cwd = '';
if ~isfile(verFile), return; end
try
    V = jsondecode(fileread(verFile));
catch
    return
end
skillRoot = normsep(getf_or(V, 'skillRoot', getf_or(getf_or(V, 'sync', struct()), ...
    'skillRoot', '')));
cmdl = getf_or(V, 'command', {});
if iscell(cmdl)
    idx = find(strcmp(cmdl, '-C'));
    if ~isempty(idx), cwd = normsep(cmdl{idx(1) + 1}); end
end
end

function s = normsep(x)
s = regexprep(strrep(char(x), '\', '/'), '/{2,}', '/');
end

function cls = classify(path, skillRoot, cwd)
%CLASSIFY  projectCopy | userRoot | other for a mentioned Skills path.
p = path;
if ~hasDrive(p)
    if isempty(cwd), cls = 'other'; return; end
    p = [cwd '/' p];
end
p = lower(strrep(p, '\', '/'));
if ~isempty(skillRoot) && startsWith(p, lower(skillRoot))
    cls = 'projectCopy';
elseif ~isempty(regexp(p, '/users/[^/]+/(\.agents|\.codex|\.qoder-cn|\.workbuddy)/skills', 'once'))
    cls = 'userRoot';
else
    cls = 'other';
end
end

function tf = hasDrive(p)
tf = ~isempty(regexp(p, '^[A-Za-z]:/', 'once'));
end

function events = read_events(path)
raw = fileread(path);
lines = strsplit(raw, newline);
events = struct('item', {});
for k = 1:numel(lines)
    line = strtrim(lines{k});
    if isempty(line), continue; end
    try
        e = jsondecode(line);
        if isfield(e, 'item') && isstruct(e.item)
            events(end+1).item = e.item; %#ok<AGROW>
        end
    catch
        % A truncated final line is not a defect in the episode; the stream is
        % still the client's own record and is kept byte-for-byte on disk.
    end
end
end

function v = getf_or(s, name, dflt)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name)), v = s.(name); else, v = dflt; end
end
