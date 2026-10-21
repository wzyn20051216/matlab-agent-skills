function out = cd_d3_filter()
%CD_D3_FILTER  Signal processing: Butterworth design + spectral check.
%
% INDEPENDENT REFERENCE (analytic, not from freqz)
%   A Butterworth filter of order N has |H|^2 = 1/(1+Omega^(2N)), where Omega is
%   the PREWARPED analog frequency ratio:
%       Omega = tan(pi*f/fs) / tan(pi*fc/fs)
%   Using Omega = f/fc (the ANALOG formula) is a trap: at f = fc both give the
%   same -3.0103 dB, so the mistake hides there, but at f = 2*fc the analog value
%   is -24.10 dB while the digital filter really gives -27.97 dB. The first
%   version of this task used the analog formula and FAILED a correct filter.
%   With Omega from the bilinear map:
%       f = 2*fc -> Omega = tan(2*pi*fc/fs)/tan(pi*fc/fs) = 2.2361
%       |H| = -10*log10(1+Omega^(2N)) = -27.966 dB for N = 4
%   The filter must also be stable (all poles inside the unit circle).

fs = 1000; fc = 100; N = 4;
[b,a] = butter(N, fc/(fs/2));

f = [fc 2*fc];
[h,~] = freqz(b, a, f, fs);
magdB = 20*log10(abs(h));

ref3  = -3.010299956639813;                       % 20*log10(1/sqrt(2))
Om    = tan(pi*(2*fc)/fs)/tan(pi*fc/fs);          % prewarped ratio at 2*fc
ref24 = -10*log10(1 + Om^(2*N));

p = roots(a);
stable = all(abs(p) < 1);

% DC gain of a lowpass must be 1. Compare it with |H(0)|, NOT with |H(fc)|:
% the first version compared sum(b)/sum(a) against abs(h(1)), which is the
% response at the CUTOFF (0.707), so a correct filter failed the check.
dc = sum(b)/sum(a);
% A SCALAR third argument to freqz is read as "n points", so freqz(b,a,0,fs)
% returns EMPTY and freqz(b,a,1e-6,fs) throws "index must be a positive integer".
% Pass the DC point inside a VECTOR to disambiguate.
h0v = freqz(b, a, [0 1], fs);
h0 = h0v(1);

ok = (abs(magdB(1)-ref3) < 0.02) && (abs(magdB(2)-ref24) < 0.05) && ...
     stable && (abs(dc-1) < 1e-9) && (abs(dc - abs(h0)) < 1e-9);

out.values = struct('magAtFc',magdB(1),'magAt2Fc',magdB(2),'stable',stable, ...
    'dcGain',dc,'maxPoleMag',max(abs(p)));
out.reference = struct('magAtFc',ref3,'magAt2Fc',ref24,'OmegaAt2Fc',Om);
out.status = tern(ok,'PASS','FAIL');
out.detail = sprintf('-3dB %.4f (ref %.4f), 2fc %.3f dB (digital ref %.3f), stable %d', ...
    magdB(1), ref3, magdB(2), ref24, stable);
end

function s = tern(c,a,b)
if c, s = a; else, s = b; end
end
