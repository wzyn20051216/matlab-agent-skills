%% Phase 3A.4 / Task 0: quantify the 1-sample settle-time fix on real data
%
% Purpose: the S5 metric used to report tv(lastOut) (the last OUT-of-band
% sample) instead of tv(lastOut+1) (the first IN-band sample that is then
% held). This script recomputes settleMs with BOTH definitions on the 21
% stored waveforms of Phase 3A.2 and reports
%   - the per-case delta (expected: exactly +1 sample = +0.0010 ms)
%   - whether any PASS/FAIL verdict changes under the ORIGINAL thresholds
%
% Read-only: it does not touch task5_acceptance.m or its artifacts.
% Output: a4_task0_settle_fix.json / .mat

clear; close all;
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, '..'));
outDir = getenv('BUCK_OUT');
if isempty(outDir), outDir = fullfile(here, '..', '..', 'artifacts', 'validation', 'buck'); end
outDir = strrep(outDir, '/', filesep);
fprintf('=========== 3A.4 Task 0: settle-time 1-sample fix audit ===========\n');

D = load(fullfile(outDir, 'task5_acceptance.mat'));
recs = D.recs; conds = D.conds; ctrls = D.ctrls;
nRec = numel(recs);
fprintf('records: %d  conditions: %d  controllers: %d\n', nRec, numel(conds), numel(ctrls));

% Original acceptance thresholds (S1-S9). NOT modified in any way.
STD = struct('PM_min',50, 'GM_min',6, 'sserr_max',0.1, 'recover_max',1.0, ...
             'startup_os_max',5, 'dip_max',12, 'duty_lo',0.05, 'duty_hi',0.85);
fprintf('thresholds (unchanged): PM>=%g GM>=%g dB |ssErr|<=%g%% S5<=%g ms OS<=%g%% |dip|<=%g%% duty in [%g,%g]\n\n', ...
    STD.PM_min, STD.GM_min, STD.sserr_max, STD.recover_max, ...
    STD.startup_os_max, STD.dip_max, STD.duty_lo, STD.duty_hi);

res = struct('cond',{},'ctrl',{},'settleOld',{},'settleNew',{},'deltaMs',{}, ...
             'firstEntry',{},'nExits',{},'passOld',{},'passNew',{},'note','');
fprintf('%-5s %-6s %11s %11s %9s %11s %7s %5s %5s\n', ...
    'cond','ctrl','settleOld','settleNew','delta','firstEntry','nExits','old','new');
for q = 1:nRec
    r = recs(q);
    % ---- recompute both definitions on the stored waveform ----
    t = r.t; y = r.vC; yRef = 12; bandPct = 1; tEvent = 0.060;
    iEv = find(t >= tEvent, 1, 'first');
    tv = t(iEv:end); yv = y(iEv:end);
    band = bandPct/100*abs(yRef);
    inB = abs(yv - yRef) <= band;
    outIdx = find(~inB);
    if isempty(outIdx)
        sOld = 0; sNew = 0;
    elseif outIdx(end) == numel(inB)
        sOld = NaN; sNew = NaN;
    else
        sOld = (tv(outIdx(end))   - tv(1))*1e3;
        sNew = (tv(outIdx(end)+1) - tv(1))*1e3;
    end
    % verdict under the original thresholds (S1-S8; S9 is reproducibility)
    passOld = verdict(r, sOld, STD);
    passNew = verdict(r, sNew, STD);
    note = '';
    if ~isnan(r.settleMs) && ~isnan(sOld) && abs(r.settleMs - sOld) > 1e-9
        note = sprintf('stored=%.6f differs from recomputed old=%.6f', r.settleMs, sOld);
    end
    res(q) = struct('cond',r.cond,'ctrl',r.ctrl,'settleOld',sOld,'settleNew',sNew, ...
        'deltaMs',sNew-sOld,'firstEntry',r.recoverMs,'nExits',r.nExits, ...
        'passOld',passOld,'passNew',passNew,'note',note);
    fprintf('%-5s %-6s %11.4f %11.4f %9.4f %11.4f %7d %5d %5d\n', ...
        r.cond, r.ctrl, sOld, sNew, sNew-sOld, r.recoverMs, ...
        tern(isnan(r.nExits),-1,round(r.nExits)), passOld, passNew);
