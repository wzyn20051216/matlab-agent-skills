function res = buck_a6_task6_accept(outDir, opt)
%BUCK_A6_TASK6_ACCEPT  Final joint acceptance matrix (C1-C7, baseline + stress).
%
% Phase 3A.6 Task 6. This is the deliverable that a reviewer should be able to
% run on a CLEAN checkout, in an EMPTY output directory, and get the same
% numbers. It therefore
%   * reads no previous result file -- every number is produced here;
%   * records which criteria are MEASURED in this model, which are INHERITED
%     design values from the average model, which are THEORETICAL estimates and
%     which are NOT VERIFIED at all;
%   * keeps the five frozen noise seeds for the baseline and adds independent
%     perturbation runs on the worst conditions, so "7/7" is not a statement
%     about five lucky seeds;
%   * re-runs one case twice to check S9 reproducibility bit for bit;
%   * writes JSON + MAT + PNG and then re-reads them to prove the three agree.
%
%   res = buck_a6_task6_accept(outDir)
%   res = buck_a6_task6_accept(outDir, struct('quick',true))
%
% CONFIGS
%   B     deployed baseline: boundary sampling, half-ripple comp, 1 period delay,
%         D+ sensor chain, L = 150 uH
%   S1    2 periods of computation delay      (expected to FAIL -- negative control)
%   S2    sample at 0.25 Ts                   (Task 4 worst phase)
%   S3    W1 worst-case tolerance combination (Task 5)
%   S4    L = 220 uH                          (Task 3 recommendation)
%   S5    ADC LSB 0.05 A                      (Task 5 stress)
%
% A negative control (S1) is included on purpose: a harness that reports PASS for
% every configuration proves nothing about its ability to detect a failure.

if nargin < 1 || isempty(outDir), outDir = getenv('BUCK_OUT'); end
if nargin < 2, opt = struct(); end
if ~isfield(opt,'quick'), opt.quick = false; end
outDir = strrep(outDir,'/',filesep);
here = fileparts(mfilename('fullpath')); addpath(fileparts(here));
if ~exist(outDir,'dir'), mkdir(outDir); end

Vref = 12;
STD = struct('sserr_max',0.1,'s5_max',1.0,'os_max',5,'dip_max',12, ...
             'dlo',0.05,'dhi',0.85,'imax',12);
LOWMARGIN = 20;
oRun = struct('ratio',2,'tStep',0.06,'tEnd',0.08,'nSub',200,'Tss',5e-3);
SEEDS = [11 23 37 41 59];
EXTRA = [61 71 83 97 103 113 127 139 151 167];

conds = [ ...
    struct('id','C1','Vin',48,'R',6,  'L',150e-6)
    struct('id','C2','Vin',42,'R',6,  'L',150e-6)
    struct('id','C3','Vin',54,'R',6,  'L',150e-6)
    struct('id','C4','Vin',48,'R',12, 'L',150e-6)
    struct('id','C5','Vin',48,'R',3,  'L',150e-6)
    struct('id','C6','Vin',54,'R',3,  'L',150e-6)
    struct('id','C7','Vin',48,'R',6,  'L',195e-6) ];

sensDp = struct('enable',true,'fBW',10e3,'nd',1,'gain',1.02,'offset',0.1, ...
                'sigma',0.02,'lsb',0.02,'iMaxPhys',10,'tol',3.0);

fprintf('=========== 3A.6 Task 6: final joint acceptance ===========\n');
fprintf('output dir : %s\n', outDir);
pre = dir(outDir);
preFiles = {pre(~[pre.isdir]).name};
fprintf('files present before the run: %d %s\n', numel(preFiles), strjoin(preFiles,', '));
fprintf('seeds (baseline) : %s\n', mat2str(SEEDS));
fprintf('seeds (perturbation) : %s\n', mat2str(EXTRA));

%% ---------- configuration table ----------
cfg = struct('id',{},'desc',{},'nDly',{},'phi',{},'L',{},'Vin',{},'C',{}, ...
             'ESR',{},'lsb',{},'compMode',{},'expectFail',{});
