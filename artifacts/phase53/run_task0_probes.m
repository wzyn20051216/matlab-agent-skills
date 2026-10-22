function run_task0_probes()
%RUN_TASK0_PROBES  Phase 5.3 Task 0: cross-model dist_enter probe, licence probe,
%                  capability discoverability, skill-graph consistency.
%   Writes logs + JSON into artifacts/phase53/evidence/.

repo = 'E:\desktop\MATLAB';
out = fullfile(repo, 'artifacts', 'phase53', 'evidence');
if ~exist(out, 'dir'), mkdir(out); end

addpath(fullfile(repo, 'matlab', 'validation', 'phase53'));
addpath(fullfile(repo, 'skills', 'matlab-simulink-modeling', 'scripts'));
addpath(fullfile(repo, 'skills', 'matlab-runner', 'scripts'));
addpath(fullfile(repo, 'skills', 'matlab-orchestrator', 'scripts'));
addpath(fullfile(repo, 'skills', 'matlab-orchestrator', 'tests'));

% ---- 1. dist_enter cross-model probe -------------------------------------
try
    txt = evalc('probe_dist_models();');
    fwrite(fopen(fullfile(out, 'probe_dist_models.log'), 'w'), txt, 'char');
catch ME
    fwrite(fopen(fullfile(out, 'probe_dist_models.log'), 'w'), ...
        sprintf('PROBE_ERROR: %s\n%s\n', ME.message, getReport(ME)), 'char');
end

% ---- 2. licence probe ----------------------------------------------------
try
    txt = evalc('phase53_license_probe();');
    fwrite(fopen(fullfile(out, 'probe_license.log'), 'w'), txt, 'char');
catch ME
    fwrite(fopen(fullfile(out, 'probe_license.log'), 'w'), ...
        sprintf('PROBE_ERROR: %s\n%s\n', ME.message, getReport(ME)), 'char');
end

% ---- 3. capability discoverability ---------------------------------------
try
    txt = evalc(['c = mas_capability_check(''all''); ' ...
        'fprintf(''%s | %s | %d/%d\n'', c.verdict, c.detail, c.nPass, c.nTotal); ' ...
        'disp(c.checks);']);
    fwrite(fopen(fullfile(out, 'probe_capability.log'), 'w'), txt, 'char');
catch ME
    fwrite(fopen(fullfile(out, 'probe_capability.log'), 'w'), ...
        sprintf('PROBE_ERROR: %s\n', ME.message), 'char');
end

% ---- 4. skill graph ------------------------------------------------------
try
    txt = evalc(['g = mas_skill_graph(''all''); ' ...
        'fprintf(''%s | %s | %d/%d\n'', g.verdict, g.detail, g.nPass, g.nTotal); ' ...
        'disp(g.checks);']);
    fwrite(fopen(fullfile(out, 'probe_skill_graph.log'), 'w'), txt, 'char');
catch ME
    fwrite(fopen(fullfile(out, 'probe_skill_graph.log'), 'w'), ...
        sprintf('PROBE_ERROR: %s\n', ME.message), 'char');
end

fprintf('TASK0_PROBES done\n');
end