%% Phase 3A.3 Task 4 verification: re-check search finalists with faithful RK4
% READ-ONLY w.r.t. existing sources; new JSON/MAT only.
% pm_fast is a search aid; every claim here is re-derived with
%   - local_margins (official convention, worst over all 0-dB crossings)
%   - own fixed-step RK4 of the FULL 0..120 ms piecewise system from X0=[0;0]
% Pure ASCII.

clear; close all;
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, '..'));
outDir = getenv('BUCK_OUT');
if isempty(outDir), outDir = fullfile(here,'..','..','artifacts','validation','buck'); end
outDir = strrep(outDir,'/',filesep);
Vref = 12; C0 = 220e-6; Dmin=0; Dmax=0.9; Tt=1e-3;
tStep=0.060; tStop=0.120; ratio=2; A_tol=0.01*Vref;

D = load(fullfile(outDir,'task5_acceptance.mat'));
b = D.b; fn = D.fnNom;
condTbl = [48 6 150e-6; 42 6 150e-6; 54 6 150e-6; 48 12 150e-6; ...
           48 3 150e-6; 54 3 150e-6; 48 6 195e-6];
cids = {'C1','C2','C3','C4','C5','C6','C7'};

cands = { ...
  struct('id','bestS5',  'Kp',0.010,'Ki',50,'notch',true,'wns',0.85,'zn',0.01,'zd',1.00), ...
  struct('id','bestS7',  'Kp',0.080,'Ki', 5,'notch',true,'wns',0.92,'zn',0.05,'zd',1.00), ...
  struct('id','refOPT',  'Kp',b.Kp ,'Ki',b.Ki,'notch',true,'wns',1.00,'zn',b.zn,'zd',b.zd), ...
  struct('id','refBASE', 'Kp',0    ,'Ki',7.902901,'notch',false,'wns',1.00,'zn',0,'zd',0)};

fprintf('=== Task 4 verification: local_margins + faithful RK4 ===\n');
for q = 1:numel(cands)
    k = cands{q};
    if k.notch, k.wn = k.wns*fn; else, k.wn = fn; end
    fprintf('\n--- %s: Kp=%.3f Ki=%.1f notch=%d wn/fn=%.2f zn=%.2f zd=%.2f ---\n', ...
        k.id, k.Kp, k.Ki, k.notch, k.wns, k.zn, k.zd);
    fprintf('  %-4s %8s %8s %10s %10s %8s %8s\n','cond','PM','GM','S5_rk4','dip%','dutyLo','dutyHi');
    res = struct('cond',{},'PM',{},'GM',{},'S5',{},'dip',{},'dLo',{},'dHi',{});
    for ic = 1:7
        Vin=condTbl(ic,1); R=condTbl(ic,2); L=condTbl(ic,3); Rp=R/ratio;
        G = tf(Vin,[L*C0, L/R, 1]);
        if k.notch
            nt = (tf('s')^2+2*k.zn*k.wn*tf('s')+k.wn^2)/ ...
                 (tf('s')^2+2*k.zd*k.wn*tf('s')+k.wn^2);
            Lp = minreal(pid(k.Kp,k.Ki,0,0)*nt*G);
        else
            Lp = minreal(pid(k.Kp,k.Ki,0,0)*G);
        end
        [gm,pm] = local_margins(Lp);
        [t,v,duty] = rk4_full(k, Vin, L, C0, R, Rp, Vref, tStep, tStop, 1e-6, Dmin, Dmax, Tt);
        i0 = find(t>=tStep,1);
        tp = t(i0:end)-tStep; vp = v(i0:end);
        inB = abs(vp-Vref) <= A_tol;
        lo = find(~inB,1,'last');
        if isempty(lo), s5=0; elseif lo==numel(inB), s5=NaN; else, s5=tp(lo+1)*1e3; end
        dip = (min(vp)-Vref)/Vref*100;
        dlo = min(duty(i0:end)); dhi = max(duty(i0:end));
        res(end+1) = struct('cond',cids{ic},'PM',pm,'GM',gm,'S5',s5, ...
            'dip',dip,'dLo',dlo,'dHi',dhi);
        if isinf(gm), gs='Inf'; else, gs=sprintf('%.2f',gm); end
        fprintf('  %-4s %8.2f %8s %10.4f %10.3f %8.3f %8.3f\n', cids{ic}, pm, gs, s5, dip, dlo, dhi);
    end
    pmMin = min([res.PM]); gmMin = min([res.GM]);
    s5max = max([res.S5]);
    dipMax = max(abs([res.dip]));
    fprintf('  -> worst PM=%.2f  GM=%.2f  S5max=%.4f  |dip|max=%.2f%%\n', pmMin, gmMin, s5max, dipMax);
    fprintf('     S2 %s | S3 %s | S5 %s | S7 %s\n', ...
        tf2(pmMin>=50), tf2(gmMin>=6), tf2(s5max<=1.0), tf2(dipMax<=12));
    out.res{q} = res; %#ok<SAGROW>
