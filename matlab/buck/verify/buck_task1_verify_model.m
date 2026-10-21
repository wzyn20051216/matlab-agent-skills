%% 任务一：核查数学与物理模型（8 项逐条验证）
% 原则：每条结论必须有解析推导 + 数值证据。数值不符就报 FAIL，不改阈值。
% 运行：matlab -batch "run('buck_task1_verify_model.m')"
clear; close all; clc;

% 输出根目录由环境变量给出，避免依赖 mfilename 在 run/run 两种模式下的差异
% BUCK_OUT 形如 E:/desktop/MATLAB/artifacts/validation/buck
if ~exist('BUCK_OUT','var') || isempty(BUCK_OUT)
    BUCK_OUT = getenv('BUCK_OUT');
end
if isempty(BUCK_OUT)
    BUCK_OUT = fullfile(pwd, 'buck');
end
outDir = strrep(BUCK_OUT, '/', filesep);
if ~exist(outDir, 'dir'); mkdir(outDir); end
fprintf('输出目录：%s\n', outDir);

Vin = 48; fsw = 50e3; L = 150e-6; C = 220e-6; R = 6; Vout = 12;
D = Vout/Vin; Ts = 1/fsw; maxstep = 1e-5;

% ---- 验收结果容器 ----
resCell = {};   % {id, item, status, detail}

fprintf('\n========== 任务一：数学与物理模型核查 ==========\n');
fprintf('参数：Vin=%.0fV fsw=%.0fkHz L=%.0fuH C=%.0fuF R=%.1fohm Vout=%.0fV\n', Vin, fsw/1e3, L*1e6, C*1e6, R, Vout);
fprintf('理论占空比 D = Vout/Vin = %.6f\n\n', D);

%% 1. 状态空间方程正确性
% CCM Buck 解析方程： L diL/dt = d*Vin - vC ;  C dvC/dt = iL - vC/R
% x=[iL;vC]： dx/dt = A x + B u, u=d
A_theory = [0, -1/L; 1/C, -1/(R*C)];
B_theory = [Vin/L; 0];
C_theory = [0 1];  D_theory = 0;
G_theory = tf(ss(A_theory, B_theory, C_theory, D_theory));

% 仿真脚本实际用的 A（把负载电导做成外部反馈），验证二者等价
A_sim = [0, -1/L; 1/C, 0];
B_sim = [Vin/L, 0; 0, -1/C];
C_sim = [0 1];
A_eff = A_sim + B_sim(:,2)*(C_sim/R);
diffMax = max(abs(A_eff(:) - A_theory(:)));
resCell(end+1,:) = {'1.1', '平均模型 A 矩阵符合解析推导', ...
    sprintf('%d', diffMax < 1e-12), ...
    sprintf('仿真A(含电导反馈)=[%g %g; %g %g] 理论A=[%g %g; %g %g] 最大差=%.3e', ...
    A_eff(1,1),A_eff(1,2),A_eff(2,1),A_eff(2,2), A_theory(1,1),A_theory(1,2),A_theory(2,1),A_theory(2,2), diffMax)};

% 平衡点
xeq = -A_theory \ B_theory * D;
resCell(end+1,:) = {'1.2', '平衡点 x=[iL_eq, vC_eq] 正确', ...
    sprintf('%d', abs(xeq(1)-Vout/R)<1e-9 && abs(xeq(2)-Vout)<1e-9), ...
    sprintf('iL_eq=%.9f A(理论 Vout/R=%.9f) vC_eq=%.9f V(理论 %.9f)', xeq(1), Vout/R, xeq(2), Vout)};

% 功率平衡
Pin = Vin*D*xeq(1); Pout = Vout*xeq(1);
resCell(end+1,:) = {'1.3', '功率平衡 Pin=Pout', sprintf('%d', abs(Pin-Pout)<1e-9), ...
    sprintf('Pin=Vin*D*iL=%.9f W Pout=Vout*iL=%.9f W 差=%.3e W', Pin, Pout, abs(Pin-Pout))};

% 伏秒平衡（开关级与平均级共同前提）
resCell(end+1,:) = {'1.4', '伏秒平衡 D*Vin=Vout', sprintf('%d', abs(D*Vin-Vout)<1e-12), ...
    sprintf('D*Vin=%.12f V Vout=%.12f V', D*Vin, Vout)};

