function buck_a6_regression(outDir)
%BUCK_A6_REGRESSION  Guard against "finite-time convergence = stability" coming back.
%
% Phase 3A.5 accepted the switching-level cases because the 60 ms simulation
% settled. This regression pins the replacement rule down with assertions that
% FAIL if that mistake is reintroduced.
%
%   R1  the period map reproduces the known operating point
%   R2  the Floquet multiplier agrees with the independent average-model pole
%   R3  a 50 mV perturbation decays at the predicted rate (validates the Jacobian)
%   R4  s1_verdict REJECTS a non-orbit with max|lambda| < 1  <-- the 3A.5 bug
%   R5  s1_verdict REJECTS a converged but repelling orbit
%   R6  end-to-end: two periods of delay must NOT be reported as PASS
%   R7  the map rejects a sampling phase it does not model (no silent mis-model)

if nargin < 1 || isempty(outDir), outDir = getenv('BUCK_OUT'); end
outDir = strrep(outDir,'/',filesep);
here = fileparts(mfilename('fullpath')); addpath(fileparts(here));

fprintf('=========== 3A.6 Task 1 regression ===========\n');
nPass = 0; nFail = 0;

%% R1 operating point
p = dual_params(48, 6, 150e-6, 'nDly', 1);
r = sw_floquet(p, struct('verbose', false));
% vOut at the sample instant must be the regulated value; iL must carry the load
vOut = (r.xstar(2) + p.ESR*r.xstar(1))/(1 + p.ESR/p.R);
ok = abs(vOut - 12) < 1e-3 && abs(r.xstar(1) - 1.387) < 0.05;   % ripple valley
fprintf('  vOut(x*) = %.6f V, iL(x*) = %.4f A\n', vOut, r.xstar(1));
[nPass,nFail] = rep('R1 period map reproduces the operating point', ok, nPass, nFail);

%% R2 Floquet vs average model
q = struct('Vin',48,'L',150e-6,'C',220e-6,'R',6,'Vref',12,'fs',50e3);
Gv = tf(dual_loop_gain(q, 6, p.Kci, p.Kpe, p.Kie, 1, 'plant'));
Ts = 1/p.fs;
Ld = c2d(tf([p.Kpe p.Kie],[1 0]),Ts,'zoh')*tf(1,[1 0],Ts)*c2d(Gv,Ts,'zoh');
maxAbsZ = max(abs(pole(feedback(Ld,1))));
dev = abs(r.maxAbs - maxAbsZ)/maxAbsZ*100;
fprintf('  max|lambda| = %.5f (switching) vs max|z| = %.5f (average model), dev %.2f %%\n', ...
    r.maxAbs, maxAbsZ, dev);
[nPass,nFail] = rep('R2 Floquet and average-model poles agree within 5 %', dev < 5, nPass, nFail);

%% R3 empirical decay matches the multiplier
dev2 = abs(r.lamEmp - r.maxAbs)/r.maxAbs*100;
fprintf('  empirical decay %.5f vs multiplier %.5f, dev %.2f %%\n', ...
    r.lamEmp, r.maxAbs, dev2);
[nPass,nFail] = rep('R3 perturbation decay matches the linearisation', dev2 < 5, nPass, nFail);

%% R4 the 3A.5 bug: a non-orbit with max|lambda| < 1 must NOT pass
[pass4, v4] = s1_verdict(false, 0.5);
fprintf('  s1_verdict(converged=false, max|lam|=0.50) -> %s\n', v4);
[nPass,nFail] = rep('R4 non-orbit with small multiplier is NOT a PASS', ~pass4, nPass, nFail);

%% R5 converged but repelling
[pass5, v5] = s1_verdict(true, 1.02);
fprintf('  s1_verdict(converged=true, max|lam|=1.02) -> %s\n', v5);
[nPass,nFail] = rep('R5 converged repelling orbit is NOT a PASS', ~pass5, nPass, nFail);

%% R6 end-to-end: two periods of delay
p2 = dual_params(48, 6, 150e-6, 'nDly', 2);
r2 = sw_floquet(p2, struct('verbose', false, 'maxIter', 1500));
[pass6, v6] = s1_verdict(r2.converged, r2.maxAbs);
fprintf('  nDly=2 : converged=%d max|lam|=%.5f -> %s\n', r2.converged, r2.maxAbs, v6);
[nPass,nFail] = rep('R6 two periods of delay does not pass S1', ~pass6, nPass, nFail);

%% R7 the map refuses a phase it does not model
threw = false;
try
    sw_period_map(zeros(5,1), dual_params(48,6,150e-6,'sampPhase',0.125));
catch
    threw = true;
end
[nPass,nFail] = rep('R7 map refuses an unsupported sampling phase', threw, nPass, nFail);

fprintf('\n通过 %d / 失败 %d（共 %d 项）\n', nPass, nFail, nPass+nFail);
res = struct('nPass',nPass,'nFail',nFail,'total',nPass+nFail, ...
    'maxAbsLam',r.maxAbs,'maxAbsZ',maxAbsZ,'lamEmp',r.lamEmp, ...
    'nDly2converged',r2.converged,'matlabVersion',version);
save(fullfile(outDir,'a6_regression.mat'),'res');
if nFail > 0, error('buck_a6_regression: %d assertion(s) failed', nFail); end
end

function [nP, nF] = rep(name, ok, nP, nF)
if ok
    fprintf('  [PASS] %s\n', name); nP = nP + 1;
else
    fprintf('  [FAIL] %s\n', name); nF = nF + 1;
end
end
