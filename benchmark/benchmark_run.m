function summary = benchmark_run(tasksFile, outDir, varargin)
%BENCHMARK_RUN  Execute benchmark tasks from a PUBLIC task file (no answers).
%
%   summary = benchmark_run(tasksFile, outDir)
%   summary = benchmark_run(tasksFile, outDir, 'limit', 3)
%
% The runner is the tool-level baseline: it does exactly the deterministic part
% of an agent episode -- route the prompt, select the declared tool, build the
% fixture, call the tool, capture every output -- but it does NOT reason. Its
% result is therefore reported as a tool-level baseline, never as an Agent
% benchmark. Answers are not read here; grading happens separately in
% benchmark_grade.m against the sealed answer file.
%
% Every task writes:
%   result_<id>.json     verdict + reported fields + input/output hashes
%   trajectory_<id>.jsonl one JSON object per step (inputs, route, call, result)
%   input_<id>.mat       the exact inputs passed to the tool
%   output_<id>.mat      the full tool result (not just the reported fields)

if nargin < 2 || isempty(outDir), error('benchmark_run:args', 'need tasksFile and outDir'); end
limit = Inf;
for k = 1:2:numel(varargin)
    if strcmpi(varargin{k}, 'limit'), limit = varargin{k+1}; end
end

here = fileparts(mfilename('fullpath'));
repo = fileparts(here);
addpath(here);
addpath(fullfile(repo, 'skills', 'matlab-orchestrator', 'scripts'));
for d = {'matlab-signal-vision-ai', 'matlab-data-analysis', 'matlab-robotics-autonomy'}
    addpath(fullfile(repo, 'skills', d{1}, 'scripts'));
end

if ~isfolder(outDir), mkdir(outDir); end
CFG = jsondecode(fileread(tasksFile));
T = CFG.tasks;
if isstruct(T), T = num2cell(T(:)); end
if isempty(T), error('benchmark_run:tasks', 'no tasks in %s', tasksFile); end
n = min(numel(T), limit);

env = environment_row(repo);
summary = struct('schema', 'mas-benchmark-run/1', 'tasksFile', tasksFile, ...
    'tasksSha256', sha256_file(tasksFile), 'outDir', outDir, ...
    'startedAt', datestr(now, 31), 'nTasks', n, 'rows', []);
rows = cell(1, n);

for k = 1:n
    task = T{k};
    rows{k} = run_one(task, outDir, env);
end

summary.rows = [rows{:}];
summary.finishedAt = datestr(now, 31);
summary.matlabVersion = version;
summary.environment = env;
write_json(fullfile(outDir, 'run_summary.json'), summary);
end

% ===========================================================================
function row = run_one(task, outDir, env)
id = char(task.id);
traj = fullfile(outDir, sprintf('trajectory_%s.jsonl', id));
if isfile(traj), delete(traj); end

row = struct('taskId', id, 'domain', char(task.domain), 'kind', char(task.kind), ...
    'skillExpected', char(task.skill), 'toolExpected', char(task.tool), ...
    'routePrimary', '', 'routeDecision', '', 'routeMatch', false, ...
    'tool', char(task.tool), 'status', 'ERROR', 'verdict', 'ERROR', ...
    'fields', struct(), 'elapsedS', NaN, 'resultFile', '', 'reason', '');
step(traj, struct('step', 'environment', 'matlabVersion', env.matlabVersion, ...
    'release', env.release, 'computer', env.computer, 'cwd', env.cwd, ...
    'toolboxes', {env.toolboxes}));

