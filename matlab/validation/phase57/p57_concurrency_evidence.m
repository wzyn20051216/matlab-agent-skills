function R = p57_concurrency_evidence(runStress)
%P57_CONCURRENCY_EVIDENCE  Task 7 evidence: isolation run + preserved overlap exhibit.
%
%   R = p57_concurrency_evidence()        % standard 3 rounds x 2 processes
%   R = p57_concurrency_evidence(true)    % plus one EXPLORATORY 1 x 4 stress round
%
% Writes artifacts/phase57/task7/concurrency_evidence_<stamp>.json.
%
% Two different questions are kept apart:
%   isolation  -- do processes own their logs, fixture dirs and build trees?
%                 This is checked structurally and can PASS or FAIL.
%   stability  -- does the suite still complete under high load? The standard
%                 2-process run is not a stability experiment; the optional
%                 4-process round is labelled EXPLORATORY and is never counted
%                 as evidence of a resource race.
%
% The Phase 5.6 overlap logs (six logs, all 11/13, byte-identical, no process
% identity) are read and hashed, not copied or edited. They are preserved as an
% observed degradation under overlapping drivers; causation is NOT established.
if nargin < 1, runStress = false; end

repo = fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
addpath(fullfile(repo, 'matlab', 'validation', 'phase54'));
outDir = fullfile(repo, 'artifacts', 'phase57', 'task7');
if ~isfolder(outDir), mkdir(outDir); end
stamp = sprintf('%s_p%d', datestr(now, 'yyyymmdd_HHMMSS'), feature('getpid'));

overlap = preserve_overlap(repo);
base = test_concurrency(3, 2, true);

stress = struct('status', 'NOT RUN', 'reason', 'not requested');
if runStress
    s = test_concurrency(1, 4, true);
    stress = struct('status', 'EXPLORATORY', ...
        'note', ['High-load observation only. A degraded round here is recorded as an ' ...
        'observation, not attributed to resource contention; no controlled comparison ' ...
        'was run.'], 'result', s);
end

compiler = '';
try
    cc = mex.getCompilerConfigurations('C');
    if ~isempty(cc), compiler = cc(1).Name; end
catch
end

R = struct();
R.phase = '5.7';
R.task = 7;
R.generatedAt = datestr(now, 'yyyy-mm-dd HH:MM:SS');
R.matlabVersion = version;
R.compiler = compiler;
R.phase56Overlap = overlap;
R.isolationRun = base;
R.stressObservation = stress;
R.isolation = base.isolation;
R.stability = base.stability;
R.pass = base.ok && (~overlap.available || overlap.preserved);
R.evidenceFile = fullfile(outDir, sprintf('concurrency_evidence_%s.json', stamp));
fid = fopen(R.evidenceFile, 'w');
if fid >= 0
    fprintf(fid, '%s', jsonencode(R, 'PrettyPrint', true));
    fclose(fid);
end
fprintf('p57_concurrency_evidence: pass=%d isolation=%d phase56Preserved=%d stress=%s\n', ...
    R.pass, base.isolation.verified, overlap.preserved, stress.status);
end

% ===========================================================================
function E = preserve_overlap(repo)
E = struct();
E.dir = fullfile(repo, 'artifacts', 'phase54', 'evidence', ...
    'concurrency_regression', '20261022_230327');
E.available = isfolder(E.dir);
E.preserved = false;
E.files = struct('name', {}, 'bytes', {}, 'sha256', {}, 'pass', {}, 'total', {}, 'failedCases', {});
E.identicalContent = false;
E.summary = '';
E.attribution = ['NOT POSSIBLE: these logs carry no session or process id, so a log ' ...
    'cannot be tied to the process that wrote it.'];
E.causation = 'NOT ESTABLISHED';
E.interpretation = ['Six logs, all 11/13, byte-identical, from two overlapping drivers. ' ...
    'This is consistent with interference between concurrent runs, but the drivers were ' ...
    'not isolated and no controlled comparison exists, so resource contention is not ' ...
    'asserted. The data is preserved as an observed degradation only and is not used as ' ...
    'a formal conclusion.'];
if ~E.available
    E.summary = 'Phase 5.6 overlap logs are not present in this checkout.';
    return;
end
d = dir(fullfile(E.dir, '*.log'));
hashes = cell(1, numel(d));
for k = 1:numel(d)
    p = fullfile(E.dir, d(k).name);
    txt = fileread(p);
    tok = regexp(txt, 'test_codegen:\s*(\d+)/(\d+)\s*passed', 'tokens', 'once');
    pnum = NaN; tnum = NaN;
    if ~isempty(tok)
        pnum = str2double(tok{1}); tnum = str2double(tok{2});
    end
    lines = regexp(txt, '\r?\n', 'split');
    failed = {};
    for j = 1:numel(lines)
        t = strtrim(lines{j});
        % Anchor at the line start: a PASS line whose case NAME contains "FAIL"
        % ("verify: FAIL on bad codegen input") is not a failed case.
        if ~isempty(regexp(t, '^FAIL\s+', 'once'))
            failed{end+1} = regexprep(t, '^FAIL\s+', ''); %#ok<AGROW>
        end
    end
    hashes{k} = sha256_file(p);
    E.files(end+1) = struct('name', d(k).name, 'bytes', d(k).bytes, ...
        'sha256', hashes{k}, 'pass', pnum, 'total', tnum, ...
        'failedCases', {failed});
end
E.identicalContent = numel(unique(hashes)) == 1;
complete = numel(E.files) == 6 && all([E.files.pass] == 11) && all([E.files.total] == 13);
E.preserved = complete && E.identicalContent && all(~cellfun(@isempty, hashes));
E.summary = sprintf(['%d logs, %d x 11/13, identical content=%d. The two failing cases ' ...
    'are the build-dependent ones (verify PASS and goldenFcn mismatch); the logs print ' ...
    'case names only -- Phase 5.6 fixed that reporting gap afterwards.'], ...
    numel(E.files), sum([E.files.pass] == 11 & [E.files.total] == 13), E.identicalContent);
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
