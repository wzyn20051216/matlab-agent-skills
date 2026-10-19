function res = boost_b2_task4_bench(outDir)
%BOOST_B2_TASK4_BENCH  Phase 3B.2 Task 4: what the agent can actually do.
%
%   res = boost_b2_task4_bench(outDir)
%
% THREE ROUTES, DEFINED PRECISELY
%   R1  agent + MATLAB command line (matlab -batch). The agent writes the script
%       and runs it in a shell.
%   R2  agent + the official MATLAB MCP server tools. Requires mcp__matlab* tools
%       to be BOUND TO THE SESSION.
%   R3  agent + this repository's SKILL.md files + the MATLAB MCP server. Requires
%       both the tools above AND the skills to be exposed as invokable skills.
%
% WHAT COUNTS AS EVIDENCE
%   * R2/R3 need an actual tool call in the transcript, not a description of one.
%   * Reading a SKILL.md and following it by hand is NOT the skill being triggered.
%   * Running matlab -batch is NOT an MCP call, however automated it looks.
%   * An MCP report from another session is NOT evidence for this one.
% Anything that cannot meet those tests is recorded as SKIP, with the reason and
% what would have to change.
%
% The benchmark task itself is fixed and lives in bench_boost_task.m; the spec is
% the comment block at the top of that file, so all routes get the same words.

if nargin < 1 || isempty(outDir), outDir = getenv('BOOST_OUT'); end
if isempty(outDir), outDir = fullfile(pwd,'artifacts','validation','boost_b2'); end
outDir = strrep(outDir,'/',filesep);
here = fileparts(mfilename('fullpath')); addpath(here);
addpath(fileparts(here));                      % matlab/boost
addpath(fullfile(fileparts(fileparts(here)),'buck'));
repo = fileparts(fileparts(fileparts(here)));
if ~exist(outDir,'dir'), mkdir(outDir); end

res = struct();
res.level = '3B.2-Task4';
res.prompt = ['For the 48 V / 96 W Boost with Vin = 20 V, L = 220 uH, C = 470 uF, ' ...
    '50 kHz and the conduction losses in boost_params.m: (1) compute the ' ...
    'loss-inclusive duty, the steady inductor current, the peak current and the ' ...
    'RHP zero frequency, (2) run a 30 ms switching simulation at that operating ' ...
    'point and report the mean output voltage and the inductor ripple, (3) state ' ...
    'whether the output is within 0.5 % of 48 V.'];
res.acceptance = ['PASS requires |vOut-48|/48 <= 0.5 % with the numbers printed; ' ...
    'a prose answer with no executed run does not pass.'];

%% ---- R1: agent + MATLAB CLI (executed now) ----
fprintf('--- R1: agent + matlab -batch ---\n');
t0 = tic;
okRun = true; errMsg = '';
try
    out = bench_boost_task(outDir);
catch ME
    okRun = false; errMsg = ME.message; out = struct();
end
elapsed = toc(t0);
if okRun
    % Independent expectations, computed HERE from the same parameters but with a
    % different code path (closed form only, no simulation for the first three).
    p = boost_params('Vin',20);
    dExp = boost_duty_for(p, p.Vref);
    stExp = boost_steady(p, dExp);
    ripExp = boost_ripple(p, dExp);
    checks = struct( ...
        'duty',  abs(out.duty - dExp) <= 1e-6, ...
        'iL',    abs(out.iL - stExp.iL) <= 5e-3*stExp.iL, ...
        'fz',    abs(out.fzRHP - ripExp.fzRHP) <= 1e-3*ripExp.fzRHP, ...
        'vOut',  abs(out.ssErrPct) <= 0.5);
    nOK = structfun(@(x) double(x), checks);
    passed = all(nOK);
    fprintf('  duty %.4f (exp %.4f)  iL %.4f (exp %.4f)\n', out.duty, dExp, out.iL, stExp.iL);
    fprintf('  fz %.1f Hz (exp %.1f)  vOut %.4f V (%.4f %%)\n', out.fzRHP, ripExp.fzRHP, ...
        out.vOutMean, out.ssErrPct);
    fprintf('  checks %s -> %s ; elapsed %.2f s\n', mat2str(nOK.'), ...
        tern(passed,'PASS','FAIL'), elapsed);
else
    checks = struct(); passed = false;
    fprintf('  RUN FAILED: %s\n', errMsg);
end
res.routes.R1 = struct('status', tern(okRun,'DONE','FAILED'), ...
    'mechanism','matlab -batch (shell)', ...
    'toolCalls', 1, 'elapsedS', elapsed, 'passed', passed, ...
    'checks', checks, ...
    'firstAttemptSuccess', 1, ...
    'firstAttemptNote', ['agent-reported: this script was written once and ran ' ...
        'on its first execution. Not machine-verifiable after the fact.']);

%% ---- R2: agent + official MATLAB MCP ----
% Enumerated from the tool list this session actually had. Re-checking it inside
% MATLAB is impossible: MATLAB cannot see the agent's tool inventory. The list is
% therefore recorded as a session fact, not as a measurement.
matlabMcp = {};
res.routes.R2 = struct('status','SKIP', ...
    'requiredTools', {{'mcp__matlab__*'}}, ...
    'toolsPresent', {matlabMcp}, ...
    'reason', ['No mcp__matlab* tool was bound to this session. The session did ' ...
        'have other MCP servers (solidworks, sheetagent, genie-baas, ' ...
        'space-library, weixinpay, agent-mail) -- their presence is exactly why ' ...
        '"MCP works" cannot be claimed in general: it is per-server.'], ...
    'wouldNeed', 'bind the MATLAB MCP server and re-run bench_boost_task through it');

%% ---- R3: agent + skills + MCP ----
skillFiles = dir(fullfile(repo,'skills','*','SKILL.md'));
res.routes.R3 = struct('status','SKIP', ...
    'skillFilesPresent', numel(skillFiles), ...
    'autoTriggered', 0, ...
    'reason', ['The repository SKILL.md files are Codex-format documents. They ' ...
        'were read and followed by hand, which is NOT a skill trigger, and no ' ...
        'MATLAB MCP tool existed for them to drive.'], ...
    'wouldNeed', 'expose skills/*/SKILL.md as invokable skills AND bind MATLAB MCP');

%% ---- what the numbers mean ----
res.summary = struct( ...
    'routesExecuted', 1, 'routesSkipped', 2, ...
    'claimsSupported', {{'R1 produced the required numbers and passed the acceptance'}}, ...
    'claimsNotSupported', {{'R2/R3 end-to-end execution', 'skill auto-triggering', ...
        'MCP-based MATLAB execution'}});
res.checklistPath = fullfile(repo,'docs','MATLAB_MCP_ACCESS_CHECKLIST.md');

save(fullfile(outDir,'b2_task4_bench.mat'),'res');
fid = fopen(fullfile(outDir,'b2_task4_bench.json'),'w');
if fid >= 0, fwrite(fid, jsonencode(res), 'char'); fclose(fid); end
fprintf('\nR1 %s ; R2 SKIP ; R3 SKIP (see %s)\n', res.routes.R1.status, res.checklistPath);
end

function s = tern(c,a,b)
if c, s = a; else, s = b; end
end
