function res = test_routing_contract(verbose)
%TEST_ROUTING_CONTRACT  Schema, refusals, dependencies, and misleading keywords.
%
%   res = test_routing_contract()
%
% The historical test_routing.m pins the scoring examples. This file pins the
% CONTRACT a consumer can rely on: every decision carries the same fields, a
% route never contains a duplicate or a nonexistent skill, dependencies load
% before dependents, and an unavailable skill/toolbox terminates with BLOCKED
% instead of a partial pipeline.

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
addpath(fullfile(fileparts(here), 'scripts'));

C = {
    'A real route: contract fields + loadable'      @caseA
    'B single domain: no irrelevant loads'          @caseB
    'C multi-skill: secondary joins'                @caseC
    'D similar domains: AMBIGUOUS'                  @caseD
    'E unknown request: CLARIFY'                    @caseE
    'F negation: Simulink is excluded'              @caseF
    'G clause-scoped negation: PID survives'        @caseG
    'H short ASCII token: no substring match'       @caseH
    'I missing toolbox: BLOCKED'                    @caseI
    'J uninstalled skill: BLOCKED'                  @caseJ
    'K damaged skill: BLOCKED'                      @caseK
    'L dependency order: runner -> beta -> alpha'   @caseL
    'M missing dependency: BLOCKED'                 @caseM
    'N dependency cycle: BLOCKED'                   @caseN
    'O blocked output carries no load order'        @caseO
    'P matched weights equal ranked scores'         @caseP
};

nP = 0;
R = struct('case', {}, 'pass', {}, 'detail', {});
if verbose, fprintf('=== routing contract tests ===\n'); end
for k = 1:size(C, 1)
    try
        [ok, detail] = C{k, 2}();
    catch ME
        ok = false;
        detail = [ME.identifier ' :: ' ME.message];
    end
    nP = nP + ok;
    if verbose
        fprintf('  [%s] %-46s %s\n', tern(ok, 'PASS', 'FAIL'), C{k, 1}, detail);
    end
    R(end+1) = struct('case', C{k, 1}, 'pass', ok, 'detail', detail); %#ok<AGROW>
end

res = struct('nPass', nP, 'nTotal', size(C, 1), 'cases', R, 'pass', nP == size(C, 1));
if verbose, fprintf('\n---- %d / %d routing-contract cases passed ----\n', nP, size(C, 1)); end
end

% ===========================================================================
function [ok, d] = caseA()
r = mas_route('分析 OFDM 通信系统的误码率');
ok = has_contract(r) && strcmp(r.decision, 'ROUTE') && ...
    strcmp(r.primary, 'matlab-signal-vision-ai') && ...
    strcmp(r.nextAction, 'load') && strcmp(r.schemaVersion, '1.1') && ...
    strcmp(r.tableVersion, '1.1') && ...
    all([r.available.loadable]) && isempty(r.missing) && ...
    numel(unique(r.loadOrder)) == numel(r.loadOrder) && ...
    all_skills_exist(r.loadOrder);
d = sprintf('dec=%s primary=%s load=%s', r.decision, r.primary, strjoin(r.loadOrder, '>'));
end

function [ok, d] = caseB()
r = mas_route('分析 OFDM 通信系统的误码率');
skip = {'matlab-control-optimization', 'matlab-codegen-deploy', ...
    'matlab-data-analysis', 'matlab-simulink-modeling', 'matlab-robotics-autonomy'};
ok = strcmp(r.decision, 'ROUTE') && ~any(ismember(skip, r.loadOrder)) && ...
    isempty(r.secondary) && any(strcmp(r.loadOrder, 'matlab-runner'));
d = sprintf('load=%s sec=%s', strjoin(r.loadOrder, '>'), strjoin(r.secondary, ','));
end

function [ok, d] = caseC()
r = mas_route('设计三相逆变器并分析 THD');
ok = strcmp(r.decision, 'ROUTE') && strcmp(r.primary, 'matlab-simulink-modeling') && ...
    any(strcmp(r.secondary, 'matlab-signal-vision-ai')) && ...
    any(strcmp(r.loadOrder, 'matlab-signal-vision-ai')) && ...
    numel(unique(r.loadOrder)) == numel(r.loadOrder);
