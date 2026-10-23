function R = p58_regression_summary(varargin)
%P58_REGRESSION_SUMMARY  Task 6: the Phase 5.8 full regression in one record.
%
%   R = p58_regression_summary()
%   R = p58_regression_summary('skipLong', true)  % re-collect, do not re-run coder/concurrency
%
% Most items are collected from runs that already wrote their own evidence --
% run_all (skill suites + references + cross-domain + routed pipeline), the
% free-layer Pester run, the client evidence, the scoring replay and the
% closed-loop acceptance. Two items belong to no other script and are executed
% here: the Coder entry contract and concurrency isolation.
%
% Frozen numbers are compared, never adjusted. Phase 5.7 froze 1075/1075 over
% 32 suites; if the total moves, the move is attributed to the suites that
% actually changed. No threshold is edited and no historical failure is deleted.
%
% Writes only under artifacts/phase58/regression/.

ap = inputParser;
ap.addParameter('skipLong', false, @(x) islogical(x) || isnumeric(x));
ap.parse(varargin{:});
skipLong = logical(ap.Results.skipLong);

here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
outDir = fullfile(repo, 'artifacts', 'phase58', 'regression');
if ~isfolder(outDir), mkdir(outDir); end
addpath(fullfile(repo, 'skills', 'matlab-testing-ci', 'scripts'));
addpath(fullfile(repo, 'skills', 'matlab-codegen-deploy', 'scripts'));
addpath(fullfile(repo, 'skills', 'matlab-codegen-deploy', 'tests'));
addpath(fullfile(repo, 'matlab', 'validation', 'phase54'));
addpath(here);

frozen = struct('skillPass', 1075, 'skillTotal', 1075, 'suites', 32, ...
    'references', 15, 'crossdomain', 15, 'pipeline', 15, ...
    'source', 'artifacts/phase57/regression/phase4_all.json', ...
    'report', 'docs/PHASE5_7_FINAL_ZH.md section 10');

R = struct();
R.schema = 'mas-phase58-regression/1';
R.generatedAt = datestr(now, 31);
R.matlabVersion = version;
R.scope = 'Phase 5.8 Task 6 regression and consistency checks';
R.frozenBaseline = frozen;
checks = new_checks();

% ---- 1. run_all: skill suites, references, cross-domain, pipeline ---------
raFile = fullfile(outDir, 'phase4_all.json');
[ra, ok] = read_json(raFile);
if ~ok
    checks(end+1) = rec('MATLAB suites (run_all)', false, ...
        sprintf('%s missing -- run matlab/validation/phase4/run_all first', raFile));
    R = finish(R, checks, outDir);
    return
end
R.runAll = ra;
p57File = fullfile(repo, 'artifacts', 'phase57', 'regression', 'phase4_all.json');
[R7, r7ok] = read_json(p57File);
delta = ra.skillTotal - frozen.skillTotal;
% A total that moves is only meaningful if the move is attributed. Compare the
% two records suite by suite: nothing may shrink, no suite may disappear, and
% every suite that grew must be one this phase deliberately extended.
[movedNames, movedText, missing, shrank] = suite_delta(R7, ra);
checks(end+1) = rec('MATLAB suites all pass with no ERROR', ...
    ra.skillPass == ra.skillTotal && ra.suitesErrored == 0 && ra.allSuitesOk, ...
    sprintf('%d/%d over %d suites, %d errored, %.1f s', ra.skillPass, ra.skillTotal, ...
    ra.suitesRun, ra.suitesErrored, ra.elapsedS));
checks(end+1) = rec('the +52 suite delta is fully attributed against the frozen 1075', ...
    r7ok && isempty(missing) && isempty(shrank) && ...
    numel(movedNames) == 1 && strcmp(movedNames{1}, 'deliveryCheck') && delta == 52, ...
    sprintf('frozen %d/%d over %d suites -> now %d/%d over %d; grew: %s; shrank: %s; missing: %s', ...
    frozen.skillPass, frozen.skillTotal, tern(r7ok, numel(R7.suites), 0), ...
    ra.skillPass, ra.skillTotal, ra.suitesRun, movedText, ...
    strjoin_or_empty(shrank), strjoin_or_empty(missing)));
