function [dA, dB, meta] = boost_designs(p, fc)
%BOOST_DESIGNS  The two designs under test, kept strictly separate.
%
%   [dA, dB, meta] = boost_designs(p)          % fc = 650 Hz
%   [dA, dB, meta] = boost_designs(p, 500)
%
% Design A : the ORIGINAL 8 A current-command clamp. Unchanged requirements.
% Design B : the 10 A CANDIDATE. It is a DIFFERENT design -- a higher current
%            rating is a hardware decision (inductor saturation, FET rating,
%            shunt range, OCP threshold). Nothing here may be read as "the 8 A
%            design now passes".
%
% Both designs share the same controller gains, the same crossover target and the
% same plant. The ONLY difference is Imax, so any behavioural difference is
% attributable to the clamp and not to a retune.
%
% WHY THE CLAMP IS NOT THE WHOLE STORY
% The inner loop is proportional:
%     d = D0 + Kci*(iLref - iL)/Vref
% At equilibrium d must equal the duty this operating point needs, D_req, so
%
%     iL = iLref + (D0 - D_req)*Vref/Kci                                    (1)
%
% The second term is a DROOP: whenever D_req > D0 (low line, heavy load) the
% inductor current settles BELOW its command by
%
%     droop = (D_req - D0)*Vref/Kci                                         (2)
%
% The outer PI compensates it by raising iLref, so the real feasibility test is
% not "is iL <= Imax" but
%
%     iLref_required = iL_required + droop <= Imax                          (3)
%
% Equation (3) is what separates an ARCHITECTURE limitation (droop) from a
% PHYSICAL current limitation (iL_required). Both numbers are computed here so a
% report can state which one binds.

if nargin < 2 || isempty(fc), fc = 650; end

c  = boost_design(p, 'B', fc);

dA = c;
dA.Imax = 8;
dA.label = 'A: original 8 A command clamp';
dA.provenance = 'Phase 3B.1 design, unchanged';

dB = c;
dB.Imax = 10;
dB.label = 'B: 10 A candidate (hardware change)';
dB.provenance = 'candidate; requires device rating change, NOT validated in hardware';

meta = struct();
meta.fcRequested = fc;
meta.gains = struct('Kpe',c.Kpe,'Kie',c.Kie,'Kci',c.Kci,'D0',c.D0, ...
    'Tt',c.Tt,'Eclamp',c.Eclamp,'Dmin',c.Dmin,'Dmax',c.Dmax,'TdPeriods',1.5);
meta.note = ['A and B share every gain; only Imax differs. A "pass" of B says ' ...
    'nothing about A.'];
end
