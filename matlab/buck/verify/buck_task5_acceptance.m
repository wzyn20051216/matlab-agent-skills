%% 任务五（定稿）：工程验收 —— 7 工况 × 2 控制器 × 3 次重复
%
% ============ 验收标准（先声明，禁止事后放宽）============
%   S1 闭环稳定          : 闭环极点 maxRe < 0
%   S2 相位裕度          : 全部 0dB 交越的最坏 PM >= 50 deg（local_margins）
%   S3 增益裕度          : GM >= 6 dB
%   S4 稳态误差          : 负载阶跃后 |ssErr| <= 0.1 %
%   S5 恢复时间          : 阶跃后进入 ±1% 频带 <= 1.0 ms
%   S6 启动超调          : <= 5 %
%   S7 阶跃跌落          : |dip| <= 12 %
%   S8 占空比余量        : 阶跃后 duty ∈ [0.05, 0.85]（不贴限幅）
%   S9 可复现性          : 同一配置 3 次重复，指标/波形偏差 < 1e-9
%
% ============ 工况（7 个）============
%   C1 额定        Vin=48  R=6    L/C 标称
%   C2 输入低压    Vin=42  R=6
%   C3 输入高压    Vin=54  R=6
%   C4 轻载        Vin=48  R=12
%   C5 重载        Vin=48  R=3
%   C6 高压+重载   Vin=54  R=3
%   C7 电感+30%    Vin=48  R=6    L=195uH（f_n 降 12%，陷波器失谐=鲁棒性测试）
%
% ============ 控制器（2 个）============
%   BASE 纯积分 Ki=7.902901（基线，作为对照）
%   OPT  陷波器+PI（任务三定稿，参数从 task3_best_controller.mat 读取，不硬编码）
%
% 输出: task5_acceptance.mat / task5_acceptance.json / task5_acceptance_overview.png
clear; close all;
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, '..'));
outDir = getenv('BUCK_OUT');
if isempty(outDir), outDir = fullfile(here, '..', '..', 'artifacts', 'validation', 'buck'); end
outDir = strrep(outDir, '/', filesep);
if ~exist(outDir, 'dir'); mkdir(outDir); end

t0 = clock;
fprintf('================ 任务五：工程验收（7 工况 x 2 控制器 x 3 次）================\n');

%% ---------- 标准 ----------
STD.PM_min = 50;  STD.GM_min = 6;  STD.sserr_max = 0.1;  STD.recover_max = 1.0;
STD.startup_os_max = 5;  STD.dip_max = 12;  STD.duty_lo = 0.05;  STD.duty_hi = 0.85;
fprintf('标准: PM>=%g°, GM>=%gdB, |ssErr|<=%g%%, 恢复<=%gms, 超调<=%g%%, |跌落|<=%g%%, duty∈[%g,%g]\n', ...
    STD.PM_min, STD.GM_min, STD.sserr_max, STD.recover_max, ...
    STD.startup_os_max, STD.dip_max, STD.duty_lo, STD.duty_hi);

%% ---------- 工况与控制器 ----------
conds = [
    struct('id','C1','desc','额定',        'Vin',48,'R',6,  'L',150e-6,'C',220e-6)
    struct('id','C2','desc','输入低压42V', 'Vin',42,'R',6,  'L',150e-6,'C',220e-6)
    struct('id','C3','desc','输入高压54V', 'Vin',54,'R',6,  'L',150e-6,'C',220e-6)
    struct('id','C4','desc','轻载12Ω',     'Vin',48,'R',12, 'L',150e-6,'C',220e-6)
    struct('id','C5','desc','重载3Ω',      'Vin',48,'R',3,  'L',150e-6,'C',220e-6)
    struct('id','C6','desc','高压+重载',   'Vin',54,'R',3,  'L',150e-6,'C',220e-6)
    struct('id','C7','desc','电感+30%',    'Vin',48,'R',6,  'L',195e-6,'C',220e-6)
];

% OPT 参数来自任务三定稿（可复现：不把数字抄进脚本）
d3 = load(fullfile(outDir, 'task3_best_controller.mat'));
b = d3.best; fnNom = d3.fn;
ctrls = [
    struct('id','BASE','desc','纯积分 Ki=7.90', ...
        'cfg', struct('Kp',0,'Ki',7.902901,'notchEnable',false))
    struct('id','OPT','desc','陷波器+PI(任务三)', ...
        'cfg', struct('Kp',b.Kp,'Ki',b.Ki,'notchEnable',true, ...
                      'notchWn',fnNom,'notchZn',b.zn,'notchZd',b.zd))
];
fprintf('OPT 参数（读自 task3_best_controller.mat）: Kp=%.4f Ki=%.4f zn=%.3f zd=%.2f f_n=%.1f rad/s\n', ...
    b.Kp, b.Ki, b.zn, b.zd, fnNom);