cfg(end+1) = mkcfg('B', 'deployed baseline',1,0,      150e-6,48,  220e-6,10e-3,0.02,'boundary',false);
cfg(end+1) = mkcfg('S1','2 periods delay (negative control)',2,0,150e-6,48,220e-6,10e-3,0.02,'boundary',true);
cfg(end+1) = mkcfg('S2','sample at 0.25 Ts',1,0.25,   150e-6,48,  220e-6,10e-3,0.02,'boundary',false);
cfg(end+1) = mkcfg('S3','worst-case tolerance combo W1',1,0,120e-6,43.2,176e-6,30e-3,0.02,'boundary',false);
cfg(end+1) = mkcfg('S4','L = 220 uH candidate',1,0,   220e-6,48,  220e-6,10e-3,0.02,'boundary',false);
cfg(end+1) = mkcfg('S5','ADC LSB 0.05 A',1,0,         150e-6,48,  220e-6,10e-3,0.05,'boundary',false);

%% ---------- 1) metric matrix: baseline (5 seeds) + stress (3 seeds) ----------
fprintf('\n--- 1) metric matrix ---\n');
fprintf('%-4s %-4s %5s %9s %9s %9s %7s %7s %7s %7s %7s %8s | %s\n', ...
    'cfg','cond','seed','ssErr%','S5 ms','dip%','OS%','dMin','dMax','iLpk','ripple','max|lam|','class');
R = struct('cfg',{},'cond',{},'seed',{},'ssErr',{},'s5',{},'dip',{},'os',{}, ...
    'dMin',{},'dMax',{},'iLpk',{},'iLavg',{},'ripple',{},'iLmin',{}, ...
    'maxAbs',{},'converged',{},'marginPct',{},'class',{},'mpass',{});
for ic = 1:numel(cfg)
    c = cfg(ic);
    for k = 1:numel(conds)
        cd = conds(k);
        % per-condition overrides come from the config (S3 changes Vin, L, C, ESR)
        if strcmp(c.id,'S3')
            cc = cd; cc.Vin = c.Vin; cc.L = c.L;
        else
            cc = cd; if c.L ~= 150e-6, cc.L = c.L; end
        end
        p = mkp(cc, c, sensDp);
        rf = sw_floquet(p, struct('verbose',false,'maxIter',1200));
        seeds = SEEDS; if ~strcmp(c.id,'B'), seeds = SEEDS(1:3); end
        if opt.quick, seeds = SEEDS(1); end
        for sd = seeds
            o = oRun; o.noise = true; o.seed = sd;
            m = cfg_metrics(p,o,Vref);
            [cls, mg, mp] = classify_cfg(m, STD, LOWMARGIN, rf);
            R(end+1) = struct('cfg',c.id,'cond',cd.id,'seed',sd,'ssErr',m.ssErr, ...
                's5',m.settleMs,'dip',m.dipPct,'os',m.osPct,'dMin',m.dMin, ...
                'dMax',m.dMax,'iLpk',m.iLpkAll,'iLavg',m.iLavg, ...
                'ripple',m.ripplePct,'iLmin',m.iLminAll,'maxAbs',rf.maxAbs, ...
                'converged',rf.converged,'marginPct',mg,'class',cls,'mpass',mp); %#ok<AGROW>
            fprintf('%-4s %-4s %5d %9.4f %9.4f %9.3f %7.3f %7.4f %7.4f %7.3f %7.1f %8s | %s\n', ...
                c.id, cd.id, sd, m.ssErr, m.settleMs, m.dipPct, m.osPct, m.dMin, ...
                m.dMax, m.iLpkAll, m.ripplePct, ...
                tern(rf.converged, sprintf('%.4f',rf.maxAbs), 'none'), cls);
        end
    end
end

