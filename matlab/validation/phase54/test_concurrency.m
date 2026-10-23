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

stamp = datestr(now, 'yyyymmdd_HHMMSS');
runRoot = fullfile(repo, 'artifacts', 'phase54', 'concurrency_runs', stamp);
logRoot = fullfile(repo, 'artifacts', 'phase54', 'evidence', 'concurrency_regression', stamp);
mkdir(runRoot);
mkdir(logRoot);
rootAtStart = mexInRepo(repo);
tempAtStart = codegenTempDirs();
rounds = struct('round', {}, 'logs', {}, 'pass', {}, 'total', {}, 'ok', {});
for r = 1:nRounds
    order = randperm(nProcs);
    pids = zeros(1, nProcs);
    logs = cell(1, nProcs);
    for j = 1:nProcs
        k = order(j);
        logFile = fullfile(logRoot, sprintf('round%d_proc%d.log', r, k));
        exitFile = fullfile(runRoot, sprintf('round%d_proc%d.exit', r, k));
        bat = fullfile(runRoot, sprintf('round%d_proc%d.bat', r, k));
        fid = fopen(bat, 'w');
        fprintf(fid, '@echo off\r\n');
        fprintf(fid, '"%s" -batch "addpath(''%s''); addpath(''%s''); test_codegen(true);" > "%s" 2>&1\r\n', ...
            exe, fwd(scripts), fwd(tests), fwd(logFile));
        fprintf(fid, 'echo %%ERRORLEVEL%% > "%s"\r\n', fwd(exitFile));
        fclose(fid);
        cmd = sprintf('start "" /B "%s"', fwd(bat));
        [st, ~] = system(cmd);
        if st ~= 0
            error('test_concurrency:start', 'could not start %s', bat);
        end
        pids(k) = 1;
        logs{k} = logFile;
        pause(randi([0 4]));
    end
    % Wait for all logs to finish, then collect.
    deadline = tic;
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
    pass = zeros(1, nProcs);
    total = zeros(1, nProcs);
    for k = 1:nProcs
        if isfile(logs{k})
            txt = fileread(logs{k});
            tok = regexp(txt, 'test_codegen:\s*(\d+)/(\d+)\s*passed', 'tokens', 'once');
            if ~isempty(tok)
                pass(k) = str2double(tok{1});
                total(k) = str2double(tok{2});
            end
        end
    end
    % What is under test is that two processes running at the same time each
    % report a COMPLETE, untruncated suite -- not the number 12. The case count
    % moves (Phase 5.6 added the empty-message codegen error case, 12 -> 13), and
    % a hard-coded 12 would make this regression fail on a green suite. A lower
    % bound still catches a run that died part way through.
    ok = all(pass == total) && all(total >= 12) && all(pass > 0);
    rounds(end+1) = struct('round', r, 'logs', {logs}, 'pass', pass, ...
        'total', total, 'ok', ok); %#ok<AGROW>
    if verbose
        fprintf('round %d: %s (%s)\n', r, mat2str(pass), mat2str(total));
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
tempNow = codegenTempDirs();
residue.tempRunDirsBefore = tempAtStart;
residue.tempRunDirs = numel(setdiff(tempNow, tempAtStart));
residue.tempRunDirsNow = numel(tempNow);
R = struct('ok', all([rounds.ok]) && ~residue.sharedFixtureDir && ...
    ~residue.cwdMex && residue.tempRunDirs == 0, 'rounds', rounds, ...
    'residue', residue, 'nRounds', nRounds, 'nProcs', nProcs, ...
    'runRoot', runRoot, 'logRoot', logRoot);
fprintf('test_concurrency: %d/%d rounds clean; residue shared=%d newMex=%d newTempDirs=%d (pre-existing: %d mex, %d temp)\n', ...
    sum([rounds.ok]), nRounds, residue.sharedFixtureDir, residue.cwdMex, ...
    residue.tempRunDirs, numel(rootAtStart), numel(tempAtStart));
end

function p = fwd(p)
p = strrep(p, '\', '/');
end

function names = codegenTempDirs()
root = fullfile(tempdir, 'mas_codegen_tests');
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

function m = mexInRepo(r)
d = dir(fullfile(r, '*.mexw64'));
m = cellfun(@(s) fullfile(d(s).folder, d(s).name), num2cell(1:numel(d)), 'UniformOutput', false);
end
