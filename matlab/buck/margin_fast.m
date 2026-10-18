function [pm, gm_dB, wc, info] = margin_fast(sys, nGrid, wLo, wHi)
%MARGIN_FAST  Fast worst-case phase/gain margin for a SISO LTI system.
%
%   [pm, gm_dB, wc] = margin_fast(sys)
%
% Returns the WORST (minimum) phase margin over ALL 0 dB crossings, and the
% worst gain margin over ALL -180 deg crossings, using the same conventions
% as local_margins.m (which is the authoritative implementation in this
% repository). This function exists only because local_margins spends ~174 ms
% per call (dense grid + branch-consistent bisection + internal band
% extension), which makes multi-dimensional searches impractical.
%
% IMPORTANT: every number that ends up in a report or a PASS/FAIL verdict is
% re-evaluated with local_margins. margin_fast is used for SEARCH ONLY.
%
% Discrete systems are evaluated on the unit circle z = exp(1j*w*Ts) and the
% grid is capped at the Nyquist frequency pi/Ts (Phase 3A.2 defect: sweeping
% past pi/Ts counts mirror-image crossings as real ones).
%
% Inputs
%   sys   - SISO tf/ss (continuous, Ts=0; or discrete, Ts>0)
%   nGrid - optional, points per decade-ish (default: chosen from nTotal)
%   wLo, wHi - optional frequency limits (rad/s)
%
% Outputs
%   pm     - worst phase margin [deg]; NaN if there is no 0 dB crossing
%   gm_dB  - worst gain margin [dB]; Inf if there is no -180 deg crossing
%            (the loop never reaches -180 deg, which is a *good* margin)
%   wc     - frequency of the gain crossover that produced pm [rad/s]
%   info   - struct with nGain, nPhase, wMax, wNyq

if nargin < 2 || isempty(nGrid), nGrid = 4000; end
Ts = sys.Ts;
if Ts > 0
    wNyq = pi/Ts;
    if nargin < 4 || isempty(wHi), wHi = wNyq; end
    wHi = min(wHi, wNyq);
else
    wNyq = Inf;
    if nargin < 4 || isempty(wHi), wHi = 1e7; end
end
if nargin < 3 || isempty(wLo), wLo = 1e-2; end

% geometric grid (logspace is fine: the systems here are smooth in log w)
w = logspace(log10(wLo), log10(wHi), nGrid);
H = reshape(freqresp(sys, w), [], 1);
magdB = 20*log10(abs(H) + eps);
ph = rad2deg(unwrap(angle(H)));

% ---- all 0 dB crossings (linear interpolation on magdB) ----
sgn = magdB(1:end-1).*magdB(2:end);
idx = find(sgn <= 0);
% exact zeros also count
idx = union(idx, find(magdB(1:end-1) == 0));
pm = NaN; wc = NaN; nGain = 0;
for k = idx(:).'
    if magdB(k) == 0
        wk = w(k); pk = ph(k);
    else
        t = magdB(k)/(magdB(k) - magdB(k+1));
        wk = w(k) + t*(w(k+1) - w(k));
        pk = ph(k) + t*(ph(k+1) - ph(k));
    end
    thispm = 180 + pk;
    % fold like margin()/allmargin: report the equivalent in (-180,180]
    while thispm > 180, thispm = thispm - 360; end
    while thispm <= -180, thispm = thispm + 360; end
    nGain = nGain + 1;
    if ~isfinite(pm) || thispm < pm
        pm = thispm; wc = wk;
    end
end

% ---- all -180 crossings (mod 360) ----
phr = mod(ph + 180, 360) - 180;          % wrap to [-180,180)
d = ph + 180;                            % distance to the -180 line
dg = mod(d + 180, 360) - 180;            % wrapped distance
s2 = dg(1:end-1).*dg(2:end);
idx2 = find(s2 <= 0);
% exclude the wrap-around at +-180 of the wrapped representation
idx2 = idx2(abs(dg(idx2) - dg(idx2+1)) < 180);
gm_dB = Inf; nPhase = 0;
for k = idx2(:).'
    if dg(k) == 0
        wk = w(k); mk = magdB(k);
    else
        t = dg(k)/(dg(k) - dg(k+1));
        wk = w(k) + t*(w(k+1) - w(k));
        mk = magdB(k) + t*(magdB(k+1) - magdB(k));
    end
    % gain margin = -|L| in dB at -180 deg (positive = stable margin)
    thisgm = -mk;
    nPhase = nPhase + 1;
    if thisgm < gm_dB, gm_dB = thisgm; end
end

info = struct('nGain', nGain, 'nPhase', nPhase, 'wMax', w(end), 'wNyq', wNyq, ...
               'phRange', [min(ph) max(ph)], 'magRange', [min(magdB) max(magdB)]);
end
