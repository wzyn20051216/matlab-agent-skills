function E = p58_native_evidence(varargin)
%P58_NATIVE_EVIDENCE  Collect per-client native Skill-invocation evidence.
%
%   E = p58_native_evidence()
%
% Builds artifacts/phase58/native/client_evidence.json from evidence that
% already exists on disk: the clients' own event streams, the discovery probe
% records, the Task 1 install snapshot and the Task 3 closed-loop acceptance
% report. Nothing here runs a client.
%
% Evidence levels (the four used by Phase 5.7, not the matlab-runner
% engineering L1-L5 ladder):
%   L1 source     the repository ships the Skill
%   L2 discovery  the client's own listing returns it
%   L3 native     the client emits a Skill-load event
%   L4 outcome    the task is worked through that Skill and an independent
%                 check accepts the delivery
%
% Codex's JSON stream has no Skill item type, so its L3 is recorded as
% NOT APPLICABLE (mechanism) and the strongest available equivalent -- the
% client reading the installed copy itself, unprompted -- is reported separately
% as l3ReadInstalledCopy. A file read is never renamed into a native trigger.

ap = inputParser;
ap.addParameter('writeReport', true, @(x) islogical(x) || isnumeric(x));
ap.parse(varargin{:});
writeReport = logical(ap.Results.writeReport);

here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
native = fullfile(repo, 'artifacts', 'phase58', 'native');
addpath(fullfile(repo, 'skills', 'matlab-testing-ci', 'scripts'));
addpath(here);

clFile = fullfile(repo, 'artifacts', 'phase58', 'closed-loop', ...
    'codex_desktop_pid_acceptance.json');
