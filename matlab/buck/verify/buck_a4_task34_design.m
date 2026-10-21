%% Phase 3A.4 / Task 3+4: outer loop design and S5/S7 feasibility for the
%% dual loop, with and without load-current feedforward.
%
% CAND-A : pure dual loop, vC and iL only   (no extra sensor)
% CAND-B : dual loop + measured load current feedforward
%          iLref = Kpe*e + Kie*xe + iLoad
%          requires one extra current-sense channel (shunt/Hall + ADC), and the
%          claim "iLoad = vC/R" is only used inside the small-signal model; the
%          implementation uses the MEASURED iLoad.
%
% Everything is judged against the ORIGINAL S1-S8 thresholds. Nothing is relaxed.
%
% Output: a4_task34_design.json / .mat, a4_task34_pareto.png

clear; close all;
addpath(fullfile(fileparts(mfilename('fullpath')), '..'));
outDir = getenv('BUCK_OUT');
if isempty(outDir), outDir = fullfile(fileparts(mfilename('fullpath')),'..','..','artifacts','validation','buck'); end
outDir = strrep(outDir,'/',filesep);

P = struct('Vref',12,'C',220e-6,'fs',50e3,'Dmin',0.05,'Dmax',0.85,'Vin',48,'L',150e-6,'R',6);
P.Ts = 1/P.fs;
STD = struct('PM_min',50,'GM_min',6,'dip_max',12,'s5_max',1.0);
condTbl = [48 6 150e-6; 42 6 150e-6; 54 6 150e-6; 48 12 150e-6; ...
           48 3 150e-6; 54 3 150e-6; 48 6 195e-6];
condIds = {'C1','C2','C3','C4','C5','C6','C7'};

fprintf('=========== 3A.4 Task 3+4: outer loop + feasibility ===========\n');
fprintf('standards (unchanged): PM>=%g GM>=%g dB  |dip|<=%g%%  S5<=%g ms\n\n', ...
    STD.PM_min, STD.GM_min, STD.dip_max, STD.s5_max);

%% ---------- T3.1 design formulas vs the EXACT model ----------
fprintf('--- T3.1 outer-loop design formulas vs exact 3rd-order model ---\n');
fprintf('  Ideal-current-source limit: RC s^2 + (1+R*Kpe) s + R*Kie = 0\n');
fprintf('    wn = sqrt(Kie/C) ,  zeta = (1+R*Kpe)/(2*R*sqrt(C*Kie))\n');
fprintf('  %8s %6s %9s %6s %10s %10s %10s %10s\n', ...
    'wn_t','zeta','Kpe','Kie','wn_exact','zeta_ex','Re_dom','dev%');
for wnT = [1500 2000 2500 3000 3500]
  for zT = 0.7
    KieT = P.C*wnT^2;
    KpeT = (2*zT*wnT*P.R*P.C - 1)/P.R;
    A = dual_A(P, P.R, 8, KpeT, KieT, 0);
    pl = eig(A); pls = pl(abs(imag(pl))>1e-6);
    if isempty(pls), continue; end
    [~,ip] = max(imag(pls)); p1 = pls(ip);
    fprintf('  %8.0f %6.2f %9.4f %6.0f %10.1f %10.3f %10.1f %10.2f\n', ...
        wnT, zT, KpeT, KieT, abs(p1), -real(p1)/abs(p1), max(real(pl)), ...
        (abs(p1)-wnT)/wnT*100);
  end
end
fprintf('  => the formulas are accurate to a few percent at Kci=8; they are used\n');
fprintf('     ONLY to seed the search, never as evidence.\n');