checks(end+1) = rec('frozen reference implementations verify', ...
    ra.references.ok && ra.references.total == frozen.references && ...
    ra.references.pass == frozen.references, ...
    sprintf('%d/%d references', ra.references.pass, ra.references.total));
checks(end+1) = rec('nine-Skill cross-domain tasks pass', ...
    ra.crossdomain.pass == frozen.crossdomain && ra.crossdomain.fail == 0 && ...
    ra.crossdomain.undetermined == 0, ...
    sprintf('pass %d, fail %d, undetermined %d of %d', ra.crossdomain.pass, ...
    ra.crossdomain.fail, ra.crossdomain.undetermined, ra.crossdomain.total));
checks(end+1) = rec('routed pipeline passes with no self-disagreement', ...
    ra.pipeline.pass == frozen.pipeline && ra.pipeline.selfDisagreement == 0, ...
    sprintf('%d/%d, skill match rate %s, selfDisagreement %s', ra.pipeline.pass, ...
    ra.pipeline.total, num2str(ra.pipeline.skillMatchRate), ...
    num2str(ra.pipeline.selfDisagreement)));

% ---- 2. capability matrix consistency ------------------------------------
capSel = ra.suites(strcmp({ra.suites.name}, 'capability'));
skDirs = dir(fullfile(repo, 'skills', 'matlab-*'));
skDirs = skDirs([skDirs.isdir]);
capFile = fullfile(repo, 'skills', 'capability-matrix.json');
[M, mok] = read_json(capFile);
nMatrixEntries = 0;
if mok && isfield(M, 'skills') && ~isempty(M.skills)
    % jsondecode turns a JSON object into a 1x1 struct, so numel() is 1; the
    % skill count is the number of fields under "skills".
    nMatrixEntries = numel(fieldnames(M.skills));
end
checks(end+1) = rec('capability matrix is consistent with the nine shipped Skills', ...
    mok && ~isempty(capSel) && capSel(1).ok && numel(skDirs) == 9 && ...
    nMatrixEntries == 9, ...
    sprintf('capability suite %g/%g, %d matlab-* skill directories, %d matrix skill entries', ...
    getf(capSel(1), 'pass', NaN), getf(capSel(1), 'total', NaN), ...
    numel(skDirs), nMatrixEntries));

% ---- 3. free-layer Pester suites -----------------------------------------
lrFile = fullfile(repo, 'artifacts', 'validation', 'tests', 'layer_report.json');
[LR, lok] = read_json(lrFile);
freeLog = fullfile(outDir, 'pester_free.log');
if lok
    lay = LR.layers(strcmpi({LR.layers.layer}, 'free'));
    if isempty(lay)
        checks(end+1) = rec('free-layer Pester suites executed', false, ...
            'layer_report.json has no "free" layer');
        checks(end+1) = rec('the single Pester failure is the known pre-existing hygiene gate', ...
            false, 'layer "free" not reported');
    else
        lay = lay(1);
        R.pester = struct('layer', char(lay.layer), 'executed', logical(lay.executed), ...
            'total', lay.total, 'passed', lay.passed, 'failed', lay.failed, ...
            'durationSec', lay.durationSec, 'report', lrFile);
        checks(end+1) = rec('free-layer Pester suites executed', ...
            logical(lay.executed) && lay.total > 0, ...
            sprintf('%d/%d passed, %d failed in %.1f s (Pester %s)', lay.passed, ...
            lay.total, lay.failed, lay.durationSec, char(getf(LR, 'pesterVersion', '?'))));
        [hok, hdetail] = hygiene_failure_is_the_known_one(freeLog, lay.failed);
        checks(end+1) = rec('the single Pester failure is the known pre-existing hygiene gate', ...
            hok && lay.failed == 1, hdetail);
        if lay.failed > 0
            R.knownOpenFailures = struct('area', 'pester free layer', ...
                'status', 'FAILED (pre-existing, not introduced by Phase 5.8)', ...
                'detail', hdetail, 'firstSeenAt', 'HEAD bf09e45 before this phase');
        end
    end