d = sprintf('primary=%s load=%s', r.primary, strjoin(r.loadOrder, '>'));
end

function [ok, d] = caseD()
r = mas_route('设计低通滤波器并分析相位裕度');
top2 = {r.ranked(1).id, r.ranked(2).id};
ok = strcmp(r.decision, 'AMBIGUOUS') && isempty(r.primary) && ...
    strcmp(r.nextAction, 'ask') && any(strcmp(top2, 'matlab-signal-vision-ai')) && ...
    any(strcmp(top2, 'matlab-control-optimization')) && ...
    ~any(strcmp(r.loadOrder, 'matlab-control-optimization'));
d = sprintf('dec=%s top=%s,%s', r.decision, top2{1}, top2{2});
end

function [ok, d] = caseE()
r = mas_route('帮我看看这个');
ok = strcmp(r.decision, 'CLARIFY') && isempty(r.primary) && ...
    isempty(r.matched) && strcmp(r.nextAction, 'ask');
d = sprintf('dec=%s matched=%d', r.decision, numel(r.matched));
end

function [ok, d] = caseF()
r = mas_route('不要用 Simulink，分析 OFDM 误码率');
ok = strcmp(r.decision, 'ROUTE') && strcmp(r.primary, 'matlab-signal-vision-ai') && ...
    ~any(strcmp({r.matched.skill}, 'matlab-simulink-modeling')) && ...
    ~any(strcmp(r.loadOrder, 'matlab-simulink-modeling'));
d = sprintf('primary=%s load=%s', r.primary, strjoin(r.loadOrder, '>'));
end

function [ok, d] = caseG()
r = mas_route('不做图像处理，只做 PID 控制');
ok = strcmp(r.decision, 'ROUTE') && strcmp(r.primary, 'matlab-control-optimization') && ...
    ~any(strcmp({r.matched.skill}, 'matlab-signal-vision-ai'));
d = sprintf('dec=%s primary=%s matched=%d', r.decision, r.primary, numel(r.matched));
end

function [ok, d] = caseH()
r = mas_route('分析 specific efficiency');
ok = strcmp(r.decision, 'CLARIFY') && isempty(r.matched);
d = sprintf('dec=%s matched=%d', r.decision, numel(r.matched));
end

function [ok, d] = caseI()
opts = struct('toolboxStatus', {{'MATLAB Coder', false}});
r = mas_route('把 Simulink 模型生成 C 代码部署到 STM32', opts);
ok = strcmp(r.decision, 'BLOCKED') && strcmp(r.nextAction, 'stop') && ...
    isempty(r.primary) && isempty(r.loadOrder) && ...
    has_missing(r, 'toolbox', 'MATLAB Coder');
d = sprintf('dec=%s missing=%s', r.decision, missing_names(r));
end

function [ok, d] = caseJ()
opts = struct('skillStatus', {{'matlab-signal-vision-ai', 'missing'}});
r = mas_route('分析 OFDM 通信系统的误码率', opts);
ok = strcmp(r.decision, 'BLOCKED') && isempty(r.loadOrder) && ...
    has_missing(r, 'skill', 'matlab-signal-vision-ai');
d = sprintf('dec=%s missing=%s', r.decision, missing_names(r));
end

function [ok, d] = caseK()
opts = struct('skillStatus', {{'matlab-signal-vision-ai', 'damaged'}});
r = mas_route('分析 OFDM 通信系统的误码率', opts);
ok = strcmp(r.decision, 'BLOCKED') && isempty(r.loadOrder) && ...
    has_missing(r, 'content', 'matlab-signal-vision-ai');
d = sprintf('dec=%s missing=%s', r.decision, missing_names(r));
end

function [ok, d] = caseL()
T = fixture_order();
opts = struct('table', T, 'skillStatus', ...
    {{'runner', 'ok'; 'beta', 'ok'; 'alpha', 'ok'}});
r = mas_route('alpha task', opts);
expect = {'runner', 'beta', 'alpha'};
ok = strcmp(r.decision, 'ROUTE') && isequal(r.loadOrder, expect);
d = sprintf('load=%s', strjoin(r.loadOrder, '>'));
end

