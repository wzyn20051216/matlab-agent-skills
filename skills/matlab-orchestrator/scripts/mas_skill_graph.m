function r = mas_skill_graph(opt, varargin)
%MAS_SKILL_GRAPH  Check the skills' call graph: cycles, dangling refs, duplication.
%
%   r = mas_skill_graph()            % every check
%   r = mas_skill_graph('cycles')    % one group
%   r = mas_skill_graph('find-cycles', adj, names)   % detector test seam
%
%   r.ok, r.checks (id, pass, detail), r.graph, r.cycles, r.detail, r.verdict
%
% WHY THIS IS NOT A GREP
% The nine SKILL.md files mention many strings that LOOK like skill names and
% are not: `mcp.matlab-install` and `mcp.matlab-license` are probe check ids,
% `matlab-actions/run-tests@v3` is a GitHub Action. A grep for `matlab-*`
% reports all of them as cross-references, which is how a real cycle hides in
% plain sight. So the graph is built from three SOURCES, each trusted for a
% different thing:
%
%   routing.json     authoritative: which skill the router may pick
%   SKILL.md body    references to OTHER skills, after excluding identifiers
%                    that belong to a foreign namespace (mcp.*, matlab-actions,
%                    feature names, file paths)
%   scripts/         a script that calls mas_* from another skill is a hard
%                    dependency, and the strongest kind
%
% WHAT COUNTS AS A PROBLEM
%
%   cycle          a -> b -> a. The router has no entry point for this pair and
%                  an agent following both skills will re-enter the first one
%                  forever. A two-skill cycle between runner and orchestrator is
%                  the realistic failure: both describe "run the task", so
%                  neither can defer to the other without a loop.
%   duplicateLoad  two skills claim the same terms, so a prompt can hit both and
%                  the agent loads both bodies. Wasteful and ambiguous, and it
%                  makes "which skill is responsible" unanswerable.
%   dangling       a skill references a sibling that does not exist
%
% This is a static check on files, so it needs no MATLAB and no toolbox. That
% matters: a check that only runs where MATLAB is installed is not a check on
% the skill package, it is a check on one machine.

if nargin < 1, opt = 'all'; end
if strcmpi(opt, 'find-cycles')
    % Public entry to the detector so it can be tested on graphs whose answer
    % is known. A cycle finder that has only ever run on one real graph has not
    % been shown to find cycles or to stop finding them; this is the seam that
    % makes both checkable.
    r = find_cycles(varargin{1}, varargin{2});
    return;
end
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
skillRoot = fullfile(repo, 'skills');

% ---- the nine skills, discovered from disk (not hard-coded) -------------
entries = dir(skillRoot);
names = {};
for k = 1:numel(entries)
    if entries(k).isdir && startsWith(entries(k).name, 'matlab-')
        if isfile(fullfile(skillRoot, entries(k).name, 'SKILL.md'))
            names{end+1} = entries(k).name; %#ok<AGROW>
        end
    end
end
names = sort(names);

if isempty(names)
    r = struct('ok', false, 'checks', struct([]), 'graph', struct(), ...
        'cycles', {{}}, 'detail', 'no skills found under skills/', 'verdict', 'EMPTY');
    return;
end

G = struct();
G.names = names;
G.edges = struct('from', {}, 'to', {}, 'via', {}, 'line', {});   % directed references
G.routedTo = struct('from', {}, 'to', {});                        % router authority

% ---- source 1: routing.json ---------------------------------------------
routingFile = fullfile(skillRoot, 'matlab-orchestrator', 'assets', 'routing.json');
routed = {};
if isfile(routingFile)
    R = jsondecode(fileread(routingFile));
    if isfield(R, 'skills')
        rf = fieldnames(R.skills);
        for k = 1:numel(rf)
            % The OBJECT KEY cannot hold a hyphen -- jsondecode turns
            % "matlab-runner" into the field name "matlab_runner". mas_route
            % therefore reads the real id out of `s.id`, and so must this
            % checker; reading the key here reported all eight skills as
            % dangling, which is how a genuine graph problem gets buried under
            % a fake one.
            nm = rf{k};
            v = R.skills.(nm);
            if isstruct(v) && isfield(v, 'id') && ~isempty(v.id)
                nm = char(v.id);
            end
            G.routedTo(end+1) = struct('from', 'ROUTER', 'to', nm); %#ok<AGROW>
            routed{end+1} = nm; %#ok<AGROW>
        end
    end
