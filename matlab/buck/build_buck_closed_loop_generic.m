function res = build_buck_closed_loop_generic(outDir, cfg)
if nargin < 1 || isempty(outDir), outDir = getenv('BUCK_OUT'); end
if nargin < 2, cfg = struct(); end
outDir = strrep(outDir,'/',filesep);
if ~exist(outDir,'dir'); mkdir(outDir); end

% ---- 默认配置 ----
d = struct('Vin',48,'L',150e-6,'C',220e-6,'R',6,'Vref',12, ...
    'Kp',0,'Ki',7.902901,'Kd',0, ...
    'notchEnable',false,'notchWn',5504.8,'notchZn',0.02,'notchZd',0.8, ...
    'Dmin',0,'Dmax',0.9,'Tt',1e-3, ...
    'loadStepTime',[],'loadStepRatio',2, ...
    'vinStepTime',[],'vinStepTo',[], ...
    'tStep',0.03,'tStop',0.06,'maxStep',1e-6,'AntiGainOverride',[], ...
    'modelName','buck_cl_generic','saveModel',true);
f = fieldnames(cfg); for i=1:numel(f), d.(f{i}) = cfg.(f{i}); end

Vin=d.Vin; L=d.L; C=d.C; R=d.R; Vref=d.Vref; Kp=d.Kp; Ki=d.Ki;
Dmin=d.Dmin; Dmax=d.Dmax; Tt=d.Tt;

mdl = d.modelName;
% 模型名只允许字母/数字/下划线：sprintf 的 %.3g 会产生小数点，Simulink 不接受
mdl = regexprep(mdl, '[^A-Za-z0-9_]', '_');
if bdIsLoaded(mdl); close_system(mdl,0); end
new_system(mdl); open_system(mdl);

% ---- 被控对象：x=[iL;vC]，输入=[d; i_load]，负载用电导外部反馈 ----
A = [0, -1/L; 1/C, 0];
B = [Vin/L, 0; 0, -1/C];
Co = [0 1; 1 0];
Do = [0 0; 0 0];

% ---- 参考 ----
add_block('simulink/Sources/Constant',[mdl '/Vref'],'Value',num2str(Vref));
% ---- 误差 e = Vref - vC ----
add_block('simulink/Math Operations/Sum',[mdl '/Error'],'Inputs','+-');

% ---- PI 主体：u_unsat = Kp*e + Int ----
add_block('simulink/Math Operations/Gain',[mdl '/Kp'],'Gain',num2str(Kp));
add_block('simulink/Math Operations/Gain',[mdl '/Ki'],'Gain',num2str(Ki));
add_block('simulink/Math Operations/Sum',[mdl '/PI_sum'],'Inputs','++');
add_block('simulink/Continuous/Integrator',[mdl '/Integrator'],'InitialCondition','0');
% 积分器输入 = Ki*e + 抗饱和项
add_block('simulink/Math Operations/Sum',[mdl '/Int_in'],'Inputs','++');

% ---- 陷波器（可选）：作用在 PI 输出上 ----
% ---- 陷波器（可选）----
% 目标 N(s) = (s^2 + 2*zn*wn*s + wn^2) / (s^2 + 2*zd*wn*s + wn^2)
%
% 实现要点（这是一个曾导致仿真发散的真实坑）：
%   分子与分母同阶(2)，而 Simulink 的 Transfer Fcn 块要求 num 次数 < den 次数，
%   即必须是**严格真有理**传函。若把分子拆成 [1, 2zn*wn] 和 [wn^2] 两项并联相加，
%   会丢掉 s^2 项，得到错误的传函（频域 tf 对象正确、时域仿真却发散）。
%
% 正确的严格真有理分解：
%   num - den = (2*zn - 2*zd)*wn*s
%   => N(s) = 1 + [2*(zn - zd)*wn*s] / den(s)
% 该形式满足：DC 增益 = 1，高频增益 = 1，f_n 处增益 = zn/zd，全部正确。
if d.notchEnable
    wn = d.notchWn; zn = d.notchZn; zd = d.notchZd;
    % 直接用完整二阶分子/分母。Simulink Transfer Fcn 允许分子次数 == 分母次数
    % （内部自动提取直通项），并能正确处理 —— 但必须显式验证等价性，
    % 见 verify/selfcheck_notch_equivalence.m
    add_block('simulink/Continuous/Transfer Fcn',[mdl '/Notch_TF'], ...
        'Numerator', mat2str([1, 2*zn*wn, wn^2]), ...
        'Denominator', mat2str([1, 2*zd*wn, wn^2]));
end

% ---- 占空比限幅 ----
add_block('simulink/Discontinuities/Saturation',[mdl '/Duty_limit'], ...
    'LowerLimit',num2str(Dmin),'UpperLimit',num2str(Dmax));

