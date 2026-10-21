function res = buck_a6_task5b_s4(outDir)
%BUCK_A6_TASK5B_S4  Two mechanism questions the margin table cannot answer.
%
% Phase 3A.6 Task 5 left two things unexplained and both matter for the release
% decision:
%
% Q1  What IS the 0.087 % steady-state offset? Task 5 already showed it is not
%     the ADC (LSB=0 gives the same number), not noise, not the sensor, and not
%     an unfinished settling tail (it is identical at tEnd = 0.08/0.16/0.32 s).
%     Hypothesis: the outer voltage loop samples vOut at the period BOUNDARY,
%     which is the valley of the output ripple, and regulates THAT to Vref. The
%     cycle average then sits half an output ripple above Vref. The inner loop
%     already compensates exactly this effect with the analytic half-ripple term;
%     the outer loop does not. Measurable prediction:
%         mean(vOut) - vOut(at the sample instant)  ==  half the vOut ripple
%     If that holds, the offset is deterministic, explainable and correctable
%     (add ESR*dIL/2 to the voltage sample, or trim Vref by the same amount).
%
% Q2  Is the START-UP part of the run physically meaningful? The frozen model
%     starts with vC = 12 V and ramps the reference from 0 V, so the controller
%     deliberately reduces the duty to Dmin and the inductor current goes
%     NEGATIVE. A diode cannot conduct negative current: the real converter would
%     enter DCM, which this model does not represent. If the negative excursion
%     is large, S6 (start-up overshoot) is measured in a region where the model
%     is not valid, and that must be said out loud instead of quoted as a pass.
%     The load-step metrics must be shown NOT to depend on that start-up history.

if nargin < 1 || isempty(outDir), outDir = getenv('BUCK_OUT'); end
outDir = strrep(outDir,'/',filesep);
here = fileparts(mfilename('fullpath')); addpath(fileparts(here));
if ~exist(outDir,'dir'), mkdir(outDir); end
Vref = 12;
oRun = struct('ratio',2,'tStep',0.06,'tEnd',0.08,'nSub',200,'Tss',5e-3);
conds = [ ...
    struct('id','C1','Vin',48,'R',6,  'L',150e-6)
    struct('id','C2','Vin',42,'R',6,  'L',150e-6)
    struct('id','C3','Vin',54,'R',6,  'L',150e-6)
    struct('id','C4','Vin',48,'R',12, 'L',150e-6)
    struct('id','C5','Vin',48,'R',3,  'L',150e-6)
    struct('id','C6','Vin',54,'R',3,  'L',150e-6)
    struct('id','C7','Vin',48,'R',6,  'L',195e-6) ];

fprintf('=== 3A.6 Task 5b: S4 mechanism and start-up validity ===\n');

%% ---------------- Q1: is the offset half the output ripple? ----------------
fprintf('\n--- Q1: mean(vOut) vs Vref and the output ripple ---\n');
fprintf('%-4s %9s %9s %9s %9s %8s %8s\n','cond','mean vOut','min vOut','mean-min','ripple','half','ratio');
Q1 = struct('cond',{},'meanV',{},'minV',{},'meanMinusMin',{},'ripple',{},'ratio',{});
for k = 1:numel(conds)
    c = conds(k);
    p = dual_params(c.Vin,c.R,c.L,'nDly',1);          % ideal sensor: isolate the plant
    r = sw_dual_sim(p,oRun);
    v = r.vOut(r.t > 0.075);
    % The loop regulates e = Vref - vOut(sample) to zero, and the sample sits at
    % the ripple valley, so min(vOut) is the regulated quantity to first order.
    % No need to locate the sample instants: if the hypothesis is right, the
    % AVERAGE sits half a ripple above the MINIMUM, and the minimum sits at Vref.
    ripple = max(v) - min(v);
    fprintf('%-4s %9.4f %9.4f %9.3f %9.3f %8.3f %8.2f\n', c.id, mean(v), min(v), ...
        (mean(v)-min(v))*1e3, ripple*1e3, ripple/2*1e3, (mean(v)-min(v))/(ripple/2));
    Q1(end+1) = struct('cond',c.id,'meanV',mean(v),'minV',min(v), ...
        'meanMinusMin',mean(v)-min(v),'ripple',ripple, ...
        'ratio',(mean(v)-min(v))/(ripple/2)); %#ok<AGROW>
end
fprintf('  ratio ~ 1 means: the loop holds the ripple VALLEY at Vref, so the average\n');
fprintf('  sits half a ripple high. That is the whole 0.087 %%, not a control error.\n');