else
    checks(end+1) = rec('free-layer Pester suites executed', false, sprintf('%s missing', lrFile));
    checks(end+1) = rec('the single Pester failure is the known pre-existing hygiene gate', ...
        false, sprintf('%s missing', lrFile));
end

% ---- 4. install / sync isolation ------------------------------------------
syncFile = fullfile(repo, 'artifacts', 'phase58', 'install', 'sync_rediscovery.json');
[SY, syok] = read_json(syncFile);
if syok
    checks(end+1) = rec('install sync stays inside its own root and rediscovery passes', ...
        getf(SY, 'pass', false), ...
        sprintf('sync/rediscovery record generated %s', char(getf(SY, 'generatedAt', '?'))));
else
    checks(end+1) = rec('install sync stays inside its own root and rediscovery passes', false, ...
        sprintf('%s missing', syncFile));
end
auditFile = fullfile(repo, 'artifacts', 'phase58', 'install', 'install_audit.json');
[IA, iaok] = read_json(auditFile);
ceFile = fullfile(repo, 'artifacts', 'phase58', 'native', 'client_evidence.json');
[CE, ceok] = read_json(ceFile);
if ceok
    roots = CE.userRootsUnchanged;
    checks(end+1) = rec('real user-level Skill roots were never written', ...
        logical(roots.equal), ...
        sprintf('%d installed copies byte-identical between %s and %s', ...
        roots.copiesCompared, char(roots.generatedAt), char(roots.recheckAt)));
    d = CE.discovery;
    checks(end+1) = rec('client discovery still returns 9/9 with repo-matching hashes', ...
        numel(d) == 2 && all([d.skillsReturned] == 9) && all([d.hashesMatchRepo]), ...
        strjoin(cellfun(@(x) sprintf('%s %d/9', char(x.client), x.skillsReturned), ...
        num2cell(d), 'UniformOutput', false), ', '));
    checks(end+1) = rec('native invocation evidence passes its own assertions', ...
        logical(CE.pass), sprintf('%d episodes, %d assertions', ...
        numel(CE.episodes), numel(CE.assertions)));
else
    checks(end+1) = rec('client discovery still returns 9/9 with repo-matching hashes', false, ...
        sprintf('%s missing', ceFile));
end

% ---- 5. scoring v1/v2/v3 compatibility ------------------------------------
scFile = fullfile(repo, 'artifacts', 'phase58', 'scoring', 'scoring_v3_replay.json');
[SC, scok] = read_json(scFile);
if scok
    dlSel = ra.suites(strcmp({ra.suites.name}, 'deliveryCheck'));
    g2Sel = ra.suites(strcmp({ra.suites.name}, 'gradeV2'));
    checks(end+1) = rec('scoring v1 fields replay unchanged and v3 is additive', ...
        logical(SC.pass) && logical(SC.v1Preserved) && logical(SC.inputsUnchanged) && ...
        logical(SC.enumOnlyFailuresSeparated) && logical(SC.workflowNotRelaxed), ...
        sprintf('%d results, v1 preserved %d, enum-only %d, numerical failures %d', ...
        SC.counts.nResults, SC.counts.v1Unchanged, SC.counts.enumOnlyFail, ...
        SC.counts.numericalFail));
    checks(end+1) = rec('schema/scoring test suites pass at their grown sizes', ...
        ~isempty(dlSel) && dlSel(1).ok && ~isempty(g2Sel) && g2Sel(1).ok, ...
        sprintf('test_delivery_check %g/%g (Phase 5.7 froze 93), test_grade_v2 %g/%g', ...
        getf(dlSel(1), 'pass', NaN), getf(dlSel(1), 'total', NaN), ...
        getf(g2Sel(1), 'pass', NaN), getf(g2Sel(1), 'total', NaN)));
    R.scoringReplay = struct('file', scFile, 'pass', logical(SC.pass), ...
        'inputsSha256', SC.inputsSha256);
