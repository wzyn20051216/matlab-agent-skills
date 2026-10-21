function res = boost_b1_task1_model(outDir)
%BOOST_B1_TASK1_MODEL  Part 1: build the CCM Boost model and verify every
%                       formula against an independent computation.
%
% The brief asks for the two switching states, the averaged model, the operating
% point, currents/power, the CCM-DCM boundary, ripple estimates and the validity
% boundary of the loss model -- and it asks that every expression be numerically
% cross-checked against the MATLAB implementation. That cross-check IS this file.
%
% EACH CHECK PAIRS TWO INDEPENDENT ROUTES
%   operating point   closed-form algebra     vs  open-loop time-domain settling
%   switching states  average model at d=1/0  vs  separately written state ODEs
%   small signal      numerical Jacobian      vs  textbook ideal transfer function
%   RHP zero          model zero              vs  R(1-D)^2/L
%   ripple            triangle formulas       vs  independent one-period RK4
%   CCM boundary      valley-current formula  vs  three-point simulation check
% A disagreement is printed and marked FAIL; neither side is adjusted to agree.

if nargin < 1 || isempty(outDir), outDir = getenv('BOOST_OUT'); end
outDir = strrep(outDir,'/',filesep);
here = fileparts(mfilename('fullpath')); addpath(fileparts(here));
if ~exist(outDir,'dir'), mkdir(outDir); end

p = boost_params();
s = boost_steady(p);
r = boost_ripple(p, s.d);
fprintf('================ Phase 3B.1 Task 1: Boost model ================\n');
fprintf('Vin %.1f V -> Vref %.1f V, Pout %.0f W, fs %.0f kHz, L %.0f uH, C %.0f uF\n', ...
    p.Vin, p.Vref, p.Pout, p.fs/1e3, p.L*1e6, p.C*1e6);
fprintf('losses (ALL ASSUMPTIONS): RL %.0f mOhm, RonSW %.0f mOhm, RonD %.0f mOhm, Vf %.2f V, ESR %.0f mOhm\n\n', ...
    p.RL*1e3, p.RonSW*1e3, p.RonD*1e3, p.Vf, p.ESR*1e3);

C = struct('id',{},'title',{},'a',{},'b',{},'tol',{},'unit',{},'pass',{});
add = @(id,t,a,b,tol,u) struct('id',id,'title',t,'a',a,'b',b,'tol',tol,'unit',u, ...
    'pass',abs(a-b) <= tol);

%% ---------- 1) operating point ----------
fprintf('--- 1) operating point (CCM, losses included) ---\n');
fprintf('  D ideal (1-Vin/Vref)    = %.6f   <- textbook formula\n', s.Dideal);
fprintf('  D with losses           = %.6f   <- what actually produces %.1f V\n', s.d, p.Vref);
fprintf('  Vout                    = %.6f V\n', s.vOut);
fprintf('  iL (input current)      = %.6f A\n', s.iL);
fprintf('  iOut                    = %.6f A\n', s.iOut);
fprintf('  Pout / Pin / eff        = %.3f W / %.3f W / %.4f\n', s.pOut, s.pIn, s.eff);
fprintf('  inductor loss %.3f W, diode-drop loss %.3f W\n', s.lossInductor, s.lossDiode);
fprintf('  average-model residual  = %.2e\n', s.residual);

xT = settle_avg(p, s.d, [0.6*s.iL; 0.8*s.vOut], 0.4, 400);
d_x = abs(xT - [s.iL; s.vC])./max(1,abs([s.iL; s.vC]));
fprintf('  time-domain settling    -> iL %.6f A, vC %.6f V (rel dev %.2e)\n', ...
    xT(1), xT(2), max(d_x));
C(end+1) = add('1.1','operating point: algebra vs time domain', max(d_x), 0, 1e-6,'rel');

vId = boost_steady(p, s.Dideal).vOut;
fprintf('  => the ideal D=%.3f gives %.3f V (%.2f %%); the integrator must supply the\n', ...
    s.Dideal, vId, 100*(vId/p.Vref-1));
fprintf('     missing %.4f of duty. A report that quotes D=0.5 AND Vout=48 V is wrong.\n', ...
    s.d - s.Dideal);
