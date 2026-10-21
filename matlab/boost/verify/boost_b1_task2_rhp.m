function res = boost_b1_task2_rhp(outDir)
%BOOST_B1_TASK2_RHP  Part 2: the right-half-plane zero of the CCM Boost.
%
% Four questions, each answered with two independent routes:
%   1. does the model reproduce  wz = R(1-D)^2/L  ?      model zero vs formula
%   2. how does wz move with D, R, L, Vin?               sweep + closed form
%   3. why does a duty increase initially LOWER the output?  time domain + theory
%   4. how much bandwidth does wz actually allow?        frequency domain + time
%      domain, with the digital delay included
%
% The brief forbids declaring an "optimal bandwidth" from a rule of thumb, so
% section 4 sweeps the crossover, measures the resulting PM/GM (delay included)
% and the time-domain response, and only then states a range -- with the reason
% for each boundary.

if nargin < 1 || isempty(outDir), outDir = getenv('BOOST_OUT'); end
outDir = strrep(outDir,'/',filesep);
here = fileparts(mfilename('fullpath')); addpath(fileparts(here));
addpath(fullfile(fileparts(fileparts(here)),'buck'));   % shared step_metrics (same definition as the Buck phase)
if ~exist(outDir,'dir'), mkdir(outDir); end

p = boost_params();
d0 = boost_duty_for(p, p.Vref);
r  = boost_ripple(p, d0);
Ts = 1/p.fs;
Md = boost_avg_lin(p, d0); pp0 = pole(tf(ss(Md.A,Md.Bd,Md.Cy,Md.Dd)));
w0d = sqrt(abs(prod(pp0))); Qdesign = w0d/(-2*real(pp0(1)));

fprintf('================ Phase 3B.1 Task 2: RHP zero ================\n');
fprintf('operating point: D=%.5f, iL=%.4f A, Vout=%.2f V\n\n', d0, boost_steady(p,d0).iL, p.Vref);

%% ---------- 1) verify wz = R(1-D)^2/L ----------
fprintf('--- 1) zero location: model vs R(1-D)^2/L ---\n');
fprintf('%8s %8s %9s %12s %12s %8s\n','Vin','R','L uH','wz model Hz','wz formula','dev %%');
GG = [ ...
    24 24 220; 24 12 220; 24 48 220; 24 24 100; 24 24 470; ...
    20 24 220; 30 24 220; 24 24 1000];
Z = struct('Vin',{},'R',{},'L',{},'D',{},'fzModel',{},'fzForm',{},'dev',{},'f0',{},'Q',{});
for q = 1:size(GG,1)
    pq = boost_params('Vin',GG(q,1),'R',GG(q,2),'L',GG(q,3)*1e-6);
    dq = boost_duty_for(pq, pq.Vref);
    M  = boost_avg_lin(pq, dq);
    G  = tf(ss(M.A, M.Bd, M.Cy, M.Dd));
    zz = zero(G);
    zr = zz(real(zz) > 0);
    fzm = max(real(zr))/(2*pi);
    u   = 1 - dq;
    fzf = pq.R*u^2/(2*pi*pq.L);
    pp  = pole(G); w0q = sqrt(abs(prod(pp)));
    dev = 100*(fzm/fzf - 1);
    fprintf('%8.1f %8.1f %9.0f %12.1f %12.1f %8.3f\n', pq.Vin, pq.R, pq.L*1e6, fzm, fzf, dev);
    Z(end+1) = struct('Vin',pq.Vin,'R',pq.R,'L',pq.L,'D',dq,'fzModel',fzm, ...
        'fzForm',fzf,'dev',dev,'f0',w0q/(2*pi),'Q',w0q/(-2*real(pp(1)))); %#ok<AGROW>
end
maxDev = max(abs([Z.dev]));
fprintf('  => max deviation %.3f %% over the grid. The formula holds for the LOSSY model\n', maxDev);
fprintf('     as well, because the RHP zero is set by R, D and L only -- the conduction\n');
fprintf('     losses move the DC gain and the damping, not the zero.\n');
fprintf('  => with ESR>0 the model has TWO zeros: the RHP one and an LHP one at 1/(2*pi*ESR*C)\n');
fprintf('     = %.0f Hz. Picking "the zero" without checking its sign gives the wrong answer.\n', ...
    1/(2*pi*p.ESR*p.C));

%% ---------- 2) sensitivity ----------
fprintf('\n--- 2) sensitivity of the RHP zero ---\n');
Dv = linspace(0.30, 0.80, 26);
fzD = p.R*(1-Dv).^2/(2*pi*p.L);
Rv = [6 12 24 48 96 192];
fzR = Rv*(1-d0)^2/(2*pi*p.L);
Lv = [100 150 220 330 470 680]*1e-6;
fzL = p.R*(1-d0)^2./(2*pi*Lv);
fprintf('  vs duty D   : %.0f Hz at D=0.30 -> %.0f Hz at D=0.80 (falls as (1-D)^2)\n', fzD(1), fzD(end));
fprintf('  vs load R   : %s Hz for R = %s ohm  (linear in R)\n', ...
    mat2str(round(fzR)), mat2str(Rv));
