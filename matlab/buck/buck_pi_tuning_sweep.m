function sweep = buck_pi_tuning_sweep(configs, outDir)
%BUCK_PI_TUNING_SWEEP PI 调参扫描：每个配置恰好产生一条记录，失败不沿用
%
% 【Task4 事故复盘】旧版 buck_tuning_compare.m 的三个缺陷：
%   1) 用 numel(tunings) 遍历 4x3 cell 数组，得到 12 而非 4 —— 遍历数≠配置数；
%   2) 结果字段用循环序号命名（tuning1..tuning4），与 label 的对应关系脆弱；
%   3) 某个配置仿真抛错时没有隔离，可能静默沿用上一条的残留值。
% 本函数把三条不变量写进实现（调用方与回归测试逐条断言）：
%   I1  numel(sweep) == numel(configs)        —— 遍历数 = 配置数
%   I2  {sweep.id} 全唯一                     —— 唯一标识（label 净化+去重）
%   I3  status='failed' 的条目指标全 NaN/空   —— 失败不沿用、且不中断后续
%
% 输入:
%   configs - struct 数组，必填字段 Kp/Ki/label；可选 R/Vin/L/C/
%             loadStepTime/loadStepRatio/tStop（默认与额定工况一致）
%             Kp/Ki 必须是有限数值标量，否则该条记 failed（刻意保留的
%             失败路径，回归测试用它验证 I3）
%   outDir  - 可选；模型保存目录（默认 artifacts/validation/buck）
% 输出:
%   sweep - 与 configs 等长的 struct 数组：
%     id/label/Kp/Ki/status('ok'|'failed')/errMsg
%     Pm/Gm_dB/fc/maxRe                      线性分析（local_margins+闭环极点）
%     dipPct/recoverMs/startupOs/tailErrPct/dutyMin/dutyMax   时域指标
%     vC/t                                    时域波形（failed 为空）
%
% 实现说明：时域部分复用 build_buck_closed_loop_generic（单一实现），
% 每个配置独立建模仿真，模型名带序号防止串台。

if nargin < 2 || isempty(outDir)
    outDir = fullfile(fileparts(mfilename('fullpath')), '..', '..', ...
        'artifacts', 'validation', 'buck');
end
outDir = strrep(outDir, '/', filesep);
if ~exist(outDir, 'dir'); mkdir(outDir); end

n = numel(configs);
if iscell(configs)
    getCfg = @(k) configs{k};      % cell：可表达"缺字段"的配置（失败注入用）
else
    getCfg = @(k) configs(k);      % struct 数组：要求字段一致
end

% ---- 模板：所有指标预置 NaN / 波形预置空 —— I3 的结构性保证 ----
tmpl = struct('id','', 'label','', 'Kp',NaN, 'Ki',NaN, ...
    'status','not-run', 'errMsg','', ...
    'Pm',NaN, 'Gm_dB',NaN, 'fc',NaN, 'maxRe',NaN, ...
    'dipPct',NaN, 'recoverMs',NaN, 'startupOs',NaN, ...
    'tailErrPct',NaN, 'dutyMin',NaN, 'dutyMax',NaN, ...
    'vC',[], 't',[]);
sweep = repmat(tmpl, n, 1);

% ---- I2：唯一 id（label 净化 + 同基名自动加后缀）----
ids = cell(n,1);
for k = 1:n
    lbl = '';
    cfgK = getCfg(k);
    if isfield(cfgK,'label') && ~isempty(cfgK.label)
        lbl = char(string(cfgK.label));
    end
    base = matlab.lang.makeValidName(lbl);
    if isempty(base), base = sprintf('cfg%d', k); end
    ids{k} = base;
end
for k = 1:n
    prior = ids(1:k-1);
    c = sum(strcmp(prior, ids{k}));
    while c > 0
        cand = sprintf('%s_%d', ids{k}, c+1);
        if any(strcmp(prior, cand)), c = c + 1; else, ids{k} = cand; c = 0; end
    end
end

