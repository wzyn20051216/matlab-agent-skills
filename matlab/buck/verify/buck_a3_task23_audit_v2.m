%% Phase 3A.3 Task 2+3 audit (v2): the modal S5 formula, audited three ways
%
% READ-ONLY w.r.t. existing sources; writes new JSON/MAT only.
%
% Task 2 asks: in  S5 ~ ln(A_LC/A_tol)/|Re p_LC|
%   (1) what exactly is A_LC?
%   (2) what exactly is A_tol?
%   (3) are units consistent?
%   (4) re-check C1 BASE / C1 OPT / C6 OPT
%   (5) if the tabulated amplitude is a different quantity, add separate fields
%   (6) recompute all 14 predictions and per-case relative error
%   (7) no rounding tricks, no data edits
%
% This script therefore defines and compares THREE candidate meanings of A:
%   A_eig    coefficient of the LC pair from an eigen-decomposition of the
%            post-step closed loop, with the true state at the switch instant
%   A_lsq    least-squares coefficient of the LC pair fitted to the recorded
%            waveform over a window
%   A_env    envelope amplitude obtained from LOCAL PEAKS of the recorded
%            oscillation, extrapolated to t=0 by an exponential fit
% Only A_env is a direct measurement of "oscillation envelope amplitude".
%
% and reports S5 four ways:
%   S5_formula   ln(A/A_tol)/|sigma| using each A
%   S5_modalsum  exact modal sum  sum_q 2 Re(a_q exp(p_q t))   (phase kept)
%   S5_ode       independent fixed-step RK4 of the FULL 0..120 ms piecewise
%                system, starting from X0=[0;0] like the Simulink model
%   S5_meas      recorded waveform
%
% Pure ASCII on purpose (MATLAB reads .m with the GBK codepage here).

clear; close all;
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, '..'));
outDir = getenv('BUCK_OUT');
if isempty(outDir), outDir = fullfile(here,'..','..','artifacts','validation','buck'); end
outDir = strrep(outDir,'/',filesep);

Vref = 12; C0 = 220e-6;
Dmin = 0; Dmax = 0.9; Tt = 1e-3;
tStep = 0.060; tStop = 0.120; ratio = 2; A_tol = 0.01*Vref;

fprintf('===== Task 2+3 audit v2: what is A_LC, and does the formula hold? =====\n');
D = load(fullfile(outDir,'task5_acceptance.mat'));
recs = D.recs; conds = D.conds; b = D.b; fnNom = D.fnNom;

condTbl = [48 6 150e-6; 42 6 150e-6; 54 6 150e-6; 48 12 150e-6; ...
           48 3 150e-6; 54 3 150e-6; 48 6 195e-6];
ctrlTbl = { ...
  struct('id','BASE','Kp',0,'Ki',7.902901,'notch',false,'wn',fnNom,'zn',0,'zd',0), ...
  struct('id','OPT','Kp',b.Kp,'Ki',b.Ki,'notch',true,'wn',fnNom,'zn',b.zn,'zd',b.zd), ...
  struct('id','OPT30','Kp',b.Kp,'Ki',30,'notch',true,'wn',fnNom,'zn',b.zn,'zd',b.zd)};

fprintf('\n--- T2.0 frozen definitions ---\n');
fprintf('A_tol = 1%% of Vref = %.4f V (band HALF-width).  S5 in ms, sigma in 1/s.\n', A_tol);
fprintf('A_eig : LC-pair coefficient 2|a| from eig(), state at switch from RK4\n');
fprintf('A_lsq : LC-pair coefficient from LSQ on the recorded 0.3..30 ms segment\n');
fprintf('A_env : envelope from LOCAL PEAKS of the recorded oscillation, exp-fitted\n');
fprintf('        to A_env*exp(sigma*t); this is the only direct envelope measurement\n');

tpl = struct('cond','','ctrl','','f_ring',[],'sigma_env',[], ...
    'A_eig_V',[],'A_lsq_V',[],'A_env_V',[], ...
    'S5f_eig',[],'S5f_lsq',[],'S5f_env',[], ...
    'S5_modalsum',[],'S5_ode',[],'S5_meas',[], ...
    'e_eig',[],'e_lsq',[],'e_env',[],'e_sum',[],'e_ode',[], ...
    'condEig',[],'odeVsMeas_V',[],'satHit',[],'preDev_V',[],'verdict','');
