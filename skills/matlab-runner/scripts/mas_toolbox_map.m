function t = mas_toolbox_map(outFile)
%MAS_TOOLBOX_MAP  Probe product -> license FEATURE on THIS machine and (optionally)
%write the reference table.
%
%   t = mas_toolbox_map()
%   t = mas_toolbox_map('skills/matlab-runner/references/toolbox-feature-map.md')
%
% The table is generated, not typed: every row is an actual ver/license call, so
% it cannot drift away from the installation the way a hand-written map does.

if nargin < 1, outFile = ''; end
pairs = { ...
  'MATLAB','MATLAB'; 'Simulink','Simulink'; ...
  'Control System Toolbox','Control_Toolbox'; ...
  'Signal Processing Toolbox','Signal_Toolbox'; ...
  'Image Processing Toolbox','Image_Toolbox'; ...
  'Statistics and Machine Learning Toolbox','Statistics_Toolbox'; ...
  'Optimization Toolbox','Optimization_Toolbox'; ...
  'System Identification Toolbox','Identification_Toolbox'; ...
  'Robotics System Toolbox','Robotics_System_Toolbox'; ...
  'Deep Learning Toolbox','Neural_Network_Toolbox'; ...
  'MATLAB Coder','MATLAB_Coder'; ...
  'Simulink Coder','Real-Time_Workshop'; ...
  'Embedded Coder','RTW_Embedded_Coder'; ...
  'Fixed-Point Designer','Fixed_Point_Toolbox'; ...
  'Simscape','Simscape'};

v = ver; names = {v.Name};
n = size(pairs,1);
t = struct('product',{},'feature',{},'installed',{},'licensed',{});
for k = 1:n
    inst = any(strcmpi(names, pairs{k,1}));
    if any(strcmpi(pairs{k,1},{'MATLAB','Simulink','Simscape'}))
        lic = NaN;                       % installation-only, license() is not meaningful
    else
        lic = license('test', pairs{k,2});
    end
    t(end+1) = struct('product',pairs{k,1},'feature',pairs{k,2}, ...
        'installed',inst,'licensed',lic); %#ok<AGROW>
end

fprintf('%-42s %-28s %-9s %s\n','product','feature','installed','licensed');
for k = 1:n
    fprintf('%-42s %-28s %-9d %s\n', t(k).product, t(k).feature, t(k).installed, ...
        tern(isnan(t(k).licensed),'n/a',sprintf('%d',t(k).licensed)));
end

if ~isempty(outFile)
    fid = fopen(outFile,'w');
    if fid < 0, error('mas_toolbox_map:io','cannot write %s', outFile); end
    fprintf(fid,'# Toolbox -> license feature map (generated)\n\n');
    fprintf(fid,'Generated on %s by `mas_toolbox_map.m`; every row is a real\n', datestr(now,31));
    fprintf(fid,'`ver` / `license(''test'',feature)` call on this machine.\n\n');
    fprintf(fid,'| product | feature | installed | licensed |\n|---|---|---|---|\n');
    for k = 1:n
        fprintf(fid,'| %s | `%s` | %d | %s |\n', t(k).product, t(k).feature, ...
            t(k).installed, tern(isnan(t(k).licensed),'n/a',sprintf('%d',t(k).licensed)));
    end
    fprintf(fid,'\n`n/a` = installation-only product; `license(''test'')` is not the right call.\n');
    fclose(fid);
    fprintf('\nwrote %s\n', outFile);
end
end

function s = tern(c,a,b)
if c, s = a; else, s = b; end
end