fprintf('  vs L        : %s Hz for L = %s uH  (inverse in L)\n', ...
    mat2str(round(fzL)), mat2str(Lv/1e-6));
fprintf('  => WORST case for control is maximum load (minimum R) at maximum duty\n');
fprintf('     (minimum Vin): here R=24, D=%.3f -> %.0f Hz. At 50 %% load the zero is twice\n', d0, fzD(end)*0+fzR(3));
fprintf('     as high, so a design that is only checked at full load is over-conservative\n');
fprintf('     at light load and optimistic nowhere.\n');

% the operating extremes of the acceptance set
fprintf('  operating extremes (Vin 20/28 V, load 50/100 %%):\n');
ex = [20 24 1.0; 28 24 1.0; 24 48 1.0; 24 12 1.0];
for q = 1:size(ex,1)
    pq = boost_params('Vin',ex(q,1),'R',ex(q,2));
    dq = boost_duty_for(pq, pq.Vref);
    fzq = pq.R*(1-dq)^2/(2*pi*pq.L);
    fprintf('    Vin %4.1f V, R %4.1f ohm: D=%.4f, fz = %6.0f Hz\n', pq.Vin, pq.R, dq, fzq);
end

%% ---------- 3) why a duty increase can lower the output first ----------
fprintf('\n--- 3) reverse response to a duty step (open loop, average model) ---\n');
fprintf('  physical reason: vOut responds to the DIODE current (1-d)*iL. A duty step up\n');
fprintf('  drops (1-d) immediately by -dd while iL can only rise with L/R time constant,\n');
fprintf('  so the charge delivered per cycle FALLS first. That is the RHP zero.\n');
fprintf('%14s %6s %10s %10s %10s %10s %10s\n','case','dd','Vout pre','min after','dip mV','dip/step %','t_min us');
S3 = struct('case',{},'dd',{},'vpre',{},'vmin',{},'dipPct',{},'dipRel',{},'tmin',{},'invfz',{});
cases3 = {'nominal 1%', 0.01, 1; 'nominal 5%', 0.05, 1; 'ESR=0, 5%', 0.05, 2; 'Vin=20V 5%', 0.05, 3};
for k = 1:size(cases3,1)
    pk = p;
    if cases3{k,3} == 2, pk.ESR = 0; end
    if cases3{k,3} == 3, pk.Vin = 20; end
    dk = boost_duty_for(pk, pk.Vref);
    fzk = pk.R*(1-dk)^2/(2*pi*pk.L);
    [t, v, ~] = duty_step(pk, dk, cases3{k,2}, 5e-3, 20e-3);
    ip = find(t >= 5e-3, 1);
    vpre = v(ip-1);
    win = t > 5e-3 & t < 15e-3;
    [vmin, im] = min(v(win));
    tw = t(win);
    vend = v(end);
    dipRel = 100*(vmin-vpre)/(vend-vpre);      % reverse as a fraction of the final change
    fprintf('%14s %6.2f %10.4f %10.4f %10.3f %10.1f %10.1f\n', cases3{k,1}, cases3{k,2}, ...
        vpre, vmin, 1e3*(vmin-vpre), dipRel, (tw(im)-5e-3)*1e6);
    S3(end+1) = struct('case',cases3{k,1},'dd',cases3{k,2},'vpre',vpre,'vmin',vmin, ...
        'dipPct',100*(vmin-vpre)/vpre,'dipRel',dipRel, ...
        'tmin',(tw(im)-5e-3),'invfz',1/fzk); %#ok<AGROW>
end
fprintf('  reading: with ESR the output takes an INSTANTANEOUS step (the duty feed-through\n');
fprintf('  through the ESR, Dd = -ESR*iL/(1+ESR/R) = %.3f V per unit duty) and then keeps\n', ...
    -p.ESR*boost_steady(p,d0).iL/(1+p.ESR/p.R));
fprintf('  falling for ~%.0f us (about 1/wz = %.0f us); with ESR removed only the slower\n', ...
    S3(1).tmin*1e6, 1e6/r.fzRHP);
fprintf('  RHP reversal remains. Both are real; only the second one is the RHP zero.\n');

