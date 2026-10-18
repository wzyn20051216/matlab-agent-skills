%% Quick decisive probe: does the dual loop survive sampling + computation delay?
% Continuous PM >= 50 is NOT evidence of digital stability (Phase 3A.4 brief).
% At fs = 50 kHz a 1.5-sample total delay costs phi = 1.5*Ts*wc.
%   wc = fs/3  -> phi = 1.5*(1/3)*2*pi = 180 deg   (!!)
%   wc = fs/10 -> phi = 54 deg
% so the usable bandwidth is far below fs/3.
%
% This script only answers "is there any feasible point at all" before we
% invest in the full design. Pure ASCII. No file is modified.

clear; close all;
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, '..'));
outDir = getenv('BUCK_OUT');
if isempty(outDir), outDir = fullfile(here,'..','..','artifacts','validation','buck'); end
outDir = strrep(outDir,'/',filesep);

P = struct('Vin',48,'Vref',12,'L',150e-6,'C',220e-6,'R',6,'fs',50e3);
P.Ts = 1/P.fs;
% 7 acceptance conditions: [Vin, R, L]
condTbl = [48 6 150e-6; 42 6 150e-6; 54 6 150e-6; 48 12 150e-6; ...
           48 3 150e-6; 54 3 150e-6; 48 6 195e-6];
condIds = {'C1','C2','C3','C4','C5','C6','C7'};

Gvfun = @(p,R,Kci) tf(Kci, [p.L*p.C, p.L/R + p.C*Kci, 1 + Kci/R]);

fprintf('=========== decisive probe: discrete PM of the dual loop ===========\n');
fprintf('if no point has PM_disc>=50 at all 7 conditions, the architecture fails.\n\n');
fprintf('%6s %7s %8s %10s %10s %10s %10s %8s\n', ...
    'Kci','Kp_e','Ki_e','PM_c_min','fc_min(Hz)','PM_d1_min','PM_d2_min','verdict');
rows = struct('Kci',{},'Kpe',{},'Kie',{},'pmcmin',{},'fcmin',{},'pmd1',{},'pmd2',{},'pass',{});
for Kci = [0.63 1 1.5 2 3 5 8]
  for Kpe = [0.2 0.5 1 1.5 2 2.5 3]
    for Kie = [200 500 1000 1500 2000 3000 4000 6000 8000]
      pmc = inf; fcm = inf; pmd1 = inf; pmd2 = inf;
      for ic = 1:7
        p = P; p.L = condTbl(ic,3); p.R = condTbl(ic,2); p.Vin = condTbl(ic,1);
        Gv = Gvfun(p, p.R, Kci);
        Cs = tf([Kpe Kie],[1 0]);
        Lc = minreal(Cs*Gv);
        [pmc_,~,wc] = margin_fast(Lc, 4000);
        pmc = min(pmc, pmc_); fcm = min(fcm, wc/2/pi);
        Gd = c2d(Gv, P.Ts, 'zoh'); Cd = c2d(Cs, P.Ts, 'zoh');
        for nd = 1:2
          if nd == 1, dly = tf(1,[1 0],P.Ts); else, dly = tf(1,[1 0 0],P.Ts); end
          Ld = Cd*dly*Gd;
          [pmd,gmd,~,~] = margin_fast(Ld, 4000);
          if nd == 1, pmd1 = min(pmd1, pmd); else, pmd2 = min(pmd2, pmd); end
        end
      end
      v = '';
      if pmd1 >= 50, v = 'PASS@1s'; end
      if pmd2 >= 50, v = 'PASS@2s'; end
      if ~isempty(v) || (pmd1 > 45 && pmd1 < 55)
        fprintf('%6.2f %7.2f %8.0f %10.2f %10.1f %10.2f %10.2f %8s\n', ...
            Kci, Kpe, Kie, pmc, fcm, pmd1, pmd2, v);
      end
      rows(end+1) = struct('Kci',Kci,'Kpe',Kpe,'Kie',Kie,'pmcmin',pmc, ...
          'fcmin',fcm,'pmd1',pmd1,'pmd2',pmd2,'pass',pmd1>=50);
    end
  end
end
pm1 = [rows.pmd1]; pm2 = [rows.pmd2];
fprintf('\ntotal grid points: %d\n', numel(rows));
fprintf('max PM_disc(1 sample) over the grid  = %.2f deg\n', max(pm1));
fprintf('max PM_disc(2 samples) over the grid = %.2f deg\n', max(pm2));
fprintf('points with PM_disc(1s) >= 50        : %d\n', sum(pm1>=50));
fprintf('points with PM_disc(2s) >= 50        : %d\n', sum(pm2>=50));
[~,ib] = max(pm1);
fprintf('best 1-sample point: Kci=%.2f Kp_e=%.2f Ki_e=%.0f -> PM_c=%.2f PM_d=%.2f\n', ...
    rows(ib).Kci, rows(ib).Kpe, rows(ib).Kie, rows(ib).pmcmin, rows(ib).pmd1);

save(fullfile(outDir,'a4_probe_disc.mat'),'rows','P','condTbl');
fprintf('\nsaved a4_probe_disc.mat\n');
