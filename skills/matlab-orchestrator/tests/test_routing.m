function res = test_routing(verbose)
%TEST_ROUTING  Pins the routing behaviour the Phase 4 brief asks for.
%
%   res = test_routing()
%
% Each case states an EXPECTATION, not a snapshot: the three examples from the
% brief must route correctly, a below-threshold prompt must ask rather than guess,
% and a genuine two-way tie must be reported as ambiguous. A router that answers
% everything confidently is worse than no router at all.

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
addpath(fullfile(fileparts(here),'scripts'));

T = struct('name',{},'prompt',{},'opts',{},'expectDecision',{}, ...
    'expectPrimary',{},'rejectPrimary',{},'expectSecondary',{});

T(end+1) = mk('OFDM bit-error-rate', '分析 OFDM 通信系统的误码率', struct(), ...
    'ROUTE','matlab-signal-vision-ai','matlab-control-optimization','');
T(end+1) = mk('three-phase inverter THD', '设计三相逆变器并分析 THD', struct(), ...
    'ROUTE','matlab-simulink-modeling','matlab-control-optimization','matlab-signal-vision-ai');
T(end+1) = mk('KITTI detection', '使用 KITTI 进行目标检测实验', struct(), ...
    'ROUTE','matlab-signal-vision-ai','matlab-control-optimization','');
T(end+1) = mk('PID speed loop', '用 pidtune 调一个电机转速环', struct(), ...
    'ROUTE','matlab-control-optimization','matlab-signal-vision-ai','');
T(end+1) = mk('codegen to STM32', '把 Simulink 模型生成 C 代码部署到 STM32', struct(), ...
    'ROUTE','matlab-codegen-deploy','matlab-data-analysis','');
T(end+1) = mk('CSV to paper figure', '整理 CSV 数据并画论文图', struct(), ...
    'ROUTE','matlab-data-analysis','matlab-codegen-deploy','');
T(end+1) = mk('weak signal asks', '同时做控制与图像处理', struct(), ...
    'CLARIFY','','','');
T(end+1) = mk('true tie is ambiguous', '同时做控制与图像处理', struct('minScore',2), ...
    'AMBIGUOUS','','','');
T(end+1) = mk('no signal asks', '帮我看看这个', struct(), 'CLARIFY','','','');

nP = 0;
if verbose, fprintf('=== routing tests ===\n'); end
R = struct('case',{},'decision',{},'primary',{},'pass',{},'detail',{});
for k = 1:numel(T)
    t = T(k);
    r = mas_route(t.prompt, t.opts);
    ok = strcmp(r.decision, t.expectDecision);
    if ~isempty(t.expectPrimary), ok = ok && strcmp(r.primary, t.expectPrimary); end
    if ~isempty(t.rejectPrimary)
        idx = find(strcmp({r.ranked.id}, t.rejectPrimary), 1);
        ok = ok && (isempty(idx) || r.ranked(idx).score < r.ranked(1).score);
    end
    if ~isempty(t.expectSecondary)
        ok = ok && any(strcmp(r.loadOrder, t.expectSecondary));
    end
    if strcmp(r.decision,'ROUTE')
        ok = ok && any(strcmp(r.loadOrder,'matlab-runner'));
    end
    nP = nP + ok;
    if verbose
        fprintf('  [%s] %-22s -> %-9s %s\n', tern(ok,'PASS','FAIL'), t.name, ...
            r.decision, tern(isempty(r.primary),'-',r.primary));
        if ~ok, fprintf('        %s\n', r.reason); end
    end
    R(end+1) = struct('case',t.name,'decision',r.decision,'primary',r.primary, ...
        'pass',ok,'detail',r.reason); %#ok<AGROW>
end

res = struct('nPass',nP,'nTotal',numel(T),'cases',R,'pass',nP==numel(T));
if verbose, fprintf('\n---- %d / %d routing cases passed ----\n', nP, numel(T)); end
end

% ---------------------------------------------------------------------------
function t = mk(name, prompt, opts, dec, prim, rej, sec)
t = struct('name',name,'prompt',prompt,'opts',opts,'expectDecision',dec, ...
    'expectPrimary',prim,'rejectPrimary',rej,'expectSecondary',sec);
end

function s = tern(c,a,b)
if c, s = a; else, s = b; end
end