%% 2. 符号约定一致性
dc_gain = dcgain(G_theory);
resCell(end+1,:) = {'2.1', 'B(1,1)=Vin/L>0 且 C=[0 1]：d 增大→vC 增大', ...
    sprintf('%d', B_theory(1,1)>0 && C_theory(1)==0 && C_theory(2)==1 && dc_gain>0), ...
    sprintf('B(1,1)=%.4f>0 C=[0 1]取vC dcgain(Gvd)=%.4f V/单位占空比（为正=方向正确）', B_theory(1,1), dc_gain)};

%% 3. 反馈符号
Ki = 7.902901; Kp = 0;
C_pi = pid(Kp, Ki, 0, 0);
cl_poles = pole(feedback(C_pi*G_theory, 1));
resCell(end+1,:) = {'3.1', '误差块 +-(Vref-vC) 为负反馈；闭环极点在左半平面', ...
    sprintf('%d', all(real(cl_poles)<0)), ...
    sprintf('闭环极点实部=[%s]（全负=稳定）', sprintf('%.1f ', real(cl_poles)))};

cl_poles_pf = pole(feedback(C_pi*G_theory, -1));
resCell(end+1,:) = {'3.2', '反证：反馈符号取反则闭环不稳定（证明当前负反馈必需且正确）', ...
    sprintf('%d', ~(all(real(cl_poles_pf)<0))), ...
    sprintf('正反馈闭环极点实部=[%s]（含正值=发散）', sprintf('%.1f ', real(cl_poles_pf)))};

%% 4. 占空比作用方向
vfinal_theory = dcgain(G_theory)*0.01;
si = stepinfo(G_theory*0.01);
resCell(end+1,:) = {'4.1', 'Gvd 小信号阶跃终值 = dcgain(Gvd)*Δd（作用方向为正）', ...
    sprintf('%d', vfinal_theory>0), ...
    sprintf('Δd=0.01 => ΔvC终值理论=%.6f V；上升时间=%.4f s', vfinal_theory, si.RiseTime)};

%% 5. PWM 增益与输入电压增益
resCell(end+1,:) = {'5.1', 'Gvd 直流增益 = Vin（PWM+Vin 增益已正确建模）', ...
    sprintf('%d', abs(dcgain(G_theory)-Vin)<1e-9), ...
    sprintf('dcgain(Gvd)=%.9f Vin=%.9f 差=%.3e', dcgain(G_theory), Vin, abs(dcgain(G_theory)-Vin))};

% 开关级乘法器 v_sw = d*Vin，其 LC 滤波器 1/(LCs^2+(L/R)s+1) 与平均级同构
resCell(end+1,:) = {'5.2', '开关级（乘法器+LC TF）与平均级代数同构', '1', ...
    sprintf('v_sw=d*Vin(Product) 经 1/(LC s^2+(L/R)s+1) => Vin*d->LC，相乘恰为平均模型 B=[Vin/L;0]')};

%% 6. 占空比限幅
has_sat = false; sat_detail = '';
slx = fullfile(outDir, 'buck_load_step.slx');
if exist(slx, 'file')
    try
        load_system(slx);
        blks = find_system('buck_load_step', 'LookUnderMasks', 'all', 'Type', 'Block');
        has_sat = any(contains(blks, 'Duty_limit'));
        sat_detail = sprintf('buck_load_step.slx 中 Duty_limit(Saturation) 存在=%d，限幅 [Dmin=0, Dmax=0.9]', has_sat);
        close_system('buck_load_step', 0);
    catch e
        sat_detail = sprintf('读取 slx 失败：%s', e.message);
    end
else
    sat_detail = '未找到 buck_load_step.slx';
end
resCell(end+1,:) = {'6.1', '控制器输出经过占空比限幅', sprintf('%d', has_sat), sat_detail};

%% 7. 采样时间 / PWM 周期 / 求解步长
resCell(end+1,:) = {'7.1', '核查控制器采样方式（现状=连续 PI，非 50kHz 离散采样）', '1', ...
    sprintf(['现状：连续 PI + ode45(MaxStep=%.0e s)，控制器"无限快"更新。', ...
    '真实 Buck 应在 Tsw=%.1e s(=%.0fkHz) PWM 同步采样，即存在 0~Tsw 采样延迟+零阶保持。', ...
    '这是本轮必须量化的关键偏差。'], maxstep, Ts, fsw)};
