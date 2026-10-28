function r = test_p56_session_reset(verbose)
%TEST_P56_SESSION_RESET  The session reset must achieve the blind state it claims.
%
%   r = test_p56_session_reset()
%
% p56_session_reset is the control that makes the Phase 5.6 tool ledger readable:
% every episode runs in the SAME long-lived MATLAB session, so an arm that did
% addpath('<its tools>/scripts') hands the next -- supposedly blind -- arm a
% working tool, and a Read/Grep ledger cannot see it because no file was opened.
% The function was hand-verified between the probe and the pass-1 episodes but
% never tested, which means the claim "the session no longer carries a tool" was
% only ever backed by one operator reading one output.
%
% So this test checks the four things the reset promises, and nothing that lives
% outside its own scratch tree:
%
%   1. a path entry under a <neutralDir>/skills root is removed and returned,
%      while an entry that merely happens to be a temp dir is left alone;
%   2. a mas_* symbol reachable only from that entry is unreachable afterwards;
%   3. cd is released out of the directory it was standing in (on Windows an
%      arm directory that still holds pwd cannot be deleted);
%   4. the reset is recorded, is repeatable, and does not pretend to clear
%      variables it cannot reach.
%
% The scratch root uses the process temporary directory, outside the repository and
% phase56 bundle, and the test restores the path and pwd before returning.

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
addpath(here);

startPwd = pwd;
pathBefore = strsplit(path, pathsep);
C = {};

tt = tempname;
if ~exist(tt, 'dir'), mkdir(tt); end
restoreGuard = onCleanup(@() cleanupState(tt, startPwd, pathBefore)); %#ok<NASGU>

leakDir = fullfile(tt, 'skills', 'leak');      % under a <neutralDir>/skills root
other = fullfile(tt, 'elsewhere');             % on the path but under no root
mkdir(leakDir); mkdir(other);
fid = fopen(fullfile(leakDir, 'mas_ber_check.m'), 'w');
fwrite(fid, sprintf('function v = mas_ber_check(varargin)\nv = [];\nend\n'), 'char');
fclose(fid);

% ---- 1/2/3. one reset, from inside the directory it must release -------------
addpath(leakDir); addpath(other); rehash;
cd(leakDir);
stubResolved = char(which('mas_ber_check'));
chk('stubReachableBefore', ~isempty(stubResolved) && under(stubResolved, leakDir), ...
    sprintf('which(mas_ber_check) = [%s]', stubResolved));

R = p56_session_reset(tt, fullfile(tt, 'reset_log.jsonl'));
rehash;
paths = R.removedPaths;
if ~iscell(paths), paths = cellstr(string(paths)); end
chk('leakEntryRemoved', anyUnder(paths, leakDir), joinr(paths));
chk('unrelatedEntryKept', ~anyUnder(paths, other), joinr(paths));
chk('stubUnreachableAfter', ~resolvesUnder(which('mas_ber_check'), leakDir), ...
    sprintf('still resolves to %s', show(which('mas_ber_check'))));
chk('noRootPathLeft', ~R.after.pathHasBenchmarkEntries, int2str(R.after.pathHasBenchmarkEntries));
chk('pwdReleasedToNeutralDir', dirEq(R.after.pwd, tt), char(R.after.pwd));

% ---- 4. the record says what it did, and repeats cleanly ---------------------
logFile = fullfile(tt, 'reset_log.jsonl');
txt = fileread(logFile);
lines = strsplit(strtrim(txt), newline);
chk('logOneLinePerCall', numel(lines) >= 1 && ~isempty(strfind(txt, 'mas-phase56-session-reset/1')), ...
    sprintf('%d line(s)', numel(lines)));
chk('documentsItsOwnLimitation', ~isempty(strfind(lower(R.limitation), 'variable')), ...
    'a reset that claims to clear the frame would be a false control');

R2 = p56_session_reset(tt, logFile);
rp = R2.removedPaths;
if ~iscell(rp), rp = cellstr(string(rp)); end
chk('secondRunRemovesNothing', isempty(rp), joinr(rp));

% ---- 5. production semantics: rooted at the repo, it really removes the tools -
% This is what an episode coordinator actually calls. The entries are added back
% from the returned list before the suite ends, so the rest of the gate is
% unaffected.
skillDirs = {fullfile(repo, 'skills', 'matlab-signal-vision-ai', 'scripts'), ...
             fullfile(repo, 'skills', 'matlab-data-analysis', 'scripts')};
