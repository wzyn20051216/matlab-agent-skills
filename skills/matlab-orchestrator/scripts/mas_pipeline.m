function trace = mas_pipeline(taskId, opts)
%MAS_PIPELINE  Natural language -> route -> precheck -> execute -> verify.
%
%   trace = mas_pipeline('D3')
%   trace = mas_pipeline('all')
%   trace = mas_pipeline('D3', struct('outDir','artifacts/pipeline'))
%
% Every step is recorded, with a timestamp and the actual call that produced it, so
% the trace is auditable without trusting a summary:
%
%   trace.steps       {route, products, execute, verify} with tStart/tEnd/status
%   trace.skill       primary skill chosen by mas_route for the TASK'S OWN prompt
%   trace.skillMatch  did the router pick the skill the task was written for?
%   trace.verdict     PASS / FAIL / UNDETERMINED / SKIP  (from mas_verify_task)
%   trace.selfVerdict what the task said about itself (recorded, NOT used)
%
% WHY THE PROMPT IS PART OF THE TASK DEFINITION
% Routing a task with a hand-written short label measures the label, not the task.
% The prompt stored in assets/tasks.json is the same sentence a user would type, and
% that is what goes through the router -- so `skillMatch` is a statement about the
% router, and the report says so rather than implying the agent chose it.

if nargin < 2, opts = struct(); end
opts = dflt(opts, struct('outDir', '', 'verbose', true));

here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
R = jsondecode(fileread(fullfile(fileparts(here), 'assets', 'tasks.json')));
tasks = R.tasks;
if isstruct(tasks) && numel(tasks) == 1 && isfield(tasks, 'id') && iscell(tasks.id)
    % jsondecode of an array of objects with identical fields returns a struct array;
    % convert to a cell list so indexing is uniform
    n = numel(tasks.id);
    C = cell(1, n);
    for k = 1:n, C{k} = structfun(@(v) v(k), tasks, 'UniformOutput', false); end
    tasks = C;
elseif isstruct(tasks) && numel(tasks) > 1
    tasks = num2cell(tasks);
elseif isstruct(tasks) && numel(tasks) == 1
    tasks = {tasks};
end

if strcmpi(taskId, 'all')
    sel = tasks;
else
    sel = {};
    for k = 1:numel(tasks)
        if strcmpi(tasks{k}.id, taskId), sel = {tasks{k}}; break; end
    end
    if isempty(sel), error('mas_pipeline:id', 'no task "%s" in the registry', taskId); end
end

addpath(here);
addpath(fullfile(repo, 'skills', 'matlab-runner', 'scripts'));
addpath(fullfile(repo, 'skills', 'matlab-testing-ci', 'scripts'));
addpath(fullfile(repo, 'matlab', 'validation', 'crossdomain'));
addpath(fullfile(repo, 'matlab', 'validation', 'crossdomain', 'tasks'));

out = struct('id', {}, 'prompt', {}, 'skill', {}, 'expectedSkill', {}, 'skillMatch', {}, ...
    'products', {}, 'executed', {}, 'verdict', {}, 'selfVerdict', {}, ...
    'detail', {}, 'steps', {}, 'elapsedS', {}, 'values', {});
if opts.verbose
    fprintf('%-4s %-10s %-6s %-14s %s\n', 'id', 'skill', 'match', 'verdict', 'detail');
end