C(end+1) = add('1.2','D=1 and D=0 match the independent state ODEs', ...
    norm(boost_avg_f([s.iL;s.vC],1,p) - state_on([s.iL;s.vC],p)) + ...
    norm(boost_avg_f([s.iL;s.vC],0,p) - state_off([s.iL;s.vC],p)), 0, 1e-10,'abs');

%% ---------- 2) small signal ----------
fprintf('\n--- 2) control-to-output transfer function ---\n');
pi0 = p; pi0.RL = 0; pi0.RonSW = 0; pi0.RonD = 0; pi0.Vf = 0; pi0.ESR = 0;
di0 = 1 - pi0.Vin/pi0.Vref;
Mi  = boost_avg_lin(pi0, di0);
Gnum = tf(ss(Mi.A, Mi.Bd, Mi.Cy, Mi.Dd));

u = 1 - di0; sref = tf('s');
Gana = pi0.Vin/u^2 * (1 - sref*pi0.L/(pi0.R*u^2)) / ...
       (1 + sref*pi0.L/(pi0.R*u^2) + sref^2*pi0.L*pi0.C/u^2);

dcNum = dcgain(Gnum); dcAna = pi0.Vin/u^2;
zN = sort(zero(Gnum)); zA = sort(zero(Gana));
pN = sort(pole(Gnum)); pA = sort(pole(Gana));
fprintf('  lossless case (a cross-check of the CODE, not of the design):\n');
fprintf('    DC gain  numeric %10.4f  analytic %10.4f  Vout/(1-D) %10.4f\n', dcNum, dcAna, pi0.Vref/u);
fprintf('    zeros    numeric %s\n             analytic %s\n', mat2str(round(zN,6).'), mat2str(round(zA,6).'));
fprintf('    poles    numeric %s\n             analytic %s\n', mat2str(round(pN,4).'), mat2str(round(pA,4).'));
C(end+1) = add('2.1','Gvd DC gain: numeric vs analytic', dcNum, dcAna, 1e-6*dcAna,'V/du');
C(end+1) = add('2.2','Gvd RHP zero: numeric vs R(1-D)^2/L', ...
    max(real(zN)), pi0.R*u^2/pi0.L, 1e-4*pi0.R*u^2/pi0.L,'rad/s');
C(end+1) = add('2.3','Gvd pole real part (ideal) vs 1/(2RC)', ...
    abs(real(pN(1))), 1/(2*pi0.R*pi0.C), 2e-3/(2*pi0.R*pi0.C),'rad/s');

M = boost_avg_lin(p, s.d);
G = tf(ss(M.A, M.Bd, M.Cy, M.Dd));
zz = zero(G); pp = pole(G);
zr = zz(real(zz) > 0); zl = zz(real(zz) < 0);
if isempty(zr), fR = NaN; else, fR = max(real(zr))/(2*pi); end
if isempty(zl), fL = NaN; else, fL = -min(real(zl))/(2*pi); end
w0 = sqrt(abs(prod(pp))); Qm = w0/(-2*real(pp(1)));
fprintf('  WITH losses (the actual design):\n');
fprintf('    RHP zero %.1f Hz   LHP zero (ESR) %.1f Hz\n', fR, fL);
fprintf('    f0 = %.2f Hz, Q = %.3f (from the model poles)\n', w0/(2*pi), Qm);
Rs = p.RL + s.d*p.RonSW + (1-s.d)*p.RonD;
Leq = p.L/(1-s.d)^2;
Qloss = 1/( Rs/(1-s.d)^2*sqrt(p.C/Leq) + sqrt(Leq/p.C)/p.R );
fprintf('    lossless Q = R(1-D)sqrt(C/L) = %.2f ; with Rs=%.0f mOhm -> Q ~ %.2f (measured %.2f)\n', ...
    r.Qideal, 1e3*Rs, Qloss, Qm);
fprintf('    => the DCR dominates the damping (Q drops %.1fx). A bandwidth rule that\n', r.Qideal/Qm);
fprintf('       assumes the lossless Q over-predicts the peaking.\n');
C(end+1) = add('2.4','lossy Q: pole estimate vs series-resistance formula', Qm, Qloss, 0.15*Qloss,'-');

