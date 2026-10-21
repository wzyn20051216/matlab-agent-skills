function dx = boost_avg_f(x, d, p, Vin)
%BOOST_AVG_F  State derivative of the CCM average Boost model.
%
%   dx = boost_avg_f(x, d, p)        % Vin from p
%   dx = boost_avg_f(x, d, p, Vin)   % Vin overridden (used for linearisation)
%
% x = [iL; vC], d = duty. CCM only: the diode is assumed to carry current for the
% whole off-interval. See boost_sw_sim.m for the switching model that also
% detects the DCM boundary.
%
% Sign conventions: iL > 0 flows from the source into the switch node, vC is the
% capacitor voltage (equal to vOut at DC; the ESR drop appears only in vOut).

if nargin < 4, Vin = p.Vin; end
iL = x(1); vC = x(2);
d  = min(max(d, 0), 1);
u  = 1 - d;

id   = u*iL;                                  % average diode current
vOut = (vC + p.ESR*id)/(1 + p.ESR/p.R);        % ESR is in series with C
iOut = vOut/p.R;

% switch-node voltage, averaged over the period
vSW = d*(p.RonSW*iL) + u*(vOut + p.Vf + p.RonD*iL);

diL = (Vin - p.RL*iL - vSW)/p.L;
dvC = (id - iOut)/p.C;
dx = [diL; dvC];
end
