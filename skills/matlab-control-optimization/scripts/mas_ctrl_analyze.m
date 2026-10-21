function r = mas_ctrl_analyze(sys, opts)
%MAS_CTRL_ANALYZE  Margins and stability for a loop, INCLUDING multiple crossings.
%
%   r = mas_ctrl_analyze(L)
%   r = mas_ctrl_analyze(L, struct('delay',2.5*Ts))
%   r = mas_ctrl_analyze(num, den)          % raw polynomials
%
%   r.verdict         'STABLE' | 'UNSTABLE' | 'MARGINAL' | 'UNDETERMINED'
%   r.openLoopStable  poles of L
%   r.closedLoopStable  poles of feedback(L,1): true | false | 'UNDETERMINED'
%   r.closedLoopPoles / r.closedLoopMaxPole / r.marginal
%   r.evidenceQuality 'VERIFIED' | 'PARTIAL' | 'NOT VERIFIED'
%   r.notes           cellstr explaining every missing / suspicious result
%   r.crossings       struct array: f (Hz), wRadPerSec, mag_dB, phase_deg,
%                     kind ('down'|'up'|'ph180'), pm, gm_dB, note
%   r.pmWorst         WORST phase margin over all downward 0 dB crossings
%   r.gmWorst         worst gain margin over all -180 deg crossings
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
% STABILITY IS NOT ONE NUMBER
% Phase 5.1 found three ways a frequency-only report lied:
%   * a negative-gain loop (-10/(s+1)) has a 0 dB crossing with phase +95.7 deg.
%     `180 + angle` calls that +84.3 deg; `margin` says -84.26 because the loop
%     encircles -1 at DC, and the closed loop has a pole at +9. The phase at a
%     crossing is only defined modulo 360, so PM is wrapped into (-180,180].
%   * a loop with |L(0)| = 1 has its only phase margin AT DC. A grid starting at
%     1e-6 misses it and reports pmWorst = NaN with no explanation.
%   * a discrete loop reaches -180 deg exactly at the Nyquist frequency pi/Ts.
%     An interior-crossing search never sees that -180 crossing and reports GM=Inf.
% Closed-loop poles are therefore computed independently and reported separately;
% the verdict combines poles and frequency evidence, and a disagreement is
% reported as UNDETERMINED rather than silently choosing a side.
%
% Units: every frequency is reported twice, f in Hz and wRadPerSec in rad/s, and
% `r.freqUnit` echoes the unit used for opts.wmin/opts.wmax. This is the contract
% that prevents Hz/rad-s mixing; passing numbers without checking the tag is the
% user error this field exists to expose.
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
% is exactly why it is applied here rather than left to the caller. When a delay is
% present the rational closed-loop poles do NOT prove stability of the delayed loop,
% so closedLoopStable is reported as 'UNDETERMINED' and the evidence is PARTIAL.

% ---- accept tf / ss / zpk / (num, den) ------------------------------------
if ~isa(sys, 'lti')
    if (isnumeric(sys) || iscell(sys)) && nargin >= 2 && ...
            (isnumeric(opts) || iscell(opts))
        den = opts;
        sys = tf(sys, den);
        opts = struct();
    else
        error('mas_ctrl_analyze:type', ...
            'pass an LTI model, or (numerator, denominator) as two positional arguments');
    end
end
if nargin < 2, opts = struct(); end
opts = defaults(opts, struct('delay', 0, 'grid', 2e5, 'wmin', [], 'wmax', [], ...
    'pmTarget', 45, 'gmTarget', 6, 'freqUnit', 'rad/s'));
if opts.delay < 0
    error('mas_ctrl_analyze:delay','delay must be >= 0 seconds');
end
Ts = sys.Ts;
disc = Ts > 0;
notes = {};
freqUnit = lower(char(opts.freqUnit));
if ~any(strcmp(freqUnit, {'rad/s','hz'}))
    error('mas_ctrl_analyze:unit','freqUnit must be ''rad/s'' or ''Hz''');
