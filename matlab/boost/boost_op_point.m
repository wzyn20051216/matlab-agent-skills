function s = boost_op_point(p, c, Vin, R)
%BOOST_OP_POINT  Everything a feasibility argument needs at one operating point.
%
%   s = boost_op_point(p, c, Vin, R)
%
% Returns the physical requirement (duty, inductor current, ripple, peak) AND the
% controller's internal requirement (the current COMMAND the outer loop has to
% produce), because those are different numbers whenever the inner loop is
% proportional. See boost_designs.m for the derivation of `droop`.
%
% Fields
%   Vin, R, Dreq, vOut, iL, dIL, iLpk, iLvalley
%   droop        A    steady-state current-command overhead, (Dreq-D0)*Vref/Kci
%   iSig         A    the current SIGNAL the inner loop regulates: the band-limited
%                    sample (valley) plus the nominal half-ripple compensation,
%                    which restores it to the cycle average. iSig = iL is the
%                    idealised statement of that; the measured residual is ~0.2 A
%                    because the ripple is asymmetric once losses are included.
%   iLrefReq     A    command needed to hold this point, iSig + droop
%   Imax         A    clamp of the design under test
%   headroom     A    Imax - iLrefReq   (negative = the clamp binds)
%   limitedBy    'none' | 'architecture (droop)' | 'physical (no headroom)'
%   dutyMarginHi -    Dmax - Dreq
%   dutyMarginLo -    Dreq - Dmin
%   ccmValley    A    iL - dIL/2 ( <=0 means DCM at this point )

pq = p;
pq.Vin = Vin;
pq.R   = R;
pq.Pout = pq.Vref^2/R;

Dreq = boost_duty_for(pq, pq.Vref);
st   = boost_steady(pq, Dreq);
rip  = boost_ripple(pq, Dreq);

droop    = (Dreq - c.D0)*p.Vref/c.Kci;
iSig     = st.iL;                 % half-ripple compensation restores the average
iLrefReq = iSig + droop;
headroom = c.Imax - iLrefReq;

% Attribute the shortfall. If the point cannot be held even with an unlimited
% clamp the cause is physical (or the duty rail); otherwise it is the droop.
if headroom >= 0
    limitedBy = 'none';
elseif st.iL <= c.Imax
    limitedBy = 'architecture (droop)';
else
    limitedBy = 'physical (no headroom)';
end

s = struct();
s.Vin = Vin; s.R = R;
s.Dreq = Dreq;
s.vOut = st.vOut;
s.iL = st.iL;
s.dIL = rip.dIL;
s.iLpk = st.iL + rip.dIL/2;
s.iLvalley = st.iL - rip.dIL/2;
s.iOut = st.iOut;
s.pOut = st.pOut;
s.eff = st.eff;
s.droop = droop;
s.iSig = iSig;
s.iLrefReq = iLrefReq;
s.Imax = c.Imax;
s.headroom = headroom;
s.headroomPct = 100*headroom/iLrefReq;
s.limitedBy = limitedBy;
s.dutyMarginHi = c.Dmax - Dreq;
s.dutyMarginLo = Dreq - c.Dmin;
s.ccmValley = s.iLvalley;
s.ccm = s.iLvalley > 0;
end
