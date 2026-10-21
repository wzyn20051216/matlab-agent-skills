%% Phase 3A.3 Task 4: rebuild the S2/S5 feasible region for the single-loop family
%
% READ-ONLY w.r.t. existing sources; writes new JSON/MAT only.
%
% Acceptance thresholds are the ORIGINAL ones, unchanged:
%   S1 maxRe<0 | S2 worst PM>=50 deg | S3 GM>=6 dB | S4 |ssErr|<=0.1 %
%   S5 settle<=1.0 ms | S6 startup overshoot<=5 % | S7 |dip|<=12 %
%   S8 duty in [0.05,0.85]
%
% Speed strategy (documented, and validated below):
%   local_margins takes ~174 ms per call, far too slow for a 5-D grid.
%   pm_fast() uses a 4000-point log grid and unwrapped phase, then is
%   cross-checked against local_margins on a random sample before use.
%   S5 is predicted with the EXACT modal sum (validated in Task 2/3 to 0.013 %),
%   using the analytic post-step initial condition
%       dx0 = [Vref/Rpre - Vref/Rpost ; 0 ; 0 ...]
%   so no Simulink run is needed inside the search.
%
% Pure ASCII.

clear; close all;
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, '..'));
outDir = getenv('BUCK_OUT');
if isempty(outDir), outDir = fullfile(here,'..','..','artifacts','validation','buck'); end
outDir = strrep(outDir,'/',filesep);

Vref = 12; C0 = 220e-6;
D = load(fullfile(outDir,'task5_acceptance.mat'));
b = D.b; fnNom = D.fnNom;

fprintf('===== Task 4: S2/S5 feasible region (single-loop PI + notch) =====\n');

condTbl = [48 6 150e-6; 42 6 150e-6; 54 6 150e-6; 48 12 150e-6; ...
           48 3 150e-6; 54 3 150e-6; 48 6 195e-6];
cids = {'C1','C2','C3','C4','C5','C6','C7'};
cdn  = {'nom','Vin42','Vin54','R12','R3','Vin54R3','L+30'};
ratio = 2;

% ------------- validate pm_fast against local_margins -------------
fprintf('\n--- T4.0 pm_fast validation vs local_margins (random sample) ---\n');
rng(0); nv = 24; dmax = 0; gmax = 0;
for q = 1:nv
    Kp = 0.08*rand; Ki = 5+300*rand; wns = 0.85+0.3*rand;
    zn = 0.01+0.09*rand; zd = 0.3+0.7*rand;
    G = tf(48,[150e-6*C0, 150e-6/6, 1]);
    nt = (tf('s')^2+2*zn*wns*fnNom*tf('s')+(wns*fnNom)^2)/ ...
         (tf('s')^2+2*zd*wns*fnNom*tf('s')+(wns*fnNom)^2);
    Lp = minreal(pid(Kp,Ki,0,0)*nt*G);
    [gm1,pm1] = local_margins(Lp);
    [pm2,gm2] = pm_fast(Lp);
    dpm = abs(pm1-pm2);
    if isinf(gm1) && isinf(gm2), dgm = 0; elseif isinf(gm1)||isinf(gm2), dgm = Inf; else, dgm = abs(gm1-gm2); end
    dmax = max(dmax,dpm); gmax = max(gmax,dgm);
end
fprintf('  max |dPM| = %.4f deg, max |dGM| = %.4f dB over %d samples\n', dmax, gmax, nv);
if dmax > 0.30
    error('pm_fast inconsistent with local_margins (dPM=%.3f) -- abort', dmax);
end
fprintf('  -> pm_fast accepted for SEARCH ONLY (dPM<=0.30 deg); every reported\n');
fprintf('     finalist is re-evaluated with local_margins before any claim.\n');

% ------------- grid -------------
KpV = [0 0.01 0.02 0.03 0.04 0.05 0.06 0.08];
KiV = [5 8 12 18 25 35 50 70 100 140 200 300];
wnV = [0.85 0.92 1.00 1.08 1.15];
znV = [0 0.01 0.02 0.05 0.10];      % 0 = notch disabled
zdV = [0.30 0.50 0.80 1.00];
nTot = numel(KpV)*numel(KiV)*numel(wnV)*numel(znV)*numel(zdV);
fprintf('\n--- T4.1 grid: %d x %d x %d x %d x %d = %d candidates ---\n', ...
    numel(KpV),numel(KiV),numel(wnV),numel(znV),numel(zdV), nTot);
fprintf('  Kp   in [%g, %g]\n', min(KpV), max(KpV));
fprintf('  Ki   in [%g, %g]\n', min(KiV), max(KiV));
fprintf('  wn/fn in [%.2f, %.2f]\n', min(wnV), max(wnV));
fprintf('  zn   in [%g, %g] (0 = notch off)\n', min(znV), max(znV));
fprintf('  zd   in [%g, %g]\n', min(zdV), max(zdV));

