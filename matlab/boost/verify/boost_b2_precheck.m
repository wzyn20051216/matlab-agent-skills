function res = boost_b2_precheck(outDir)
%BOOST_B2_PRECHECK  Phase 3B.2 Task 5: catch the failures BEFORE a long run.
%
%   res = boost_b2_precheck(outDir)
%
% WHY THIS EXISTS
% In Phase 3B.1 none of the five main scripts ran on the first attempt. Most of
% those failures were cheap to detect: a typo, a struct built with different
% fields, a mask applied to the wrong array, a block wired before it existed.
% This file runs the cheap checks first, in the order that fails fastest, so a
% 20-minute matrix is never started on a script that cannot compile.
%
% ORDER (deliberately cheap -> expensive)
%   1  static analysis (checkcode) on every Boost file
%   2  presence and signature of the functions the scripts depend on
%   3  numeric invariants that do not need a simulation
%   4  a 3 ms smoke run of each engine
%   5  the regression suite (which itself contains the defect guards)
%   6  the error classification of THIS phase, so the pattern is visible
%
% Every item is reported as PASS/FAIL with the measured value.

if nargin < 1 || isempty(outDir), outDir = getenv('BOOST_OUT'); end
if isempty(outDir), outDir = fullfile(pwd,'artifacts','validation','boost_b2'); end
outDir = strrep(outDir,'/',filesep);
here = fileparts(mfilename('fullpath'));
boostDir = fileparts(here);
addpath(boostDir); addpath(here);
addpath(fullfile(fileparts(boostDir),'buck'));
if ~exist(outDir,'dir'), mkdir(outDir); end

res = struct('level','3B.2-Task5');
fprintf('===== Phase 3B.2 Task 5: precheck =====\n');

%% 1) static analysis
fprintf('\n--- 1) static analysis (checkcode) ---\n');
files = [dir(fullfile(boostDir,'*.m')); dir(fullfile(here,'*.m'))];
nErr = 0; nWarn = 0; worst = {};
for k = 1:numel(files)
    f = fullfile(files(k).folder, files(k).name);
    try
        msgs = checkcode(f,'-m0');   % -m0: no "this line is fine" noise
    catch
        msgs = [];
    end
    for q = 1:numel(msgs)
        if msgs(q).line <= 0      % file-level message: the file does not parse
            nErr = nErr + 1;
            worst{end+1} = sprintf('%s:%d %s', files(k).name, msgs(q).line, msgs(q).message); %#ok<AGROW>
        else
            nWarn = nWarn + 1;
        end
    end
end
fprintf('  files scanned %d ; syntax-level findings %d ; other findings %d\n', ...
    numel(files), nErr, nWarn);
res.static = struct('files',numel(files),'errors',nErr,'warnings',nWarn);
if ~isempty(worst)
    for k = 1:min(5,numel(worst)), fprintf('    %s\n', worst{k}); end
end

%% 2) presence and signatures
fprintf('\n--- 2) function presence ---\n');
need = {'boost_params','boost_steady','boost_avg_f','boost_avg_out','boost_avg_lin', ...
        'boost_duty_for','boost_ripple','boost_tf','boost_design','boost_designs', ...
        'boost_margins','boost_op_point','boost_run_metrics','boost_avg_sim', ...
        'boost_sw_sim','build_boost_avg','build_boost_switching'};
missing = {};
for k = 1:numel(need)
    if exist(need{k},'file') ~= 2, missing{end+1} = need{k}; end %#ok<AGROW>
end
fprintf('  required %d ; missing %d %s\n', numel(need), numel(missing), strjoin(missing,','));
res.presence = struct('required',numel(need),'missing',{missing});

%% 3) numeric invariants (no simulation)
fprintf('\n--- 3) numeric invariants ---\n');
p = boost_params();
d0 = boost_duty_for(p, p.Vref);
st = boost_steady(p, d0);
inv = struct();
inv.dutyDeliversSetpoint = abs(st.vOut - p.Vref) < 1e-9;
inv.steadyResidual = st.residual;
inv.steadyIsEquilibrium = st.residual < 1e-6;
% the linearisation must reproduce the analytic DC gain
M = boost_avg_lin(p, d0);
Gdc = -M.Cy*(M.A\M.Bd) + M.Dd;
% CENTRAL difference: a one-sided difference with h=1e-3 carries a 0.2 % second
% order bias here, which is larger than the tolerance and would fail for the
% wrong reason.
h = 1e-3;
sp = boost_steady(p, d0+h); smn = boost_steady(p, d0-h);
inv.dcGainNumeric = Gdc;
inv.dcGainFiniteDiff = (sp.vOut - smn.vOut)/(2*h);
inv.dcGainMatches = abs(Gdc - inv.dcGainFiniteDiff)/abs(Gdc) < 1e-3;
% the RHP zero must match R(1-D)^2/L
rip = boost_ripple(p, d0);
[zz,~] = zero(tf(ss(M.A,M.Bd,M.Cy,M.Dd)));
zr = zz(real(zz)>0);
inv.fzRHPmodel = max(real(zr))/(2*pi);
inv.fzRHPformula = rip.fzRHP;
inv.fzMatches = abs(inv.fzRHPmodel/inv.fzRHPformula - 1) < 0.02;
% CCM at the design point
inv.ccmAtDesign = rip.iLvalley > 0;
fprintf('  duty->setpoint %.6f V ; residual %.2e ; DC gain %.4f vs %.4f\n', ...
    st.vOut, inv.steadyResidual, inv.dcGainNumeric, inv.dcGainFiniteDiff);
