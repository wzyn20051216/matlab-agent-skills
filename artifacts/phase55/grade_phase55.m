function G = grade_phase55(resultsRoot, arms, outFile, taskFilter)
%GRADE_PHASE55  Grade Phase 5.5 agent results against the sealed answers.
%
%   G = grade_phase55('E:\desktop\MATLAB-bench-phase55', {'R1','R2','R3'}, ...
%                     'artifacts/phase55/grades/agent_grade.json')
%
% Agent-level scoring: exact verdict + the observable fields listed in
% score_spec.json, compared with the frozen tolerances from answers.json.
% Route and tool are recorded when present but never required, so a baseline
% arm is not penalised for not knowing project tool names. Missing results are
% MISSING, never false rejects.
%
% taskFilter (optional) restricts grading to a subset of task ids, used for the
% minimal three-arm comparison so its grade file reports only what was run.

if nargin < 1 || isempty(resultsRoot)
    resultsRoot = 'E:\desktop\MATLAB-bench-phase55';
end
if nargin < 2 || isempty(arms), arms = {'R1', 'R2', 'R3'}; end
repo = 'E:\desktop\MATLAB';
if nargin < 3 || isempty(outFile)
    outFile = fullfile(repo, 'artifacts', 'phase55', 'grades', 'agent_grade.json');
end
if nargin < 4, taskFilter = {}; end
if ischar(taskFilter) || isstring(taskFilter), taskFilter = {char(taskFilter)}; end
taskFilter = cellfun(@char, taskFilter, 'UniformOutput', false);
outDir = fileparts(outFile);
if ~isfolder(outDir), mkdir(outDir); end

S = jsondecode(fileread(fullfile(repo, 'artifacts', 'phase55', 'score_spec.json')));
A = jsondecode(fileread('E:\desktop\MATLAB-bench-holdout-phase53\answers.json'));
B = jsondecode(fileread('E:\desktop\MATLAB-bench-holdout-phase54\answers.json'));
amap = containers.Map('KeyType', 'char', 'ValueType', 'any');
for src = {A, B}
    ts = src{1}.tasks; if isstruct(ts), ts = num2cell(ts(:)); end
    for k = 1:numel(ts), amap(char(ts{k}.id)) = ts{k}; end
end

G = struct();
G.schema = 'mas-phase55-agent-grade/1';
G.gradedAt = datestr(now, 31);
G.resultsRoot = resultsRoot;
G.scoring = ['verdict + observable fields from score_spec.json; tolerances from ' ...
    'frozen answers; route/tool recorded but not required'];
G.taskFilter = taskFilter;
G.arms = struct('arm', {}, 'nPlanned', {}, 'nExecuted', {}, 'nMissing', {}, ...
    'nPass', {}, 'nFail', {}, 'passRateExecuted', {}, 'falseAccepts', {}, ...
    'falseRejects', {}, 'undetExpected', {}, 'undetDetected', {}, ...
    'fieldsPass', {}, 'fieldsTotal', {}, 'verdictConfusion', {}, 'rows', {});

