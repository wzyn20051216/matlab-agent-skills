function r = mas_ctrl_pid_design(P, opts)
%MAS_CTRL_PID_DESIGN  PI/PID gains that MAXIMISE bandwidth subject to margins.
%
%   r = mas_ctrl_pid_design(P)                       % PI, PM>=45, GM>=6 dB
%   r = mas_ctrl_pid_design(P, struct('pmTarget',60,'gmTarget',10,'delay',Ts))
%
%   r.feasible      true if any candidate met BOTH margins
%   r.Kp, r.Ki, r.Kd
%   r.pm, r.gm, r.fcHz       margins of the chosen candidate
%   r.table         every candidate tried, with its margins
%   r.reason        why nothing was found, when feasible is false
%
% WHY A GRID AND NOT `pidtune`
% Not because a grid is better, but because the answer must be CHECKABLE. The
% candidate is graded by mas_ctrl_analyze, which reports the WORST margin over all
% 0 dB crossings; a controller that looks fine at its design crossing and has a
% second, worse one is rejected here. `pidtune` returns gains without that guarantee,
% and re-deriving the same robustness statement from its output is more work than
% sweeping, for a two-parameter loop.
%
% The objective is not "best margins" but "widest bandwidth that still meets the
% margins", because margins are a constraint, not a goal: an over-damped loop meets
% every margin and is useless.
%
% SATURATION IS NOT MODELLED HERE. A design from this function is a linear design;
% whether it survives the actuator limit has to be checked with mas_ctrl_aw_sim.

if nargin < 2, opts = struct(); end
opts = dflt(opts, struct('pmTarget', 45, 'gmTarget', 6, 'delay', 0, ...
    'zeroRatio', [0.05 0.1 0.2 0.4], 'nGain', 140, 'pid', false, ...
    'KpRange', [], 'verbose', false));

s = tf('s');
base = struct('pmTarget', opts.pmTarget, 'gmTarget', opts.gmTarget, ...
    'delay', opts.delay, 'grid', 6e4);

nr = numel(opts.zeroRatio);
if isempty(opts.KpRange)
    % start from the gain that puts the plant's own crossover near its dominant
    % pole, then sweep three decades around it. Guessing a range is unavoidable
    % without a plant model; the table makes the guess visible.
    k0 = 1/max(1e-12, abs(freqresp(P, 1)));
    opts.KpRange = logspace(log10(k0) - 2, log10(k0) + 3, opts.nGain);
end

T = struct('Kp', {}, 'Ki', {}, 'pm', {}, 'gm', {}, 'fcHz', {}, 'nCross', {}, ...
    'verdict', {}, 'ok', {});
for a = 1:numel(opts.KpRange)
    for b = 1:nr
        Kp = opts.KpRange(a);
        Ki = Kp * opts.zeroRatio(b);
        C = Kp + Ki/s;
        if opts.pid
            % derivative on the error with a fixed 1/20 of the target bandwidth as
            % the filter pole; not optimised, because a third free parameter makes
            % the grid unreadable without a real objective function
            C = C + Kp*1e-3*s/(1 + s*1e-3);
        end
        L = C*P;
        r = mas_ctrl_analyze(L, base);
        ok = (r.pmWorst >= opts.pmTarget) && (r.gmWorst >= opts.gmTarget) && ...
             strcmp(r.verdict, 'STABLE');
        T(end+1) = struct('Kp', Kp, 'Ki', Ki, 'pm', r.pmWorst, 'gm', r.gmWorst, ...
            'fcHz', pickF(r), 'nCross', r.nDown, 'verdict', r.verdict, 'ok', ok); %#ok<AGROW>
    end
end

okIdx = find([T.ok]);
r = struct();
r.table = T;
r.pmTarget = opts.pmTarget;
r.gmTarget = opts.gmTarget;
if isempty(okIdx)
    % No candidate met the constraints. Report the best margin actually achieved
    % instead of silently returning the highest-bandwidth one.
    [~, k] = max([T.pm]);
    r.feasible = false;
    r.Kp = NaN; r.Ki = NaN; r.Kd = NaN;
    r.pm = T(k).pm; r.gm = T(k).gm; r.fcHz = T(k).fcHz;
    r.reason = sprintf(['no candidate met PM>=%.0f and GM>=%.0f dB; best PM seen was ' ...
        '%.1f deg at Kp=%.4g. The plant may need a different structure (feedforward, ' ...
        'inner loop), not different gains.'], opts.pmTarget, opts.gmTarget, ...
        T(k).pm, T(k).Kp);
else
    [~, kk] = max([T(okIdx).fcHz]);
    k = okIdx(kk);
    r.feasible = true;
    r.Kp = T(k).Kp; r.Ki = T(k).Ki; r.Kd = 0;
    r.pm = T(k).pm; r.gm = T(k).gm; r.fcHz = T(k).fcHz;
    r.reason = sprintf('widest feasible bandwidth: %.4g Hz at PM %.1f deg', ...
        T(k).fcHz, T(k).pm);
end
r.margins = struct('PM', r.pm, 'GM', r.gm, 'crossings', T(k).nCross);
r.nCandidates = numel(T);
r.nFeasible = numel(okIdx);
end

% ---------------------------------------------------------------------------
function f = pickF(r)
% The reported crossover is the LOWEST downward crossing, because that is where a
% bode plot's "bandwidth" is conventionally read; the margin verdict still uses the
% worst of all crossings.
d = r.crossings(strcmp({r.crossings.kind}, 'down'));
if isempty(d), f = NaN; else, f = min([d.f]); end
end

function o = dflt(o, d)
f = fieldnames(d);
for k = 1:numel(f)
    if ~isfield(o, f{k}), o.(f{k}) = d.(f{k}); end
end
end
