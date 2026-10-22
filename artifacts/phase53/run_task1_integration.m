function run_task1_integration()
% Phase 5.3 Task 1: integration checks after the signal-domain enhancement.
% Routing table, capability matrix, pipeline route-match, new-capability probes.
repo = fileparts(fileparts(fileparts(mfilename('fullpath'))));
addpath(fullfile(repo,'skills','matlab-orchestrator','scripts'));
addpath(fullfile(repo,'skills','matlab-orchestrator','tests'));
addpath(fullfile(repo,'skills','matlab-testing-ci','scripts'));
addpath(fullfile(repo,'skills','matlab-testing-ci','tests'));
addpath(fullfile(repo,'skills','matlab-signal-vision-ai','scripts'));
addpath(fullfile(repo,'skills','matlab-signal-vision-ai','tests'));
addpath(fullfile(repo,'skills','matlab-runner','scripts'));
addpath(fullfile(repo,'skills','matlab-runner','tests'));

r1 = test_routing(false);          fprintf('routing %d/%d\n', r1.nPass, r1.nTotal);
r2 = test_routing_contract(false); fprintf('routingContract %d/%d\n', r2.nPass, r2.nTotal);
r3 = test_skill_graph(false);      fprintf('skillGraph %d/%d\n', r3.nPass, r3.nTotal);
r4 = test_capability(false);       fprintf('capability %d/%d\n', r4.nPass, r4.nTotal);
c = mas_capability_check();        fprintf('matrix %s %d/%d\n', c.verdict, c.nPass, c.nTotal);

% every pipeline task prompt must still route to its expected skill with the
% nine new signal terms in the table (terms are additive; no pinned prompt
% contains any of them)
R = jsondecode(fileread(fullfile(repo,'skills','matlab-orchestrator','assets','tasks.json')));
tasks = R.tasks; nMatch = 0; bad = {};
for k = 1:numel(tasks)
    t = tasks{k};
    rr = mas_route(t.prompt);
    m = strcmp(rr.primary, t.expectedSkill);
    nMatch = nMatch + m;
    if ~m, bad{end+1} = sprintf('%s -> %s expected %s', t.id, rr.primary, t.expectedSkill); end
end
fprintf('pipeline route-match %d/%d\n', nMatch, numel(tasks));
if ~isempty(bad), fprintf('  MISMATCH: %s\n', bad{:}); end

q = {'计算功率谱密度并检查泄漏','检查采样率是否满足采样定理，是否存在混叠', ...
     '分析 Eb/N0 与误码率的关系','帮我做 PSD 分析'};
for k = 1:numel(q)
    rr = mas_route(q{k});
    fprintf('new-term probe: %s -> %s %s\n', q{k}, rr.decision, rr.primary);
end

r5 = test_signal_contract(false); fprintf('signalContract %d/%d\n', r5.nPass, r5.nTotal);
r6 = test_signal_vision(false);   fprintf('signalVision %d/%d\n', r6.nPass, r6.nTotal);
end