%% ---------- T3.2 feasibility search ----------
fprintf('\n--- T3.2 feasibility search (all 7 conditions, discrete PM with 1 Ts delay) ---\n');
for ff = [0 1]
  if ff, fprintf('\n### CAND-B: dual loop + load-current feedforward ###\n');
  else,  fprintf('\n### CAND-A: pure dual loop ###\n'); end
  fprintf('  %6s %6s %7s %8s %8s %9s %9s %8s %8s\n', ...
      'Kci','Kp_e','Ki_e','PMd1','GMd1','S5max','dipW','dutyMax','feas');
  R = struct('Kci',{},'Kpe',{},'Kie',{},'ff',{},'pmd',{},'gmd',{},'pmc',{}, ...
             's5',{},'dip',{},'dutyMax',{},'iLmax',{},'dut',{},'zInner',{}, ...
             'feas',{},'s5v',{},'dipv',{});
  nFeas = 0; bestS5 = inf; bestCfg = [];
  for Kci = [4 5 6 7 8 9 10 12]
   for Kpe = [1.2 1.4 1.6 1.8 2.0 2.2 2.5 2.8]
    for Kie = [4000 4500 5000 5500 6000 6500 7000 8000 9000]
      pmd = inf; gmd = inf; pmc = inf;
      s5v = zeros(1,7); dipv = zeros(1,7); dmax = 0; iLm = 0; dut = false;
      zInnerWorst = 1;
      for ic = 1:7
        Vin = condTbl(ic,1); R0 = condTbl(ic,2); Lq = condTbl(ic,3);
        q = P; q.Vin = Vin; q.L = Lq; q.R = R0;
        % CORRECT plant for BOTH architectures. With ff=1 the inner loop
        % regulates iC (not iL), so the old vC/Vin-equivalent transfer function
        % tf(Kci,[LC, L/R+C*Kci, 1+Kci/R]) is simply the wrong object and would
        % mis-state PM for CAND-B. dual_loop_gain derives it from the state
        % equations with the feedforward folded in.
        Gv = tf(dual_loop_gain(q, R0, Kci, Kpe, Kie, ff, 'plant'));
        Cs = tf([Kpe Kie],[1 0]);
        Ld = c2d(Cs,P.Ts,'zoh')*tf(1,[1 0],P.Ts)*c2d(Gv,P.Ts,'zoh');
        [pmk,gmk] = margin_fast(Ld, 2500);
        pmd = min(pmd,pmk); if isfinite(gmk), gmd = min(gmd,gmk); end
        [pmck,~] = margin_fast(minreal(Cs*Gv), 2500);
        pmc = min(pmc, pmck);
        ev = dual_step_eval(q, Vin, R0, Lq, Kci, Kpe, Kie, ff, 2);
        s5v(ic) = ev.s5ms; dipv(ic) = ev.dipPct;
        dmax = max(dmax, ev.dmax); iLm = max(iLm, ev.iLmaxA);
        dut = dut || ev.dutFlag;
        % INNER-LOOP SAMPLING CONSTRAINT (found the hard way in 3A.4).
        % The digital inner loop closes around an integrator, so with a P gain
        % the current-loop pole maps to z = 1 - Kci*Ts/L. If this goes negative
        % the current loop rings at fs/2 (25 kHz); if |z|>1 it is unstable. The
        % CONTINUOUS model shows nothing of this -- for Kci=10..12 it still
        % predicts S5 ~ 0.7 ms while the discrete simulation does not settle at
        % all (measured S5 = NaN ~ 30 ms). Requiring z>=0 gives Kci <= L/Ts,
        % i.e. a current-loop time constant no shorter than one sampling period.
        zk = 1 - Kci*P.Ts/Lq;
        zInnerWorst = min(zInnerWorst, zk);
      end
      s5m = max(s5v); dipw = min(dipv);
      % Saturation MUST be part of feasibility: when the linear duty command
      % leaves [Dmin,Dmax] the linear modal sum is no longer valid (it keeps
      % commanding more than the actuator can deliver), so S5/dip would be
      % optimistic. Such points are reported as infeasible with dut=true and
      % must be re-checked by the nonlinear digital simulation.
      feas = (pmd>=STD.PM_min) && (gmd>=STD.GM_min) && (s5m<=STD.s5_max) && ...
             (dipw>=-STD.dip_max) && ~any(isnan(s5v)) && ~dut && ...
             (zInnerWorst >= 0);
      R(end+1) = struct('Kci',Kci,'Kpe',Kpe,'Kie',Kie,'ff',ff,'pmd',pmd, ...
          'gmd',gmd,'pmc',pmc,'s5',s5m,'dip',dipw,'dutyMax',dmax, ...
          'iLmax',iLm,'dut',dut,'zInner',zInnerWorst,'feas',feas, ...
          's5v',s5v,'dipv',dipv);
      if feas, nFeas = nFeas + 1; end
      if feas && s5m < bestS5, bestS5 = s5m; bestCfg=[Kci Kpe Kie]; end
      % print: all feasible points, plus the region near the S5/S2 boundary
      if feas || (pmd>=48 && pmd<=53)
        fprintf('  %6.1f %6.2f %7.0f %8.2f %8.2f %9.4f %9.3f %8.3f %8d%s\n', ...
            Kci,Kpe,Kie,pmd,gmd,s5m,dipw,dmax,feas, ...
            merge(feas,' ***',''));
      end
    end
   end
  end
  fprintf('  --> feasible points: %d ; best S5 = %.4f ms', nFeas, bestS5);
  if ~isempty(bestCfg)
    fprintf(' at Kci=%.1f Kp_e=%.2f Ki_e=%.0f', bestCfg(1),bestCfg(2),bestCfg(3));
  end
  fprintf('\n');
  if ff, RB = R; else, RA = R; end
