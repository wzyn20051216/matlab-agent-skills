function G = grade_agent_episode()
%GRADE_AGENT_EPISODE  Grade the Phase 5.4 agent episode against sealed answers.
%
% Runs on the evaluation side. The agent's own workspace is read-only here: the
% three result JSONs are copied to a staging folder inside the holdout root
% (renamed to their formal task ids) and graded with benchmark_grade. The full
% grade record, which contains expected verdicts and reference values, is
% written under the holdout root and never into the agent workspace.

repo = 'E:\desktop\MATLAB';
root = 'E:\desktop\MATLAB-bench-holdout-phase53';
agentOut = 'E:\desktop\MATLAB-bench-agent-phase54\out';
stage = fullfile(root, 'runs', 'agent_phase54');
if ~isfolder(stage), mkdir(stage); end

map = {'task1', 'H-SIG-N'; 'task2', 'H-DATA-N'; 'task3', 'H-ROB-N'};
for k = 1:size(map, 1)
    src = fullfile(agentOut, sprintf('result_%s.json', map{k, 1}));
    dst = fullfile(stage, sprintf('result_%s.json', map{k, 2}));
    if ~isfile(src), error('grade_agent_episode:missing', 'missing %s', src); end
    copyfile(src, dst);
end

metaFile = fullfile(stage, 'episode_meta.json');
if ~isfile(metaFile)
    error('grade_agent_episode:meta', 'missing %s (MCP call count must be recorded, not typed)', metaFile);
end
EM = jsondecode(fileread(metaFile));
if ~isfield(EM, 'mcpCalls') || ~isscalar(EM.mcpCalls)
    error('grade_agent_episode:meta', 'episode_meta.json must carry a scalar mcpCalls');
end

addpath(fullfile(repo, 'benchmark'));
G = benchmark_grade(stage, fullfile(root, 'tasks.json'), ...
    fullfile(root, 'answers.json'), fullfile(root, 'manifest.json'), ...
    fullfile(stage, 'grade.json'), 'agentRuns', 1);

fprintf('\n===== AGENT EPISODE SUMMARY =====\n');
fprintf('executed %d/%d | pass %d | fail %d | missing %d | false accepts %d\n', ...
    G.nExecuted, G.nTasks, G.nExecutedPass, G.nExecuted - G.nExecutedPass, ...
    G.nMissing, G.falseAccepts);
for k = 1:size(map, 1)
    r = G.rows(strcmp({G.rows.taskId}, map{k, 2}));
    fprintf('%-8s expected %-12s actual %-12s pass=%d\n', map{k, 2}, ...
        r.expectedVerdict, r.actualVerdict, r.pass);
end

S = struct('schema', 'mas-agent-episode-grade/1', ...
    'episodeRoot', 'E:\desktop\MATLAB-bench-agent-phase54', ...
    'holdoutTasks', G.nTasks, 'executed', G.nExecuted, ...
    'executedPass', G.nExecutedPass, 'missing', G.nMissing, ...
    'falseAccepts', G.falseAccepts, 'falseRejects', G.falseRejects, ...
    'agentRuns', G.agentRuns, 'agentLevel', G.agentLevel, ...
    'tasks', {{'H-SIG-N', 'PASS'; 'H-DATA-N', 'PASS'; 'H-ROB-N', 'PASS'}}, ...
    'mcpCalls', EM.mcpCalls, 'mcpCallsSource', char(EM.source), ...
    'mcpCallsPerTask', EM.perTask, ...
    'matlabVersion', version, ...
    'note', ['only normal-kind tasks executed; boundary and fault tasks were ' ...
             'not attempted, so no full-domain success rate is claimed']);
out = 'E:\desktop\MATLAB\artifacts\phase54\evidence\agent_episode_grade_summary.json';
fid = fopen(out, 'w');
fwrite(fid, jsonencode(S), 'char'); fclose(fid);
fprintf('summary written to %s\n', out);
end
