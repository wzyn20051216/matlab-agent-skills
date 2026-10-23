function r = mas_skill_install_audit(varargin)
%MAS_SKILL_INSTALL_AUDIT  Read-only drift audit of every installed Skill copy.
%
%   r = mas_skill_install_audit()
%   r = mas_skill_install_audit('outFile', path)
%   r = mas_skill_install_audit('repoRoot', path, 'rootsFile', path)
%
% Compares the repository tree against each discovery root, resolves the copy a
% client actually reads from the precedence recorded in assets/install-roots.json,
% and emits a machine-readable report plus safe update suggestions.
%
% The tool never writes to, renames, or deletes an install directory. The only
% file it may write is the report named by 'outFile'.
%
% A root that exists is not a root a client loads. Each client therefore carries
% a resolution level, and only log/engine evidence upgrades it to "observed".
% Callers must not read a row from an unobserved root as proof of loading.

here = fileparts(mfilename('fullpath'));
skillDir = fileparts(here);
repoDefault = fileparts(fileparts(skillDir));
repoRoot = repoDefault;
rootsFile = fullfile(skillDir, 'assets', 'install-roots.json');
outFile = '';
for k = 1:2:numel(varargin)
    switch lower(varargin{k})
        case 'reporoot', repoRoot = varargin{k+1};
        case 'rootsfile', rootsFile = varargin{k+1};
        case 'outfile', outFile = varargin{k+1};
        otherwise, error('mas_skill_install_audit:option', 'unknown option "%s"', varargin{k});
    end
end
if ~isfolder(fullfile(repoRoot, 'skills'))
    error('mas_skill_install_audit:repo', 'no skills/ under %s', repoRoot);
end
if ~isfile(rootsFile)
    error('mas_skill_install_audit:roots', 'roots file not found: %s', rootsFile);
end
cfg = jsondecode(fileread(rootsFile));
if ~isfield(cfg, 'roots') || ~isfield(cfg, 'clients')
    error('mas_skill_install_audit:roots', 'roots file needs "roots" and "clients"');
end

R = struct('id', {}, 'client', {}, 'scope', {}, 'path', {}, 'priority', {}, ...
    'exists', {}, 'evidence', {});
for k = 1:numel(cfg.roots)
    rt = cfg.roots(k);
    R(end+1).id = char(rt.id); %#ok<AGROW>
    R(end).client = char(rt.client);
    R(end).scope = char(rt.scope);
    R(end).path = expand_path(char(rt.path), repoRoot);
    R(end).priority = double(rt.priority);
    R(end).exists = isfolder(R(end).path);
    R(end).evidence = char(rt.evidence);
end

skillNames = list_skill_dirs(fullfile(repoRoot, 'skills'));
S = struct('name', {}, 'repoPath', {}, 'repoSkillMdSha256', {}, 'repoFileCount', {}, ...
    'installs', {}, 'referencedTools', {}, 'missingReferencedToolsInRepo', {});

for si = 1:numel(skillNames)
    nm = skillNames{si};
    repoSkill = fullfile(repoRoot, 'skills', nm);
    [repoNames, repoHashes] = hash_tree(repoSkill);
    refs = referenced_tools(repoSkill);
    S(si).name = nm;
    S(si).repoPath = repoSkill;
    S(si).repoSkillMdSha256 = field_or( ...
        repoHashes(strcmp(repoNames, 'SKILL.md')), '');
    S(si).repoFileCount = numel(repoNames);
    S(si).referencedTools = refs;
    S(si).missingReferencedToolsInRepo = setdiff(refs, tools_in_root(fullfile(repoRoot, 'skills')));

    inst = struct('rootId', {}, 'root', {}, 'path', {}, 'installed', {}, 'identical', {}, ...
        'skillMdSha256', {}, 'fileCount', {}, 'missing', {}, 'extra', {}, ...
        'differing', {}, 'referencedTools', {}, 'missingReferencedTools', {});
    for ri = 1:numel(R)
        d = fullfile(R(ri).path, nm);
        rec = struct();
        rec.rootId = R(ri).id;
        rec.root = R(ri).path;
        rec.path = d;
        rec.installed = isfolder(d) && isfile(fullfile(d, 'SKILL.md'));
        rec.referencedTools = {};
        rec.missingReferencedTools = {};
        if rec.installed
            [names, hashes] = hash_tree(d);
            [missing, extra, differing] = diff_tree(repoNames, repoHashes, names, hashes);
            rec.identical = isempty(missing) && isempty(extra) && isempty(differing);
            rec.skillMdSha256 = field_or(hashes(strcmp(names, 'SKILL.md')), '');
            rec.fileCount = numel(names);
            rec.missing = missing;
            rec.extra = extra;
            rec.differing = differing;
            rec.referencedTools = referenced_tools(d);
            rec.missingReferencedTools = setdiff(rec.referencedTools, tools_in_root(R(ri).path));
        else
            rec.identical = false;
            rec.skillMdSha256 = '';
            rec.fileCount = 0;
            rec.missing = repoNames;
            rec.extra = {};
            rec.differing = {};
        end
        inst(end+1) = rec; %#ok<AGROW>
    end
    S(si).installs = inst;
