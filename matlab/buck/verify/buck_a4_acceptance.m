%% Phase 3A.4 / Task 5: engineering acceptance of the dual loop vs BASE and OPT
%
% 7 conditions x 4 controllers x 3 repeats, ORIGINAL S1-S9 thresholds, real
% Simulink execution on the same plant for every controller.
%
% Controllers
%   BASE    pure integral, no notch            (historical, unchanged)
%   OPT     notch + PI, 3A.1 final tuning      (historical, unchanged)
%   DUALA   cascaded dual loop, ff = 0         (this phase)
%   DUALB   cascaded dual loop + iLoad FF      (this phase)
%
% Fairness / gating rules, stated BEFORE the numbers
%   1. S1-S8 thresholds are the original text. Nothing is relaxed.
%   2. S2/S3 are gated on the CONTINUOUS loop gain for all four controllers,
%      exactly as every previous phase did (no goalpost move).
%   3. The NEW candidates additionally have to satisfy S2/S3 on the DISCRETE
%      loop with one sampling period of computation delay. This requirement is
%      applied ONLY to the new architecture -- it can only make the new
%      candidate harder to pass, never easier.
%   4. BASE and OPT keep Dmax = 0.9 (their historical actuator); the dual loop
%      is built with Dmax = 0.85, i.e. the S8 ceiling itself, so the new
%      candidate has LESS duty authority. Also conservative.
%   5. S8 is evaluated on the post-step duty window only, as in Phase 3A.2.
%   6. A criterion that cannot be evaluated is UNDETERMINED, never PASS.
%
% Output: a4_acceptance.json / .mat, a4_acceptance.png

clear; close all;
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, '..'));
outDir = getenv('BUCK_OUT');
if isempty(outDir), outDir = fullfile(here,'..','..','artifacts','validation','buck'); end
outDir = strrep(outDir,'/',filesep);
if ~exist(outDir,'dir'), mkdir(outDir); end

fprintf('================ 3A.4 acceptance: 7 cond x 4 ctrl x 3 repeats ================\n');

%% ---------- standards (verbatim from the brief, NOT modified) ----------
STD = struct('PM_min',50, 'GM_min',6, 'sserr_max',0.1, 'recover_max',1.0, ...
             'startup_os_max',5, 'dip_max',12, 'duty_lo',0.05, 'duty_hi',0.85, ...
             'repro',1e-9);
fprintf('S2 PM>=%g deg | S3 GM>=%g dB | S4 |ssErr|<=%g%% | S5 settle<=%g ms\n', ...
    STD.PM_min, STD.GM_min, STD.sserr_max, STD.recover_max);
fprintf('S6 startupOS<=%g%% | S7 |dip|<=%g%% | S8 duty in [%g,%g] | S9 repro<%g\n\n', ...
    STD.startup_os_max, STD.dip_max, STD.duty_lo, STD.duty_hi, STD.repro);

%% ---------- 7 conditions ----------
conds = [ ...
    struct('id','C1','desc','nominal 48V 6ohm 150uH','Vin',48,'R',6,'L',150e-6,'C',220e-6)
    struct('id','C2','desc','Vin -12.5% (42V)','Vin',42,'R',6,'L',150e-6,'C',220e-6)
    struct('id','C3','desc','Vin +12.5% (54V)','Vin',54,'R',6,'L',150e-6,'C',220e-6)
    struct('id','C4','desc','light load 12ohm','Vin',48,'R',12,'L',150e-6,'C',220e-6)
    struct('id','C5','desc','heavy load 3ohm','Vin',48,'R',3,'L',150e-6,'C',220e-6)
    struct('id','C6','desc','54V + 3ohm (worst)','Vin',54,'R',3,'L',150e-6,'C',220e-6)
    struct('id','C7','desc','L +30% (195uH)','Vin',48,'R',6,'L',195e-6,'C',220e-6)
    ];

%% ---------- controllers ----------
d3 = load(fullfile(outDir,'task3_best_controller.mat'));
b = d3.best; fnNom = d3.fn;

% ---- dual-loop parameters (from the Task 3+4 search; see a4_task34_design.mat) ----
if exist(fullfile(outDir,'a4_dualsel.mat'),'file')
    tmp = load(fullfile(outDir,'a4_dualsel.mat'));
    S = tmp.S;                      % load() wraps the saved variable in a struct