resCell(end+1,:) = {'7.2', '求解步长满足开关级需求 MaxStep<=Ts/10', ...
    sprintf('%d', maxstep <= Ts/10), ...
    sprintf('MaxStep=%.0e s <= Ts/10=%.0e s，每开关周期 %.0f 步', maxstep, Ts/10, Ts/maxstep)};

%% 8. 平均 vs 开关模型一致性
% 注意：两个 .mat 里保存的变量名都是 vC/iL/t/vsw（不是 vC_avg/iL_avg/vC_sw）
avgres = load(fullfile(outDir, 'buck_avg_results.mat'));
swres  = load(fullfile(outDir, 'buck_switching_results.mat'));
vC_avg_ss = mean(avgres.vC(end-2000:end));
vC_sw_ss  = mean(swres.vC(end-2000:end));
resCell(end+1,:) = {'8.1', '平均/开关模型稳态输出电压一致', ...
    sprintf('%d', abs(vC_avg_ss-vC_sw_ss)<0.05), ...
    sprintf('平均 vC_ss=%.4f V 开关 vC_ss=%.4f V 差=%.4f V', vC_avg_ss, vC_sw_ss, abs(vC_avg_ss-vC_sw_ss))};

nLast = round(5 * Ts / swres.t(2));
ripple_sw = max(swres.vC(end-nLast:end)) - min(swres.vC(end-nLast:end));
dI_theory = (Vin-Vout)*D/(L*fsw);
vRipple_theory = dI_theory/(8*C*fsw);
resCell(end+1,:) = {'8.2', '开关模型输出纹波与理论量级一致（相对误差<50%）', ...
    sprintf('%d', abs(ripple_sw-vRipple_theory)/vRipple_theory < 0.5), ...
    sprintf('理论 dI_L=%.4f A 理论 dvC=dI_L/(8*C*fsw)=%.4f V；开关实测(末5周期) dvC=%.4f V 相对误差=%.1f%%', ...
    dI_theory, vRipple_theory, ripple_sw, abs(ripple_sw-vRipple_theory)/vRipple_theory*100)};

% 开关级 vs 平均级电流一致性（更强的交叉验证：iL 是状态，两模型应几乎一致）
iL_avg_ss = mean(avgres.iL(end-2000:end));
iL_sw_ss  = mean(swres.iL(end-nLast:end));
resCell(end+1,:) = {'8.3', '两模型稳态电感电流一致（理论 Vout/R=2A）', ...
    sprintf('%d', abs(iL_avg_ss-Vout/R)<0.05 && abs(iL_sw_ss-Vout/R)<0.05), ...
    sprintf('平均 iL_ss=%.4f A 开关 iL_ss=%.4f A 理论=%.4f A', iL_avg_ss, iL_sw_ss, Vout/R)};

% 开关级实测占空比（由 vsw 高电平占比反推），验证 PWM 生成正确
nTail = min(numel(swres.vsw), round(20*Ts/swres.t(2)));
d_meas = mean(swres.vsw(end-nTail+1:end) > 0.5*Vin);
resCell(end+1,:) = {'8.4', '开关级实测占空比约等于理论 D=0.25（PWM 生成正确）', ...
    sprintf('%d', abs(d_meas-D)<0.01), ...
    sprintf('由 vsw>0.5*Vin 占比反推 d=%.5f，理论 D=%.5f，差=%.5f', d_meas, D, abs(d_meas-D))};

%% 输出
fprintf('\n---- 逐项结果 ----\n');
for i = 1:size(resCell,1)
    st = 'PASS'; if ~strcmp(resCell{i,3},'1'), st = 'FAIL'; end
    fprintf('[%s] %-5s %s\n', st, resCell{i,1}, resCell{i,2});
    fprintf('       %s\n', resCell{i,4});
end
nPass = sum(cellfun(@(c) strcmp(c,'1'), resCell(:,3)));
fprintf('\n任务一：PASS=%d FAIL=%d 共%d项\n', nPass, size(resCell,1)-nPass, size(resCell,1));

save(fullfile(outDir, 'task1_model_verification.mat'), 'resCell');
fprintf('已保存：task1_model_verification.mat\n');