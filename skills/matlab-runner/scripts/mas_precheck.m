function r = mas_precheck(kind, varargin)
%MAS_PRECHECK  Cheap checks that catch the failures Phase 3A/3B actually hit.
%
%   r = mas_precheck('function','boost_params')
%   r = mas_precheck('struct', s, {'a','b'})
%   r = mas_precheck('numeric', x, struct('finite',true,'range',[0 1],'size',[3 1]))
%   r = mas_precheck('index', mask, numel(target))
%   r = mas_precheck('cell', c, [1 3])
%   r = mas_precheck('toolbox', 'Deep Learning Toolbox')
%   r = mas_precheck('path', 'matlab/boost')
%   r = mas_precheck('model', 'matlab/boost/models/boost_avg.slx')
%
% WHY THESE KINDS
% Each one corresponds to a defect that cost real time in this repository:
%
%   index    A per-period logical mask applied to a waveform array does NOT error
%            in MATLAB; it silently indexes the first nPer samples. That bug made
%            every iLref reading 0 in Phase 3B.2 and nearly produced a wrong
%            conclusion. A length check turns it into a loud failure.
%   struct   A struct preallocated with fewer fields than the assignment is a
%            runtime error, and it happened twice (tailFit, summ). Checking the
%            field set before the loop makes it a one-line failure.
%   toolbox  license('test', <product name>) returns 0 for a LICENSED product,
%            because the argument is a FEATURE name. The map below was verified on
%            this machine; it replaces the masacc.availability call that the
%            previous SKILL.md told the agent to use -- masacc does not exist.
%   function A missing function is the most common first-run failure.
%   numeric  NaN/Inf and out-of-range values poison a long run silently.
%   cell     Cell arrays whose elements have different shapes break cellfun later.
%   path     A relative path that depends on pwd breaks when the agent changes dir.
%   model    A .slx that will not load or update cannot be simulated at all.
%
% Every check returns the same shape: pass, kind, detail, and where relevant the
% measured value, so a caller can log it without re-deriving anything.

r = struct('pass',false,'kind',kind,'detail','','errorClass','','value',[]);