scoreTasks = S.tasks;
if isstruct(scoreTasks), scoreTasks = num2cell(scoreTasks(:)); end
for a = 1:numel(arms)
    arm = arms{a};
    rows = struct('taskId', {}, 'expectedVerdict', {}, 'actualVerdict', {}, ...
        'verdictOk', {}, 'fieldsPass', {}, 'fieldsTotal', {}, 'pass', {}, ...
        'falseAccept', {}, 'falseReject', {}, 'routePrimary', {}, 'tool', {}, ...
        'notes', {}, 'resultSha256', {}, 'resultFile', {}, 'fieldDetail', {});
    for k = 1:numel(scoreTasks)
        id = char(scoreTasks{k}.id);
        if ~isempty(taskFilter) && ~any(strcmp(taskFilter, id)), continue; end
        flds = scoreTasks{k}.fields;
        if ~iscell(flds), flds = num2cell(flds); end
        if ~isKey(amap, id)
            error('grade_phase55:answers', 'no sealed answer for task %s', id);
        end
        ans = amap(id);
        rf = fullfile(resultsRoot, arm, id, 'result.json');
        row = struct('taskId', id, 'expectedVerdict', char(ans.verdict), ...
            'actualVerdict', 'MISSING', 'verdictOk', false, 'fieldsPass', 0, ...
            'fieldsTotal', numel(flds), 'pass', false, 'falseAccept', false, ...
            'falseReject', false, 'routePrimary', '', 'tool', '', 'notes', '', ...
            'resultSha256', '', 'resultFile', rf, 'fieldDetail', struct('name', {}, 'ok', {}, 'detail', {}));
        if ~isfile(rf)
            row.notes = 'result.json missing';
            rows(end+1) = row; %#ok<AGROW>
            continue;
        end
        row.resultSha256 = sha256_file(rf);
        try
            r = jsondecode(fileread(rf));
        catch ME
            row.notes = ['unreadable result: ' ME.message];
            rows(end+1) = row; %#ok<AGROW>
            continue;
        end
        row.actualVerdict = char(getf(r, 'verdict', 'MISSING'));
        row.routePrimary = char(getf(r, 'routePrimary', ''));
        row.tool = char(getf(r, 'tool', ''));
        row.verdictOk = strcmp(row.actualVerdict, row.expectedVerdict);
        if ~isfield(ans, 'fields') || isempty(ans.fields)
            F = {};
        else
            F = ans.fields; if isstruct(F), F = num2cell(F(:)); end
        end
        for q = 1:numel(F)
            spec = F{q}; nm = char(spec.name);
            if ~any(strcmp(flds, nm)), continue; end
            fr = struct('name', nm, 'ok', false, 'detail', '');
            [fr.ok, fr.detail] = compare_field(r, strrep(nm, '.', '_'), spec);
            row.fieldDetail(end+1) = fr; %#ok<AGROW>
        end
        row.fieldsPass = nnz([row.fieldDetail.ok]);
        fieldsOk = row.fieldsPass == row.fieldsTotal;
        row.pass = row.verdictOk && fieldsOk;
        row.falseAccept = strcmp(row.expectedVerdict, 'FAIL') && strcmp(row.actualVerdict, 'PASS');
        row.falseReject = strcmp(row.expectedVerdict, 'PASS') && ...
            ~strcmp(row.actualVerdict, 'PASS') && ~strcmp(row.actualVerdict, 'MISSING');
        rows(end+1) = row; %#ok<AGROW>
    end
    R = rows(:).';
    actual = {R.actualVerdict};
    exp = {R.expectedVerdict};
    armRes = struct();
    armRes.arm = arm;
    armRes.nPlanned = numel(R);
    armRes.nExecuted = nnz(~strcmp(actual, 'MISSING'));
    armRes.nMissing = armRes.nPlanned - armRes.nExecuted;
    armRes.nPass = nnz([R.pass]);
    armRes.nFail = armRes.nExecuted - armRes.nPass;
    if armRes.nExecuted > 0
        armRes.passRateExecuted = armRes.nPass / armRes.nExecuted;
    else
        armRes.passRateExecuted = NaN;
    end
    armRes.falseAccepts = nnz([R.falseAccept]);
    armRes.falseRejects = nnz([R.falseReject]);
    armRes.undetExpected = nnz(strcmp(exp, 'UNDETERMINED'));
    armRes.undetDetected = nnz(strcmp(exp, 'UNDETERMINED') & strcmp(actual, 'UNDETERMINED'));
    armRes.fieldsPass = sum([R.fieldsPass]);
    armRes.fieldsTotal = sum([R.fieldsTotal]);
    armRes.verdictConfusion = confusion(exp, actual);
    armRes.rows = R;
    G.arms(end+1) = armRes;
    fprintf(['\n== %s: %d/%d executed, pass %d, false accept %d, false reject %d, ' ...
        'UNDET %d/%d, fields %d/%d ==\n'], arm, armRes.nExecuted, armRes.nPlanned, ...
        armRes.nPass, armRes.falseAccepts, armRes.falseRejects, ...
        armRes.undetDetected, armRes.undetExpected, armRes.fieldsPass, armRes.fieldsTotal);
    for j = 1:numel(R)
        fprintf('%-12s exp=%-12s act=%-12s fields %d/%d pass=%d %s\n', ...
            R(j).taskId, R(j).expectedVerdict, R(j).actualVerdict, ...
            R(j).fieldsPass, R(j).fieldsTotal, R(j).pass, R(j).notes);
    end
