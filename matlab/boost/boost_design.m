function c = boost_design(p, arch, fc, opts)
%BOOST_DESIGN  Design a voltage-mode controller for the CCM Boost at crossover fc.
%
%   c = boost_design(p, 'A', 600)                 % single voltage PI
%   c = boost_design(p, 'B', 600)                 % inner current P + outer PI
%   c = boost_design(p, 'A', 600, struct('TdPeriods',1.5,'zeroRatio',5))
%
% Both architectures are designed for the SAME target crossover so that Part 3
% compares architectures and not two different bandwidths.
%
% WHY THE DESIGN IS DONE ON THE FREQUENCY RESPONSE AND NOT WITH A FORMULA
% The textbook "fc <= fz/5" rule is a starting point, not a design. What decides
% the achievable bandwidth here is the combination of
%   * the RHP zero (phase lag that grows with frequency, magnitude +20 dB/dec),
%   * the LC resonance (peaking because Q is only ~3.6 with the losses),
%   * the digital delay (Td = (nDly + 0.5) periods by default = 30 us),
% and those three trade off against each other. The function therefore computes
% the loop gain numerically, finds the actual crossover, and reports the actual
% phase and gain margins INCLUDING the delay. If the achieved crossover differs
% from the request by more than 5 %, that is reported, not hidden.
%
% ARCH A  single PI:  d = D0 + Kp*e + Ki*integral(e)
% ARCH B  inner loop: d = D0 + Kci*(iLref - iL)/Vref     (proportional, no delay
%         of its own beyond the shared sampling delay)
%         outer loop: iLref = Kpe*e + Kie*integral(e)
%         The inner loop does NOT remove the RHP zero: the zero is in the
%         duty-to-inductor-current path as well, so it survives the cascade. This
%         is verified numerically in the task 3 comparison, not assumed.

if nargin < 4, opts = struct(); end
if ~isfield(opts,'TdPeriods'), opts.TdPeriods = 1.5; end
if ~isfield(opts,'zeroRatio'), opts.zeroRatio = 5; end

Ts = 1/p.fs;
Td = opts.TdPeriods*Ts;
wz = 2*pi*fc/opts.zeroRatio;          % PI zero placed below the crossover
wc = 2*pi*fc;

M = boost_avg_lin(p, boost_duty_for(p, p.Vref));
Gvd = tf(ss(M.A, M.Bd, M.Cy, M.Dd));
Gid = tf(ss(M.A, M.Bd, [1 0], 0));

c = struct('arch',arch,'fcTarget',fc,'Td',Td,'D0',boost_duty_for(p,p.Vref));
c.Tt = 20*Td;                % anti-windup back-calculation time
c.Eclamp = 2.0;
c.Imax = p.Imax;
c.Dmin = p.Dmin; c.Dmax = p.Dmax;
c.Tss = 5e-3; c.Vref0 = p.Vref;

switch upper(arch)
    case 'A'
        m = abs(freqresp(Gvd, wc));
        c.Kp = 1/(m*sqrt(1 + (wz/wc)^2));      % |C(jwc)|*|G(jwc)| = 1
        c.Ki = c.Kp*wz;
        LG = tf([c.Kp c.Ki],[1 0])*Gvd;
        c.plant = Gvd;
    case 'B'
        % ---- inner current loop: choose Kci for a target inner bandwidth ----
        % Li = (Kci/Vref)*Gid ; the inner loop is closed before the outer design.
        if isfield(opts,'Kci')
            Kci = opts.Kci;
        else
            % pick Kci so that the inner crossover sits at 2*fc (well above the
            % outer loop, so the cascade behaves as designed) but never above
            % fs/10 where the sampled behaviour dominates
            fci = min(2*fc, p.fs/10);
            mi  = abs(freqresp(Gid, 2*pi*fci));
            Kci = p.Vref/mi;
        end
        c.Kci = Kci;
        Li = (Kci/p.Vref)*Gid;
        Ti = Li/(1+Li);                        % iL / iLref
        % output impedance seen by the diode current: (1-D)*Zout
        R = p.R; ESR = p.ESR; D = c.D0;
        s = tf('s');
        Zout = (1 + s*ESR*p.C)*R/(1 + s*(R+ESR)*p.C);
        Gvi  = (1-D)*Zout;                     % iL -> vOut (duty held)
        Gouter = Ti*Gvi;
        m = abs(freqresp(Gouter, wc));
        c.Kpe = 1/(m*sqrt(1 + (wz/wc)^2));
        c.Kie = c.Kpe*wz;
        LG = tf([c.Kpe c.Kie],[1 0])*Gouter;
        c.plant = Gouter;
        c.Ti = Ti; c.Gvi = Gvi;
    otherwise
        error('boost_design:arch','arch must be A or B');
end

% closed-loop = C*G/(1+C*G) with the delay; margins computed on the numeric
% response of C*G*exp(-s*Td) so the delay is inside the number, not a footnote
[w, Lw] = loop_response(LG, Td);
c.LG = LG;
% Margins are evaluated at EVERY crossing (see boost_margins.m). PM/GM keep their
% old names but now mean the WORST over all crossings, not the highest/first one.
mm = boost_margins(w, Lw);
c.fcActual = mm.fcHighest;
c.PM = mm.pmWorst;
c.GM = mm.gmWorst;
c.nCross = mm.nDown;
c.nCrossUp = mm.nUp;
c.crossDetail = mm.cross;
c.gmDetail = mm.gm;
c.marginsOK = mm.crossingsOK;
c.fcReq = fc;
c.fcErr = 100*(c.fcActual/fc - 1);
c.w = w; c.L = Lw;
c.name = sprintf('%s@%.0fHz', upper(arch), round(c.fcActual));
end

% ---------------------------------------------------------------------------
function [w, Lw] = loop_response(LG, Td)
w = logspace(log10(2*pi*10), log10(2*pi*200e3), 4000).';
Lw = squeeze(freqresp(LG, w));
Lw = Lw(:).*exp(-1j*w*Td);
end