else
    error(['a4_dualsel.mat not found -- run verify/buck_a4_task34_design.m ' ...
           'and record the selected points first']);
end
fprintf('DUAL-A: Kci=%.3f Kp_e=%.4f Ki_e=%.1f (ff=%d)\n', ...
    S.A.Kci, S.A.Kpe, S.A.Kie, 0);
fprintf('DUAL-B: Kci=%.3f Kp_e=%.4f Ki_e=%.1f (ff=%d)\n\n', ...
    S.B.Kci, S.B.Kpe, S.B.Kie, 1);

ctrls = [ ...
    struct('id','BASE', 'kind','single', ...
        'cfg',struct('Kp',0,'Ki',7.902901,'notchEnable',false,'Dmax',0.9))
    struct('id','OPT',  'kind','single', ...
        'cfg',struct('Kp',b.Kp,'Ki',b.Ki,'notchEnable',true, ...
                     'notchWn',fnNom,'notchZn',b.zn,'notchZd',b.zd,'Dmax',0.9))
    struct('id','DUALA','kind','dual', ...
        'cfg',struct('Kci',S.A.Kci,'Kpe',S.A.Kpe,'Kie',S.A.Kie,'ff',0,'Dmax',0.85, ...
                     'Imin',0,'Imax',12,'Tt',3e-4,'Eclamp',1.5,'Tss',5e-3))
    struct('id','DUALB','kind','dual', ...
        'cfg',struct('Kci',S.B.Kci,'Kpe',S.B.Kpe,'Kie',S.B.Kie,'ff',1,'Dmax',0.85, ...
                     'Imin',0,'Imax',12,'Tt',3e-4,'Eclamp',1.5,'Tss',5e-3))
    ];

tStep = 0.06; ratio = 2; tStop = 0.12; nRep = 3;

recs = struct('cond',{},'ctrl',{},'Vin',{},'R',{},'L',{}, ...
    'Pm',{},'Gm',{},'fc',{},'maxRe',{}, ...
    'PmD',{},'GmD',{},'maxAbsZ',{}, ...
    'dipPct',{},'recoverMs',{},'settleMs',{},'nExits',{},'converged',{}, ...
    'tailInBandMs',{},'startupOs',{},'ssErrPct',{},'dutyMin',{},'dutyMax',{}, ...
    'iLmax',{},'iLrefMax',{},'devSet',{},'devVc',{}, ...
    'S1',{},'S2',{},'S2d',{},'S3',{},'S4',{},'S5',{},'S6',{},'S7',{},'S8',{}, ...
    'S9',{},'all',{},'t',{},'vC',{});

fprintf('%-5s %-6s %8s %8s %9s %9s %9s %9s %8s %8s %6s\n', ...
    'cond','ctrl','PM','GM','PM_disc','GM_disc','dip%','S5ms','dutyMin','dutyMax','verdict');
