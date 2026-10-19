function res = run_crossdomain(outDir)
%RUN_CROSSDOMAIN  Phase 4 Task 6: the same agent, eight different domains.
%
%   res = run_crossdomain(outDir)
%
% WHY THESE TASKS
% Each one has an answer that exists BEFORE any code is written: an exact
% integral, a closed-form kinematics solution, an analytic Butterworth response,
% a rectangle whose area is known by construction, a first-order step response.
% The task is graded against that reference, never against its own output. A task
% that only checks "the script ran" would pass a wrong answer, which is the exact
% failure mode Phase 3A/3B kept producing.
%
% A task whose toolbox is not licensed is reported as SKIP with the missing
% product; it is never reported as a pass and never silently dropped.
%
% OUTPUT per task:
%   id, domain, status (PASS/FAIL/SKIP), elapsedS, values, reference, errors,
%   errorClass, detail

if nargin < 1 || isempty(outDir), outDir = getenv('MAS_OUT'); end
if isempty(outDir), outDir = fullfile(pwd,'artifacts','validation','phase4'); end
outDir = strrep(outDir,'/',filesep);
here = fileparts(mfilename('fullpath'));
addpath(here); addpath(fullfile(here,'tasks'));
if ~exist(outDir,'dir'), mkdir(outDir); end

T = { ...
  struct('id','D1','domain','scientific computing','fn','cd_d1_linalg',    'need',{{}}); ...
  struct('id','D2','domain','data analysis',       'fn','cd_d2_regression','need',{{}}); ...
  struct('id','D3','domain','signal processing',   'fn','cd_d3_filter',    'need',{{'Signal Processing Toolbox'}}); ...
  struct('id','D4','domain','image processing',    'fn','cd_d4_segment',   'need',{{'Image Processing Toolbox'}}); ...
  struct('id','D5','domain','control',             'fn','cd_d5_statespace','need',{{'Control System Toolbox'}}); ...
  struct('id','D6','domain','Simulink',            'fn','cd_d6_simulink',  'need',{{'Simulink'}}); ...
  struct('id','D7','domain','power electronics',   'fn','cd_d7_boost',     'need',{{}}); ...
  struct('id','D8','domain','robotics',            'fn','cd_d8_kinematics','need',{{}}) };

fprintf('===== Phase 4 Task 6: cross-domain tasks =====\n');
fprintf('%-4s %-22s %-8s %8s  %s\n','id','domain','status','time','detail');
R = struct('id',{},'domain',{},'status',{},'elapsedS',{},'values',{}, ...
    'reference',{},'errorClass',{},'detail',{},'need',{});

for k = 1:numel(T)
    t = T{k};
    missing = '';
    for q = 1:numel(t.need)
        [ok, why] = have_product(t.need{q});
        if ~ok, missing = [missing ' ' t.need{q} '(' why ')']; end %#ok<AGROW>
    end
    if ~isempty(missing)
        fprintf('%-4s %-22s %-8s %8.2f  %s\n', t.id, t.domain, 'SKIP', 0, strtrim(missing));
        R(end+1) = struct('id',t.id,'domain',t.domain,'status','SKIP','elapsedS',0, ...
            'values',struct(),'reference',struct(),'errorClass','MISSING_PRODUCT', ...
            'detail',strtrim(missing),'need',{t.need}); %#ok<AGROW>
        continue;
    end
    t0 = tic;
    try
        out = feval(t.fn);
        el = toc(t0);
        st = out.status; ec = '';
    catch ME
        el = toc(t0);
        out = struct('values',struct(),'reference',struct(),'status','FAIL', ...
            'detail',ME.message);
        st = 'FAIL'; ec = classify(ME);
    end
    if ~isfield(out,'detail'), out.detail = ''; end
    fprintf('%-4s %-22s %-8s %8.2f  %s\n', t.id, t.domain, st, el, out.detail);
    R(end+1) = struct('id',t.id,'domain',t.domain,'status',st,'elapsedS',el, ...
        'values',out.values,'reference',out.reference,'errorClass',ec, ...
        'detail',out.detail,'need',{t.need}); %#ok<AGROW>
end

nP = nnz(strcmp({R.status},'PASS'));
nF = nnz(strcmp({R.status},'FAIL'));
nS = nnz(strcmp({R.status},'SKIP'));
fprintf('\nPASS %d / FAIL %d / SKIP %d  (total %d)\n', nP, nF, nS, numel(R));

res = struct('level','Phase4-Task6','tasks',R,'nPass',nP,'nFail',nF,'nSkip',nS, ...
    'matlabVersion',version,'outDir',outDir);
save(fullfile(outDir,'crossdomain.mat'),'res');
fid = fopen(fullfile(outDir,'crossdomain.json'),'w');
if fid >= 0, fwrite(fid, jsonencode(res),'char'); fclose(fid); end
end

% ---------------------------------------------------------------------------
function [ok, why] = have_product(name)
% Product NAME -> installed (ver) and licensed (license('test')).
% The feature string is NOT the product name; the mapping below was verified on
% this machine in this phase (see references/toolbox-feature-map.md).
map = { ...
  'Statistics Toolbox','Statistics_Toolbox'; ...
  'Signal Processing Toolbox','Signal_Toolbox'; ...
  'Image Processing Toolbox','Image_Toolbox'; ...
  'Control System Toolbox','Control_Toolbox'; ...
  'Robotics System Toolbox','Robotics_System_Toolbox'; ...
  'Deep Learning Toolbox','Neural_Network_Toolbox'; ...
  'Simulink','Simulink'; ...
  'MATLAB Coder','MATLAB_Coder'};
feat = '';
for k = 1:size(map,1)
    if strcmpi(map{k,1}, name), feat = map{k,2}; break; end
end
installed = any(strcmpi({ver().Name}, name));
if isempty(feat)
    ok = false; why = 'no verified feature name'; return;
end
licensed = license('test', feat);
if strcmpi(name,'Simulink')
    ok = installed; why = 'installed check only';
else
    ok = installed && licensed;
    why = sprintf('installed %d, licensed %d', installed, licensed);
end
end

function c = classify(ME)
id = ME.identifier;
if contains(id,'license') || contains(id,'License')
    c = 'LICENSE_ERROR';
elseif contains(id,'Undefined') || contains(id,'unrecognized')
    c = 'MISSING_FUNCTION';
elseif contains(id,'MATLAB:')
    c = 'MATLAB_RUNTIME_ERROR';
else
    c = 'UNKNOWN';
end
end
