function dipPct = buck_dip_floor(P, R0, R1, dmax)
%BUCK_DIP_FLOOR  Shallowest achievable load-step dip with the duty pinned at dmax.
%
%   dipPct = buck_dip_floor(P, R0, R1, dmax)
%
% Integrates the lossless average plant
%     L diL/dt = Vin*d - vC ,   C dvC/dt = iL - vC/R1
% from the pre-step steady state (iL=Vref/R0, vC=Vref) with the duty held at
% dmax from t=0. Holding d at the maximum feeds the capacitor with as much
% current as the actuator allows for the whole transient, so the resulting dip
% is a LOWER BOUND on |dip| for any causal controller that must respect the same
% duty ceiling. It is not achievable in practice (a real controller must reduce
% the duty again), which is why it is called a floor.
%
% WHY THIS FUNCTION EXISTS (Phase 3A.5 defect A5)
% Phase 3A.3 computed this bound once with R0 = 6 ohm and then quoted the number
% for every R1. But the heavy-load acceptance cases C5/C6 start from R = 3 ohm,
% so the current step is 4 A instead of 6 A and the true floor is roughly half
% as deep. Quoting the R0=6 number for C5/C6 made the controller look 2.2x
% better than it was. This function takes R0 explicitly so the mistake cannot be
% repeated silently.
%
% P must contain Vin, Vref, L, C.

opts = odeset('RelTol',1e-10,'AbsTol',1e-13,'MaxStep',1e-6);
f = @(t,x) [(P.Vin*dmax - x(2))/P.L; (x(1) - x(2)/R1)/P.C];
[~,x] = ode45(f, [0 3e-3], [P.Vref/R0; P.Vref], opts);
dipPct = (min(x(:,2)) - P.Vref)/P.Vref*100;
end
