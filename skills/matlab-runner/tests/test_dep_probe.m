function res = test_dep_probe(verbose)
%TEST_DEP_PROBE  Pins the five-level dependency discovery and the name aliases.
%
%   res = test_dep_probe()
%
% Half of these cases must FAIL to resolve: a probe that answers "OK" for a folder
% name, for a bogus product, or for a product whose feature is spelled the display
% name, is worse than no probe at all -- it turns a fixable environment problem
% into a mystery.

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
addpath(fullfile(fileparts(here), 'scripts'));

T = struct('name', {}, 'fn', {}, 'expectState', {}, 'expectPass', {}, 'check', {});
T(end+1) = tc('callable function',        @() mas_dep_probe('function', 'butter'),                     'OK', true, '');
T(end+1) = tc('folder is not a function', @() mas_dep_probe('function', 'robotics'),                   'IS_A_DIRECTORY', false, '');
T(end+1) = tc('bogus function name',      @() mas_dep_probe('function', 'no_such_fn_xyz'),             'FN_NOT_FOUND', false, '');
T(end+1) = tc('licensed product',         @() mas_dep_probe('product', 'Signal Processing Toolbox'),  'OK', true, '');
T(end+1) = tc('product by old name',      @() mas_dep_probe('product', 'Neural Network Toolbox'),     'OK', true, 'Deep Learning Toolbox');
T(end+1) = tc('product alias 2',          @() mas_dep_probe('product', 'Statistics Toolbox'),         'OK', true, 'Statistics and Machine Learning Toolbox');
T(end+1) = tc('case insensitive',         @() mas_dep_probe('product', 'signal processing toolbox'),  'OK', true, '');
T(end+1) = tc('unknown product',          @() mas_dep_probe('product', 'Quantum Nonsense Toolbox'),   'UNKNOWN_PRODUCT', false, '');
T(end+1) = tc('feature name as product',  @() mas_dep_probe('product', 'Signal_Toolbox'),             'UNKNOWN_PRODUCT', false, '');
T(end+1) = tc('feature probe',            @() mas_dep_probe('feature', 'Signal_Toolbox'),             'OK', true, '');
T(end+1) = tc('exec probe ok',            @() mas_dep_probe('exec', 'x = 1;'),                         'OK', true, '');
T(end+1) = tc('exec probe fails',         @() mas_dep_probe('exec', 'error(''boom'')'),                'EXEC_FAILED', false, '');
T(end+1) = tc('deep function probe',      @() mas_dep_probe('function', 'tf', struct('deep', true)),  'OK', true, '');

% the legacy entry point must still answer, and must agree with the new one
tb = mas_precheck('toolbox', 'Signal Processing Toolbox');

nP = 0;
if verbose, fprintf('=== dependency probe tests ===\n'); end
R = struct('case', {}, 'state', {}, 'level', {}, 'pass', {}, 'detail', {});
for k = 1:numel(T)
    t = T(k);
    r = t.fn();
    ok = strcmp(r.state, t.expectState) && (r.pass == t.expectPass);
    if ~isempty(t.check)
        ok = ok && strcmp(r.product, t.check);
    end
    nP = nP + ok;
    if verbose
        fprintf('  [%s] %-24s -> %-16s L%d  %s\n', tern(ok, 'PASS', 'FAIL'), ...
            t.name, r.state, r.level, shorten(r.detail));
    end
    R(end+1) = struct('case', t.name, 'state', r.state, 'level', r.level, ...
        'pass', ok, 'detail', r.detail); %#ok<AGROW>
end

okTb = tb.pass && isfield(tb.value, 'feature') && strcmp(tb.value.feature, 'Signal_Toolbox');
nP = nP + okTb;
if verbose
    fprintf('  [%s] %-24s -> %s\n', tern(okTb, 'PASS', 'FAIL'), 'mas_precheck delegate', tb.detail);
end

% ---- aliases must map to the SAME feature, not a second copy -----------------
aliasPairs = { ...
    'Deep Learning Toolbox',   'Neural Network Toolbox'; ...
    'Statistics and Machine Learning Toolbox', 'Statistics Toolbox'; ...
    'Simscape Electrical',     'Simscape Power Systems'};
nAlias = 0;
for k = 1:size(aliasPairs, 1)
    a = mas_product_map(aliasPairs{k, 1});
    b = mas_product_map(aliasPairs{k, 2});
    nAlias = nAlias + (a.found && b.found && strcmp(a.feature, b.feature) && ...
        strcmp(a.name, b.name));
end
if verbose
    fprintf('  [%s] %-24s -> %d/%d alias pairs share one row\n', ...
        tern(nAlias == size(aliasPairs, 1), 'PASS', 'FAIL'), 'cross-version aliases', ...
        nAlias, size(aliasPairs, 1));
end

total = numel(T) + 1 + size(aliasPairs, 1);
allok = (nP + nAlias) == total;
res = struct('nPass', nP + nAlias, 'nTotal', total, 'cases', R, 'pass', allok, ...
    'legacyDelegate', tb);
if verbose
    fprintf('\n---- %d / %d dependency cases passed ----\n', nP + nAlias, total);
end
end

% ---------------------------------------------------------------------------
function t = tc(name, fn, state, pass, product)
t = struct('name', name, 'fn', fn, 'expectState', state, 'expectPass', pass, ...
    'check', product);
end

function s = shorten(s)
if numel(s) > 72, s = [s(1:69) '...']; end
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
