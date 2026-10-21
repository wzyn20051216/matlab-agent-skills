function res = boost_b2_regression(verbose)
%BOOST_B2_REGRESSION  Regression tests for every defect fixed in Phase 3B.2.
%
%   res = boost_b2_regression()
%
% Each test names the defect it guards. If a future change reintroduces it, the
% test fails with the measured value, not with a stack trace from inside a
% simulation.
%
%   R1  average model accepts nDly = 0 (it used to index an empty duty history)
%   R2  average model REPORTS DCM instead of reporting 48.000 V inside DCM
%   R3  switching model reports DCM as invalid
%   R4  load-current feedforward uses the load current, not the regulated iL
%   R5  margins evaluate every crossing (single loop @300 Hz crosses 0 dB twice)
%   R6  margins catch a negative phase margin (single loop @650 Hz)
%   R7  metrics: the command is measured on the waveform window, not the first
%       1.5 ms (the mask-mismatch bug that reported iLref = 0)
%   R8  the acceptance step check is non-circular (nominal step from the R change)
%   R9  the grader accepts a good record and rejects a bad one
%   R10 D0 is the loss-inclusive duty, not 0.5

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
addpath(fileparts(here));
addpath(fullfile(fileparts(fileparts(here)),'buck'));
p = boost_params();
[dA, ~] = boost_designs(p, 650);

T = struct('id',{},'name',{},'pass',{},'detail',{});

% ---- R1 ----
try
    r = boost_avg_sim(p, dA, struct('ratio',1,'tStep',0.02,'tEnd',0.02, ...
        'nSub',100,'nDly',0));
    v = mean(r.vOut(r.t>0.015));
    T(end+1) = rec('R1','average model accepts nDly = 0', abs(v-p.Vref)<1e-3, ...
        sprintf('vOut %.6f V', v)); %#ok<AGROW>
catch ME
    T(end+1) = rec('R1','average model accepts nDly = 0', false, ME.message); %#ok<AGROW>
end

% ---- R2 ----
pp = p; pp.R = 400; pp.Pout = pp.Vref^2/pp.R;
r = boost_avg_sim(pp, dA, struct('ratio',1,'tStep',0.02,'tEnd',0.05,'nSub',100,'nDly',1));
T(end+1) = rec('R2','average model flags DCM at R = 400 ohm', ...
    ~r.valid && contains(r.invalidReason,'DCM'), ...
    sprintf('valid %d, reason "%s"', r.valid, r.invalidReason)); %#ok<AGROW>

% ---- R3 ----
rs = boost_sw_sim(pp, dA, struct('ratio',1,'tStep',0.02,'tEnd',0.05,'nSub',200,'nDly',1));
T(end+1) = rec('R3','switching model flags DCM at R = 400 ohm', ...
    ~rs.valid && rs.dcmTime > 0, ...
    sprintf('DCM %.2f %% of run, valid %d', 100*rs.dcmFracTotal, rs.valid)); %#ok<AGROW>

% ---- R4 ----
c0 = dA; c0.ff = 0; c1 = dA; c1.ff = 1;
o = struct('ratio',1,'tStep',0.02,'tEnd',0.04,'nSub',100,'nDly',1);
a0 = boost_avg_sim(p, c0, o); a1 = boost_avg_sim(p, c1, o);
d0 = mean(a0.vOut(a0.t>0.03)); d1 = mean(a1.vOut(a1.t>0.03));
T(end+1) = rec('R4','feedforward does not bias the steady state', abs(d1-d0)<1e-3, ...
    sprintf('ff=0 %.5f V, ff=1 %.5f V, diff %.2e', d0, d1, abs(d1-d0))); %#ok<AGROW>

% ---- R5 ----
cA300 = boost_design(p,'A',300);
T(end+1) = rec('R5','margins evaluate every crossing', cA300.nCross == 2, ...
    sprintf('%d down-crossings at %s Hz, PMs %s deg, worst %.1f deg', cA300.nCross, ...
    mat2str(round([cA300.crossDetail(strcmp({cA300.crossDetail.kind},'down')).f])), ...
    mat2str(round([cA300.crossDetail(strcmp({cA300.crossDetail.kind},'down')).pm],1)), ...
    cA300.PM)); %#ok<AGROW>