else
    checks(end+1) = rec('scoring v1 fields replay unchanged and v3 is additive', false, ...
        sprintf('%s missing', scFile));
end

% ---- 6. closed-loop acceptance -------------------------------------------
clFile = fullfile(repo, 'artifacts', 'phase58', 'closed-loop', ...
    'codex_desktop_pid_acceptance.json');
[CL, clok] = read_json(clFile);
if clok
    dims = fieldnames(CL.dimensions);
    allPass = true;
    for k = 1:numel(dims)
        allPass = allPass && strcmp(CL.dimensions.(dims{k}).status, 'PASS');
    end
    checks(end+1) = rec('the real closed loop still accepts independently', ...
        logical(CL.pass) && logical(CL.independentAgreement) && allPass && ...
        logical(CL.clientInputsUnchanged), ...
        sprintf('7 dimensions, agreement %d, client inputs unchanged %d', ...
        logical(CL.independentAgreement), logical(CL.clientInputsUnchanged)));
else
    checks(end+1) = rec('the real closed loop still accepts independently', false, ...
        sprintf('%s missing', clFile));
end

% ---- 7. Coder entry contract (executed here) ------------------------------
if skipLong
    checks(end+1) = rec('Coder entry contract keeps its three distinct outcomes', ...
        false, 'skipped by request (skipLong) -- recorded as not run');
    checks(end+1) = rec('concurrency isolation holds across independent processes', ...
        false, 'skipped by request (skipLong) -- recorded as not run');
else
    [cok, cdetail, coder] = coder_contract(outDir);
    R.coder = coder;
    checks(end+1) = rec('Coder entry contract keeps its three distinct outcomes', cok, cdetail);
    [uok, udetail, conc] = concurrency_isolation();
    R.concurrency = conc;
    checks(end+1) = rec('concurrency isolation holds across independent processes', uok, udetail);
end

% ---- 8. historical artifacts still intact --------------------------------
if r7ok
    checks(end+1) = rec('the Phase 5.7 regression record is still readable and unchanged in size', ...
        R7.skillPass == frozen.skillPass && R7.skillTotal == frozen.skillTotal, ...
        sprintf('Phase 5.7 archived %d/%d over %d suites', R7.skillPass, R7.skillTotal, ...
        numel(R7.suites)));
else
    checks(end+1) = rec('the Phase 5.7 regression record is still readable and unchanged in size', ...
        false, sprintf('%s missing', p57File));
end
if iaok
    checks(end+1) = rec('the frozen Task 1 install audit is still parseable', ...
        isfield(IA, 'skills') && numel(IA.skills) == 9, ...
        sprintf('generated %s, %d Skills', char(IA.generatedAt), numel(IA.skills)));
end

R.pass = all([checks.ok]);
R = finish(R, checks, outDir);
if ~R.pass
    bad = {checks(~[checks.ok]).label};
    error('p58_regression_summary:assertion', '%d check(s) failed: %s', ...
        numel(bad), strjoin(bad, '; '));
end
end

% ===========================================================================
function checks = new_checks()
checks = struct('label', {}, 'ok', {}, 'detail', {});
end

function c = rec(label, ok, detail)
c = struct('label', label, 'ok', logical(ok), 'detail', detail);
end

function [v, ok] = read_json(p)
v = struct();
ok = isfile(p);
if ~ok, return; end
try
    v = jsondecode(fileread(p));
catch
    ok = false;
end
end

function v = getf(s, name, dflt)
if isstruct(s) && numel(s) == 1 && isfield(s, name) && ~isempty(s.(name))
    v = s.(name);
else
    v = dflt;
end
end

function R = finish(R, checks, outDir)
R.checks = checks;
R.tally = struct('total', numel(checks), 'ok', sum([checks.ok]), ...
    'failed', sum(~[checks.ok]));
R.verdict = 'PASS';
if sum(~[checks.ok]) > 0
    R.verdict = sprintf('%d CHECK(S) FAILED', sum(~[checks.ok]));