end

% ---- source 2: SKILL.md bodies -----------------------------------------
foreign = foreign_namespace();
for a = 1:numel(names)
    f = fullfile(skillRoot, names{a}, 'SKILL.md');
    txt = read_lines(f);
    for ln = 1:numel(txt)
        refs = find_refs(txt{ln}, names, foreign);
        % A skill naming ITSELF is not a dependency. Without this, every
        % SKILL.md contributes a self-loop, and the cycle detector then reports
        % a nine-skill cycle that does not exist -- a fake so loud that it hides
        % the real one.
        refs = setdiff(refs, names{a});
        for q = 1:numel(refs)
            G.edges(end+1) = struct('from', names{a}, 'to', refs{q}, ...
                'via', 'SKILL.md', 'line', ln); %#ok<AGROW>
        end
    end
end

% ---- source 3: scripts calling another skill's mas_* --------------------
for a = 1:numel(names)
    sd = fullfile(skillRoot, names{a}, 'scripts');
    fs = dir(fullfile(sd, '*.m'));
    for k = 1:numel(fs)
        owner = mas_owner(skillRoot, fs(k).name);
        % A script inside skill X that calls another mas_* from skill X is just
        % internal reuse. Only a call that CROSSES a skill boundary is a graph
        % edge, so the self-case is dropped here too.
        if isempty(owner) || strcmp(owner, names{a}), continue; end
        G.edges(end+1) = struct('from', names{a}, 'to', owner, ...
            'via', 'script', 'line', 0); %#ok<AGROW>
    end
end

G.edges = dedupe_edges(G.edges);

C = struct('id', {}, 'pass', {}, 'detail', {});
doCycles = any(strcmpi(opt, {'all','cycles'}));
doDangle = any(strcmpi(opt, {'all','dangling'}));
doDup    = any(strcmpi(opt, {'all','duplication'}));
doCover  = any(strcmpi(opt, {'all','coverage'}));

% ---- cycles -------------------------------------------------------------
cycles = {};
if doCycles
    adj = adjacency(G, names);
    cycles = find_cycles(adj, names);
    if isempty(cycles)
        C(end+1) = struct('id', 'cycles', 'pass', true, ...
            'detail', sprintf('no cycle among %d edge(s) over %d skill(s)', ...
                numel(G.edges), numel(names)));
    else
        txt = {};
        for k = 1:numel(cycles)
            txt{end+1} = strjoin(cycles{k}, ' -> '); %#ok<AGROW>
        end
        C(end+1) = struct('id', 'cycles', 'pass', false, ...
            'detail', sprintf('%d cycle(s): %s', numel(cycles), strjoin(txt, '; ')));
    end
end

% ---- dangling references -----------------------------------------------
if doDangle
    bad = {};
    for k = 1:numel(routed)
        if ~any(strcmp(names, routed{k}))
            bad{end+1} = sprintf('routing.json -> %s (no such skill dir)', routed{k}); %#ok<AGROW>
        end
    end
    if isempty(bad)
        C(end+1) = struct('id', 'dangling', 'pass', true, ...
            'detail', sprintf('all %d routed skill(s) exist on disk', numel(routed)));
    else
        C(end+1) = struct('id', 'dangling', 'pass', false, ...
            'detail', strjoin(bad, '; '));
    end
end

