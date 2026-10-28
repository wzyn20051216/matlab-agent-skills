function S = p57_delivery_audit(evalDir)
%P57_DELIVERY_AUDIT  Re-check the frozen Phase 5.6 results for delivery
%consistency: engineering math and output schema scored independently.
%
%   S = p57_delivery_audit()
%   S = p57_delivery_audit(evaluationDirectory)
%
% Contracts are built in memory from the sealed answers (evaluation side). The
% results, answers and tasks are hashed before and after; this function never
% writes to them and never rewrites a delivered verdict. Output lives under
% artifacts/phase57/delivery.

here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
if nargin < 1 || isempty(evalDir)
    evalDir = fullfile(fileparts(repo), 'MATLAB-bench-phase56', 'eval');
end
outDir = fullfile(repo, 'artifacts', 'phase57', 'delivery');
if ~isfolder(outDir), mkdir(outDir); end
addpath(fullfile(repo, 'skills', 'matlab-testing-ci', 'scripts'));

answersFile = fullfile(evalDir, 'answers.json');
tasksFile = fullfile(evalDir, 'tasks_frozen.json');
arms = ["R1", "R2", "R3"];
inputFiles = [string(answersFile), string(tasksFile)];
for a = arms
    for id = ["P56-SIG-B", "P56-ODE-N", "P56-SIG-F"]
        inputFiles(end+1) = string(fullfile(evalDir, ['arm_' char(a)], ...
            sprintf('result_%s.json', id))); %#ok<AGROW>
    end
end
before = arrayfun(@(p) string(sha256_file(char(p))), inputFiles);

A = jsondecode(fileread(answersFile));
T = jsondecode(fileread(tasksFile));
alist = A.tasks; if isstruct(alist), alist = num2cell(alist(:)); end
tlist = T.tasks; if isstruct(tlist), tlist = num2cell(tlist(:)); end
amap = containers.Map('KeyType', 'char', 'ValueType', 'any');
for k = 1:numel(alist), amap(char(alist{k}.id)) = alist{k}; end

rows = struct('arm', {}, 'taskId', {}, 'overall', {}, 'format', {}, ...
    'required', {}, 'enums', {}, 'units', {}, 'verdict', {}, 'math', {}, ...
    'budget', {}, 'reference', {}, 'numericValidFormatInvalid', {}, ...
    'formatValidNumericInvalid', {}, 'errorCodes', {});
for a = arms
    for k = 1:numel(tlist)
        id = char(tlist{k}.id);
        rf = fullfile(evalDir, ['arm_' char(a)], sprintf('result_%s.json', id));
        spec = contract_from(amap(id));
        D = mas_delivery_check(rf, spec, 'verbose', false);
        rows(end+1) = struct('arm', char(a), 'taskId', id, ...
            'overall', D.overall, 'format', D.format.status, ...
            'required', D.required.status, 'enums', D.enums.status, ...
            'units', D.units.status, 'verdict', D.verdict.status, ...
            'math', D.math.status, 'budget', D.budget.status, ...
            'reference', D.reference.status, ...
            'numericValidFormatInvalid', D.separation.numericValidFormatInvalid, ...
            'formatValidNumericInvalid', D.separation.formatValidNumericInvalid, ...
            'errorCodes', {unique({D.errors.code})}); %#ok<AGROW>
    end
end

% Cross-check against the independent v2 grader. Both read the same stored
% results; a disagreement means one of the two is wrong.
nAgree = 0; nCompared = 0; disagreements = {};
for k = 1:numel(rows)
    gf = fullfile(repo, 'artifacts', 'phase57', 'grading', ...
        sprintf('replay_%s.json', rows(k).arm));
    if ~isfile(gf), continue; end
    G = jsondecode(fileread(gf));
    gr = G.rows(strcmp({G.rows.taskId}, rows(k).taskId));
    if isempty(gr), continue; end
    fd = gr(1).dims(strcmp({gr(1).dims.name}, 'fields'));
    nCompared = nCompared + 1;
    if strcmp(fd(1).status, rows(k).math)
        nAgree = nAgree + 1;
    else
        disagreements{end+1} = sprintf('%s/%s: delivery %s vs v2 %s', ...
            rows(k).arm, rows(k).taskId, rows(k).math, fd(1).status); %#ok<AGROW>
    end
end