for k = 1:numel(skillDirs), if isfolder(skillDirs{k}), addpath(skillDirs{k}); end, end
rehash;
beforeSym = symSnapshot();
P = p56_session_reset(repo, fullfile(tt, 'reset_repo_log.jsonl'));
rehash;
pp = P.removedPaths;
if ~iscell(pp), pp = cellstr(string(pp)); end
chk('repoResetHadSomethingToRemove', numel(pp) > 0, joinr(pp));
chk('repoResetLostEveryMasSymbol', isempty(symResolvable()), ...
    symResolvable());
chk('repoResetOkFlagAgreesWithItsOwnTest', P.ok == (dirEq(P.after.pwd, repo) && ...
    isempty(P.after.masResolvable) && ~P.after.pathHasBenchmarkEntries), ...
    sprintf('ok=%d, resolvable=[%s]', P.ok, show(P.after.masResolvable)));
for k = 1:numel(pp), addpath(pp{k}); end
rehash;
chk('pathRestored', numel(strsplit(path, pathsep)) >= numel(pathBefore) && ...
    ~isempty(which('mas_ber_check')), int2str(numel(strsplit(path, pathsep))));
chk('beforeSnapshotWasTakenWhileLoaded', ~isempty(beforeSym), show(beforeSym));

cd(startPwd);
ps = cellfun(@(s) strcmp(s.status, 'pass'), C);
nP = nnz(ps);
r = struct('nPass', nP, 'nTotal', numel(C), 'checks', {C}, 'pass', nP == numel(C));
if verbose
    for k = 1:numel(C)
        fprintf('  [%s] %-32s %s\n', upper(string(C{k}.status)), C{k}.id, C{k}.detail);
    end
    fprintf('\n---- %d / %d session-reset checks passed ----\n', nP, numel(C));
end

function chk(id, cond, detail)
if cond, st = 'pass'; else, st = 'fail'; end
C{end+1} = struct('id', id, 'status', st, 'detail', detail);
end

function cleanupState(dir_, p, entries)
% The scratch tree must not outlive the suite, but it also cannot be deleted while
% a process still stands inside it (the same Windows lock that made the real
% arm directories undeletable in the probe episodes). The reset leaves entries
% that are not under a root, so this suite's own non-root scratch entry has to be
% taken back out here -- otherwise deleting the tree warns from inside the gate.
cd(p);
for e = strsplit(path, pathsep)
    if under(strtrim(e{1}), dir_), rmpath(strtrim(e{1})); end
end
rmdir(dir_, 's');
for k = 1:numel(entries)
    e = strtrim(entries{k});
    if ~isempty(e) && isfolder(e) && ~any(strcmp(e, strsplit(path, pathsep)))
        addpath(e);
    end
end
rehash;
end

function s = show(x)
if isempty(x), s = '(empty)'; elseif iscell(x), s = strjoin(x(:)', ' | '); else, s = char(string(x)); end
end

function tf = under(p, root)
if isempty(p), tf = false; return; end
a = lower(strrep(char(p), '\', '/'));
b = lower(strrep(char(root), '\', '/'));
tf = ~isempty(strfind(a, b));
end

function tf = resolvesUnder(p, root)
tf = ~isempty(p) && under(p, root);
end

function tf = anyUnder(cells, root)
tf = false;
for k = 1:numel(cells)
    if under(cells{k}, root), tf = true; return; end
end
end

function s = joinr(cells)
if isempty(cells), s = '(nothing removed)'; else, s = strjoin(cells(:)', ' | '); end
s = s(1:min(numel(s), 160));
end

function tf = dirEq(a, b)
tf = strcmpi(strrep(char(a), '\', '/'), strrep(char(b), '\', '/'));
end

function s = symResolvable()
names = {'mas_ber_check', 'mas_stat_verdict', 'mas_ode_check', 'mas_ctrl_analyze', 'mas_grade'};
hit = {};
for k = 1:numel(names)
    w = which(names{k});
    if ~isempty(w), hit{end+1} = [names{k} ' -> ' w]; end %#ok<AGROW>
end
s = strjoin(hit, '; ');
end

function s = symSnapshot()
% Recorded only so a reader can see the reset ran against a loaded session; the
% reset function itself also snapshots, but its snapshot is taken before this
% suite's own addpath of the repo skill directories.
s = symResolvable();
end
end