end
try
    save(fullfile(outDir,'a3_task4_verify.mat'),'out');
    J = struct('cands',{cands},'res',{out.res});
    txt = jsonencode(J);
    fid=fopen(fullfile(outDir,'a3_task4_verify.json'),'w'); n=fwrite(fid,txt,'char'); fclose(fid);
    fprintf('\nsaved a3_task4_verify.mat / .json (%d bytes)\n', n);
catch ME
    fprintf(2,'save failed: %s\n', ME.message);
end

function s = tf2(c)
if c, s='PASS'; else, s='FAIL'; end
end

function [t,v,duty] = rk4_full(k, Vin, L, C, Rpre, Rpost, Vref, tStep, tStop, h, Dmin, Dmax, Tt)
n1 = round(tStep/h); n2 = round((tStop-tStep)/h); n = n1+n2;
t = (0:n).'*h;
if k.notch, x = zeros(5,1); else, x = zeros(3,1); end
v = zeros(n+1,1); duty = zeros(n+1,1);
v(1) = x(2); duty(1) = ctrl_d(k,x,Vref,Dmin,Dmax);
for i = 1:n
    if i<=n1, R = Rpre; else, R = Rpost; end
    k1 = der(x,        k,Vin,L,C,R,Vref,Dmin,Dmax,Tt);
    k2 = der(x+h/2*k1, k,Vin,L,C,R,Vref,Dmin,Dmax,Tt);
    k3 = der(x+h/2*k2, k,Vin,L,C,R,Vref,Dmin,Dmax,Tt);
    k4 = der(x+h*k3,   k,Vin,L,C,R,Vref,Dmin,Dmax,Tt);
    x = x + h/6*(k1+2*k2+2*k3+k4);
    v(i+1) = x(2);
    duty(i+1) = ctrl_d(k,x,Vref,Dmin,Dmax);
end
end

function d = ctrl_d(k, x, Vref, Dmin, Dmax)
e = Vref - x(2);
u = k.Kp*e + x(3);
if k.notch, u = u + 2*(k.zn-k.zd)*k.wn*x(5); end
d = min(max(u,Dmin),Dmax);
end

function dx = der(x, k, Vin, L, C, R, Vref, Dmin, Dmax, Tt)
vC = x(2); Int = x(3);
e = Vref - vC;
u_pi = k.Kp*e + Int;
if k.notch
    x1=x(4); x2=x(5); wn=k.wn; zn=k.zn; zd=k.zd;
    u = u_pi + 2*(zn-zd)*wn*x2;
    dx1 = x2;
    dx2 = -wn^2*x1 - 2*zd*wn*x2 + u_pi;
else
    u = u_pi; dx1=0; dx2=0;
end
d = min(max(u,Dmin),Dmax);
diL = (Vin*d - vC)/L;
dvC = (x(1) - vC/R)/C;
dInt = k.Ki*e + (1/Tt)*(d-u);
if k.notch, dx = [diL;dvC;dInt;dx1;dx2]; else, dx = [diL;dvC;dInt]; end
end
