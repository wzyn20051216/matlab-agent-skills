function out = cd_d7_boost()
%CD_D7_BOOST  Power electronics: reuse the frozen Boost case as a small task.
%
% INDEPENDENT REFERENCE
%   The requirement is 48 V, not "whatever the model produced". The closed-form
%   duty comes from boost_steady's loss-inclusive equations; the time-domain
%   switching simulation is a DIFFERENT code path. The task passes only if the
%   switching run lands on the specified 48 V and its ripple agrees with the
%   analytic triangle formula. Two methods, one requirement.

here = fileparts(mfilename('fullpath'));
addpath(fullfile(fileparts(fileparts(fileparts(here))),'boost'));

p = boost_params('Vin',20);
dq = boost_duty_for(p, p.Vref);
c = boost_design(p,'B',650);
c.D0 = dq; c.Imax = 8;
o = struct('ratio',1,'tStep',1,'tEnd',0.03,'nSub',200,'nDly',1,'noise',false);
r = boost_sw_sim(p, c, o);
q = r.t > 0.02;

vOut = mean(r.vOut(q));
ssErr = 100*(vOut - p.Vref)/p.Vref;
dILmeas = mean(r.iLpeak(r.tPer>0.02) - r.iLvalley(r.tPer>0.02));
dILana = boost_ripple(p, dq).dIL;

ok = abs(ssErr) <= 0.5 && abs(dILmeas/dILana - 1) < 0.10;

% The verifier grades a RATIO against 1, not two absolute values against a
% constant: an absolute ripple limit would have to be re-tuned for every Vin.
out.values = struct('duty',dq,'vOutMean',vOut,'ssErrPct',ssErr, ...
    'iLrippleMeas',dILmeas,'iLrippleAna',dILana,'iLrippleRatio',dILmeas/dILana);
out.reference = struct('Vref',p.Vref,'dutyClosedForm',dq,'rippleAnalytic',dILana);
out.status = tern(ok,'PASS','FAIL');
out.detail = sprintf('D %.4f, vOut %.4f V (%.3f %%), ripple %.4f vs %.4f A', ...
    dq, vOut, ssErr, dILmeas, dILana);
end

function s = tern(c,a,b)
if c, s = a; else, s = b; end
end
