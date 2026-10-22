function run_task3_suites()
%RUN_TASK3_SUITES  Re-run the suites touched by the robotics enhancement.
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(here));
addpath(fullfile(repo, 'skills', 'matlab-orchestrator', 'scripts'));
addpath(fullfile(repo, 'skills', 'matlab-orchestrator', 'tests'));
addpath(fullfile(repo, 'skills', 'matlab-robotics-autonomy', 'scripts'));
addpath(fullfile(repo, 'skills', 'matlab-robotics-autonomy', 'tests'));
suites = { ...
    'routing',         @() test_routing(false); ...
    'routingContract', @() test_routing_contract(false); ...
    'skillGraph',      @() test_skill_graph(false); ...
    'capability',      @() test_capability(false); ...
    'robotics',        @() test_robotics(false); ...
    'roboticsContract',@() test_robotics_contract(false); ...
    'bench',           @() test_bench(false)};
lines = {};
lines{end+1} = sprintf('=== Task 3 suite sweep: %s ===', datestr(now, 31));
nP = 0; nT = 0; bad = 0;
for k = 1:size(suites, 1)
    t0 = tic;
    try
        body = evalc('r = suites{k, 2}();');
        dt = toc(t0);
        p = r.nPass; t = r.nTotal;
        nP = nP + p; nT = nT + t;
        if p == t, tag = 'PASS'; else, tag = 'FAIL'; bad = bad + 1; end
        lines{end+1} = strtrim(body); %#ok<AGROW>
        lines{end+1} = sprintf('%-16s %4d / %4d  %s  (%.1f s)', ...
            suites{k,1}, p, t, tag, dt); %#ok<AGROW>
    catch ME
        bad = bad + 1;
        lines{end+1} = sprintf('%-16s ERROR: %s', suites{k,1}, ME.message); %#ok<AGROW>
        if ~isempty(ME.stack)
            lines{end+1} = sprintf('%-16s at %s line %d', '', ...
                ME.stack(1).name, ME.stack(1).line); %#ok<AGROW>
        end
    end
end
lines{end+1} = '';
lines{end+1} = sprintf('SWEEP: %d / %d, failing suites = %d', nP, nT, bad);
lines{end+1} = sprintf('MATLAB %s', version);
all = strjoin(lines, sprintf('\n'));
fprintf('%s\n', all);
logFile = fullfile(here, 'task3_suites.txt');
fid = fopen(logFile, 'w');
if fid >= 0, fwrite(fid, all, 'char'); fclose(fid); end
fprintf('\nlog written to %s (%d bytes)\n', logFile, numel(all));
end