out = struct(); out.cases = tpl([]);

for ic = 1:size(condTbl,1)
    Vin = condTbl(ic,1); Rpre = condTbl(ic,2); L = condTbl(ic,3); Rpost = Rpre/ratio;
    for ik = 1:numel(ctrlTbl)
        k = ctrlTbl{ik};
        idx = find(strcmp({recs.cond},conds(ic).id) & strcmp({recs.ctrl},k.id),1);
        if isempty(idx), continue; end
        r = recs(idx);
        i0 = find(r.t >= tStep,1);
        tp = r.t(i0:end) - tStep; vp = r.vC(i0:end);

        % ---- measured pre-step deviation (startup not fully settled) ----
        preDev = r.vC(i0) - Vref;

        % ---- faithful RK4 over the FULL 0..120 ms, X0=[0;0] ----
        [tO, vO] = buck_ode_full(k, Vin, L, C0, Rpre, Rpost, Vref, tStep, tStop, ...
            1e-6, Dmin, Dmax, Tt);
        iO = find(tO >= tStep,1);
        tpO = tO(iO:end) - tStep; vpO = vO(iO:end);
        s5ode = strict_s5(tpO, vpO, Vref, A_tol);
        odeVsMeas = max(abs(vpO - interp1(tp, vp, tpO, 'linear', 'extrap')));
        s5meas = strict_s5(tp, vp, Vref, A_tol);
        xsw = state_at_switch(k, Vin, L, C0, Rpre, Vref, tStep, 1e-6, Dmin, Dmax, Tt);

        % ---- A_env from local peaks of the recorded oscillation ----
        [A_env, sig_env, f_ring] = envelope_fit(tp, vp - Vref);

        % ---- A_eig from the post-step A with the true switch state ----
        Apost = buck_cl_a(k, Vin, L, C0, Rpost);
        % CRITICAL: expand the deviation from the POST-step steady state, not the
        % absolute state. Otherwise the DC operating point (12 V) leaks into the
        % modal sum and every coefficient is inflated by ~12 V.
        xss_post = buck_x0_ss(k, Vin, Rpost, Vref);
        mc = modal_of_step(Apost, xsw - xss_post, Vref);
        % pick the pair closest to f_ring
        iLC = 1; bestd = inf;
        for q = 1:numel(mc)
            if abs(imag(mc(q).p)) > 1
                d = abs(abs(imag(mc(q).p))/(2*pi) - f_ring);
                if d < bestd, bestd = d; iLC = q; end
            end
        end
        if abs(imag(mc(iLC).p)) > 1
            % a conjugate PAIR contributes 2*Re(a*exp(pt)) -> envelope = 2|a|
            A_eig = 2*abs(mc(iLC).a); sig_eig = real(mc(iLC).p);
        else
            A_eig = NaN; sig_eig = NaN;
        end
        condEig = cond(basis_of(mc, tp(2:2:min(end,2000))));

        % ---- A_lsq: LSQ coefficient of the LC pair on the recorded segment ----
        A_lsq = lsq_pair_amp(mc, iLC, tp, vp - Vref);

        % ---- S5 predictions ----
        s5f_eig = safe_formula(A_eig, sig_eig, A_tol);
        s5f_lsq = safe_formula(A_lsq, sig_eig, A_tol);
        s5f_env = safe_formula(A_env, sig_env, A_tol);
        s5sum = s5_modalsum(mc, tp, Vref, A_tol);

        % ---- duty saturation from the record ----
        satHit = (r.dutyMax >= Dmax-1e-9) || (r.dutyMin <= Dmin+1e-9);

        e = tpl;
        e.cond = conds(ic).id; e.ctrl = k.id;
        e.f_ring = f_ring; e.sigma_env = sig_env;
        e.A_eig_V = A_eig; e.A_lsq_V = A_lsq; e.A_env_V = A_env;
        e.S5f_eig = s5f_eig; e.S5f_lsq = s5f_lsq; e.S5f_env = s5f_env;
        e.S5_modalsum = s5sum; e.S5_ode = s5ode; e.S5_meas = s5meas;
        e.e_eig = relerr(s5f_eig,s5meas); e.e_lsq = relerr(s5f_lsq,s5meas);
        e.e_env = relerr(s5f_env,s5meas); e.e_sum = relerr(s5sum,s5meas);
        e.e_ode = relerr(s5ode,s5meas);
        e.condEig = condEig; e.odeVsMeas_V = odeVsMeas;
        e.satHit = satHit; e.preDev_V = preDev;
        if ~isfinite(s5meas)
            e.verdict = 'UNDETERMINED(not converged)';
        elseif satHit
            e.verdict = 'UNDETERMINED(duty saturated: linear model invalid)';
        elseif odeVsMeas > 0.02
            e.verdict = 'UNDETERMINED(independent ODE vs Simulink mismatch)';
        else
            e.verdict = 'DETERMINED';
        end
        out.cases(end+1) = e;
        out.modes{numel(out.cases)} = mc;

        fprintf('%s %-6s f_ring=%6.1fHz | A: eig=%8.3f lsq=%8.3f env=%8.3f V | ', ...
            conds(ic).id, k.id, f_ring, A_eig, A_lsq, A_env);
        fprintf('S5: eig=%7.3f lsq=%7.3f env=%7.3f sum=%7.3f ode=%7.3f meas=%7.3f | ', ...
            s5f_eig, s5f_lsq, s5f_env, s5sum, s5ode, s5meas);
        fprintf('cond=%.1e dODE=%.4fV pre=%+.4fV %s\n', condEig, odeVsMeas, preDev, e.verdict);
    end
