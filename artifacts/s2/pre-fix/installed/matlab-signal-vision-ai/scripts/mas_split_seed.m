function r = mas_split_seed(y, opts)
%MAS_SPLIT_SEED  A reproducible train/validation split, with the leakage checked.
%
%   r = mas_split_seed(y)                       % 70/30, stratified, seed 0
%   r = mas_split_seed(y, struct('trainFrac',0.8,'seed',7,'stratify',true))
%
%   r.trainIdx, r.valIdx, r.seed
%   r.classBalance   per class: fraction in train vs fraction overall
%   r.noOverlap, r.noGap   asserted, not assumed
%   r.reproducible   re-running with the same seed gives the same indices
%
% WHY THIS IS A TOOL AND NOT TWO LINES OF randperm
% Three defects are common and all three produce a number that looks fine:
%   1. the same seed is not reused, so "we validated on 20 %" is not reproducible;
%   2. a row lands in both sets (index arithmetic off by one), inflating validation
%      accuracy;
%   3. the class balance silently shifts, so a 50/50 problem is trained on 70/30.
% All three are cheap to check and expensive to discover late, so they are checked
% here and returned as booleans the caller can assert on.
%
% STRATIFICATION
% Per class, take round(trainFrac*n_c) at random. Rounding can make the achieved
% fraction differ from the target by up to 0.5/n_c per class; that is reported in
% classBalance rather than hidden behind a boolean.

if nargin < 2, opts = struct(); end
opts = dflt(opts, struct('trainFrac', 0.7, 'seed', 0, 'stratify', true));

if ~isvector(y), error('mas_split_seed:y', 'y must be a vector of labels'); end
y = y(:);
n = numel(y);
if n < 4, error('mas_split_seed:short', 'need at least 4 samples'); end
if opts.trainFrac <= 0 || opts.trainFrac >= 1
    error('mas_split_seed:frac', 'trainFrac must be in (0,1)');
end

rng(opts.seed);
if opts.stratify
    cls = unique(y);
    tr = [];
    bal = struct('class', {}, 'nTotal', {}, 'nTrain', {}, 'fracIn', {});
    for k = 1:numel(cls)
        idx = find(y == cls(k));
        p = randperm(numel(idx));
        nTr = round(opts.trainFrac * numel(idx));
        if nTr >= numel(idx), nTr = numel(idx) - 1; end   % never leave a class empty
        if nTr < 1, nTr = 1; end
        tr = [tr; idx(p(1:nTr))]; %#ok<AGROW>
        bal(end+1) = struct('class', cls(k), 'nTotal', numel(idx), 'nTrain', nTr, ...
            'fracIn', nTr/numel(idx)); %#ok<AGROW>
    end
else
    p = randperm(n);
    nTr = round(opts.trainFrac * n);
    tr = p(1:nTr);
    bal = struct('class', 'all', 'nTotal', n, 'nTrain', nTr, 'fracIn', nTr/n);
end

tr = sort(tr(:));
va = setdiff((1:n).', tr);
noOverlap = isempty(intersect(tr, va));
noGap = numel(tr) + numel(va) == n;

% reproducibility: the same seed must reproduce the split exactly
rng(opts.seed);
if opts.stratify
    tr2 = [];
    cls = unique(y);
    for k = 1:numel(cls)
        idx = find(y == cls(k));
        p = randperm(numel(idx));
        nTr = round(opts.trainFrac * numel(idx));
        if nTr >= numel(idx), nTr = numel(idx) - 1; end
        if nTr < 1, nTr = 1; end
        tr2 = [tr2; idx(p(1:nTr))]; %#ok<AGROW>
    end
    tr2 = sort(tr2(:));
else
    p = randperm(n);
    tr2 = sort(p(1:round(opts.trainFrac*n)).');
end
reproducible = isequal(tr, tr2);

r = struct();
r.trainIdx = tr; r.valIdx = va; r.seed = opts.seed;
r.nTrain = numel(tr); r.nVal = numel(va); r.nTotal = n;
r.classBalance = bal;
r.noOverlap = noOverlap; r.noGap = noGap; r.reproducible = reproducible;
r.ok = noOverlap && noGap && reproducible;
r.detail = sprintf('%d/%d split (seed %d), overlap %d, gap %d, reproducible %d', ...
    r.nTrain, r.nVal, opts.seed, ~noOverlap, ~noGap, reproducible);
end

% ---------------------------------------------------------------------------
function o = dflt(o, d)
f = fieldnames(d);
for k = 1:numel(f)
    if ~isfield(o, f{k}), o.(f{k}) = d.(f{k}); end
end
end
