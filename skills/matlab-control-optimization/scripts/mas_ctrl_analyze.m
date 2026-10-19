function r = mas_ctrl_analyze(sys, opts)
%MAS_CTRL_ANALYZE  Margins and stability for a loop, INCLUDING multiple crossings.
%
%   r = mas_ctrl_analyze(L)
%   r = mas_ctrl_analyze(L, struct('delay',2.5*Ts))
%   r = mas_ctrl_analyze(num, den)          % raw polynomials
%
%   r.stable          true if every pole is in the open LHP (or inside the unit disk)
%   r.crossings       struct array: f, mag_dB, phase_deg, kind, pm, gm_dB
%   r.pmWorst         WORST phase margin over all downward 0 dB crossings
%   r.gmWorst         worst gain margin over all -180 deg crossings
%   r.nDown/r.nUp     number of downward / upward 0 dB crossings
%   r.binding         index of the crossing that actually limits the loop
%   r.verdict         'STABLE' | 'UNSTABLE' | 'MARGINAL'
%
% WHY "WORST" AND NOT "THE" MARGIN
% `margin(L)` returns ONE number. For a loop with a resonance it can be the wrong
% one: |L| dips below 0 dB, the resonance lifts it back above, and the loop crosses
% 0 dB a second time with far less phase. Measured in this repository (Phase 3B.2,
% Boost single-loop PI at 300 Hz): two crossings, the first reporting +38 deg and
% the second actually -18 deg -- i.e. the loop was unstable while `margin` said it
% had 38 degrees. The same shape appears in the C3 test case here (-95 deg at the
% second crossing).
%
% A margin is a property of a CROSSING, not of a loop. This function reports every
% crossing and then takes the worst; it never substitutes the first one.
%
% DISCRETE SYSTEMS
% A tf/ss with Ts > 0 is evaluated on the unit circle, and the frequency axis is
% mapped to Hz with f = w/(2*pi*Ts). Poles are tested with |p| < 1. No manual
% bilinear conversion is done, so what is reported IS the sampled loop.
%
% DELAY
% opts.delay adds a transport delay of that many SECONDS:
%   continuous: exp(-s*Td), phase = -w*Td
%   discrete:   floor/frac split into a whole number of samples plus the residual,
%               so a non-integer delay still gets the right phase without changing
%               the magnitude.
% A delay never changes |L|, so it can only move crossings through the phase, which
% is exactly why it is applied here rather than left to the caller.

% ---- accept tf / ss / zpk / (num, den) ------------------------------------
% This has to happen BEFORE the options are filled in: with (num, den) the second
% argument IS the denominator, and calling defaults() on it tries to add fields to a
% double. (That produced "variable of type double does not support dot indexing".)
if ~isa(sys, 'lti')
    if (isnumeric(sys) || iscell(sys)) && nargin >= 2 && ...
            (isnumeric(opts) || iscell(opts))
        den = opts;               % the second positional argument is the denominator
        sys = tf(sys, den);
        opts = struct();
    else
        error('mas_ctrl_analyze:type', ...
            'pass an LTI model, or (numerator, denominator) as two positional arguments');
    end
end
if nargin < 2, opts = struct(); end
opts = defaults(opts, struct('delay', 0, 'grid', 2e5, 'wmin', [], 'wmax', [], ...
    'pmTarget', 45, 'gmTarget', 6));
Ts = sys.Ts;
disc = Ts > 0;

% ---- stability from the poles --------------------------------------------
p = pole(sys);
if disc
    onAxis = any(abs(abs(p) - 1) < 1e-9);
    inRHP  = any(abs(p) > 1);
    maxPole = max(abs(p));
else
    onAxis = any(abs(real(p)) < 1e-9);
    inRHP  = any(real(p) > 1e-9);
    maxPole = max(real(p));
end
% An integrator puts a pole exactly on the axis and is NORMAL for a loop; calling
% that "marginal" (the first version did) hides the real verdict. Poles ON the axis
% are reported separately from poles in the RHP, and `stable` is the strict test.
stable = ~inRHP && ~onAxis;