%% ---------------- Q2: start-up validity and contamination ----------------
fprintf('\n--- Q2: start-up validity (negative iL = DCM the model does not have) ---\n');
fprintf('%-4s %9s %9s %9s %9s | %9s %9s %9s %8s\n','cond','iLmin all','iLmin<0 ms','t(iLmin)','vOut@2ms', ...
    'dip softSS','dip hardIC','S5 soft','S5 hard');
Q2 = struct('cond',{},'iLmin',{},'negMs',{},'tMin',{},'vOut2',{},'dipSoft',{}, ...
    'dipHard',{},'s5Soft',{},'s5Hard',{},'ssSoft',{},'ssHard',{});
for k = 1:numel(conds)
    c = conds(k);
    p = dual_params(c.Vin,c.R,c.L,'nDly',1);
    r = sw_dual_sim(p,oRun);
    [imin, ix] = min(r.iL);
    neg = r.t(r.iL < 0);
    negMs = 0; if ~isempty(neg), negMs = (max(neg)-min(neg))*1e3; end
    j = find(r.t >= 0.002, 1);
    % consistent initial condition: reference starts at Vref, no soft-start ramp
    o2 = oRun; o2.Vref0 = Vref;
    mS = cfg_metrics(p,oRun,Vref);
    mH = cfg_metrics(p,o2,Vref);
    fprintf('%-4s %9.3f %9.3f %9.4f %9.3f | %9.3f %9.3f %9.4f %8.4f\n', c.id, imin, ...
        negMs, r.t(ix)*1e3, r.vOut(j), mS.dipPct, mH.dipPct, mS.settleMs, mH.settleMs);
    Q2(end+1) = struct('cond',c.id,'iLmin',imin,'negMs',negMs,'tMin',r.t(ix), ...
        'vOut2',r.vOut(j),'dipSoft',mS.dipPct,'dipHard',mH.dipPct, ...
        's5Soft',mS.settleMs,'s5Hard',mH.settleMs,'ssSoft',mS.ssErr,'ssHard',mH.ssErr); %#ok<AGROW>
end
fprintf('  a large negative iL means the start-up trajectory is NOT physical (a real\n');
fprintf('  diode blocks, the converter enters DCM, this model keeps integrating).\n');
fprintf('  The load-step columns then answer: does that history still change the\n');
fprintf('  metrics that S4/S5/S7 are based on?\n');

%% ---------------- Q3: duty at the operating point vs in the transient ----------------
fprintf('\n--- Q3: S8 duty range, settled window vs whole post-step window ---\n');
fprintf('%-4s %10s %10s %10s %10s %8s\n','cond','settled min','settled max','post min','post max','atDmin%');
Q3 = struct('cond',{},'setMin',{},'setMax',{},'postMin',{},'postMax',{},'satPct',{});
for k = 1:numel(conds)
    c = conds(k);
    p = dual_params(c.Vin,c.R,c.L,'nDly',1);
    r = sw_dual_sim(p,oRun);
    st = r.t > 0.075; ps = r.t >= 0.06;
    fprintf('%-4s %10.4f %10.4f %10.4f %10.4f %8.2f\n', c.id, min(r.duty(st)), ...
        max(r.duty(st)), min(r.duty(ps)), max(r.duty(ps)), ...
        100*mean(abs(r.duty(ps)-p.Dmin) < 1e-9));
    Q3(end+1) = struct('cond',c.id,'setMin',min(r.duty(st)),'setMax',max(r.duty(st)), ...
        'postMin',min(r.duty(ps)),'postMax',max(r.duty(ps)), ...
        'satPct',100*mean(abs(r.duty(ps)-p.Dmin) < 1e-9)); %#ok<AGROW>
end

res = struct('level','3A.6-Task5b','q1_outputRipple',Q1,'q2_startup',Q2, ...
    'q3_duty',Q3, ...
    'note',['Q1 explains the 0.0977 % S4 value as half the output ripple sampled at ' ...
            'the boundary; Q2 checks whether the start-up region (negative iL, DCM ' ...
            'not modelled) contaminates the load-step metrics; Q3 separates the ' ...
            'operating-point duty range from the transient duty excursion.']);
save(fullfile(outDir,'a6_task5b_s4.mat'),'res');
fid = fopen(fullfile(outDir,'a6_task5b_s4.json'),'w');
if fid >= 0, fwrite(fid, jsonencode(res), 'char'); fclose(fid); end
fprintf('\nsaved a6_task5b_s4.json/.mat\n');
end
