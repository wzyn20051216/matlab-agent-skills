%% 步骤 1 终版：从电路方程独立推导 Gvd(s)，判定是否含 RHP zero
% 方法：不依赖任何记忆或 tf 对象，直接对物理方程做符号运算。
clear; clc;

Vin = 48; L = 150e-6; C = 220e-6; R = 6; Vout = 12;
syms s real

fprintf('================ 从电路方程独立推导 ================\n');
fprintf('\nCCM Buck 精确电路方程（时域）：\n');
fprintf('  电感回路:  L diL/dt = d*Vin - vC          (iL 从 Vin 流向输出)\n');
fprintf('  节点 KCL:   C dvC/dt = iL - vC/R          (负载电阻 R 泄放)\n');
fprintf('  状态 x = [iL; vC]，输入 u = d，输出 y = vC\n');

A   = [0, -1/L; 1/C, -1/(R*C)];
B   = [Vin/L; 0];
Co  = [0, 1];  Do = 0;

fprintf('\nA = [%g %g; %g %g]\n', A(1,1),A(1,2),A(2,1),A(2,2));
fprintf('B = [%g; %g]\n', B(1), B(2));
fprintf('C = [0 1], D = %g\n', Do);

Gvd_sym = simplify(Co * ((s*eye(2) - A) \ B) + Do);
[numS, denS] = numden(Gvd_sym);
numS = expand(numS); denS = expand(denS);

fprintf('\n推导结果 Gvd(s) = %s\n', char(Gvd_sym));
numN = sym2poly(numS);
denN = sym2poly(denS);
fprintf('  分子 = %s   (次数 %d)\n', char(numS), length(numN)-1);
fprintf('  分母 = %s   (次数 %d)\n', char(denS), length(denN)-1);
fprintf('  dcgain = num(1)/den(3) = %.6f   (理想 Buck 应为 Vin = %.6f)\n', numN(1)/denN(3), Vin);

fprintf('\n================ 关键判定：RHP zero 是否存在 ================\n');
nClassic = [Vin/(L*C), -Vin*R*C/(L*C)];
dClassic = [1, L/R, 1/(L*C)];
fprintf('教科书式 分子 = %s   分母 = %s\n', mat2str(nClassic, 8), mat2str(dClassic, 8));
fprintf('推导式   分子 = %s   分母 = %s\n', mat2str(numN, 8), mat2str(denN, 8));
fprintf('\n分母相同？ %d\n', max(abs(dClassic - denN)) < 1e-6*max(abs(denN)));
fprintf('分子相同？ %d\n', max(abs(nClassic - numN)) < 1e-6*max(abs(nClassic)));

fprintf('\n--- 分母推导 ---\n');
detS = expand(det(s*eye(2)-A));
fprintf('det(sI-A) = %s\n', char(detS));
fprintf('  = s*(s + 1/(RC)) + (1/L)*(1/C) = s^2 + s/(RC) + 1/(LC)\n');
fprintf('  归一化（乘 L*C）: (L*C)s^2 + (L/R)s + 1\n');

wz = 1/(R*C);
valDet = double(subs(detS, s, wz));
fprintf('\n--- 分母在 RHP zero 位置 s=+1/(RC)=%.4f rad/s (%.2f Hz) 的取值 ---\n', wz, wz/(2*pi));
fprintf('det(sI-A)|s=1/RC = %.6e\n', valDet);
if abs(valDet) < 1e-12
    fprintf('  >> 为 0：存在公共因子，RHP zero 可约分\n');
else
    fprintf('  >> 非 0：**无公共因子**，两式是不同的传递函数\n');
end

fprintf('\n================ 物理自洽性检验 ================\n');
fprintf('检验1  dc(Gvd) = %.6f （>0 表示占空比增大则输出电压上升）\n', numN(1)/denN(3));
fprintf('检验2  稳态方程 d*Vin = vC 独立推出 dc(Gvd) 必须 = Vin = %.2f\n', Vin);
fprintf('       推导式实测 = %.6f  => %s\n', numN(1)/denN(3), ...
    merge(abs(numN(1)/denN(3)-Vin)<1e-6, '一致，推导正确', '不一致'));
fprintf('       教科书式   = %.6f  => %s\n', nClassic(1)/dClassic(3), ...
    merge(abs(nClassic(1)/dClassic(3)-Vin)<1e-6, '一致', '不一致'));

fprintf('\n检验3  分子常数项 = %.6e\n', numN(1));
fprintf('       教科书式 s 项 = %.6e（对应零点 s=%+.2f rad/s = %+.2f Hz）\n', ...
    nClassic(2), -nClassic(1)/nClassic(2), -nClassic(1)/nClassic(2)/(2*pi));

fprintf('\n================ LC 极点与阻尼 ================\n');
fn = 1/sqrt(L*C);
zn = (L/R)/(2*sqrt(L*C));
fprintf('LC 双极点频率 f_n = 1/(2*pi*sqrt(LC)) = %.2f Hz (%.1f rad/s)\n', fn/(2*pi), fn);
fprintf('阻尼比 zeta = (L/R)/(2*sqrt(LC)) = %.4f\n', zn);
fprintf('品质因数 Q = 1/(2*zeta) = %.2f\n', 1/(2*zn));
fprintf('>> zeta 极小（%.3f），双极点几乎无阻尼：在 f_n 附近相位从 0 陡降到 -180°\n', zn);
fprintf('>> 这是"加 Kp 就掉相位裕度"的物理根源所在。\n');

function t = merge(c, a, b)
if c, t = a; else, t = b; end
end