end
if isfield(R, 'knownOpenFailures') && ~isempty(R.knownOpenFailures)
    R.verdict = [R.verdict ' (with 1 known pre-existing gate failure, kept as failed)'];
end
for k = 1:numel(checks)
    fprintf('  [%s] %s\n', tern(checks(k).ok, 'PASS', 'FAIL'), checks(k).label);
    fprintf('       %s\n', checks(k).detail);
end
fid = fopen(fullfile(outDir, 'regression_summary.json'), 'w');
if fid >= 0
    fwrite(fid, jsonencode(R), 'char');
    fclose(fid);
end
fprintf('p58_regression_summary: %d/%d checks -> %s\n', R.tally.ok, R.tally.total, ...
    fullfile(outDir, 'regression_summary.json'));
end

function [ok, detail, C] = coder_contract(outDir)
%CODER_CONTRACT  Re-execute the three Coder entry shapes, writing only here.
%
% Phase 5.7's p57_coder_contract.m writes its log into artifacts/phase57/task7,
% which is frozen evidence, so re-running it would rewrite history. The same
% three outcomes are reproduced here instead: a supported string entry, an
% unsupported function handle, and a real link failure whose compiler log must
% survive cleanup.
fixtures = tempname;
mkdir(fixtures);
addpath(fixtures);
cleanup = onCleanup(@() rmpath_and_remove(fixtures));
write_fn(fullfile(fixtures, 'p58_rg_ok.m'), ...
    sprintf('function y = p58_rg_ok(x)\ny = x.^2 + sin(x) + 1;\nend\n'));
write_fn(fullfile(fixtures, 'p58_rg_build_fail.m'), sprintf([ ...
    'function y = p58_rg_build_fail(x)\n' ...
    'coder.ceval(''mas_undefined_symbol_xyz'', int32(1));\n' ...
    'y = x + 1;\nend\n']));

C = struct();
C.generatedAt = datestr(now, 31);
C.compiler = '';
C.status = 'RUN';
try
    cc = mex.getCompilerConfigurations('C');
    if ~isempty(cc), C.compiler = cc(1).Name; end
catch
end
if exist('codegen', 'file') == 0 || isempty(C.compiler)
    C.status = 'SKIP';
    C.reason = 'MATLAB Coder or a configured C compiler is unavailable';
    ok = false;
    detail = 'SKIP: no Coder/C compiler -- recorded as not run, not as pass';
    return
end

r1 = mas_codegen_verify('p58_rg_ok', {1:5}, struct('keep', true));
logs1 = r1.compilerLog;
okLog1 = ~isempty(logs1) && any(~cellfun(@isempty, regexpi({logs1.name}, 'buildLog\.log$', 'once'))) ...
    && all(cellfun(@(t) ~isempty(t), {logs1.text}));
okKept = isfolder(r1.buildDir) && logical(r1.buildDirRetained);
ok1 = strcmp(r1.verdict, 'PASS') && strcmp(r1.stage, 'compare') && okLog1 && okKept;
C.stringFileName = struct('verdict', r1.verdict, 'stage', r1.stage, 'ok', ok1, ...
    'compilerLogBytes', sum([logs1.bytes]), 'buildDirRetained', okKept);
if okKept, try, rmdir(r1.buildDir, 's'); catch, end; end

bad = mas_codegen_verify(@(x) x * 2 + sin(x), {0.5});
hDetail = strtrim(char(bad.detail));
ok2 = strcmp(bad.verdict, 'FAIL') && strcmp(bad.stage, 'codegen') && ...
    ~isempty(strfind(lower(hDetail), 'function handle')) && ...
    ~isempty(strfind(hDetail, 'emlc'));
C.functionHandle = struct('verdict', bad.verdict, 'stage', bad.stage, 'ok', ok2, ...
    'detail', hDetail);

