function s = boost_steady(p, d)
%BOOST_STEADY  Closed-form CCM operating point of the lossy Boost converter.
%
%   s = boost_steady(p)        % uses p.Dmin? no: uses the loss-inclusive duty
%   s = boost_steady(p, d)     % fixed duty
%
% MODEL (average, CCM, conduction losses only)
%   states x = [iL; vC];  vOut = (vC + ESR*id)/(1 + ESR/R);  id = (1-d)*iL
%   diL/dt = (Vin - RL*iL - vSW)/L
%   vSW    = d*RonSW*iL + (1-d)*(vOut + Vf + RonD*iL)
%   dvC/dt = (id - vOut/R)/C
%
% DERIVATION (this is why the function is closed-form and not a solver)
%   At equilibrium the capacitor charge balance gives  id = vOut/R, hence
%       vC = vOut  (the ESR drop cancels exactly: vOut = (vC + ESR*id)/(1+ESR/R)
%                   and id = vOut/R imply vC = vOut)
%   and the inductor volt-second balance gives
%       Vin = IL*Req + (1-d)*(vOut + Vf),   Req = RL + d*RonSW + (1-d)*RonD
%   with IL = vOut/(R*(1-d)). Substituting and solving for vOut:
%
%       vOut = (Vin - (1-d)*Vf) / ( (1-d) + Req/(R*(1-d)) )
%
%   which is the textbook 1/(1-d) law plus two loss penalties. The ideal case
%   (Req = Vf = 0) reduces to vOut = Vin/(1-d) exactly.
%
% OUTPUT
%   s.d, s.iL, s.vC, s.vOut, s.iOut, s.pOut, s.pIn, s.eff, s.Req, s.Dideal

if nargin < 2
    d = boost_duty_for(p, p.Vref);      % duty that actually produces Vref
else
    d = min(max(d,0), p.Dmax);
end

u  = 1 - d;
Req = p.RL + d*p.RonSW + u*p.RonD;
vOut = (p.Vin - u*p.Vf) / (u + Req/(p.R*u));   % see derivation above

s = struct();
s.d = d;
s.vOut = vOut;
s.vC = vOut;                            % exact at equilibrium (ESR drops cancel)
s.iL = vOut/(p.R*u);
s.iOut = vOut/p.R;
s.pOut = vOut*s.iOut;
s.pIn = p.Vin*s.iL;
s.eff = s.pOut/max(s.pIn,eps);
s.Req = Req;
s.Dideal = 1 - p.Vin/p.Vref;
s.lossInductor = s.iL^2*(p.RL + d*p.RonSW + u*p.RonD);
s.lossDiode = u*s.iL*p.Vf;              % average diode drop loss
s.residual = max(abs(boost_avg_f([s.iL; s.vC], d, p)));   % self-check
end
