function r = mas_stability_verdict(sysOrResult, opts)
%MAS_STABILITY_VERDICT  Three answers that must never be collapsed into one:
%
%   math.stability    STABLE | UNSTABLE | UNDETERMINED
%   target.status     PASS   | FAIL     | UNDETERMINED
%   evidence.quality  VERIFIED | PARTIAL | NOT VERIFIED
%
%   r = mas_stability_verdict(L)
%   r = mas_stability_verdict(L, struct('pmTarget',45,'gmTarget',6))
%   r = mas_stability_verdict(mas_ctrl_analyze(L), opts)
%
% WHY THREE ANSWERS
% Phase 5.1 recorded 18 defects of the form "the number was right, the engineering
% conclusion was wrong". The combinations that a single boolean cannot express:
%
%   * ran + closed-loop stable + PM missing       -> math STABLE, target UNDETERMINED
%   * ran + closed-loop unstable + PM positive    -> math UNSTABLE (negative-gain loop)
%   * ran + closed-loop stable + PM below target  -> math STABLE, target FAIL
%   * ran + only a partial frequency sweep        -> evidence PARTIAL, not PASS
%
% The verdict is derived from two INDEPENDENT sources: poles of feedback(L,1) and
% margins at every 0 dB / -180 deg crossing (including DC and, for discrete
% systems, the Nyquist frequency). When the two disagree the result is
% UNDETERMINED with an EVIDENCE_CONFLICT note -- never a silent STABLE.
%
% CONTRACT (schema 1.0)
%   r.schemaVersion
%   r.verdict                 == r.math.stability
%   r.math.stability          STABLE | UNSTABLE | UNDETERMINED
%   r.math.marginal           true when the loop is only marginally stable; such a
%                             loop is reported as UNSTABLE because it is not
%                             asymptotically stable
%   r.math.closedLoopStatus   STABLE | UNSTABLE | MARGINAL | UNDETERMINED
%   r.target.status / pm / gm / pmTarget / gmTarget / reasons
%   r.evidence.quality / sources / independent / warnings / freqUnit / hasDelay
%   r.notes                   cellstr, human-readable reasons
%
% A missing margin is UNDETERMINED, never PASS and never FAIL. An infinite gain
% margin is a PASS (the phase never reaches -180 deg), not a missing value.

if nargin < 2, opts = struct(); end

if isstruct(sysOrResult)
    if isfield(sysOrResult, 'pmWorst') && isfield(sysOrResult, 'verdict')
        a = sysOrResult;
        if isfield(opts,'pmTarget'), a.pmTarget = opts.pmTarget; end
        if isfield(opts,'gmTarget'), a.gmTarget = opts.gmTarget; end
    else
        r = undetermined('INVALID_INPUT: struct is not a mas_ctrl_analyze result');
        return;
    end
elseif isempty(sysOrResult)
    r = undetermined('INVALID_INPUT: empty model');
    return;
elseif ~isa(sysOrResult, 'lti')
    r = undetermined(sprintf('INVALID_INPUT: expected an LTI model, got %s', class(sysOrResult)));
    return;
else
    try
        a = mas_ctrl_analyze(sysOrResult, opts);
    catch ME
        r = undetermined(['ANALYSIS_FAILED: ' ME.identifier ' :: ' ME.message]);
        return;
    end
end

notes = {};
if isfield(a,'notes'), notes = a.notes; end
if ~iscell(notes), notes = {notes}; end

% ---- dimension 1: mathematical stability ---------------------------------
legacy = a.verdict;
marginal = false;
switch legacy
    case 'STABLE'
        mathStatus = 'STABLE';
    case 'UNSTABLE'
        mathStatus = 'UNSTABLE';
    case 'MARGINAL'
        mathStatus = 'UNSTABLE';          % not asymptotically stable
        marginal = true;
        notes{end+1} = ['MARGINALLY_STABLE_TREATED_AS_UNSTABLE: the loop has a ' ...
            'zero or near-zero stability margin.'];
    otherwise
        mathStatus = 'UNDETERMINED';
end
if isfield(a,'closedLoopStatus')
    clStatus = a.closedLoopStatus;
elseif isfield(a,'closedLoopStable') && ischar(a.closedLoopStable)
    clStatus = a.closedLoopStable;
else
    clStatus = 'UNDETERMINED';
end

% ---- dimension 2: engineering target --------------------------------------
pmTarget = 45; gmTarget = 6;
if isfield(a,'pmTarget'), pmTarget = a.pmTarget; end
if isfield(a,'gmTarget'), gmTarget = a.gmTarget; end
if isfield(opts,'pmTarget'), pmTarget = opts.pmTarget; end
if isfield(opts,'gmTarget'), gmTarget = opts.gmTarget; end

pm = a.pmWorst;
if isfield(a,'gmKnown')
    gmKnown = a.gmKnown;
else
    gmKnown = isfinite(a.gmWorst);
end
gm = a.gmWorst;
pmKnown = isfinite(pm);
targetReasons = {};

if strcmp(mathStatus,'UNSTABLE')
    targetStatus = 'FAIL';
    targetReasons{end+1} = 'closed loop is not asymptotically stable';