bf = mas_codegen_verify('p58_rg_build_fail', {1});
bfLogs = bf.compilerLog;
bfText = '';
srcBytes = 0;
if ~isempty(bfLogs)
    [~, idx] = max([bfLogs.bytes]);
    bfText = bfLogs(idx).text;
    srcBytes = bfLogs(idx).bytes;
end
logFile = fullfile(outDir, 'regression_build_failure_compiler.log');
onDisk = 0;
if ~isempty(bfText)
    fid = fopen(logFile, 'w');
    if fid >= 0
        % uint8, not 'char': a text encoding could expand bytes above 127 and
        % the copy would no longer be the compiler's own log.
        fwrite(fid, uint8(bfText), 'uint8');
        fclose(fid);
    end
    dd = dir(logFile);
    if ~isempty(dd), onDisk = dd(1).bytes; end
else
    logFile = '';
end
byteExact = ~isempty(bfText) && onDisk == numel(bfText) && numel(bfText) == srcBytes;
ok3 = strcmp(bf.verdict, 'FAIL') && strcmp(bf.stage, 'build') && ...
    ~isempty(regexpi(bfText, 'LNK\d+|fatal error', 'once')) && ...
    ~isfolder(bf.buildDir) && byteExact;
C.linkFailure = struct('verdict', bf.verdict, 'stage', bf.stage, 'ok', ok3, ...
    'compilerLogBytes', numel(bfText), 'bytesOnDisk', onDisk, ...
    'sourceLogBytes', srcBytes, 'byteExact', byteExact, ...
    'logFile', logFile, 'buildDirRemoved', ~isfolder(bf.buildDir), ...
    'sha256', sha256_txt(logFile));

ok = ok1 && ok2 && ok3;
detail = sprintf('string=%s@%s handle=%s@%s link=%s@%s log %d bytes byte-exact %d compiler "%s"', ...
    r1.verdict, r1.stage, bad.verdict, bad.stage, bf.verdict, bf.stage, ...
    numel(bfText), byteExact, C.compiler);
end

function [ok, detail, X] = concurrency_isolation()
%CONCURRENCY_ISOLATION  Three rounds x two independent MATLAB processes.
%
% test_concurrency stamps its evidence with the process id, so running it here
% adds files instead of touching the Phase 5.7 records.
try
    R = test_concurrency(3, 2, true);
catch ME
    ok = false;
    X = struct('error', ME.message);
    detail = sprintf('test_concurrency threw: %s', ME.message);
    return
end
ok = logical(R.ok) && logical(R.isolation.verified);
X = struct('ok', logical(R.ok), 'roundsClean', sum([R.rounds.ok]), ...
    'rounds', numel(R.rounds), 'verified', logical(R.isolation.verified), ...
    'sessionInLog', logical(R.isolation.sessionInLog), ...
    'crossSessionContamination', logical(R.isolation.crossSessionContamination), ...
    'fixtureUnderSessionRoot', logical(R.isolation.fixtureUnderSessionRoot), ...
    'newTempDirs', R.isolation.newTempDirs, ...
    'sessionDirsLeft', numel(R.isolation.sessionDirsLeft));
detail = sprintf('%d/%d rounds clean; isolation.verified=%d own-session-log=%d cross-session=%d fixture-owned=%d residue temp=%d left=%d', ...
    X.roundsClean, X.rounds, X.verified, X.sessionInLog, ...
    X.crossSessionContamination, X.fixtureUnderSessionRoot, X.newTempDirs, ...
    X.sessionDirsLeft);
end

function write_fn(p, txt)
fid = fopen(p, 'w');
if fid >= 0, fwrite(fid, txt, 'char'); fclose(fid); end
end

function rmpath_and_remove(dirName)
try
    rmpath(dirName);
catch
end
try
    if isfolder(dirName), rmdir(dirName, 's'); end
catch
end
end

