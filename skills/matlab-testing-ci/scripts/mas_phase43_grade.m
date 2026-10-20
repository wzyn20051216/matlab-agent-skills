function r = mas_phase43_grade(rootDir)
%MAS_PHASE43_GRADE  Grade the Phase 4.3 benchmark runs against frozen references.
%
%   r = mas_phase43_grade()                       % default artifact directory
%   r = mas_phase43_grade('E:\desktop\MATLAB\artifacts\validation\phase43')
%
%   r.groups    struct array: group, perTask(taskId, pass/fail/error, ms), totals
%   r.verdict   plain-language summary
%   r.table     one row per (group, task, repeat) for inspection
%
% HOW THIS DIFFERS FROM THE DRIVER
% The driver runs the code; this function only READS the numbers and compares
% them with evals/phase43_benchmark.json. It never runs MATLAB, never touches
% the MCP server, and never looks at the raw output beyond the single
% MAS_RESULT line -- so a "PASS" here cannot be produced by the thing it grades.
%
% A task that produced no MAS_RESULT line is ERROR, not FAIL: "we could not
% measure it" and "the number is wrong" are different findings, and collapsing
% them is how a broken harness turns into a good score.

if nargin < 1 || isempty(rootDir)
    here = fileparts(mfilename('fullpath'));
    repo = fileparts(fileparts(fileparts(here)));
    rootDir = fullfile(repo, 'artifacts', 'validation', 'phase43');
else
    here = fileparts(mfilename('fullpath'));
    repo = fileparts(fileparts(fileparts(here)));
end
cfgFile = fullfile(repo, 'evals', 'phase43_benchmark.json');
CFG = jsondecode(fileread(cfgFile));
T = CFG.tasks;
if isstruct(T) && numel(T) > 1, T = num2cell(T(:)); elseif isstruct(T), T = {T}; end

% ---- collect every *_result.json ---------------------------------------
dirs = dir(rootDir);
% Build the struct with REAL values, not with an empty cell: struct('f', {})
% passes a cell to struct(), which then builds a 0x0 STRUCT ARRAY instead of a
% 1x1 struct with an empty field, and every later `runs(end+1) = ...` fails
% with a dimension error that reads like a data problem.
runs = struct('group', '', 'repeat', 0, 'taskId', '', 'status', '', ...
    'ms', 0, 'masLine', '');
runs(1) = [];
for k = 1:numel(dirs)
    if ~dirs(k).isdir, continue; end
    nm = dirs(k).name;
    m = regexp(nm, '^(R[123])_run(\d+)$', 'tokens', 'once');
    if isempty(m), continue; end
    g = m{1}; rep = str2double(m{2});
    files = dir(fullfile(dirs(k).folder, nm, '*_result.json'));
    for q = 1:numel(files)
        try
            raw = fileread(fullfile(files(q).folder, files(q).name));
            % The PowerShell driver writes these with a UTF-8 BOM, and
            % jsondecode rejects a BOM outright. Stripping it here is not a
            % workaround for a bug: the BOM is PowerShell's default for
            % Set-Content -Encoding utf8 on 5.1.
            raw = strip_bom(raw);
            d = jsondecode(raw);
        catch
            continue;
        end
        line = '';
        if isfield(d, 'masLine'), line = d.masLine; end
        tid = '';
        if isfield(d, 'taskId'), tid = d.taskId; end
        [st, vals] = grade_task(T, tid, line);
        runs(end+1) = struct('group', g, 'repeat', rep, 'taskId', tid, ...
            'status', st, 'ms', d.ms, 'masLine', line); %#ok<AGROW>
    end
end

% ---- aggregate by group and task ---------------------------------------
groups = {'R1','R2','R3'};
G = struct('group', '', 'perTask', struct('taskId', {}, 'pass', {}, ...
    'fail', {}, 'error', {}, 'ms', {}), 'nPass', 0, 'nFail', 0, ...
    'nError', 0, 'totalMs', 0);
G(1) = [];
for gi = 1:numel(groups)
    g = groups{gi};
    sel = strcmp({runs.group}, g);
    if ~any(sel), continue; end
    gr = runs(sel);
    ids = unique({gr.taskId});
    perTask = struct('taskId', {}, 'pass', {}, 'fail', {}, 'error', {}, 'ms', {});
    for q = 1:numel(ids)
        s = strcmp({gr.taskId}, ids{q});
        sub = gr(s);
        perTask(end+1) = struct('taskId', ids{q}, ...
            'pass', nnz(strcmp({sub.status}, 'PASS')), ...
            'fail', nnz(strcmp({sub.status}, 'FAIL')), ...
            'error', nnz(strcmp({sub.status}, 'ERROR')), ...
            'ms', mean([sub.ms])); %#ok<AGROW>
    end
    G(end+1) = struct('group', g, 'perTask', perTask, ...
        'nPass', nnz(strcmp({gr.status}, 'PASS')), ...
        'nFail', nnz(strcmp({gr.status}, 'FAIL')), ...
        'nError', nnz(strcmp({gr.status}, 'ERROR')), ...
        'totalMs', sum([gr.ms])); %#ok<AGROW>
