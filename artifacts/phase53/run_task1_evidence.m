function run_task1_evidence()
% Phase 5.3 Task 1: regenerate every evidence log with evalc + fwrite.
%
% Why not diary(): in this MATLAB MCP session diary() created the files but
% never flushed a byte to them (verified: three attempts, all 0 bytes on disk
% after `diary off`). evalc captures the command-window text and an explicit
% fwrite+fclose goes to disk, which is what the Task 0 logs already do.
here = fileparts(mfilename('fullpath'));
ev = fullfile(here, 'evidence');
if ~isfolder(ev), mkdir(ev); end
addpath(here);
repo = fileparts(fileparts(here));
addpath(fullfile(repo,'skills','matlab-signal-vision-ai','scripts'));

jobs = { ...
    'task1_probe.log',           'probe_task1_tools'; ...
    'task1_probe_extra.log',     'probe_task1_extra'; ...
    'task1_probe_worstband.log', 'probe_worstband'; ...
    'task1_contract_tests.log',  'sig = test_signal_contract(true); fprintf(''\nSUMMARY %d/%d\n'', sig.nPass, sig.nTotal);'; ...
    'task1_integration.log',     'run_task1_integration'; ...
    };

fprintf('%-30s %10s  %s\n', 'log', 'bytes', 'status');
for k = 1:size(jobs, 1)
    name = jobs{k, 1};
    code = jobs{k, 2};
    f = fullfile(ev, name);
    try
        body = evalc(code);
        head = sprintf('== %s | %s | MATLAB %s ==\n', code, datestr(now, 31), version);
        fid = fopen(f, 'w');
        if fid < 0, error('run_task1_evidence:io', 'cannot write %s', f); end
        fwrite(fid, [head body], 'char');
        fclose(fid);
        d = dir(f);
        fprintf('%-30s %10d  %s\n', name, d.bytes, local_tern(d.bytes > 0, 'OK', 'EMPTY'));
    catch ME
        fprintf('%-30s %10s  ERROR: %s\n', name, '-', ME.message);
    end
end
end

function s = local_tern(c, a, b)
if c, s = a; else, s = b; end
end