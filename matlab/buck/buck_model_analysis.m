% Buck DC-DC 变换器：数学建模与开环特性分析
% 初始设计值（可参数化，非最终最佳参数）
function buck_model_analysis()
close all;

% ==== 设计参数 ====
Vin = 48;        % 输入电压 V
Vout_target = 12;% 目标输出电压 V
fsw = 50e3;      % 开关频率 Hz
R_nom = 6;       % 标称负载 Ω
L = 150e-6;      % 电感 H
C = 220e-6;      % 电容 F

% ==== 理想 Buck 电压关系 ====
D = Vout_target / Vin;   % 理想占空比 = 12/48 = 0.25
fprintf('=== 理想 Buck 稳态关系 ===\n');
fprintf('D = Vout/Vin = %.4f\n', D);
fprintf('Vout(理想) = D * Vin = %.4f V\n', D*Vin);

% ==== CCM 状态空间模型 ====
% 状态 x = [iL; vC]，输入 u = Vin（占空比 d 进入 B 矩阵）
% A 与 d 无关（Buck 特性）
A = [0, -1/L; 1/C, -1/(R_nom*C)];
B_d = [D/L; 0];           % B * d * Vin，这里 B_d = [d/L; 0] * Vin 的系数
% 状态方程：dx/dt = A x + [D/L; 0] * Vin  （标称占空比下的平均模型）

% 平衡点：0 = A x_eq + B_d * Vin
x_eq = -A \ (B_d * Vin);
iL_eq = x_eq(1);
vC_eq = x_eq(2);
fprintf('\n=== 平衡点（标称工况）===\n');
fprintf('iL_eq = %.4f A\n', iL_eq);
fprintf('vC_eq = %.4f V\n', vC_eq);
fprintf('理论 iL_eq = Vout/R = %.4f A\n', Vout_target/R_nom);
fprintf('理论 vC_eq = %.4f V\n', Vout_target);

% ==== CCM 条件检查 ====
% 电感电流纹波：ΔiL = (Vin - Vout) * D / (L * fsw)
diL = (Vin - Vout_target) * D / (L * fsw);
iL_min = iL_eq - diL/2;
fprintf('\n=== CCM 条件 ===\n');
fprintf('电感电流纹波 ΔiL = %.4f A\n', diL);
fprintf('iL_min = %.4f A（>0 则 CCM）\n', iL_min);
fprintf('CCM 判定：%s\n', string(iL_min > 0));

% ==== 开环传递函数：占空比 -> 输出电压 ====
% 从状态空间推出 G_vd(s) = vC(s)/d(s)
% 用 ss2tf 需要 Control System Toolbox
try
    % 控制输入是 d，B 矩阵对 d 的偏导 = [Vin/L; 0]
    B_ctrl = [Vin/L; 0];
    C_out = [0, 1];
    D_out = 0;
    sys = ss(A, B_ctrl, C_out, D_out);
    Gvd = tf(sys);
    fprintf('\n=== 开环传递函数 Gvd(s) = vC(s)/d(s) ===\n');
    Gvd
    
    % 特征值（极点）
    eigA = eig(A);
    fprintf('极点：%.2f ± j%.2f\n', real(eigA(1)), abs(imag(eigA(1))));
    % 理论自然频率与阻尼
    wn = 1/sqrt(L*C);
    zeta = (1/(2*R_nom)) * sqrt(L/C);
    fprintf('理论 ωn = 1/sqrt(LC) = %.2f rad/s\n', wn);
    fprintf('理论 ζ = (1/(2R))*sqrt(L/C) = %.4f\n', zeta);
    fprintf('理论极点实部 = -1/(2RC) = %.2f\n', -1/(2*R_nom*C));

    % 阶跃响应
    info = stepinfo(Gvd);
    fprintf('\n=== 开环阶跃特性（占空比阶跃 1%）===\n');
    fprintf('稳态增益 = %.4f（理论 = Vin = %d）\n', dcgain(Gvd), Vin);
    fprintf('峰值 = %.4f\n', info.Peak);
    fprintf('超调 = %.2f%%\n', info.Overshoot);
    fprintf('调节时间 = %.4f s\n', info.SettlingTime);
catch ME
    fprintf('Control System Toolbox 不可用：%s\n', ME.message);
    fprintf('退化为手算：ωn=%.2f, ζ=%.4f\n', wn, zeta);
end

% ==== 输出电压纹波（CCM 近似）====
% ΔvC = ΔiL / (8 * C * fsw)  （忽略 ESR）
dvC = diL / (8 * C * fsw);
fprintf('\n=== 输出电压纹波（CCM 近似）===\n');
fprintf('ΔvC ≈ ΔiL/(8*C*fsw) = %.4f V\n', dvC);
fprintf('纹波率 = %.4f%%\n', dvC/Vout_target*100);

% ==== 功率平衡 ====
P_out = Vout_target^2 / R_nom;
P_in = Vin * (iL_eq * D);   % 平均输入电流 = iL_eq * D
fprintf('\n=== 功率平衡 ===\n');
fprintf('P_out = %.2f W\n', P_out);
fprintf('P_in = Vin * iL_eq * D = %.2f W\n', P_in);
fprintf('损耗(理想)=0，P_in==P_out：%s\n', string(abs(P_in-P_out) < 0.01));

fprintf('\n=== 结论 ===\n');
fprintf('D=%.4f, iL_eq=%.4f A, vC_eq=%.4f V, 纹波ΔiL=%.4f A, ΔvC=%.4f V\n', ...
    D, iL_eq, vC_eq, diL, dvC);
fprintf('开环系统：ωn=%.2f rad/s, ζ=%.4f（欠阻尼）\n', wn, zeta);
end