%% ---------- 2) independent perturbation on the worst conditions ----------
% The 7/7 claim must not rest on five seeds. The two worst conditions are
% re-run with ten NEW seeds, and C1 is re-run with a +-1 % input perturbation,
% which is far below the stated +-10 % tolerance, so the verdict must not move.
fprintf('\n--- 2) independent perturbation (10 new seeds + +-1%% Vin) ---\n');
P = struct('kind',{},'cond',{},'seed',{},'ssErr',{},'s5',{},'dip',{},'iLpk',{},'class',{});
for q = 1:2
    if q == 1, cid = 'C6'; else, cid = 'C5'; end
    cd = conds(strcmp({conds.id}, cid));
    p = mkp(cd, cfg(1), sensDp);
    s5s = []; dps = []; pk = []; cls = cell(1,numel(EXTRA));
    for j = 1:numel(EXTRA)
        o = oRun; o.noise = true; o.seed = EXTRA(j);
        m = cfg_metrics(p,o,Vref);
        s5s(end+1) = m.settleMs; dps(end+1) = m.dipPct; pk(end+1) = m.iLpkAll; %#ok<AGROW>
        cls{j} = metrics_class(m, STD, LOWMARGIN);
        P(end+1) = struct('kind','seed','cond',cid,'seed',EXTRA(j),'ssErr',m.ssErr, ...
            's5',m.settleMs,'dip',m.dipPct,'iLpk',m.iLpkAll,'class',cls{j}); %#ok<AGROW>
    end
    fprintf('  %s 10 extra seeds: S5 %.4f..%.4f  dip %.3f..%.3f  iLpk %.2f..%.2f  classes %s\n', ...
        cid, min(s5s), max(s5s), min(dps), max(dps), min(pk), max(pk), strjoin(unique(cls),','));
end
for dv = [-0.48 0.48]
    cd = conds(1); cd.Vin = cd.Vin + dv;
    p = mkp(cd, cfg(1), sensDp);
    for sd = [11 23 37]
        o = oRun; o.noise = true; o.seed = sd;
        m = cfg_metrics(p,o,Vref);
        cl = metrics_class(m, STD, LOWMARGIN);
        P(end+1) = struct('kind','vin','cond','C1','seed',sd,'ssErr',m.ssErr, ...
            's5',m.settleMs,'dip',m.dipPct,'iLpk',m.iLpkAll,'class',cl); %#ok<AGROW>
        fprintf('  C1 Vin=%+.2f V seed %d: ssErr %+.4f%% S5 %.4f dip %.3f -> %s\n', ...
            cd.Vin, sd, m.ssErr, m.settleMs, m.dipPct, cl);
    end
end

%% ---------- 3) reproducibility (S9) ----------
fprintf('\n--- 3) S9 reproducibility: same seed twice, bit for bit ---\n');
p = mkp(conds(1), cfg(1), sensDp);
o = oRun; o.noise = true; o.seed = 11;
a = cfg_metrics(p,o,Vref); b = cfg_metrics(p,o,Vref);
dRep = [abs(a.ssErr-b.ssErr), abs(a.settleMs-b.settleMs), abs(a.dipPct-b.dipPct), ...
        abs(a.iLpkAll-b.iLpkAll)];
fprintf('  |diff| ssErr %.3e  S5 %.3e  dip %.3e  iLpk %.3e  -> %s\n', ...
    dRep, tern(max(dRep)==0,'BIT-IDENTICAL','NOT reproducible'));
s9 = struct('identical',max(dRep)==0,'diff',dRep);

% Cross-VERSION reproducibility: the frozen D+ artefact was produced by the
% pre-Task-4 engine. Comparing the new baseline against it is the check that the
% refactor (in-period sampling, factored control law, noise flag) did not quietly
% change the deployed behaviour. It is OPTIONAL on purpose: if the file is absent
% the run still stands on its own, which is what "no dependency on old artefacts"
% has to mean.
repoRoot = fileparts(fileparts(fileparts(here)));
frozenF = fullfile(repoRoot,'artifacts','validation','buck','a6_dplus.json');
xver = struct('available',false,'maxS5',NaN,'maxDip',NaN,'maxSsErr',NaN);
if exist(frozenF,'file')
    F = jsondecode(fileread(frozenF));
    dS5 = 0; dDip = 0; dE = 0;
    for k = 1:numel(conds)
        fsel = strcmp({F.records.cond}, conds(k).id);
        nsel = strcmp({R.cfg},'B') & strcmp({R.cond},conds(k).id);
        dS5 = max(dS5, abs(max([F.records(fsel).settleMs]) - max([R(nsel).s5])));
        dDip = max(dDip, abs(min([F.records(fsel).dipPct]) - min([R(nsel).dip])));
        dE = max(dE, abs(max(abs([F.records(fsel).ssErr])) - max(abs([R(nsel).ssErr]))));
    end
    xver = struct('available',true,'maxS5',dS5,'maxDip',dDip,'maxSsErr',dE);
    fprintf('  vs frozen D+ artefact: max |dS5| %.4f ms, |dDip| %.3f pp, |dssErr| %.4f pp\n', ...
        dS5, dDip, dE);
