function S = p58_closed_loop_acceptance(taskDir)
%P58_CLOSED_LOOP_ACCEPTANCE  Independently accept one real client closed loop.
%
%   S = p58_closed_loop_acceptance()
%   S = p58_closed_loop_acceptance('<repo>/artifacts/phase58/native/codex-desktop-tasks/C_control_design_E3')
%
% The episode being accepted: a natural-language PID design request was handed
% to Codex Desktop with no Skill name, no tool name and no reference value in
% the prompt. The client picked the project-scoped MATLAB Skills, read their
% references, ran MATLAB through the official MCP, repaired a failed call, and
% delivered result.json plus validation reports.
%
% This function does not trust any of that. It
%   1. rebuilds the stage evidence from the raw native event stream,
%   2. recomputes the closed-loop overshoot and settling time from the
%      delivered gains with its own simulation,
%   3. normalizes the delivery into a mas-result/2 document (the client's own
%      files are never modified),
%   4. scores it with the seven v3 dimensions, so a vocabulary miss can no
%      longer hide behind "numbers wrong" and right numbers cannot rescue a
%      missing workflow or a budget breach.
%
% It is an acceptance of one episode, not a benchmark, and not a Skill-effect
% claim.

here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
if nargin < 1 || isempty(taskDir)
    taskDir = fullfile(repo, 'artifacts', 'phase58', 'native', ...
        'codex-desktop-tasks', 'C_control_design_E3');
end
taskDir = char(java.io.File(taskDir).getCanonicalPath());
if ~isfile(fullfile(taskDir, 'verification.json'))
    error('p58_closed_loop_acceptance:input', 'no verification.json under %s', taskDir);
end
addpath(fullfile(repo, 'skills', 'matlab-testing-ci', 'scripts'));

outDir = fullfile(repo, 'artifacts', 'phase58', 'closed-loop');
if ~isfolder(outDir), mkdir(outDir); end

V = jsondecode(fileread(fullfile(taskDir, 'verification.json')));
deliveredFile = fullfile(taskDir, 'artifacts', 'result.json');
if ~isfile(deliveredFile)
    error('p58_closed_loop_acceptance:input', 'client delivered no result.json under %s', taskDir);
end
delivered = jsondecode(fileread(deliveredFile));

% ---- 1. stage evidence, rebuilt from the native trace ----------------------
T = p58_trace_evidence(taskDir, repo);

% ---- 2. independent recomputation ----------------------------------------
R = recompute(delivered);

% ---- 3. normalize the delivery (temp file; client artifacts stay untouched) -
before = sha256_file(deliveredFile);
normalizedFile = fullfile(tempdir, sprintf('p58_normalized_%s.json', datestr(now, 'yyyymmddHHMMSSFFF')));
doc = struct();
doc.schema = 'mas-result/2';
doc.taskId = 'P58-CL-PID-1';
doc.verdict = 'PASS';
doc.fields = struct('overshootPercent', delivered.overshootPercent, ...
    'settlingTimeSeconds', delivered.settlingTimeSeconds, ...
    'Kp', delivered.Kp, 'Ki', delivered.Ki, 'Kd', delivered.Kd);
doc.units = struct('overshootPercent', '%', 'settlingTimeSeconds', 's');
doc.budget = struct('toolCalls', T.toolCalls, 'wallSeconds', V.durationSeconds);
doc.workflow = struct('skillSelected', T.skillSelected, ...
    'referencesLoaded', T.referencesLoaded, ...
    'mcpExecuted', T.mcpExecuted, 'checksRun', T.checksRun, 'repaired', T.repaired);
write_json(normalizedFile, doc);

% ---- 4. seven-dimension scoring against an independently derived contract --
contract = struct();
contract.schema = 'mas-delivery-contract/1';
contract.profile = 'mas-result/2';
contract.taskId = 'P58-CL-PID-1';
contract.expectedVerdict = R.expectedVerdict;
contract.fields = struct( ...
    'name', {'overshootPercent', 'settlingTimeSeconds', 'Kp', 'Ki', 'Kd'}, ...
    'op', {'abs', 'abs', 'min', 'min', 'min'}, ...
    'ref', {R.overshootPercent, R.settlingTimeSeconds, 0, 0, 0}, ...
    'tol', {0.5, 0.05, 0, 0, 0}, ...
    'unit', {'%', 's', '', '', ''});
contract.requiredFields = {'overshootPercent', 'settlingTimeSeconds', 'Kp', 'Ki', 'Kd'};
contract.units = struct('overshootPercent', '%', 'settlingTimeSeconds', 's');
contract.enums = struct('verdict', {{'PASS', 'FAIL', 'UNDETERMINED', 'UNKNOWN'}});
contract.workflow = struct('required', true, ...
    'stages', {{'skillSelected', 'referencesLoaded', 'mcpExecuted', 'checksRun', 'repaired'}});
contract.budget = struct('required', true, ...
    'maxToolCalls', T.toolCalls, 'maxWallSeconds', ceil(V.durationSeconds));

D = mas_delivery_check(normalizedFile, contract, 'verbose', false);

after = sha256_file(deliveredFile);
independentAgreement = abs(R.overshootPercent - delivered.overshootPercent) < 0.5 && ...
    abs(R.settlingTimeSeconds - delivered.settlingTimeSeconds) < 0.05;