for ic = 1:numel(conds)
    c = conds(ic);
    for it = 1:numel(ctrls)
        k = ctrls(it);

        % ---------------- linear analysis ----------------
        if strcmp(k.kind,'single')
            Gvd = tf(ss([0,-1/c.L; 1/c.C,-1/(c.R*c.C)], [c.Vin/c.L;0], [0 1], 0));
            if k.cfg.notchEnable
                s = tf('s');
                nt = (s^2+2*k.cfg.notchZn*k.cfg.notchWn*s+k.cfg.notchWn^2)/ ...
                     (s^2+2*k.cfg.notchZd*k.cfg.notchWn*s+k.cfg.notchWn^2);
                Cl = pid(k.cfg.Kp,k.cfg.Ki,0,0)*nt;
            else
                Cl = pid(k.cfg.Kp,k.cfg.Ki,0,0);
            end
            Lc = minreal(Cl*Gvd);
            GvObj = Gvd; CsObj = Cl;
        else
            q = struct('L',c.L,'C',220e-6);
            GvObj = tf(dual_loop_gain(q, c.R, k.cfg.Kci, k.cfg.Kpe, k.cfg.Kie, k.cfg.ff, 'plant'));
            CsObj = tf([k.cfg.Kpe k.cfg.Kie],[1 0]);
            Lc = minreal(CsObj*GvObj);
        end
        [Gm_dB, Pm_worst, ~, Wcp] = local_margins(Lc);
        fc = Wcp/(2*pi);
        maxRe = max(real(pole(feedback(Lc,1))));
        % discrete: ZOH + one period of computation delay
        Ts = 1/50e3;
        Ld = c2d(CsObj,Ts,'zoh')*tf(1,[1 0],Ts)*c2d(GvObj,Ts,'zoh');
        [GmD, PmD] = local_margins(Ld);
        maxAbsZ = max(abs(pole(feedback(Ld,1))));

        % ---------------- time domain, 3 repeats ----------------
        setA = nan(1,nRep); dipA = nan(1,nRep); recA = nan(1,nRep);
        exA = nan(1,nRep); osA = nan(1,nRep); ssA = nan(1,nRep);
        dminA = nan(1,nRep); dmaxA = nan(1,nRep); ilmA = nan(1,nRep);
        ilrA = nan(1,nRep); convA = false(1,nRep); tailA = nan(1,nRep);
        vCs = cell(1,nRep);
        for ir = 1:nRep
            if strcmp(k.kind,'single')
                cfg = struct('Kp',k.cfg.Kp,'Ki',k.cfg.Ki,'R',c.R,'Vin',c.Vin, ...
                    'L',c.L,'C',220e-6,'Vref',12, 'Dmin',0.0,'Dmax',k.cfg.Dmax, ...
                    'loadStepTime',tStep,'loadStepRatio',ratio,'tStop',tStop, ...
                    'maxStep',1e-6,'saveModel',false, ...
                    'modelName',sprintf('a4_%s_%s_%d',c.id,k.id,ir));
                if k.cfg.notchEnable
                    cfg.notchEnable = true; cfg.notchWn = k.cfg.notchWn;
                    cfg.notchZn = k.cfg.notchZn; cfg.notchZd = k.cfg.notchZd;
                end
                rr = build_buck_closed_loop_generic(outDir, cfg);
                iLrefTrace = nan(size(rr.t));
            else
                cfg = struct('Vin',c.Vin,'L',c.L,'C',220e-6,'R',c.R,'Vref',12, ...
                    'Kci',k.cfg.Kci,'Kpe',k.cfg.Kpe,'Kie',k.cfg.Kie,'ff',k.cfg.ff, ...
                    'Dmin',0.05,'Dmax',k.cfg.Dmax,'Tt',k.cfg.Tt, ...
                    'Imin',k.cfg.Imin,'Imax',k.cfg.Imax, ...
                    'Eclamp',k.cfg.Eclamp,'Tss',k.cfg.Tss, ...
                    'loadStepTime',tStep,'loadStepRatio',ratio,'tStop',tStop, ...
                    'maxStep',1e-6,'saveModel',false, ...
                    'modelName',sprintf('a4_%s_%s_%d',c.id,k.id,ir));
                rr = build_buck_dual_loop(outDir, cfg);
                iLrefTrace = rr.iLref;
            end
            t = rr.t; vC = rr.vC; duty = rr.duty;
            post = t >= tStep;
            sm = step_metrics(t, vC, 12, tStep, 1);
            dipA(ir) = sm.dipPct; recA(ir) = sm.firstEntryMs; setA(ir) = sm.settleMs;
            exA(ir) = sm.nExits; convA(ir) = sm.converged; tailA(ir) = sm.tailInBandMs;
            osA(ir) = (max(vC(~post))-12)/12*100;
            ssA(ir) = (mean(vC(t > tStop-0.01))-12)/12*100;
            dminA(ir) = min(duty(post)); dmaxA(ir) = max(duty(post));
            ilmA(ir) = max(rr.iL(post));
            ilrA(ir) = max(iLrefTrace(post));
            vCs{ir} = vC;
            if ir == 1, t1 = t; vC1 = vC; sm1 = sm; end
        end
        devSet = max(abs(setA - setA(1)));
        devVc = Inf;
        if all(cellfun(@numel,vCs) == numel(vCs{1})) && numel(vCs{1}) > 1
            devVc = 0;
            for ir = 2:nRep, devVc = max(devVc, max(abs(vCs{ir}-vCs{1}))); end
        end

        % ---------------- verdicts ----------------
        v = struct();
        v.S1 = maxRe < 0;
        v.S2 = Pm_worst >= STD.PM_min;
        v.S2d = PmD >= STD.PM_min;          % extra gate for the NEW controllers
        v.S3 = Gm_dB >= STD.GM_min;
        v.S4 = abs(ssA(1)) <= STD.sserr_max;
        v.S5 = isfinite(setA(1)) && setA(1) <= STD.recover_max;
        v.S6 = osA(1) <= STD.startup_os_max;
        v.S7 = abs(dipA(1)) <= STD.dip_max;
        v.S8 = dminA(1) >= STD.duty_lo && dmaxA(1) <= STD.duty_hi;
        v.S9 = (devSet < STD.repro) && (devVc < STD.repro);
        % the discrete-PM gate applies to the new architecture only (see header)
        if strcmp(k.kind,'dual')
            v.all = v.S1 && v.S2 && v.S2d && v.S3 && v.S4 && v.S5 && v.S6 && ...
                    v.S7 && v.S8 && v.S9;
        else
            v.all = v.S1 && v.S2 && v.S3 && v.S4 && v.S5 && v.S6 && v.S7 && v.S8 && v.S9;
        end

        fprintf('%-5s %-6s %8.2f %8s %9.2f %9s %9.3f %9.3f %8.3f %8.3f %6s\n', ...
            c.id, k.id, Pm_worst, gms(Gm_dB), PmD, gms(GmD), dipA(1), setA(1), ...
            dminA(1), dmaxA(1), merge3(v.all,'PASS','FAIL'));
        fprintf('        S1=%d S2=%d S2d=%d S3=%d S4=%d(%.4f%%) S5=%d(%.3f) S6=%d(%.2f%%) S7=%d S8=%d S9=%d\n', ...
            v.S1,v.S2,v.S2d,v.S3,v.S4,ssA(1),v.S5,setA(1),v.S6,osA(1),v.S7,v.S8,v.S9);

        recs(end+1) = struct('cond',c.id,'ctrl',k.id,'Vin',c.Vin,'R',c.R,'L',c.L, ...
            'Pm',Pm_worst,'Gm',Gm_dB,'fc',fc,'maxRe',maxRe, ...
            'PmD',PmD,'GmD',GmD,'maxAbsZ',maxAbsZ, ...
            'dipPct',dipA(1),'recoverMs',recA(1),'settleMs',setA(1), ...
            'nExits',exA(1),'converged',convA(1),'tailInBandMs',tailA(1), ...
            'startupOs',osA(1),'ssErrPct',ssA(1),'dutyMin',dminA(1),'dutyMax',dmaxA(1), ...
            'iLmax',ilmA(1),'iLrefMax',ilrA(1),'devSet',devSet,'devVc',devVc, ...
            'S1',v.S1,'S2',v.S2,'S2d',v.S2d,'S3',v.S3,'S4',v.S4,'S5',v.S5, ...
            'S6',v.S6,'S7',v.S7,'S8',v.S8,'S9',v.S9,'all',v.all, ...
            't',t1,'vC',vC1);
    end