%% ---------- 3) ripple vs independent one-period integration ----------
fprintf('\n--- 3) ripple: triangle formulas vs one-period RK4 ---\n');
% Start the independent run at the VALLEY of the predicted ripple. Starting at
% the average offsets the whole waveform by dIL/2 (first version: peak and valley
% both 0.55 A high). Settling the orbit first is not an option either: at light
% load the per-period decay is ~1e-3, so it takes thousands of periods.
[w, ~] = period_map_sw([r.iLvalley; s.vC], p, s.d);
fprintf('  iL peak-peak  formula %.6f A   RK4 %.6f A   dev %.2e A\n', ...
    r.dIL, w.iLpk-w.iLval, abs(r.dIL-(w.iLpk-w.iLval)));
fprintf('  iL peak       formula %.6f A   RK4 %.6f A\n', r.iLpk, w.iLpk);
fprintf('  iL valley     formula %.6f A   RK4 %.6f A\n', r.iLvalley, w.iLval);
fprintf('  iL period mean formula %.6f A   RK4 %.6f A\n', s.iL, w.iLmean);
fprintf('  vOut pk-pk    formula %.6f V   RK4 %.6f V   (ratio %.3f)\n', ...
    r.dvOut, w.vOpp, r.dvOut/w.vOpp);
C(end+1) = add('3.1','inductor ripple: formula vs RK4', r.dIL, w.iLpk-w.iLval, 5e-3*r.dIL,'A');
C(end+1) = add('3.2','period-mean iL: operating point vs RK4', s.iL, w.iLmean, 5e-3*s.iL,'A');
% the two-term output-ripple formula adds the capacitive triangle and the ESR step
% as if their peaks coincided: an UPPER BOUND, not an equality. Check it as a
% bound, and require it to be tight (<=1.25x the exact value).
C(end+1) = add('3.3','output ripple: formula is a tight upper bound', ...
    double(r.dvOut >= w.vOpp && r.dvOut <= 1.25*w.vOpp), 1, 0,'bool');

%% ---------- 4) CCM/DCM boundary: three-point check at the predicted R ----------
fprintf('\n--- 4) CCM/DCM boundary ---\n');
fprintf('  formula: valley reaches 0 at R = %.2f ohm, Iout = %.4f A (%.2f %% of rated)\n', ...
    r.Rb, r.Ib, r.IoutFrac*100);
vv = zeros(1,3); fac = [0.95 1.00 1.05];
for q = 1:3
    pp = p; pp.R = r.Rb*fac(q);
    sRb = boost_steady(pp, s.d);     % NOT "ss": that would shadow the ss() constructor
    % start at the LIGHT-LOAD steady state (average minus half ripple). Using the
    % FULL-LOAD valley here keeps the trajectory at 3.5 A and the check reports
    % "CCM" at every R -- which is exactly what the first version did.
    [wq, ~] = period_map_sw([sRb.iL - r.dIL/2; sRb.vC], pp, s.d);
    vv(q) = wq.iLval;
    fprintf('    R = %7.2f ohm (%.2fx Rb): valley = %+8.4f A  -> %s\n', pp.R, fac(q), ...
        vv(q), tern(vv(q) > 0,'CCM','would be DCM'));
end
fprintf('  => |valley| at the predicted boundary is %.4f A (%.2f %% of the ripple) and the\n', ...
    abs(vv(2)), 100*abs(vv(2))/r.dIL);
fprintf('     sign changes across it: the boundary is verified to +-5 %% without any\n');
fprintf('     slow orbit settling.\n');
C(end+1) = add('4.1','CCM boundary: formula bracketed +-5% by simulation', ...
    double(vv(1) > 0 && vv(3) < 0 && abs(vv(2)) < 0.10*r.dIL), 1, 0,'bool');

%% ---------- 5) what the loss model does NOT contain ----------
fprintf('\n--- 5) loss-model boundary (stated, not modelled) ---\n');
fprintf('  modelled    : RL*iL^2, RonSW*d*iL^2, RonD*(1-d)*iL^2, Vf*(1-d)*iL, ESR\n');
fprintf('  NOT modelled: switching loss (Coss, gate, reverse recovery), dead time,\n');
fprintf('                core loss, saturation, temperature, diode capacitance, PCB,\n');
fprintf('                DCM (the average model has no DCM state)\n');
fprintf('  => efficiency from this model is an OPTIMISTIC estimate; treat it as an upper bound.\n');

