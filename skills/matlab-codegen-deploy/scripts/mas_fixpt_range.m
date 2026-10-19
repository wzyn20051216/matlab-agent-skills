function r = mas_fixpt_range(fcn, stimuli, opts)
%MAS_FIXPT_RANGE  Observe ranges under test stimuli, then measure quantization cost.
%
%   r = mas_fixpt_range(@myAlg, {u1, u2, u3})
%   r = mas_fixpt_range(@myAlg, {u1, u2}, struct('wordLength', 16, 'signed', true))
%
%   r.min, r.max          observed output range over all stimuli
%   r.proposed            struct: signed, wordLength, fractionLength, range, resolution
%   r.maxQuantErr         worst |quantized - reference|
%   r.sqnrDb              signal-to-quantization-noise ratio over all stimuli
%   r.overflowFrac        fraction of output samples outside the representable range
%   r.perStimulus         per-stimulus min / max / max error
%   r.warnings, r.verdict
%
% RANGES ARE OBSERVED, NOT PROVEN
% This reports the range the output actually took under the stimuli you gave it.
% It is not a bound. Feeding it a stimulus that does not exercise the worst case
% produces a scaling that quietly overflows in the field -- which is exactly the
% failure this is meant to prevent. Say so in the output rather than implying a
% guarantee, and treat the stimuli as part of the result.
%
% WHY THE FRACTION LENGTH IS CHOSEN THIS WAY
% With W total bits and S signed, the fraction length f must satisfy two
% conflicting demands: cover the observed magnitude, and keep resolution fine.
% Taking f = W - S - (bits needed for the integer part) maximises precision
% subject to not overflowing what was observed, then a small guard band is
% reserved for stimuli slightly outside the tested set. Overflow is reported as a
% FRACTION, not a boolean, because a single saturated sample and a hundred
% saturated samples are different problems.
%
% Requires Fixed-Point Designer (`fi`). Without it the function returns
% `verdict = 'SKIP'` and says so, rather than emulating fixed point badly with
% doubles -- an emulation that would agree on every test and mislead in production.

if nargin < 3, opts = struct(); end
opts = dflt(opts, struct('wordLength', 16, 'signed', true, 'guardBits', 2));

if exist('fi', 'file') == 0 && exist('fi', 'builtin') ~= 5
    r = struct();
    r.verdict = 'SKIP';
    r.reason = 'Fixed-Point Designer not available';
    r.detail = 'SKIP: Fixed-Point Designer not available (fi missing)';
    return;
end

n = numel(stimuli);
per = struct('index', {}, 'min', {}, 'max', {}, 'maxErr', {});
lo = Inf; hi = -Inf;

for k = 1:n
    y = feval(fcn, stimuli{k}{:});
    if ~isnumeric(y)
        error('mas_fixpt_range:output', ...
            'stimulus %d produced a non-numeric output; quantify numerically first', k);
    end
    yf = y(isfinite(y(:)));
    if isempty(yf)
        error('mas_fixpt_range:output', 'stimulus %d produced no finite samples', k);
    end
    mn = min(yf); mx = max(yf);
    lo = min(lo, mn); hi = max(hi, mx);
    per(end+1) = struct('index', k, 'min', mn, 'max', mx, 'maxErr', 0); %#ok<AGROW>
end

% ---- choose a signed/unsigned, fixed-length representation ----------------
sgn = logical(opts.signed);
W = opts.wordLength;
g = opts.guardBits;

% bits needed for the integer part of the observed range, including the sign
if hi == lo
    intBits = ceil(log2(max(abs(hi), 1) + eps)) + 1;
else
    intBits = ceil(log2(max(abs([lo hi])) + eps)) + 1;
end
if sgn, intBits = intBits + 1; end
intBits = intBits + g;                      % guard band

f = max(W - intBits, 0);
if sgn
    repMin = -2^(W-1) * 2^-f;
    repMax =  (2^(W-1) - 1) * 2^-f;
else
    repMin = 0;
    repMax = (2^W - 1) * 2^-f;
end
res = 2^-f;

% ---- measure what that choice costs ---------------------------------------
sigE = 0; errE = 0; nTot = 0; nOver = 0;
for k = 1:n
    y = feval(fcn, stimuli{k}{:});
    q = quantize_to(y, sgn, W, f);
    d = abs(y(:) - q(:));
    d = d(isfinite(d));
    per(k).maxErr = max([d; 0]);
    yv = y(isfinite(y(:)));
    sigE = sigE + sum(yv.^2);
    errE = errE + sum(d.^2);
    nTot = nTot + numel(yv);
    nOver = nOver + sum(yv < repMin - eps | yv > repMax + eps);
end

if errE > 0
    sqnr = 10*log10(sigE / errE);
else
    sqnr = Inf;
end

warn = {};
if nOver > 0
    warn{end+1} = sprintf(['%.1f%% of samples fall outside [%g, %g] for %d-bit ' ...
        'representation: the range was measured on the stimuli given, not proven. ' ...
        'Add a stimulus that exercises the worst case before trusting this scaling.'], ...
        100*nOver/nTot, repMin, repMax, W);
end
if isempty(sigE) || sigE == 0
    warn{end+1} = 'output is identically zero: no dynamic range to scale against';
end

r = struct();
r.min = lo; r.max = hi;
r.signed = sgn; r.wordLength = W; r.fractionLength = f;
r.proposed = struct('signed', sgn, 'wordLength', W, 'fractionLength', f, ...
    'min', repMin, 'max', repMax, 'resolution', res);
r.maxQuantErr = max([per.maxErr]);
r.sqnrDb = sqnr;
r.overflowFrac = nOver / max(nTot, 1);
r.perStimulus = per;
r.nStimuli = n;
r.warnings = warn;
r.ok = isempty(warn);
r.verdict = tern(r.ok, 'PASS', 'WARN');
r.detail = sprintf('range [%.4g, %.4g], W=%d f=%d, maxQuantErr %.3e, SQNR %s dB -- %s', ...
    lo, hi, W, f, r.maxQuantErr, fmtnum(sqnr), r.verdict);
end

% ===========================================================================
function q = quantize_to(y, sgn, W, f)
% Round-to-nearest with saturation, i.e. the default `fi` behaviour, applied
% explicitly so the error accounting is visible rather than implicit.
scale = 2^f;
if sgn
    lo = -2^(W-1);
    hi =  2^(W-1) - 1;
else
    lo = 0;
    hi = 2^W - 1;
end
yi = round(y * scale);
yi = max(min(yi, hi), lo);
q = reshape(yi / scale, size(y));
end

% ===========================================================================
function s = fmtnum(v)
if isfinite(v), s = sprintf('%.1f', v); else, s = 'inf'; end
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end

% ===========================================================================
function o = dflt(o, d)
f = fieldnames(d);
for k = 1:numel(f)
    if ~isfield(o, f{k}), o.(f{k}) = d.(f{k}); end
end
end