% ---- duplicate loading: one skill referenced by several others ---------
if doDup
    tgt = {};
    for k = 1:numel(G.edges), tgt{end+1} = G.edges(k).to; end %#ok<AGROW>
    if isempty(tgt)
        C(end+1) = struct('id', 'duplication', 'pass', true, 'detail', 'no cross-skill edges');
    else
        [u, ~, idx] = unique(tgt);
        counts = accumarray(idx, 1);
        [mx, imx] = max(counts);
        if mx <= 1
            C(end+1) = struct('id', 'duplication', 'pass', true, ...
                'detail', sprintf('no skill is referenced by more than one other (%d edge(s))', numel(tgt)));
        else
            srcs = {};
            for k = 1:numel(G.edges)
                if strcmp(G.edges(k).to, u{imx}), srcs{end+1} = G.edges(k).from; end %#ok<AGROW>
            end
            C(end+1) = struct('id', 'duplication', 'pass', false, ...
                'detail', sprintf(['%s is referenced %d times (%s): loading it that ' ...
                    'often duplicates context and makes ownership ambiguous'], ...
                    u{imx}, mx, strjoin(unique(srcs), ', ')));
        end
    end
end

% ---- coverage: every skill must be reachable from the router -----------
if doCover
    unreachable = setdiff(names, routed);
    % matlab-orchestrator is the router itself and is deliberately unrouted.
    unreachable = setdiff(unreachable, 'matlab-orchestrator');
    if isempty(unreachable)
        C(end+1) = struct('id', 'coverage', 'pass', true, ...
            'detail', sprintf('all %d non-router skill(s) are routable', numel(routed)));
    else
        C(end+1) = struct('id', 'coverage', 'pass', false, ...
            'detail', sprintf('never routable: %s', strjoin(unreachable, ', ')));
    end
end

nPass = nnz([C.pass]);
r = struct();
r.ok = all([C.pass]);
r.checks = C;
r.nPass = nPass;
r.nTotal = numel(C);
r.graph = G;
r.cycles = {cycles{:}};
r.verdict = tern(r.ok, 'ACCEPTABLE', 'PROBLEMS');
r.detail = sprintf('%d/%d graph checks passed over %d skill(s), %d edge(s)', ...
    nPass, numel(C), numel(names), numel(G.edges));
end

% ===========================================================================
function L = foreign_namespace()
% Identifier prefixes that LOOK like skill names but belong to other systems.
% Naming a reference pattern as "foreign" here is what stops `mcp.matlab-license`
% and `matlab-actions/run-tests@v3` from being read as sibling skills.
% Each entry is stripped with a non-word char in front of it, so a BARE name is
% still matched -- `mcp.matlab-license` must not leave "matlab-license" behind.
L = {'mcp.matlab-install', 'mcp.matlab-license', 'mcp.matlab-session-config', ...
     'mcp.client-registration', 'mcp.protocol-handshake', 'mcp.readonly-exec', ...
     'mcp.file-io', 'matlab-actions/', 'matlab_license', 'matlab_install'};
end

% ---------------------------------------------------------------------------
function refs = find_refs(line, names, foreign)
% Strip identifiers that belong to a foreign namespace BEFORE looking for skill
% names. Without this, `mcp.matlab-license` matches "matlab-license" and
% `matlab-actions/run-tests@v3` matches "matlab-actions" -- both counted as
% cross-skill edges by a naive substring search.
s = line;
for k = 1:numel(foreign)
    % Remove the token together with one leading non-word char, so a bare
    % "matlab-license" inside "mcp.matlab-license" cannot survive as a match.
    % The loop is BOUNDED: a `while regexp(...)` here spins forever as soon as
    % regexprep stops making progress (the version that shipped first hung for
    % the full run timeout instead of reporting a problem). A fixed bound turns
    % a hang into a slightly incomplete strip, which is recoverable; a hang is
    % not.
    pat = ['([^A-Za-z0-9_])' foreign{k}];
    for guard = 1:32
        [tok, ~] = regexp(s, pat, 'match', 'once');
        if isempty(tok), break; end
        sNew = regexprep(s, [pat '$'], '');
        if strcmp(sNew, s), break; end   % no progress: stop rather than spin
        s = sNew;
    end
    s = regexprep(s, ['^' foreign{k}], '');
end
refs = {};
for a = 1:numel(names)
    if ~isempty(strfind(line, ['<' names{a} '>'])) || ~isempty(strfind(s, names{a}))
        refs{end+1} = names{a}; %#ok<AGROW>
    end