switch lower(kind)
    case 'function'
        name = varargin{1};
        ok = exist(name,'file') == 2;
        r.pass = ok;
        if ok
            try
                n = nargin(name);
                r.value = n;
                r.detail = sprintf('%s found (nargin %d)', name, n);
            catch
                r.detail = sprintf('%s found', name);
            end
        else
            r.detail = sprintf('%s NOT found on the path', name);
            r.errorClass = 'MISSING_FUNCTION';
        end

    case 'struct'
        s = varargin{1}; need = varargin{2};
        if ~isstruct(s)
            r.detail = 'value is not a struct'; r.errorClass = 'TYPE_ERROR'; return;
        end
        have = fieldnames(s);
        miss = setdiff(need, have);
        r.pass = isempty(miss);
        if r.pass
            r.detail = sprintf('all %d required fields present', numel(need));
        else
            r.detail = ['missing field(s): ' strjoin(miss.', ', ')];
            r.errorClass = 'STRUCT_FIELD_MISMATCH';
        end
        r.value = have;

    case 'numeric'
        x = varargin{1};
        o = struct('finite',true,'range',[],'size',[],'maxabs',[]);
        if numel(varargin) > 1, f = varargin{2}; fn = fieldnames(f);
            for k = 1:numel(fn), o.(fn{k}) = f.(fn{k}); end; end
        msgs = {};
        if ~isnumeric(x) && ~islogical(x)
            msgs{end+1} = 'not numeric';
        else
            if o.finite && any(~isfinite(x(:))), msgs{end+1} = 'non-finite values'; end
            if ~isempty(o.range) && (any(x(:) < o.range(1)) || any(x(:) > o.range(2)))
                msgs{end+1} = sprintf('outside [%g %g]', o.range(1), o.range(2));
            end
            if ~isempty(o.size) && ~isequal(size(x), o.size)
                msgs{end+1} = sprintf('size %s, expected %s', mat2str(size(x)), mat2str(o.size));
            end
            if ~isempty(o.maxabs) && any(abs(x(:)) > o.maxabs)
                msgs{end+1} = sprintf('|x| exceeds %g', o.maxabs);
            end
        end
        r.pass = isempty(msgs);
        if r.pass
            r.detail = sprintf('numeric ok (%s)', mat2str(size(x)));
            r.value = x;
        else
            r.detail = strjoin(msgs,'; '); r.errorClass = 'NUMERIC_CONSTRAINT';
        end

    case 'index'
        mask = varargin{1}; n = varargin{2};
        if ~islogical(mask) && ~isnumeric(mask)
            r.detail = 'mask is not logical/numeric'; r.errorClass = 'TYPE_ERROR'; return;
        end
        r.pass = numel(mask) == n;
        if r.pass
            r.detail = sprintf('mask length %d matches target %d', numel(mask), n);
        else
            % This is the silent one: MATLAB would index the FIRST numel(mask)
            % elements and return a wrong subset without any error.
            r.detail = sprintf(['mask length %d != target length %d; MATLAB would ' ...
                'silently select the first %d elements'], numel(mask), n, numel(mask));
            r.errorClass = 'INDEX_MASK_MISMATCH';
        end

    case 'cell'
        c = varargin{1};
        if ~iscell(c)
            r.detail = 'not a cell array'; r.errorClass = 'TYPE_ERROR'; return;
        end
        bad = 0; badIdx = [];
        if numel(varargin) > 1 && ~isempty(varargin{2})
            want = varargin{2};
            for k = 1:numel(c)
                if ~isequal(size(c{k}), want), bad = bad + 1; badIdx(end+1) = k; end %#ok<AGROW>
            end
        else
            for k = 1:numel(c)
                if ~isequal(size(c{k}), size(c{1})), bad = bad + 1; badIdx(end+1) = k; end %#ok<AGROW>
            end
        end
        r.pass = bad == 0;
        if r.pass
            r.detail = sprintf('%d cells, consistent shape', numel(c));
        else
            r.detail = sprintf('%d cell(s) with a different shape: %s', bad, mat2str(badIdx));
            r.errorClass = 'CELL_SHAPE_MISMATCH';
        end

    case {'toolbox', 'dep'}
        % Delegated to mas_dep_probe so there is ONE product/feature table in the
        % repository. Before this, mas_precheck carried its own copy and the two
        % could drift; the table now lives in mas_product_map and the five-level
        % discovery in mas_dep_probe.
        name = varargin{1};
        d = mas_dep_probe('product', name);
        r.pass = d.pass; r.detail = d.detail;
        r.value = struct('state', d.state, 'level', d.level, ...
            'product', d.product, 'feature', d.feature);
        if ~d.pass
            r.errorClass = d.state;
        end

    case 'path'
        p = varargin{1};
        ok = isfolder(p);
        r.pass = ok;
        if ok
            r.detail = sprintf('folder exists: %s', p);
        else
            r.detail = sprintf('folder missing: %s', p);
            r.errorClass = 'PATH_MISSING';
        end

    case 'model'
        f = varargin{1};
        if ~isfile(f)
            r.detail = sprintf('model file missing: %s', f); r.errorClass = 'PATH_MISSING'; return;
        end
        [~, nm] = fileparts(f);
        if bdIsLoaded(nm), close_system(nm,0); end
        try
            load_system(f);
            set_param(nm,'SimulationCommand','update');
            r.pass = true;
            r.detail = sprintf('%s loads and updates', nm);
        catch ME
            r.pass = false;
            r.detail = ME.message;
            r.errorClass = 'MODEL_UPDATE_FAILED';
        end
        try, close_system(nm,0); catch, end

    otherwise
        error('mas_precheck:kind','unknown check kind "%s"', kind);
end
end