after = arrayfun(@(p) string(sha256_file(char(p))), inputFiles);
S = struct();
S.schema = 'mas-phase57-delivery-audit/1';
S.generatedAt = datestr(now, 31);
S.evalDir = evalDir;
S.profile = 'mas-result/1-legacy';
S.claimLimit = ['stored results re-checked for delivery consistency; not a new ' ...
    'experiment and not evidence of a Skill effect'];
S.nResults = numel(rows);
S.nExecuted = nnz(~strcmp({rows.overall}, 'ERROR'));
S.nFormatValid = nnz(strcmp({rows.format}, 'PASS'));
S.nMathValid = nnz(strcmp({rows.math}, 'PASS'));
S.nNumericValidFormatInvalid = nnz([rows.numericValidFormatInvalid]);
S.nFormatValidNumericInvalid = nnz([rows.formatValidNumericInvalid]);
S.agreement = struct('nCompared', nCompared, 'nAgree', nAgree, ...
    'disagreements', {disagreements});
S.inputsUnchanged = isequal(before, after);
S.inputFiles = cellstr(inputFiles);
S.inputsSha256 = cellstr(before);
S.perArm = arm_summary(rows, arms);
S.rows = rows;
S.pass = S.inputsUnchanged && S.nExecuted == S.nResults && ...
    nCompared == S.nResults && nAgree == nCompared;

fid = fopen(fullfile(outDir, 'delivery_audit.json'), 'w');
fwrite(fid, jsonencode(S, 'PrettyPrint', true), 'char'); fclose(fid);

fprintf('%-3s %-11s %-8s %-6s %-6s %-8s %-6s %s\n', ...
    'arm', 'task', 'format', 'math', 'verd', 'overall', 'units', 'separation');
for k = 1:numel(rows)
    sep = '-';
    if rows(k).numericValidFormatInvalid, sep = 'math-ok/format-bad'; end
    if rows(k).formatValidNumericInvalid, sep = 'format-ok/math-bad'; end
    fprintf('%-3s %-11s %-8s %-6s %-6s %-8s %-6s %s\n', rows(k).arm, ...
        rows(k).taskId, rows(k).format, rows(k).math, rows(k).verdict, ...
        rows(k).overall, rows(k).units, sep);
end
fprintf('\n%d/%d format-valid, %d/%d math-valid, %d numericsOK-formatBad, %d formatOK-numericsBad\n', ...
    S.nFormatValid, S.nResults, S.nMathValid, S.nResults, ...
    S.nNumericValidFormatInvalid, S.nFormatValidNumericInvalid);
fprintf('v2 agreement %d/%d, inputs unchanged=%d, pass=%d\n', ...
    nAgree, nCompared, S.inputsUnchanged, S.pass);

    function spec = contract_from(a)
        spec = struct('schema', 'mas-delivery-contract/1', ...
            'profile', 'mas-result/1-legacy', 'taskId', char(a.id), ...
            'expectedVerdict', char(a.verdict), 'fields', a.fields);
    end
end

% ===========================================================================
function P = arm_summary(rows, arms)
P = struct('arm', {}, 'n', {}, 'formatPass', {}, 'mathPass', {}, ...
    'verdictPass', {}, 'overallPass', {}, 'numericValidFormatInvalid', {}, ...
    'formatValidNumericInvalid', {});
for a = arms
    hit = strcmp({rows.arm}, char(a));
    P(end+1) = struct('arm', char(a), 'n', nnz(hit), ...
        'formatPass', nnz(hit & strcmp({rows.format}, 'PASS')), ...
        'mathPass', nnz(hit & strcmp({rows.math}, 'PASS')), ...
        'verdictPass', nnz(hit & strcmp({rows.verdict}, 'PASS')), ...
        'overallPass', nnz(hit & strcmp({rows.overall}, 'PASS')), ...
        'numericValidFormatInvalid', nnz(hit & [rows.numericValidFormatInvalid]), ...
        'formatValidNumericInvalid', nnz(hit & [rows.formatValidNumericInvalid])); %#ok<AGROW>
end
end

function h = sha256_file(p)
fid = fopen(p, 'r');
if fid < 0, error('p57_delivery_audit:hash', 'cannot open %s', p); end
b = fread(fid, Inf, '*uint8'); fclose(fid);
md = java.security.MessageDigest.getInstance('SHA-256');
d = typecast(md.digest(b), 'uint8');
h = lower(reshape(dec2hex(d)', 1, []));
end
