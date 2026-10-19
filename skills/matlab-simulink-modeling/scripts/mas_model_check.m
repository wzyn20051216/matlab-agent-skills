function r = mas_model_check(mdlPath, opts)
%MAS_MODEL_CHECK  Grade a .slx by the level it actually reached.
%
%   r = mas_model_check('matlab/boost/models/boost_avg.slx', struct('tStop',0.01))
%
% Levels (cumulative, never inherited):
%   L0  file missing or will not load
%   L1  file loads              -- an artifact exists, nothing more
%   L2  model updates/compiles  -- the diagram is valid
%   L3  simulates to tStop and every logged signal is nonempty and finite
%   L4  caller-supplied extra check (passed in opts.extra as a function handle);
%       this function does not invent one
%
% WHY LEVELS INSTEAD OF A BOOLEAN
% "The model was created" is not "the model runs". Phase 3A treated a saved .slx
% as evidence of a working model; in Phase 3B.2 the first generated model applied a
% zero duty for one period because a Unit Delay defaulted to 0, and it still
% "simulated". A level forces the report to say which of those was proven.
%
% opts: tStop (default 0.02), extra (function handle returning [ok, detail])

if nargin < 2, opts = struct(); end
if ~isfield(opts,'tStop'), opts.tStop = 0.02; end
if ~isfield(opts,'extra'), opts.extra = []; end

r = struct('pass',false,'level','L0','detail','','signals',{{}});

if ~isfile(mdlPath)
    r.detail = sprintf('file missing: %s', mdlPath); return;
end
[~, nm] = fileparts(mdlPath);
wasLoaded = bdIsLoaded(nm);
if wasLoaded, close_system(nm,0); end
try
    load_system(mdlPath);
catch ME
    r.detail = ['load failed: ' ME.message]; return;
end
r.level = 'L1'; r.detail = 'loads';

try
    set_param(nm,'SimulationCommand','update');
    r.level = 'L2'; r.detail = 'loads and updates';
catch ME
    r.detail = ['update failed: ' ME.message];
    close_system(nm,0); return;
end

try
    set_param(nm,'StopTime',num2str(opts.tStop));
    so = sim(nm);
    names = who(so);
    bad = {};
    for k = 1:numel(names)
        v = so.(names{k});
        if isa(v,'timeseries')
            d = v.Data;
        else
            d = v;
        end
        if isempty(d) || (isnumeric(d) && any(~isfinite(d(:))))
            bad{end+1} = names{k}; %#ok<AGROW>
        end
    end
    r.signals = names;
    if isempty(names)
        r.detail = 'simulated but logged NO signals';
    elseif ~isempty(bad)
        r.detail = ['non-finite or empty signals: ' strjoin(bad.', ', ')];
    else
        r.level = 'L3'; r.detail = sprintf('simulated to %.3g s, %d signal(s) finite', ...
            opts.tStop, numel(names));
    end
catch ME
    r.detail = ['simulation failed: ' ME.message];
    close_system(nm,0); return;
end

if ~isempty(opts.extra) && strcmp(r.level,'L3')
    [ok, d] = opts.extra(so);
    if ok
        r.level = 'L4'; r.detail = [r.detail ' ; extra: ' d];
    else
        r.detail = [r.detail ' ; extra FAILED: ' d];
    end
end

r.pass = any(strcmp(r.level,{'L3','L4'}));
close_system(nm,0);
end