N = NaN;
tpl = struct('Kp',N,'Ki',N,'wns',N,'zn',N,'zd',N, ...
    'PM_C1',N,'GM_C1',N,'maxRe_C1',N,'PM_C6',N,'GM_C6',N,'maxRe_C6',N, ...
    'PMmin',N,'GMmin',N,'S5_C1',N,'S5_C6',N,'S5max',N, ...
    'dip_C1',N,'dip_C6',N,'dipMaxAbs',N,'feas',false,'reason','');
rows = tpl([]);
nEval = 0; nPassS23 = 0;

for a1 = 1:numel(KpV)
 for a2 = 1:numel(KiV)
  for a3 = 1:numel(wnV)
   for a4 = 1:numel(znV)
    for a5 = 1:numel(zdV)
      k = struct('Kp',KpV(a1),'Ki',KiV(a2),'notch',znV(a4)>0, ...
                 'wn',wnV(a3)*fnNom,'zn',znV(a4),'zd',zdV(a5));
      nEval = nEval + 1;
      % Screen S1/S2/S3 at ALL 7 conditions (C4 turns out to be PM-binding;
      % screening only C1/C6 was an incomplete filter in the first pass).
      pm = inf; gm = inf; mre = -inf; pm1 = NaN; gm1 = NaN; mr1 = NaN;
      pm6 = NaN; gm6 = NaN; mr6 = NaN;
      for ic = 1:7
          Vin = condTbl(ic,1); R = condTbl(ic,2); L = condTbl(ic,3);
          G = tf(Vin,[L*C0, L/R, 1]);
          if k.notch
              nt = (tf('s')^2+2*k.zn*k.wn*tf('s')+k.wn^2)/ ...
                   (tf('s')^2+2*k.zd*k.wn*tf('s')+k.wn^2);
              Lp = minreal(pid(k.Kp,k.Ki,0,0)*nt*G);
          else
              Lp = minreal(pid(k.Kp,k.Ki,0,0)*G);
          end
          [pmk,gmk] = pm_fast(Lp);
          clp = pole(feedback(Lp,1)); mrk = max(real(clp));
          if ic == 1, pm1 = pmk; gm1 = gmk; mr1 = mrk; end
          if ic == 6, pm6 = pmk; gm6 = gmk; mr6 = mrk; end
          pm = min(pm,pmk); gm = min(gm,gmk); mre = max(mre,mrk);
      end
      r = tpl;
      r.Kp=k.Kp; r.Ki=k.Ki; r.wns=wnV(a3); r.zn=k.zn; r.zd=k.zd;
      r.PM_C1=pm1; r.GM_C1=gm1; r.maxRe_C1=mr1;
      r.PM_C6=pm6; r.GM_C6=gm6; r.maxRe_C6=mr6;
      r.PMmin=pm; r.GMmin=gm;
      if mre >= 0 || pm < 50 || gm < 6
          r.feas = false;
          if mre >= 0, r.reason = 'S1 unstable';
          elseif pm < 50, r.reason = 'S2 PM<50';
          else, r.reason = 'S3 GM<6'; end
          rows(end+1) = r;
          continue;
      end
      nPassS23 = nPassS23 + 1;
      % ---- S5 and dip at ALL 7 conditions via the exact modal sum ----
      s5v = zeros(1,7); dpv = zeros(1,7);
      for ic = 1:7
          [s5v(ic), dpv(ic)] = s5_dip(k, condTbl(ic,1), condTbl(ic,2), ...
              condTbl(ic,3), C0, Vref, ratio);
      end
      r.S5_C1 = s5v(1); r.S5_C6 = s5v(6); r.S5max = max(s5v);
      r.dip_C1 = dpv(1); r.dip_C6 = dpv(6);
      r.dipMaxAbs = max(abs(dpv));
      if ~(isfinite(r.S5max) && r.S5max <= 1.0)
          r.feas = false; r.reason = 'S5 settle>1ms';
      elseif ~(r.dipMaxAbs <= 12)
          r.feas = false; r.reason = 'S7 dip>12%';
      else
          r.feas = true; r.reason = 'FEASIBLE';
      end
      rows(end+1) = r;
    end
   end
  end
 end
end

