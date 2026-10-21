function res = boost_b2_task1_designs(outDir)
%BOOST_B2_TASK1_DESIGNS  Phase 3B.2 Task 1: Design A (8 A) vs Design B (10 A).
%
% The two designs are NOT "before and after a bug fix". They are two different
% products: B needs a larger current rating everywhere. This script therefore
%   (a) computes the physical requirement and the controller's command
%       requirement at every operating point,
%   (b) states which one binds, and
%   (c) grades both designs on the same seven conditions,
% and it never lets a pass of B be reported as a pass of A.
%
% Conditions (all at Vref = 48 V, fs = 50 kHz):
%   C1 24 V 100 %   C2 20 V 100 %   C3 28 V 100 %   C4 24 V 50 %
%   C5 28 V  50 %   C6 20 V 150 %   C7 24 V 150 %
% Every condition gets the SAME absolute load step (+1 A of output current), so
% the light-load cases are not made trivially easy and the heavy cases are not
% made impossible by a relative step.

if nargin < 1 || isempty(outDir), outDir = getenv('BOOST_OUT'); end
if isempty(outDir), outDir = fullfile(pwd,'artifacts','validation','boost_b2'); end
outDir = strrep(outDir,'/',filesep);
here = fileparts(mfilename('fullpath'));
addpath(fileparts(here));
addpath(fullfile(fileparts(fileparts(here)),'buck'));   % step_metrics
if ~exist(outDir,'dir'), mkdir(outDir); end

p = boost_params();
[dA, dB, meta] = boost_designs(p, 650);
SEEDS = [11 23 37];

% C1-C5 are the REQUIREMENT set (all at or below the 96 W rating, each with a
% +1 A output-current step). C6/C7 are STRESS points at 150 % of the rating: the
% converter was never specified to hold 144 W, so they bound the capability and
% are reported separately instead of being folded into the pass count.
% REQUIRED conditions carry the +1 A output step. STRESS conditions do NOT: they
% are pure steady-state capability tests at 150 % of the rating, run long enough
% (150 ms) for the slowest operating point to settle. Mixing a step into a 150 %
% point would test 200 % and confound two different questions -- the first version
% of this matrix did exactly that and reported "B fails 150 %" when B actually
% holds 48.000 V there with the command pinned at its clamp.
conds = [ ...
    struct('id','C1','Vin',24,'R',24,'name','24 V 100 %','kind','required','step',1,'tEnd',0.06)
    struct('id','C2','Vin',20,'R',24,'name','20 V 100 %','kind','required','step',1,'tEnd',0.06)
    struct('id','C3','Vin',28,'R',24,'name','28 V 100 %','kind','required','step',1,'tEnd',0.06)
    struct('id','C4','Vin',24,'R',48,'name','24 V  50 %','kind','required','step',1,'tEnd',0.06)
    struct('id','C5','Vin',28,'R',48,'name','28 V  50 %','kind','required','step',1,'tEnd',0.06)
    struct('id','C6','Vin',20,'R',16,'name','20 V 150 %','kind','stress','step',0,'tEnd',0.15)
    struct('id','C7','Vin',24,'R',16,'name','24 V 150 %','kind','stress','step',0,'tEnd',0.15) ];

fprintf('========== Phase 3B.2 Task 1: Design A (8 A) vs Design B (10 A) ==========\n');
fprintf('shared gains: Kpe %.4f  Kie %.1f  Kci %.4f  D0 %.4f  Td %.1f periods\n', ...
    meta.gains.Kpe, meta.gains.Kie, meta.gains.Kci, meta.gains.D0, meta.gains.TdPeriods);
fprintf('design A: Imax %g A ; design B: Imax %g A ; only that differs\n', dA.Imax, dB.Imax);
fprintf('margins: PM %.1f deg, GM %.1f dB, fc %.0f Hz, crossings down %d / up %d\n\n', ...
    dA.PM, dA.GM, dA.fcActual, dA.nCross, dA.nCrossUp);

%% ---------- 1) static feasibility: who binds? ----------
fprintf('--- 1) static requirement at each operating point (design A clamp = 8 A) ---\n');
fprintf('%-3s %-11s %6s %6s %6s %6s %7s %7s %8s %8s | %s\n', ...
    'id','name','Dreq','iL A','dIL A','iLpk A','droop A','iLrefReq','headroom','dutyHi','binds');
OP = struct('cond',{},'Vin',{},'R',{},'Dreq',{},'iL',{},'dIL',{},'iLpk',{}, ...
    'droop',{},'iLrefReq',{},'headroom',{},'binds',{},'valley',{},'eff',{});