%% ---------- 主循环 ----------
tStep = 0.06; ratio = 2; tStop = 0.12; nRep = 3;   % 6Ω->3Ω（电导 x2，重载阶跃）
% 注意：必须初始化为**空结构体数组**。若写 recs=[]（double），
% recs(end+1)=struct(...) 会触发"无法从 struct 转换为 double"（历史崩溃点）。
recs = struct('cond',{}, 'condDesc',{}, 'Vin',{}, 'R',{}, 'L',{}, ...
    'ctrl',{}, 'ctrlDesc',{}, 'Pm',{}, 'Gm',{}, 'fc',{}, 'maxRe',{}, ...
    'dipPct',{}, 'recoverMs',{}, 'startupOs',{}, 'postStepOs',{}, ...
    'ssErrPct',{}, 'dutyMin',{}, 'dutyMax',{}, ...
    'devRecMs',{}, 'devVc',{}, 'pass',{}, 't',{}, 'vC',{});
verdicts = struct('S1',{}, 'S2',{}, 'S3',{}, 'S4',{}, 'S5',{}, ...
    'S6',{}, 'S7',{}, 'S8',{}, 'S9',{}, 'all',{});
for ic = 1:numel(conds)
    c = conds(ic);
    for it = 1:numel(ctrls)
        k = ctrls(it);
        fprintf('\n--- %s %s（Vin=%g, R=%g, L=%guH）x %s ---\n', ...
            c.id, c.desc, c.Vin, c.R, c.L*1e6, k.id);

        % ---- 线性分析（该工况的 Gvd）----
        Gvd = tf(ss([0,-1/c.L; 1/c.C,-1/(c.R*c.C)], [c.Vin/c.L;0], [0 1], 0));
        Cc = k.cfg;
        if Cc.notchEnable
            s = tf('s');
            notch = (s^2+2*Cc.notchZn*Cc.notchWn*s+Cc.notchWn^2)/ ...
                    (s^2+2*Cc.notchZd*Cc.notchWn*s+Cc.notchWn^2);
            Cp = pid(Cc.Kp,Cc.Ki,0,0)*notch;
        else
            Cp = pid(Cc.Kp,Cc.Ki,0,0);
        end
        Lp = Cp*Gvd;
        [Gm_dB, Pm_worst, ~, Wcp] = local_margins(Lp);
        fc = Wcp/(2*pi);
        clp = pole(feedback(Lp,1));
        maxRe = max(real(clp));

        % ---- 时域：3 次重复 ----
        dipA = []; recA = []; osA = []; psoA = []; ssA = []; dminA = []; dmaxA = [];
        vCs = {}; vC1 = []; t1 = [];
        for ir = 1:nRep
            bcfg = struct('Kp',Cc.Kp,'Ki',Cc.Ki,'R',c.R,'Vin',c.Vin, ...
                'L',c.L,'C',c.C,'Vref',12, ...
                'loadStepTime',tStep,'loadStepRatio',ratio, ...
                'tStop',tStop,'maxStep',1e-6, ...
                'modelName', sprintf('acc_%s_%s_r%d', c.id, k.id, ir), ...
                'saveModel', false);
            if Cc.notchEnable
                bcfg.notchEnable = true;
                bcfg.notchWn = Cc.notchWn; bcfg.notchZn = Cc.notchZn; bcfg.notchZd = Cc.notchZd;
            end
            r = build_buck_closed_loop_generic(outDir, bcfg);
            t = r.t; vC = r.vC; duty = r.duty;
            post = t >= tStep;
            [dip, di] = min(vC(post));
            post_v = vC(post); post_t = t(post);
            band = 0.01*12;
            bi = find(abs(post_v(di:end)-12) <= band, 1, 'first');
            if isempty(bi), rec = NaN; else, rec = (post_t(di+bi-1)-tStep)*1e3; end
            dipA(ir)  = (dip-12)/12*100;
            recA(ir)  = rec;
            osA(ir)   = (max(vC(~post))-12)/12*100;
            psoA(ir)  = (max(vC(post))-12)/12*100;     % 信息性：阶跃后超调（不门禁）
            ssA(ir)   = (mean(vC(t > tStop-0.01))-12)/12*100;
            dminA(ir) = min(duty(post));
            dmaxA(ir) = max(duty(post));
            vCs{ir} = vC; %#ok<SAGROW>
            if ir == 1, vC1 = vC; t1 = t; end
        end

        % ---- S9 可复现性 ----
        devRec = max(abs(recA - recA(1)));
        devVc = Inf;
        if numel(vCs{1}) == numel(vCs{2}) && numel(vCs{2}) == numel(vCs{3})
            devVc = max(max(abs(vCs{1} - vCs{2})), max(abs(vCs{2} - vCs{3})));
        end

        % ---- 判定（用第 1 次的指标；S9 已证 3 次一致）----
        m1 = struct('dipPct',dipA(1),'recoverMs',recA(1),'startupOs',osA(1), ...
            'postStepOs',psoA(1),'ssErrPct',ssA(1),'dutyMin',dminA(1),'dutyMax',dmaxA(1));
        v.S1 = maxRe < 0;
        v.S2 = Pm_worst >= STD.PM_min;
        v.S3 = Gm_dB >= STD.GM_min;
        v.S4 = abs(m1.ssErrPct) <= STD.sserr_max;
        v.S5 = m1.recoverMs <= STD.recover_max;
        v.S6 = m1.startupOs <= STD.startup_os_max;
        v.S7 = abs(m1.dipPct) <= STD.dip_max;
        v.S8 = m1.dutyMin >= STD.duty_lo && m1.dutyMax <= STD.duty_hi;
        v.S9 = (devRec < 1e-9) && (devVc < 1e-9);
        v.all = v.S1 && v.S2 && v.S3 && v.S4 && v.S5 && v.S6 && v.S7 && v.S8 && v.S9;

        fprintf('线性: PM_worst=%7.2f°  GM=%7s dB  fc=%8.1f Hz  maxRe=%+9.2f\n', ...
            Pm_worst, merge3(isinf(Gm_dB),'Inf',sprintf('%.2f',Gm_dB)), fc, maxRe);
        fprintf('时域: 跌落=%+7.3f%%  恢复=%7.3f ms  阶跃后超调=%+7.3f%%  启动超调=%+6.3f%%  稳态误差=%+7.4f%%  duty∈[%.3f,%.3f]\n', ...
            m1.dipPct, m1.recoverMs, m1.postStepOs, m1.startupOs, m1.ssErrPct, m1.dutyMin, m1.dutyMax);
        if v.all
            fprintf('判定: PASS（S1-S9 全过）\n');
        else
            fnv = fieldnames(v);
            bad = fnv(arrayfun(@(i) ~v.(fnv{i}), 1:numel(fnv)-1)); %#ok<NBRAK>
            fprintf('判定: FAIL -> 未过项: %s\n', strjoin(bad, ', '));
        end

        recs(end+1) = struct('cond',c.id,'condDesc',c.desc,'Vin',c.Vin,'R',c.R,'L',c.L, ...
            'ctrl',k.id,'ctrlDesc',k.desc, ...
            'Pm',Pm_worst,'Gm',Gm_dB,'fc',fc,'maxRe',maxRe, ...
            'dipPct',m1.dipPct,'recoverMs',m1.recoverMs,'startupOs',m1.startupOs, ...
            'postStepOs',m1.postStepOs, ...
            'ssErrPct',m1.ssErrPct,'dutyMin',m1.dutyMin,'dutyMax',m1.dutyMax, ...
            'devRecMs',devRec,'devVc',devVc, ...
            'pass',v.all, ...
            't',t1,'vC',vC1); %#ok<SAGROW>
        verdicts(end+1) = v; %#ok<SAGROW>
    end
