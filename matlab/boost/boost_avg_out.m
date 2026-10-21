function y = boost_avg_out(x, d, Vin, p)
%BOOST_AVG_OUT  Output voltage of the CCM average model (the measured quantity).
%
%   y = boost_avg_out(x, d, Vin, p)
%
% Kept separate from boost_avg_f so that the linearisation differentiates exactly
% the same algebraic expression the simulator evaluates. Forgetting this split is
% how C = [0 1] (i.e. vOut = vC) gets into a model that then cannot explain the
% ESR ripple or the duty-to-output feed-through.
iL = x(1); vC = x(2);
d  = min(max(d,0),1);
id = (1-d)*iL;
y  = (vC + p.ESR*id)/(1 + p.ESR/p.R);
end
