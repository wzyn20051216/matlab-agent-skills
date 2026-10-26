function r = mas_route(prompt, opts)
%MAS_ROUTE  Pick the MATLAB skills a natural-language request needs.
%
%   r = mas_route("分析 OFDM 通信系统的误码率")
%   r = mas_route(prompt, struct('minScore',3,'multiSkillRatio',0.6))
%
% OUTPUT CONTRACT (schema 1.1)
%   r.schemaVersion   '1.1'
%   r.decision        ROUTE | CLARIFY | AMBIGUOUS | BLOCKED
%   r.primary         primary skill id, '' unless ROUTE
%   r.secondary       score-based secondary ids (not dependencies)
%   r.loadOrder       dependency-first order; {} when BLOCKED
%   r.alwaysLoaded    skills that are always loaded (normally matlab-runner)
%   r.ranked          scored domains, highest first
%   r.matched         struct array: skill, term, weight
%   r.missing         struct array: kind, name, detail, hard
%   r.available       struct array: id, installed, loadable, problem
%   r.nextAction      load | ask | stop
%   r.reason          human-readable explanation
%
% DECISIONS
%   * score < minScore -> CLARIFY; ask, do not guess.
%   * top two tie      -> AMBIGUOUS; ask which one carries the core work.
%   * a selected skill is uninstalled/damaged, a hard toolbox is unlicensed,
%     a declared dependency is absent, or dependencies form a cycle
%                      -> BLOCKED; stop and report what must be fixed.
%   * otherwise        -> ROUTE.
%
% WHY THE ADDITIONS
% Phase 5.1 C9-10 recorded that the output had no documented contract and a
% consumer mis-bound 12/12 results. Two more defects were structural: the
% matcher loaded a skill with no check that it exists or that its toolbox is
% licensed, and it ignored dependencies. The old fields are unchanged; the new
% ones are additive, so existing callers that read decision/primary/loadOrder
% keep working.
%
% NEGATION
% A term preceded by a negator ("不用 Simulink", "without PID") does not score.
% This is a lexical guard, not natural-language understanding; it prevents the
% most common misleading keyword, not every possible one.
%
% TEST SEAMS (for tests only)
%   opts.table           routing table struct instead of routing.json
%   opts.skillStatus     N-by-2 cell: {skillId, 'ok'|'missing'|'damaged'}
%   opts.toolboxStatus   N-by-2 cell: {displayName, logical}
%   opts.skillsRoot      root that contains the skill directories

if nargin < 2, opts = struct(); end
here = fileparts(mfilename('fullpath'));
skillsRoot = fileparts(fileparts(here));
if isfield(opts, 'skillsRoot'), skillsRoot = opts.skillsRoot; end

if isfield(opts, 'table')
    T = opts.table;
    tableSource = 'opts.table';
else
    tblFile = fullfile(fileparts(here), 'assets', 'routing.json');
    if ~isfile(tblFile)
        error('mas_route:noTable', 'routing table not found: %s', tblFile);
    end
    T = jsondecode(fileread(tblFile));
    tableSource = tblFile;
end
if isfield(opts, 'minScore'), T.minScore = opts.minScore; end
if isfield(opts, 'multiSkillRatio'), T.multiSkillRatio = opts.multiSkillRatio; end

p = lower(char(prompt));
keys = fieldnames(T.skills);
n = numel(keys);
ids = cell(n,1);
meta = cell(n,1);
score = zeros(n,1);
hits = cell(n,1);
weights = cell(n,1);
always = false(n,1);

for k = 1:n
    s = T.skills.(keys{k});
    if isfield(s, 'id'), ids{k} = char(s.id); else, ids{k} = strrep(keys{k}, '_', '-'); end
    if isfield(s, 'always'), always(k) = logical(s.always); end
    meta{k} = s;
    terms = get_terms(s);
    for q = 1:numel(terms)
        tq = terms{q}{1};
        wq = terms{q}{2};
        pos = term_positions(p, tq);
        keep = false;
        for t = 1:numel(pos)
            if ~negated_before(p, pos(t))
                keep = true;
                break;
            end
        end
        if keep
            score(k) = score(k) + wq;
            hits{k}{end+1} = tq; %#ok<AGROW>
            weights{k}(end+1) = wq; %#ok<AGROW>
        end
    end
end

% ---- matched terms, ranked domains ---------------------------------------
matched = struct('skill', {}, 'term', {}, 'weight', {});
for k = 1:n
    for q = 1:numel(hits{k})
        matched(end+1) = struct('skill', ids{k}, 'term', hits{k}{q}, ...
            'weight', weights{k}(q)); %#ok<AGROW>
    end
end

pri = zeros(n,1);
for k = 1:n
    if isfield(meta{k}, 'priority'), pri(k) = double(meta{k}.priority); end
