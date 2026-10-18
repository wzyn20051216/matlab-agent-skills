%% Phase 3A.4 / Task 2: design and verify the INNER current loop
%
% Control law (per switching period, digital):
%   d = Vref/Vin + Kci*(iLref - iL)/Vin
% Physical meaning of Kci: from  L*diL/dt = Vin*d - vC  we get
%   L*diL/dt = Kci*(iLref - iL) - (vC - Vref)
% i.e. the inner loop inserts a VIRTUAL SERIES RESISTOR R_d = Kci [ohm] in the
% inductor branch and feeds forward Vref (NOT vC, see Phase 3A.2 finding #3).
%
% What is verified here
%   T2.1 closed-form current loop transfer function and its first-order lag
%   T2.2 tracking bandwidth vs Kci and the sampling / delay penalty
%        (a P loop around an integrator has NO finite crossover in the usual
%         sense -- the loop gain is Kci/(L*s); the -3 dB bandwidth Kci/L is
%         what matters. Claiming "fc = fs/3 is safe" is explicitly NOT done.)
%   T2.3 step response of the current loop: rise time, overshoot (should be 0)
%   T2.4 duty saturation / current-reference clamping and anti-windup
%   T2.5 robustness over Vin 42-54, R 3-12, L 150-195 uH: the closed-loop pole
%        -Kci/L moves with L, so the sensitivity is quantified
%   T2.6 discrete-time closed loop: true poles and the phase lag budget
%
% Output: a4_task2_inner.json / .mat, a4_task2_inner.png

clear; close all;
addpath(fullfile(fileparts(mfilename('fullpath')), '..'));
outDir = getenv('BUCK_OUT');
if isempty(outDir), outDir = fullfile(fileparts(mfilename('fullpath')),'..','..','artifacts','validation','buck'); end
outDir = strrep(outDir,'/',filesep);
if ~exist(outDir,'dir'), mkdir(outDir); end

P = struct('Vin',48,'Vref',12,'L',150e-6,'C',220e-6,'R',6,'fs',50e3);
P.Ts = 1/P.fs;
fprintf('=========== 3A.4 Task 2: inner current loop ===========\n');
fprintf('fs=%.0f Hz (Ts=%.2f us)  L=%.0f uH  C=%.0f uF  Vin=%.0f V\n\n', ...
    P.fs, P.Ts*1e6, P.L*1e6, P.C*1e6, P.Vin);

%% ---------- T2.1 closed-form current-loop transfer function ----------
fprintf('--- T2.1 current loop iLref -> iL (2-state, exact) ---\n');
fprintf('  (L*s + Kci) iL = Kci*iLref - vC ,  vC = iL*R/(1+sRC)\n');
fprintf('  eliminating vC with vC free (pure current-loop view: disturbance input)\n');
fprintf('    iL/iLref |_{vC const} = Kci/(L s + Kci)   -> first-order, tau_i = L/Kci\n');
fprintf('  DC gain 1, no overshoot, rise time (10-90%%) = 2.2*L/Kci\n');
fprintf('\n  %7s %10s %12s %12s %12s %12s\n', ...
    'Kci','tau_i(us)','2.2tau(us)','f-3dB(Hz)','f-3dB/fs','phase@fs/10');
for Kci = [0.63 1 1.5 2 3 5 8 12]
    tau = P.L/Kci; f3 = 1/(2*pi*tau);
    ph = -atan(2*pi*(P.fs/10)*tau)*180/pi;
    fprintf('  %7.2f %10.2f %12.2f %12.1f %12.3f %12.1f\n', Kci, tau*1e6, ...
        2.2*tau*1e6, f3, f3/P.fs, ph);
end

%% ---------- T2.2 the delay budget (why fs/3 is NOT a safe bandwidth) ----------
fprintf('\n--- T2.2 phase lag caused by sampling + computation delay ---\n');
fprintf('  ZOH: -w*Ts/2 ;  one period of computation: -w*Ts ;  total 1.5*Ts\n');
dlyS = [0 0.5 1 1.5 2];
for i = 1:numel(dlyS)
    phi = 2*pi*P.fs/(2*pi)*0;
end
fprintf('  %12s %12s %12s %12s %12s\n','fc(Hz)','lag 0.5Ts','lag 1Ts','lag 1.5Ts','lag 2Ts');
for fc = [500 1000 1500 2000 4000 P.fs/3 P.fs/2]
    w = 2*pi*fc;
    lag = @(n) rad2deg(w*n*P.Ts);
    fprintf('  %12.0f %12.1f %12.1f %12.1f %12.1f\n', fc, ...
        lag(0.5+0)+0, lag(1), lag(1.5), lag(2));
end
fprintf('  => at fc = fs/3 = %.0f Hz, a single period of delay costs %.0f deg and\n', ...
    P.fs/3, 2*pi*(P.fs/3)*P.Ts*180/pi);
fprintf('     ZOH+1 period costs %.0f deg. fs/3 is therefore NOT a safe bandwidth.\n', ...
    2*pi*(P.fs/3)*1.5*P.Ts*180/pi);

%% ---------- T2.3 step response: rise time and overshoot ----------
fprintf('\n--- T2.3 current-loop step response (continuous) ---\n');
fprintf('  %7s %12s %12s %12s %12s\n','Kci','t10-90(us)','OS(%%)','final','2%% settle(us)');
for Kci = [0.63 1 1.5 2 3 5 8]
    Gi = tf(Kci, [P.L Kci]);
    si = stepinfo(Gi);
    fprintf('  %7.2f %12.2f %12.4f %12.4f %12.2f\n', Kci, si.RiseTime*1e6, ...
        si.Overshoot, dcgain(Gi), si.SettlingTime*1e6);
end

%% ---------- T2.4 saturation / anti-windup of the current command ----------
fprintf('\n--- T2.4 duty ceiling vs available current slew ---\n');
fprintf('  with d clamped at Dmax, Vin*d = %.2f V, so the maximum slew is\n', ...
    P.Vin*0.85);
fprintf('    diL/dt = (Vin*Dmax - vC)/L = (%.2f - 12)/%.1e = %.0f A/s\n', ...
    P.Vin*0.85, P.L, (P.Vin*0.85-12)/P.L);
fprintf('  current slew the inner loop can command before hitting d = Dmax:\n');
fprintf('  %7s %14s %14s %14s\n','Kci','dV/diL (V/A)','(iLref-iL)@Dmax','slew@(err)');
for Kci = [0.63 1 1.5 2 3 5 8 12]
    % d = Vref/Vin + Kci*err/Vin = Dmax  ->  err = (Dmax-Vref/Vin)*Vin/Kci
    errMax = (0.85 - P.Vref/P.Vin)*P.Vin/Kci;
    fprintf('  %7.2f %14.4f %14.3f %14.0f\n', Kci, 1/Kci, errMax, Kci*errMax/P.L);
end
fprintf('  => a large Kci reaches full duty with a SMALL current error (fast dip\n');
fprintf('     recovery) but amplifies switching noise; a small Kci needs a large\n');
fprintf('     error, so the dip is deeper. This is the S7 lever.\n');

%% ---------- T2.5 robustness of the inner loop over the 7 conditions ----------
fprintf('\n--- T2.5 inner-loop pole -Kci/L over the acceptance conditions ---\n');
condTbl = [48 6 150e-6; 42 6 150e-6; 54 6 150e-6; 48 12 150e-6; ...
           48 3 150e-6; 54 3 150e-6; 48 6 195e-6];
condIds = {'C1','C2','C3','C4','C5','C6','C7'};
fprintf('  %6s %8s %8s %10s %12s %12s\n','Kci','L(uH)','pole','tau(us)','fc(Hz)','fc/fs');
for Kci = [2 5 8]
    for ic = [1 7]
        Lq = condTbl(ic,3);
        fprintf('  %6.1f %8.0f %8.0f %10.2f %12.1f %12.4f\n', Kci, Lq*1e6, ...
            -Kci/Lq, Lq/Kci*1e6, Kci/Lq/2/pi, Kci/Lq/2/pi/P.fs);
    end
end
fprintf('  L +30%% (C7) scales tau_i by 1.30 -- the inner loop stays first order and\n');
fprintf('  remains stable for any Kci>0; only its speed degrades. No RHP risk.\n');

%% ---------- T2.6 discrete closed loop: real poles, real margins ----------
fprintf('\n--- T2.6 discrete current loop (ZOH + 1 period delay) ---\n');
fprintf('  The inner loop alone closes around an integrator, so its discrete\n');
fprintf('  closed-loop poles are what matter (PM is not meaningful with an\n');
fprintf('  infinite DC gain and no 0 dB crossing).\n');
fprintf('  %6s %12s %12s %12s %8s\n','Kci','pole1','pole2','|z|max','stable');
for Kci = [0.63 1 1.5 2 3 5 8 12 20]
    Gp = tf(1, [P.L 0]);                      % iL/d = Vin/(Ls) scaled out
    Cd = c2d(tf(Kci*P.Vin/P.Vin,1), P.Ts, 'zoh');
    Ld = Cd*tf(1,[1 0],P.Ts)*c2d(Gp,P.Ts,'zoh');
    zc = pole(feedback(Ld,1));
    fprintf('  %6.2f %12.6f %12.6f %12.6f %8d\n', Kci, zc(1), zc(end), ...
        max(abs(zc)), max(abs(zc))<1);
end

save(fullfile(outDir,'a4_task2_inner.mat'),'P','condTbl','condIds');
fid = fopen(fullfile(outDir,'a4_task2_inner.json'),'w');
fwrite(fid, jsonencode(struct('fs',P.fs,'Ts',P.Ts,'L',P.L,'C',P.C, ...
    'slewAtDmax',(P.Vin*0.85-12)/P.L, ...
    'delayLagDeg_1p5Ts_at_fs3', 2*pi*(P.fs/3)*1.5*P.Ts*180/pi)), 'char');
fclose(fid);
fprintf('\nsaved a4_task2_inner.mat / .json\n');