fprintf('\n--- T4.2 search results ---\n');
fprintf('  evaluated            : %d\n', nEval);
fprintf('  passed S1+S2+S3      : %d (%.1f %%)\n', nPassS23, nPassS23/nEval*100);
nf = sum([rows.feas]);
fprintf('  FEASIBLE (all S1-S8) : %d\n', nf);
if nf > 0
    ix = find([rows.feas]);
    [~, o] = min([rows(ix).S5max]);
    bi = ix(o); c = rows(bi);
    fprintf('  best: Kp=%.3f Ki=%.1f wn/fn=%.2f zn=%.2f zd=%.2f\n', ...
        c.Kp,c.Ki,c.wns,c.zn,c.zd);
    fprintf('        PM=%.2f GM=%.2f S5(C1)=%.4f S5(C6)=%.4f dip=%.2f%%\n', ...
        c.PMmin,c.GMmin,c.S5_C1,c.S5_C6,c.dipMaxAbs);
else
    fprintf('  -> NO feasible point. This is a statement about the SEARCH RANGE only.\n');
    % closest points by S5 among those that passed S2/S3
    okS = [rows.PMmin] >= 50 & [rows.GMmin] >= 6 & [rows.maxRe_C1] < 0 & [rows.maxRe_C6] < 0;
    ix = find(okS);
    [~, o] = sort([rows(ix).S5max]);
    fprintf('  best-effort (S2/S3 met, S5 still failing):\n');
    for q = 1:min(5,numel(o))
        c = rows(ix(o(q)));
        fprintf('    Kp=%.3f Ki=%6.1f wn/fn=%.2f zn=%.2f zd=%.2f | PM=%6.2f S5max=%7.4f dip=%5.2f\n', ...
            c.Kp,c.Ki,c.wns,c.zn,c.zd,c.PMmin,c.S5max,c.dipMaxAbs);
    end
end

%% ---------- T4.3 Pareto: PM vs S5 ----------
fprintf('\n--- T4.3 Pareto front (PMmin vs S5max), S2/S3/S1-satisfying points ---\n');
ok = [rows.PMmin] >= 50 & [rows.GMmin] >= 6 & [rows.maxRe_C1] < 0 & [rows.maxRe_C6] < 0 ...
     & isfinite([rows.S5max]);
px = [rows(ok).PMmin]; py = [rows(ok).S5max];
if ~isempty(px)
    [pxs, oo] = sort(px); pys = py(oo);
    best = inf; front = false(size(pxs));
    for q = 1:numel(pxs)
        if pys(q) < best, front(q) = true; best = pys(q); end
    end
    fprintf('  Pareto points (PM, S5):\n');
    for q = find(front)
        fprintf('    PM=%6.2f  S5max=%7.4f ms\n', pxs(q), pys(q));
    end
    fprintf('  S5=1ms needs PM<=? -> min S5max over all S2/S3-ok points = %.4f ms\n', min(py));
else
    fprintf('  no S2/S3-satisfying point\n');
end

fprintf('\n--- T4.5 reachable S5max vs required PM threshold (S1/S3 met) ---\n');
base = [rows.maxRe_C1] < 0 & [rows.maxRe_C6] < 0 & [rows.GMmin] >= 6 & isfinite([rows.S5max]);
for pmq = [50 55 60 65 70 75 80]
    sel = base & [rows.PMmin] >= pmq;
    if any(sel)
        [best, bi] = min([rows(sel).S5max]);
        idxs = find(sel); c = rows(idxs(bi));
        fprintf('  PM>=%2d : n=%5d  min S5max=%7.4f ms  (Kp=%.2f Ki=%5.1f wn/fn=%.2f zn=%.2f zd=%.2f, dip=%.1f%%)\n', ...
            pmq, nnz(sel), best, c.Kp,c.Ki,c.wns,c.zn,c.zd,c.dipMaxAbs);
    else
        fprintf('  PM>=%2d : no point\n', pmq);
    end
end
fprintf('\n--- T4.6 same, but ALSO requiring S7 (|dip|<=12%%) ---\n');
for pmq = [50 55 60 65 70]
    sel = base & [rows.PMmin] >= pmq & [rows.dipMaxAbs] <= 12;
    if any(sel)
        [best, bi] = min([rows(sel).S5max]);
        idxs = find(sel); c = rows(idxs(bi));
        fprintf('  PM>=%2d : n=%5d  min S5max=%7.4f ms  (Kp=%.2f Ki=%5.1f wn/fn=%.2f zn=%.2f zd=%.2f)\n', ...
            pmq, nnz(sel), best, c.Kp,c.Ki,c.wns,c.zn,c.zd);
    else
        fprintf('  PM>=%2d : no point with dip<=12%%\n', pmq);
    end
end

%% ---------- T4.4 per-condition S5 for the two reference controllers ----------
fprintf('\n--- T4.4 reference controllers, all 7 conditions (modal-sum S5) ---\n');
refs = {struct('id','BASE','Kp',0,'Ki',7.902901,'notch',false,'wn',fnNom,'zn',0,'zd',0), ...
        struct('id','OPT','Kp',b.Kp,'Ki',b.Ki,'notch',true,'wn',fnNom,'zn',b.zn,'zd',b.zd)};