end

%% ---------- 汇总 ----------
fprintf('\n================ 验收汇总 ================\n');
fprintf('%-4s %-12s %-6s %8s %8s %9s %9s %8s %8s %6s\n', ...
    '工况','说明','控制器','PM(°)','GM(dB)','跌落%','恢复ms','超调%','ssErr%','判定');
for k = 1:numel(recs)
    r = recs(k);
    fprintf('%-4s %-12s %-6s %8.2f %8s %9.3f %9.3f %8.3f %8.4f %6s\n', ...
        r.cond, r.condDesc, r.ctrl, r.Pm, ...
        merge3(isinf(r.Gm),'Inf',sprintf('%.2f',r.Gm)), ...
        r.dipPct, r.recoverMs, r.startupOs, r.ssErrPct, ...
        merge3(r.pass,'PASS','FAIL'));
end
nOpt = sum(strcmp({recs.ctrl},'OPT') & [recs.pass]);
nBase = sum(strcmp({recs.ctrl},'BASE') & [recs.pass]);
fprintf('\nBASE: %d/7 PASS   OPT: %d/7 PASS\n', nBase, nOpt);
maxDev = max(max([recs.devRecMs]), max([recs.devVc]));
fprintf('可复现性: 3 次重复最大偏差 = %.3e（恢复时间 ms / 波形 V，阈值 1e-9）\n', maxDev);

