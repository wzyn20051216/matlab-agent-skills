function probe_bench_datan()
repo = fileparts(fileparts(fileparts(mfilename('fullpath'))));
addpath(fullfile(repo, 'skills', 'matlab-data-analysis', 'scripts'));
f = @(z) 4./(1+z.^2);
r = mas_quad_check(f, 0, 1, struct('value', pi, 'tolRel', 1e-8, ...
    'method', 'simpson', 'n', 32, 'derivAt', 0.5, 'derivValue', -2.56));
fprintf('verdict %s\n', r.verdict);
disp(r.detail);
disp(r.orders);
disp(r.ref);
fprintf('field ref.gap = %.3e\n', r.ref.gap);
end