%% ---------- 4) bandwidth constraint ----------
% Two different limits show up here and they must not be confused:
%   (a) the LC resonance (f0 = 243 Hz, Q = 3.6): a PI has no phase lead, so once
%       the loop crosses near f0 the phase is already -160 deg. Measured: the PI
%       loop crosses 0 dB TWICE and the second crossing sits at 270-330 Hz with
%       PM = 15-38 deg. A single PI therefore cannot be given a useful bandwidth.
%   (b) the RHP zero: with the resonance handled by an inner current loop, the
%       outer loop is well behaved and the bandwidth can be pushed until the RHP
%       zero takes its phase. This is where fz actually binds.
fprintf('\n--- 4a) architecture A (single PI): where does it actually cross? ---\n');
fprintf('%7s %7s %6s %6s %6s\n','fcReq','fcAct','cross','PM','GM');
POLE = struct('fcReq',{},'fcAct',{},'PM',{},'GM',{},'nCross',{});
for fc = [60 100 150 200 300]
    c = boost_design(p, 'A', fc);
    fprintf('%7d %7.0f %6d %6.1f %6.1f\n', fc, c.fcActual, c.nCross, c.PM, c.GM);
    POLE(end+1) = struct('fcReq',fc,'fcAct',c.fcActual,'PM',c.PM,'GM',c.GM,'nCross',c.nCross); %#ok<AGROW>
end
fprintf('  => every A design has TWO 0 dB crossings and PM <= %.0f deg: the PI has no\n', ...
    max([POLE.PM]));
fprintf('     phase lead to spend at the resonance. This is a property of the\n');
fprintf('     ARCHITECTURE, not of the RHP zero (which is 17x above f0 here).\n');

fprintf('\n--- 4b) architecture B (inner current loop): how far can fc go? ---\n');
fprintf('  delay 1.5 periods = %.0f us, PM/GM measured on the numeric loop gain.\n', 1.5*Ts*1e6);
fprintf('%7s %7s %7s %6s %6s %8s %8s %9s %6s | %s\n','fcReq','fcAct','fz/fc','PM','GM','lineDip%','dip %','S5load ms','Kci','verdict');
FC = [300 500 650 800 1000 1200 1400 1600 2000];
BW = struct('fcReq',{},'fcAct',{},'ratio',{},'PM',{},'GM',{},'os',{},'lineDip',{},'dip',{}, ...
    's5',{},'Kci',{},'verdict',{});
for q = 1:numel(FC)
    c = boost_design(p, 'B', FC(q));
    % 100 % -> 150 % load step. A 2x step needs iL = 8.18 A at the input, which
    % is ABOVE Imax = 8 A, so the current clamp (not the controller) would decide
    % the response -- measured: every 2x case ended outside the band and reported
    % settleMs = NaN. That is a real finding about the OCP headroom, not a metric
    % artefact, and it is why the step here is 1.5x.
    o = struct('ratio',1.5,'tStep',0.02,'tEnd',0.06,'nSub',200,'nDly',1);
    rr = boost_avg_sim(p, c, o);
    sm = step_metrics(rr.t, rr.vOut, p.Vref, o.tStep, 1);
    o2 = o; o2.ratio = 1; o2.VinStep = -2;        % -2 V line step
    rr2 = boost_avg_sim(p, c, o2);
    % a line step must be reported on BOTH sides: the excursion is a dip for a
    % lower input, and an "overshoot only" metric reads 0.04 % and hides it
    os = (max(rr2.vOut) - p.Vref)/p.Vref*100;
    lDip = (min(rr2.vOut) - p.Vref)/p.Vref*100;
    ok = c.PM >= 45 && c.GM >= 8 && abs(sm.dipPct) <= 10 && isfinite(sm.settleMs);
    vd = tern(ok,'usable','rejected');
    fprintf('%7d %7.0f %7.1f %6.1f %6.1f %8.3f %8.2f %9.4f %6.2f | %s\n', FC(q), c.fcActual, ...
        r.fzRHP/c.fcActual, c.PM, c.GM, lDip, sm.dipPct, sm.settleMs, c.Kci, vd);
    BW(end+1) = struct('fcReq',FC(q),'fcAct',c.fcActual,'ratio',r.fzRHP/c.fcActual, ...
        'PM',c.PM,'GM',c.GM,'os',os,'lineDip',lDip,'dip',sm.dipPct,'s5',sm.settleMs, ...
        'Kci',c.Kci,'verdict',vd); %#ok<AGROW>
end
okBW = BW(strcmp({BW.verdict},'usable'));
fprintf('\n  usable crossover range (B): %.0f .. %.0f Hz ; fz = %.0f Hz\n', ...
    min([okBW.fcAct]), max([okBW.fcAct]), r.fzRHP);
fprintf('  => fc <= fz/%.1f for PM >= 45 deg. The RHP zero costs -%.1f deg at that\n', ...
    r.fzRHP/max([okBW.fcAct]), atand(max([okBW.fcAct])/r.fzRHP));
