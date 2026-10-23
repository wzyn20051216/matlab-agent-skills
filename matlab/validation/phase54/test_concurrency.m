function R = test_concurrency(nRounds, nProcs, verbose)
%TEST_CONCURRENCY  Launch independent MATLAB processes running test_codegen.
%
%   R = test_concurrency()            % 3 rounds x 2 processes
%   R = test_concurrency(3, 2, true)
%
% This is a regression for the shared-fixture defect: both processes used to
% write tests/fixtures_codegen and codegen into one cwd, so one run's cleanup
% deleted the other's files (observed 10/12 and 11/12). Each run must now use
% its own fixture and working directory, report every case it owns, and leave no
% residue.
%
% ISOLATION IS VERIFIED; HIGH-LOAD STABILITY IS NOT
% Every process gets a session id (MAS_RUN_SESSION) and a session root under
% MAS_CODEGEN_RUN_ROOT. The driver checks that each log carries its own session
% and no other process's session, that each fixture path is inside its own
% session root, and that no session directory survives the run. Those are
% structural ownership facts. Completeness at 2 concurrent compiles is recorded
% but is not a stability claim; a run with nProcs >= 4 is labelled EXPLORATORY
% and a degraded round is not attributed to resource contention without a
% controlled comparison.
%
% The driver starts each process through a generated .bat so quoting is stable
% on Windows, gives each a random 0-4 s head start, and waits for completion.
% It never deletes a directory it did not create; residue is reported, not
% cleaned.
if nargin < 1 || isempty(nRounds), nRounds = 3; end
if nargin < 2 || isempty(nProcs), nProcs = 2; end
if nargin < 3, verbose = true; end

repo = fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
scripts = fullfile(repo, 'skills', 'matlab-codegen-deploy', 'scripts');
tests = fullfile(repo, 'skills', 'matlab-codegen-deploy', 'tests');
exe = fullfile(matlabroot, 'bin', 'matlab.exe');
if ~isfile(exe), exe = fullfile(matlabroot, 'bin', 'matlab'); end

% The driver pid in the stamp keeps two overlapping drivers from writing the
% same log paths -- the exact condition under which Phase 5.6 lost attribution.
stamp = sprintf('%s_p%d', datestr(now, 'yyyymmdd_HHMMSS'), feature('getpid'));
runRoot = fullfile(repo, 'artifacts', 'phase54', 'concurrency_runs', stamp);
logRoot = fullfile(repo, 'artifacts', 'phase54', 'evidence', 'concurrency_regression', stamp);
mkdir(runRoot);
mkdir(logRoot);
runBase = fullfile(tempdir, 'mas_codegen_tests');
if ~isfolder(runBase), mkdir(runBase); end
rootAtStart = mexInRepo(repo);
tempAtStart = list_dirs(runBase);
rootFilesAtStart = list_files(runBase);
rounds = struct('round', {}, 'logs', {}, 'sessions', {}, 'fixtureDir', {}, ...
    'pass', {}, 'total', {}, 'ok', {}, 'timedOut', {}, 'sessionInLog', {}, ...
    'crossSession', {}, 'fixtureOwned', {}, 'logSha256', {});
