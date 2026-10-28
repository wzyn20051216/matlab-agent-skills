%P56_CODER_DRIVE_D  Driver for channel D: the MCP run_matlab_file tool.
%
%   Executed by run_matlab_file on <repo>/matlab/validation/phase56/p56_coder_drive_d.m
%
% p56_coder_channel_probe.m measured A (real batch process) and B (MCP dynamic
% evaluation). The official MCP server exposes a third way to run code -- a file
% handed to run_matlab_file -- and Phase 5.5 never probed it. This script exists
% only because run() needs a script, not a function file; the measurement itself
% stays in p56_coder_channel_probe.m so all channels record the same fields.

here = fileparts(mfilename('fullpath'));
% <repo>/matlab/validation/phase56 -> three levels up is the repo root.
repo = fileparts(fileparts(fileparts(here)));
outDir = fullfile(repo, 'artifacts', 'phase56', 'coder_channel');
addpath(here);
try
    S = p56_coder_channel_probe(outDir, 'D');
    fprintf('D ok=%d id=[%s] artifacts=%d frames=%d\n', S.ok, S.errorIdentifier, ...
        numel(S.artifacts), numel(S.callFrames));
    for q = 1:numel(S.callFrames)
        fprintf('   | %s\n', S.callFrames{q});
    end
catch ME
    fprintf('D driver failed: [%s] %s\n', ME.identifier, ME.message);
end
rmpath(here);