end
dom = find(~always);
[~, ord] = sortrows([-score(dom), pri(dom), (1:numel(dom)).']);
dom = dom(ord);
ranked = repmat(struct('id', '', 'score', 0, 'hits', {{}}, 'priority', 0), numel(dom), 1);
for k = 1:numel(dom)
    ranked(k).id = ids{dom(k)};
    ranked(k).score = score(dom(k));
    ranked(k).hits = hits{dom(k)};
    ranked(k).priority = pri(dom(k));
end

top = 0; second = 0;
if ~isempty(ranked)
    top = ranked(1).score;
    if numel(ranked) > 1, second = ranked(2).score; end
end

alwaysIds = unique_keep(ids(always).');
metaById = containers.Map('KeyType', 'char', 'ValueType', 'any');
for k = 1:n, metaById(ids{k}) = meta{k}; end

r = base_output(char(prompt), ranked, matched, alwaysIds, tableSource);
r.tableVersion = ternary(isfield(T, 'version'), char(T.version), '');

% ---- CLARIFY / AMBIGUOUS -------------------------------------------------
if top < T.minScore
    r.decision = 'CLARIFY';
    r.nextAction = 'ask';
    if isempty(ranked)
        r.reason = sprintf('no term matched any domain (need >= %g)', T.minScore);
    else
        r.reason = sprintf(['best domain %s scored %g, below the %g threshold; ' ...
            'ask one clarifying question instead of guessing'], ...
            ranked(1).id, top, T.minScore);
    end
    r = with_always(r, alwaysIds, metaById, skillsRoot, opts);
    return;
end

if second >= top
    r.decision = 'AMBIGUOUS';
    r.nextAction = 'ask';
    r.reason = sprintf(['%s and %s both scored %g; the request does not say ' ...
        'which carries the core work'], ranked(1).id, ranked(2).id, top);
    r = with_always(r, alwaysIds, metaById, skillsRoot, opts);
    return;
end

% ---- ROUTE assembly ------------------------------------------------------
r.decision = 'ROUTE';
r.primary = ranked(1).id;
sec = {};
for k = 2:numel(ranked)
    if ranked(k).score >= T.multiSkillRatio * top
        sec{end+1} = ranked(k).id; %#ok<AGROW>
    end
end
sec = unique_keep(sec);
r.secondary = sec;

selected = [alwaysIds, {r.primary}, sec];
if (any(strcmp(sec, 'matlab-testing-ci')) || contains(p, '验收') || contains(p, '回归')) ...
        && ~any(strcmp(selected, 'matlab-testing-ci'))
    selected{end+1} = 'matlab-testing-ci';
end
selected = unique_keep(selected);

[closure, absentDep] = close_dependencies(selected, metaById);
if ~isempty(absentDep)
    r.decision = 'BLOCKED';
    r.nextAction = 'stop';
    r.primary = '';
    r.secondary = {};
    r.missing = add_missing(r.missing, 'dependency', strjoin(absentDep, ', '), ...
        'declared dependency is not a skill in the routing table', true);
    r.reason = ['blocked: unresolved dependency ' strjoin(absentDep, ', ')];
    [r.available, ~, r.missing] = check_available(closure, metaById, ...
        skillsRoot, opts, r.missing);
    return;
end

[order, cycle] = topo_order(closure, metaById);
if ~isempty(cycle)
    r.decision = 'BLOCKED';
    r.nextAction = 'stop';
    r.primary = '';
    r.secondary = {};
    r.missing = add_missing(r.missing, 'dependency_cycle', strjoin(cycle, ' -> '), ...
        'dependencies form a cycle; no load order exists', true);
    r.reason = ['blocked: dependency cycle ' strjoin(cycle, ' -> ')];
    [r.available, ~, r.missing] = check_available(closure, metaById, ...
        skillsRoot, opts, r.missing);
    return;
end

[r.available, notes, r.missing] = check_available(closure, metaById, ...
    skillsRoot, opts, r.missing);
if ~isempty(r.missing)
    r.decision = 'BLOCKED';
    r.nextAction = 'stop';
    r.primary = '';
    r.secondary = {};
    r.loadOrder = {};
    r.reason = ['blocked: ' describe_missing(r.missing)];
    r.notes = notes;
    return;
end

r.loadOrder = order;
r.nextAction = 'load';
r.reason = sprintf('routed to %s (score %g); %d secondary skill(s), %d dependency-ordered', ...
    r.primary, top, numel(sec), numel(order));
r.notes = notes;
end

% ===========================================================================
function r = base_output(prompt, ranked, matched, alwaysIds, tableSource)
r = struct();
r.schemaVersion = '1.1';
r.decision = '';
r.primary = '';
r.secondary = {};
r.loadOrder = {};
r.alwaysLoaded = alwaysIds;
r.ranked = ranked;
r.matched = matched;
r.missing = struct('kind', {}, 'name', {}, 'detail', {}, 'hard', {});
r.available = struct('id', {}, 'installed', {}, 'loadable', {}, 'problem', {});
r.nextAction = '';
r.reason = '';
r.notes = {};
r.prompt = prompt;
r.tableSource = tableSource;
r.tableVersion = '';
end

function r = with_always(r, alwaysIds, metaById, skillsRoot, opts)
[r.available, notes, miss] = check_available(alwaysIds, metaById, skillsRoot, opts, r.missing);
r.missing = miss;
r.notes = notes;
if ~isempty(miss)
    r.decision = 'BLOCKED';
    r.nextAction = 'stop';
    r.loadOrder = {};
    r.reason = ['blocked: ' describe_missing(miss)];
else
    r.loadOrder = alwaysIds;
end
end

function [closure, absent] = close_dependencies(selected, metaById)
closure = unique_keep(selected);
absent = {};
k = 1;
while k <= numel(closure)
    id = closure{k};
    deps = {};
    if isKey(metaById, id)
        deps = get_deps(metaById(id));
    end
    for q = 1:numel(deps)
        d = deps{q};
        if ~isKey(metaById, d)
            if ~any(strcmp(absent, d)), absent{end+1} = d; end %#ok<AGROW>
        elseif ~any(strcmp(closure, d))
            closure{end+1} = d; %#ok<AGROW>
        end
    end
    k = k + 1;
end
end

function [order, cyc] = topo_order(closure, metaById)
state = containers.Map('KeyType', 'char', 'ValueType', 'double');
for k = 1:numel(closure), state(closure{k}) = 0; end
order = {}; cyc = {};
for k = 1:numel(closure)
    if state(closure{k}) == 0
        [order, cyc] = visit(closure{k}, metaById, state, order, {});
        if ~isempty(cyc), return; end
    end
end
end

function [order, cyc] = visit(id, metaById, state, order, stack)
cyc = {};
if state(id) == 1
    at = find(strcmp(stack, id), 1);
    cyc = [stack(at:end), {id}];
    return;
end
if state(id) == 2, return; end
state(id) = 1;
stack{end+1} = id;
deps = get_deps(metaById(id));
for k = 1:numel(deps)
    d = deps{k};
    if ~isKey(metaById, d), continue; end
    if state(d) ~= 2
        [order, cyc] = visit(d, metaById, state, order, stack);
        if ~isempty(cyc), return; end
    end
end
state(id) = 2;
order{end+1} = id;
end

function [avail, notes, missing] = check_available(ids, metaById, skillsRoot, opts, missing)
avail = struct('id', {}, 'installed', {}, 'loadable', {}, 'problem', {});
notes = {};
for k = 1:numel(ids)
    id = ids{k};
    st = skill_state(id, skillsRoot, get_opt(opts, 'skillStatus'));
    installed = ~strcmp(st, 'missing');
    loadable = strcmp(st, 'ok');
    problem = '';
    if strcmp(st, 'missing')
        problem = 'skill directory not found';
        missing = add_missing(missing, 'skill', id, problem, true);
    elseif strcmp(st, 'damaged')
        problem = 'SKILL.md missing or empty';
        missing = add_missing(missing, 'content', id, problem, true);
    end
    avail(end+1) = struct('id', id, 'installed', installed, ...
        'loadable', loadable, 'problem', problem); %#ok<AGROW>
    if ~isKey(metaById, id), continue; end
    reqs = get_reqs(metaById(id));
    for q = 1:numel(reqs)
        req = reqs(q);
        typ = ternary(isfield(req, 'type'), char(req.type), 'toolbox');
        nm = ternary(isfield(req, 'name'), char(req.name), '');
        ft = ternary(isfield(req, 'feature'), char(req.feature), '');
        hard = true;
        if isfield(req, 'hard'), hard = logical(req.hard); end
        if ~strcmp(typ, 'toolbox')
            missing = add_missing(missing, typ, nm, 'unsupported requirement type', hard);
            continue;
        end
        ok = toolbox_ok(nm, ft, get_opt(opts, 'toolboxStatus'));
        if ~ok && hard
            missing = add_missing(missing, 'toolbox', nm, ...
                sprintf('license test failed for feature %s', ft), true);
        elseif ~ok
            notes{end+1} = sprintf('%s is not licensed; the task may only use the base-MATLAB part of %s', nm, id); %#ok<AGROW>
        end
    end
end
end

function missing = add_missing(missing, kind, name, detail, hard)
for k = 1:numel(missing)
    if strcmp(missing(k).kind, kind) && strcmp(missing(k).name, name)
        return;
    end
end
missing(end+1) = struct('kind', kind, 'name', name, 'detail', detail, 'hard', hard);
end

function s = describe_missing(missing)
parts = cell(1, numel(missing));
for k = 1:numel(missing)
    parts{k} = sprintf('%s %s: %s', missing(k).kind, missing(k).name, missing(k).detail);
end
s = strjoin(parts, '; ');
end

function st = skill_state(id, skillsRoot, override)
st = '';
if ~isempty(override)
    for k = 1:size(override, 1)
        if strcmp(override{k,1}, id), st = lower(char(override{k,2})); break; end
    end
end
if ~isempty(st), return; end
d = fullfile(skillsRoot, id);
if ~isfolder(d)
    st = 'missing'; return;
end
f = fullfile(d, 'SKILL.md');
if ~isfile(f) || dir(f).bytes == 0
    st = 'damaged'; return;
end
st = 'ok';
end

function ok = toolbox_ok(name, feature, override)
ok = true;
if ~isempty(override)
    for k = 1:size(override, 1)
        if strcmp(override{k,1}, name)
            ok = logical(override{k,2});
            return;
        end
    end
end
if ~isempty(feature)
    ok = license('test', feature) == 1;
end
end

function v = get_opt(opts, f)
if isfield(opts, f), v = opts.(f); else, v = []; end
end

function deps = get_deps(s)
deps = {};
if isfield(s, 'dependsOn'), deps = cellstr_of(s.dependsOn); end
end

function reqs = get_reqs(s)
reqs = struct('type', {}, 'name', {}, 'feature', {}, 'hard', {});
if ~isfield(s, 'requires') || isempty(s.requires), return; end
v = s.requires;
if isstruct(v)
    reqs = v(:).';
elseif iscell(v)
    for k = 1:numel(v)
        if isstruct(v{k}), reqs(end+1) = v{k}; end %#ok<AGROW>
    end
end
end

function terms = get_terms(s)
terms = {};
if ~isfield(s, 'terms') || isempty(s.terms), return; end
v = s.terms;
if isstruct(v) && isfield(v, 't')
    for k = 1:numel(v)
        tq = v(k).t; wq = v(k).w;
        if iscell(tq), tq = tq{1}; end
        if iscell(wq), wq = wq{1}; end
        terms{end+1} = {char(tq), double(wq)}; %#ok<AGROW>
    end
elseif iscell(v)
    for k = 1:numel(v)
        if isstruct(v{k}) && isfield(v{k}, 't')
            terms{end+1} = {char(v{k}.t), double(v{k}.w)}; %#ok<AGROW>
        end
    end
end
end

function c = cellstr_of(v)
if ischar(v), c = {v};
elseif isstring(v), c = cellstr(v);
elseif iscell(v)
    c = {};
    for k = 1:numel(v)
        if ischar(v{k}), c{end+1} = v{k}; %#ok<AGROW>
        elseif isstring(v{k}), c{end+1} = char(v{k}); end %#ok<AGROW>
    end
else, c = {};
end
c = c(:).';
end

function pos = term_positions(p, term)
t = lower(char(term));
pos = [];
if isempty(t), return; end
if all(double(t) < 128) && all(isletter(t)) && numel(t) <= 3
    pat = ['(?<![a-z0-9])' regexptranslate('escape', t) '(?![a-z0-9])'];
    pos = regexp(p, pat);
else
    pos = strfind(p, t);
end
end

function tf = negated_before(p, pos)
if pos <= 1, pre = ''; else, pre = p(max(1, pos - 24):pos - 1); end
% A negator belongs to its clause. "不做图像处理，只做 PID 控制" must not
% negate PID just because 不做 is 10 characters earlier.
seps = {'，', ',', '。', '.', '；', ';', '！', '!', '？', '?', '、', ...
    ' but ', '而是', '只做', '仅做'};
cut = 0;
for k = 1:numel(seps)
    at = strfind(pre, seps{k});
    if ~isempty(at)
        cut = max(cut, at(end) + numel(seps{k}) - 1);
    end
end
if cut > 0, pre = pre(cut+1:end); end
if numel(pre) > 12, pre = pre(end-11:end); end
negs = {'不要', '不用', '不使用', '无需', '无须', '不是', '没有', ...
    '排除', '别用', '不做', '不含', '不包括', 'without', 'not ', 'no ', ...
    'don''t', 'exclude'};
tf = false;
for k = 1:numel(negs)
    if contains(pre, negs{k})
        tf = true;
        return;
    end
end
end

function c = unique_keep(c)
if isempty(c), c = {}; return; end
[~, ia] = unique(c, 'stable');
c = c(sort(ia));
end

function s = ternary(c, a, b)
if c, s = a; else, s = b; end
end