pass = [C.pass];
fprintf('\n---- Task 1 summary: %d / %d checks pass ----\n', nnz(pass), numel(pass));
for q = 1:numel(C)
    fprintf('  %-4s %-56s %s\n', C(q).id, C(q).title, tern(C(q).pass,'PASS','FAIL'));
end

res = struct('level','3B.1-Task1','params',p,'steady',s,'ripple',r, ...
    'checks',C,'nPass',nnz(pass),'nTotal',numel(pass), ...
    'rhpZeroHz',fR,'esrZeroHz',fL,'f0Hz',w0/(2*pi),'Qmodel',Qm,'Qlossless',r.Qideal, ...
    'note','numerically linearised average model; analytic TF used only as a check');
save(fullfile(outDir,'b1_task1_model.mat'),'res');
fid = fopen(fullfile(outDir,'b1_task1_model.json'),'w');
if fid >= 0, fwrite(fid, jsonencode(res), 'char'); fclose(fid); end
fprintf('\nsaved b1_task1_model.json/.mat\n');
if nnz(pass) < numel(pass)
    fprintf(2,'WARNING: %d check(s) failed -- see the table above\n', numel(pass)-nnz(pass));
end
end

% ---------------------------------------------------------------------------
function xT = settle_avg(p, d, x0, tEnd, n)
% independent route to the DC operating point: integrate the average model
h = tEnd/n; x = x0;
for k = 1:n
    k1 = boost_avg_f(x,d,p); k2 = boost_avg_f(x+0.5*h*k1,d,p);
    k3 = boost_avg_f(x+0.5*h*k2,d,p); k4 = boost_avg_f(x+h*k3,d,p);
    x = x + (h/6)*(k1+2*k2+2*k3+k4);
end
xT = x;
end

function dx = state_on(x, p)
% switch closed, diode reverse-biased: the capacitor supplies the load alone
iL = x(1); vC = x(2);
vOut = vC/(1 + p.ESR/p.R);
dx = [(p.Vin - iL*(p.RL + p.RonSW))/p.L; -(vOut/p.R)/p.C];
end

function dx = state_off(x, p)
% switch open, diode conducts: the inductor feeds the output
iL = x(1); vC = x(2);
vOut = (vC + p.ESR*iL)/(1 + p.ESR/p.R);
dx = [(p.Vin - vOut - p.Vf - (p.RL + p.RonD)*iL)/p.L; (iL - vOut/p.R)/p.C];
end

function [w, xnext] = period_map_sw(x, p, d)
% one switching period at FIXED duty, RK4, CCM (no DCM clamp), no controller
Ts = 1/p.fs; n = 2000; h = Ts/n;
x0 = x; t = 0;
iLmin = inf; iLmax = -inf; vmin = inf; vmax = -inf; iSum = 0;
for k = 1:n
    sw = (t + 0.5*h) < d*Ts;
    if sw
        k1 = state_on(x,p); k2 = state_on(x+0.5*h*k1,p);
        k3 = state_on(x+0.5*h*k2,p); k4 = state_on(x+h*k3,p);
    else
        k1 = state_off(x,p); k2 = state_off(x+0.5*h*k1,p);
        k3 = state_off(x+0.5*h*k2,p); k4 = state_off(x+h*k3,p);
    end
    x = x + (h/6)*(k1+2*k2+2*k3+k4);
    if sw, iIn = 0; else, iIn = x(1); end
    vO = (x(2) + p.ESR*iIn)/(1 + p.ESR/p.R);
    iLmin = min(iLmin,x(1)); iLmax = max(iLmax,x(1));
    vmin = min(vmin,vO); vmax = max(vmax,vO);
    iSum = iSum + x(1)*h;
    t = t + h;
end
xnext = x;
w = struct('iLpk',iLmax,'iLval',iLmin,'iLmean',iSum/Ts,'vOpp',vmax-vmin,'x0',x0,'xEnd',x);
end

function s = tern(c,a,b)
if c, s = a; else, s = b; end
end
