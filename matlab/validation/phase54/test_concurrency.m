function R = test_concurrency(nRounds, nProcs, verbose)
%TEST_CONCURRENCY  Launch independent MATLAB processes running test_codegen.
%
%   R = test_concurrency()            % 3 rounds x 2 processes
%   R = test_concurrency(3, 2, true)
%
% This is a regression for the shared-fixture defect: both processes used to
% write tests/fixtures_codegen and codegen into one cwd, so one run's cleanup
% deleted the other's files (observed 10/12 and 11/12). Each run must now use
% its own fixture and working directory, report 12/12, and leave no residue.
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
    ok = all(pass == 12 & total == 12);
    rounds(end+1) = struct('round', r, 'logs', {logs}, 'pass', pass, ...
        'total', total, 'ok', ok); %#ok<AGROW>
    if verbose
        fprintf('round %d: %s (%s)\n', r, mat2str(pass), mat2str(total));
    end
end

residue = struct();
sharedDir = fullfile(tests, 'fixtures_codegen');
residue.sharedFixtureDir = isfolder(sharedDir);
residue.cwdMex = ~isempty(dir(fullfile(repo, '*.mexw64')));
cgRoot = fullfile(tempdir, 'mas_codegen_tests');
if isfolder(cgRoot)
    listing = dir(cgRoot);
    residue.tempRunDirs = sum([listing.isdir]) - 2;
else
    residue.tempRunDirs = 0;
end
R = struct('ok', all([rounds.ok]) && ~residue.sharedFixtureDir && ...
    ~residue.cwdMex && residue.tempRunDirs == 0, 'rounds', rounds, ...
    'residue', residue, 'nRounds', nRounds, 'nProcs', nProcs, ...
    'runRoot', runRoot, 'logRoot', logRoot);
fprintf('test_concurrency: %d/%d rounds clean; residue shared=%d mex=%d tempDirs=%d\n', ...
    sum([rounds.ok]), nRounds, residue.sharedFixtureDir, residue.cwdMex, ...
    residue.tempRunDirs);
end

function p = fwd(p)
p = strrep(p, '\', '/');
end