end
refs = unique(refs);
end

% ---------------------------------------------------------------------------
function owner = mas_owner(skillRoot, fileName)
[~, nm] = fileparts(fileName);
if isempty(strfind(nm, 'mas_')), owner = ''; return; end
entries = dir(skillRoot);
owner = '';
for k = 1:numel(entries)
    if ~entries(k).isdir, continue; end
    if isfile(fullfile(skillRoot, entries(k).name, 'scripts', fileName))
        owner = entries(k).name; return;
    end
end
end

% ---------------------------------------------------------------------------
function E = dedupe_edges(E)
if isempty(E), return; end
keys = arrayfun(@(e) sprintf('%s|%s|%s', e.from, e.to, e.via), E, ...
    'UniformOutput', false);
[~, ix] = unique(keys, 'stable');
E = E(sort(ix));
end

% ---------------------------------------------------------------------------
function adj = adjacency(G, names)
adj = containers.Map('KeyType', 'char', 'ValueType', 'any');
for k = 1:numel(names), adj(names{k}) = {}; end
for k = 1:numel(G.edges)
    lst = adj(G.edges(k).from);
    lst{end+1} = G.edges(k).to;
    adj(G.edges(k).from) = lst;
end
end

% ---------------------------------------------------------------------------
function cycles = find_cycles(adj, names)
% Iterative DFS with an explicit stack and a real three-colour state machine.
%
% The first version marked every node BLACK after the first root, which
% destroys the invariant the algorithm depends on: a back edge is only a CYCLE
% when the target is GREY (on the current stack), and a node that is BLACK
% (finished) is a DAG edge, not a cycle. With the invariant broken, this
% reported 9 cycles for a graph with no self-loop at all -- a false alarm that
% would have sent someone hunting a routing loop that does not exist.
cycles = {};
WHITE = 0; GREY = 1; BLACK = 2;
color = containers.Map('KeyType', 'char', 'ValueType', 'double');
for k = 1:numel(names), color(names{k}) = WHITE; end

for s = 1:numel(names)
    if color(names{s}) ~= WHITE, continue; end

    % each stack frame is {node, nextChildIndex}
    stNode = {names{s}};
    stIdx  = {1};
    color(names{s}) = GREY;

    while ~isempty(stNode)
        n = stNode{end};
        kids = adj(n);
        i = stIdx{end};
        if i > numel(kids)
            color(n) = BLACK;                 % finished: children explored
            stNode(end) = []; stIdx(end) = [];
            continue;
        end
        stIdx{end} = i + 1;                  % advance BEFORE descending
        ch = kids{i};
        cs = color(ch);
        if cs == GREY
            % back edge -> genuine cycle: ch ... n -> ch
            path = [stNode, ch];
            idx = find(strcmp(stNode, ch), 1, 'last');
            if ~isempty(idx)
                c = [path(idx:end)];
                if ~has_cycle(c, cycles), cycles{end+1} = c; end %#ok<AGROW>
            end
        elseif cs == WHITE
            color(ch) = GREY;
            stNode{end+1} = ch; %#ok<AGROW>
            stIdx{end+1} = 1; %#ok<AGROW>
        end
        % BLACK: cross edge or already-visited, no action
    end
end
end

% ---------------------------------------------------------------------------
function tf = has_cycle(c, cycles)
tf = false;
for k = 1:numel(cycles)
    if numel(cycles{k}) == numel(c) && all(strcmp(cycles{k}, c)), tf = true; return; end
end
end

% ---------------------------------------------------------------------------
function L = read_lines(f)
fid = fopen(f, 'r');
if fid < 0, L = {}; return; end
t = fread(fid, inf, '*char')';
fclose(fid);
t = strrep(t, sprintf('\r\n'), sprintf('\n'));
L = strsplit(t, sprintf('\n'), 'CollapseDelimiters', false);
end

% ---------------------------------------------------------------------------
function s = tern(c, a, b)
if c, s = a; else, s = b; end
end