end

%% ---------- T4.1 Pareto front (S5 vs PM) per architecture ----------
fprintf('\n--- T4.1 Pareto front: minimum S5max for a required PM_disc ---\n');
fprintf('  %10s %12s %12s\n','PM req','CAND-A S5','CAND-B S5');
for pmq = [50 52 55 58 60 65]
  sA = pareto_min(RA, pmq); sB = pareto_min(RB, pmq);
  fprintf('  %10.0f %12s %12s\n', pmq, num2str(sA,'%.4f'), num2str(sB,'%.4f'));
end

%% ---------- T4.2 what binds S5 ----------
fprintf('\n--- T4.2 which condition binds S5 (best CAND-A / CAND-B point) ---\n');
for k = 1:2
  if k==1, set = RA; nm='CAND-A'; else, set=RB; nm='CAND-B'; end
  fin = set([set.feas]);
  if isempty(fin), fprintf('  %s: no feasible point\n', nm); continue; end
  [~,ib] = min([fin.s5]); b = fin(ib);
  fprintf('  %s (Kci=%.1f Kp_e=%.2f Ki_e=%.0f): PMd=%.2f GMd=%.2f\n', ...
      nm, b.Kci, b.Kpe, b.Kie, b.pmd, b.gmd);
  for ic = 1:7
    fprintf('     %s: S5=%8.4f ms  dip=%9.3f %%\n', condIds{ic}, b.s5v(ic), b.dipv(ic));
  end
end

save(fullfile(outDir,'a4_task34_design.mat'),'RA','RB','P','STD','condTbl','condIds');
fid = fopen(fullfile(outDir,'a4_task34_design.json'),'w');
tmp = rmfield_s5v(RB);
fwrite(fid, jsonencode(struct('CAND_A',rmfield_s5v(RA),'CAND_B',tmp, ...
    'standards',STD)), 'char'); fclose(fid);
fprintf('\nsaved a4_task34_design.mat / .json\n');

% ==================================================================
function s = pareto_min(R, pmq)
s = NaN;
if isempty(R), return; end
ok = [R.pmd] >= pmq & [R.gmd] >= 6 & [R.dip] >= -12 & ~isnan([R.s5]);
if any(ok), s = min([R(ok).s5]); end
end

function o = rmfield_s5v(R)
% jsonencode cannot handle the per-condition vectors together with empty
% struct arrays; flatten to plain column vectors.
o = struct('Kci',[R.Kci].','Kpe',[R.Kpe].','Kie',[R.Kie].','ff',[R.ff].', ...
    'pmd',[R.pmd].','gmd',[R.gmd].','pmc',[R.pmc].','s5max',[R.s5].', ...
    'dipworst',[R.dip].','dutyMax',[R.dutyMax].','iLmax',[R.iLmax].', ...
    'zInner',[R.zInner].','feas',[R.feas].');
end

function s = merge(c,a,b)
if c, s=a; else, s=b; end
end
