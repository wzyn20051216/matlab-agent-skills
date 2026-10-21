function m = boost_margins(w, Lw)
%BOOST_MARGINS  Phase and gain margins evaluated at EVERY crossing.
%
%   m = boost_margins(w, Lw)
%
% WHY THIS REPLACES THE OLD margins_from()
% The previous helper reported the phase margin at the HIGHEST 0 dB crossing and
% the gain margin at the FIRST -180 deg crossing. That is right only when the loop
% crosses 0 dB once. A Boost with an LC resonance crosses more than once: measured
% on the single-loop architecture, |L| crosses 0 dB at 49.3 Hz (PM 125 deg) and
% again at 300 Hz (PM 15.9 deg). Reporting only the highest one happens to give
% the worst PM in that case, but nothing guarantees it, and the gain margin is
% still taken at a crossing that may not be the binding one.
%
% The rule used here is the standard engineering one for a loop with several
% crossings: the loop is accepted only if
%   * every downward 0 dB crossing has PM > 0, and
%   * every -180 deg crossing has GM > 0.
% The reported PM/GM are the WORST over those crossings, and the full list is
% returned so a report can show what was actually evaluated instead of a single
% number.
%
% OUTPUT
%   m.cross   struct array: f, pm, kind ('down'|'up')
%   m.gm      struct array: f, gm
%   m.pmWorst worst phase margin over downward crossings (NaN if none)
%   m.gmWorst worst gain margin over -180 crossings (Inf if none)
%   m.nDown, m.nUp, m.fcHighest (highest downward crossing)
%   m.crossingsOK  logical: pmWorst > 0 && gmWorst > 0 && nDown >= 1

w = w(:); Lw = Lw(:);
mag = abs(Lw);
ph  = unwrap(angle(Lw));

m = struct();
m.cross = struct('f',{},'pm',{},'kind',{});
m.gm    = struct('f',{},'gm',{});

% ---- downward crossings: |L| goes from >=1 to <1 ----
ix = find(mag(1:end-1) >= 1 & mag(2:end) < 1);
for k = 1:numel(ix)
    i = ix(k);
    [f, phc] = interp_cross(w, mag, ph, i);
    m.cross(end+1) = struct('f',f,'pm',180 + phc*180/pi,'kind','down'); %#ok<AGROW>
end
% ---- upward crossings: |L| comes back above 1 (the resonance) ----
iu = find(mag(1:end-1) < 1 & mag(2:end) >= 1);
for k = 1:numel(iu)
    i = iu(k);
    [f, phc] = interp_cross(w, mag, ph, i);
    m.cross(end+1) = struct('f',f,'pm',180 + phc*180/pi,'kind','up'); %#ok<AGROW>
end

% ---- -180 deg crossings: gain margin at each ----
jx = find(ph(1:end-1) > -pi & ph(2:end) <= -pi);
for k = 1:numel(jx)
    j = jx(k);
    r = (-pi - ph(j))/(ph(j+1)-ph(j));
    f = exp(log(w(j)) + r*(log(w(j+1))-log(w(j))))/(2*pi);
    mg = exp(log(mag(j)) + r*(log(mag(j+1))-log(mag(j))));
    m.gm(end+1) = struct('f',f,'gm',-20*log10(mg)); %#ok<AGROW>
end

m.nDown = numel(ix);
m.nUp   = numel(iu);
if m.nDown > 0
    fdown = arrayfun(@(s) s.f, m.cross(strcmp({m.cross.kind},'down')));
    pmdown = arrayfun(@(s) s.pm, m.cross(strcmp({m.cross.kind},'down')));
    m.fcHighest = max(fdown);
    m.pmWorst   = min(pmdown);
else
    m.fcHighest = NaN;
    m.pmWorst   = NaN;
end
if isempty(m.gm)
    m.gmWorst = Inf;
else
    m.gmWorst = min([m.gm.gm]);
end
m.crossingsOK = (m.nDown >= 1) && (m.pmWorst > 0) && (m.gmWorst > 0);
end

% ---------------------------------------------------------------------------
function [f, phc] = interp_cross(w, mag, ph, i)
% log-linear interpolation of the crossing between samples i and i+1
r   = (0 - log(mag(i)))/(log(mag(i+1)) - log(mag(i)));
f   = exp(log(w(i)) + r*(log(w(i+1)) - log(w(i))))/(2*pi);
phc = ph(i) + r*(ph(i+1) - ph(i));
end