clTaskDir = '';
if isfile(clFile)
    clTaskDir = strrep(char(jsondecode(fileread(clFile)).taskDir), '\', '/');
end

E = struct();
E.schema = 'mas-phase58-client-evidence/1';
E.generatedAt = datestr(now, 31);
E.phase = '5.8';
E.readOnly = true;
E.levels = struct( ...
    'L1', 'the repository ships the Skill', ...
    'L2', 'the client listing returns the Skill', ...
    'L3', 'the client emits a native Skill-load event', ...
    'L4', 'the task is worked through that Skill and independently accepted');
E.l3MechanismNote = ['Codex app-server/CLI event types are error, agent_message, ' ...
    'command_execution, mcp_tool_call and file_change; no Skill item exists. ' ...
    'Codex L3 is therefore NOT APPLICABLE (mechanism), and l3ReadInstalledCopy ' ...
    'is its strongest available equivalent, not a native trigger.'];

% ---- episodes ------------------------------------------------------------
groups = struct('dir', {'codex-desktop-tasks', 'codex-cli-tasks'}, ...
    'client', {'codex-desktop', 'codex-cli'});
rows = {};
for g = 1:numel(groups)
    root = fullfile(native, groups(g).dir);
    if ~isfolder(root), continue; end
    ds = dir(root); ds = ds([ds.isdir] & ~strcmp({ds.name}, '.'));
    for k = 1:numel(ds)
        d = strrep(fullfile(root, ds(k).name), '\', '/');
        vf = fullfile(d, 'verification.json');
        if ~isfile(vf), continue; end
        V = jsondecode(fileread(vf));
        row = new_episodes();
        row.trace = default_trace();
        row.client = groups(g).client;
        row.episode = ds(k).name;
        row.task = char(getf(V, 'task', ''));
        row.status = upper(char(getf(V, 'status', 'UNKNOWN')));
        row.exitCode = double(getf(V, 'exitCode', NaN));
        row.approvalMode = char(getf(V, 'approvalMode', 'sandbox'));
        row.durationSeconds = double(getf(V, 'durationSeconds', NaN));
        row.prompt = char(getf(V, 'prompt', ''));
        row.promptHasSkillName = prompt_is_dirty(row.prompt);
        pf = getf(V, 'producedFiles', struct());
        if isstruct(pf), row.producedFiles = fieldnames(pf); end
        if isfile(fullfile(d, 'events.jsonl'))
            T = p58_trace_evidence(d, repo);
            keep = {'skillSelected', 'referencesLoaded', 'mcpExecuted', 'checksRun', ...
                'repaired', 'toolCalls', 'mcpFailures', 'commandCalls', ...
                'userRootSkillReads', 'projectScoped', 'skillPaths', 'referencePaths', ...
                'repoSourceReads'};
            for q = 1:numel(keep)
                row.trace.(keep{q}) = T.(keep{q});
            end
            row.skillRoot = T.skillRoot;
        end
        row.mcpExecuted = row.trace.mcpExecuted;
        row.userRootSkillReads = row.trace.userRootSkillReads;
        row.projectScoped = row.trace.projectScoped;
        row.filesProduced = numel(row.producedFiles);
        row.independentlyAccepted = ~isempty(clTaskDir) && ...
            strcmp(lower(strrep(d, '\', '/')), lower(clTaskDir));
        row.levels = level_flags(row);
        row.l3eq = row.levels.l3ReadInstalledCopy;
        row.l4 = row.levels.L4;
        row.note = episode_note(V, row);
        rows{end+1} = row; %#ok<AGROW>
    end
end
if isempty(rows)
    eps_ = new_episodes();
    eps_ = eps_([]);
else
    eps_ = cell2mat(rows);
end
E.episodes = eps_;

% ---- discovery probes (L2) ------------------------------------------------
disc = struct('client', {}, 'status', {}, 'skillsReturned', {}, 'expected', {}, ...
    'hashesMatchRepo', {}, 'discoveryErrors', {}, 'names', {}, 'fixtureRemoved', {});
for p = {fullfile(native, 'codex-desktop-isolated'), fullfile(native, 'codex-cli-isolated')}
    vf = fullfile(char(p), 'verification.json');
    if ~isfile(vf), continue; end
    V = jsondecode(fileread(vf));
    row = struct();
    row.client = char(getf(V, 'client', ''));
    row.status = char(getf(V, 'status', ''));
    row.skillsReturned = numel(getf(V, 'skills', {}));
    row.expected = double(getf(V, 'expectedCount', NaN));
    row.hashesMatchRepo = logical(getf(V, 'hashesMatchRepo', false));
    row.discoveryErrors = as_cellchar(getf(V, 'discoveryErrors', {}));
    s = getf(V, 'skills', {});
    row.names = {};
    for q = 1:numel(s), row.names{end+1} = char(s(q).name); end %#ok<AGROW>
    row.fixtureRemoved = logical(getf(V, 'fixtureRemoved', false));
    disc(end+1) = row; %#ok<AGROW>
end
E.discovery = disc;

% ---- user-level roots were read, never written ----------------------------
snap = root_compare(fullfile(repo, 'artifacts', 'phase58', 'install', 'install_audit.json'));
E.userRootsUnchanged = snap;

% ---- the accepted closed loop --------------------------------------------
E.closedLoop = struct('file', clFile, 'exists', isfile(clFile), 'pass', false, ...
    'dimensions', struct(), 'independentAgreement', false);
if isfile(clFile)
    C = jsondecode(fileread(clFile));
    E.closedLoop.pass = logical(C.pass);
    E.closedLoop.independentAgreement = logical(C.independentAgreement);
    fn = fieldnames(C.dimensions);
    for k = 1:numel(fn)
        E.closedLoop.dimensions.(fn{k}) = char(C.dimensions.(fn{k}).status);
    end
end

% ---- per-client coverage matrix -------------------------------------------
E.clients = client_matrix(eps_, disc);
E.coverageLimits = { ...
    ['Codex CLI task runs stopped at 2026-10-23T05:28Z: the models cache was ' ...
    'rejected (missing field supports_parallel_tool_calls) and the skill context ' ...
    'budget dropped descriptions; the one CLI episode produced no Skill read.'], ...
    ['Codex Desktop task runs stopped after 2026-10-23T06:57Z: the account usage ' ...
    'limit was reached, so no further episode was attempted.'], ...
    ['Qoder native verification is deferred: its user root is 2/9 CURRENT and ' ...
    '7/9 DRIFTED and syncing it needs explicit approval.'], ...
    ['WorkBuddy has no Skill-list or task interface in this repository, so it is ' ...
    'NOT TESTED; disk presence under its out-of-repo skills directory is not loading.'], ...
    ['The Codex Windows sandbox rejected process creation ' ...
    '(CreateProcessAsUserW failed: 5, access denied) in three attempts: two in ' ...
    'working directories outside the repository (a system temp scratch directory ' ...
    'and an isolated probe tree on the desktop) and one ' ...
    'inside the repository. Neither out-of-repo attempt ever exposed the MATLAB ' ...
    'MCP and neither was retried, so they were abandoned; the in-repo attempt ' ...
    'recovered on the next run. The rejection is therefore not attributed to the ' ...
    'working directory alone.'], ...
    ['Per-client observations on one machine; not a cross-client ranking and not ' ...
    'a Skill-effect measurement.']};

% ---- evidence provenance --------------------------------------------------
% Each episode ran in a throwaway probe directory and its evidence was filed
% afterwards under native/<client>-tasks/. The working directory baked into
% verification.json therefore often no longer exists, so the recorded root is
% reported as relocated instead of being presented as still-inspectable.
E.provenanceNotes = provenance_notes(eps_);

% ---- defects found while the client worked, not fixed mid-audit ----------
E.knownDefects = struct( ...
    'id', {'skill-reads-outside-its-own-directory'}, ...
    'observedIn', {{'C_control_design_E3'}}, ...
    'detail', {['matlab-runner / matlab-orchestrator SKILL.md tells the agent to ' ...
    'run .\scripts\Test-MatlabMcpExistingSession.ps1. Inside an installed project ' ...
    'copy that path does not exist, so the client went looking for it and ended up ' ...
    'reading the source repository working copy (scripts/* at the checkout root). The episode still ' ...
    'passed, which is exactly why this is a latent defect: it works only where a ' ...
    'clone happens to be reachable.']}, ...
    'recommendation', {['Ship that check inside the Skill and reference it relative ' ...
    'to SKILL.md. Not edited this phase: changing SKILL.md would move every ' ...
    'installed hash while the install audit is still open, and a metadata edit ' ...
    'needs before/after evidence of its own.']});

% ---- assertions -----------------------------------------------------------
A = struct('label', {}, 'ok', {});
neg = eps_(strcmp({eps_.task}, 'D_nonmatlab_control'));
A(end+1) = rec('negative control never calls the MATLAB MCP and delivers nothing', ...
    ~isempty(neg) && ~any([neg.mcpExecuted]) && all([neg.filesProduced] == 0));
l4 = eps_(strcmp({eps_.l4}, 'EVIDENCED'));
A(end+1) = rec('an episode reaches L4 only through the independent acceptance', ...
    ~isempty(l4) && all([l4.independentlyAccepted]));
A(end+1) = rec('the L4 episode read only the installed project copy', ...
    ~isempty(l4) && all([l4.userRootSkillReads] == 0) && all([l4.projectScoped]));
A(end+1) = rec('no prompt named a Skill or a mas_ tool', ~any([eps_.promptHasSkillName]));
A(end+1) = rec('both Codex engines listed 9/9 with hashes matching the repository', ...
    numel(disc) == 2 && all([disc.skillsReturned] == 9) && all([disc.hashesMatchRepo]));
A(end+1) = rec('user-level roots are byte-identical to the pre-probe snapshot', snap.equal);
A(end+1) = rec('the closed-loop acceptance passes', E.closedLoop.pass);
A(end+1) = rec('a desktop episode shows the client reading SKILL.md unprompted', ...
    any(strcmp({eps_.l3eq}, 'EVIDENCED')));
E.assertions = A;
E.pass = all([A.ok]);
bad = {A(~[A.ok]).label};

if writeReport
    outFile = fullfile(native, 'client_evidence.json');
    fid = fopen(outFile, 'w');
    fwrite(fid, jsonencode(E, 'PrettyPrint', true), 'char');
    fclose(fid);
    E.reportFile = outFile;
end
print_table(E);
if ~E.pass
    error('p58_native_evidence:assertion', '%d assertion(s) failed: %s', ...
        numel(bad), strjoin(bad, '; '));
end
end

% ===========================================================================
function e = new_episodes()
e = struct('client', '', 'episode', '', 'task', '', 'status', '', 'exitCode', NaN, ...
    'approvalMode', '', 'durationSeconds', NaN, 'prompt', '', ...
    'promptHasSkillName', false, 'producedFiles', {{}}, 'skillRoot', '', ...
    'independentlyAccepted', false, 'levels', struct(), 'note', '', 'trace', struct(), ...
    'l3eq', '', 'l4', '', 'mcpExecuted', false, 'userRootSkillReads', 0, ...
    'projectScoped', false, 'filesProduced', 0);
end

function t = default_trace()
t = struct('skillSelected', false, 'referencesLoaded', false, 'mcpExecuted', false, ...
    'checksRun', false, 'repaired', false, 'toolCalls', 0, 'mcpFailures', 0, ...
    'commandCalls', 0, 'userRootSkillReads', 0, 'projectScoped', false, ...
    'skillPaths', {{}}, 'referencePaths', {{}}, 'repoSourceReads', {{}});
end

function L = level_flags(row)
L = struct('L1', 'EVIDENCED', 'L2', 'EVIDENCED', 'L3', 'NOT APPLICABLE (mechanism)', ...
    'L4', 'NOT EVIDENCED', 'l3ReadInstalledCopy', 'NOT EVIDENCED', ...
    'matlabWorked', 'NO');
T = row.trace;
if T.skillSelected
    L.l3ReadInstalledCopy = 'EVIDENCED';
end
if T.mcpExecuted
    L.matlabWorked = 'YES';
    if row.independentlyAccepted
        L.L4 = 'EVIDENCED';
    elseif ~isempty(row.producedFiles) && strcmp(row.status, 'PASS')
        L.L4 = ['PARTIAL: MATLAB ran through the Skill and an artifact was ' ...
            'delivered, but no independent acceptance check covers this task'];
    else
        L.L4 = 'PARTIAL: MATLAB ran, nothing accepted was delivered';
    end
end
end

function n = episode_note(V, row)
n = '';
st = char(getf(V, 'stderrTail', ''));
if strcmp(row.status, 'FAIL')
    if row.trace.commandCalls == 0 && row.trace.toolCalls == 0
        n = 'client aborted before any command or tool call ran';
    else
        n = 'episode recorded FAIL; its events are kept byte-for-byte';
    end
    if contains(st, 'Transport channel closed')
        n = [n ' | MCP transport closed mid-task'];
    elseif contains(st, 'failed to load models cache')
        n = [n ' | model metadata rejected by the CLI'];
    elseif contains(st, 'CreateProcessAsUserW')
        n = [n ' | the client sandbox rejected process creation (access denied)'];
    end
elseif row.trace.userRootSkillReads > 0
    n = sprintf('this episode also read the user-level Skills root %d time(s) (read-only)', ...
        row.trace.userRootSkillReads);
end
end

function tf = prompt_is_dirty(p)
p = lower(char(p));
names = {'matlab-orchestrator', 'matlab-runner', 'matlab-control-optimization', ...
    'matlab-data-analysis', 'matlab-simulink-modeling', 'matlab-signal-vision-ai', ...
    'matlab-robotics-autonomy', 'matlab-codegen-deploy', 'matlab-testing-ci', 'mas_'};
tf = any(cellfun(@(n) contains(p, lower(n)), names));
end

function notes = provenance_notes(eps_)
% One line per distinct recorded working root, saying whether it still exists.
notes = {};
seen = {};
for k = 1:numel(eps_)
    r = strrep(char(getf(eps_(k), 'skillRoot', '')), '\', '/');
    if isempty(r) || any(strcmp(seen, r)), continue; end
    seen{end+1} = r; %#ok<AGROW>
    if isfolder(r)
        notes{end+1} = sprintf('%s -- still present on disk', r); %#ok<AGROW>
    else
        notes{end+1} = sprintf(['%s -- RELOCATED: the episode ran here and its ' ...
            'evidence was filed under artifacts/phase58/native afterwards, so this ' ...
            'root no longer exists to re-inspect. Path classification used the ' ...
            'recorded root, which is the path the client actually addressed.'], r); %#ok<AGROW>
    end
end
end

function M = client_matrix(eps_, disc)
clients = {{'codex-desktop', 'Codex Desktop engine 0.163.0-alpha.11.1'}, ...
           {'codex-cli', 'Codex CLI 0.147.0'}, ...
           {'qoder', 'Qoder Desktop'}, ...
           {'workbuddy', 'WorkBuddy'}};
M = struct('client', {}, 'name', {}, 'episodes', {}, 'episodesPass', {}, ...
    'L2', {}, 'L3', {}, 'l3ReadInstalledCopy', {}, 'L4', {}, 'status', {}, 'basis', {});
for k = 1:numel(clients)
    id = clients{k}{1};
    sel = eps_(strcmp({eps_.client}, id));
    d = disc(contains(lower({disc.client}), strrep(id, '-', ' ')));
    row.client = id;
    row.name = clients{k}{2};
    row.episodes = numel(sel);
    row.episodesPass = sum(strcmp({sel.status}, 'PASS'));
    row.L2 = status_of(~isempty(d) && all([d.skillsReturned] == 9) && all([d.hashesMatchRepo]));
    row.l3ReadInstalledCopy = status_of(any(strcmp({sel.l3eq}, 'EVIDENCED')));
    row.L4 = status_of(any(strcmp({sel.l4}, 'EVIDENCED')));
    switch id
        case 'codex-desktop'
            row.L3 = 'NOT APPLICABLE (mechanism)';
            row.status = 'EVIDENCED to independently accepted L4, then BLOCKED by the account usage limit';
            row.basis = 'four task episodes (A, B, C, D) plus two aborted transport attempts and one out-of-repo attempt';
        case 'codex-cli'
            row.L3 = 'NOT APPLICABLE (mechanism)';
            row.status = 'L2 EVIDENCED only; task runs BLOCKED';
            row.basis = 'app-server skills/list 9/9; its single task episode died on model metadata';
        case 'qoder'
            row.L2 = 'PARTIAL (Phase 5.7 override log and an explicit Skill event; not re-run in 5.8)';
            row.L3 = 'DEFERRED (user root 2/9 CURRENT, 7/9 DRIFTED; sync needs approval)';
            row.l3ReadInstalledCopy = 'NOT TESTED';
            row.L4 = 'NOT TESTED';
            row.status = 'BLOCKED pending an approved install sync';
            row.basis = 'skill-usage.json records 1 use of matlab-orchestrator on this machine';
        case 'workbuddy'
            row.L2 = 'NOT TESTED'; row.L3 = 'NOT TESTED';
            row.l3ReadInstalledCopy = 'NOT TESTED'; row.L4 = 'NOT TESTED';
            row.status = 'NO CLIENT INTERFACE IN THIS REPOSITORY';
            row.basis = 'the .workbuddy skills root under the user profile is a symlink into an out-of-repo data directory; only disk presence is known';
    end
    M(end+1) = row; %#ok<AGROW>
end
end

function s = status_of(tf)
if tf, s = 'EVIDENCED'; else, s = 'NOT EVIDENCED'; end
end

function a = rec(label, ok)
a = struct('label', label, 'ok', logical(ok));
end

function snap = root_compare(snapshotFile)
% Compare the frozen Task 1 install snapshot against a fresh read-only audit.
snap = struct('generatedAt', '', 'recheckAt', '', 'copiesCompared', 0, ...
    'equal', false, 'detail', {{'snapshot missing'}}, 'nowVerdict', '', ...
    'nowByClient', struct(), 'method', ...
    'per-Skill SKILL.md sha256 plus the missing/differing file lists, snapshot vs now');
if ~isfile(snapshotFile)
    return
end
S = jsondecode(fileread(snapshotFile));
snap.generatedAt = char(S.generatedAt);
R = mas_skill_install_audit();
snap.recheckAt = datestr(now, 31);
count = 0;
same = true;
detail = {};
nowNames = {R.skills.name};
for k = 1:numel(S.skills)
    j = find(strcmp(nowNames, S.skills(k).name));
    if isempty(j)
        same = false;
        detail{end+1} = sprintf('%s is no longer in the audit', S.skills(k).name); %#ok<AGROW>
        continue;
    end
    nowSkill = R.skills(j);
    for q = 1:numel(S.skills(k).installs)
        i1 = S.skills(k).installs(q);
        m = find(strcmp({nowSkill.installs.rootId}, i1.rootId));
        count = count + 1;
        if isempty(m)
            same = false;
            detail{end+1} = sprintf('%s/%s is gone', S.skills(k).name, i1.rootId); %#ok<AGROW>
            continue;
        end
        a = fingerprint(S.skills(k).name, i1);
        b = fingerprint(nowSkill.name, nowSkill.installs(m));
        if ~strcmp(a, b)
            same = false;
            detail{end+1} = sprintf('%s/%s changed: %s -> %s', ...
                S.skills(k).name, i1.rootId, a, b); %#ok<AGROW>
        end
    end
end
snap.copiesCompared = count;
snap.equal = same && count > 0;
if isfield(R, 'summary')
    snap.nowVerdict = char(getf(R.summary, 'verdict', ''));
    snap.nowByClient = R.summary.byClient;
end
if snap.equal
    detail{1} = sprintf('%d installed copies are byte-identical to the pre-probe snapshot', count);
end
snap.detail = detail;
end

function f = fingerprint(skillName, inst)
f = sprintf('%s | md=%s | missing=%s | differing=%s', skillName, ...
    char(getf(inst, 'skillMdSha256', '')), ...
    strjoin(sort(as_cellchar(getf(inst, 'missing', {}))), ','), ...
    strjoin(sort(as_cellchar(getf(inst, 'differing', {}))), ','));
end

function v = getf(s, name, dflt)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name)), v = s.(name); else, v = dflt; end
end

function c = as_cellchar(x)
if isempty(x), c = {};
elseif ischar(x) || isstring(x), c = cellstr(x);
elseif iscell(x), c = cellfun(@char, x(:)', 'UniformOutput', false);
else, c = {};
end
end

function print_table(E)
fprintf('episodes (%d)\n', numel(E.episodes));
for k = 1:numel(E.episodes)
    r = E.episodes(k);
    fprintf('  %-13s %-24s %-5s exit=%-3s skill=%d refs=%d mcp=%d chk=%d userRoot=%d files=%d L4=%s\n', ...
        r.client, r.episode, r.status, num2str(r.exitCode), r.trace.skillSelected, ...
        r.trace.referencesLoaded, r.trace.mcpExecuted, r.trace.checksRun, ...
        r.trace.userRootSkillReads, numel(r.producedFiles), ...
        ternary(strcmp(r.levels.L4, 'EVIDENCED'), 'YES', 'no'));
end
fprintf('clients\n');
for k = 1:numel(E.clients)
    c = E.clients(k);
    fprintf('  %-14s L2=%-10s L3=%-28s L3eq=%-12s L4=%-10s %s\n', c.client, c.L2, c.L3, ...
        c.l3ReadInstalledCopy, c.L4, c.status);
end
fprintf('user roots unchanged vs %s snapshot: %d (%d copies)\n', E.userRootsUnchanged.generatedAt, ...
    E.userRootsUnchanged.equal, E.userRootsUnchanged.copiesCompared);
for k = 1:numel(E.provenanceNotes)
    fprintf('  provenance: %s\n', E.provenanceNotes{k});
end
bc = E.userRootsUnchanged.nowByClient;
if ~isempty(bc)
    parts = cell(1, numel(bc));
    for k = 1:numel(bc)
        parts{k} = sprintf('%s %d CURRENT / %d DRIFTED', bc(k).client, bc(k).nCurrent, bc(k).nDrifted);
    end
    fprintf('install verdict now (%s): %s\n', E.userRootsUnchanged.nowVerdict, strjoin(parts, ', '));
end
for k = 1:numel(E.assertions)
    fprintf('  [%s] %s\n', ternary(E.assertions(k).ok, 'PASS', 'FAIL'), E.assertions(k).label);
end
fprintf('pass=%d\n', E.pass);
end

function s = ternary(c, a, b)
if c, s = a; else, s = b; end
end