t0 = tic;
try
    % ---- 1. task identification: the prompt is the only input here --------
    step(traj, struct('step', 'input', 'prompt', char(task.prompt), ...
        'fixture', char(task.fixture), 'seed', getfield_or(task, 'seed', 53)));

    % ---- 2. routing -------------------------------------------------------
    rt = tic;
    route = mas_route(char(task.prompt));
    routeS = toc(rt);
    row.routePrimary = route.primary; row.routeDecision = route.decision;
    row.routeMatch = strcmp(route.primary, char(task.skill)) && strcmp(route.decision, 'ROUTE');
    step(traj, struct('step', 'route', 'primary', route.primary, ...
        'decision', route.decision, 'reason', route.reason, ...
        'secondary', {route.secondary}, 'elapsedS', routeS));

    % ---- 3. capability selection (declared by the task, checked above) ----
    step(traj, struct('step', 'capability', 'skillExpected', char(task.skill), ...
        'tool', char(task.tool), 'toolboxRequirements', ...
        {getfield_or(task, 'requires', {})}));

    % ---- 4. inputs and execution -----------------------------------------
    [args, spec, inputs] = benchmark_fixtures(char(task.fixture), getfield_or(task, 'seed', 53));
    inFile = fullfile(outDir, sprintf('input_%s.mat', id));
    save(inFile, '-struct', 'inputs');
    inSha = sha256_file(inFile);
    step(traj, struct('step', 'fixture', 'spec', spec, 'inputFile', inFile, ...
        'inputSha256', inSha));

    et = tic;
    res = feval(char(task.tool), args{:});
    toolS = toc(et);
    row.tool = char(task.tool); row.status = 'OK';
    row.verdict = res.verdict;

    % ---- 5. reported fields (declared before the run) ---------------------
    fields = struct();
    names = task.report;
    if ischar(names), names = {names}; end
    for q = 1:numel(names)
        nm = char(names{q});
        fields.(strrep(nm, '.', '_')) = scalar_field(res, nm);
    end
    row.fields = fields;
    outFile = fullfile(outDir, sprintf('output_%s.mat', id));
    save(outFile, 'res');
    row.resultFile = fullfile(outDir, sprintf('result_%s.json', id));
    checks = check_table(res);
    step(traj, struct('step', 'tool_call', 'tool', char(task.tool), ...
        'verdict', res.verdict, 'checks', {checks}, 'fields', fields, ...
        'elapsedS', toolS, 'outputFile', outFile));
    row.elapsedS = toc(t0);
    result = struct('schema', 'mas-benchmark-result/1', 'taskId', id, ...
        'domain', char(task.domain), 'kind', char(task.kind), ...
        'prompt', char(task.prompt), 'skillExpected', char(task.skill), ...
        'routePrimary', row.routePrimary, 'routeDecision', row.routeDecision, ...
        'routeMatch', row.routeMatch, 'tool', char(task.tool), ...
        'verdict', row.verdict, 'fields', fields, 'checks', {checks}, ...
        'inputFile', inFile, 'inputSha256', inSha, 'outputFile', outFile, ...
        'elapsedS', row.elapsedS, 'matlabVersion', version, ...
        'timestamp', datestr(now, 31));
    write_json(row.resultFile, result);
    step(traj, struct('step', 'delivery', 'resultFile', row.resultFile, ...
        'resultSha256', sha256_file(row.resultFile)));
catch ME
    row.status = 'ERROR'; row.verdict = 'ERROR'; row.reason = ME.message;
    row.elapsedS = toc(t0);
    step(traj, struct('step', 'error', 'message', ME.message, ...
        'identifier', ME.identifier));
    result = struct('schema', 'mas-benchmark-result/1', 'taskId', id, ...
        'status', 'ERROR', 'verdict', 'ERROR', 'error', ME.message, ...
        'matlabVersion', version, 'timestamp', datestr(now, 31));
    row.resultFile = fullfile(outDir, sprintf('result_%s.json', id));
    write_json(row.resultFile, result);
end
end

% ===========================================================================
function step(file, obj)
fid = fopen(file, 'a');
if fid < 0, return; end
fprintf(fid, '%s\n', jsonencode(obj));
fclose(fid);
end

function v = getfield_or(s, name, defaultValue)
if isfield(s, name) && ~isempty(s.(name)), v = s.(name); else, v = defaultValue; end
end

function v = scalar_field(res, nm)
parts = strsplit(nm, '.');
x = res;
for k = 1:numel(parts)
    if ~isstruct(x) || ~isfield(x, parts{k})
        error('benchmark_run:field', 'result has no field "%s"', nm);
    end
    x = x.(parts{k});
end
if ischar(x)
    v = x;
elseif isnumeric(x) && isscalar(x)
    v = double(x);
elseif islogical(x) && isscalar(x)
    v = logical(x);
elseif isstruct(x) && isscalar(x)
    v = x;
else
    v = sprintf('<%s %s>', class(x), mat2str(size(x)));
end
end

function C = check_table(res)
C = struct('id', {}, 'status', {});
if isfield(res, 'checks') && isstruct(res.checks)
    for k = 1:numel(res.checks)
        C(end+1) = struct('id', res.checks(k).id, 'status', res.checks(k).status); %#ok<AGROW>
    end
end
end

function env = environment_row(repo)
tb = {};
names = {'Signal_Toolbox', 'Statistics_Toolbox', 'Robotics_System_Toolbox', ...
    'Control_Toolbox', 'Simulink', 'Navigation_Toolbox', 'ROS_Toolbox'};
for k = 1:numel(names)
    tb{end+1} = sprintf('%s=%d', names{k}, license('test', names{k})); %#ok<AGROW>
end
env = struct('matlabVersion', version, 'release', matlabRelease(), ...
    'computer', computer(), 'cwd', repo, 'toolboxes', {tb});
end

function h = sha256_file(p)
fid = fopen(p, 'r');
if fid < 0, error('benchmark_run:hash', 'cannot open %s', p); end
b = fread(fid, Inf, '*uint8'); fclose(fid);
md = java.security.MessageDigest.getInstance('SHA-256');
d = typecast(md.digest(b), 'uint8');
h = lower(reshape(dec2hex(d)', 1, []));
end

function write_json(p, obj)
fid = fopen(p, 'w');
if fid < 0, error('benchmark_run:write', 'cannot write %s', p); end
fwrite(fid, jsonencode(obj), 'char');
fclose(fid);
end
