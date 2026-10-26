function res = test_skill_graph(verbose)
%TEST_SKILL_GRAPH  Pins the skill call-graph checker, including its detector.
%
%   res = test_skill_graph()
%
% The cycle detector gets the first block, and it is the part that needs it most:
% a graph checker whose detector cries wolf gets switched off, and a graph
% checker that misses a real routing loop ships one. So the detector is run
% against eight graphs whose answer is known by inspection -- empty, chain, self
% loop, 2-cycle, DIAMOND, star, tail-into-cycle, and two disjoint cycles. The
% diamond and the star are the shapes that produce false positives when a
% three-colour DFS is written with the wrong invariant.
%
% The second block checks the REAL repository: no cycle, every routed skill
% exists, every non-router skill is routable.

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
addpath(fullfile(fileparts(here), 'scripts'));

T = struct('name', {}, 'fn', {}, 'expect', {});

% ---- the detector, on graphs whose answer is known by inspection --------
det = { ...
  'det: empty graph -> 0',        @() detEmpty(),        0; ...
  'det: chain -> 0',              @() detChain(),        0; ...
  'det: self loop -> 1',          @() detSelf(),         1; ...
  'det: 2-cycle -> 1',            @() detTwo(),          1; ...
  'det: diamond -> 0',            @() detDiamond(),      0; ...
  'det: star -> 0',               @() detStar(),         0; ...
  'det: tail into cycle -> 1',    @() detTailCycle(),    1; ...
  'det: two disjoint -> 2',       @() detTwoCycles(),    2 };
for k = 1:size(det, 1)
    T(end+1) = mk(det{k,1}, det{k,2}, det{k,3}); %#ok<AGROW>
end

% ---- the real repository ------------------------------------------------
T(end+1) = mk('real: no routing cycle',     @() realNoCycle(),     true);
T(end+1) = mk('real: no dangling route',   @() realNoDangling(),  true);
T(end+1) = mk('real: all skills routable', @() realCoverage(),    true);
T(end+1) = mk('real: every skill found',   @() realNineSkills(),  true);
T(end+1) = mk('real: foreign ids excluded',@() realForeign(),     true);

% -------------------------------------------------------------------------
n = numel(T);
pass = false(n,1); got = cell(n,1);
for k = 1:n
    try
        got{k} = T(k).fn();
    catch ME
        got{k} = sprintf('<EXC %s>', ME.message);
    end
    if isnumeric(T(k).expect)
        pass(k) = isequal(double(got{k}), double(T(k).expect));
    else
        pass(k) = isequal(logical(got{k}), logical(T(k).expect));
    end
    if verbose
        if pass(k), s = 'PASS'; else, s = 'FAIL'; end
        fprintf('  %-4s %s\n', s, T(k).name);
    end
end
fprintf('test_skill_graph: %d / %d passed\n', sum(pass), n);
res = struct();
res.nPass = sum(pass);
res.nTotal = n;
res.pass = all(pass);
res.cases = {T.name};
end

% ===========================================================================
function adj = graph(names, eFrom, eTo)
adj = containers.Map('KeyType', 'char', 'ValueType', 'any');
for k = 1:numel(names), adj(names{k}) = {}; end
for k = 1:numel(eFrom)
    lst = adj(eFrom{k});
    lst{end+1} = eTo{k};
    adj(eFrom{k}) = lst;
end
end

function n = nCycles(names, eFrom, eTo)
c = mas_skill_graph('find-cycles', graph(names, eFrom, eTo), names);
n = numel(c);
end

% ---- the eight known graphs ---------------------------------------------
function n = detEmpty()
n = nCycles({'a'}, {}, {});
end
function n = detChain()
n = nCycles({'a','b','c'}, {'a','b'}, {'b','c'});
end
function n = detSelf()
n = nCycles({'a'}, {'a'}, {'a'});
end
function n = detTwo()
n = nCycles({'a','b'}, {'a','b'}, {'b','a'});
end
function n = detDiamond()
% a -> b -> d and a -> c -> d, with no path back. A DFS that treats a
% BLACK revisit as a cycle reports this one, which is the classic false alarm.
n = nCycles({'a','b','c','d'}, {'a','b','c','b','c'}, {'b','c','d','d','d'});
end
function n = detStar()
n = nCycles({'h','a','b','c','d'}, {'h','h','h','h'}, {'a','b','c','d'});
end
function n = detTailCycle()
n = nCycles({'a','b','c'}, {'a','b','c'}, {'b','c','b'});
end
function n = detTwoCycles()
% a->b->a and c->d->c are separate components; a detector that stops after
% the first component reports one and silently under-counts.
n = nCycles({'a','b','c','d'}, {'a','c','b','d'}, {'b','d','a','c'});
end

% ---- the real repository ------------------------------------------------
function v = realNoCycle()
r = mas_skill_graph('cycles');
v = isempty(r.cycles);
end

function v = realNoDangling()
r = mas_skill_graph('dangling');
v = r.ok;
end

function v = realCoverage()
r = mas_skill_graph('coverage');
v = r.ok;
end

function v = realNineSkills()
r = mas_skill_graph('cycles');
v = numel(r.graph.names) == 9;
end

function v = realForeign()
% `mcp.matlab-license`, `mcp.matlab-install` and `matlab-actions/*` all contain
% the substring "matlab-" and none of them is a skill. Counting them as edges
% produced a nine-skill cycle that does not exist.
r = mas_skill_graph('cycles');
tgt = {};
for k = 1:numel(r.graph.edges), tgt{end+1} = r.graph.edges(k).to; end
src = {};
for k = 1:numel(r.graph.edges), src{end+1} = r.graph.edges(k).from; end
v = isempty(intersect(tgt, {'matlab-actions','matlab-license','matlab-install'})) && ...
    all(~strcmp(src, 'matlab-actions'));
end

% ===========================================================================
function t = mk(name, fn, expect)
t = struct('name', name, 'fn', fn, 'expect', expect);
end