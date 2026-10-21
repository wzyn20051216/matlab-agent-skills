function L = sw_state_layout(p)
%SW_STATE_LAYOUT  Index map of the closed-loop period-map state vector.
%
%   L = sw_state_layout(p)
%
% ONE definition of the state size and of every field offset, shared by
% sw_period_map.m (which packs/unpacks the vector) and sw_floquet.m (which needs
% the dimension for the numerical Jacobian). If the two computed the size
% independently, adding a state would silently produce a wrong Jacobian instead
% of an error -- exactly the class of bug this phase is meant to remove.
%
% STATE
%   [iL; vC; xI; d(1..np); yS; m(1..nd); (dxI)]
%
%   np    duty pipeline stages. d(1) is applied DURING the current period, so a
%         duty computed at the end of period k is applied in period k+1, k+2, ...
%   nd    measurement transport-delay stages
%   dxI   integrator slope held from the previous sampling instant. It is only
%         carried when the sample is NOT at the period boundary: with
%         sampPhase > 0 the integrator runs for a while on the previous slope
%         before the new one is computed, and that slope is not recoverable from
%         (iL, vC, xI) alone -- it depends on the previous sample.
%
% SAMPLING PHASE AND DELAY
%   sampPhase = 0    boundary sampling; np = nDly (nDly = 0 is allowed and means
%                    the duty is computed and applied inside the same period)
%   sampPhase > 0    sample at sampPhase*Ts; the PWM register can only be
%                    updated at a period boundary, so the duty ALWAYS waits for
%                    the next boundary. nDly = 0 is therefore not realisable and
%                    is rejected instead of being silently promoted, because the
%                    effective delay (1-sampPhase)*Ts would otherwise be
%                    mislabelled as "zero".

phi = 0;
if isfield(p,'sampPhase'), phi = p.sampPhase; end
if phi < 0 || phi >= 1
    error('sw_state_layout:phase','sampPhase must be in [0,1); got %g', phi);
end
np = p.nDly;
if phi > 0 && np < 1
    error('sw_state_layout:delay', ...
        ['sampPhase=%g with nDly=0 is not realisable: a sample inside the ' ...
         'period can only change the duty at the next period boundary'], phi);
end
nd = p.sens.nd;

L = struct('phi',phi,'np',np,'nd',nd,'hasDxI',phi>0);
L.iIL = 1; L.iVC = 2; L.iXI = 3;
q = 3;
L.idx = q + (1:np);      q = q + np;
L.iYS = q + 1;           q = q + 1;
L.iM  = q + (1:nd);      q = q + nd;
L.iDxI = [];
if L.hasDxI
    L.iDxI = q + 1;      q = q + 1;
end
L.n = q;

% effective delay from the sampling instant to the start of the period in which
% the computed duty takes effect, in switching periods. Boundary sampling with
% one pipeline stage = 1.0; a sample at 0.75 with one stage = 0.25.
L.effDelayPeriods = (np - phi);
end