end

%% ---------- summary ----------
fprintf('\n================ summary ================\n');
ids = {ctrls.id};
for q = 1:numel(ids)
    sel = strcmp({recs.ctrl}, ids{q});
    fprintf('  %-6s : %d/%d PASS\n', ids{q}, sum([recs(sel).all]), sum(sel));
end
fprintf('\n  per-criterion pass counts\n  %-8s','ctrl');
for q=1:numel(ids), fprintf('%-8s',ids{q}); end
fprintf('\n');
crit = {'S1','S2','S2d','S3','S4','S5','S6','S7','S8','S9'};
for ci = 1:numel(crit)
    fprintf('  %-8s', crit{ci});
    for q = 1:numel(ids)
        sel = strcmp({recs.ctrl}, ids{q});
        fprintf('%-8d', sum([recs(sel).(crit{ci})]));
    end
    fprintf('\n');
end

recSave = rmfield(recs, {'t','vC'});
save(fullfile(outDir,'a4_acceptance.mat'),'recs','STD','conds','ctrls','-v7.3');
fid = fopen(fullfile(outDir,'a4_acceptance.json'),'w');
fwrite(fid, jsonencode(struct('results',recSave,'standards',STD, ...
    'note','S2/S3 gated on the continuous loop for all controllers; the dual loop must also pass S2d (discrete, 1 Ts delay)')), 'char');
fclose(fid);
fprintf('\nsaved a4_acceptance.mat / .json\n');

% ==================================================================
function s = gms(x)
if isinf(x), s = 'Inf'; else, s = sprintf('%.2f', x); end
end

function s = merge3(c,a,bb)
if c, s = a; else, s = bb; end
end
