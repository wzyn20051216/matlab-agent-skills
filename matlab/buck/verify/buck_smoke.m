function ok = buck_smoke(verbose)
%BUCK_SMOKE  One-command install check for the Buck demo (about 40 s, base MATLAB).
%
%   ok = buck_smoke()          prints a table and returns true/false
%   buck_smoke                 same, with an error on failure
%
% WHY THIS FILE EXISTS
% A stranger who clones the repository needs ONE command that answers "is my
% MATLAB able to reproduce the published numbers?" without waiting ten minutes
% for the full acceptance matrix, and without reading the phase reports. It
% checks the smallest set that exercises the whole chain end to end:
%
%   dual_params -> sw_period_map -> sw_floquet      (stability machinery)
%   sw_dual_sim -> cfg_metrics -> step_metrics      (time-domain machinery)
%
% Every golden value below was measured on MATLAB R2026a with the frozen
% parameter set and is reproducible bit for bit (fixed seeds). Tolerances are
% wide enough for a different MATLAB release to pass and narrow enough that a
% broken model or a wrong parameter cannot.
%
% DEPENDENCIES: base MATLAB only (no toolbox). Verified with
%   matlab.codetools.requiredFilesAndProducts('buck_smoke')
% which reports MATLAB only for this entry point. The average-model design
% scripts do need Control System Toolbox; this check deliberately does not.

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
addpath(here);                 % this file
addpath(fileparts(here));      % the engine (sw_period_map, cfg_metrics, ...)
Vref = 12;
fprintf('=== Buck demo smoke test ===\n');
fprintf('MATLAB %s\n', version);

fail = {};
nChk = 0;
% ---- 1) period map fixed point and Floquet multiplier ----
p = dual_params(48,6,150e-6,'nDly',1);
rf = sw_floquet(p, struct('verbose',false,'maxIter',1500));
chk('S1 orbit found', rf.converged, true);
chk('max|lambda| (golden 0.96530)', rf.maxAbs, 0.96530, 0.002);

% ---- 2) load-step metrics with the ideal sensor ----
m = cfg_metrics(p, struct('ratio',2,'tStep',0.06,'tEnd',0.08,'nSub',200,'Tss',5e-3), Vref);
chk('dip % (golden -2.181)', m.dipPct, -2.181, 0.05);
chk('settling ms (golden 0.1831)', m.settleMs, 0.1831, 0.004);
chk('iL peak A (golden 6.580)', m.iLpkAll, 6.580, 0.03);
chk('ripple % (golden 61.4)', m.ripplePct, 61.4, 0.6);

% ---- 3) D+ sensor chain is deterministic and reproduces its own value ----
s = struct('enable',true,'fBW',10e3,'nd',1,'gain',1.02,'offset',0.1, ...
           'sigma',0.02,'lsb',0.02,'iMaxPhys',10);
p2 = dual_params(48,6,150e-6,'nDly',1,'sens',s);
o = struct('ratio',2,'tStep',0.06,'tEnd',0.08,'nSub',200,'Tss',5e-3,'noise',true,'seed',11);
a = cfg_metrics(p2,o,Vref); b = cfg_metrics(p2,o,Vref);
chk('D+ seed 11 dip % (golden -2.418)', a.dipPct, -2.418, 0.05);
chk('S9 bit-identical repeat', double(a.ssErr==b.ssErr && a.dipPct==b.dipPct), 1, 0);

% ---- 4) the map must refuse what it does not model ----
rejected = false;
try
    sw_period_map(zeros(5,1), dual_params(48,6,150e-6,'nDly',0,'sampPhase',0.25));
catch
    rejected = true;      % in-period sampling with zero delay is not realisable
end
chk('invalid configuration rejected', double(rejected), 1, 0);

ok = isempty(fail);
fprintf('\n---- %d / %d checks passed ----\n', nChk-numel(fail), nChk);
if ~ok
    fprintf('FAILED: %s\n', strjoin(fail, ', '));
    if nargout == 0
        error('buck_smoke:fail','%d check(s) failed: %s', numel(fail), strjoin(fail,', '));
    end
else
    fprintf('The demo reproduces its published numbers on this machine.\n');
end

    function chk(name, got, want, tol)
        if nargin < 4, tol = 0; end
        nChk = nChk + 1;
        pass = abs(got-want) <= tol;
        if ~pass, fail{end+1} = name; end
        if verbose
            if tol == 0
                fprintf('  %-38s got %-14.6g want %-14.6g %s\n', name, got, want, ...
                    tern(pass,'PASS','FAIL'));
            else
                fprintf('  %-38s got %-14.6g want %-8.5g +-%g %s\n', name, got, want, tol, ...
                    tern(pass,'PASS','FAIL'));
            end
        end
    end
end

function s = tern(c,a,b)
if c, s = a; else, s = b; end
end