function h = sha256_txt(p)
h = '';
if isempty(p) || ~isfile(p), return; end
fid = fopen(p, 'r');
if fid < 0, return; end
b = fread(fid, Inf, '*uint8');
fclose(fid);
if isempty(b), return; end
md = java.security.MessageDigest.getInstance('SHA-256');
d = typecast(md.digest(b), 'uint8');
h = lower(reshape(dec2hex(d)', 1, []));
end

function [movedNames, movedText, missing, shrank] = suite_delta(old, new)
% Attribute a change in the suite total to the suites that actually moved.
movedNames = {};
movedText = 'none';
missing = {};
shrank = {};
if ~(isstruct(old) && isfield(old, 'suites') && numel(old.suites) > 0) || ...
        ~(isstruct(new) && isfield(new, 'suites') && numel(new.suites) > 0)
    missing{end+1} = 'either record has no suite list'; %#ok<AGROW>
    return
end
parts = {};
for k = 1:numel(new.suites)
    nm = new.suites(k).name;
    j = find(strcmp({old.suites.name}, nm), 1);
    if isempty(j)
        movedNames{end+1} = nm; %#ok<AGROW>
        parts{end+1} = sprintf('%s is new (%g)', nm, new.suites(k).total); %#ok<AGROW>
        continue
    end
    if new.suites(k).total < old.suites(j).total
        shrank{end+1} = sprintf('%s %g->%g', nm, old.suites(j).total, new.suites(k).total); %#ok<AGROW>
    end
    if new.suites(k).total ~= old.suites(j).total
        movedNames{end+1} = nm; %#ok<AGROW>
        parts{end+1} = sprintf('%s %g->%g', nm, old.suites(j).total, new.suites(k).total); %#ok<AGROW>
    end
end
for k = 1:numel(old.suites)
    if ~any(strcmp({new.suites.name}, old.suites(k).name))
        missing{end+1} = old.suites(k).name; %#ok<AGROW>
    end
end
if ~isempty(parts), movedText = strjoin(parts, '; '); end
end

function s = strjoin_or_empty(c)
if isempty(c), s = 'none'; else, s = strjoin(c, '; '); end
end

function [ok, detail] = hygiene_failure_is_the_known_one(logFile, nFailed)
% The repository-hygiene gate (no drive-letter paths in shipped files) fails at
% HEAD, before anything in Phase 5.8 ran. This separates "the known gate is
% still failing for its known reason" from "a new test broke": it re-reads the
% Pester log, requires exactly one failing test, and requires that failure to
% name the hygiene test file and report the git-tracked scan mode. The failing
% record is kept verbatim; nothing here turns it green.
ok = false;
detail = sprintf('%s missing -- Pester free layer output not available', logFile);
if ~isfile(logFile), return; end
txt = fileread(logFile);
lines = strsplit(txt, sprintf('\n'));
failIdx = ~cellfun('isempty', regexpi(lines, '^\s*\[-\]\s+\S', 'once'));
nSeen = sum(failIdx);
hasCore = ~isempty(strfind(txt, fullfile('tests', 'MatlabAgentSkills.Core.Tests.ps1'))) || ...
    ~isempty(regexpi(txt, 'MatlabAgentSkills\.Core\.Tests\.ps1', 'once'));
hasScan = ~isempty(regexpi(txt, '\[scan=git-tracked; files=\d+\]', 'once'));
invM = regexpi(txt, 'But was:\s+\{(.*)\}', 'tokens', 'once');
nEntries = NaN;
if ~isempty(invM)
    % The gate appends its own "[scan=...; files=...]" note inside the same
    % brace list; that note contains a semicolon, so it must be dropped before
    % counting, otherwise the inventory reads as one entry too many.
    inv = regexprep(strtrim(char(invM{1})), '\s*\[scan=[^\]]*\]', '');
    nEntries = numel(strsplit(inv, ';'));
end
detail = sprintf('log shows %d failing test line(s) (report says %d); gate hit inventory %s entries, scan=%s; named file=%d', ...
    nSeen, nFailed, num2str(nEntries), tern(hasScan, 'git-tracked', 'not reported'), tern(hasCore, 1, 0));
ok = (nSeen == 1) && (nFailed == 1) && hasCore && hasScan;
end

function t = tern(c, a, b)
if c, t = a; else, t = b; end
end
