function M = boost_avg_lin(p, d)
%BOOST_AVG_LIN  Small-signal state space of the CCM average model at duty d.
%
%   M = boost_avg_lin(p, d)
%
%   M.A   2x2  dx = A*dx + Bd*dd + Bv*dVin
%   M.Bd  2x1  control input (duty)
%   M.Bv  2x1  line input (Vin)
%   M.Cy  1x2  output = vOut (NOT vC: the ESR term is part of the output)
%   M.Dd  scalar  feed-through duty -> vOut (ESR only; zero if ESR = 0)
%   M.Dv  scalar  feed-through Vin -> vOut (zero: Vin does not reach the output
%                 instantaneously)
%   M.xs  operating point [iL; vC], M.d, M.vOut
%
% WHY NUMERICAL LINEARISATION
% The loss terms (Ron*iL, Vf, ESR and the algebraic vOut expression) make the
% hand-derived Jacobian long and easy to get subtly wrong -- the classic mistake
% being to use C = [0 1] and forget that vOut = (vC + ESR*id)/(1+ESR/R) depends
% on iL as well. Central differences of the SAME function that the time-domain
% simulation integrates cannot disagree with the simulation. The analytic
% transfer function is then used as the independent check (see
% verify/boost_b1_task1_model.m), not as the source of the model.

if nargin < 2 || isempty(d), d = boost_duty_for(p, p.Vref); end
st = boost_steady(p, d);
xs = [st.iL; st.vC];        % boost_steady returns a STRUCT; the linearisation needs
                            % the 2x1 state vector (the first version indexed the
                            % struct and crashed at abs(xs(j)))

h  = 1e-7;
n  = 2;
A  = zeros(n,n); Bd = zeros(n,1); Bv = zeros(n,1);

for j = 1:n
    xp = xs; xm = xs;
    xp(j) = xp(j) + h*max(1,abs(xs(j)));
    xm(j) = xm(j) - h*max(1,abs(xs(j)));
    A(:,j) = (boost_avg_f(xp,d,p) - boost_avg_f(xm,d,p))/(xp(j)-xm(j));
end

hd = 1e-7; hd = min(hd, 0.01*min(d,1-d));
Bd = (boost_avg_f(xs,d+hd,p) - boost_avg_f(xs,d-hd,p))/(2*hd);
hv = 1e-3;
Bv = (boost_avg_f(xs,d,p,p.Vin+hv) - boost_avg_f(xs,d,p,p.Vin-hv))/(2*hv);

% output: vOut, linearised with the SAME expression the simulator uses
yp = boost_avg_out(xs, d+hd, p.Vin, p);  yn = boost_avg_out(xs, d-hd, p.Vin, p);
Dd = (yp-yn)/(2*hd);
Cy = zeros(1,n);
for j = 1:n
    xp = xs; xm = xs;
    xp(j) = xp(j) + h*max(1,abs(xs(j)));
    xm(j) = xm(j) - h*max(1,abs(xs(j)));
    Cy(j) = (boost_avg_out(xp,d,p.Vin,p) - boost_avg_out(xm,d,p.Vin,p))/(xp(j)-xm(j));
end
yp = boost_avg_out(xs, d, p.Vin+hv, p); yn = boost_avg_out(xs, d, p.Vin-hv, p);
Dv = (yp-yn)/(2*hv);

M = struct('A',A,'Bd',Bd,'Bv',Bv,'Cy',Cy,'Dd',Dd,'Dv',Dv, ...
    'xs',xs,'d',d,'vOut',st.vOut,'p',p);
end
