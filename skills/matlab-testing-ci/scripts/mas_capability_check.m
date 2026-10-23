function r = mas_capability_check(opt, matFile)
%MAS_CAPABILITY_CHECK  Keep skills/capability-matrix.json honest about the code.
%
%   r = mas_capability_check()            % every check, real matrix
%   r = mas_capability_check('tools')     % one group
%   r = mas_capability_check('all', f)    % check a COPY at path f
%
%   r.ok, r.checks (struct array: id, pass, detail), r.detail, r.verdict
%
% WHY THIS EXISTS
% The capability matrix was written in Phase 4 and was correct then. By the end
% of Phase 4.2 it listed 14 tools while 28 were on disk, and it still marked all
% three matlab-codegen-deploy capabilities NOT TESTED after they had been built
% and tested. Nothing about a JSON file makes it go stale loudly -- it just
% becomes a plausible-looking lie, and a capability matrix that lies is worse
% than none, because people route work based on it.
%
% So the claims are checked against the filesystem rather than trusted:
%
%   tools      every mas_*.m under skills/*/scripts must appear in the matrix,
%              and every matrix entry must exist on disk (both directions)
%   skillOwners a tool must be listed under the skill it actually lives in
%   summary    the counts must equal what the entries say -- a hand-typed total
%              is exactly the kind of number that stops matching
%   evidence   a VERIFIED claim must name a test file that exists, or a graded
%              task id / task range that a reader can re-run
%
% A new tool that nobody added to the matrix is the failure this catches most
% often, so it is checked first and reported first.

if nargin < 1, opt = 'all'; end
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
if nargin < 2 || isempty(matFile)
    matFile = fullfile(repo, 'skills', 'capability-matrix.json');
end

if ~isfile(matFile)
    r = struct('ok', false, 'checks', struct([]), ...
        'detail', sprintf('%s is missing', matFile), 'verdict', 'MISSING');
    return;
end
M = jsondecode(fileread(matFile));

doTools   = any(strcmpi(opt, {'all','tools'}));
doOwners  = any(strcmpi(opt, {'all','owners'}));
doSummary = any(strcmpi(opt, {'all','summary'}));
doEvid    = any(strcmpi(opt, {'all','evidence'}));
doRefs    = any(strcmpi(opt, {'all','references'}));

C = struct('id', {}, 'pass', {}, 'detail', {});

% The tool inventory is needed by two checks, so it is built once here rather
% than inside the block that reports on it.
onDisk = {};                      % {toolName, skillName}
seen = containers.Map('KeyType', 'char', 'ValueType', 'logical');
sdirs = dir(fullfile(repo, 'skills', '*', 'scripts'));
for k = 1:numel(sdirs)
    % `dir('skills/*/scripts')` returns the CONTENTS of each scripts folder, not
    % the folder itself, so `name` is "mas_foo.m" (plus "." / ".." rows) and the
    % skill name has to come from the PATH. The first version of this loop read
    % `sdirs(k).name` as the skill and reported 116 tools instead of 28.
    if sdirs(k).isdir, continue; end
    [~, nm] = fileparts(sdirs(k).name);
    if isempty(strfind(nm, 'mas_')), continue; end
    pth = strsplit(sdirs(k).folder, filesep);
    % .../<repo>/skills/<skill>/scripts  ->  <skill> is second from the end.
    % Find it by name instead of counting from the end: trailing separators and
    % UNC/extended-length prefixes make the offset wrong in ways that are hard
    % to see, and a wrong `sk` silently doubles the inventory.
    sk = '';
    for t = 1:numel(pth)
        if strcmp(pth{t}, 'skills') && t < numel(pth), sk = pth{t+1}; end
    end
    if isempty(sk), sk = pth{end - 1}; end
    % De-duplicate by skill+tool. The wildcard can yield the same directory twice
    % on some layouts, and a doubled inventory would report every tool as
    % "missing from matrix" -- a false alarm that trains people to ignore it.
    key = fullfile(sk, nm);
    if isKey(seen, key), continue; end
    seen(key) = true;
    onDisk(end+1, :) = {nm, sk}; %#ok<AGROW>
end
diskNames = onDisk(:, 1);

