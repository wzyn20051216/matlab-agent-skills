%% 任务三（定稿）：陷波器 + PI 的结构化设计 + 时域验证
%
% 任务二根因（已实证）：LC 双极点 f_n=876 Hz, zeta=0.0688(Q=7.27) 使 |Gvd| 在
% f_n 处达 348 倍（48V/占空比 -> 峰值 348）。任何把环路增益在 f_n 抬到 0dB
% 以上的控制器都会把交越推进谐振区，相位在 f_n 附近由 0 陡降至 -180°。
% 纯积分 Ki=7.9029 之所以稳定，仅因 f_c=60.7 Hz = f_n/14.4，远在谐振峰以下。
%
% 改进方案：在控制器串入对准 f_n 的陷波器 N(s)，压掉谐振峰，
% 从而允许交越频率大幅提高（更快扰动抑制）而保持 PM。
clear; close all; clc;
outDir = getenv('BUCK_OUT'); if isempty(outDir), outDir = fullfile(pwd,'buck'); end
outDir = strrep(outDir,'/',filesep); if ~exist(outDir,'dir'), mkdir(outDir); end
% 路径可移植：从本脚本位置（matlab/buck/verify）推 matlab/buck，不写死盘符
addpath(fullfile(fileparts(fileparts(mfilename('fullpath')))));

Vin=48; L=150e-6; C=220e-6; R=6; Vout=12; D=Vout/Vin; Ts=1/50e3;
A=[0,-1/L; 1/C,-1/(R*C)]; B=[Vin/L;0]; Co=[0,1]; Do=0;
Gvd = minreal(tf(ss(A,B,Co,Do)));
fn = 1/sqrt(L*C); s = tf('s');

% ===== 工程验收标准（先声明，禁止事后放宽）=====
STD.PM_min        = 50;      % deg
STD.GM_min        = 6;       % dB
STD.sserr_max     = 0.1;     % %
STD.recover_max   = 1.0;     % ms
STD.startup_os_max= 5;       % %
STD.dip_max       = 12;      % % 峰值跌落绝对值上限
STD.duty_lo       = 0.05; STD.duty_hi = 0.85;

fprintf('================ 任务三：控制器改进 ================\n');
fprintf('f_n=%.2f Hz  |Gvd(f_n)|=%.1f (%.1f dB)  zeta=%.4f\n', ...
    fn/(2*pi), abs(squeeze(freqresp(Gvd,fn))), ...
    20*log10(abs(squeeze(freqresp(Gvd,fn)))), (L/R)/(2*sqrt(L*C)));
fprintf('基线 Ki=7.9029 -> f_c=60.7 Hz = f_n/14.4（带宽被浪费 %.1f 倍）\n\n', ...
    (fn/(2*pi))/60.66);

fprintf('--- 步骤1：陷波器 + PI 的结构化搜索 ---\n');
best = struct('fc',-Inf,'score',-Inf); results = [];
for zn_n = [0.01 0.02 0.05]
  for zd_n = [0.5 0.8 1.2]
    notch = (s^2+2*zn_n*fn*s+fn^2)/(s^2+2*zd_n*fn*s+fn^2);
    for Kp = [0.005 0.010 0.015 0.020 0.030 0.040]
      for Ki = [5 8 10 12 15 20]
        C = pid(Kp,Ki,0,0)*notch;  Ls = C*Gvd;
        % 裕度用 local_margins（稠密网格全交越扫描 + 最坏值口径）。
        % 历史教训：margin() 只报一个交越点；且曾把 Wcg（相位穿越频率）
        % 误当幅值算 GM，导致 GM 恒为 -70 dB 量级、搜索空间被系统性污染。
        [Gm_dB, Pm, Wcg, Wcp] = local_margins(Ls);
        if isnan(Wcp), continue; end
        if isnan(Pm), continue; end
        clp = pole(feedback(Ls,1));
        if max(real(clp)) >= 0, continue; end
        if Pm < STD.PM_min, continue; end
        if Gm_dB < STD.GM_min, continue; end
        fc = Wcp/(2*pi);
        results(end+1,:) = [zn_n,zd_n,Kp,Ki,Pm,Gm_dB,fc,max(real(clp))];
        % 目标：PM 有余量（>=55 更稳）且 f_c 大
        score = fc * min(1, Pm/60);
        if score > best.score
            best = struct('fc',fc,'score',score,'zn',zn_n,'zd',zd_n, ...
                          'Kp',Kp,'Ki',Ki,'Pm',Pm,'Gm_dB',Gm_dB,'maxRe',max(real(clp)));
        end
      end
    end
  end