end

%% ---------- summaries ----------
fprintf('\n--- T2.1 per-channel error over determined cases ---\n');
det = strcmp({out.cases.verdict},'DETERMINED');
fprintf('determined %d / %d\n', nnz(det), numel(out.cases));
if any(det)
    chans = {'e_eig','formula with A_eig'; 'e_lsq','formula with A_lsq'; ...
             'e_env','formula with A_env'; 'e_sum','modal sum (exact)'; ...
             'e_ode','independent RK4'};
    for q = 1:size(chans,1)
        v = abs([out.cases(det).(chans{q,1})]);
        v = v(isfinite(v));
        if isempty(v), continue; end
        fprintf('  %-20s max %8.3f %%  mean %7.3f %%  (n=%d)\n', chans{q,2}, max(v), mean(v), numel(v));
    end
end

fprintf('\n--- T2.2 the four named cases requested by the task ---\n');
fprintf('%-8s %-6s %10s %10s %10s %10s %10s %10s\n', ...
    'case','ctrl','A_env(V)','A_env(%)','sigma_env','S5f_env','S5sum','S5meas');
for want = {'C1','C6'}
    for ik = [1 2]
        j = find(strcmp({out.cases.cond},want{1}) & strcmp({out.cases.ctrl},ctrlTbl{ik}.id),1);
        if isempty(j), continue; end
        c = out.cases(j);
        fprintf('%-8s %-6s %10.4f %10.3f %10.2f %10.4f %10.4f %10.4f\n', ...
            c.cond, c.ctrl, c.A_env_V, c.A_env_V/Vref*100, c.sigma_env, ...
            c.S5f_env, c.S5_modalsum, c.S5_meas);
    end
end

fprintf('\n--- T3 condition number of the modal basis (collinearity) ---\n');
for j = 1:numel(out.cases)
    if out.cases(j).condEig > 1e4
        fprintf('  ILL-COND %s %-6s cond=%.2e -> individual "amplitudes" are not robust\n', ...
            out.cases(j).cond, out.cases(j).ctrl, out.cases(j).condEig);
    end
end
fprintf('  median cond = %.2e\n', median([out.cases.condEig]));

fprintf('\n--- T3 independent ODE vs Simulink (whole post-step record) ---\n');
fprintf('  max |dvC| over all cases = %.5f V\n', max([out.cases.odeVsMeas_V]));