fprintf('  fz model %.1f Hz vs formula %.1f Hz ; CCM at design %d\n', ...
    inv.fzRHPmodel, inv.fzRHPformula, inv.ccmAtDesign);
inv.pass = inv.dutyDeliversSetpoint && inv.steadyIsEquilibrium && ...
    inv.dcGainMatches && inv.fzMatches && inv.ccmAtDesign;
res.invariants = inv;

%% 4) smoke runs
fprintf('\n--- 4) smoke runs (3 ms) ---\n');
[dA,~] = boost_designs(p, 650);
sm = struct();
t0 = tic;
ra = boost_avg_sim(p, dA, struct('ratio',1,'tStep',1,'tEnd',0.003,'nSub',100,'nDly',1));
sm.avgVout = mean(ra.vOut(ra.t > 0.002));   % last 1 ms, not the start-up
% 1 %, not 0.1 %: the controller starts with xI = 0 while iL is already at its
% operating value, so the first ~0.8 ms is a real start-up transient in BOTH
% engines. The smoke test asks "did it run and land near the setpoint", not "did
% it settle", because a 3 ms window cannot answer the second question.
sm.avgOK = abs(sm.avgVout - p.Vref)/p.Vref < 0.01;
rs = boost_sw_sim(p, dA, struct('ratio',1,'tStep',1,'tEnd',0.003,'nSub',200,'nDly',1));
sm.swVout = mean(rs.vOut(rs.t>0.002));
sm.swOK = abs(sm.swVout - p.Vref)/p.Vref < 0.01;
sm.elapsedS = toc(t0);
fprintf('  avg vOut %.4f V ; sw vOut %.4f V ; %.2f s\n', sm.avgVout, sm.swVout, sm.elapsedS);
sm.pass = sm.avgOK && sm.swOK;
res.smoke = sm;

%% 5) regression suite
fprintf('\n--- 5) regression suite ---\n');
rg = boost_b2_regression(false);
fprintf('  %d / %d passed\n', rg.nPass, rg.nTest);
res.regression = struct('pass',rg.pass,'nPass',rg.nPass,'nTest',rg.nTest, ...
    'failed',{{rg.results(~[rg.results.pass]).id}});

%% 6) error classification of this phase
fprintf('\n--- 6) failures observed in Phase 3B.2, classified ---\n');
E = [ ...
 e('nDly=0 -> badsubscript (empty duty history)','dimension/indexing','dPrev register, regression R1'); ...
 e('struct built with a field the prealloc lacks (x2)','struct/API','add the field, R9 covers the grader'); ...
 e('per-period mask applied to a waveform array (silent)','indexing (silent)','two masks + helper, R7'); ...
 e('dcmFrac overwritten by a scalar','regression from a patch','separate dcmFracTotal, R3'); ...
 e('Simulink Unit Delay starts at 0','model','InitialCondition = D0'); ...
 e('load step multiplied R by ratio instead of dividing','model','R/ratio, matches o.ratio'); ...
 e('add_line before the source block exists','Simulink API','create states/delays first'); ...
 e('absolute vs relative signal paths in add_line','Simulink API','relative names'); ...
 e('step check graded the MEASURED current change','acceptance logic','nominal step, R8'); ...
 e('cls() applied to higher-is-better margins','acceptance logic','clsHi'); ...
 e('s5w used outside its scope','syntax','local variable'); ...
 e('fprintf format/arg count mismatch','syntax','count specifiers'); ...
 e('duty scalar passed where a controller struct is expected','model/API','build the controller') ];
fprintf('  %-52s %-22s %s\n','failure','category','guard');
for k = 1:numel(E)
    fprintf('  %-52s %-22s %s\n', E(k).what, E(k).category, E(k).guard);
end
cats = unique({E.category});
cnt = zeros(1,numel(cats));
for k = 1:numel(cats), cnt(k) = nnz(strcmp({E.category},cats{k})); end
for k = 1:numel(cats), fprintf('    %-22s %d\n', cats{k}, cnt(k)); end
res.errorStats = struct('items',E,'categories',{cats},'counts',cnt, ...
    'total',numel(E));

%% verdict
allOK = (nErr == 0) && isempty(missing) && inv.pass && sm.pass && rg.pass;
fprintf('\nPRECHECK: %s\n', ternary(allOK,'PASS','FAIL'));
res.pass = allOK;

save(fullfile(outDir,'b2_precheck.mat'),'res');
fid = fopen(fullfile(outDir,'b2_precheck.json'),'w');
if fid >= 0, fwrite(fid, jsonencode(res), 'char'); fclose(fid); end
end

function s = e(what, cat, guard)
s = struct('what',what,'category',cat,'guard',guard);
end

function s = ternary(c,a,b)
if c, s = a; else, s = b; end
end
