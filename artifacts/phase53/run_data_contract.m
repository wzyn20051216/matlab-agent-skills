% Run the data-analysis contract suite and persist the transcript.
clear functions; rehash;
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(here));
addpath(fullfile(repo, 'skills', 'matlab-data-analysis', 'scripts'));
addpath(fullfile(repo, 'skills', 'matlab-data-analysis', 'tests'));
out = evalc('res = test_data_contract(true);');
fprintf('%s', out);
fid = fopen(fullfile(here, 'data_contract_run.txt'), 'w');
if fid >= 0, fwrite(fid, out, 'char'); fclose(fid); end
fprintf('\npass=%d nPass=%d nTotal=%d\n', res.pass, res.nPass, res.nTotal);
