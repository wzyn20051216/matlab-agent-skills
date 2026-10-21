function build_buck_switching_model2(outDir)
if nargin < 1 || isempty(outDir)
    outDir = getenv('BUCK_OUT');
    if isempty(outDir)
        outDir = fullfile(pwd, 'buck');
    end
end
outDir = strrep(outDir, '/', filesep);
if ~exist(outDir, 'dir'); mkdir(outDir); end
close all;

%% ---- 参数 ----
Vin   = 48;
fsw   = 50e3;
L     = 150e-6;
C     = 220e-6;
R     = 6;
D     = 12/Vin;      % 0.25，由伏秒平衡得出
Tsw   = 1/fsw;
Tstop = 0.02;
LoadStepTime = [];   % 开关级本轮只做稳态（负载阶跃在闭环模型里做）

%% ---- 状态空间（负载用电导外部反馈，与平均模型同构）----
A = [0, -1/L; 1/C, 0];
B = [1/L, 0; 0, -1/C];     % 输入 u=[v_sw; i_load]，注意此处 v_sw 是斩波电压本身
                        % 所以 Vin 由 Switch 乘法器承担，不进 B —— 与 v1 的
                        % "Vin*d 进 B" 形式等价，但这里能显式看到电感电流
C_out = [0 1; 1 0];
D_out = [0 0; 0 0];

mdl = 'buck_switching_plant';
if bdIsLoaded(mdl); close_system(mdl, 0); end
new_system(mdl); open_system(mdl);

% --- PWM 载波：carrier = mod(t/Tsw, 1) ∈ [0,1) ---
add_block('simulink/Sources/Clock', [mdl '/Clock']);
add_block('simulink/Math Operations/Gain', [mdl '/InvTsw'], 'Gain', num2str(1/Tsw));
add_block('simulink/Math Operations/Math Function', [mdl '/Mod'], 'Function', 'mod');
add_block('simulink/Sources/Constant', [mdl '/One'], 'Value', '1');

% --- 占空比（可被闭环覆盖；本轮用常量）---
add_block('simulink/Sources/Constant', [mdl '/Duty'], 'Value', num2str(D));

% --- 比较器：duty > carrier -> 1 (开关导通) ---
add_block('simulink/Logic and Bit Operations/Relational Operator', [mdl '/Compare'], 'Operator', '>');

% --- 理想开关：v_sw = s(t) * Vin ---
add_block('simulink/Sources/Constant', [mdl '/Vin'], 'Value', num2str(Vin));
add_block('simulink/Math Operations/Product', [mdl '/Switch'], 'Inputs', '2');

% --- 负载电导 G(t)=1/R（外部反馈实现，便于后续做负载阶跃）---
add_block('simulink/Sources/Constant', [mdl '/Conductance'], 'Value', num2str(1/R));

% --- 被控对象：iL 与 vC 均为显式状态 ---
add_block('simulink/Continuous/State-Space', [mdl '/Plant'], ...
    'A', mat2str(A), 'B', mat2str(B), 'C', mat2str(C_out), 'D', mat2str(D_out), ...
    'X0', mat2str([0;0]));

add_block('simulink/Math Operations/Product', [mdl '/Load'], 'Inputs', '2');
add_block('simulink/Signal Routing/Mux',  [mdl '/Mux'], 'Inputs', '2');
add_block('simulink/Signal Routing/Demux',[mdl '/Demux'], 'Outputs', '2');

add_block('simulink/Sinks/To Workspace', [mdl '/vC_sink'], 'VariableName', 'vC',  'SaveFormat', 'Timeseries');
add_block('simulink/Sinks/To Workspace', [mdl '/iL_sink'], 'VariableName', 'iL',  'SaveFormat', 'Timeseries');
add_block('simulink/Sinks/To Workspace', [mdl '/vsw_sink'],'VariableName', 'vsw', 'SaveFormat', 'Timeseries');

% --- 连线 ---
add_line(mdl, 'Clock/1',     'InvTsw/1');
add_line(mdl, 'InvTsw/1',    'Mod/1');
add_line(mdl, 'One/1',       'Mod/2');
add_line(mdl, 'Mod/1',       'Compare/2');
add_line(mdl, 'Duty/1',      'Compare/1');
add_line(mdl, 'Compare/1',   'Switch/1');
add_line(mdl, 'Vin/1',       'Switch/2');
add_line(mdl, 'Switch/1',    'Mux/1');        % v_sw
add_line(mdl, 'Demux/1',     'Load/1');       % vC
add_line(mdl, 'Conductance/1','Load/2');      % G
add_line(mdl, 'Load/1',      'Mux/2');        % i_load = vC/R
add_line(mdl, 'Mux/1',       'Plant/1');
add_line(mdl, 'Plant/1',     'Demux/1');
add_line(mdl, 'Demux/1',     'vC_sink/1');
add_line(mdl, 'Demux/2',     'iL_sink/1');
add_line(mdl, 'Switch/1',    'vsw_sink/1');

