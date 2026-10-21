function A = dual_A(cfg, R, Kci, Kpe, Kie, ff)
%DUAL_A  Exact closed-loop A matrix of the dual loop (3 states: iL, vC, xe).
%
%   A = dual_A(cfg, R, Kci, Kpe, Kie, ff)
%
% Control law
%   e      = Vref - vC
%   iLref  = Kpe*e + Kie*xe + ff*iLoad          (ff = 0 or 1; iLoad = vC/R)
%   dxe/dt = e            (+ back-calculation when a limit is active)
%   d      = Vref/Vin + Kci*(iLref - iL)/Vin
%
% Plant
%   L diL/dt = Vin*d - vC
%   C dvC/dt = iL - vC/R
%
% Substituting d:
%   diL/dt = [ Kci*(Kpe*(Vref-vC) + Kie*xe + ff*vC/R - iL) ] / L
%   dvC/dt = (iL - vC/R)/C
%   dxe/dt = Vref - vC
%
% so
%   A = [ -Kci/L , (-Kci*Kpe + ff*Kci/R)/L , Kci*Kie/L ;
%          1/C   ,        -1/(R*C)         ,      0      ;
%          0     ,            -1           ,      0      ]
%
% With ff = 0 this reduces to the model analysed in Task 1 (verified there to
% match det(sI-A) to 4e-16 and to reproduce the 3-state ODE).
%
% NOTE: with ff = 1 the feedforward uses the MEASURED load current, whose
% small-signal gain with respect to vC is 1/R. It therefore appears in A.

A = [ -Kci/cfg.L, (-Kci*Kpe + ff*Kci/R)/cfg.L, Kci*Kie/cfg.L ; ...
       1/cfg.C,   -1/(R*cfg.C),                0             ; ...
       0,         -1,                          0             ];
end
