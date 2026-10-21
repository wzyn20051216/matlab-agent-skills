function info = featureName(productName)
%FEATURENAME 把 MathWorks 产品名映射成 license feature 名。
%
%   info = masacc.featureName("MATLAB Coder")
%   info.feature  -> "MATLAB_Coder"
%   info.source   -> "table" | "normalized-guess" | "unknown"
%
%   为什么需要这张表：
%   license('test', x) 的第二个参数是 **license feature 名**，不是产品显示名。
%   两者经常不同，用产品名去测会得到 0，看起来像"没有许可证"，其实只是查错了键：
%       MATLAB Coder     -> MATLAB_Coder
%       Simulink Coder   -> Real-Time_Workshop
%       Embedded Coder   -> RTW_Embedded_Coder
%       Fixed-Point Designer -> Fixed_Point_Toolbox
%       Deep Learning Toolbox -> Neural_Network_Toolbox
%   实测环境：MATLAB R2026a，117 个已安装产品。
%   表中 feature 名均在本机以 license('test', ...) 返回 1 或 0 实测过（见 docs/P1_ACCEPTANCE_ZH.md 3.7 节）。
%
%   关于 normalized-guess：
%   把产品名里的空格换成下划线，大多数产品能命中（AUTOSAR Blockset -> AUTOSAR_Blockset）。
%   但"命中"只能用来**确认**，不能用来**否定**：
%       Simulink Coder 归一化后是 Simulink_Coder，值为 0，而真实 feature 值是 1。
%   所以归一化猜测返回 0 时不允许据此判定"未授权"，只能记"未知"。
%   这条规则由 masacc.licenseState 强制执行。

arguments
    productName (1,1) string
end

persistent cachedNames cachedFeatures
if isempty(cachedNames)
    [cachedNames, cachedFeatures] = localTable();
end

info = struct("feature", "", "source", "unknown", "note", "");

matchIndex = find(cachedNames == productName, 1);
if ~isempty(matchIndex)
    info.feature = cachedFeatures(matchIndex);
    info.source = "table";
    return
end

% 表里没有：给一个归一化猜测，只用于"确认已授权"，不用于否定。
normalized = replace(strtrim(productName), " ", "_");
if strlength(normalized) == 0 || normalized == productName && ~contains(productName, " ")
    info.note = "产品名未收录，且无法归一化成 feature 名";
    return
end
info.feature = normalized;
info.source = "normalized-guess";
info.note = "未收录的归一化猜测，只用于确认已授权；返回 0 时按未知处理";
end

function [names, features] = localTable()
%LOCALTABLE 已实测的 产品名 -> license feature 名 映射。
%
% 收录原则：
%   1. 只收录在本机实测过的映射（返回 1，确认授权；或返回 0 但 feature 名本身可确认）；
%   2. 没有确认过 feature 名的产品一律不收录，让它走 normalized-guess，最终如实报"未知"；
%   3. 产品改名后旧 feature 仍可用的，按当前版本实测结果收录（如 Simscape Electrical 仍是
%      Power_System_Blocks，Simscape Multibody 仍是 SimMechanics）。

names = [
    "MATLAB"
    "Simulink"
    "Stateflow"
    "MATLAB Coder"
    "Simulink Coder"
    "Embedded Coder"
    "Simulink Control Design"
    "Simulink Test"
    "Simulink Coverage"
    "Simulink Design Verifier"
    "Simulink Code Inspector"
    "Simulink Compiler"
    "Simulink PLC Coder"
    "Simulink FMU Builder"
    "Simulink Fault Analyzer"
    "Simulink Real-Time"
    "Simulink 3D Animation"
    "Requirements Toolbox"
    "MATLAB Test"
    "Fixed-Point Designer"
    "Deep Learning Toolbox"
    "Signal Processing Toolbox"
    "DSP System Toolbox"
    "Image Processing Toolbox"
    "Optimization Toolbox"
    "Global Optimization Toolbox"
    "Statistics and Machine Learning Toolbox"
    "Symbolic Math Toolbox"
    "Control System Toolbox"
    "Robust Control Toolbox"
    "System Identification Toolbox"
    "Model Predictive Control Toolbox"
    "Partial Differential Equation Toolbox"
    "Curve Fitting Toolbox"
    "Fuzzy Logic Toolbox"
    "Wavelet Toolbox"
    "Bioinformatics Toolbox"
    "Text Analytics Toolbox"
    "Audio Toolbox"
    "GPU Coder"
    "HDL Coder"
    "HDL Verifier"
    "Parallel Computing Toolbox"
    "MATLAB Compiler"
    "MATLAB Compiler SDK"
    "MATLAB Report Generator"
    "Simulink Report Generator"
    "Simscape"
    "Simscape Electrical"
    "Simscape Multibody"
    "Simscape Driveline"
    "Simscape Fluids"
    "SimEvents"
    "SimBiology"
    "Communications Toolbox"
    "5G Toolbox"
    "LTE Toolbox"
    "WLAN Toolbox"
    "Antenna Toolbox"
    "RF Toolbox"
    "RF Blockset"
    "RF PCB Toolbox"
    "Phased Array System Toolbox"
    "Radar Toolbox"
    "Computer Vision Toolbox"
    "Automated Driving Toolbox"
    "Navigation Toolbox"
    "Robotics System Toolbox"
    "ROS Toolbox"
    "UAV Toolbox"
    "Lidar Toolbox"
    "Medical Imaging Toolbox"
    "Image Acquisition Toolbox"
    "Bluetooth Toolbox"
    "DDS Blockset"
    "AUTOSAR Blockset"
    "Aerospace Blockset"
    "Aerospace Toolbox"
    "Motor Control Blockset"
    "Powertrain Blockset"
    "Vehicle Dynamics Blockset"
    "Vehicle Network Toolbox"
    "SoC Blockset"
    "Vision HDL Toolbox"
    "Wireless HDL Toolbox"
    "Wireless Testbench"
    "Wireless Network Toolbox"
    "System Composer"
    "Database Toolbox"
    "Datafeed Toolbox"
    "Econometrics Toolbox"
    "Financial Toolbox"
    "Risk Management Toolbox"
    "Signal Integrity Toolbox"
    "SerDes Toolbox"
    "Mixed-Signal Blockset"
    "Deep Learning HDL Toolbox"
    "DSP HDL Toolbox"
    "Raspberry Pi Blockset"
    "Sensor Fusion and Tracking Toolbox"
    ];

