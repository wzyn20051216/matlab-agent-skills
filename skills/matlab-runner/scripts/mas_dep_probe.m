function r = mas_dep_probe(what, target, opts)
%MAS_DEP_PROBE  Five-level dependency discovery with explicit failure classes.
%
%   r = mas_dep_probe('function', 'butter')
%   r = mas_dep_probe('product',  'Deep Learning Toolbox')
%   r = mas_dep_probe('feature',  'Signal_Toolbox')
%   r = mas_dep_probe('exec',     'tf(1,[1 1])')
%
%   r.state   % OK | FN_NOT_FOUND | IS_A_DIRECTORY | NOT_ON_PATH | NOT_INSTALLED
%             %    | NOT_LICENSED | EXEC_FAILED | UNKNOWN_PRODUCT | BAD_CALL
%   r.level   % how deep the probe got: 0 nothing, 1 function resolved,
%             %    3 product installed, 4 feature licensed, 5 probe executed
%
% WHY FIVE LEVELS AND NOT A BOOLEAN
% "It does not work" has five different causes with five different fixes, and the
% previous phase collapsed them into a boolean:
%
%   1 function not found      -> the name is wrong, or the folder is not on path
%   2 name resolves to a dir  -> `robotics` is a toolbox FOLDER; exist()=7, which
%                                a naive `exist(...)==2` reports as "missing"
%   3 file exists off path    -> `which` empty; addpath is the fix, not install
%   4 product not installed   -> ver() does not list it; install
%   5 product installed but   -> license('test', FEATURE) = 0; the feature string
%     not licensed              is the usual culprit, see mas_product_map
%   6 licensed but throws     -> the product is there and the call is wrong
%
% Level 3-5 are only attempted for 'product' probes, because they are the expensive
% ones (license checkout has real cost, and executing a probe can have side
% effects). 'function' probes stop at level 1 unless opts.deep is set.
%
% opts:
%   .deep      (false)  continue past level 1 for function probes
%   .throw     (false)  rethrow execution errors after recording them
%   .skipExec  (false)  do not run the representative probe expression

if nargin < 3 || isempty(opts), opts = struct(); end
opts = with_defaults(opts);

r = struct('what', what, 'target', char(target), 'state', 'BAD_CALL', 'level', 0, ...
    'pass', false, 'detail', '', 'product', '', 'feature', '', 'evidence', {{}});

switch lower(what)
    case 'function'
        r = probe_function(r, char(target), opts);
    case 'product'
        r = probe_product(r, char(target), opts);
    case 'feature'
        r = probe_feature(r, char(target), opts);
    case 'exec'
        r = probe_exec(r, char(target), opts);
    otherwise
        error('mas_dep_probe:what', 'unknown probe type "%s"', what);
end
r.pass = strcmp(r.state, 'OK');
end

% ---------------------------------------------------------------------------
function r = probe_function(r, name, opts)
% Level 1: does the name resolve to something callable?
e = exist(name, 'file');
if e == 7
    r.state = 'IS_A_DIRECTORY'; r.level = 0;
    r.detail = sprintf('"%s" is a FOLDER (exist=7), not a function; it cannot be called', name);
    return;
elseif e == 0
    r.state = 'FN_NOT_FOUND'; r.level = 0;
    r.detail = sprintf('"%s" not found: not a file, not a builtin, not a folder', name);
    return;
elseif e == 5 || e == 2 || e == 3 || e == 6
    r.level = 1;
    w = which(name);
    if isempty(w) && e == 2
        % A file that exists but is not visible to the path resolver. This happens
        % after `cd` into a folder whose parent was removed from the path.
        r.state = 'NOT_ON_PATH'; r.level = 0;
        r.detail = sprintf('"%s" is a file but `which` cannot resolve it: add its folder to the path', name);
        return;
    end
    r.state = 'OK';
    r.detail = sprintf('%s resolves to %s', name, tern(isempty(w), '<builtin>', w));
    r.evidence{end+1} = sprintf('exist=%d', e);
    r.evidence{end+1} = sprintf('which=%s', w);
else
    r.state = 'FN_NOT_FOUND'; r.level = 0;
    r.detail = sprintf('"%s" returned exist=%d, which is not callable', name, e);
    return;
end

if ~opts.deep, return; end

% Level 3-5: attribute the function to a product and check the license.
pm = mas_product_map(name);
if pm.found
    r.product = pm.name; r.feature = pm.feature;
else
    % Unknown owner is not a failure: many core functions live in MATLAB itself.
    r.evidence{end+1} = 'owner product unknown; treated as core MATLAB';
    return;
end
[r, okOwn] = check_product_levels(r, pm, opts);
if ~okOwn, return; end

% Level 5: execute the representative probe of the OWNING product, if any. The
% function itself is not called, because calling it needs valid arguments; a
% product-level probe answers "is this product usable at all".
if ~isempty(pm.probe)
    [okx, msg] = run_probe(pm.probe);
    if ~okx
        r.state = 'EXEC_FAILED'; r.detail = sprintf('%s licensed but probe "%s" failed: %s', ...
            pm.name, pm.probe, msg);
        return;
    end
    r.level = 5;
    r.evidence{end+1} = sprintf('probe "%s" executed', pm.probe);
