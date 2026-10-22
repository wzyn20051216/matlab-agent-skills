% Task 2 focused verification: routing, contracts, graph, capability, data suites.
clear functions; rehash;
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(here));
addpath(fullfile(repo, 'matlab', 'validation', 'phase4'));
for d = {'skills/matlab-orchestrator/scripts','skills/matlab-orchestrator/tests', ...
         'skills/matlab-testing-ci/scripts','skills/matlab-testing-ci/tests', ...
         'skills/matlab-data-analysis/scripts','skills/matlab-data-analysis/tests'}
    addpath(fullfile(repo, d{1}));
end
L = {};
step = @(name, fn) struct('name', name, 'fn', fn);
S = { step('routing', @() test_routing(false)); ...
      step('routingContract', @() test_routing_contract(false)); ...
      step('skillGraph', @() test_skill_graph(false)); ...
      step('capability', @() mas_capability_check()); ...
      step('tableAudit', @() test_table_audit(false)); ...
      step('dataContract', @() test_data_contract(false)) };
for k = 1:numel(S)
    try
        r = S{k}.fn();
        if isfield(r, 'pass')
            L{end+1} = sprintf('%-16s %d/%d %s', S{k}.name, r.nPass, r.nTotal, ...
                char(string(r.pass))); %#ok<SAGROW>
        else
            L{end+1} = sprintf('%-16s %s %s', S{k}.name, r.verdict, r.detail); %#ok<SAGROW>
        end
    catch ME
        L{end+1} = sprintf('%-16s ERROR %s', S{k}.name, ME.message); %#ok<SAGROW>
    end
end
txt = strjoin(L, sprintf('\n'));
fprintf('%s\n', txt);
fid = fopen(fullfile(here, 'task2_verify.txt'), 'w');
if fid >= 0, fwrite(fid, txt, 'char'); fclose(fid); end