end

% ---- open-loop poles ------------------------------------------------------
p = pole(sys);
[olStatus, maxPole, rhp, onAxis] = pole_status(p, disc);
stable = strcmp(olStatus, 'STABLE');
if isempty(p)
    notes{end+1} = 'STATIC_SYSTEM: no open-loop poles; stability is decided by the closed loop.';
end
if strcmp(olStatus,'UNSTABLE')
    notes{end+1} = sprintf('OPEN_LOOP_UNSTABLE: %d pole(s) in the unstable region.', rhp);
end

% ---- closed-loop poles (independent of the frequency method) -------------
hasTd = false;
try, hasTd = hasdelay(sys); catch, end
clStatus = 'UNDETERMINED';
pcl = [];
clNote = '';
if opts.delay ~= 0 || hasTd
    clNote = ['DELAY_NOT_IN_POLE_EVIDENCE: feedback(L,1) excludes the transport ' ...
        'delay; only frequency evidence can decide this loop.'];
    notes{end+1} = clNote;
else
    try
        cl = feedback(sys, 1);
        pcl = pole(cl);
        [clStatus, clMax, clRhp, clAxis] = pole_status(pcl, disc);
    catch ME
        clNote = ['CLOSED_LOOP_POLES_FAILED: ' ME.message];
        notes{end+1} = clNote;
    end
end
if isempty(pcl) && strcmp(clStatus,'STABLE')
    notes{end+1} = 'STATIC_CLOSED_LOOP: no closed-loop poles (static gain), asymptotically stable.';
end

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
    if strcmp(freqUnit, 'hz')
        wmin = wmin*2*pi; wmax = wmax*2*pi;
    end
    if disc && wmax > pi/Ts
        wmax = pi/Ts;
        notes{end+1} = 'GRID_CLAMPED_TO_NYQUIST: wmax exceeded pi/Ts and was clamped.';
    end
    if wmin <= 0
        wmin = wmax/1e6;
        notes{end+1} = 'GRID_WMIN_NONPOSITIVE: wmin was <= 0 and was replaced.';
    end
end
w = logspace(log10(wmin), log10(wmax), max(1000, opts.grid));
w = w(:).';

% ---- loop response with optional delay -----------------------------------
Lw = squeeze(freqresp(sys, w));
Lw = reshape(Lw, 1, []);
if opts.delay ~= 0
    Lw = Lw .* delay_term(opts.delay, w, disc, Ts);
end
nonfinite = ~isfinite(real(Lw)) | ~isfinite(imag(Lw));
nNonfinite = nnz(nonfinite);
if nNonfinite > 0
    notes{end+1} = sprintf(['NONFINITE_FREQUENCY_DATA: %d of %d grid points were ' ...
        'not finite; crossings near them are unreliable.'], nNonfinite, numel(w));
end
mag = abs(Lw);
magdB = 20*log10(mag);
% unwrap is mandatory: a loop with an integrator runs past -180 deg and angle()
% folds it back, which turns the worst margin into the best-looking one.
ph = unwrap(angle(Lw)) * 180/pi;
if disc, wHz = w/(2*pi*Ts); else, wHz = w/(2*pi); end

% ---- every 0 dB crossing --------------------------------------------------
C = new_crossing();
idu = find(mag(1:end-1) >= 1 & mag(2:end) < 1);       % downward
iiu = find(mag(1:end-1) < 1 & mag(2:end) >= 1);       % upward
for k = 1:numel(idu)
    [f, pdeg, wc] = interp_cross(w, wHz, mag, ph, idu(k));
    C(end+1) = crossing(f, wc, 0, pdeg, 'down', phase_margin(pdeg), NaN, ''); %#ok<AGROW>