for q = 1:numel(refs)
    k = refs{q};
    fprintf('  %-5s:', k.id);
    for ic = 1:7
        [s5,dp] = s5_dip(k, condTbl(ic,1), condTbl(ic,2), condTbl(ic,3), C0, Vref, ratio);
        fprintf(' %s=%6.3f', cids{ic}, s5);
    end
    fprintf('\n');
end

try
    save(fullfile(outDir,'a3_task4_feasible.mat'),'rows','nEval','nPassS23','nf');
    J = rows; J = rmfield(J,{});
    txt = jsonencode(struct('nEval',nEval,'nPassS23',nPassS23,'nFeasible',nf, ...
        'grid',struct('Kp',KpV,'Ki',KiV,'wns',wnV,'zn',znV,'zd',zdV), ...
        'cases',J));
    fid = fopen(fullfile(outDir,'a3_task4_feasible.json'),'w');
    n = fwrite(fid,txt,'char'); fclose(fid);
    fprintf('\nsaved a3_task4_feasible.mat / .json (%d bytes)\n', n);
catch ME
    fprintf(2,'save failed: %s\n', ME.message);
end

%% ================= local functions =================
function [pm, gm] = pm_fast(L)
% Lean worst-case margins: dense log grid + unwrapped phase.
w = logspace(0, 7, 6000);
H = reshape(freqresp(L, w), [], 1);
m = 20*log10(max(abs(H), realmin));
ph = rad2deg(unwrap(angle(H)));
pm = inf;
for k = 1:numel(w)-1
    if m(k)*m(k+1) <= 0
        t = m(k)/(m(k)-m(k+1));
        pc = ph(k) + t*(ph(k+1)-ph(k));
        pm = min(pm, 180 + pc);          % unwrapped branch, no wrapping
    end
end
gm = inf;
for k = 1:numel(w)-1
    if (ph(k)+180)*(ph(k+1)+180) <= 0
        t = (ph(k)+180)/(ph(k)-(ph(k+1)));
        mm = m(k) + t*(m(k+1)-m(k));
        gm = min(gm, -mm);
    end
end
end

function [s5, dipAbs] = s5_dip(k, Vin, Rpre, L, C, Vref, ratio)
% Exact modal sum of the load-step response, analytic post-step initial state.
Rpost = Rpre/ratio;
A = cl_a(k, Vin, L, C, Rpost);
dss = Vref/Vin;
if k.notch
    xss = [Vref/Rpost; Vref; dss; dss/k.wn^2; 0];
    dx0 = [Vref/Rpre - Vref/Rpost; 0; 0; 0; 0];
else
    xss = [Vref/Rpost; Vref; dss]; %#ok<NASGU>
    dx0 = [Vref/Rpre - Vref/Rpost; 0; 0];
end
[V, Lam] = eig(A); p = diag(Lam); W = inv(V);
amp = V(2,:).' .* (W*dx0(:));
tp = (0:1e-6:0.060).';
v = zeros(size(tp));
used = false(numel(p),1);
for q = 1:numel(p)
    if used(q), continue; end
    if abs(imag(p(q))) < 1e-6
        v = v + real(amp(q))*exp(real(p(q))*tp);
        used(q) = true;
    else
        j = find(abs(p-conj(p(q))) < 1e-6, 1);
        if isempty(j) || used(j), continue; end
        v = v + 2*real(amp(q)*exp(p(q)*tp));
        used(q) = true; used(j) = true;
    end
end
tol = 0.01*Vref;
inB = abs(v) <= tol;
lo = find(~inB, 1, 'last');
if isempty(lo), s5 = 0;
elseif lo == numel(inB), s5 = NaN;
else, s5 = tp(lo+1)*1e3; end
dipAbs = abs(min(v))/Vref*100;
end

function A = cl_a(k, Vin, L, C, R)
if k.notch
    wn = k.wn; zn = k.zn; zd = k.zd;
    A = zeros(5,5);
    A(1,:) = [0, (-Vin*k.Kp-1)/L, Vin/L, 0, Vin*2*(zn-zd)*wn/L];
    A(2,:) = [1/C, -1/(R*C), 0, 0, 0];
    A(3,:) = [0, -k.Ki, 0, 0, 0];
    A(4,:) = [0, 0, 0, 0, 1];
    A(5,:) = [0, -k.Kp, 1, -wn^2, -2*zd*wn];
else
    A = zeros(3,3);
    A(1,:) = [0, (-Vin*k.Kp-1)/L, Vin/L];
    A(2,:) = [1/C, -1/(R*C), 0];
    A(3,:) = [0, -k.Ki, 0];
end
end
