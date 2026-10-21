function p = boost_params(varargin)
%BOOST_PARAMS  Parameter set for the 48 V / 96 W CCM Boost case study.
%
%   p = boost_params()
%   p = boost_params('L', 330e-6, 'C', 1000e-6)
%
% These are the RESEARCH STARTING POINTS from the Phase 3B.1 brief, not a BOM:
%
%   Vin 24 V, Vout 48 V, Pout 96 W, fs 50 kHz, L 220 uH, C 470 uF
%
% The loss elements are placeholders with a stated provenance:
%   RL    50 mOhm  assumed DCR of a 220 uH / 5 A toroid
%   RonSW 20 mOhm  assumed low-side MOSFET + driver
%   RonD  20 mOhm  assumed diode/body-diode conduction
%   Vf    0.50 V   assumed Schottky at ~100 C (a synchronous design would set
%                  Vf = 0 and use RonD only; the model supports both)
%   ESR   20 mOhm  assumed electrolytic + ceramic mix
% Every one of these is an ASSUMPTION. They are marked as such in the report and
% swept in the tolerance study; none is a datasheet value.
%
% WHY Vout IS NOT A PARAMETER
% The output voltage is a RESULT of the duty cycle, the load and the losses. The
% setpoint is Vref. Storing a "Vout" parameter and also computing a duty from it
% is how models end up with a 0.5 duty that produces 46.95 V while the report
% claims 48 V (measured on this design: the ideal D0 = 0.5 gives 46.95 V).

d = struct( ...
    'Vin', 24, ...          % V   input voltage
    'Vref', 48, ...         % V   output setpoint
    'Pout', 96, ...         % W   rated output power
    'fs', 50e3, ...         % Hz  switching frequency
    'L', 220e-6, ...        % H   inductance (starting point)
    'C', 470e-6, ...        % F   capacitance (starting point)
    'RL', 50e-3, ...        % Ohm inductor DCR
    'RonSW', 20e-3, ...     % Ohm switch on-resistance
    'RonD', 20e-3, ...      % Ohm diode on-resistance
    'Vf', 0.5, ...          % V   diode forward drop
    'ESR', 20e-3, ...       % Ohm output capacitor ESR
    'Dmin', 0.05, ...       % -   modulator lower rail
    'Dmax', 0.90, ...       % -   modulator upper rail
    'Imax', 8, ...          % A   current-command clamp (OCP)
    'Eclamp', 2.0, ...      % V   voltage-error clamp
    'R', NaN, ...           % Ohm load; NaN = derive from Vref^2/Pout (the normal case)
    'Nsub', 200);           % -   switching-simulator substeps per period

if mod(numel(varargin),2) ~= 0
    error('boost_params:args','name/value pairs expected');
end
for k = 1:2:numel(varargin)
    nm = varargin{k};
    if ~isfield(d, nm)
        error('boost_params:unknown','unknown parameter "%s"', nm);
    end
    d.(nm) = varargin{k+1};
end

% Load resistance and rated power are the same degree of freedom. By default R is
% derived from Vref and Pout; if the caller passes R explicitly (load sweeps), the
% rated power is derived instead, so the pair is always self-consistent.
if isnan(d.R)
    d.R = d.Vref^2/d.Pout;
else
    d.Pout = d.Vref^2/d.R;
end
p = d;
end