end
for k = 1:numel(iiu)
    [f, pdeg, wc] = interp_cross(w, wHz, mag, ph, iiu(k));
    C(end+1) = crossing(f, wc, 0, pdeg, 'up', phase_margin(pdeg), NaN, ''); %#ok<AGROW>
end

% ---- DC boundary: |L(0)| = 1 or phase = -180 at w = 0 --------------------
Ldc = freqresp(sys, 0);
magDc = abs(Ldc);
if isfinite(magDc) && magDc > 0
    dbDc = 20*log10(magDc);
    phDc = wrap180(angle(Ldc)*180/pi);
    dcDup = any(strcmp({C.kind}, 'down') & [C.f] < 2*wHz(1));
    if abs(dbDc) < 1e-9 && ~dcDup
        pmDc = phase_margin(phDc);
        C(end+1) = crossing(0, 0, 0, phDc, 'down', pmDc, NaN, 'DC_AT_0_DB'); %#ok<AGROW>
        notes{end+1} = sprintf(['DC_AT_0_DB: |L(0)| = 1; phase margin %.2f deg is ' ...
            'evaluated at DC because the loop never crosses 0 dB again.'], pmDc);
    end
    if abs(wrap180(phDc + 180)) < 1e-9 && magDc > 1
        gmDc = -dbDc;
        C(end+1) = crossing(0, 0, -gmDc, -180, 'ph180', NaN, gmDc, 'DC_PHASE_180'); %#ok<AGROW>
        notes{end+1} = sprintf(['DC_PHASE_180: phase at DC is -180 deg with |L| = %.4g, ' ...
            'so the gain margin is %.2f dB at w = 0 (Nyquist encirclement).'], magDc, gmDc);
    end
end

% ---- every interior -180 deg crossing (gain margin) ----------------------
phMod = mod(ph + 180, 360) - 180;   % in (-180, 180]
idg = find(phMod(1:end-1) <= 0 & phMod(2:end) > 0);
if any(strcmp({C.kind},'ph180'))
    % A DC -180 crossing is already recorded; skip an interior duplicate at the
    % first grid point if it describes the same crossing.
    if ~isempty(idg) && any([C.wRadPerSec] == 0) && idg(1) == 1
        idg = idg(2:end);
    end
end
for k = 1:numel(idg)
    i = idg(k);
    r_ = (0 - phMod(i))/(phMod(i+1) - phMod(i));
    wc = exp(log(w(i)) + r_*(log(w(i+1)) - log(w(i))));
    gm = -20*log10(mag(i) + r_*(mag(i+1) - mag(i)));
    if disc, fHz = wc/(2*pi*Ts); else, fHz = wc/(2*pi); end
    C(end+1) = crossing(fHz, wc, -gm, -180, 'ph180', NaN, gm, ''); %#ok<AGROW>
end

% ---- discrete Nyquist boundary: -180 at pi/Ts ----------------------------
if disc
    phEnd = wrap180(ph(end));
    if abs(wrap180(phEnd + 180)) < 1e-6 && mag(end) > 0
        gmNy = -20*log10(mag(end));
        dup = any(strcmp({C.kind},'ph180') & abs([C.wRadPerSec] - pi/Ts) < 1e-9*pi/Ts);
        if ~dup
            C(end+1) = crossing(1/(2*Ts), pi/Ts, -gmNy, -180, 'ph180', NaN, gmNy, 'NYQUIST_BOUNDARY'); %#ok<AGROW>
            notes{end+1} = sprintf(['NYQUIST_BOUNDARY: phase reaches -180 deg at pi/Ts; ' ...
                'the gain margin there is %.2f dB.'], gmNy);
        end
    end
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
if isempty(gms)
    gmWorst = Inf;
    gmKnown = false;
else
    gmWorst = min(gms);
    gmKnown = true;
end

if isempty(pms)
    notes{end+1} = ['NO_GAIN_CROSSING: |L| never crosses 0 dB in the analysed band; ' ...
        'the phase margin is not defined by a crossing. GM may still be finite.'];