% ---- 逐配置执行：单条失败不影响其他条目 ----
for k = 1:n
    try
        cfg = getCfg(k);
        sweep(k).id    = ids{k};
        sweep(k).label = char(string(cfg.label));
        % —— 参数校验：非有限数值标量 -> 走失败路径 ——
        if ~isfield(cfg,'Kp') || ~isnumeric(cfg.Kp) || ~isscalar(cfg.Kp) || ~isfinite(cfg.Kp)
            error('buck:sweep:badKp', 'Kp 必须为有限数值标量');
        end
        if ~isfield(cfg,'Ki') || ~isnumeric(cfg.Ki) || ~isscalar(cfg.Ki) || ~isfinite(cfg.Ki)
            error('buck:sweep:badKi', 'Ki 必须为有限数值标量');
        end
        sweep(k).Kp = cfg.Kp;
        sweep(k).Ki = cfg.Ki;

        % —— 工况参数（带默认值）——
        R = 6;  Vin = 48;  L = 150e-6;  C = 220e-6;  Vref = 12;
        if isfield(cfg,'R'),   R = cfg.R;     end
        if isfield(cfg,'Vin'), Vin = cfg.Vin; end
        if isfield(cfg,'L'),   L = cfg.L;     end
        if isfield(cfg,'C'),   C = cfg.C;     end
        if isfield(cfg,'Vref'),Vref = cfg.Vref; end
        tStep = 0.03; ratio = 2; tStop = 0.06;   % 6Ω -> 3Ω（电导 x2）
        if isfield(cfg,'loadStepTime'),  tStep = cfg.loadStepTime;  end
        if isfield(cfg,'loadStepRatio'), ratio = cfg.loadStepRatio; end
        if isfield(cfg,'tStop'),         tStop = cfg.tStop;         end

        % —— 线性分析：该工况的 Gvd 与环路裕度 ——
        Gvd = tf(ss([0,-1/L; 1/C,-1/(R*C)], [Vin/L;0], [0 1], 0));
        Lp = pid(cfg.Kp, cfg.Ki, 0, 0) * Gvd;
        [Gm_dB, Pm, ~, Wcp] = local_margins(Lp);
        clp = pole(feedback(Lp, 1));
        sweep(k).Pm = Pm;  sweep(k).Gm_dB = Gm_dB;
        sweep(k).fc = Wcp/(2*pi);  sweep(k).maxRe = max(real(clp));

        % —— 时域：负载阶跃仿真（复用唯一实现）——
        bcfg = struct('Kp',cfg.Kp, 'Ki',cfg.Ki, 'R',R, 'Vin',Vin, ...
            'L',L, 'C',C, 'Vref',Vref, ...
            'loadStepTime',tStep, 'loadStepRatio',ratio, ...
            'tStop',tStop, 'maxStep',1e-6, ...
            'modelName', sprintf('tune_%02d_%s', k, ids{k}), ...
            'saveModel', false);
        r = build_buck_closed_loop_generic(outDir, bcfg);
        t = r.t; vC = r.vC; duty = r.duty;

        post = t >= tStep;
        [dip, di] = min(vC(post));
        sweep(k).dipPct = (dip - Vref)/Vref*100;
        post_v = vC(post); post_t = t(post);
        band = 0.01*Vref;
        bi = find(abs(post_v(di:end) - Vref) <= band, 1, 'first');
        if isempty(bi)
            sweep(k).recoverMs = NaN;
        else
            sweep(k).recoverMs = (post_t(di+bi-1) - tStep)*1e3;
        end
        sweep(k).startupOs  = (max(vC(~post)) - Vref)/Vref*100;
        tail = t > (tStop - 0.01);
        sweep(k).tailErrPct = (mean(vC(tail)) - Vref)/Vref*100;
        sweep(k).dutyMin = min(duty);
        sweep(k).dutyMax = max(duty);
        sweep(k).vC = vC;
        sweep(k).t  = t;
        sweep(k).status = 'ok';

    catch err
        % I3：只记录失败事实，不拷贝任何其他条目的数值
        sweep(k).status = 'failed';
        sweep(k).errMsg = err.message;
    end
end
end