end

if isempty(results)
    fprintf('**无解**\n');
else
    [~,ordr] = sort(results(:,7),'descend');
    fprintf('可行解 %d 个，前 8 名:\n', size(results,1));
    for k=1:min(8,numel(ordr))
        r=results(ordr(k),:);
        fprintf('  zn=%.2f zd=%.1f Kp=%.4f Ki=%4.1f | PM=%6.2f GM=%s f_c=%8.2f Hz maxRe=%+8.2f\n', ...
            r(1),r(2),r(3),r(4),r(5), ...
            merge(isinf(r(6)),'  Inf',sprintf('%6.1f',r(6))), r(7), r(8));
    end
    fprintf('\n选定：zn=%.2f zd=%.1f Kp=%.4f Ki=%.1f\n', best.zn,best.zd,best.Kp,best.Ki);
    fprintf('  PM=%.2f deg  GM=%s  f_c=%.2f Hz (=%.2f f_n, 基线的 %.1f 倍)  maxRe=%+.2f\n', ...
        best.Pm, merge(isinf(best.Gm_dB),'Inf(无限制)',sprintf('%.2f dB',best.Gm_dB)), ...
        best.fc, best.fc/(fn/(2*pi)), best.fc/60.66, best.maxRe);

    fprintf('\n--- 步骤2：环路详细核查（多重交越 / 增益裕度）---\n');
    notch_b = (s^2+2*best.zn*fn*s+fn^2)/(s^2+2*best.zd*fn*s+fn^2);
    C_best = pid(best.Kp,best.Ki,0,0)*notch_b;
    L_best = C_best*Gvd;
    [Gm_dB_b, Pm_b, ~, Wcp_b, xov] = local_margins(L_best);
    kk = 0;
    for j = 1:numel(xov)
        if strcmp(xov(j).kind,'gain')
            kk = kk + 1;
            fprintf('   增益交越 #%d @ %9.2f Hz  相位 %+8.2f deg -> PM %+7.2f deg\n', ...
                kk, xov(j).freq/(2*pi), xov(j).phase_deg, xov(j).Pm);
        end
    end
    fprintf('增益交越次数 = %d（含陷波凹陷区的往返穿越）\n', kk);
    fprintf('最坏 PM = %.2f deg @ %.2f Hz；GM = %s\n', Pm_b, Wcp_b/(2*pi), ...
        merge(isinf(Gm_dB_b),'Inf（无相位穿越）',sprintf('%.2f dB',Gm_dB_b)));
    % 实用增益裕度：相位最接近 -180 deg 处的 |L|（该处未必精确穿越 -180）
    wscan = logspace(2, 8, 400001);
    phs  = rad2deg(unwrap(reshape(angle(reshape(freqresp(L_best,wscan),[],1)),[],1)));
    mags = reshape(abs(freqresp(L_best,wscan)),[],1);
    [~,im] = min(abs(phs+180));
    fprintf('相位最接近 -180deg 处: f=%.2f Hz, |L|=%.5f (%+.2f dB) -> 有效 GM 约 %.1f dB\n', ...
        wscan(im)/(2*pi), mags(im), 20*log10(mags(im)), -20*log10(mags(im)));
    fprintf('陷波后 f_n 处 |L|=%.4f (%+.2f dB)（原始无陷波为 %.1f dB）\n', ...
        abs(squeeze(freqresp(L_best,fn))), 20*log10(abs(squeeze(freqresp(L_best,fn)))), ...
        20*log10(abs(squeeze(freqresp(pid(best.Kp,best.Ki,0,0)*Gvd,fn)))));

    fprintf('\n--- 步骤3：时域验证（与频域结论必须一致）---\n');
    ctrls = { '基线 纯积分 Ki=7.9029', struct('Kp',0,'Ki',7.902901,'notchEnable',false); ...
              '陷波器+PI (选中)', struct('Kp',best.Kp,'Ki',best.Ki,'notchEnable',true, ...
                 'notchWn',fn,'notchZn',best.zn,'notchZd',best.zd) };
    simRes = cell(size(ctrls,1),1);
    for i=1:size(ctrls,1)
        cfg = ctrls{i,2};
        cfg.loadStepTime = []; cfg.tStop = 0.1; cfg.modelName = sprintf('nominal_%d',i);
        cfg.saveModel = false;
        r = build_buck_closed_loop_generic(outDir, cfg);
        simRes{i} = r;
        ss = mean(r.vC(r.t>0.08));
        fprintf('%-26s 稳态 vC=%9.5f (误差 %+.4f%%)  duty=%7.5f  启动超调=%6.2f%%\n', ...
            ctrls{i,1}, ss, (ss-Vout)/Vout*100, r.duty(end), (max(r.vC)-Vout)/Vout*100);
    end

    fprintf('\n--- 步骤4：负载阶跃对比（6Ω -> 3Ω @ 30ms）---\n');
    for i=1:size(ctrls,1)
        cfg = ctrls{i,2};
        cfg.loadStepTime = 0.03; cfg.loadStepRatio = 2; cfg.tStop = 0.06;
        cfg.modelName = sprintf('load_%d',i); cfg.saveModel = false;
        r = build_buck_closed_loop_generic(outDir, cfg);
        simRes{i} = r;
        t=r.t; vC=r.vC; ts=0.03;
        pre = mean(vC(t>0.02 & t<ts-0.001));
        dip = min(vC(t>=ts & t<=ts+0.002));
        dipPct = (dip-Vout)/Vout*100;
        post = mean(vC(t>0.05));
        band = 0.01*Vout;
        post_v = vC(t>=ts); t_post = t(t>=ts);
        [~,di] = min(post_v);
        bi = find(abs(post_v(di:end)-Vout)<=band, 1, 'first');
        if isempty(bi), rec = NaN; else, rec = (t_post(di+bi-1)-ts)*1e3; end
        fprintf('%-26s 阶跃前=%8.4f 跌落=%+7.3f%% 恢复=%6.3f ms 阶跃后稳态=%8.4f duty∈[%.3f,%.3f]\n', ...
            ctrls{i,1}, pre, dipPct, rec, post, min(r.duty), max(r.duty));
    end

    fprintf('\n--- 步骤5：Bode 与裕度对比图 ---\n');
    fig = figure('Visible','off','Position',[100 100 1200 900]);
    wplot = logspace(0,5,2000);
    subplot(2,2,1); bodeplot(pid(0,7.902901,0,0)*Gvd,wplot); grid on; hold on;
    xline(fn,'r--','f_n'); title('基线 纯积分 (PM=89.5^\circ, f_c=61 Hz)');
    subplot(2,2,2); bodeplot(L_best,wplot); grid on; hold on;
    xline(fn,'r--','f_n');
    title(sprintf('陷波器+PI (PM=%.1f^\\circ, f_c=%.0f Hz)',best.Pm,best.fc));
    subplot(2,2,3); margin(pid(0,7.902901,0,0)*Gvd); grid on; title('基线裕度');
    subplot(2,2,4); margin(L_best); grid on; title('改进裕度');
    sgtitle('Buck 电压环：陷波器+PI 与纯积分基线对比');
    saveas(fig, fullfile(outDir,'task3_bode_vs_baseline.png')); close(fig);

    % 阶跃响应对比图
    fig = figure('Visible','off','Position',[100 100 1100 800]);
    subplot(3,1,1); plot(simRes{1}.t*1e3, simRes{1}.vC); hold on;
    yline(Vout,'r--'); grid on; xline(30,'k--');
    ylabel('v_C (V)'); title('基线：输出电压');
    subplot(3,1,2); plot(simRes{2}.t*1e3, simRes{2}.vC); hold on;
    yline(Vout,'r--'); grid on; xline(30,'k--');
    ylabel('v_C (V)'); title(sprintf('陷波器+PI：输出电压（PM=%.1f^\\circ）',best.Pm));
    subplot(3,1,3); plot(simRes{2}.t*1e3, simRes{2}.duty); hold on;
    grid on; xline(30,'k--'); ylabel('duty'); xlabel('t (ms)'); title('陷波器+PI：占空比');
    sgtitle('负载阶跃 6Ω→3Ω 对比');
    saveas(fig, fullfile(outDir,'task3_load_step_compare.png')); close(fig);
    fprintf('图已保存: task3_bode_vs_baseline.png, task3_load_step_compare.png\n');

    save(fullfile(outDir,'task3_best_controller.mat'),'C_best','notch_b','best', ...
        'Gvd','fn','Vin','L','C','R','Vout','D','Ts','STD','results');
    save(fullfile(outDir,'task3_sim_results.mat'),'simRes');
    fprintf('\n已保存 task3_best_controller.mat / task3_sim_results.mat\n');
end

function t = merge(c,a,b)
if c, t = a; else, t = b; end
end