for r = 1:nRounds
    order = randperm(nProcs);
    logs = cell(1, nProcs);
    sessions = cell(1, nProcs);
    for j = 1:nProcs
        k = order(j);
        % Session id is per process, not per driver: two processes of the same
        % round must be distinguishable in their own logs.
        session = sprintf('r%02d_p%d_%s_%06d', r, k, stamp, randi(999999));
        sessions{k} = session;
        logFile = fullfile(logRoot, sprintf('round%d_proc%d.log', r, k));
        exitFile = fullfile(runRoot, sprintf('round%d_proc%d.exit', r, k));
        bat = fullfile(runRoot, sprintf('round%d_proc%d.bat', r, k));
        fid = fopen(bat, 'w');
        fprintf(fid, '@echo off\r\n');
        fprintf(fid, 'set "MAS_RUN_SESSION=%s"\r\n', session);
        fprintf(fid, 'set "MAS_CODEGEN_RUN_ROOT=%s"\r\n', fwd(runBase));
        fprintf(fid, '"%s" -batch "addpath(''%s''); addpath(''%s''); test_codegen(true);" > "%s" 2>&1\r\n', ...
            exe, fwd(scripts), fwd(tests), fwd(logFile));
        fprintf(fid, 'echo %%ERRORLEVEL%% > "%s"\r\n', fwd(exitFile));
        fclose(fid);
        cmd = sprintf('start "" /B "%s"', fwd(bat));
        [st, ~] = system(cmd);
        if st ~= 0
            error('test_concurrency:start', 'could not start %s', bat);
        end
        logs{k} = logFile;
        pause(randi([0 4]));
    end
    % Wait for all logs to finish, then collect.
    deadline = tic;
    timedOut = false;
    while toc(deadline) < 420
        done = true;
        for k = 1:nProcs
            if ~isfile(logs{k}) || ~contains(fileread(logs{k}), 'test_codegen:')
                done = false;
            end
        end
        if done, break; end
        pause(2);
    end
    if ~done, timedOut = true; end
    pass = zeros(1, nProcs);
    total = zeros(1, nProcs);
    sessionInLog = false(1, nProcs);
    crossSession = true(1, nProcs);
    fixtureOwned = false(1, nProcs);
    logSha = cell(1, nProcs);
    fixtureDir = cell(1, nProcs);
    for k = 1:nProcs
        if ~isfile(logs{k}), continue; end
        txt = fileread(logs{k});
        tok = regexp(txt, 'test_codegen:\s*(\d+)/(\d+)\s*passed', 'tokens', 'once');
        if ~isempty(tok)
            pass(k) = str2double(tok{1});
            total(k) = str2double(tok{2});
        end
        st = regexp(txt, 'test_codegen_session:\s*(\S+)', 'tokens', 'once');
        seen = '';
        if ~isempty(st), seen = st{1}; end
        fx = regexp(txt, 'test_codegen_fixture:\s*(.+)', 'tokens', 'once');
        if ~isempty(fx), fixtureDir{k} = strtrim(fx{1}); end
        sessionInLog(k) = strcmp(seen, sessions{k});
        others = sessions(setdiff(1:nProcs, k));
        crossSession(k) = any(cellfun(@(s) ~isempty(strfind(txt, s)), others));
        wantPrefix = [fullfile(runBase, sessions{k}) filesep];
        fixtureOwned(k) = ~isempty(fixtureDir{k}) && ...
            strncmpi(fixtureDir{k}, wantPrefix, numel(wantPrefix));
        logSha{k} = sha256_file(logs{k});
    end
    % What is under test is that two processes running at the same time each
    % report a COMPLETE, untruncated suite -- not a fixed number. The case count
    % moves (Phase 5.6 added the empty-message codegen error case, 12 -> 13;
    % Phase 5.7 added the link-failure and string-entry diagnostics, 13 -> 15),
    % and a hard-coded count would make this regression fail on a green suite. A
    % lower bound still catches a run that died part way through.
    ok = ~timedOut && all(pass == total) && all(total >= 12) && all(pass > 0) && ...
        all(sessionInLog) && ~any(crossSession) && all(fixtureOwned);
    rounds(end+1) = struct('round', r, 'logs', {logs}, 'sessions', {sessions}, ...
        'fixtureDir', {fixtureDir}, 'pass', pass, 'total', total, 'ok', ok, ...
        'timedOut', timedOut, 'sessionInLog', sessionInLog, ...
        'crossSession', crossSession, 'fixtureOwned', fixtureOwned, ...
        'logSha256', {logSha}); %#ok<AGROW>
    if verbose
        fprintf('round %d: pass %s total %s sessions %d/%d own, cross=%d, fixture=%d/%d\n', ...
            r, mat2str(pass), mat2str(total), sum(sessionInLog), nProcs, ...
            any(crossSession), sum(fixtureOwned), nProcs);
    end
end

residue = struct();
sharedDir = fullfile(tests, 'fixtures_codegen');
residue.sharedFixtureDir = isfolder(sharedDir);
% A .mexw64 sitting in the repo root is not automatically this run's doing: the
% suite ran here earlier in the day with the repository as its cwd. Flagging a
% file that predates the run would make a clean run look dirty, so only NEW
% repo-root output is residue; whatever was already there is listed instead.
residue.cwdMexBefore = rootAtStart;
residue.cwdMex = any(~ismember(mexInRepo(repo), rootAtStart));
residue.preExistingMex = rootAtStart;
% Same attribution rule for the build root: a directory left behind by a run
% that was killed (a suspended session, a Ctrl-C) is not this run's leak. Only a
% directory that appeared while this run was going counts as residue; whatever
% was already there is named in the record instead.
tempNow = list_dirs(runBase);
residue.tempRunDirsBefore = tempAtStart;
residue.tempRunDirs = numel(setdiff(tempNow, tempAtStart));
residue.tempRunDirsNow = numel(tempNow);
residue.newTempRunDirs = setdiff(tempNow, tempAtStart);
residue.newRootFiles = setdiff(list_files(runBase), rootFilesAtStart);
allSessions = [rounds.sessions];
left = allSessions(cellfun(@(s) isfolder(fullfile(runBase, s)), allSessions));
residue.sessionDirsLeft = left;

