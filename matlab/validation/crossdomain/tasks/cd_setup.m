function repo = cd_setup()
%CD_SETUP  Put every skill script folder on the path, once, from one place.
%
% Counting fileparts() calls separately in each task is how the first version of the
% C tasks ended up one level short (it added matlab/skills, which does not exist, so
% mas_ctrl_analyze was undefined). Resolving the repo root here means there is one
% number to get right instead of one per task.

here = fileparts(mfilename('fullpath'));       % .../crossdomain/tasks
repo = fileparts(fileparts(fileparts(fileparts(here))));   % -> repo root
% addpath on a folder that does not exist prints a warning and continues, which
% buries the one folder that DOES matter. Only add what is there.
dirs = { ...
  'skills/matlab-control-optimization/scripts', 'skills/matlab-runner/scripts', ...
  'skills/matlab-testing-ci/scripts', 'skills/matlab-simulink-modeling/scripts', ...
  'skills/matlab-data-analysis/scripts', 'skills/matlab-signal-vision-ai/scripts', ...
  'skills/matlab-robotics-autonomy/scripts', 'skills/matlab-codegen-deploy/scripts', ...
  'skills/matlab-orchestrator/scripts', 'matlab/boost', 'matlab/buck', ...
  'matlab/validation/crossdomain'};
for k = 1:numel(dirs)
    d = fullfile(repo, dirs{k});
    if isfolder(d), addpath(d); end
end
end