end
% A DC unity-gain loop intentionally reports its margin at f=0; do not call that
% "no crossing".
if numel(pms) > 1 && nDown > 1
    notes{end+1} = sprintf(['MULTIPLE_DOWNWARD_CROSSINGS: %d downward crossings; ' ...
        'the worst one (%.2f deg) is binding, not the first.'], nDown, pmWorst);
end
if ~isempty(pms) && any(pms < 0) && any(pms >= 0)
    notes{end+1} = 'MIXED_MARGIN_SIGNS: at least one crossing is healthy and another is negative.';
end
if isinf(gmWorst) && ~gmKnown
    notes{end+1} = 'NO_PHASE_180_CROSSING: phase never reaches -180 deg; GM is infinite.';
end

% ---- verdict: poles and frequency evidence are combined ------------------
freqUnstable = (~isempty(pms) && any(pms < 0)) || (gmKnown && gmWorst < 0);
freqMarginal = (~isempty(pms) && any(abs(pms) < 5)) || (gmKnown && gmWorst <= 1);
conflict = false;
if strcmp(clStatus,'UNSTABLE')
    verdict = 'UNSTABLE';
elseif strcmp(clStatus,'STABLE') && freqUnstable
    verdict = 'UNDETERMINED';
    conflict = true;
    notes{end+1} = ['EVIDENCE_CONFLICT: closed-loop poles are stable but frequency ' ...
        'margins are negative; neither conclusion is reported as STABLE.'];
elseif freqUnstable
    verdict = 'UNSTABLE';
elseif strcmp(clStatus,'MARGINAL') || freqMarginal
    verdict = 'MARGINAL';
elseif strcmp(clStatus,'STABLE')
    verdict = 'STABLE';
elseif ~isempty(pms) && all(pms >= 5) && (~gmKnown || gmWorst > 1)
    verdict = 'STABLE';         % frequency-only loop (delay): all evidence agrees
else
    verdict = 'UNDETERMINED';
end
if strcmp(clStatus,'MARGINAL')
    notes{end+1} = 'MARGINAL_POLES: closed-loop pole(s) lie on the stability boundary.';
end

% ---- evidence quality -----------------------------------------------------
freqComplete = ~isempty(pms) && isfinite(pmWorst) && ~conflict && nNonfinite == 0;
if strcmp(clStatus,'UNSTABLE') || strcmp(clStatus,'STABLE')
    if freqComplete && ~hasTd && opts.delay == 0 && ~strcmp(olStatus,'UNSTABLE')
        quality = 'VERIFIED';
    elseif freqComplete || ~isempty(pms) || gmKnown
        quality = 'PARTIAL';
    else
        quality = 'PARTIAL';    % poles alone are real evidence, but not both methods
    end
elseif ~isempty(pms) || gmKnown
    quality = 'PARTIAL';
else
    quality = 'NOT VERIFIED';
end
if conflict || nNonfinite > 0
    quality = 'PARTIAL';
end

r = struct();
r.schemaVersion = '1.1';
r.stable = stable;
r.openLoopStable = stable;
r.openLoopStatus = olStatus;
r.closedLoopStatus = clStatus;
r.closedLoopStable = clStatus;   % true | false | 'MARGINAL' | 'UNDETERMINED'
r.closedLoopPoles = pcl;
if isempty(pcl)
    r.closedLoopMaxPole = NaN;
else
    if disc, r.closedLoopMaxPole = max(abs(pcl)); else, r.closedLoopMaxPole = max(real(pcl)); end