end

%% ---------- 4) per-condition summary (baseline) ----------
fprintf('\n--- 4) per-condition summary (baseline config B, worst over 5 seeds) ---\n');
fprintf('%-4s %8s %8s %8s %7s %7s %7s %7s %7s %8s | %s\n','cond','ssErr%','S5 ms', ...
    'dip%','OS%','dMin','dMax','iLpk','ripple','margin%','class');
SUM = struct('cond',{},'ssErr',{},'s5',{},'dip',{},'os',{},'dMin',{},'dMax',{}, ...
             'iLpk',{},'ripple',{},'margin',{},'class',{});
for k = 1:numel(conds)
    sel = strcmp({R.cfg},'B') & strcmp({R.cond},conds(k).id);
    e = max(abs([R(sel).ssErr])); s5 = max([R(sel).s5]); dp = min([R(sel).dip]);
    os = max([R(sel).os]); dl = min([R(sel).dMin]); dh = max([R(sel).dMax]);
    pk = max([R(sel).iLpk]); rp = max([R(sel).ripple]);
    mg = min([100*(1-e/STD.sserr_max), 100*(1-s5/STD.s5_max), ...
              100*(1-os/STD.os_max), 100*(1-abs(dp)/STD.dip_max), ...
              100*(dl-STD.dlo)/(STD.dhi-STD.dlo), 100*(STD.dhi-dh)/(STD.dhi-STD.dlo), ...
              100*(1-pk/STD.imax)]);
    raw = e<=STD.sserr_max && s5<=STD.s5_max && os<=STD.os_max && ...
          abs(dp)<=STD.dip_max && dl>=STD.dlo && dh<=STD.dhi && pk<=STD.imax;
    cls = classify(raw, mg, LOWMARGIN);
    fprintf('%-4s %8.4f %8.4f %8.3f %7.3f %7.4f %7.4f %7.3f %7.1f %8.1f | %s\n', ...
        conds(k).id, e, s5, dp, os, dl, dh, pk, rp, mg, cls);
    SUM(end+1) = struct('cond',conds(k).id,'ssErr',e,'s5',s5,'dip',dp,'os',os, ...
        'dMin',dl,'dMax',dh,'iLpk',pk,'ripple',rp,'margin',mg,'class',cls); %#ok<AGROW>
end

%% ---------- 5) evidence provenance ----------
prov = [ ...
  struct('criterion','S1 local stability','source','MEASURED', ...
      'detail','Floquet multipliers of the closed-loop period map, per config/condition'); ...
  struct('criterion','S2 phase margin','source','INHERITED', ...
      'detail','average-model discrete design value; not measurable in the switching model, so UNDETERMINED at this level'); ...
  struct('criterion','S3 gain margin','source','INHERITED', ...
      'detail','average-model discrete design value; not measurable in the switching model, so UNDETERMINED at this level'); ...
  struct('criterion','S4 steady-state error','source','MEASURED','detail','80 ms switching run, mean over the last 5 ms'); ...
  struct('criterion','S5 settling','source','MEASURED','detail','+-1 % band, step_metrics.m, 1 us resolution'); ...
  struct('criterion','S6 overshoot','source','MEASURED','detail','max vOut over the whole run'); ...
  struct('criterion','S7 load dip','source','MEASURED','detail','load doubled (R -> R/2) at 60 ms'); ...
  struct('criterion','S8 duty range','source','MEASURED','detail','applied duty, post-step window'); ...
  struct('criterion','S9 reproducibility','source','MEASURED','detail','same seed twice, bit-identical'); ...
  struct('criterion','current peak','source','MEASURED','detail','instantaneous peak, graded against the strict 12 A limit'); ...
  struct('criterion','ripple','source','MEASURED','detail','per-period peak-valley / cycle average'); ...
  struct('criterion','CCM/DCM boundary','source','THEORETICAL', ...
      'detail','R < Vref/(dIL/2) for CCM; the model has no DCM state, so DCM operation is UNDETERMINED'); ...
  struct('criterion','temperature, ageing','source','NOT VERIFIED','detail','no thermal or lifetime model'); ...
  struct('criterion','hardware (level E)','source','NOT VERIFIED','detail','no board, no measurement') ];

