%% 探针：BASE vs OPT 的灵敏度函数 |S(f)| = 1/|1+L| 逐点对比
%
% 目的：核实"21.4x 交越频率"到底带来多少扰动抑制改善。
% 假设（待验证）：陷波器在 f_n 挖掉 28dB 增益，使 876~1295Hz 频段
% |S| 仅与基线相当 —— 交越频率不等于扰动抑制能力。
clear; close all;
outDir = getenv('BUCK_OUT');
if isempty(outDir), outDir = fullfile(fileparts(fileparts(mfilename('fullpath'))), '..', '..', 'artifacts', 'validation', 'buck'); end
outDir = strrep(outDir,'/',filesep);
d3 = load(fullfile(outDir,'task3_best_controller.mat'));
Gvd = d3.Gvd; fn = d3.fn;
Lbase = pid(0,7.902901,0,0)*Gvd;
Lopt  = d3.C_best*Gvd;

fList = [10 20 50 100 200 300 600 876.12 1000 1295 1500 2000 3000];
fprintf('%8s %12s %12s %10s %10s\n','f(Hz)','|S|_BASE','|S|_OPT','改善倍数','|L|_OPT(dB)');
for f = fList
    w = 2*pi*f;
    SB = abs(1/(1+freqresp(Lbase,w)));
    SO = abs(1/(1+freqresp(Lopt,w)));
    LO = 20*log10(abs(squeeze(freqresp(Lopt,w))));
    fprintf('%8.1f %12.4f %12.4f %10.2f %10.2f\n', f, SB, SO, SB/SO, LO);
end

% 全频段峰值 |S|（最坏扰动放大）
w = logspace(0, 5, 200001);
SBv = abs(1./(1+reshape(freqresp(Lbase,w),[],1)));
SOv = abs(1./(1+reshape(freqresp(Lopt,w),[],1)));
fprintf('\n10Hz~100kHz 内 |S| 峰值: BASE=%.4f @ %.1f Hz   OPT=%.4f @ %.1f Hz\n', ...
    max(SBv), w(find(SBv==max(SBv),1))/2/pi, max(SOv), w(find(SOv==max(SOv),1))/2/pi);
% 50~1000Hz 平均改善
m = w>=2*pi*50 & w<=2*pi*1000;
fprintf('50~1000Hz 平均 |S|: BASE=%.4f  OPT=%.4f  平均改善=%.2f 倍\n', ...
    mean(SBv(m)), mean(SOv(m)), mean(SBv(m))/mean(SOv(m)));