for k = 1:numel(sel)
    t = sel{k};
    T0 = tic;

    % ---- step 1: route -----------------------------------------------------
    s1 = tic;
    rr = mas_route(t.prompt);
    skill = rr.primary;
    match = strcmp(skill, t.expectedSkill);
    step_route = step('route', s1, ternary(rr.decision == "ROUTE" || ...
        strcmp(rr.decision, 'ROUTE'), 'OK', rr.decision), ...
        sprintf('%s -> %s (%s)', t.prompt, skill, rr.decision));

    % ---- step 2: dependencies ---------------------------------------------
    s2 = tic;
    missing = {};
    if isfield(t, 'products') && ~isempty(t.products)
        pl = t.products;
        if ischar(pl), pl = {pl}; end
        for q = 1:numel(pl)
            d = mas_dep_probe('product', pl{q});
            if ~d.pass, missing{end+1} = sprintf('%s: %s', pl{q}, d.state); end %#ok<AGROW>
        end
    end
    step_dep = step('products', s2, ternary(isempty(missing), 'OK', 'MISSING'), ...
        ternary(isempty(missing), 'all present', strjoin(missing, '; ')));

    if ~isempty(missing)
        out(end+1) = pack(t, skill, match, step_dep, false, 'SKIP', '', ...
            strjoin(missing, '; '), [step_route step_dep], toc(T0), struct()); %#ok<AGROW>
        if opts.verbose
            fprintf('%-4s %-10s %-6d %-14s %s\n', t.id, shortid(skill), match, 'SKIP', ...
                strjoin(missing, '; '));
        end
        continue;
    end

    % ---- step 3: execute ---------------------------------------------------
    s3 = tic;
    try
        res = feval(t.entry);
        ec = 'OK';
        vals = res.values;
        selfV = res.status;
        det = res.detail;
    catch ME
        ec = ['ERROR: ' ME.message];
        vals = struct(); selfV = 'ERROR'; det = ME.message;
    end
    step_exec = step('execute', s3, ternary(strcmp(ec, 'OK'), 'OK', 'FAILED'), ec);

    % ---- step 4: independent verification ----------------------------------
    s4 = tic;
    v = mas_verify_task(t.id, vals);
    step_ver = step('verify', s4, v.status, v.detail);

    out(end+1) = pack(t, skill, match, step_exec, true, v.status, selfV, v.detail, ...
        [step_route step_dep step_exec step_ver], toc(T0), vals); %#ok<AGROW>
    if opts.verbose
        fprintf('%-4s %-10s %-6d %-14s %s\n', t.id, shortid(skill), match, v.status, ...
            shorten(v.detail, 62));
    end
end

trace = struct();
trace.level = 'pipeline';
trace.records = out;
trace.nTasks = numel(out);
trace.nPass = nnz(strcmp({out.verdict}, 'PASS'));
trace.nFail = nnz(strcmp({out.verdict}, 'FAIL'));
trace.nUndet = nnz(strcmp({out.verdict}, 'UNDETERMINED'));
trace.nSkip = nnz(strcmp({out.verdict}, 'SKIP'));
trace.skillMatchRate = mean([out.skillMatch]);
trace.selfDisagreement = nnz(~strcmp({out.selfVerdict}, {out.verdict}));
trace.elapsedS = sum([out.elapsedS]);
trace.matlabVersion = version;
trace.timestamp = datestr(now, 31);

if opts.verbose
    fprintf('\n%d tasks: PASS %d / FAIL %d / UNDETERMINED %d / SKIP %d\n', ...
        trace.nTasks, trace.nPass, trace.nFail, trace.nUndet, trace.nSkip);
    fprintf('router agreed with the task''s intended skill on %d/%d\n', ...
        nnz([out.skillMatch]), trace.nTasks);
end

if ~isempty(opts.outDir)
    d = strrep(opts.outDir, '/', filesep);
    if ~exist(d, 'dir'), mkdir(d); end
    json = jsonencode(rmfield(trace, 'records'));
    fid = fopen(fullfile(d, 'pipeline.json'), 'w');
    if fid >= 0, fwrite(fid, json, 'char'); fclose(fid); end
    % the per-record values need their own file: they contain task-specific fields
    fid = fopen(fullfile(d, 'pipeline_records.json'), 'w');
    if fid >= 0, fwrite(fid, jsonencode(out), 'char'); fclose(fid); end
end
end

% ---------------------------------------------------------------------------
function s = step(name, t0, status, detail)
s = struct('name', name, 'tStart', t0, 'elapsedS', toc(t0), ...
    'status', status, 'detail', detail);
end

function r = pack(t, skill, match, execStep, executed, verdict, selfV, detail, steps, el, vals)
r = struct('id', t.id, 'prompt', t.prompt, 'skill', skill, ...
    'expectedSkill', t.expectedSkill, 'skillMatch', match, ...
    'products', {t.products}, 'executed', executed, 'verdict', verdict, ...
    'selfVerdict', selfV, 'detail', detail, 'steps', steps, ...
    'elapsedS', el, 'values', vals);
end

function s = shortid(s)
if numel(s) > 10, s = s(1:10); end
end

function s = shorten(s, n)
if numel(s) > n, s = [s(1:n-3) '...']; end
end

function o = dflt(o, d)
f = fieldnames(d);
for k = 1:numel(f)
    if ~isfield(o, f{k}), o.(f{k}) = d.(f{k}); end
end
end

function y = ternary(c, a, b)
if c, y = a; else, y = b; end
end
