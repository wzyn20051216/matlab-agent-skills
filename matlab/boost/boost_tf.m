function T = boost_tf(p, d, which)
%BOOST_TF  Transfer functions of the CCM average model.
%
%   T = boost_tf(p)                 % at the duty that produces Vref
%   T = boost_tf(p, d, 'Gvd')       % control -> output
%   T = boost_tf(p, d, 'Gid')       % control -> inductor current
%   T = boost_tf(p, d, 'Gvi')       % line  -> output (audio susceptibility)
%
% Returns a struct of tf objects built from boost_avg_lin (numerical
% linearisation) so that every quantity used for design is derived from the same
% model the simulator integrates.

if nargin < 2 || isempty(d), d = boost_duty_for(p, p.Vref); end
if nargin < 3, which = 'all'; end
M = boost_avg_lin(p, d);

sys_v = ss(M.A, [M.Bd M.Bv], M.Cy, [M.Dd M.Dv]);
sys_i = ss(M.A, [M.Bd M.Bv], [1 0], [0 0]);

Gvd = tf(sys_v(1,1));   Gvi = tf(sys_v(1,2));
Gid = tf(sys_i(1,1));   Gii = tf(sys_i(1,2));

T = struct('d',d,'Gvd',Gvd,'Gvi',Gvi,'Gid',Gid,'Gii',Gii, ...
    'A',M.A,'Bd',M.Bd,'Bv',M.Bv,'Cy',M.Cy,'Dd',M.Dd,'Dv',M.Dv, ...
    'xs',M.xs,'p',p);

% analytic reference (ideal, no losses) for cross-checking:
%   Gvd_ideal(s) = Vin/(1-D)^2 * (1 - s*L/(R*(1-D)^2)) /
%                  (1 + s*L/(R*(1-D)^2) + s^2*L*C/(1-D)^2)
if nargout == 0
    fprintf('Gvd zeros : '); disp(zero(Gvd).');
    fprintf('Gvd poles : '); disp(pole(Gvd).');
end
end