fprintf('     crossover, while the LC resonance (already handled by the inner loop)\n');
fprintf('     costs nothing there. That is the measured reason for the fz/4 rule here --\n');
fprintf('     and it only becomes the binding limit once the architecture allows it.\n');

fprintf('\n  delay sensitivity at fc = 800 Hz (B):\n');
fprintf('%10s %8s %8s\n','Td periods','PM','GM');
DL = struct('Td',{},'PM',{},'GM',{});
for tp = [0.5 1.5 2.5 3.5]
    c = boost_design(p, 'B', 800, struct('TdPeriods',tp));
    fprintf('%10.1f %8.1f %8.1f\n', tp, c.PM, c.GM);
    DL(end+1) = struct('Td',tp,'PM',c.PM,'GM',c.GM); %#ok<AGROW>
end

%% ---------- 5) figure ----------
c650 = boost_design(p, 'B', 650);
f = figure('Visible','off','Position',[80 80 1000 700]);

subplot(2,2,1);
w = logspace(log10(2*pi*50), log10(2*pi*20e3), 1200);
Gvd = c650.plant;
mag = squeeze(abs(freqresp(Gvd,w))); ph = squeeze(angle(freqresp(Gvd,w)))*180/pi;
semilogx(w/(2*pi), 20*log10(mag)); grid on; hold on;
xline(r.fzRHP,'r--','RHP zero'); xline(r.f0,'k:','f0');
title('G_{vd} magnitude'); ylabel('dB'); xlabel('Hz');

subplot(2,2,2);
semilogx(w/(2*pi), ph); grid on; hold on;
xline(r.fzRHP,'r--','RHP zero');
title('G_{vd} phase (note the extra lag from the RHP zero)'); ylabel('deg'); xlabel('Hz');

subplot(2,2,3);
Lm = 20*log10(abs(c650.L)); Lp = unwrap(angle(c650.L))*180/pi;
semilogx(c650.w/(2*pi), Lm); grid on; hold on;
semilogx(c650.w/(2*pi), Lp);
xline(c650.fcActual,'k--',sprintf('fc=%.0f Hz',c650.fcActual));
legend('|L| dB','angle L deg','Location','southwest');
title(sprintf('loop gain, PM=%.1f deg, GM=%.1f dB', c650.PM, c650.GM));

subplot(2,2,4);
semilogx(Dv, fzD); grid on; hold on;
semilogx(Dv, fzD*0+650,'k--');
xlabel('duty D'); ylabel('fz Hz'); title('RHP zero vs duty (dashed = 650 Hz design)');

print(f,'-dpng','-r110',fullfile(outDir,'b1_rhp_summary.png'));
close(f);

res = struct('level','3B.1-Task2','grid',Z,'maxDeviationPct',maxDev, ...
    'fzRHP',r.fzRHP,'f0',r.f0,'Qmodel',Qdesign, ...
    'sensitivity',struct('D',Dv,'fzD',fzD,'R',Rv,'fzR',fzR,'L',Lv,'fzL',fzL), ...
    'dutyStep',S3,'bandwidth',BW,'delaySensitivity',DL, ...
    'usableFcHz',[min([okBW.fcAct]) max([okBW.fcAct])],'archA',POLE, ...
    'note',['fc limit is measured on the loop gain including a 1.5-period delay; ' ...
            'the RHP zero is identified by the SIGN of its real part, not by being "the zero"']);
save(fullfile(outDir,'b1_task2_rhp.mat'),'res');
fid = fopen(fullfile(outDir,'b1_task2_rhp.json'),'w');
if fid >= 0, fwrite(fid, jsonencode(res), 'char'); fclose(fid); end
fprintf('\nsaved b1_task2_rhp.json/.mat/png\n');
end

% ---------------------------------------------------------------------------
function [t, v, iL] = duty_step(p, d0, dd, tStep, tEnd)
% open-loop average model with a duty step; RK4, fine steps
Ts = 1/p.fs; h = Ts/200;
nPer = round(tEnd/Ts); n = nPer*200;
t = zeros(n,1); v = zeros(n,1); iL = zeros(n,1);
xs = boost_steady(p, d0); x = [xs.iL; xs.vC];
for k = 1:n
    tt = (k-1)*h;
    d = d0 + dd*(tt >= tStep);
    k1 = boost_avg_f(x,d,p); k2 = boost_avg_f(x+0.5*h*k1,d,p);
    k3 = boost_avg_f(x+0.5*h*k2,d,p); k4 = boost_avg_f(x+h*k3,d,p);
    x = x + (h/6)*(k1+2*k2+2*k3+k4);
    x(1) = max(x(1),0);
    t(k) = tt+h; iL(k) = x(1); v(k) = boost_avg_out(x,d,p.Vin,p);
end
end

function s = tern(c,a,b)
if c, s = a; else, s = b; end
end