try
    save(fullfile(outDir,'a3_task23_audit_v2.mat'),'out');
    outJ = out;
    for q = 1:numel(outJ.modes)
        pl = [outJ.modes{q}.p]; aa = [outJ.modes{q}.a];
        outJ.modes{q} = struct('p_re',real(pl),'p_im',imag(pl),'a_re',real(aa),'a_im',imag(aa));
    end
    txt = jsonencode(outJ);
    fid = fopen(fullfile(outDir,'a3_task23_audit_v2.json'),'w');
    n = fwrite(fid, txt, 'char'); fclose(fid);
    fprintf('\nsaved a3_task23_audit_v2.mat / .json (%d bytes)\n', n);
catch ME
    fprintf(2,'save failed: %s\n', ME.message);
end

%% ================= local functions =================
function s5 = strict_s5(tp, vp, Vref, tol)
inB = abs(vp - Vref) <= tol;
lo = find(~inB, 1, 'last');
if isempty(lo), s5 = 0;
elseif lo == numel(inB), s5 = NaN;
else, s5 = tp(lo+1)*1e3; end
end

function s = safe_formula(A, sig, A_tol)
if ~isfinite(A) || ~isfinite(sig) || A <= A_tol || sig >= 0
    s = NaN;
else
    s = log(A/A_tol)/abs(sig)*1e3;
end
end

function e = relerr(x, ref)
if isfinite(x) && isfinite(ref) && ref > 0
    e = (x-ref)/ref*100;
else
    e = NaN;
end
end

function A = buck_cl_a(k, Vin, L, C, R)
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

function mc = modal_of_step(A, x0, Vref) %#ok<INUSD>
[V, Lam] = eig(A);
p = diag(Lam); W = inv(V); c = W*x0(:);
amp = V(2,:).' .* c(:);
mc = struct('p',{},'a',{});
used = false(numel(p),1);
for q = 1:numel(p)
    if used(q), continue; end
    if abs(imag(p(q))) < 1e-6
        mc(end+1) = struct('p',real(p(q)),'a',amp(q)); %#ok<SAGROW>
        used(q) = true;
    else
        j = find(abs(p - conj(p(q))) < 1e-6, 1);
        if isempty(j) || used(j), continue; end
        % keep the complex coefficient; pair contribution = 2*Re(a*exp(pt))
        mc(end+1) = struct('p',p(q),'a',amp(q)); %#ok<SAGROW>
        used(q) = true; used(j) = true;
    end
end
end

function B = basis_of(mc, tv)
B = zeros(numel(tv), numel(mc));
for q = 1:numel(mc)
    B(:,q) = exp(mc(q).p*tv);
end
end

function A = lsq_pair_amp(mc, iLC, tp, dev)
w = tp >= 0.0003 & tp <= 0.030;
tw = tp(w); yw = dev(w);
B = zeros(numel(tw), numel(mc));
for q = 1:numel(mc), B(:,q) = exp(mc(q).p*tw); end
cf = B \ yw;
A = abs(cf(iLC))*2;      % pair contribution is 2*Re(...)
end

function s5 = s5_modalsum(mc, tp, Vref, tol)
v = zeros(size(tp));
for q = 1:numel(mc)
    if abs(imag(mc(q).p)) < 1e-6
        v = v + real(mc(q).a)*exp(real(mc(q).p)*tp);
    else
        v = v + 2*real(mc(q).a*exp(mc(q).p*tp));
    end
end
% dev already starts at ~0 because we expand relative to x_ss
s5 = strict_s5(tp, v, 0, tol);   % band on |dev| <= tol
end

function [A, sig, fpk] = envelope_fit(tp, dev)
% local peaks of |dev| after 0.5 ms, then ln(peak) = ln A + sig*t
sel = tp >= 0.0005;
t = tp(sel); y = abs(dev(sel));
pv = [];
for i = 2:numel(y)-1
    if y(i) > y(i-1) && y(i) >= y(i+1) && y(i) > 1e-5
        pv(end+1) = i; %#ok<AGROW>
    end
end
if numel(pv) < 4
    A = NaN; sig = NaN; fpk = NaN; return;
