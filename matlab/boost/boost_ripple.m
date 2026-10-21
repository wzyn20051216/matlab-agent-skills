function r = boost_ripple(p, d)
%BOOST_RIPPLE  Inductor / capacitor ripple and the CCM-DCM boundary.
%
%   r = boost_ripple(p)      % at the operating duty
%   r = boost_ripple(p, d)
%
% Everything here is an ANALYTIC estimate from the same parameters, used to
%   (a) size the components,
%   (b) provide an independent check of the switching simulation, and
%   (c) define the CCM validity boundary that the acceptance protocol needs.
%
% The formulas assume CCM and small ripple (the usual first-order triangle
% approximation). They are compared against the switching simulation in
% verify/boost_b1_task1_model.m, where the difference is reported rather than
% hidden.

if nargin < 2 || isempty(d), d = boost_duty_for(p, p.Vref); end
s  = boost_steady(p, d);
Ts = 1/p.fs;
u  = 1 - d;

% --- inductor: volt-second balance during the ON interval ---
vLon  = p.Vin - s.iL*(p.RL + p.RonSW);      % voltage across L while the switch is on
dIL   = vLon*d*Ts/p.L;                      % peak-to-peak
iLpk  = s.iL + dIL/2;
iLval = s.iL - dIL/2;

% --- capacitor: charge balance during the ON interval ---
% While the switch is on the diode blocks, so the capacitor supplies the load:
% dV = Iout*d*Ts/C. This is the capacitive part only; the ESR adds a step of
% ESR * (diode current just after the switch opens).
dvC   = s.iOut*d*Ts/p.C;
dILd  = dIL;                                 % diode current swings 0 <-> iL during OFF
dvESR = p.ESR*(iLpk - 0);                    % step when the diode starts conducting
dvOut = dvC + dvESR;                         % worst case: both terms in phase

% --- CCM / DCM boundary: valley current reaches zero ---
Rb   = 2*s.vOut/(u*dIL);                     % load resistance at the boundary
Ib   = s.vOut/Rb;                            % output current at the boundary
frac = Ib/s.iOut;                            % fraction of rated load

% --- ideal small-signal landmarks (checked against the model in task 1) ---
f0   = u/(2*pi*sqrt(p.L*p.C));
Qid  = p.R*u*sqrt(p.C/p.L);      % Q = omega0*R*C = R*(1-D)*sqrt(C/L)
fzRHP= p.R*u^2/(2*pi*p.L);
fESR = 1/(2*pi*p.ESR*p.C);
fsw  = p.fs;

r = struct('d',d,'dIL',dIL,'dILpct',100*dIL/s.iL,'iLpk',iLpk,'iLvalley',iLval, ...
    'dvC',dvC,'dvESR',dvESR,'dvOut',dvOut,'dvOutPct',100*dvOut/s.vOut, ...
    'Rb',Rb,'Ib',Ib,'IoutFrac',frac,'iOut',s.iOut, ...
    'f0',f0,'Qideal',Qid,'fzRHP',fzRHP,'fESR',fESR,'fsw',fsw, ...
    'note',['ripple formulas are first-order (small-ripple triangle); ESR ripple ' ...
            'is approximated by the worst-case step at the diode turn-on']);
end
