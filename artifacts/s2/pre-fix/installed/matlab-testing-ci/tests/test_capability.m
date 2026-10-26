function res = test_capability(verbose)
%TEST_CAPABILITY  Pins the capability-matrix consistency checker.
%
%   res = test_capability()
%
% The interesting cases are the NEGATIVE ones. A consistency checker that has
% only ever seen a consistent repository has not been shown to detect anything,
% and a checker that cries wolf gets ignored -- which is worse than no checker,
% because the matrix is what people route work based on.
%
% So this suite copies the real matrix, breaks it in four different ways, and
% asserts the corresponding check fires. The real file is never modified.

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
addpath(fullfile(fileparts(here), 'scripts'));
realFile = fullfile(repo, 'skills', 'capability-matrix.json');

scratch = fullfile(tempdir, 'mas_cap_check');
if ~exist(scratch, 'dir'), mkdir(scratch); end
cleanup = onCleanup(@() rmdir(scratch, 's'));

T = struct('name', {}, 'fn', {}, 'expect', {});

% ---- the real repository must be consistent right now -------------------
T(end+1) = mk('real matrix is consistent',    @() realConsistent(realFile),    true);
T(end+1) = mk('real inventory is non-trivial',@() realInventory(realFile),    true);

% ---- negative controls: each break must be caught -----------------------
T(end+1) = mk('neg: missing tool is caught',  @() missingToolCaught(realFile, scratch),    true);
T(end+1) = mk('neg: ghost tool is caught',    @() ghostToolCaught(realFile, scratch),      true);
T(end+1) = mk('neg: wrong owner is caught',   @() wrongOwnerCaught(realFile, scratch),     true);
T(end+1) = mk('neg: stale summary is caught',  @() staleSummaryCaught(realFile, scratch),   true);
T(end+1) = mk('neg: stale tool summary is caught', @() staleToolSummaryCaught(realFile, scratch), true);
T(end+1) = mk('neg: evidence-free VERIFIED is caught', ...
              @() evidenceFreeCaught(realFile, scratch),                                  true);

% -------------------------------------------------------------------------
n = numel(T);
pass = false(n,1); got = cell(n,1);
for k = 1:n
    try
        got{k} = T(k).fn();
    catch ME
        got{k} = sprintf('<EXC %s>', ME.message);
    end
    if ischar(T(k).expect)
        pass(k) = ischar(got{k}) && strcmp(got{k}, T(k).expect);
    else
        pass(k) = isequal(logical(got{k}), logical(T(k).expect));
    end
    if verbose
        if pass(k), s = 'PASS'; else, s = 'FAIL'; end
        fprintf('  %-4s %-36s\n', s, T(k).name);
    end
end
fprintf('test_capability: %d / %d passed\n', sum(pass), n);
res = struct();
res.nPass = sum(pass);
res.nTotal = n;
res.pass = all(pass);
res.cases = {T.name};
end

% ===========================================================================
function v = realConsistent(f)
r = mas_capability_check();
v = r.ok && strcmp(r.verdict, 'CONSISTENT');
end

function v = realInventory(f)
M = jsondecode(fileread(f));
nTools = numel(fieldnames(M.tools));
nCaps = 0;
f = fieldnames(M.skills);
for k = 1:numel(f)
    caps = M.skills.(f{k});
    cf = fieldnames(caps);
    for q = 1:numel(cf)
        if isstruct(caps.(cf{q})) && isfield(caps.(cf{q}), 'status'), nCaps = nCaps + 1; end
    end
end
% A matrix with almost nothing in it would pass every consistency check while
% answering none of the questions it exists for.
v = nTools >= 25 && nCaps >= 40;
end

% ===========================================================================
function v = missingToolCaught(realFile, scratch)
f = broken(realFile, scratch, 'dropTool');
r = mas_capability_check_at(f);
v = ~r.ok && any(strcmp({r.checks.id}, 'tools')) && contains(detailOf(r, 'tools'), 'MISSING');
end

function v = ghostToolCaught(realFile, scratch)
f = broken(realFile, scratch, 'addGhost');
r = mas_capability_check_at(f);
v = ~r.ok && contains(detailOf(r, 'tools'), 'GHOST');
end

function v = wrongOwnerCaught(realFile, scratch)
f = broken(realFile, scratch, 'wrongOwner');
r = mas_capability_check_at(f);
v = ~r.ok && any(strcmp({r.checks.id}, 'skillOwners'));
end

function v = staleSummaryCaught(realFile, scratch)
f = broken(realFile, scratch, 'bumpSummary');
r = mas_capability_check_at(f);
v = ~r.ok && any(strcmp({r.checks.id}, 'summary'));
end

function v = staleToolSummaryCaught(realFile, scratch)
f = broken(realFile, scratch, 'bumpToolSummary');
r = mas_capability_check_at(f);
v = ~r.ok && any(strcmp({r.checks.id}, 'summary')) && ...
    contains(detailOf(r, 'summary'), 'tool VERIFIED');
end

function v = evidenceFreeCaught(realFile, scratch)
f = broken(realFile, scratch, 'stripEvidence');
r = mas_capability_check_at(f);
v = ~r.ok && any(strcmp({r.checks.id}, 'evidence'));
end

% ===========================================================================
% mas_capability_check reads a fixed path, so the negative controls run against
% a full COPY of the repository tree (skills/ only, which is all it inspects).
function r = mas_capability_check_at(matFile)
r = mas_capability_check('all', matFile);
end

function d = detailOf(r, id)
d = '';
for k = 1:numel(r.checks)
    if strcmp(r.checks(k).id, id), d = r.checks(k).detail; return; end
end
end

% ===========================================================================
function t = mk(name, fn, expect)
t = struct('name', name, 'fn', fn, 'expect', expect);
end

function f = broken(realFile, scratch, mode)
[~, nm] = fileparts(realFile);
[~, nm] = fileparts(nm);
f = fullfile(scratch, [nm '.json']);
M = jsondecode(fileread(realFile));
switch mode
    case 'dropTool'
        k = fieldnames(M.tools);
        M.tools = rmfield(M.tools, k{1});
    case 'addGhost'
        M.tools.mas_this_tool_does_not_exist = struct('skill','matlab-runner', ...
            'status','VERIFIED','tests','','what','phantom');
    case 'wrongOwner'
        k = fieldnames(M.tools);
        M.tools.(k{1}).skill = 'matlab-not-a-skill';
    case 'bumpSummary'
        M.summary.capability_counts.VERIFIED = 999;
    case 'bumpToolSummary'
        M.summary.tool_counts.VERIFIED = 999;
    case 'stripEvidence'
        f2 = fieldnames(M.skills);
        M.skills.(f2{1}).weighted_routing.evidence = 'trust me';
end
fid = fopen(f, 'w');
if fid >= 0, fwrite(fid, jsonencode(M, 'PrettyPrint', true), 'char'); fclose(fid); end
end

