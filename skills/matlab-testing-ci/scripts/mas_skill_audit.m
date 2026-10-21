function r = mas_skill_audit(action, opt)
%MAS_SKILL_AUDIT  Auditable record of what happened to each Skill.
%
%   r = mas_skill_audit('record')            % append the current session's events
%   r = mas_skill_audit('report')            % summarise the ledger
%   r = mas_skill_audit('report', ledgerFile)
%
%   r.events   struct array: id, ts, stage, skill, evidence, source
%   r.stages   the five stages of Task 1, each with a count
%   r.ok       true when every stage that SHOULD have happened did
%
% THE FIVE STAGES (Phase 4.3 Task 1)
%   1 DISCOVERED   the platform listed the skill
%   2 LOADED       the skill's content was actually read
%   3 SELECTED     the agent chose this skill for the task
%   4 WORKFLOW     the agent acted per the skill's workflow
%   5 ACCEPTED     the engineering result passed independent validation
%
% WHY THIS FILE EXISTS
% `mas_route` proves a ROUTER can name a skill. It proves nothing about an
% agent: routing is a string match, loading is a file read, and the two are
% routinely confused. A report that says "the skill was used" because a prompt
% matched a keyword is a claim about a regex, not about behaviour.
%
% So each stage is recorded from the EVIDENCE that establishes it, and the
% evidence names its source:
%
%   platform  the agent platform's own skill listing / load event
%   tool      a tool call whose arguments name the skill
%   file      a file that the agent produced under the skill's workflow
%   grader    the independent verifier's verdict
%
% A stage with no evidence is UNOBSERVED -- never silently OK. `mas_skill_audit`
% reports the gap, because "we could not see it" and "it did not happen" are
% different answers and the whole point of an audit is to tell them apart.

if nargin < 1, action = 'report'; end
if nargin < 2, opt = ''; end

here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
ledgerDir = fullfile(repo, 'artifacts', 'validation', 'phase43');
if ~exist(ledgerDir, 'dir'), mkdir(ledgerDir); end
ledgerFile = fullfile(ledgerDir, 'skill_audit_ledger.json');

switch lower(action)
    case 'record'
        r = do_record(repo, ledgerFile, ledgerDir, opt);
    case 'report'
        r = do_report(ledgerFile);
    otherwise
        error('mas_skill_audit:action', 'unknown action "%s"', action);
end
end

% ===========================================================================
function r = do_record(repo, ledgerFile, ledgerDir, opt)
% Read the observable evidence that exists right now and append it.
%
% Sources, in order of strength:
%   1. the platform's installed skill list  -> DISCOVERED
%   2. the platform's own load receipt      -> LOADED
%   3. an explicit caller's assertion      -> SELECTED / WORKFLOW
%   4. the independent verifier's ledger    -> ACCEPTED
%
% The function NEVER invents a stage. If the platform does not expose a load
% receipt, LOADED stays UNOBSERVED unless the caller supplies one.
ev = struct('id', {}, 'ts', {}, 'stage', {}, 'skill', {}, 'evidence', {}, 'source', {});

% ---- 1. DISCOVERED: what the platform can see ---------------------------
roots = {fullfile(getenv('USERPROFILE'), '.workbuddy', 'skills'), ...
         fullfile(getenv('USERPROFILE'), '.agents', 'skills'), ...
         fullfile(getenv('USERPROFILE'), '.codex', 'skills')};
for a = 1:numel(roots)
    r0 = roots{a};
    if ~exist(r0, 'dir'), continue; end
    d = dir(r0);
    for k = 1:numel(d)
        if ~d(k).isdir, continue; end
        if isempty(strfind(d(k).name, 'matlab-')), continue; end
        f = fullfile(r0, d(k).name, 'SKILL.md');
        if ~isfile(f), continue; end
        ev(end+1) = mk('DISCOVERED', d(k).name, ...
            sprintf('%s', f), 'platform'); %#ok<AGROW>
    end
end

