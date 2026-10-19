function res = boost_b1_task6_agent(outDir)
%BOOST_B1_TASK6_AGENT  Part 6: what was actually verified about agent capability.
%
% This file records only what can be MEASURED from inside MATLAB plus the
% environment facts that decide which of the three execution routes were
% available. It deliberately does NOT claim an MCP/Skills end-to-end pass.
%
% The three routes the brief asks about:
%   R1  bare agent + MATLAB command line
%   R2  agent using the official MATLAB MCP tools
%   R3  agent using this project's Skills + MATLAB MCP
% R2 and R3 require MATLAB MCP tools to be bound to the agent session and the
% repository's SKILL.md files to be exposed as invokable skills. Neither was true
% in this session, so both are SKIP -- a SKIP is not a pass.

if nargin < 1 || isempty(outDir), outDir = getenv('BOOST_OUT'); end
outDir = strrep(outDir,'/',filesep);
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
if ~exist(outDir,'dir'), mkdir(outDir); end

scripts = {'boost_b1_task1_model.m','boost_b1_task2_rhp.m','boost_b1_task3_ctrl.m', ...
           'boost_b1_task4_switching.m','boost_b1_task5_accept.m'};
have = zeros(1,numel(scripts));
for k = 1:numel(scripts)
    have(k) = exist(fullfile(here,scripts{k}),'file') == 2;
end

mcpFiles = dir(fullfile(repo,'artifacts','validation','mcp_e2e_report_*.json'));
mcp = struct('file',{},'status',{},'level',{});
for k = 1:numel(mcpFiles)
    try
        j = jsondecode(fileread(fullfile(mcpFiles(k).folder,mcpFiles(k).name)));
        mcp(end+1) = struct('file',mcpFiles(k).name,'status',j.overallStatus, ...
            'level',j.achievedLevel); %#ok<AGROW>
    catch
    end
end

res = struct();
res.level = '3B.1-Task6';
res.matlabVersion = version;
res.routes = struct( ...
  'R1_agent_cli', struct('status','DONE','evidence', ...
     'all seven scripts in this phase were written and run by the agent through matlab -batch'), ...
  'R2_matlab_mcp', struct('status','SKIP','reason', ...
     ['no mcp__matlab* tool was bound to this agent session; the tool list contained ' ...
      'solidworks / sheetagent / genie-baas / space-library / weixinpay / agent-mail only']), ...
  'R3_skills_mcp', struct('status','SKIP','reason', ...
     ['same as R2, plus: the repository SKILL.md files are Codex-format and were not ' ...
      'exposed as invokable skills in this session, so "the skill was loaded" cannot ' ...
      'be claimed -- only "the text was read and followed by hand"']));
res.skillFiles = numel(dir(fullfile(repo,'skills','*','SKILL.md')));
res.scriptsPresent = struct('names',{scripts},'found',have);
res.mcpReportsFromEarlierSessions = mcp;
res.note = ['The MCP end-to-end reports above are from an EARLIER session (2026-10-17). ' ...
            'They prove the server worked then; they are NOT evidence for this phase.'];
res.selfAssessment = struct( ...
  'scriptsWritten', numel(scripts), ...
  'scriptsThatRanFirstTry', 0, ...
  'reason', 'every script needed at least one fix; the failures are listed in the phase report');
save(fullfile(outDir,'b1_task6_agent.mat'),'res');
fid = fopen(fullfile(outDir,'b1_task6_agent.json'),'w');
if fid >= 0, fwrite(fid, jsonencode(res), 'char'); fclose(fid); end
fprintf('Task 6 evidence written: R1 DONE, R2 SKIP, R3 SKIP\n');
fprintf('  scripts present: %d/%d ; skills found: %d\n', sum(have), numel(have), res.skillFiles);
for k = 1:numel(mcp)
    fprintf('  earlier MCP report: %-34s %-5s %s\n', mcp(k).file, mcp(k).status, mcp(k).level);
end
end