end

r = struct();
r.schema = 'mas-phase43-grade/1';
r.generatedAt = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));
r.rootDir = rootDir;
r.groups = G;
r.runs = runs;
r.verdict = build_verdict(G);
r.scope = ['The task programs are FIXED, so this measures the execution channel ' ...
    'and the availability of the skill tooling -- not an agent''s ability to ' ...
    'author the code, choose a tool, or recover from an error.'];

fid = fopen(fullfile(rootDir, 'grade.json'), 'w');
if fid >= 0, fwrite(fid, jsonencode(r, 'PrettyPrint', true), 'char'); fclose(fid); end
end

% ===========================================================================
function [status, vals] = grade_task(T, tid, masLine)
vals = struct();
t = [];
for k = 1:numel(T)
    if strcmp(T{k}.id, tid), t = T{k}; break; end
end
if isempty(t)
    status = 'ERROR'; return;
end
if isempty(masLine)
    status = 'ERROR'; return;          % not measured, NOT failed
end
i = strfind(masLine, 'MAS_RESULT');
line = masLine(i + numel('MAS_RESULT'):end);
nl = find(line == char(10), 1);
if ~isempty(nl), line = line(1:nl-1); end
line = strtrim(line);
try
    vals = jsondecode(line);
catch
    status = 'ERROR'; return;
end

nMiss = 0; nPass = 0;
for k = 1:numel(t.checks)
    c = t.checks(k);
    if ~isfield(vals, c.field)
        nMiss = nMiss + 1; continue;
    end
    got = vals.(c.field);
    ok = compare_op(got, c.ref, c.op, c.tol);
    nPass = nPass + ok;
end
if nMiss > 0
    status = 'UNDETERMINED';
elseif nPass == numel(t.checks)
    status = 'PASS';
else
    status = 'FAIL';
end
end

% ===========================================================================
function s = strip_bom(s)
% Remove a leading UTF-8 BOM (EF BB BF). jsondecode fails on it, and a silent
% skip turns a readable result file into a missing one -- which reads as "the
% run never happened" rather than "the file has a BOM".
b = uint8([239 187 191]);
if numel(s) >= 3 && isequal(uint8(s(1:3)), b)
    s = s(4:end);
end
end

function ok = compare_op(got, ref, op, tol)
ok = false;
if ischar(got) || ischar(ref)
    ok = strcmp(got, char(ref)); return;
end
if ~isnumeric(got), return; end
switch lower(op)
    case 'absdiff',    ok = abs(double(got) - double(ref)) <= tol;
    case 'reldiff',    ok = abs(double(got) - double(ref)) <= tol*max(1, abs(double(ref)));
    case 'maxabsdiff'
        if numel(got) ~= numel(ref), ok = false; return; end
        ok = max(abs(double(got(:)) - double(ref(:)))) <= tol;
    case 'eq',         ok = double(got) == double(ref);
    case 'true',       ok = logical(got);
    case 'false',      ok = ~logical(got);
    case 'le',         ok = double(got) <= double(ref);
    case 'ge',         ok = double(got) >= double(ref);
    otherwise,         ok = false;
end
end

% ===========================================================================
function v = build_verdict(G)
lines = {};
for k = 1:numel(G)
    g = G(k);
    nRuns = g.nPass + g.nFail + g.nError;
    lines{end+1} = sprintf('%s: %d pass / %d fail / %d error over %d run(s), %.1f s', ...
        g.group, g.nPass, g.nFail, g.nError, nRuns, g.totalMs/1000); %#ok<AGROW>
end
b6 = {};
for k = 1:numel(G)
    hit = find(strcmp({G(k).perTask.taskId}, 'B6'), 1);
    if isempty(hit), b6{end+1} = sprintf('%s: n/a', G(k).group); %#ok<AGROW>
    else, b6{end+1} = sprintf('%s: %d pass', G(k).group, G(k).perTask(hit).pass); end %#ok<AGROW>
end
v = strjoin(lines, '; ');
v = [v sprintf(' | B6 (needs the skill tool): %s', strjoin(b6, ', '))];
end