end

C = struct('id', {}, 'display', {}, 'resolutionLevel', {}, 'observed', {}, ...
    'evidence', {}, 'roots', {}, 'skills', {});
for ci = 1:numel(cfg.clients)
    cl = cfg.clients(ci);
    rootIds = as_cellstr(cl.roots);
    cand = [];
    for q = 1:numel(rootIds)
        ri = find_root(R, rootIds{q});
        if ri > 0, cand(end+1) = ri; end %#ok<AGROW>
    end
    eff = struct('skill', {}, 'rootId', {}, 'rootPath', {}, 'status', {}, ...
        'confidence', {}, 'identical', {}, 'missingCount', {}, ...
        'extraCount', {}, 'differingCount', {});
    for si = 1:numel(skillNames)
        [hit, fallback] = resolve_root(S(si).installs, R, rootIds);
        e = struct();
        e.skill = skillNames{si};
        e.rootId = ''; e.rootPath = '';
        e.status = 'MISSING'; e.confidence = 'observed';
        e.identical = false; e.missingCount = numel(S(si).installs(1).missing);
        e.extraCount = 0; e.differingCount = 0;
        if hit > 0
            rec = S(si).installs(hit);
            e.rootId = rec.rootId; e.rootPath = rec.root;
            e.identical = rec.identical;
            e.status = ternary(rec.identical, 'CURRENT', 'DRIFTED');
            e.missingCount = numel(rec.missing);
            e.extraCount = numel(rec.extra);
            e.differingCount = numel(rec.differing);
            if ~cl.observed
                e.confidence = 'assumed';
                others = differing_installs(S(si).installs, hit, cand);
                if ~isempty(others)
                    e.status = 'UNRESOLVED';
                    e.confidence = 'unresolved';
                end
            elseif fallback && strcmp(char(cl.resolutionLevel), 'observed-single-root')
                e.status = 'UNVERIFIED_FALLBACK';
                e.confidence = 'unresolved';
            end
        end
        eff(end+1) = e; %#ok<AGROW>
    end
    C(ci).id = char(cl.id);
    C(ci).display = char(cl.display);
    C(ci).resolutionLevel = char(cl.resolutionLevel);
    C(ci).observed = logical(cl.observed);
    C(ci).evidence = char(cl.evidence);
    C(ci).roots = rootIds;
    C(ci).skills = eff;
end

K = struct('skill', {}, 'roots', {}, 'hashes', {}, 'distinctHashes', {}, 'effective', {});
for si = 1:numel(skillNames)
    ids = {}; hs = {}; idx = [];
    for ri = 1:numel(R)
        if S(si).installs(ri).installed
            ids{end+1} = S(si).installs(ri).rootId; %#ok<AGROW>
            hs{end+1} = S(si).installs(ri).skillMdSha256; %#ok<AGROW>
            idx(end+1) = ri; %#ok<AGROW>
        end
    end
    if numel(unique(hs)) > 1
        eff = struct('client', {}, 'rootId', {});
        for ci = 1:numel(C)
            row = C(ci).skills(si);
            eff(end+1) = struct('client', C(ci).id, 'rootId', row.rootId); %#ok<AGROW>
        end
        K(end+1) = struct('skill', skillNames{si}, 'roots', {ids}, 'hashes', {hs}, ...
            'distinctHashes', numel(unique(hs)), 'effective', eff); %#ok<AGROW>
    end