end

d = [res.deltaMs];
d = d(isfinite(d));
fprintf('\n--- delta statistics (finite cases, n=%d) ---\n', numel(d));
fprintf('  min=%.9f  max=%.9f  mean=%.9f  (expected: one sample = 0.001 ms)\n', ...
    min(d), max(d), mean(d));
fprintf('  all deltas identical? %d   value=%.9f\n', all(abs(d-d(1))<1e-9), d(1));

% sample interval check on the step window
tq = recs(1).t; dq = diff(tq(tq>=0.060)); dq = dq(dq>0);
fprintf('  median dt after the step = %.6f s (=%.4f ms)\n', median(dq), median(dq)*1e3);

flip = find([res.passOld] ~= [res.passNew]);
fprintf('\n--- verdict changes ---\n');
if isempty(flip)
    fprintf('  none. All %d verdicts are unchanged by the fix.\n', nRec);
else
    for q = flip
        fprintf('  CHANGED: %s x %s : %d -> %d\n', res(q).cond, res(q).ctrl, ...
            res(q).passOld, res(q).passNew);
    end
end

% which criterion binds, before and after
fprintf('\n--- binding criteria per case (new definition) ---\n');
for q = 1:nRec
    b = binders(recs(q), res(q).settleNew, STD);
    fprintf('  %-5s %-6s : %s\n', res(q).cond, res(q).ctrl, b);
end

save(fullfile(outDir,'a4_task0_settle_fix.mat'),'res','STD');
fid = fopen(fullfile(outDir,'a4_task0_settle_fix.json'),'w');
fwrite(fid, jsonencode(struct('records',res, ...
    'deltaMean',mean(d),'deltaUnique',d(1),'nVerdictChanges',numel(flip), ...
    'medianDt',median(dq),'standards',STD)), 'char'); fclose(fid);
fprintf('\nsaved a4_task0_settle_fix.mat / .json\n');

% ------------------------------------------------------------------
function p = verdict(r, s5, S)
p = (r.maxRe < 0) && (r.Pm >= S.PM_min) && (r.Gm >= S.GM_min) && ...
    (abs(r.ssErrPct) <= S.sserr_max) && isfinite(s5) && (s5 <= S.recover_max) && ...
    (r.startupOs <= S.startup_os_max) && (abs(r.dipPct) <= S.dip_max) && ...
    (r.dutyMin >= S.duty_lo) && (r.dutyMax <= S.duty_hi);
end

function s = binders(r, s5, S)
s = '';
if ~(r.maxRe < 0), s = [s 'S1 ']; end
if ~(r.Pm >= S.PM_min), s = [s sprintf('S2(%.2f) ', r.Pm)]; end
if ~(r.Gm >= S.GM_min), s = [s sprintf('S3(%.2f) ', r.Gm)]; end
if ~(abs(r.ssErrPct) <= S.sserr_max), s = [s 'S4 ']; end
if ~(isfinite(s5) && s5 <= S.recover_max), s = [s sprintf('S5(%.3f) ', s5)]; end
if ~(r.startupOs <= S.startup_os_max), s = [s 'S6 ']; end
if ~(abs(r.dipPct) <= S.dip_max), s = [s sprintf('S7(%.2f) ', r.dipPct)]; end
if ~(r.dutyMin >= S.duty_lo && r.dutyMax <= S.duty_hi), s = [s 'S8 ']; end
if isempty(s), s = 'ALL PASS'; end
end

function v = tern(c, a, b)
if c, v = a; else, v = b; end
end