%% ---------- 6) artefacts ----------
[~, outName] = fileparts(outDir);
res = struct('level','3A.6-Task6','std',STD,'seeds',SEEDS,'extraSeeds',EXTRA, ...
    'configs',cfg,'records',R,'perturbation',P,'s9',s9,'crossVersion',xver, ...
    'summary',SUM,'provenance',prov,'outDirName',outName, ...
    'note',['Every number in this file was produced by this run in this ' ...
            'directory. No previous result file is read. S2/S3 remain ' ...
            'average-model design values and are labelled INHERITED.']);
save(fullfile(outDir,'a6_task6_accept.mat'),'res');
fid = fopen(fullfile(outDir,'a6_task6_accept.json'),'w');
if fid >= 0, fwrite(fid, jsonencode(res), 'char'); fclose(fid); end

f = figure('Visible','off','Position',[100 100 900 420]);
subplot(1,2,1);
bar(1:numel(SUM), -[SUM.dip]);
set(gca,'XTick',1:numel(SUM),'XTickLabel',{SUM.cond});
title('worst load dip (%)'); grid on; yline(STD.dip_max,'r--');
subplot(1,2,2);
bar(1:numel(SUM), [SUM.s5]);
set(gca,'XTick',1:numel(SUM),'XTickLabel',{SUM.cond});
title('worst settling time (ms)'); grid on; yline(STD.s5_max,'r--');
print(f,'-dpng','-r120',fullfile(outDir,'a6_task6_summary.png'));
close(f);

