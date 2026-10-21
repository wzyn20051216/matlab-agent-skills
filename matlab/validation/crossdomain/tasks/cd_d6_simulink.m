function out = cd_d6_simulink()
%CD_D6_SIMULINK  Simulink: build a first-order system and check the trajectory.
%
% INDEPENDENT REFERENCE
%   dx/dt = -2x + 2u, u = 1, x(0) = 0  ->  x(t) = 1 - exp(-2t).
%   At t = 1 : 0.864665,  at t = 2 : 0.981684. These are closed-form values; the
%   model is graded against them, not against its own log.
%
% The model is built programmatically from library blocks only, so this task also
% exercises the "Simulink modeling" capability end to end.

mdl = 'cd_fos';
if bdIsLoaded(mdl), close_system(mdl,0); end
new_system(mdl); open_system(mdl);
% The reference is x(t) = 1-exp(-2t), which belongs to dx = -2x + 2u. The first
% version wired u with a gain of 1 (dx = -2x + u), giving x(inf) = 0.5 and half
% the reference trajectory. The independent reference caught a real model error,
% it did not need adjusting.
add_block('simulink/Sources/Step',[mdl '/u'],'Time','0','Before','0','After','2');
add_block('simulink/Math Operations/Sum',[mdl '/sum'],'Inputs','+-');
add_block('simulink/Continuous/Integrator',[mdl '/int'],'InitialCondition','0');
add_block('simulink/Math Operations/Gain',[mdl '/k2'],'Gain','2');
add_block('simulink/Sinks/To Workspace',[mdl '/x'],'VariableName','x', ...
    'SaveFormat','Timeseries');
add_line(mdl,'u/1','sum/1','autorouting','on');
add_line(mdl,'sum/1','int/1','autorouting','on');
add_line(mdl,'int/1','k2/1','autorouting','on');
add_line(mdl,'k2/1','sum/2','autorouting','on');
add_line(mdl,'int/1','x/1','autorouting','on');
set_param(mdl,'StopTime','2','Solver','ode4','SolverType','Fixed-step', ...
    'FixedStep','0.001');
so = sim(mdl);
t = so.x.Time; v = so.x.Data;
x1 = interp1(t, v, 1.0);
x2 = interp1(t, v, 2.0);
close_system(mdl,0);

ref1 = 1 - exp(-2);
ref2 = 1 - exp(-4);
ok = abs(x1-ref1) < 2e-3 && abs(x2-ref2) < 2e-3 && all(isfinite(v));

out.values = struct('x_at_1',x1,'x_at_2',x2,'nSamples',numel(t));
out.reference = struct('x_at_1',ref1,'x_at_2',ref2);
out.status = tern(ok,'PASS','FAIL');
out.detail = sprintf('x(1)=%.6f (ref %.6f), x(2)=%.6f (ref %.6f)', x1, ref1, x2, ref2);
end

function s = tern(c,a,b)
if c, s = a; else, s = b; end
end