isolation = struct();
isolation.scope = 'log identity, fixture/build directory ownership, and residue attribution';
isolation.sessionIdPerProcess = true;
isolation.sessionInLog = all([rounds.sessionInLog]);
isolation.crossSessionContamination = any([rounds.crossSession]);
isolation.fixtureUnderSessionRoot = all([rounds.fixtureOwned]);
isolation.sharedFixtureDirAbsent = ~residue.sharedFixtureDir;
isolation.newRepoMex = residue.cwdMex;
isolation.newTempDirs = residue.tempRunDirs;
isolation.newRootFiles = residue.newRootFiles;
isolation.sessionDirsLeft = left;
isolation.verified = isolation.sessionInLog && ...
    ~isolation.crossSessionContamination && isolation.fixtureUnderSessionRoot && ...
    isolation.sharedFixtureDirAbsent && ~isolation.newRepoMex && ...
    isolation.newTempDirs == 0 && isempty(residue.newRootFiles) && isempty(left);

stability = struct();
stability.nProcs = nProcs;
stability.roundsComplete = sum([rounds.ok]);
stability.roundsTotal = nRounds;
if nProcs >= 4
    stability.status = 'EXPLORATORY';
    stability.note = ['High-load observation at nProcs >= 4. It is not a controlled ' ...
        'stability experiment and a degraded round is recorded without being ' ...
        'attributed to resource contention.'];
else
    stability.status = 'NOT CLAIMED';
    stability.note = ['Isolation is verified at this concurrency; numerical stability ' ...
        'under high load is a separate question and is not claimed by this run.'];
end

evDir = fullfile(repo, 'artifacts', 'phase57', 'task7');
if ~isfolder(evDir), mkdir(evDir); end
evFile = fullfile(evDir, sprintf('concurrency_n%d_%s.json', nProcs, stamp));
R = struct('ok', isolation.verified && all([rounds.ok]), ...
    'rounds', rounds, 'residue', residue, 'isolation', isolation, ...
    'stability', stability, 'nRounds', nRounds, 'nProcs', nProcs, ...
    'runRoot', runRoot, 'logRoot', logRoot, 'runBase', runBase, ...
    'evidenceFile', evFile);
fid = fopen(evFile, 'w');
if fid >= 0
    fprintf(fid, '%s', jsonencode(R, 'PrettyPrint', true));
    fclose(fid);
end
fprintf('test_concurrency: %d/%d rounds clean; isolation=%d (own=%d cross=%d fixture=%d) residue shared=%d newMex=%d newTempDirs=%d left=%d\n', ...
    sum([rounds.ok]), nRounds, isolation.verified, isolation.sessionInLog, ...
    isolation.crossSessionContamination, isolation.fixtureUnderSessionRoot, ...
    residue.sharedFixtureDir, residue.cwdMex, residue.tempRunDirs, numel(left));
fprintf('test_concurrency: stability=%s (%d/%d rounds complete at nProcs=%d)\n', ...
    stability.status, stability.roundsComplete, stability.roundsTotal, nProcs);
end

function p = fwd(p)
p = strrep(p, '\', '/');
end

function names = list_dirs(root)
names = {};
if ~isfolder(root), return; end
d = dir(root);
for k = 1:numel(d)
    if d(k).isdir && ~any(strcmp(d(k).name, {'.', '..'}))
        names{end+1} = d(k).name; %#ok<AGROW>
    end
end
names = sort(names);
end

function names = list_files(root)
names = {};
if ~isfolder(root), return; end
d = dir(root);
for k = 1:numel(d)
    if ~d(k).isdir
        names{end+1} = d(k).name; %#ok<AGROW>
    end
end
names = sort(names);
end

function m = mexInRepo(r)
d = dir(fullfile(r, '*.mexw64'));
m = cellfun(@(s) fullfile(d(s).folder, d(s).name), num2cell(1:numel(d)), 'UniformOutput', false);
end

function h = sha256_file(p)
fid = fopen(p, 'r');
if fid < 0, h = ''; return; end
b = fread(fid, Inf, '*uint8');
fclose(fid);
if isempty(b), return; end
md = java.security.MessageDigest.getInstance('SHA-256');
d = typecast(md.digest(b), 'uint8');
h = lower(reshape(dec2hex(d)', 1, []));
end
