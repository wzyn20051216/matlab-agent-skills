function p = dual_params(vin, R, L, varargin)
%DUAL_PARAMS  Parameter struct for the switching-level map / Floquet analysis.
%
%   p = dual_params(48, 6, 150e-6)                       nominal DUAL-B
%   p = dual_params(48, 6, 150e-6, 'nDly', 2)            two periods of delay
%   p = dual_params(48, 6, 150e-6, 'sens', s)            sensor chain enabled
%
% Keeps ONE definition of the deployed controller so the map, the Floquet
% analysis, the Simulink builder and the acceptance scripts cannot drift apart.
% Values are the frozen Phase 3A.4 tuning for DUAL-B.

d = struct( ...
    'Vin', vin, 'R', R, 'L', L, 'C', 220e-6, 'Vref', 12, 'fs', 50e3, 'Nsub', 200, ...
    'ESR', 10e-3, 'RL', 20e-3, 'Vf', 0.35, 'RonSW', 1e-3, 'RonD', 2e-3, ...
    'Kci', 6, 'Kpe', 1.8, 'Kie', 4000, 'ff', 1, ...
    'Imin', 0, 'Imax', 12, 'Dmin', 0.05, 'Dmax', 0.85, ...
    'Tt', 3e-4, 'Eclamp', 1.5, ...
    'sampPhase', 0, 'rippleComp', true, 'nDly', 1);

% sensor defaults: DISABLED (i.e. ideal iLoad) unless the caller enables it
d.sens = struct('enable', false, 'fBW', 10e3, 'gain', 1, 'offset', 0, ...
                'sigma', 0, 'lsb', 0, 'seed', 7, 'nd', 0, ...
                'iMaxPhys', 1.25*12/1.5, 'tol', 3.0);

if mod(numel(varargin),2) ~= 0
    error('dual_params:args','name/value pairs expected');
end
for k = 1:2:numel(varargin)
    nm = varargin{k};
    if strcmp(nm,'sens')
        f = fieldnames(varargin{k+1});
        for q = 1:numel(f), d.sens.(f{q}) = varargin{k+1}.(f{q}); end
    else
        if ~isfield(d, nm)
            error('dual_params:unknown','unknown parameter "%s"', nm);
        end
        d.(nm) = varargin{k+1};
    end
end
p = d;
end
