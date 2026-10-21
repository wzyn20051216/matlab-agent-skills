function r = mas_route(prompt, opts)
%MAS_ROUTE  Pick the MATLAB skills a natural-language request needs.
%
%   r = mas_route("分析 OFDM 通信系统的误码率")
%   r = mas_route(prompt, struct('minScore',3,'multiSkillRatio',0.6))
%
% WHY A TABLE AND NOT A JUDGEMENT CALL
% "Load the right skill" is the one decision that silently ruins a run: pick the
% control skill for an OFDM question and the agent will happily tune a PID for a
% bit-error-rate problem. A weighted term table is inspectable, deterministic and
% testable; ../tests/test_routing.m pins the three examples from the Phase 4 brief
% plus the cases that must NOT route (below threshold, two-way tie).
%
% RULES
%   * matlab-runner is always loaded: whatever the domain, execution is needed.
%   * score = sum of matched term weights (Chinese and English), no normalisation,
%     so one strong term can carry a short prompt.
%   * score < minScore            -> CLARIFY   (ask, do not guess)
%   * top two domains tie exactly -> AMBIGUOUS (ask, do not guess)
%   * secondary skills join when their score >= multiSkillRatio * top score.
%
% The table lives in ../assets/routing.json as an OBJECT keyed by skill id. It is
% not an array because JSON arrays whose objects have different key sets do not
% decode into a MATLAB struct array.

if nargin < 2, opts = struct(); end
here = fileparts(mfilename('fullpath'));
tblFile = fullfile(fileparts(here),'assets','routing.json');
if ~isfile(tblFile)
    error('mas_route:noTable','routing table not found: %s', tblFile);
end
T = jsondecode(fileread(tblFile));
if isfield(opts,'minScore'), T.minScore = opts.minScore; end
if isfield(opts,'multiSkillRatio'), T.multiSkillRatio = opts.multiSkillRatio; end

p = lower(char(prompt));
keys = fieldnames(T.skills);
% jsondecode maps "matlab-simulink-modeling" to the field matlab_simulink_modeling,
% so the DIRECTORY name is carried inside the object as s.id.
ids = cell(numel(keys),1);
for k = 1:numel(keys)
    s = T.skills.(keys{k});
    if isfield(s,'id'), ids{k} = char(s.id); else, ids{k} = keys{k}; end
end
n = numel(keys);
score = zeros(n,1);
hits  = cell(n,1);
always = false(n,1);

for k = 1:n
    s = T.skills.(keys{k});
    always(k) = isfield(s,'always') && logical(s.always);
    if ~isfield(s,'terms') || isempty(s.terms), continue; end
    terms = s.terms;
    % terms is a struct array of {t,w}; tolerate the single-term cell form too
    if isstruct(terms) && numel(terms) >= 1 && isfield(terms,'t')
        for q = 1:numel(terms)
            tq = terms(q).t; wq = terms(q).w;
            if iscell(tq), tq = tq{1}; end
            if iscell(wq), wq = wq{1}; end
            if contains(p, lower(char(tq)))
                score(k) = score(k) + wq;
                hits{k}{end+1} = char(tq);
            end
        end
    end
end

dom = find(~always);
[~, ord] = sort(score(dom),'descend');
dom = dom(ord);
ranked = repmat(struct('id','','score',0,'hits',{{}}), numel(dom), 1);
for k = 1:numel(dom)
    ranked(k).id    = ids{dom(k)};
    ranked(k).score = score(dom(k));
    ranked(k).hits  = hits{dom(k)};      % cellstr, possibly empty
end

top = 0; second = 0;
if ~isempty(ranked)
    top = ranked(1).score;
    if numel(ranked) > 1, second = ranked(2).score; end
end

r = struct();
r.ranked = ranked;
r.alwaysLoaded = ids(always).';
r.prompt = char(prompt);

if top < T.minScore
    r.decision = 'CLARIFY';
    r.primary = '';
    r.secondary = {};
    r.loadOrder = r.alwaysLoaded;
    if isempty(ranked)
        r.reason = sprintf('no term matched any domain (need >= %g)', T.minScore);
    else
        r.reason = sprintf(['best domain %s scored %g, below the %g threshold; ' ...
            'ask one clarifying question instead of guessing'], ...
            ranked(1).id, top, T.minScore);
    end
    return;
end

if second >= top
    r.decision = 'AMBIGUOUS';
    r.primary = '';
    r.secondary = {};
    r.loadOrder = r.alwaysLoaded;
    r.reason = sprintf(['%s and %s both scored %g; the request does not say ' ...
        'which carries the core work'], ranked(1).id, ranked(2).id, top);
    return;
end

r.decision = 'ROUTE';
r.primary = ranked(1).id;
sec = {};
for k = 2:numel(ranked)
    if ranked(k).score >= T.multiSkillRatio*top
        sec{end+1} = ranked(k).id; %#ok<AGROW>
    end
end
r.secondary = sec;
r.loadOrder = [r.alwaysLoaded, {r.primary}, sec];
if (any(strcmp(sec,'matlab-testing-ci')) || contains(p,'验收') || contains(p,'回归')) ...
        && ~any(strcmp(r.loadOrder,'matlab-testing-ci'))
    r.loadOrder{end+1} = 'matlab-testing-ci';
end
r.reason = sprintf('routed to %s (score %g); %d secondary skill(s)', ...
    r.primary, top, numel(sec));
end