end

M = struct('skill', {}, 'client', {}, 'targetRoot', {}, 'action', {}, ...
    'add', {}, 'overwrite', {}, 'onlyInInstall', {}, 'confidence', {}, ...
    'requiresApproval', {}, 'note', {});
seen = containers.Map('KeyType', 'char', 'ValueType', 'logical');
for ci = 1:numel(C)
    for si = 1:numel(skillNames)
        e = C(ci).skills(si);
        if strcmp(e.status, 'CURRENT'), continue; end
        if strcmp(e.status, 'MISSING')
            action = 'INSTALL';
            add = S(si).installs(1).missing; overwrite = {}; extra = {};
        elseif strcmp(e.status, 'UNRESOLVED') || strcmp(e.status, 'UNVERIFIED_FALLBACK')
            action = 'MANUAL_REVIEW';
            add = {}; overwrite = {}; extra = {};
        else
            action = 'SYNC';
            ri = find_root(R, e.rootId);
            rec = S(si).installs(ri);
            add = rec.missing; overwrite = rec.differing; extra = rec.extra;
        end
        key = sprintf('%s|%s', e.rootPath, S(si).name);
        if isKey(seen, key), continue; end
        seen(key) = true;
        M(end+1) = struct('skill', S(si).name, 'client', C(ci).id, ...
            'targetRoot', e.rootPath, 'action', action, 'add', {add}, ...
            'overwrite', {overwrite}, 'onlyInInstall', {extra}, ...
            'confidence', e.confidence, 'requiresApproval', true, ...
            'note', 'Read-only suggestion. Backup first; never delete onlyInInstall automatically.'); %#ok<AGROW>
    end
end

summary = struct();
summary.verdict = ternary(all(arrayfun(@(c) all(strcmp({c.skills.status}, 'CURRENT')), C)), ...
    'CONSISTENT', 'DRIFTED');
summary.nSkills = numel(skillNames);
summary.nClients = numel(C);
summary.nRecommendations = numel(M);
summary.consistentClients = arrayfun(@(c) all(strcmp({c.skills.status}, 'CURRENT')), C);
summary.claimLimit = ['A root that exists is not a root the client loads. Only Qoder ' ...
    'precedence (log) and Codex engine listing (skills/list) were observed.'];
for ci = 1:numel(C)
    summary.byClient(ci).client = C(ci).id;
    summary.byClient(ci).nCurrent = nnz(strcmp({C(ci).skills.status}, 'CURRENT'));
    summary.byClient(ci).nDrifted = nnz(strcmp({C(ci).skills.status}, 'DRIFTED'));
    summary.byClient(ci).nMissing = nnz(strcmp({C(ci).skills.status}, 'MISSING'));
    summary.byClient(ci).nUnresolved = nnz(ismember({C(ci).skills.status}, ...
        {'UNRESOLVED', 'UNVERIFIED_FALLBACK'}));
end

r = struct();
r.schema = 'mas-skill-install-audit/1';
r.readOnly = true;
r.generatedAt = datestr(now, 31);
r.repoRoot = repoRoot;
r.rootsFile = rootsFile;
r.writeTarget = outFile;
r.roots = R;
r.clients = C;
r.skills = S;
r.conflicts = K;
r.recommendations = M;
r.summary = summary;

if ~isempty(outFile)
    fid = fopen(outFile, 'w');
    if fid < 0, error('mas_skill_install_audit:write', 'cannot write %s', outFile); end
    fwrite(fid, jsonencode(r, 'PrettyPrint', true), 'char');
    fclose(fid);
end
end

% ===========================================================================
function names = list_skill_dirs(root)
d = dir(root);
names = {};
for k = 1:numel(d)
    if d(k).isdir && ~any(strcmp(d(k).name, {'.', '..'})) && ...
            isfile(fullfile(root, d(k).name, 'SKILL.md'))
        names{end+1} = d(k).name; %#ok<AGROW>
    end