end
r.marginal = strcmp(verdict,'MARGINAL');
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
r.gmKnown = gmKnown;
r.binding = binding;
r.verdict = verdict;
r.evidenceQuality = quality;
r.notes = notes;
r.Ts = Ts;
r.delay = opts.delay;
r.hasDelay = hasTd || opts.delay ~= 0;
r.freqUnit = char(opts.freqUnit);
r.meetsTarget = (pmWorst >= opts.pmTarget) && (gmWorst >= opts.gmTarget);
r.pmTarget = opts.pmTarget;
r.gmTarget = opts.gmTarget;
r.w = w; r.wRadPerSec = w; r.wHz = wHz; r.magdB = magdB; r.phase = ph;
if isnan(pmWorst)
    r.detail = sprintf(['no downward 0 dB crossing; %d pole(s), closed loop %s, ' ...
        'GM %s, %s, evidence %s'], numel(p), clStatus, ...
        tern(gmKnown, sprintf('%.1f dB', gmWorst), 'n/a'), verdict, quality);
else
    r.detail = sprintf(['%d down-crossing(s), worst PM %.1f deg at %.4g Hz, GM %s, ' ...
        '%s, closed loop %s, evidence %s'], r.nDown, pmWorst, C(max(binding, 1)).f, ...
        tern(gmKnown, sprintf('%.1f dB', gmWorst), 'n/a'), verdict, clStatus, quality);
end
end

% ---------------------------------------------------------------------------
function C = new_crossing()
C = struct('f', {}, 'wRadPerSec', {}, 'mag_dB', {}, 'phase_deg', {}, ...
    'kind', {}, 'pm', {}, 'gm_dB', {}, 'note', {});
end
function c = crossing(f, w, magdB, pdeg, kind, pm, gm, note)
c = struct('f', f, 'wRadPerSec', w, 'mag_dB', magdB, 'phase_deg', pdeg, ...
    'kind', kind, 'pm', pm, 'gm_dB', gm, 'note', note);
end

% ---------------------------------------------------------------------------
function [status, maxPole, nRhp, nAxis] = pole_status(p, disc)
if isempty(p)
    status = 'STABLE'; maxPole = NaN; nRhp = 0; nAxis = 0; return;
end
if any(~isfinite(p(:)))
    status = 'UNDETERMINED'; maxPole = NaN;
    nRhp = NaN; nAxis = NaN;
    return;
end
if disc
    nAxis = sum(abs(abs(p) - 1) < 1e-9);
    nRhp  = sum(abs(p) > 1);
    maxPole = max(abs(p));
else
    nAxis = sum(abs(real(p)) < 1e-9);
    nRhp  = sum(real(p) > 1e-9);
    maxPole = max(real(p));
end
if nRhp > 0
    status = 'UNSTABLE';
elseif nAxis > 0
    status = 'MARGINAL';
else
    status = 'STABLE';
end
end

% ---------------------------------------------------------------------------
function pm = phase_margin(phDeg)
% The phase at a crossing is defined modulo 360. `180 + angle` alone turns a
% negative-gain loop into +275.7 deg; wrapping gives the -84.26 deg that
% `margin` reports and that the closed-loop pole at +9 confirms.
p = mod(phDeg, 360);
if p > 180, p = p - 360; end
pm = 180 + p;
if pm > 180, pm = pm - 360; end
end

function y = wrap180(x)
y = mod(x + 180, 360) - 180;
if abs(y + 180) < 1e-12 && x > 0, y = 180; end
end

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
function [fHz, pdeg, wc] = interp_cross(w, wHz, mag, ph, i)
r_ = (0 - log(mag(i)))/(log(mag(i+1)) - log(mag(i)));
fHz = exp(log(wHz(i)) + r_*(log(wHz(i+1)) - log(wHz(i))));
pdeg = ph(i) + r_*(ph(i+1) - ph(i));
wc = exp(log(w(i)) + r_*(log(w(i+1)) - log(w(i))));
end

function o = defaults(o, d)
f = fieldnames(d);
for k = 1:numel(f)
    if ~isfield(o, f{k}), o.(f{k}) = d.(f{k}); end
end
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