% ode45 + 变步长：每开关周期至少 500 步，保证能捕捉开关纹波
set_param(mdl, 'StopTime', num2str(Tstop), 'Solver', 'ode45', 'MaxStep', num2str(Tsw/500));
save_system(mdl, fullfile(outDir, 'buck_switching_plant.slx'));

%% ---- 仿真 ----
simout = sim(mdl);
vC  = simout.vC.Data;
iL  = simout.iL.Data;
vsw = simout.vsw.Data;
t   = simout.vC.Time;

%% ---- 分析（窗口只取末 10 个开关周期，避免把过渡过程算进纹波）----
lastPeriods = t > (t(end) - 10*Tsw);
vC_ss = mean(vC(lastPeriods));
iL_ss = mean(iL(lastPeriods));
vC_ripple = max(vC(lastPeriods)) - min(vC(lastPeriods));
iL_ripple = max(iL(lastPeriods)) - min(iL(lastPeriods));
iL_min    = min(iL(lastPeriods));
d_meas    = mean(vsw(lastPeriods))/Vin;

% 理论值（CCM, 理想 Buck）
dI_L_theory = (Vin - 12) * D / (L * fsw);
dvC_theory = dI_L_theory / (8 * C * fsw);
VinLdI_theory = (Vin - 12) * D;      % 伏秒平衡：L*dI_L/dt = Vin-Vout

fprintf('=== 开关级模型 v2（显式电感电流）===\n');
fprintf('vC 稳态均值      = %.4f V   (理论 12 V, 误差 %.4f V)\n', vC_ss, vC_ss - 12);
fprintf('iL 稳态均值      = %.4f A   (理论 Vout/R = %.4f A)\n', iL_ss, 12/R);
fprintf('vC 纹波(峰峰)    = %.4f mV  (理论 %.4f mV)\n', vC_ripple*1e3, dvC_theory*1e3);
fprintf('iL 纹波(峰峰)    = %.4f A   (理论 %.4f A)\n', iL_ripple, dI_L_theory);
fprintf('iL 最小值        = %.4f A   (>0 则 CCM 成立)\n', iL_min);
fprintf('实测占空比        = %.5f     (理论 %.5f)\n', d_meas, D);
fprintf('CCM 判据 ΔiL/iL_ss = %.2f%%  (<100%% 即 CCM)\n', iL_ripple/iL_ss*100);

% 伏秒平衡数值验证：L*diL/dt 的平均值应等于 Vin-Vout
LdiLdt = L * gradient(iL, t);
fprintf('伏秒平衡验证: <L*diL/dt> = %.4f V (理论 Vin-Vout = %.4f V)\n', ...
    mean(LdiLdt(lastPeriods)), VinLdI_theory);

save(fullfile(outDir, 'buck_switching_results.mat'), 't', 'vC', 'iL', 'vsw', ...
    'Vin','fsw','L','C','R','D','Tsw','vC_ss','iL_ss','vC_ripple','iL_ripple', ...
    'dI_L_theory','dvC_theory','iL_min','d_meas');

%% ---- 画图 ----
fig = figure('Visible','off','Position',[100 100 1000 900]);
subplot(3,1,1);
plot(t*1e3, vC); grid on; xlabel('t (ms)'); ylabel('v_C (V)');
title(sprintf('开关级模型 v2：输出电压（稳态 %.4f V，纹波 %.2f mV）', vC_ss, vC_ripple*1e3));
subplot(3,1,2);
plot(t*1e3, iL); grid on; xlabel('t (ms)'); ylabel('i_L (A)');
title(sprintf('电感电流（稳态 %.4f A，纹波 %.4f A）', iL_ss, iL_ripple));
subplot(3,1,3);
plot(t*1e3, vsw); grid on; xlabel('t (ms)'); ylabel('v_{sw} (V)');
title('斩波电压 v_{sw}（PWM 方波，占空比 0.25）');
saveas(fig, fullfile(outDir, 'buck_switching_response.png'));
close(fig);

% 稳态放大图（3 个开关周期）
zoomWin = t > (t(end) - 3*Tsw);
fig = figure('Visible','off','Position',[100 100 1000 700]);
subplot(2,1,1);
plot(t(zoomWin)*1e6, vC(zoomWin), 'LineWidth', 1.2); grid on;
xlabel('t (us)'); ylabel('v_C (V)'); title('稳态放大：输出电压开关纹波');
subplot(2,1,2);
plot(t(zoomWin)*1e6, iL(zoomWin), 'LineWidth', 1.2); grid on;
xlabel('t (us)'); ylabel('i_L (A)'); title('稳态放大：电感电流纹波（v2 新增能力）');
saveas(fig, fullfile(outDir, 'buck_switching_steady_zoom.png'));
close(fig);

close_system(mdl, 0);
fprintf('模型已保存：%s\n', fullfile(outDir, 'buck_switching_plant.slx'));
fprintf('结果已保存：%s\n', fullfile(outDir, 'buck_switching_results.mat'));
end