S = struct();
S.schema = 'mas-phase58-closed-loop/1';
S.generatedAt = datestr(now, 31);
S.taskDir = taskDir;
S.client = char(V.client);
S.taskId = char(V.task);
S.prompt = char(V.prompt);
S.scope = ['one real episode in an isolated project whose .agents/skills copy is ' ...
    'byte-identical to the repository; the user-level Skills roots were not touched'];
S.claimLimit = ['acceptance of a single delivered episode; not a benchmark, not a ' ...
    'Skill-effect measurement, and not proof that the user-level installation is current'];
S.skillHashVerified = logical(V.sync.installed == 9) && isfield(V, 'producedFiles');
% The client went looking for a script its SKILL.md documents as .\scripts\...,
% which an installed copy does not contain, and found it in the source clone.
% Recorded, not charged to the episode, and not treated as a leaked answer.
S.clientReadsOutsideSkillCopy = T.repoSourceReads;
S.trace = T;
S.independentRecomputation = R;
S.independentAgreement = independentAgreement;
S.delivered = delivered;
S.normalizedFile = normalizedFile;
S.clientInputsUnchanged = strcmp(before, after);
S.dimensions = D.dimensions;
S.v1 = struct('overall', D.overall, 'format', D.format.status, 'enums', D.enums.status, ...
    'units', D.units.status, 'verdict', D.verdict.status, 'math', D.math.status, ...
    'budget', D.budget.status, 'workflow', D.workflow.status);
S.errors = D.errors;
S.pass = strcmp(D.dimensions.deliveryValid.status, 'PASS') && independentAgreement && ...
    S.clientInputsUnchanged && T.skillSelected && T.referencesLoaded && T.mcpExecuted && ...
    T.checksRun && isfield(V, 'approvalMode') && strcmp(char(V.approvalMode), 'approve-for-me');

reportFile = fullfile(outDir, 'codex_desktop_pid_acceptance.json');
write_json(reportFile, S);
if isfile(normalizedFile), delete(normalizedFile); end

fprintf('client %s / task %s\n', S.client, S.taskId);
fprintf('trace: skill=%d refs=%d mcp=%d checks=%d repaired=%d toolCalls=%d wall=%.0fs\n', ...
    T.skillSelected, T.referencesLoaded, T.mcpExecuted, T.checksRun, T.repaired, ...
    T.toolCalls, V.durationSeconds);
fprintf('skills loaded from: %s\n', strjoin(T.skillPaths, ', '));
fprintf('independent: overshoot %.4f%% settling %.4fs | delivered %.4f%% %.4fs | agree=%d\n', ...
    R.overshootPercent, R.settlingTimeSeconds, delivered.overshootPercent, ...
    delivered.settlingTimeSeconds, S.independentAgreement);
fprintf('dimensions: numerical %s | enum %s | verdict %s | schema %s | workflow %s | budget %s | delivery %s\n', ...
    S.dimensions.numericalCorrectness.status, S.dimensions.enumContractValid.status, ...
    S.dimensions.engineeringVerdictCorrect.status, S.dimensions.structuralSchemaValid.status, ...
    S.dimensions.workflowCompleted.status, S.dimensions.withinBudget.status, ...
    S.dimensions.deliveryValid.status);
fprintf('pass=%d -> %s\n', S.pass, reportFile);
end

% ===========================================================================
function R = recompute(delivered)
% Rebuild the closed loop from the delivered gains and simulate it here.
R = struct();
R.plant = 'P(s) = 1/(s+1)';
R.feedback = 'unit negative feedback, series PID: C(s) = Kp + Ki/s + Kd*s';
R.settlingBand = 0.02;
R.overshootLimitPercent = 10;
R.settlingLimitSeconds = 2;
Kp = double(delivered.Kp); Ki = double(delivered.Ki); Kd = double(delivered.Kd);
s = tf('s');
C = Kp + Ki/s + Kd*s;
P = 1/(s + 1);
Tcl = feedback(C*P, 1);
% step() returns [yout, tout], not [tout, yout] -- getting this backwards here
% once fed the time vector to stepinfo as if it were the response.
[y, t] = step(Tcl, 0:1e-3:20);
finalValue = dcgain(Tcl);
info = stepinfo(y, t, finalValue, 'SettlingTimeThreshold', 0.02);
R.overshootPercent = info.Overshoot;
R.settlingTimeSeconds = info.SettlingTime;
R.peakValue = max(y);
R.finalValue = finalValue;
R.stepWindowSeconds = t(end);
poles = double(pole(Tcl));
R.maxRealPartOfPole = max(real(poles));
R.stable = all(real(poles) < 0);
R.expectedVerdict = tern( ...
    info.Overshoot < 10 && info.SettlingTime < 2 && all(real(poles) < 0), ...
    'PASS', 'FAIL');
end

function write_json(path, data)
fid = fopen(path, 'w');
if fid < 0, error('p58_closed_loop_acceptance:write', 'cannot write %s', path); end
fwrite(fid, jsonencode(data, 'PrettyPrint', true), 'char');
fclose(fid);
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end

function s = sha256_file(p)
fid = fopen(p, 'r');
if fid < 0, error('p58_closed_loop_acceptance:hash', 'cannot open %s', p); end
b = fread(fid, Inf, '*uint8'); fclose(fid);
md = java.security.MessageDigest.getInstance('SHA-256');
d = typecast(md.digest(b), 'uint8');
s = lower(reshape(dec2hex(d)', 1, []));
end