% ---- 抗饱和 back-calculation：Int_in = Ki*e + (1/Tt)*(u_sat - u_unsat) ----
% 注意 u_unsat 必须取**限幅前**的控制器输出（陷波器之后）
add_block('simulink/Math Operations/Sum',[mdl '/Sat_diff'],'Inputs','+-');
if isempty(d.AntiGainOverride)
    agVal = 1/Tt;
else
    agVal = d.AntiGainOverride;
end
add_block('simulink/Math Operations/Gain',[mdl '/AntiGain'],'Gain',num2str(agVal));

% ---- 负载电导 G(t) ----
% loadStepRatio 语义：**电导倍增倍数**，即新负载电阻 = R/loadStepRatio
% （重载阶跃，如 ratio=2, R=6Ω -> 3Ω）。
% 历史 bug：曾写成 After=1/(R*ratio)（电阻乘以 ratio，6Ω->18Ω 减载），
% 方向与文档意图相反，且把纯积分回路推入 R=18Ω 的不稳区（GM<0），
% 表现为阶跃后振荡增长——一度被误读为"恢复慢"。现已修正为重载方向。
if isempty(d.loadStepTime)
    add_block('simulink/Sources/Constant',[mdl '/Conductance'],'Value',num2str(1/R));
else
    add_block('simulink/Sources/Step',[mdl '/Conductance'], ...
        'Time',num2str(d.loadStepTime),'Before',num2str(1/R), ...
        'After',num2str(d.loadStepRatio/R));
end
add_block('simulink/Math Operations/Product',[mdl '/Load'],'Inputs','2');

% ---- 被控对象 ----
add_block('simulink/Continuous/State-Space',[mdl '/Plant'], ...
    'A',mat2str(A),'B',mat2str(B),'C',mat2str(Co),'D',mat2str(Do),'X0','[0;0]');

add_block('simulink/Signal Routing/Mux',  [mdl '/Mux'],'Inputs','2');
add_block('simulink/Signal Routing/Demux',[mdl '/Demux'],'Outputs','2');

add_block('simulink/Sinks/To Workspace',[mdl '/vC_sink'],'VariableName','vC','SaveFormat','Timeseries');
add_block('simulink/Sinks/To Workspace',[mdl '/iL_sink'],'VariableName','iL','SaveFormat','Timeseries');
add_block('simulink/Sinks/To Workspace',[mdl '/duty_sink'],'VariableName','duty','SaveFormat','Timeseries');
add_block('simulink/Sinks/To Workspace',[mdl '/err_sink'],'VariableName','err','SaveFormat','Timeseries');

% ---- 连线 ----
add_line(mdl,'Vref/1','Error/1');
add_line(mdl,'Demux/1','Error/2');        % vC 反馈
add_line(mdl,'Error/1','Kp/1');
add_line(mdl,'Kp/1','PI_sum/1');
add_line(mdl,'Integrator/1','PI_sum/2');   % 积分器输出加到 u_unsat（正确方向）
add_line(mdl,'Error/1','Ki/1');
add_line(mdl,'Ki/1','Int_in/1');
add_line(mdl,'AntiGain/1','Int_in/2');
add_line(mdl,'Int_in/1','Integrator/1');

% 陷波器连线（若启用）：PI_sum -> Notch -> Duty_limit
if d.notchEnable
    add_line(mdl,'PI_sum/1','Notch_TF/1');
    add_line(mdl,'Notch_TF/1','Duty_limit/1');
    add_line(mdl,'Notch_TF/1','Sat_diff/2');    % - u_unsat
else
    add_line(mdl,'PI_sum/1','Duty_limit/1');
    add_line(mdl,'PI_sum/1','Sat_diff/2');      % - u_unsat
end

% 抗饱和：u_sat - u_unsat
add_line(mdl,'Duty_limit/1','Sat_diff/1');       % + u_sat
add_line(mdl,'Sat_diff/1','AntiGain/1');

% 被控对象连接
add_line(mdl,'Duty_limit/1','Mux/1');
add_line(mdl,'Demux/1','Load/1');
add_line(mdl,'Conductance/1','Load/2');
add_line(mdl,'Load/1','Mux/2');
add_line(mdl,'Mux/1','Plant/1');
add_line(mdl,'Plant/1','Demux/1');

% 输出
add_line(mdl,'Demux/1','vC_sink/1');
add_line(mdl,'Demux/2','iL_sink/1');
add_line(mdl,'Duty_limit/1','duty_sink/1');
add_line(mdl,'Error/1','err_sink/1');

set_param(mdl,'StopTime',num2str(d.tStop),'Solver','ode45','MaxStep',num2str(d.maxStep));
if d.saveModel
    save_system(mdl, fullfile(outDir, [mdl '.slx']));
end

simout = sim(mdl);
res = struct();
res.t  = simout.vC.Time;
res.vC = simout.vC.Data;
res.iL = simout.iL.Data;
res.duty = simout.duty.Data;
res.err = simout.err.Data;
res.cfg = d;
res.modelPath = fullfile(outDir, [mdl '.slx']);
close_system(mdl,0);
end