%% ---------- 图 ----------
fig = figure('Visible','off','Position',[100 100 1400 900]);
cids = {conds.id}; xv = 1:numel(conds);
idxB = strcmp({recs.ctrl},'BASE'); idxO = strcmp({recs.ctrl},'OPT');
barpair(1, [recs(idxB).Pm],        [recs(idxO).Pm],        STD.PM_min,        '最坏相位裕度（全部 0dB 交越）', 'PM (deg)', false, xv, cids);
barpair(2, [recs(idxB).Gm],        [recs(idxO).Gm],        STD.GM_min,        '增益裕度',                       'GM (dB)',  false, xv, cids);
barpair(3, [recs(idxB).dipPct],    [recs(idxO).dipPct],    -STD.dip_max,      '负载阶跃跌落',                   'dip (%)',  false, xv, cids);
barpair(4, [recs(idxB).recoverMs], [recs(idxO).recoverMs], STD.recover_max,   '恢复时间（±1% 频带）',           'recover (ms)', true, xv, cids);
barpair(5, [recs(idxB).ssErrPct],  [recs(idxO).ssErrPct],  0,                 '阶跃后稳态误差',                 'ssErr (%)', false, xv, cids);
barpair(6, [recs(idxB).startupOs], [recs(idxO).startupOs], STD.startup_os_max,'启动超调',                       'overshoot (%)', false, xv, cids);
sgtitle(sprintf('任务五验收：7 工况 x 2 控制器（BASE %d/7, OPT %d/7）', nBase, nOpt));
saveas(fig, fullfile(outDir,'task5_acceptance_overview.png')); close(fig);

%% ---------- 保存 ----------
recSave = recs;
for k = 1:numel(recSave)
    recSave(k).t = []; recSave(k).vC = [];
end
save(fullfile(outDir,'task5_acceptance.mat'), 'recs','verdicts','STD','conds','ctrls','b','fnNom');
jsonTxt = jsonencode(struct('standard',STD,'conds',conds,'controllers',ctrls, ...
    'results',recSave,'summary',struct('basePass',nBase,'optPass',nOpt, ...
    'maxReproDev',maxDev,'matlabVersion',version,'generatedAt',datestr(now,31))));
fid = fopen(fullfile(outDir,'task5_acceptance.json'),'w');
fwrite(fid, jsonTxt, 'char'); fclose(fid);
fprintf('\n图与数据已保存: task5_acceptance_overview.png / task5_acceptance.mat / task5_acceptance.json\n');
fprintf('总耗时 %.1f 分钟\n', etime(clock,t0)/60);

function barpair(ax, valsB, valsO, thr, ttl, ylab, logy, xv, cids)
subplot(2,3,ax); hold on; grid on;
hB = bar(xv-0.2, valsB, 0.38, 'FaceColor', [0.55 0.55 0.55], 'EdgeColor', 'k');
hO = bar(xv+0.2, valsO, 0.38, 'FaceColor', [0.16 0.42 0.72], 'EdgeColor', 'k');
hT = [];
if thr ~= 0
    hT = yline(thr, 'r--', 'LineWidth', 1.5);
end
if logy, set(gca, 'YScale', 'log'); end
set(gca, 'XTick', xv, 'XTickLabel', cids);
xlabel('工况'); ylabel(ylab); title(ttl);
if thr ~= 0
    legend([hB, hO, hT], {'BASE 纯积分', 'OPT 陷波器+PI', '标准线'}, 'Location', 'best');
else
    legend([hB, hO], {'BASE 纯积分', 'OPT 陷波器+PI'}, 'Location', 'best');
end
end

function t = merge3(c, a, b)
if c, t = a; else, t = b; end
end
