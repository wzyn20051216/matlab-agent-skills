%% Phase 3A.4 / Task 1: exact average state-space model of the dual loop
%
% Architecture
%   vC --> [PI outer] --> iL_ref --> [P inner] --> d --> Buck --> iL, vC
%
% Control law (identical convention to Phase 3A.2 so results are comparable):
%   e      = Vref - vC
%   iLref  = Kp_e*e + Ki_e*xe                      [A]      (xe: A*s)
%   dxe/dt = e  (+ back-calculation anti-windup)
%   d_raw  = Vref/Vin + Kci*(iLref - iL)/Vin       [1]      (no vC feedforward!)
%   d      = sat(d_raw, Dmin, Dmax)
%
% Units
%   Kci    [V/A] = [ohm]  -> virtual series resistance of the current loop
%   Kp_e   [A/V]
%   Ki_e   [A/(V*s)]
%   Vref/Vin [-] feedforward duty; MUST be a constant (a vC/Vin feedforward
%   makes Vin*d = vC hold identically, so every vC is an equilibrium and the
%   outer loop cannot regulate -- see Phase 3A.2 finding #3).
%
% The EXACT closed-loop characteristic polynomial is derived symbolically in
% the report; this script only *numerically* verifies it. It does NOT use the
% approximation |Re_LC| ~ Kci/(2L) for any claim.
%
% Output: a4_task1_model.json / .mat

clear; close all;
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, '..'));
outDir = getenv('BUCK_OUT');
if isempty(outDir), outDir = fullfile(here, '..', '..', 'artifacts', 'validation', 'buck'); end
outDir = strrep(outDir, '/', filesep);
fprintf('=========== 3A.4 Task 1: dual-loop average model ===========\n');

%% ---------- T1.1 nominal hardware ----------
P = struct('Vin',48, 'Vref',12, 'L',150e-6, 'C',220e-6, 'R',6, ...
           'fs',50e3, 'Dmin',0.05, 'Dmax',0.85, 'Imax',20);
P.Ts = 1/P.fs;
fprintf('\n--- T1.1 nominal operating point ---\n');
D0 = P.Vref/P.Vin; I0 = P.Vref/P.R;
fprintf('  D0 = Vref/Vin = %.6f   I0 = Vref/R = %.4f A\n', D0, I0);
% power balance: input power == output power (lossless average model)
fprintf('  Pin = Vin*Iin = Vin*D0*I0 = %.4f W\n', P.Vin*D0*I0);
fprintf('  Pout= Vref*I0             = %.4f W   -> balance error = %.3e W\n', ...
    P.Vref*I0, P.Vin*D0*I0 - P.Vref*I0);
% inductor volt-second balance at the operating point
fprintf('  volt-second: Vin*D0 - vC = %.6f V (should be 0)\n', P.Vin*D0 - P.Vref);
% the control law reproduces D0 exactly at steady state (e=0, iLref=iL):
dSS = P.Vref/P.Vin + 0;   % Kci*(iLref-iL)/Vin = 0
fprintf('  d_ss from the control law = %.6f  (matches D0: %d)\n', dSS, abs(dSS-D0)<1e-12);

%% ---------- T1.2 exact closed-loop A matrix ----------
% x = [iL; vC; xe]
%   diL/dt = ( Vin*d - vC )/L ,  d = Vref/Vin + Kci*(iLref - iL)/Vin
%   dvC/dt = ( iL - vC/R )/C
%   dxe/dt = Vref - vC
% => A = [ -a, -(1+Kci*Kp_e)/L,  Kci*Ki_e/L ;
%          1/C,        -1/(R*C),        0      ;
%          0,          -1,              0      ]
% with a = Kci/L.
acl = @(p, Kci, Kpe, Kie) [ -Kci/p.L, -(1+Kci*Kpe)/p.L, Kci*Kie/p.L ; ...
                             1/p.C,   -1/(p.R*p.C),     0          ; ...
                             0,       -1,               0          ];
clsys = @(p, Kci, Kpe, Kie) ss(acl(p,Kci,Kpe,Kie), [0;0;0], [0 1 0], 0);

fprintf('\n--- T1.2 exact characteristic polynomial ---------\n');
% Analytic result (derived by hand in the report, verified numerically here):
%   det(sI-A) = s^3 + (Kci/L + 1/(R*C))*s^2
%                   + (Kci/(L*R*C) + (1 + Kci*Kp_e)/(L*C))*s
%                   + Kci*Ki_e/(L*C)
Kci = 2; Kpe = 0.5; Kie = 500;
pAna = [1, ...
        Kci/P.L + 1/(P.R*P.C), ...
        Kci/(P.L*P.R*P.C) + (1 + Kci*Kpe)/(P.L*P.C), ...
        Kci*Kie/(P.L*P.C)];