% ---- 2. LOADED: only if a receipt exists --------------------------------
% The platform hands back a receipt when it loads a skill; that receipt is
% written by the CALLER (the agent), because MATLAB cannot observe the host
% agent's context. Absent a receipt, the stage stays unobserved.
receipt = fullfile(ledgerDir, 'skill_load_receipts.json');
if isfile(receipt)
    try
        R = jsondecode(fileread(receipt));
        names = fieldnames(R);
        for k = 1:numel(names)
            e = R.(names{k});
            if isfield(e, 'stage') && strcmpi(e.stage, 'LOADED')
                % jsondecode cannot keep a hyphen in a FIELD NAME, so the key
                % arrives as "matlab_orchestrator" while the platform calls the
                % skill "matlab-orchestrator". Without normalising, every
                % loaded skill looks different from its discovered twin and
                % "discovered but not loaded" lists all nine.
                sk = canon_skill(names{k});
                ev(end+1) = mk('LOADED', sk, ...
                    sprintf('%s', e.evidence), 'platform'); %#ok<AGROW>
            end
        end
    catch
        % a malformed receipt must not abort the audit
    end
end

% ---- 3/4. SELECTED and WORKFLOW: caller-supplied ------------------------
% These come from the agent's own trace, not from MATLAB.
traceFile = fullfile(ledgerDir, 'agent_trace.json');
if isfile(traceFile)
    try
        T = jsondecode(fileread(traceFile));
        if isfield(T, 'selected')
            for k = 1:numel(T.selected)
                ev(end+1) = mk('SELECTED', canon_skill(T.selected{k}.skill), ...
                    sprintf('%s', T.selected{k}.reason), 'agent'); %#ok<AGROW>
            end
        end
        if isfield(T, 'workflow')
            for k = 1:numel(T.workflow)
                ev(end+1) = mk('WORKFLOW', canon_skill(T.workflow{k}.skill), ...
                    sprintf('%s', T.workflow{k}.action), 'tool'); %#ok<AGROW>
            end
        end
    catch
    end
end

% ---- 5. ACCEPTED: the independent verifier -----------------------------
accFile = fullfile(ledgerDir, 'acceptance_ledger.json');
if isfile(accFile)
    try
        A = jsondecode(fileread(accFile));
        for k = 1:numel(A)
            if strcmpi(A(k).status, 'PASS')
                ev(end+1) = mk('ACCEPTED', canon_skill(A(k).skill), ...
                    sprintf('%s', A(k).detail), 'grader'); %#ok<AGROW>
            end
        end
    catch
    end
end

nowStr = char(datetime('now','Format','yyyy-MM-dd HH:mm:ss'));
% Build the ledger field by field. `struct('events', {}, ...)` passes a CELL to
% struct(), and struct() then treats EVERY value as a cell and builds a 0x0
% STRUCT ARRAY -- so `ledger.events` is not even a field, and the first
% `isfield(ledger,'events')` says false while `ledger.events` errors with
% "invalid argument". Assigning the fields one at a time avoids the whole
% class of problem.
ledger = struct();
ledger.events = ev;
ledger.updatedAt = nowStr;
if isfile(ledgerFile)
    try
        ledger = jsondecode(fileread(ledgerFile));
    catch
    end
end
if ~isfield(ledger, 'events'), ledger.events = struct('id',{},'ts',{},'stage',{},'skill',{},'evidence',{},'source',{}); end
if ~isfield(ledger, 'events') || isempty(ledger.events)
    ledger.events = ev;
elseif ~isempty(ev)
    % Concatenating struct arrays requires IDENTICAL field ORDER. A ledger that
    % came back through jsondecode can have a different order than the one mk()
    % builds, and the mismatch is reported as "the structures are not
    % concatenable" rather than as an ordering problem -- so normalise first.
    ev = reorder(ev, fieldnames(ledger.events));
    old = reorder(ledger.events, fieldnames(ev));
    ledger.events = [old, ev];
end
ledger.updatedAt = char(datetime('now','Format','yyyy-MM-dd HH:mm:ss'));