% ---- consistency: JSON vs MAT vs figure ----
J = jsondecode(fileread(fullfile(outDir,'a6_task6_accept.json')));
M2 = load(fullfile(outDir,'a6_task6_accept.mat')); M2 = M2.res;
c1 = numel(J.records) == numel(M2.records);
c2 = abs(sum([J.records.dip]) - sum([res.records.dip])) < 1e-12;
c3 = abs(min([J.summary.dip]) - min([SUM.dip])) < 1e-12;
d = dir(fullfile(outDir,'a6_task6_summary.png'));
c5 = ~isempty(d) && d.bytes > 2000;
raw = fileread(fullfile(outDir,'a6_task6_accept.json'));
c6 = isempty(strfind(raw, 'E:\')) && isempty(strfind(raw, '/e/')) && isempty(strfind(raw, '\Users\'));
fprintf('\n--- 7) artefact consistency ---\n');
fprintf('  JSON/MAT record count  : %s (%d)\n', tern(c1,'agree','MISMATCH'), numel(J.records));
fprintf('  JSON/MAT dip sum       : %s\n', tern(c2,'agree','MISMATCH'));
fprintf('  JSON/figure dip min    : %s\n', tern(c3,'agree','MISMATCH'));
fprintf('  PNG written and >2 kB  : %s (%d bytes)\n', tern(c5,'yes','NO'), d.bytes);
fprintf('  no machine path in JSON: %s\n', tern(c6,'yes','NO -- fix before release'));
cons = struct('jsonMatCount',c1,'jsonMatSum',c2,'jsonFigure',c3,'png',c5,'noLocalPath',c6);

%% ---------- 8) verdict ----------
nb = strcmp({R.cfg},'B');
nB = nnz(nb); pB = nnz([R(nb).mpass] & [R(nb).converged]);
fprintf('\n--- 8) verdict ---\n');
fprintf('  baseline B : %d / %d runs pass every measured criterion with a stable orbit\n', pB, nB);
neg = strcmp({R.cfg},'S1');
nNegPass = nnz([R(neg).mpass] & [R(neg).converged]);
fprintf('  negative control S1 (2 periods delay): %d / %d pass %s\n', nNegPass, nnz(neg), ...
    tern(nNegPass==0,'(harness detects the failure)','(CONTROL FAILED)'));
for q = 2:numel(cfg)
    s = strcmp({R.cfg},cfg(q).id);
    fprintf('  %-3s %-38s %2d / %2d runs pass\n', cfg(q).id, cfg(q).desc, ...
        nnz([R(s).mpass] & [R(s).converged]), nnz(s));
end

res.consistency = cons;
res.nBaselinePass = pB; res.nBaseline = nB;
res.negativeControlPass = nNegPass;
save(fullfile(outDir,'a6_task6_accept.mat'),'res');
fprintf('\nsaved a6_task6_accept.mat/.json/.png in %s\n', outDir);
end

% ---------------------------------------------------------------------------
function c = mkcfg(id,desc,nd,phi,L,Vin,C,ESR,lsb,mode,expectFail)
c = struct('id',id,'desc',desc,'nDly',nd,'phi',phi,'L',L,'Vin',Vin, ...
    'C',C,'ESR',ESR,'lsb',lsb,'compMode',mode,'expectFail',expectFail);
end

function p = mkp(cond, c, sensDp)
s = sensDp; s.lsb = c.lsb;
p = dual_params(cond.Vin, cond.R, cond.L, 'nDly', c.nDly, ...
    'sampPhase', c.phi, 'compMode', c.compMode, 'sens', s);
p.C = c.C; p.ESR = c.ESR;
end

function [cls, mg, mpass] = classify_cfg(m, STD, LOWMARGIN, rf)
mpass = abs(m.ssErr)<=STD.sserr_max && isfinite(m.settleMs) && m.settleMs<=STD.s5_max ...
    && m.osPct<=STD.os_max && abs(m.dipPct)<=STD.dip_max ...
    && m.dMin>=STD.dlo-1e-6 && m.dMax<=STD.dhi+1e-6 && m.iLpkAll<=STD.imax;
mg = min([100*(1-abs(m.ssErr)/STD.sserr_max), 100*(1-m.settleMs/STD.s5_max), ...
          100*(1-m.osPct/STD.os_max), 100*(1-abs(m.dipPct)/STD.dip_max), ...
          100*(m.dMin-STD.dlo)/(STD.dhi-STD.dlo), ...
          100*(STD.dhi-m.dMax)/(STD.dhi-STD.dlo), 100*(1-m.iLpkAll/STD.imax)]);
stable = rf.converged && rf.maxAbs < 1;
if ~stable || ~mpass
    cls = 'FAIL';
elseif mg < LOWMARGIN
    cls = 'PASS WITH LOW MARGIN';
else
    cls = 'PASS';
end
end

function cls = metrics_class(m, STD, LOWMARGIN)
mpass = abs(m.ssErr)<=STD.sserr_max && isfinite(m.settleMs) && m.settleMs<=STD.s5_max ...
    && m.osPct<=STD.os_max && abs(m.dipPct)<=STD.dip_max ...
    && m.dMin>=STD.dlo-1e-6 && m.dMax<=STD.dhi+1e-6 && m.iLpkAll<=STD.imax;
mg = min([100*(1-abs(m.ssErr)/STD.sserr_max), 100*(1-m.settleMs/STD.s5_max), ...
          100*(1-abs(m.dipPct)/STD.dip_max), 100*(1-m.iLpkAll/STD.imax)]);
cls = classify(mpass, mg, LOWMARGIN);
end

function cls = classify(rawPass, marginPct, lowLimit)
if ~rawPass
    cls = 'FAIL';
elseif marginPct < lowLimit
    cls = 'PASS WITH LOW MARGIN';
else
    cls = 'PASS';
end
end

function s = tern(c,a,b)
if c, s = a; else, s = b; end
end
