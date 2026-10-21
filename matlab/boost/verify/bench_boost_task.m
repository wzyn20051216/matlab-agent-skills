function res = bench_boost_task(outDir)
%BENCH_BOOST_TASK  The fixed task used by the Phase 3B.2 agent benchmark.
%
% NATURAL-LANGUAGE SPEC (given to each route verbatim):
%   "For the 48 V / 96 W Boost with Vin = 20 V, L = 220 uH, C = 470 uF,
%    50 kHz and the conduction losses in boost_params.m:
%      (1) compute the loss-inclusive duty, the steady inductor current, the
%          peak current and the RHP zero frequency,
%      (2) run a 30 ms switching simulation at that operating point and report
%          the mean output voltage and the inductor ripple,
%      (3) state whether the output is within 0.5 % of 48 V."
%
% WHY THIS TASK
% It is small enough to run in a few seconds, but it touches every part of the
% toolchain: closed-form model, operating point, ripple, RHP zero, switching
% simulation, and a numeric verdict. A route that can only write prose cannot
% produce the numbers; a route that can run code must still get the model right.
%
% The script is written to be run ONCE and to print a PASS/FAIL line, so a route's
% first-attempt success is observable rather than claimed.

if nargin < 1 || isempty(outDir), outDir = getenv('BOOST_OUT'); end
if isempty(outDir), outDir = fullfile(pwd,'artifacts','validation','boost_b2'); end
outDir = strrep(outDir,'/',filesep);
here = fileparts(mfilename('fullpath')); addpath(here);
if ~exist(outDir,'dir'), mkdir(outDir); end

t0 = tic;
p = boost_params('Vin',20);
dq = boost_duty_for(p, p.Vref);
st = boost_steady(p, dq);
rip = boost_ripple(p, dq);
% the controller's bias must be the duty of THIS operating point, otherwise the
% run starts from the 24 V equilibrium and burns the first 10 ms recovering
c = boost_design(p, 'B', 650);
c.D0 = dq; c.Imax = 8;
o = struct('ratio',1,'tStep',1,'tEnd',0.03,'nSub',200,'nDly',1,'noise',false);
r = boost_sw_sim(p, c, o);
q = r.t > 0.02;

out = struct();
out.Vin = p.Vin;
out.duty = dq;
out.iL = st.iL;
out.iLpk = rip.iLpk;
out.fzRHP = rip.fzRHP;
out.vOutMean = mean(r.vOut(q));
out.iLripple = mean(r.iLpeak(r.tPer > 0.02) - r.iLvalley(r.tPer > 0.02));
out.ssErrPct = 100*(out.vOutMean - p.Vref)/p.Vref;
out.withinTolerance = abs(out.ssErrPct) <= 0.5;
out.elapsedS = toc(t0);

fprintf('BENCH duty        = %.4f\n', out.duty);
fprintf('BENCH iL          = %.4f A\n', out.iL);
fprintf('BENCH iL peak     = %.4f A\n', out.iLpk);
fprintf('BENCH fz(RHP)     = %.1f Hz\n', out.fzRHP);
fprintf('BENCH vOut mean   = %.4f V (%.4f %%)\n', out.vOutMean, out.ssErrPct);
fprintf('BENCH iL ripple   = %.4f A\n', out.iLripple);
fprintf('BENCH within 0.5%% = %d\n', out.withinTolerance);
fprintf('BENCH elapsed     = %.2f s\n', out.elapsedS);
fprintf('BENCH RESULT: %s\n', tern(out.withinTolerance,'PASS','FAIL'));

save(fullfile(outDir,'bench_boost_task.mat'),'out');
fid = fopen(fullfile(outDir,'bench_boost_task.json'),'w');
if fid >= 0, fwrite(fid, jsonencode(out), 'char'); fclose(fid); end
res = out;
end

function s = tern(c,a,b)
if c, s = a; else, s = b; end
end