for k = 1:numel(conds)
    cd = conds(k);
    s = boost_op_point(p, dA, cd.Vin, cd.R);
    fprintf('%-3s %-11s %6.4f %6.3f %6.3f %6.3f %7.3f %8.3f %8.3f %8.3f | %s\n', ...
        cd.id, cd.name, s.Dreq, s.iL, s.dIL, s.iLpk, s.droop, s.iLrefReq, ...
        s.headroom, s.dutyMarginHi, s.limitedBy);
    OP(end+1) = struct('cond',cd.id,'Vin',cd.Vin,'R',cd.R,'Dreq',s.Dreq,'iL',s.iL, ...
        'dIL',s.dIL,'iLpk',s.iLpk,'droop',s.droop,'iLrefReq',s.iLrefReq, ...
        'headroom',s.headroom,'binds',s.limitedBy,'valley',s.iLvalley, ...
        'eff',s.eff); %#ok<AGROW>
end

%% ---------- 2) the decisive case: C6 ----------
fprintf('\n--- 2) C6 (20 V, 150 %%): architecture vs physical limit ---\n');
s6A = boost_op_point(p, dA, 20, 16);
s6B = boost_op_point(p, dB, 20, 16);
fprintf('  physical : iL = %.3f A, peak = %.3f A (clamp 8 A alone would be enough)\n', ...
    s6A.iL, s6A.iLpk);
fprintf('  command  : droop %.3f A -> iLref must reach %.3f A\n', s6A.droop, s6A.iLrefReq);
fprintf('  design A : Imax 8 A  -> headroom %+.3f A (%+.1f %%) -> %s\n', ...
    s6A.headroom, s6A.headroomPct, s6A.limitedBy);
fprintf('  design B : Imax 10 A -> headroom %+.3f A (%+.1f %%) -> %s\n', ...
    s6B.headroom, s6B.headroomPct, s6B.limitedBy);
fprintf('  => A fails because the PROPORTIONAL INNER LOOP adds %.2f A to the command,\n', s6A.droop);
fprintf('     not because 7.5 A cannot be delivered by an 8 A stage. B "works" with only\n');
fprintf('     %.0f %% command headroom, i.e. it is a margin problem, not a solved one.\n', ...
    100*s6B.headroom/s6B.iLrefReq);

%% ---------- 3) measured matrix, both designs ----------
fprintf('\n--- 3) measured: same seven conditions, +1 A output step, 3 seeds ---\n');
R = struct('design',{},'cond',{},'seed',{},'vOut',{},'ssErr',{},'dip',{}, ...
    's5',{},'iLavg',{},'iLref',{},'cmdErr',{},'iLpkSS',{},'iLpkTr',{},'dcm',{}, ...
    'dMin',{},'dMax',{},'valid',{},'verdict',{});
% the same sensor chain the acceptance uses; without it the two scripts report
% different recovery times for the same configuration (1.45 vs 2.25 ms at C2)
sens = struct('enable',true,'gain',1.02,'offset',0.05,'sigma',0.02,'lsb',0.01, ...
              'nd',1,'iMaxPhys',12);
designs = {dA, dB};
for id = 1:2
    c = designs{id}; c.sens = sens;
    if id == 1, dn = 'A'; else, dn = 'B'; end
    fprintf('\n  design %s (Imax %.0f A)\n', dn, c.Imax);
    fprintf('  %-3s %-11s %5s %9s %9s %8s %8s %8s %8s %8s | %s\n', ...
        'id','name','seed','Vout V','SSerr%','dip %','S5 ms','iLavg','cmdErr','dcm%','verdict');
    for k = 1:numel(conds)
        cd = conds(k);
        for is = 1:numel(SEEDS)
            pq = p; pq.Vin = cd.Vin; pq.R = cd.R; pq.Pout = pq.Vref^2/cd.R;
            if cd.step, ratio = 1 + cd.R/p.Vref; else, ratio = 1; end
            o = struct('ratio',ratio,'tStep',0.02,'tEnd',cd.tEnd, ...
                       'nSub',200,'nDly',1,'noise',true,'seed',SEEDS(is));
            rr = boost_sw_sim(pq, c, o);
            m  = boost_run_metrics(rr, p, o);
            % Graded condition: regulation, dip, recovery, CCM in both steady
            % windows, and a peak inside the design's own clamp. A transient DCM
            % excursion is reported but does not by itself void the run.
            if cd.step
                ok = abs(m.ssErr) <= 0.5 && abs(m.dip) <= 5 && ...
                     (m.s5 <= 2.0 || m.s5 == 0) && m.ccmValid && m.iLpkTr <= c.Imax;
            else
                ok = abs(m.ssErr) <= 0.5 && m.ccmValid && m.iLpkTr <= c.Imax;
            end
            if ~m.ccmValid
                vd = 'UNDETERMINED';
            elseif ok
                vd = 'PASS';
            else
                vd = 'FAIL';
            end
            fprintf('  %-3s %-11s %5d %9.4f %9.4f %8.3f %8.4f %8.3f %8.3f %8.2f | %s\n', ...
                cd.id, cd.name, SEEDS(is), m.vOut, m.ssErr, m.dip, m.s5, ...
                m.iLavgPre, m.cmdErr, m.dcmPre + m.dcmTr + m.dcmPost, vd);
            R(end+1) = struct('design',dn,'cond',cd.id,'seed',SEEDS(is), ...
                'vOut',m.vOut,'ssErr',m.ssErr,'dip',m.dip,'s5',m.s5, ...
                'iLavg',m.iLavgPre,'iLref',m.iLrefPre,'cmdErr',m.cmdErr, ...
                'iLpkSS',m.iLpkSS,'iLpkTr',m.iLpkTr,'dcm',m.dcmPre+m.dcmTr+m.dcmPost, ...
                'dMin',m.dMin,'dMax',m.dMax,'valid',m.ccmValid,'verdict',vd); %#ok<AGROW>
        end
    end