features = [
    "MATLAB"
    "Simulink"
    "Stateflow"
    "MATLAB_Coder"
    "Real-Time_Workshop"
    "RTW_Embedded_Coder"
    "Simulink_Control_Design"
    "Simulink_Test"
    "Simulink_Coverage"
    "Simulink_Design_Verifier"
    "Simulink_Code_Inspector"
    "Simulink_Compiler"
    "Simulink_PLC_Coder"
    "Simulink_FMU_Builder"
    "Simulink_Fault_Analyzer"
    "xPC_Target"
    "Virtual_Reality_Toolbox"
    "Simulink_Requirements"
    "MATLAB_Test"
    "Fixed_Point_Toolbox"
    "Neural_Network_Toolbox"
    "Signal_Toolbox"
    "Signal_Blocks"
    "Image_Toolbox"
    "Optimization_Toolbox"
    "GADS_Toolbox"
    "Statistics_Toolbox"
    "Symbolic_Toolbox"
    "Control_Toolbox"
    "Robust_Toolbox"
    "Identification_Toolbox"
    "MPC_Toolbox"
    "PDE_Toolbox"
    "Curve_Fitting_Toolbox"
    "Fuzzy_Toolbox"
    "Wavelet_Toolbox"
    "Bioinformatics_Toolbox"
    "Text_Analytics_Toolbox"
    "Audio_System_Toolbox"
    "GPU_Coder"
    "HDL_Coder"
    "EDA_Simulator_Link"
    "Distrib_Computing_Toolbox"
    "Compiler"
    "MATLAB_Builder_EX"
    "MATLAB_Report_Gen"
    "Simulink_Report_Gen"
    "Simscape"
    "Power_System_Blocks"
    "SimMechanics"
    "SimDriveline"
    "SimHydraulics"
    "SimEvents"
    "SimBiology"
    "Communications_Toolbox"
    "5G_Toolbox"
    "LTE_Toolbox"
    "WLAN_System_Toolbox"
    "Antenna_Toolbox"
    "RF_Toolbox"
    "RF_Blockset"
    "RF_PCB_Toolbox"
    "Phased_Array_System_Toolbox"
    "Radar_Toolbox"
    "Video_and_Image_Blockset"
    "Automated_Driving_Toolbox"
    "Navigation_Toolbox"
    "Robotics_System_Toolbox"
    "ROS_Toolbox"
    "UAV_Toolbox"
    "Lidar_Toolbox"
    "Medical_Imaging_Toolbox"
    "Image_Acquisition_Toolbox"
    "Bluetooth_Toolbox"
    "DDS_Blockset"
    "AUTOSAR_Blockset"
    "Aerospace_Blockset"
    "Aerospace_Toolbox"
    "Motor_Control_Blockset"
    "Powertrain_Blockset"
    "Vehicle_Dynamics_Blockset"
    "Vehicle_Network_Toolbox"
    "SoC_Blockset"
    "Vision_HDL_Toolbox"
    "Wireless_HDL_Toolbox"
    "Wireless_Testbench"
    "Wireless_Network_Toolbox"
    "System_Composer"
    "Database_Toolbox"
    "Datafeed_Toolbox"
    "Econometrics_Toolbox"
    "Financial_Toolbox"
    "Risk_Management_Toolbox"
    "Signal_Integrity_Toolbox"
    "SerDes_Toolbox"
    "Mixed_Signal_Blockset"
    "Deep_Learning_HDL_Toolbox"
    "DSP_HDL_Toolbox"
    "Raspberry_Pi_Blockset"
    "Sensor_Fusion_and_Tracking_Toolbox"
    ];

if numel(names) ~= numel(features)
    error("masacc:featureTable", "产品名与 feature 名数量不一致：%d vs %d", numel(names), numel(features));
end
end