end
pf = polyfit(t(pv), log(y(pv)), 1);
sig = pf(1); A = exp(pf(2));
% dominant ringing frequency from zero crossings of the detrended signal
zc = 0;
for i = 2:numel(y)
    if sign(y(i)) ~= sign(y(i-1)) && abs(y(i)-y(i-1)) > 1e-9
        zc = zc + 1;
    end
end
span = t(end) - t(1);
if zc >= 2 && span > 0
    fpk = zc/(2*span);
else
    fpk = NaN;
end
% refine with FFT on a uniform resample
tu = (t(1):1e-6:t(end)).';
yu = interp1(t, dev(sel), tu, 'linear');
N = numel(yu);
if N > 64
    Y = abs(fft(yu.*hann(N)));
    fr = (0:N-1).'/(N*1e-6);
    band = fr > 300 & fr < 2500;
    [~, im] = max(Y(band));
    idxb = find(band); fpk = fr(idxb(im));
end
end

function x = state_at_switch(k, Vin, L, C, R, Vref, tSw, h, Dmin, Dmax, Tt)
n = round(tSw/h);
x = buck_x0_init(k);
for i = 1:n
    k1 = cl_deriv(x,      k, Vin, L, C, R, Vref, Dmin, Dmax, Tt);
    k2 = cl_deriv(x+h/2*k1, k, Vin, L, C, R, Vref, Dmin, Dmax, Tt);
    k3 = cl_deriv(x+h/2*k2, k, Vin, L, C, R, Vref, Dmin, Dmax, Tt);
    k4 = cl_deriv(x+h*k3, k, Vin, L, C, R, Vref, Dmin, Dmax, Tt);
    x = x + h/6*(k1 + 2*k2 + 2*k3 + k4);
end
end

function x0 = buck_x0_ss(k, Vin, R, Vref)
dss = Vref/Vin;
if k.notch
    x0 = [Vref/R; Vref; dss; dss/k.wn^2; 0];
else
    x0 = [Vref/R; Vref; dss];
end
end

function x0 = buck_x0_init(k)
if k.notch, x0 = zeros(5,1); else, x0 = zeros(3,1); end
end

function [t, vC] = buck_ode_full(k, Vin, L, C, Rpre, Rpost, Vref, tStep, tStop, h, Dmin, Dmax, Tt)
n1 = round(tStep/h); n2 = round((tStop-tStep)/h); n = n1+n2;
t = (0:n).'*h;
x = buck_x0_init(k);
vC = zeros(n+1,1); vC(1) = x(2);
for i = 1:n
    if i <= n1, R = Rpre; else, R = Rpost; end
    k1 = cl_deriv(x,      k, Vin, L, C, R, Vref, Dmin, Dmax, Tt);
    k2 = cl_deriv(x+h/2*k1, k, Vin, L, C, R, Vref, Dmin, Dmax, Tt);
    k3 = cl_deriv(x+h/2*k2, k, Vin, L, C, R, Vref, Dmin, Dmax, Tt);
    k4 = cl_deriv(x+h*k3, k, Vin, L, C, R, Vref, Dmin, Dmax, Tt);
    x = x + h/6*(k1 + 2*k2 + 2*k3 + k4);
    vC(i+1) = x(2);
end
end

function dx = cl_deriv(x, k, Vin, L, C, R, Vref, Dmin, Dmax, Tt)
vC = x(2); Int = x(3);
e = Vref - vC;
u_pi = k.Kp*e + Int;
if k.notch
    x1 = x(4); x2 = x(5); wn = k.wn; zn = k.zn; zd = k.zd;
    u_unsat = u_pi + 2*(zn-zd)*wn*x2;
    dx1 = x2;
    dx2 = -wn^2*x1 - 2*zd*wn*x2 + u_pi;
else
    u_unsat = u_pi; dx1 = 0; dx2 = 0;
end
d = min(max(u_unsat, Dmin), Dmax);
dInt = k.Ki*e + (1/Tt)*(d - u_unsat);
diL = (Vin*d - vC)/L;
dvC = (x(1) - vC/R)/C;
if k.notch
    dx = [diL; dvC; dInt; dx1; dx2];
else
    dx = [diL; dvC; dInt];
end
end