end

reqIds = {conds(strcmp({conds.kind},'required')).id};
stressIds = {conds(strcmp({conds.kind},'stress')).id};
nA = 0; nRunA = 0; nB = 0; nRunB = 0;
for q = 1:numel(R)
    if ~any(strcmp(R(q).cond, reqIds)), continue; end
    if R(q).design == 'A', nRunA = nRunA + 1; nA = nA + strcmp(R(q).verdict,'PASS');
    else, nRunB = nRunB + 1; nB = nB + strcmp(R(q).verdict,'PASS'); end
end
fprintf('\n  REQUIREMENT set (C1-C5, 3 seeds each):\n');
fprintf('    design A: %d / %d runs PASS\n', nA, nRunA);
fprintf('    design B: %d / %d runs PASS\n', nB, nRunB);
fprintf('  per condition (all seeds must pass):\n');
for k = 1:numel(conds)
    for dn2 = ['A' 'B']
        sel = R(strcmp({R.design},dn2) & strcmp({R.cond},conds(k).id));
        fprintf('    %-3s %-9s design %s : %s\n', conds(k).id, conds(k).name, dn2, ...
            tern(all(strcmp({sel.verdict},'PASS')),'PASS','FAIL'));
    end
end
fprintf('\n  STRESS set (150 %%, outside the 96 W rating):\n');
for k = 1:numel(stressIds)
    for dn2 = ['A' 'B']
        sel = R(strcmp({R.design},dn2) & strcmp({R.cond},stressIds{k}));
        fprintf('    %-3s design %s : vOut %6.2f V (%.1f %%), dip %.1f %% -> %s\n', ...
            stressIds{k}, dn2, mean([sel.vOut]), mean([sel.ssErr]), mean([sel.dip]), ...
            tern(all(strcmp({sel.verdict},'PASS')),'PASS','FAIL'));
    end
end

%% ---------- 4) design B: what is NOT verified ----------
fprintf('\n--- 4) design B: device and protection items ---\n');
fprintf('  %-28s %-12s %s\n','item','status','why');
SAFE = struct('item',{},'status',{},'why',{});
adds = @(i,s,w) struct('item',i,'status',s,'why',w);
SAFE = [ ...
 adds('inductor peak current','NOT VERIFIED','no saturation curve / part number; peak reaches 8.03 A at C6'); ...
 adds('inductor saturation margin','NOT VERIFIED','needs Isat and its temperature derating'); ...
 adds('MOSFET rating','NOT VERIFIED','no device; RonSW 20 mOhm is a placeholder'); ...
 adds('diode average/peak current','NOT VERIFIED','no part; Vf 0.5 V and RonD 20 mOhm are placeholders'); ...
 adds('current-sense range','NOT VERIFIED','12 A range assumed; offset/gain are assumptions'); ...
 adds('thermal / temperature rise','NOT VERIFIED','no loss-to-thermal model, no Rth, no airflow spec'); ...
 adds('OCP trip behaviour','FAIL','only a COMMAND clamp is modelled; no instantaneous trip exists, so a real over-current is not interrupted'); ...
 adds('10 A clamp feasibility','PASS (simulation)','C6 needs iLref 9.84 A, so 10 A has 0.16 A headroom in the model only') ];
for k = 1:numel(SAFE)
    fprintf('  %-28s %-12s %s\n', SAFE(k).item, SAFE(k).status, SAFE(k).why);
end

res = struct('level','3B.2-Task1','gains',meta.gains, ...
    'designA',struct('Imax',dA.Imax,'PM',dA.PM,'GM',dA.GM,'fc',dA.fcActual), ...
    'designB',struct('Imax',dB.Imax,'PM',dB.PM,'GM',dB.GM,'fc',dB.fcActual), ...
    'conditions',conds,'static',OP,'c6A',s6A,'c6B',s6B,'records',R, ...
    'summary',struct('nPassA',nA,'nRunA',nRunA,'nPassB',nB,'nRunB',nRunB, ...
                     'requirementSet',{reqIds},'stressSet',stressIds), ...
    'safety',SAFE, ...
    'note',['Design B is a hardware change (Imax 8 -> 10 A). Its passes are not ' ...
            'passes of design A, and all device-level items remain NOT VERIFIED.']);
save(fullfile(outDir,'b2_task1_designs.mat'),'res');
fid = fopen(fullfile(outDir,'b2_task1_designs.json'),'w');
if fid >= 0, fwrite(fid, jsonencode(res), 'char'); fclose(fid); end
fprintf('\nsaved b2_task1_designs.json/.mat\n');
end

function s = tern(c,a,b)
if c, s = a; else, s = b; end
end