% ---- R6 ----
cA650 = boost_design(p,'A',650);
T(end+1) = rec('R6','negative phase margin is caught', ...
    cA650.PM < 0 && ~cA650.marginsOK, ...
    sprintf('PM %.1f deg at %.0f Hz, marginsOK %d', cA650.PM, cA650.fcActual, cA650.marginsOK)); %#ok<AGROW>

% ---- R7 ----
o = struct('ratio',1.5,'tStep',0.02,'tEnd',0.06,'nSub',200,'nDly',1, ...
           'noise',true,'seed',11);
r = boost_sw_sim(p, dA, o);
m = boost_run_metrics(r, p, o);
direct = mean(r.iLref(r.t>=0.012 & r.t<0.02));
T(end+1) = rec('R7','command measured on the right window', ...
    abs(m.iLrefPre-direct) < 1e-12 && m.iLrefPre > 1, ...
    sprintf('helper %.4f A, direct %.4f A', m.iLrefPre, direct)); %#ok<AGROW>

% ---- R8 ----
nomStep = p.Vref*(1/16 - 1/24);
T(end+1) = rec('R8','step check is non-circular', abs(nomStep-1) < 1e-9, ...
    sprintf('nominal step %.4f A from R 24 -> 16 ohm', nomStep)); %#ok<AGROW>

% ---- R9 ----
bad = struct('ssErr',9.9,'iLrippleA',0,'ripplePct',0,'dip',0,'s5',0, ...
    'iLpkSS',1,'iLpkTr',1,'ccmValid',true);
good = struct('ssErr',0.2,'iLrippleA',0.5,'ripplePct',0.4,'dip',-1,'s5',0.5, ...
    'iLpkSS',4,'iLpkTr',7,'ccmValid',true);
okBad = grade_fake(bad, 8); okGood = grade_fake(good, 8);
T(end+1) = rec('R9','grader accepts good and rejects bad', (~okBad) && okGood, ...
    sprintf('bad -> %s, good -> %s', tern(okBad,'ACCEPT','REJECT'), ...
    tern(okGood,'ACCEPT','REJECT'))); %#ok<AGROW>

% ---- R10 ----
ok = abs(dA.D0 - 0.511058) < 1e-5 && abs(boost_steady(p,dA.D0).vOut - 48) < 1e-6;
T(end+1) = rec('R10','D0 is the loss-inclusive duty', ok, ...
    sprintf('D0 %.6f -> %.6f V', dA.D0, boost_steady(p,dA.D0).vOut)); %#ok<AGROW>

nPass = sum([T.pass]); nFail = numel(T) - nPass;
if verbose
    fprintf('=== Phase 3B.2 regression ===\n');
    for k = 1:numel(T)
        fprintf('  [%s] %-3s %s\n         %s\n', tern(T(k).pass,'PASS','FAIL'), ...
            T(k).id, T(k).name, T(k).detail);
    end
    fprintf('\n---- %d / %d checks passed ----\n', nPass, numel(T));
end
res = struct('nPass',nPass,'nFail',nFail,'nTest',numel(T),'results',T, ...
    'pass',nFail==0);
end

% ---------------------------------------------------------------------------
function s = rec(id, name, ok, detail)
s = struct('id',id,'name',name,'pass',logical(ok),'detail',detail);
end

function ok = grade_fake(m, Imax)
ok = abs(m.ssErr) <= 0.5 && m.iLrippleA <= 1.6362 && m.ripplePct <= 1.0 && ...
     m.iLpkSS <= 0.8*Imax && m.iLpkTr <= Imax && abs(m.dip) <= 5 && ...
     (m.s5 <= 2 || m.s5 == 0) && m.ccmValid;
end

function s = tern(c,a,b)
if c, s = a; else, s = b; end
end
