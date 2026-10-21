function out = cd_d2_regression()
%CD_D2_REGRESSION  Data analysis: missing values, exponential fit, statistics.
%
% INDEPENDENT REFERENCE
%   The data are GENERATED from y = a*exp(b*x) with a = 2.5, b = -0.7, so the true
%   parameters are known before any fitting. Noise is added with a fixed seed, and
%   a block of samples is replaced by NaN. The fit must recover the truth, not
%   reproduce its own output.
%
% Missing data are handled explicitly (removed, and the count reported) rather
% than silently dropped inside a toolbox call.

aTrue = 2.5; bTrue = -0.7;
x = (0:0.1:5).';
rng(7);
yClean = aTrue*exp(bTrue*x);
y = yClean .* (1 + 0.02*randn(size(x)));

miss = false(size(x));
miss(12:14) = true;                % 3 samples removed on purpose
y(miss) = NaN;

nMissing = sum(isnan(y));
keep = ~isnan(y) & y > 0;
p = polyfit(x(keep), log(y(keep)), 1);   % log y = log a + b x
bHat = p(1); aHat = exp(p(2));

yHat = aHat*exp(bHat*x(keep));
ssRes = sum((y(keep)-yHat).^2);
ssTot = sum((y(keep)-mean(y(keep))).^2);
R2 = 1 - ssRes/ssTot;

errA = abs(aHat/aTrue - 1);
errB = abs(bHat/bTrue - 1);
ok = (nMissing == 3) && (errA < 0.03) && (errB < 0.03) && (R2 > 0.98);

out.values = struct('aHat',aHat,'bHat',bHat,'R2',R2,'nMissing',nMissing, ...
    'nUsed',nnz(keep));
out.reference = struct('a',aTrue,'b',bTrue,'nMissing',3);
out.status = tern(ok,'PASS','FAIL');
out.detail = sprintf('a %.3f (true %.3f), b %.4f (true %.4f), R2 %.4f, %d NaN removed', ...
    aHat, aTrue, bHat, bTrue, R2, nMissing);
end

function s = tern(c,a,b)
if c, s = a; else, s = b; end
end