% ---- tools: matrix <-> filesystem, both directions ----------------------
if doTools
    listed = fieldnames(M.tools);
    missing = diskNames(~ismember(diskNames, listed));
    ghost = listed(~ismember(listed, diskNames));
    ok = isempty(missing) && isempty(ghost);
    % `numel` on an Nx2 cell returns 2N, not N. The first version printed "58 tool(s)
    % on disk" for 29 tools, and because the only reported name was the genuinely
    % new one, it still looked like a small, believable discrepancy.
    d = sprintf('%d tool(s) on disk, %d listed', size(onDisk, 1), numel(listed));
    if ~ok
        if ~isempty(missing)
            d = sprintf('%s | MISSING from matrix: %s', d, strjoin(missing', ', '));
        end
        if ~isempty(ghost)
            d = sprintf('%s | GHOST (listed, not on disk): %s', d, strjoin(ghost', ', '));
        end
    end
    C(end+1) = struct('id', 'tools', 'pass', ok, 'detail', d);
end

% ---- owner: a tool must sit under the skill that actually contains it ----
if doTools && doOwners
    bad = {};
    tf = fieldnames(M.tools);
    for k = 1:numel(tf)
        nm = tf{k};
        claim = M.tools.(nm).skill;
        hit = find(strcmp(diskNames, nm), 1);
        if isempty(hit)
            continue;                       % already reported by the tools check
        end
        if ~strcmp(claim, onDisk{hit, 2})
            bad{end+1} = sprintf('%s: matrix says %s, disk says %s', ...
                nm, claim, onDisk{hit, 2}); %#ok<AGROW>
        end
    end
    C(end+1) = struct('id', 'skillOwners', 'pass', isempty(bad), ...
        'detail', tern(isempty(bad), 'every tool is listed under its real skill', ...
        strjoin(bad, '; ')));
end

% ---- summary must be derived, not typed ---------------------------------
if doSummary
% Status names contain spaces ("NOT TESTED"), and JSON object keys cannot:
% jsonencode strips them, so the summary stores NOTTESTED while the entries
% store "NOT TESTED". Index the counts under BOTH spellings so either side can
% be looked up; the earlier version looked up only the spaced form and reported
% "NOTTESTED claimed 13 actual 0", which reads like a counting bug rather than
% a name mismatch.
need = {'VERIFIED','PARTIAL','NOT TESTED','UNSUPPORTED','UNKNOWN'};
cnt = containers.Map('KeyType', 'char', 'ValueType', 'double');
for k = 1:numel(need)
    cnt(need{k}) = 0;
    cnt(strrep(need{k}, ' ', '')) = 0;
end
f = fieldnames(M.skills);
for k = 1:numel(f)
    caps = M.skills.(f{k});
    cf = fieldnames(caps);
    for q = 1:numel(cf)
        info = caps.(cf{q});
        if isstruct(info) && isfield(info, 'status') && isKey(cnt, info.status)
            cnt(info.status) = cnt(info.status) + 1;
            % The stripped alias is kept in sync as a MIRROR, not incremented
            % again: counting both spellings as separate entries doubled every
            % total (31 became 62) and looked like a counting bug.
            cnt(strrep(info.status, ' ', '')) = cnt(info.status);
        end
    end
end
claimed = M.summary.capability_counts;
cf = fieldnames(claimed);
mism = {};
for k = 1:numel(cf)
    actual = 0;
    if isKey(cnt, cf{k}), actual = cnt(cf{k}); end
    if actual ~= claimed.(cf{k})
        mism{end+1} = sprintf('%s claimed %d actual %d', cf{k}, claimed.(cf{k}), actual); %#ok<AGROW>
    end
end
% tool_counts was not validated by the first version, and by Phase 5.7 it still
% said 53 while all 54 listed tools were VERIFIED. An unvalidated count is a
% count that drifts, so the same derivation is applied to the tool entries.
if isfield(M.summary, 'tool_counts')
    tcnt = containers.Map('KeyType', 'char', 'ValueType', 'double');
    for k = 1:numel(need)
        tcnt(need{k}) = 0;
        tcnt(strrep(need{k}, ' ', '')) = 0;
    end
    tf = fieldnames(M.tools);
    for k = 1:numel(tf)
        info = M.tools.(tf{k});
        if isstruct(info) && isfield(info, 'status') && isKey(tcnt, info.status)
            tcnt(info.status) = tcnt(info.status) + 1;
            tcnt(strrep(info.status, ' ', '')) = tcnt(info.status);
        end
    end
    claimedT = M.summary.tool_counts;
    ctf = fieldnames(claimedT);
    for k = 1:numel(ctf)
        actual = 0;
        if isKey(tcnt, ctf{k}), actual = tcnt(ctf{k}); end
        if actual ~= claimedT.(ctf{k})
            mism{end+1} = sprintf('tool %s claimed %d actual %d', ...
                ctf{k}, claimedT.(ctf{k}), actual); %#ok<AGROW>
        end
    end
end
    C(end+1) = struct('id', 'summary', 'pass', isempty(mism), ...
        'detail', tern(isempty(mism), 'counts match the entries', strjoin(mism, '; ')));
end

% ---- a VERIFIED claim must cite a file that exists ----------------------
if doEvid
    noFile = {};
    f = fieldnames(M.skills);
    for k = 1:numel(f)
        caps = M.skills.(f{k});
        cf = fieldnames(caps);
        for q = 1:numel(cf)
            info = caps.(cf{q});
            if ~isstruct(info) || ~isfield(info, 'status'), continue; end
            if ~strcmp(info.status, 'VERIFIED'), continue; end
            ev = '';
            if isfield(info, 'evidence'), ev = info.evidence; end
            % A VERIFIED claim must point at something a reader can re-run. Accepted
% forms, because the repo's evidence is not all .m:
%   - a test file under skills/*/tests
%   - a graded cross-domain task id (D1..T1, S1/R1/G1)
%   - a driver script under scripts/ (*.ps1), which is how the MCP and
%     benchmark evidence is produced
%   - a committed artefact under artifacts/validation/ (*.json)
% The last two matter: the MATLAB MCP link and the R1/R2/R3 benchmark are
% driven from PowerShell, so a checker that only accepts .m files would call
% the strongest evidence in this repository "no evidence".
tokF = regexp(ev, '[A-Za-z0-9_\-]+\.(?:m|ps1)', 'match');
tokJ = regexp(ev, 'artifacts/[A-Za-z0-9_\-/]+\.json', 'match');
tokT = regexp(ev, '(D[1-8]|C[1-3]|T1|S1|R1|G1)', 'match');
tokR = regexp(ev, '(D[1-8]\.\.|cross-domain\s+[0-9]+|held-out\s+set)', 'match');
if isempty(tokF) && isempty(tokJ) && isempty(tokT) && isempty(tokR)
    noFile{end+1} = sprintf('%s/%s cites no test file, script, artefact or task id', ...
        f{k}, cf{q}); %#ok<AGROW>
    continue;
end
missingF = {};
for t = 1:numel(tokF)
    if isempty(dir(fullfile(repo, 'skills', '*', 'tests', tokF{t}))) && ...
       isempty(dir(fullfile(repo, 'scripts', tokF{t})))
        missingF{end+1} = tokF{t}; %#ok<AGROW>
    end
end
for t = 1:numel(tokJ)
    if ~isfile(fullfile(repo, tokJ{t}))
        missingF{end+1} = tokJ{t}; %#ok<AGROW>
    end
end
            if ~isempty(missingF)
                noFile{end+1} = sprintf('%s/%s cites missing %s', f{k}, cf{q}, ...
                    strjoin(missingF, ', ')); %#ok<AGROW>
            end
        end
    end
    C(end+1) = struct('id', 'evidence', 'pass', isempty(noFile), ...
        'detail', tern(isempty(noFile), 'every VERIFIED claim cites a test file that exists', ...
        sprintf('%d claim(s) cite nothing that exists: %s', numel(noFile), strjoin(noFile, '; '))));
end

% ---- references: every referenced file must exist, and be reachable -------
% Progressive loading only works if the pointer is right. A SKILL.md that says
% "see references/x.md" for a file that was renamed is worse than a long file,
% because the agent follows the pointer, misses, and concludes the skill is vague.
if doRefs
    refBad = {};
    refN = 0;
    sd = dir(fullfile(repo, 'skills', '*'));
    for k = 1:numel(sd)
        if ~sd(k).isdir, continue; end
        skRoot = fullfile(repo, 'skills', sd(k).name);
        f = fullfile(skRoot, 'SKILL.md');
        if ~isfile(f), continue; end
        txt = fileread(f);
        % references/<name>.md, and the sibling form ../<skill>/references/<name>.md
        tok = regexp(txt, 'references/[A-Za-z0-9_\-]+\.md', 'match');
        for t = 1:numel(tok)
            refN = refN + 1;
            if isfile(fullfile(skRoot, tok{t}))
                continue;
            end
            % sibling-skill spelling; keep the extension on the leaf
            leaf = tok{t}(strfind(tok{t}, '/')+1:end);
            sib = dir(fullfile(repo, 'skills', '*', 'references', leaf));
            if isempty(sib)
                refBad{end+1} = sprintf('%s -> %s', sd(k).name, tok{t}); %#ok<AGROW>
            end
        end
    end
    if isempty(refBad)
        C(end+1) = struct('id', 'references', 'pass', true, ...
            'detail', sprintf('all %d reference pointer(s) resolve to a real file', refN));
    else
        C(end+1) = struct('id', 'references', 'pass', false, ...
            'detail', sprintf('%d dangling pointer(s): %s', numel(refBad), strjoin(refBad, '; ')));
    end
end

nPass = nnz([C.pass]);
r = struct();
r.ok = all([C.pass]);
r.checks = C;
r.nPass = nPass;
r.nTotal = numel(C);
r.verdict = tern(r.ok, 'CONSISTENT', 'DRIFTED');
r.detail = sprintf('%d/%d consistency checks passed', nPass, numel(C));
end

% ---------------------------------------------------------------------------
function s = tern(c, a, b)
if c, s = a; else, s = b; end
end