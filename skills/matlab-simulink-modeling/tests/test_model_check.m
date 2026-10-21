function res = test_model_check(verbose)
%TEST_MODEL_CHECK  A real model must reach L3; a missing file must stay L0.
%
%   res = test_model_check()

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
addpath(fullfile(fileparts(here),'scripts'));

mdl = fullfile(repo,'matlab','boost','models','boost_avg.slx');
r1 = mas_model_check(mdl, struct('tStop',0.01));
r2 = mas_model_check(fullfile(repo,'no_such_model.slx'));

nP = 0;
if verbose, fprintf('=== model check tests ===\n'); end
ok1 = strcmp(r1.level,'L3') && r1.pass;
ok2 = strcmp(r2.level,'L0') && ~r2.pass;
nP = ok1 + ok2;
if verbose
    fprintf('  [%s] real model   -> %s %s\n', tern(ok1,'PASS','FAIL'), r1.level, r1.detail);
    fprintf('  [%s] missing file -> %s %s\n', tern(ok2,'PASS','FAIL'), r2.level, r2.detail);
    fprintf('\n---- %d / 2 model-check cases passed ----\n', nP);
end
res = struct('nPass',nP,'nTotal',2,'pass',nP==2, ...
    'realModel',r1,'missing',r2);
end

function s = tern(c,a,b)
if c, s = a; else, s = b; end
end