fprintf('  at Kci=%.2f Kp_e=%.2f Ki_e=%.0f :\n', Kci, Kpe, Kie);
fprintf('    analytic [s^3 s^2 s 1] = %s\n', mat2str(pAna,8));
pl = pole(clsys(P,Kci,Kpe,Kie));
pNum = poly(pl);
fprintf('    pole()   [s^3 s^2 s 1] = %s\n', mat2str(pNum,8));
okPoly = max(abs(pAna - pNum)./max(abs(pAna),eps)) < 1e-10;
fprintf('    analytic == numeric    : %d   (max rel err %.3e)\n', okPoly, ...
    max(abs(pAna-pNum)./max(abs(pAna),eps)));
fprintf('    poles: %s\n', mat2str(sort(pl).',6));
% Routh-Hurwitz necessary+sufficient for a monic cubic
%   s^3 + c2 s^2 + c1 s + c0 : stable iff c2>0, c1>0, c0>0, c2*c1>c0
stRouth = (pAna(2)>0) && (pAna(3)>0) && (pAna(4)>0) && (pAna(2)*pAna(3) > pAna(4));
fprintf('    Routh-Hurwitz c2*c1>c0 : %d  (c2*c1=%.4e  c0=%.4e)\n', stRouth, ...
    pAna(2)*pAna(3), pAna(4));
fprintf('    maxRe from pole()      : %+.4f  (stable: %d)\n', max(real(pl)), max(real(pl))<0);
% analytic stability bound on Ki_e from Routh:  Ki_e < c2*c1_option*L*C/Kci
KieRouthMax = (pAna(2)*(Kci/(P.L*P.R*P.C))) * (P.L*P.C)/Kci;
fprintf('    Routh upper bound on Ki_e (ignoring the Kp_e term) ~ %.4e A/(V*s)\n', KieRouthMax);

%% ---------- T1.3 how Kci moves the LC pair (exact, no approximation) ----------
fprintf('\n--- T1.3 effect of Kci on the closed-loop poles (Kp_e=0, Ki_e=500) ---\n');
fprintf('  %8s %10s %10s %10s %10s %12s\n', 'Kci','Re(slow)','wn_LC(Hz)','zeta_LC','maxRe','|Re|_dominant');
for Kci = [0.2 0.5 0.63 1 1.5 2 3 5 10 15.7]
    pl = pole(clsys(P,Kci,0,500));
    pl = pl(abs(imag(pl))>1e-6);                     % the complex pair
    if isempty(pl)
        continue;
    end
    [~,ip] = max(imag(pl));
    p1 = pl(ip);
    wn = abs(p1); z = -real(p1)/wn;
    plAll = pole(clsys(P,Kci,0,500));
    fprintf('  %8.2f %10.1f %10.1f %10.3f %10.2f %12.1f\n', Kci, real(p1), ...
        wn/(2*pi), z, max(real(plAll)), -max(real(plAll)));
end

%% ---------- T1.4 outer loop: can it be made fast AND damped? ----------
% The ideal-current-source limit (Kci -> inf) gives a clean analytic target:
%   RC*s^2 + (1 + R*Kp_e)*s + R*Ki_e = 0
%   wn = sqrt(Ki_e/C) ,  2*zeta*wn = (1+R*Kp_e)/(R*C)
% so Kp_e and Ki_e are INDEPENDENT knobs -- Phase 3A.2 only explored Kp_e=0,
% which is why it concluded "zeta ~ 1/Ki_e, PM and dip cannot both be had".
fprintf('\n--- T1.4 ideal-current-source target (sanity of the design formulas) ---\n');
fprintf('  %10s %10s %10s %10s %11s %11s %11s\n', ...
    'wn_t(rad/s)','zeta_t','Kp_e','Ki_e','wn_act','zeta_act','Re_slow');
for wnT = [1000 1500 2000 2500 3000 4000 5000]
    for zT = [0.7]
        KieT = P.C*wnT^2;
        KpeT = (2*zT*wnT*P.R*P.C - 1)/P.R;
        if KpeT < 0, continue; end
        pl = pole(clsys(P,10,KpeT,KieT));
        pls = pl(abs(imag(pl))>1e-6);
        if isempty(pls), continue; end
        [~,ip] = max(imag(pls)); p1 = pls(ip);
        fprintf('  %10.0f %10.2f %10.4f %10.1f %11.1f %11.3f %11.1f\n', wnT, zT, KpeT, KieT, ...
            abs(p1), -real(p1)/abs(p1), max(real(pl)));
    end
end

%% ---------- T1.5 per-loop open-loop characteristics ----------
fprintf('\n--- T1.5a inner current loop (iLref -> iL), plant = Vin/(L*s) ---\n');
fprintf('  The inner loop closes around an INTEGRATOR, so a P controller gives a\n');
fprintf('  first-order lag with pole -Kci/L; it has no finite crossover of the\n');
fprintf('  usual type. What matters is the tracking bandwidth Kci/L.\n');
fprintf('  %8s %12s %12s %14s\n','Kci','Kci/L(rad/s)','f_ci(Hz)','f_ci/fs');
for Kci = [0.63 1 1.5 2 3 5 10 15.7]
    fprintf('  %8.2f %12.1f %12.1f %14.4f\n', Kci, Kci/P.L, Kci/P.L/2/pi, Kci/P.L/2/pi/P.fs);
end
fprintf('  NOTE: a P-only current loop cannot reject the vC back-EMF; the outer\n');
fprintf('  integrator is what removes the resulting steady-state current error.\n');

fprintf('\n--- T1.5b outer voltage loop: PM of the FULL 3rd-order loop ---\n');
fprintf('  L(s) = (Kp_e + Ki_e/s) * [vC/iLref with the inner loop closed]\n');
fprintf('  %8s %8s %9s %9s %10s %10s %12s\n','Kci','Kp_e','Ki_e','PM(deg)','fc(Hz)','maxRe','S5pred(ms)');
for Kci = [1 2 5 10]
  for Kpe = [0.2 0.5 1.0 2.0]
    for Kie = [300 800 2000]
      % vC/iLref with the inner loop closed.  Derivation (2-state, exact):
      %   (Ls+Kci) iL = Kci*iLref - vC ,  vC = iL*R/(1+sRC)
      %   =>  vC/iLref = R*Kci / [ (Ls+Kci)(1+sRC) + R ]
      %                 = Kci / [ LC s^2 + (L/R + C*Kci) s + (1 + Kci/R) ]
      % NOTE: the naive Kci/(Ls+Kci) * R/(1+sRC) misses the "+R" term, i.e. the
      % load feedback. Its DC gain is R instead of R*Kci/(Kci+R), which inflates
      % the loop gain by up to (Kci+R)/Kci and falsely raises PM (this file had
      % that bug in its first draft; the cross-check below is what caught it).
      Gv = tf(Kci, [P.L*P.C, P.L/P.R + P.C*Kci, 1 + Kci/P.R]);
      GvDC = dcgain(Gv); GvDCexpect = P.R*Kci/(P.R+Kci);
      Cs = tf([Kpe Kie],[1 0]);
      Lp = minreal(Cs*Gv);
      [~,pm,~,wc] = local_margins(Lp);
      plAll = pole(feedback(Lp,1));
      if abs(GvDC-GvDCexpect) > 1e-9
          error('Gv DC gain %.6f != R*Kci/(R+Kci) = %.6f', GvDC, GvDCexpect);
      end
      fprintf('  %8.1f %8.2f %9.0f %9.2f %10.1f %10.1f %12s\n', Kci, Kpe, Kie, pm, ...
          wc/2/pi, max(real(plAll)), '-');
    end
  end
end

%% ---------- T1.6 continuous vs discrete ----------
fprintf('\n--- T1.6 continuous vs discrete (ZOH + 0/1/2 sample delay) ---\n');
fprintf('  %8s %8s %9s %8s %10s %10s %12s %10s\n','Kci','Kp_e','Ki_e','delay','PM_c','PM_d','max|z|','GM_d');
for Kci = [2 5 10]
  for Kpe = [0.5 1.0 2.0]
    Kie = 800;
    Gv = tf(Kci, [P.L*P.C, P.L/P.R + P.C*Kci, 1 + Kci/P.R]);
    Cs = tf([Kpe Kie],[1 0]);
    Lc = minreal(Cs*Gv);
    [~,pmc] = local_margins(Lc);
    for nd = 0:2
        if nd > 0, dly = tf(1,[1 zeros(1,nd-1) 0], P.Ts); else, dly = 1; end
        Ld = c2d(Cs,P.Ts,'zoh')*dly*c2d(Gv,P.Ts,'zoh');
        [gmd,pmd,~,~,~,info] = local_margins(Ld);
        zc = pole(feedback(Ld,1)); mz = max(abs(zc));
        if isinf(gmd), gs='Inf'; else, gs=sprintf('%.2f',gmd); end
        fprintf('  %8.1f %8.2f %9.0f %8d %10.2f %10.2f %12.6f %10s\n', ...
            Kci, Kpe, Kie, nd, pmc, pmd, mz, gs);
    end
  end
end

%% ---------- T1.7 modal amplitude / S5 of the load step (exact) ----------
% R switches from R0 to R1 = R0/2 at the step. The response is a linear
% combination of the POST-step closed-loop modes with coefficients fixed by
% continuity of (iL, vC) and continuity of xe across the step.
fprintf('\n--- T1.7 load-step modal decomposition (R 6 -> 3 ohm) ---\n');
fprintf('  %8s %8s %9s %12s %12s %10s %10s %11s\n','Kci','Kp_e','Ki_e','domRe','domHz','A_pct','S5sum(ms)','dip_pct');
ratio = 2;
bestS5 = inf; bestCfg = [];
for Kci = [1 2 5 10 15]
  for Kpe = [0.3 0.6 1.0 1.5 2.0]
    for Kie = [800 2000 4000 8000]
      [s5, Apct, dRe, dHz, dipPct] = step_response_dual(P, Kci, Kpe, Kie, ratio);
      if isfinite(s5) && s5 < 1.0
          flag = ' <= S5 MET';
      else
          flag = '';
      end
      fprintf('  %8.1f %8.2f %9.0f %12.1f %12.1f %10.3f %10.4f %11.3f%s\n', ...
          Kci, Kpe, Kie, dRe, dHz, Apct, s5, dipPct, flag);
      if isfinite(s5) && s5 < bestS5
          bestS5 = s5; bestCfg = [Kci Kpe Kie];
      end
    end
  end
end
fprintf('  best S5 = %.4f ms at Kci=%.2f Kp_e=%.2f Ki_e=%.0f\n', bestS5, bestCfg(1), bestCfg(2), bestCfg(3));

save(fullfile(outDir,'a4_task1_model.mat'),'P','D0','I0','pAna');
fid = fopen(fullfile(outDir,'a4_task1_model.json'),'w');
fwrite(fid, jsonencode(struct('Vin',P.Vin,'Vref',P.Vref,'L',P.L,'C',P.C,'R',P.R, ...
    'fs',P.fs,'D0',D0,'I0',I0,'polyAnalytic',pAna,'polyOK',okPoly)), 'char'); fclose(fid);
fprintf('\nsaved a4_task1_model.mat / .json\n');

% ==================================================================
function [s5ms, Apct, domRe, domHz, dipPct] = step_response_dual(P, Kci, Kpe, Kie, ratio)
% Exact load-step response of the 3-state dual loop, computed from the
% closed-loop modes of the POST-step plant.
R1 = P.R/ratio;
Apre = acl_of(P, P.R, Kci, Kpe, Kie);
% pre-step steady state: iL0 = Vref/R, vC0 = Vref
% Pre-step steady state. xe is NOT zero: at steady state iLref = iL = Vref/R0
% and e = 0, so xe = (Vref/R0)/Ki_e. Setting xe=0 (first draft) makes the
% current reference start from zero and fabricates a ~30 % initial deviation.
x0 = [P.Vref/P.R; P.Vref; (P.Vref/P.R)/Kie];
% post-step steady state (xe must be re-solved: iLref_ss = Vref/R1 = Ki_e*xe)
xe1 = (P.Vref/R1)/Kie;
xss = [P.Vref/R1; P.Vref; xe1];
Apost = acl_of(P, R1, Kci, Kpe, Kie);
d0 = x0 - xss;                       % deviation at the switching instant
[V, Lam] = eig(Apost);
c = V \ d0;                          % modal coefficients on the ABSOLUTE state
% output is vC = row 2 -> dev(t) = sum_q V(2,q)*c(q)*exp(lam_q t)
tv = (0:1e-6:0.060).';
dev = zeros(numel(tv),1);
nM = size(V,2);
for q = 1:nM
    dev = dev + real(V(2,q)*c(q)*exp(Lam(q,q)*tv));
end
band = 0.01*P.Vref;
lo = find(abs(dev) > band, 1, 'last');
if isempty(lo), s5ms = 0;
elseif lo == numel(tv), s5ms = NaN;
else, s5ms = tv(lo+1)*1e3; end
% dominant mode = the one that leaves the band last
lam = diag(Lam); amp = abs(V(2,:).'.*c);
tExit = -inf(size(lam));
for q = 1:numel(lam)
    if amp(q) > band && real(lam(q)) < 0
        tExit(q) = log(amp(q)/band)/(-real(lam(q)));
    end
end
[~,iq] = max(tExit);
domRe = real(lam(iq)); domHz = abs(imag(lam(iq)))/(2*pi); Apct = amp(iq)/P.Vref*100;
dipPct = min(dev)/P.Vref*100;
end

function A = acl_of(P, R, Kci, Kpe, Kie)
A = [ -Kci/P.L, -(1+Kci*Kpe)/P.L, Kci*Kie/P.L ; ...
       1/P.C,   -1/(R*P.C),        0            ; ...
       0,       -1,                0            ];
end