% ---- frequency grid -------------------------------------------------------
if isempty(opts.wmin) || isempty(opts.wmax)
    if disc
        wmax = pi/Ts; wmin = wmax/1e5;
    else
        wmax = 10*max([abs(p(:)).' 1])*100;
        wmin = wmax/1e6;
    end
else
    wmin = opts.wmin; wmax = opts.wmax;
end
% Row vectors throughout. freqresp() returns 1x1xN and squeeze() turns that into a
% COLUMN, so `Lw .* delay` silently became a 2e5 x 2e5 outer product and tried to
% allocate 596 GB. Normalising the orientation once is cheaper than remembering it.
w = logspace(log10(wmin), log10(wmax), opts.grid);
w = w(:).';

% ---- loop response with optional delay -----------------------------------
Lw = squeeze(freqresp(sys, w));
Lw = reshape(Lw, 1, []);
if opts.delay ~= 0
    Lw = Lw .* delay_term(opts.delay, w, disc, Ts);
end
mag = abs(Lw);
magdB = 20*log10(mag);
% unwrap is mandatory: a loop with an integrator runs past -180 deg and angle()
% folds it back, which turns the worst margin into the best-looking one.
ph = unwrap(angle(Lw)) * 180/pi;
if disc, wHz = w/(2*pi*Ts); else, wHz = w/(2*pi); end

% ---- every 0 dB crossing --------------------------------------------------
C = struct('f', {}, 'mag_dB', {}, 'phase_deg', {}, 'kind', {}, 'pm', {}, 'gm_dB', {});
idu = find(mag(1:end-1) >= 1 & mag(2:end) < 1);       % downward
iiu = find(mag(1:end-1) < 1 & mag(2:end) >= 1);       % upward
for k = 1:numel(idu)
    [f, pdeg] = interp_cross(w, wHz, mag, ph, idu(k));
    C(end+1) = struct('f', f, 'mag_dB', 0, 'phase_deg', pdeg, 'kind', 'down', ...
        'pm', 180 + pdeg, 'gm_dB', NaN); %#ok<AGROW>
end
for k = 1:numel(iiu)
    [f, pdeg] = interp_cross(w, wHz, mag, ph, iiu(k));
    C(end+1) = struct('f', f, 'mag_dB', 0, 'phase_deg', pdeg, 'kind', 'up', ...
        'pm', 180 + pdeg, 'gm_dB', NaN); %#ok<AGROW>
end

% ---- every -180 deg crossing (gain margin) -------------------------------
% Phase is compared modulo 360 so a loop that has already passed -180 once is not
% silently ignored.
phMod = mod(ph + 180, 360) - 180;   % in (-180, 180]
idg = find(phMod(1:end-1) <= 0 & phMod(2:end) > 0);
for k = 1:numel(idg)
    i = idg(k);
    r_ = (0 - phMod(i))/(phMod(i+1) - phMod(i));
    f = exp(log(w(i)) + r_*(log(w(i+1)) - log(w(i))));
    if disc, fHz = f/(2*pi*Ts); else, fHz = f/(2*pi); end
    gm = -20*log10(mag(i) + r_*(mag(i+1) - mag(i)));
    C(end+1) = struct('f', fHz, 'mag_dB', -gm, 'phase_deg', -180, 'kind', 'ph180', ...
        'pm', NaN, 'gm_dB', gm); %#ok<AGROW>
end

% ---- summary --------------------------------------------------------------
isDown = strcmp({C.kind}, 'down');
pms = [C(isDown).pm];
if isempty(pms)
    pmWorst = NaN; binding = NaN; nDown = 0;
else
    [pmWorst, kk] = min(pms);
    idx = find(isDown);
    binding = idx(kk);
    nDown = numel(pms);
end
gms = [C(strcmp({C.kind}, 'ph180')).gm_dB];
if isempty(gms), gmWorst = Inf; else, gmWorst = min(gms); end

% The verdict must combine BOTH pieces of evidence. A loop can have all poles in
% the LHP and still cross 0 dB twice with a negative margin at the second crossing
% (that is C3); reporting "STABLE" because the poles look fine is exactly the
% mistake this tool exists to prevent.
if inRHP
    verdict = 'UNSTABLE';
elseif ~isnan(pmWorst) && pmWorst < 0
    verdict = 'UNSTABLE';
elseif ~isnan(pmWorst) && abs(pmWorst) < 5
    verdict = 'MARGINAL';
elseif isempty(pms) && onAxis
    verdict = 'UNDETERMINED';        % integrator but no crossing found
else
    verdict = 'STABLE';
end

r = struct();
r.stable = stable;
r.maxPole = maxPole;
r.nPoles = numel(p);
if disc, r.rhpPoles = sum(abs(p) > 1); r.onAxisPoles = sum(abs(abs(p)-1) < 1e-9);
else, r.rhpPoles = sum(real(p) > 1e-9); r.onAxisPoles = sum(abs(real(p)) < 1e-9); end
r.hasIntegrator = r.onAxisPoles > 0;
r.nDown = nDown;
r.nUp = numel(iiu);
r.crossings = C;
r.pmWorst = pmWorst;
r.gmWorst = gmWorst;
r.binding = binding;
r.verdict = verdict;
r.Ts = Ts;
r.delay = opts.delay;
r.meetsTarget = (pmWorst >= opts.pmTarget) && (gmWorst >= opts.gmTarget);
r.pmTarget = opts.pmTarget;
r.gmTarget = opts.gmTarget;
r.w = w; r.wHz = wHz; r.magdB = magdB; r.phase = ph;
if isnan(pmWorst)
    r.detail = sprintf('no 0 dB crossing; %d poles, max pole %.4g', numel(p), maxPole);
else
    r.detail = sprintf('%d down-crossing(s), worst PM %.1f deg at %.4g Hz, GM %.1f dB, %s', ...
        r.nDown, pmWorst, C(max(binding, 1)).f, gmWorst, verdict);
end
end

% ---------------------------------------------------------------------------
function d = delay_term(Td, w, disc, Ts)
if ~disc
    d = exp(-1j*w*Td);
else
    n = floor(Td/Ts);
    frac = Td/Ts - n;
    d = (exp(-1j*w*Ts)).^n .* exp(-1j*w*Ts*frac);
end
end

% ---------------------------------------------------------------------------
function [fHz, pdeg] = interp_cross(w, wHz, mag, ph, i)
% Log-linear interpolation of the 0 dB crossing. Linear interpolation on a log
% frequency axis is the standard convention and is what makes the reported value
% reproducible; at a 2e5-point grid the difference is below the print precision.
r_ = (0 - log(mag(i)))/(log(mag(i+1)) - log(mag(i)));
fHz = exp(log(wHz(i)) + r_*(log(wHz(i+1)) - log(wHz(i))));
pdeg = ph(i) + r_*(ph(i+1) - ph(i));
end

function o = defaults(o, d)
f = fieldnames(d);
for k = 1:numel(f)
    if ~isfield(o, f{k}), o.(f{k}) = d.(f{k}); end
end
end