function [ok, d] = caseM()
T = fixture_missing_dep();
opts = struct('table', T, 'skillStatus', {{'runner', 'ok'; 'gamma', 'ok'}});
r = mas_route('gamma task', opts);
ok = strcmp(r.decision, 'BLOCKED') && isempty(r.loadOrder) && ...
    has_missing(r, 'dependency', 'ghost');
d = sprintf('dec=%s missing=%s', r.decision, missing_names(r));
end

function [ok, d] = caseN()
T = fixture_cycle();
opts = struct('table', T, 'skillStatus', ...
    {{'runner', 'ok'; 'alpha', 'ok'; 'beta', 'ok'}});
r = mas_route('alpha task', opts);
ok = strcmp(r.decision, 'BLOCKED') && isempty(r.loadOrder) && ...
    any(strcmp({r.missing.kind}, 'dependency_cycle'));
d = sprintf('dec=%s missing=%s', r.decision, missing_names(r));
end

function [ok, d] = caseO()
opts = struct('toolboxStatus', {{'MATLAB Coder', false}});
r = mas_route('把 Simulink 模型生成 C 代码部署到 STM32', opts);
ok = strcmp(r.decision, 'BLOCKED') && isempty(r.loadOrder) && ...
    isempty(r.secondary) && ~any(strcmp(r.loadOrder, 'matlab-runner'));
d = sprintf('loadOrder=%d secondary=%d', numel(r.loadOrder), numel(r.secondary));
end

function [ok, d] = caseP()
r = mas_route('分析 OFDM 通信系统的误码率');
sk = 'matlab-signal-vision-ai';
w = sum([r.matched(strcmp({r.matched.skill}, sk)).weight]);
idx = find(strcmp({r.ranked.id}, sk), 1);
ok = ~isempty(idx) && w == r.ranked(idx).score;
d = sprintf('matchedWeight=%g ranked=%g', w, r.ranked(idx).score);
end

% ===========================================================================
function T = fixture_order()
T = struct('version', '1.1', 'minScore', 3, 'multiSkillRatio', 0.6);
T.skills = struct();
T.skills.runner = sk('runner', true, {}, []);
T.skills.beta = sk('beta', false, {'runner'}, term('beta task', 4));
T.skills.alpha = sk('alpha', false, {'beta'}, term('alpha task', 4));
end

function T = fixture_missing_dep()
T = struct('version', '1.1', 'minScore', 3, 'multiSkillRatio', 0.6);
T.skills = struct();
T.skills.runner = sk('runner', true, {}, []);
T.skills.gamma = sk('gamma', false, {'ghost'}, term('gamma task', 4));
end

function T = fixture_cycle()
T = struct('version', '1.1', 'minScore', 3, 'multiSkillRatio', 0.6);
T.skills = struct();
T.skills.runner = sk('runner', true, {}, []);
T.skills.alpha = sk('alpha', false, {'beta'}, term('alpha task', 4));
T.skills.beta = sk('beta', false, {'alpha'}, term('beta task', 4));
end

function s = sk(id, always, deps, terms)
s = struct('id', id, 'always', always, 'priority', 1, ...
    'dependsOn', {deps}, 'terms', {terms});
end

function t = term(text, w)
t = struct('t', text, 'w', w);
end

function tf = has_contract(r)
need = {'schemaVersion', 'decision', 'primary', 'loadOrder', 'matched', ...
    'missing', 'reason', 'available', 'nextAction'};
tf = isstruct(r) && all(isfield(r, need));
end

function tf = has_missing(r, kind, name)
tf = any(strcmp({r.missing.kind}, kind) & strcmp({r.missing.name}, name));
end

function s = missing_names(r)
if isempty(r.missing), s = ''; return; end
parts = cell(1, numel(r.missing));
for k = 1:numel(r.missing)
    parts{k} = [r.missing(k).kind ':' r.missing(k).name];
end
s = strjoin(parts, ',');
end

function tf = all_skills_exist(ids)
repo = fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
tf = true;
for k = 1:numel(ids)
    if ~isfolder(fullfile(repo, 'skills', ids{k})), tf = false; return; end
end
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