else
    if ~pmKnown
        pmStatus = 'UNDETERMINED';
        targetReasons{end+1} = 'no finite phase margin (no 0 dB crossing)';
    elseif pm >= pmTarget
        pmStatus = 'PASS';
        targetReasons{end+1} = sprintf('PM %.2f >= %.2f deg', pm, pmTarget);
    else
        pmStatus = 'FAIL';
        targetReasons{end+1} = sprintf('PM %.2f < %.2f deg', pm, pmTarget);
    end
    if ~gmKnown && isinf(gm)
        gmStatus = 'PASS';
        targetReasons{end+1} = 'GM infinite (phase never reaches -180 deg)';
    elseif ~gmKnown
        gmStatus = 'UNDETERMINED';
        targetReasons{end+1} = 'no finite gain margin';
    elseif gm >= gmTarget
        gmStatus = 'PASS';
        targetReasons{end+1} = sprintf('GM %.2f >= %.2f dB', gm, gmTarget);
    else
        gmStatus = 'FAIL';
        targetReasons{end+1} = sprintf('GM %.2f < %.2f dB', gm, gmTarget);
    end
    if strcmp(pmStatus,'FAIL') || strcmp(gmStatus,'FAIL')
        targetStatus = 'FAIL';
    elseif strcmp(pmStatus,'PASS') && strcmp(gmStatus,'PASS')
        targetStatus = 'PASS';
    else
        targetStatus = 'UNDETERMINED';
    end
end

% ---- dimension 3: evidence quality ---------------------------------------
if isfield(a,'evidenceQuality')
    quality = a.evidenceQuality;
else
    quality = 'NOT VERIFIED';
end
sources = {};
if any(strcmp(clStatus, {'STABLE','UNSTABLE','MARGINAL'}))
    sources{end+1} = 'closed-loop poles of feedback(L,1)';
end
if pmKnown
    sources{end+1} = 'phase margins at every downward 0 dB crossing';
end
if gmKnown
    sources{end+1} = 'gain margins at every -180 deg crossing';
end
independent = numel(sources) >= 2;
% A label is not evidence. If no source produced a usable value (e.g. a NaN
% model where both roots() and freqresp() are non-finite), nothing was verified.
if isempty(sources)
    quality = 'NOT VERIFIED';
elseif strcmp(quality,'VERIFIED') && ~independent
    quality = 'PARTIAL';
end

freqUnit = 'rad/s';
if isfield(a,'freqUnit'), freqUnit = a.freqUnit; end
hasDelay = false;
if isfield(a,'hasDelay'), hasDelay = a.hasDelay; end

r = struct();
r.schemaVersion = '1.0';
r.verdict = mathStatus;
r.math = struct('stability', mathStatus, 'marginal', marginal, ...
    'closedLoopStatus', clStatus, ...
    'method', 'closed-loop poles + all-crossing frequency margins', ...
    'openLoopStatus', tern(isfield(a,'openLoopStatus'), a.openLoopStatus, ...
        tern(isfield(a,'openLoopStable') && a.openLoopStable, 'STABLE', 'UNKNOWN')));
r.target = struct('status', targetStatus, 'pm', pm, 'gm', gm, ...
    'pmTarget', pmTarget, 'gmTarget', gmTarget, ...
    'pmStatus', pmStatusOf(mathStatus, pm, pmTarget, pmKnown), ...
    'gmStatus', gmStatusOf(mathStatus, gm, gmTarget, gmKnown), ...
    'reasons', {targetReasons});
r.evidence = struct('quality', quality, 'sources', {sources}, ...
    'independent', independent, 'warnings', {notes}, ...
    'freqUnit', freqUnit, 'hasDelay', hasDelay);
r.notes = notes;
r.summary = sprintf('math=%s target=%s evidence=%s (PM %s, GM %s)', ...
    mathStatus, targetStatus, quality, fmt(pm, 'deg'), fmt(gm, 'dB'));
r.analysis = a;
end

% ---------------------------------------------------------------------------
function s = pmStatusOf(mathStatus, pm, target, known)
if strcmp(mathStatus,'UNSTABLE'), s = 'FAIL'; return; end
if ~known, s = 'UNDETERMINED';
elseif pm >= target, s = 'PASS';
else, s = 'FAIL'; end
end
function s = gmStatusOf(mathStatus, gm, target, known)
if strcmp(mathStatus,'UNSTABLE'), s = 'FAIL'; return; end
if ~known && isinf(gm), s = 'PASS';
elseif ~known, s = 'UNDETERMINED';
elseif gm >= target, s = 'PASS';
else, s = 'FAIL'; end
end
function s = fmt(v, unit)
if isinf(v), s = ['Inf ' unit];
elseif isnan(v), s = 'n/a';
else, s = sprintf('%.2f %s', v, unit); end
end

function r = undetermined(note)
r = struct();
r.schemaVersion = '1.0';
r.verdict = 'UNDETERMINED';
r.math = struct('stability','UNDETERMINED','marginal',false, ...
    'closedLoopStatus','UNDETERMINED','method','none','openLoopStatus','UNKNOWN');
r.target = struct('status','UNDETERMINED','pm',NaN,'gm',NaN, ...
    'pmTarget',45,'gmTarget',6,'pmStatus','UNDETERMINED', ...
    'gmStatus','UNDETERMINED','reasons',{{note}});
r.evidence = struct('quality','NOT VERIFIED','sources',{{}},'independent',false, ...
    'warnings',{{note}},'freqUnit','rad/s','hasDelay',false);
r.notes = {note};
r.summary = ['math=UNDETERMINED target=UNDETERMINED evidence=NOT VERIFIED: ' note];
r.analysis = struct();
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