end

fid = fopen(outFile, 'w', 'n', 'UTF-8');
fwrite(fid, jsonencode(G, 'PrettyPrint', true), 'char'); fclose(fid);
fprintf('\ngrade written to %s\n', outFile);
end

% ---------------------------------------------------------------------------
function [ok, detail] = compare_field(r, nm, spec)
ok = false; detail = '';
if ~isfield(r, 'fields') || ~isfield(r.fields, nm)
    detail = 'field missing from result';
    return;
end
a = r.fields.(nm);
ref = spec.ref;
op = char(spec.op);
tol = 0;
if isfield(spec, 'tol') && ~isempty(spec.tol), tol = spec.tol; end
if ischar(a) || ischar(ref)
    ok = strcmp(char(a), char(ref));
    detail = sprintf('"%s" vs "%s"', char(a), char(ref));
    return;
end
if ~isnumeric(a) || isempty(a)
    detail = 'field is not numeric';
    return;
end
switch lower(op)
    case 'exact'
        ok = isequal(double(a), double(ref));
        detail = sprintf('%s vs %s', mat2str(a), mat2str(ref));
    case 'abs'
        err = max(abs(double(a(:)) - double(ref(:))));
        ok = err <= tol; detail = sprintf('abs err %.3e <= %.3e', err, tol);
    case 'rel'
        err = max(abs(double(a(:)) - double(ref(:))));
        if all(double(ref(:)) == 0), lim = tol; else, lim = tol * max(abs(double(ref(:)))); end
        ok = err <= lim; detail = sprintf('abs err %.3e <= %.3e (rel %.3g)', err, lim, tol);
    case 'maxabsdiff'
        err = max(abs(double(a(:)) - double(ref(:))));
        ok = err <= tol; detail = sprintf('max|diff| %.3e <= %.3e', err, tol);
    case 'min'
        ok = double(a) >= double(ref) - tol; detail = sprintf('%.6g >= %.6g - %.3g', double(a), double(ref), tol);
    case 'max'
        ok = double(a) <= double(ref) + tol; detail = sprintf('%.6g <= %.6g + %.3g', double(a), double(ref), tol);
    otherwise
        detail = sprintf('unknown op "%s"', op);
end
end

function v = getf(s, name, dflt)
if isfield(s, name) && ~isempty(s.(name)), v = s.(name); else, v = dflt; end
end

function C = confusion(exp, act)
C = struct();
for e = {'PASS', 'FAIL', 'UNDETERMINED', 'MISSING'}
    for a = {'PASS', 'FAIL', 'UNDETERMINED', 'MISSING'}
        nm = sprintf('%s_to_%s', e{1}, a{1});
        C.(nm) = nnz(strcmp(exp, e{1}) & strcmp(act, a{1}));
    end
end
end

function h = sha256_file(p)
fid = fopen(p, 'r');
if fid < 0, error('grade_phase55:hash', 'cannot open %s', p); end
b = fread(fid, Inf, '*uint8'); fclose(fid);
md = java.security.MessageDigest.getInstance('SHA-256');
d = typecast(md.digest(b), 'uint8');
h = lower(reshape(dec2hex(d)', 1, []));
end
