scriptPath = mfilename('fullpath');
repoRoot = fileparts(fileparts(fileparts(fileparts(fileparts(scriptPath)))));
cd(repoRoot);
addpath(fullfile(repoRoot, 'skills', 'matlab-orchestrator', 'scripts'));
addpath(fullfile(repoRoot, 'skills', 'matlab-testing-ci', 'scripts'));

cases = { ...
    'simulink', 'build a simulink model with stateflow', 'matlab-simulink-modeling'; ...
    'signal',   'analyze OFDM bit error rate',            'matlab-signal-vision-ai'; ...
    'control',  'tune a PID controller with pidtune',     'matlab-control-optimization'; ...
    'data',     'load a csv table and plot',              'matlab-data-analysis'; ...
    'codegen',  'generate c code with matlab coder for stm32', 'matlab-codegen-deploy'; ...
    'robotics', 'robot manipulator jacobian trajectory',  'matlab-robotics-autonomy'; ...
    'testing',  'set up github actions ci for matlab unit tests', 'matlab-testing-ci'};

ok = true;
for k = 1:size(cases, 1)
    r = mas_route(cases{k, 2});
    hasExpected = any(strcmp(r.loadOrder, cases{k, 3}));
    hasRunner = any(strcmp(r.loadOrder, 'matlab-runner'));
    fprintf('ROUTE %-9s decision=%-8s expected=%-30s present=%d runner=%d primary=%s\n', ...
        cases{k, 1}, r.decision, cases{k, 3}, hasExpected, hasRunner, r.primary);
    ok = ok && strcmp(r.decision, 'ROUTE') && hasExpected && hasRunner;
end

cap = mas_capability_check('all');
fprintf('CAPABILITY ok=%d checks=%d verdict=%s\n', cap.ok, numel(cap.checks), cap.verdict);
ok = ok && cap.ok;

assert(ok, 'TASK6_CONSISTENCY_FAILED');
fprintf('TASK6_CONSISTENCY PASS\n');
