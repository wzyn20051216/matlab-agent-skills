function Gv = dual_loop_gain(cfg, R, Kci, Kpe, Kie, ff, type)
%DUAL_LOOP_GAIN  Plant seen by the OUTER PI: vC / u_o.
%
%   Gv = dual_loop_gain(cfg, R, Kci, Kpe, Kie, ff)
%   Gv = dual_loop_gain(..., 'L')   -> full loop gain (Kpe + Kie/s)*Gv
%
% u_o is the outer controller output BEFORE the current reference is formed:
%     iLref = u_o + ff*iLoad ,  iLoad = vC/R
%     u_o   = Kpe*(Vref-vC) + Kie*xe
%
% Linearising the inductor equation with d = Vref/Vin + Kci*(iLref-iL)/Vin:
%   L diL/dt = Vref - vC + Kci*(u_o + ff*vC/R - iL)
%   C dvC/dt = iL - vC/R
% so the 2-state plant from u_o to vC is
%   A2 = [ -Kci/L , (ff*Kci/R - 1)/L ;  1/C , -1/(R*C) ]
%   B2 = [ Kci/L ; 0 ] ,  C2 = [0 1]
%
% With ff=0 this is the model used in Task 1 (verified there against the exact
% 3-state characteristic polynomial). With ff=1 the plant changes STRUCTURE:
% the inner loop no longer regulates iL, it regulates the capacitor current
% iC = iL - vC/R, because iLref picks up vC/R. The LC resonance is then removed
% from the outer loop and the outer plant degenerates to ~1/(C*s). That is the
% real mechanism behind the CAND-B improvement -- it is NOT merely a
% feedforward that leaves the loop gain untouched. Computing PM with the ff=0
% transfer function would therefore be wrong, which is why this file exists.

if nargin < 7 || isempty(type), type = 'plant'; end

A2 = [ -Kci/cfg.L, (ff*Kci/R - 1)/cfg.L ; ...
        1/cfg.C,   -1/(R*cfg.C) ];
B2 = [ Kci/cfg.L ; 0 ];
C2 = [0 1];
Gv = ss(A2, B2, C2, 0);
if strcmpi(type,'L')
    Cs = tf([Kpe Kie],[1 0]);
    Gv = minreal(Cs*tf(Gv));
end
end