end
names = sort(names);
end

function p = expand_path(p, repoRoot)
p = strrep(p, '${REPO}', repoRoot);
p = strrep(p, '${USERPROFILE}', getenv('USERPROFILE'));
p = strrep(p, '/', filesep);
end

function c = as_cellstr(v)
if ischar(v), c = {v}; elseif iscell(v), c = reshape(v, 1, []); else, c = {}; end
end

function v = field_or(cellv, dflt)
if isempty(cellv), v = dflt; else, v = cellv{1}; end
end

function v = ternary(cond, a, b)
if cond, v = a; else, v = b; end
end

function names = rel_files(d)
names = {};
items = dir(fullfile(d, '**', '*'));
for k = 1:numel(items)
    if items(k).isdir, continue; end
    full = fullfile(items(k).folder, items(k).name);
    names{end+1, 1} = rel_path(full, d); %#ok<AGROW>
end
names = sort(names);
end

function r = rel_path(p, base)
p = strrep(p, '\', '/'); base = strrep(base, '\', '/');
if ~endsWith(base, '/'), base = [base '/']; end
if startsWith(p, base), r = p(numel(base)+1:end); else, r = p; end
end

function [names, hashes] = hash_tree(d)
names = rel_files(d);
hashes = cell(size(names));
for k = 1:numel(names)
    hashes{k} = sha256_file(fullfile(d, names{k}));
end
end

function [missing, extra, differing] = diff_tree(repoN, repoH, instN, instH)
missing = setdiff(repoN, instN);
extra = setdiff(instN, repoN);
both = intersect(repoN, instN);
differing = {};
for k = 1:numel(both)
    a = repoH{find(strcmp(repoN, both{k}), 1)};
    b = instH{find(strcmp(instN, both{k}), 1)};
    if ~strcmp(a, b), differing{end+1, 1} = both{k}; end %#ok<AGROW>
end
end

function h = sha256_file(p)
fid = fopen(p, 'r');
if fid < 0, error('mas_skill_install_audit:hash', 'cannot open %s', p); end
b = fread(fid, Inf, '*uint8'); fclose(fid);
md = java.security.MessageDigest.getInstance('SHA-256');
d = typecast(md.digest(b), 'uint8');
h = lower(reshape(dec2hex(d)', 1, []));
end

function refs = referenced_tools(d)
refs = {};
if ~isfolder(d), return; end
files = [{'SKILL.md'}];
r = dir(fullfile(d, 'references', '*.md'));
for k = 1:numel(r), files{end+1} = fullfile('references', r(k).name); end %#ok<AGROW>
for k = 1:numel(files)
    p = fullfile(d, files{k});
    if isfile(p)
        m = regexp(fileread(p), 'mas_[A-Za-z0-9_]+', 'match');
        refs = [refs, m]; %#ok<AGROW>
    end
end
refs = unique(refs);
end

function tools = tools_in_root(root)
tools = {};
r = dir(fullfile(root, '*', 'scripts', '*.m'));
for k = 1:numel(r)
    [~, nm] = fileparts(r(k).name);
    tools{end+1} = nm; %#ok<AGROW>
end
tools = unique(tools);
end

function [hit, fallback] = resolve_root(installs, R, rootIds)
hit = 0; fallback = false;
for q = 1:numel(rootIds)
    ri = find_root(R, rootIds{q});
    if ri == 0, continue; end
    if installs(ri).installed
        if hit == 0
            hit = ri;
            fallback = ~strcmp(R(hit).id, rootIds{1});
        end
    end
end
end

function ri = find_root(R, id)
ri = 0;
for k = 1:numel(R)
    if strcmp(R(k).id, id), ri = k; return; end
end
end

function idx = differing_installs(installs, refIdx, candidates)
idx = [];
for k = candidates
    if k == refIdx || ~installs(k).installed, continue; end
    if ~strcmp(installs(k).skillMdSha256, installs(refIdx).skillMdSha256)
        idx(end+1) = k; %#ok<AGROW>
    end
end
end