end
end

% ---------------------------------------------------------------------------
function r = probe_product(r, name, opts)
pm = mas_product_map(name);
if ~pm.found
    r.state = 'UNKNOWN_PRODUCT'; r.level = 0;
    r.detail = sprintf('"%s" is not in the product map', name);
    if ~isempty(pm.candidates)
        r.detail = sprintf('%s; did you mean: %s', r.detail, strjoin(pm.candidates, ' | '));
    end
    return;
end
r.product = pm.name; r.feature = pm.feature;
r.evidence{end+1} = sprintf('canonical=%s', pm.name);
if ~isempty(pm.aliases)
    r.evidence{end+1} = sprintf('aliases=%s', strjoin(pm.aliases, ','));
end

[r, ok] = check_product_levels(r, pm, opts);
if ~ok, return; end

if opts.skipExec || isempty(pm.probe)
    r.state = 'OK';
    if isempty(pm.probe)
        r.detail = sprintf('%s installed and licensed (no executable probe defined)', pm.name);
    else
        r.detail = sprintf('%s installed and licensed (probe skipped)', pm.name);
    end
    return;
end

[okx, msg] = run_probe(pm.probe);
if okx
    r.state = 'OK'; r.level = 5;
    r.detail = sprintf('%s usable: installed, licensed, probe "%s" ran', pm.name, pm.probe);
    r.evidence{end+1} = sprintf('probe "%s" OK', pm.probe);
else
    r.state = 'EXEC_FAILED';
    r.detail = sprintf('%s installed and licensed but probe "%s" failed: %s', pm.name, pm.probe, msg);
end
end

% ---------------------------------------------------------------------------
function r = probe_feature(r, feat, opts)
installed = ver_has_feature(feat);
lic = license('test', feat);
r.feature = feat;
r.level = 4;
r.evidence{end+1} = sprintf('license(''test'',''%s'')=%d', feat, lic);
if installed && lic
    r.state = 'OK'; r.detail = sprintf('feature %s licensed', feat);
elseif ~installed && lic
    r.state = 'OK'; r.detail = sprintf('feature %s licensed (not listed in ver: a shared feature)', feat);
elseif installed && ~lic
    r.state = 'NOT_LICENSED'; r.detail = sprintf('feature %s installed but not licensed', feat);
else
    r.state = 'NOT_INSTALLED'; r.detail = sprintf('feature %s neither installed nor licensed', feat);
end
end

% ---------------------------------------------------------------------------
function r = probe_exec(r, expr, opts)
r.level = 0;
[ok, msg] = run_probe(expr);
if ok
    r.state = 'OK'; r.level = 5; r.detail = sprintf('"%s" ran', expr);
else
    r.state = 'EXEC_FAILED'; r.detail = sprintf('"%s" failed: %s', expr, msg);
    if opts.throw, error('mas_dep_probe:exec', '%s', msg); end
end
end

% ---------------------------------------------------------------------------
function [r, ok] = check_product_levels(r, pm, opts)
% Level 3: installed. Level 4: licensed. Writes the state and returns ok=false when
% the chain stops.
installed = any(strcmpi({ver().Name}, pm.name));
r.evidence{end+1} = sprintf('installed=%d', installed);
r.level = 3;
if ~installed
    r.state = 'NOT_INSTALLED';
    r.detail = sprintf('%s is not listed by ver()', pm.name);
    ok = false; return;
end
if pm.installationOnly
    r.state = 'OK';
    r.detail = sprintf('%s installed (installation-only; license(''test'') not applicable)', pm.name);
    r.evidence{end+1} = 'license not applicable';
    ok = true; return;
end
lic = license('test', pm.feature);
r.level = 4;
r.evidence{end+1} = sprintf('license(''test'',''%s'')=%d', pm.feature, lic);
if ~lic
    r.state = 'NOT_LICENSED';
    r.detail = sprintf('%s installed but feature %s not licensed', pm.name, pm.feature);
    ok = false; return;
end
ok = true;
end

% ---------------------------------------------------------------------------
function [ok, msg] = run_probe(expr)
% Evaluate an expression in a private workspace with output captured, so a
% successful probe can neither pollute the caller's variables nor print.
ok = false; msg = '';
try
    evalc(expr);
    ok = true;
catch ME
    msg = sprintf('%s: %s', ME.identifier, ME.message);
end
end

% ---------------------------------------------------------------------------
function tf = ver_has_feature(feat)
% ver() lists product NAMES, so an exact feature string rarely appears. Map it back
% through the table when possible; otherwise report "not listed" without claiming
% the feature is absent from the license.
m = mas_product_map('', 'all');
tf = false;
for k = 1:size(m,1)
    if strcmpi(m{k,2}, feat)
        tf = any(strcmpi({ver().Name}, m{k,1}));
        return;
    end
end
end

% ---------------------------------------------------------------------------
function o = with_defaults(o)
d = struct('deep', false, 'throw', false, 'skipExec', false);
fn = fieldnames(d);
for k = 1:numel(fn)
    if ~isfield(o, fn{k}), o.(fn{k}) = d.(fn{k}); end
end
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