fid = fopen(ledgerFile, 'w');
if fid >= 0
    fwrite(fid, jsonencode(ledger, 'PrettyPrint', true), 'char');
    fclose(fid);
end
r = ledger;
r.ledgerFile = ledgerFile;
r.appended = numel(ev);
end

% ===========================================================================
function r = do_report(ledgerFile)
stages = {'DISCOVERED','LOADED','SELECTED','WORKFLOW','ACCEPTED'};
if isfile(ledgerFile)
    L = jsondecode(fileread(ledgerFile));
    E = L.events;
else
    E = struct('id',{},'ts',{},'stage',{},'skill',{},'evidence',{},'source',{});
end

r = struct();
r.schema = 'mas-skill-audit/1';
r.generatedAt = char(datetime('now','Format','yyyy-MM-dd HH:mm:ss'));
r.stages = struct('stage', {}, 'count', {}, 'skills', {});
for k = 1:numel(stages)
    hit = {};
    for e = 1:numel(E)
        if strcmp(E(e).stage, stages{k}), hit{end+1} = E(e).skill; end %#ok<AGROW>
    end
    hit = unique(hit);
    r.stages(end+1) = struct('stage', stages{k}, 'count', numel(hit), ...
        'skills', {hit}); %#ok<AGROW>
end

% A skill that was DISCOVERED but never LOADED is the interesting case: it is
% installed and therefore claimable, but no evidence of use exists.
disc = {};
for e = 1:numel(E)
    if strcmp(E(e).stage, 'DISCOVERED'), disc{end+1} = E(e).skill; end %#ok<AGROW>
end
disc = unique(disc);
load_ = {};
for e = 1:numel(E)
    if strcmp(E(e).stage, 'LOADED'), load_{end+1} = E(e).skill; end %#ok<AGROW>
end
r.discoveredNotLoaded = setdiff(disc, unique(load_));
r.allStages = all(arrayfun(@(s) s.count > 0, r.stages));
r.verdict = tern(r.allStages, 'FULL_CHAIN_OBSERVED', 'INCOMPLETE_CHAIN');
r.detail = sprintf('%d event(s); ', numel(E));
parts = {};
for k = 1:numel(r.stages)
    parts{end+1} = sprintf('%s=%d', r.stages(k).stage, r.stages(k).count); %#ok<AGROW>
end
r.detail = [r.detail strjoin(parts, ' ')];
end

% ===========================================================================
function e = mk(stage, skill, evidence, source)
% NOTE: `char(datetime(...))` inside a struct() literal makes struct() see a
% char ARRAY and try to build a struct array, which fails. Compute the
% timestamp into a variable first -- a struct() literal containing a char
% value is only safe when the char has exactly one row.
% Also: datetime's Format does not accept a literal 'T' (it is reserved for
% ISO output); it has to be quoted as ''T''.
ts = char(datetime('now', 'Format', 'yyyy-MM-dd''T''HH:mm:ss'));
e = struct('id', 0, 'ts', ts, ...
    'stage', stage, 'skill', skill, 'evidence', evidence, 'source', source);
end

% ---------------------------------------------------------------------------
function S = reorder(S, fnames)
% Put every element's fields in the same order, so two struct arrays with the
% same fields but different orders can still be concatenated.
if isempty(S) || isempty(fnames), return; end
for k = 1:numel(S)
    s = S(k);
    t = struct();
    for q = 1:numel(fnames)
        t.(fnames{q}) = s.(fnames{q});
    end
    S(k) = t;
end
end

% ---------------------------------------------------------------------------
function s = canon_skill(name)
% Canonical skill id: underscores become hyphens. JSON field names cannot
% contain a hyphen, so jsondecode turns "matlab-orchestrator" into
% "matlab_orchestrator"; every skill name in this repository is of the form
% matlab-<domain>, so the mapping is unambiguous.
s = strrep(name, '_', '-');
end

% ---------------------------------------------------------------------------
function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
