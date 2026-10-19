function res = run_crossdomain(outDir, taskIds)
%RUN_CROSSDOMAIN  The same harness, many domains, graded by an independent verifier.
%
%   res = run_crossdomain(outDir)
%   res = run_crossdomain(outDir, {'D3','C1'})
%
% WHAT CHANGED FROM PHASE 4
% Phase 4 let each task compute its own `status`. When D3's reference was wrong, the
% task compared the filter against that wrong reference and reported PASS -- the
% verdict was self-consistent and meaningless. Now:
%
%   task          -> returns NUMBERS only (values struct)
%   mas_verify_task -> grades those numbers against evals/references/*.json
%
% The task's own `status` is still recorded, as `selfVerdict`, purely so a
% disagreement can be reported. A disagreement is a finding, not a nuisance: it
% means either the task's internal check or the frozen reference is wrong, and both
% are worth knowing about.
%
% A missing product is SKIP with the reason from mas_dep_probe, never a pass.

if nargin < 1 || isempty(outDir), outDir = getenv('MAS_OUT'); end
if isempty(outDir), outDir = fullfile(pwd, 'artifacts', 'validation', 'phase4'); end
outDir = strrep(outDir, '/', filesep);
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
addpath(here); addpath(fullfile(here, 'tasks'));
addpath(fullfile(repo, 'skills', 'matlab-runner', 'scripts'));
addpath(fullfile(repo, 'skills', 'matlab-testing-ci', 'scripts'));
% The held-out tasks call the Task 3/4/5 tools, so those script folders have to
% be reachable from here. Without this they fail with MISSING_FUNCTION, which
% reads like a broken task rather than a missing path.
addpath(fullfile(repo, 'skills', 'matlab-signal-vision-ai', 'scripts'));
addpath(fullfile(repo, 'skills', 'matlab-robotics-autonomy', 'scripts'));
addpath(fullfile(repo, 'skills', 'matlab-codegen-deploy', 'scripts'));
if ~exist(outDir, 'dir'), mkdir(outDir); end

T = { ...
  struct('id','D1','domain','scientific computing','fn','cd_d1_linalg',    'need',{{}},'split','dev'); ...
  struct('id','D2','domain','data analysis',       'fn','cd_d2_regression','need',{{}},'split','dev'); ...
  struct('id','D3','domain','signal processing',   'fn','cd_d3_filter',    'need',{{'Signal Processing Toolbox'}},'split','dev'); ...
  struct('id','D4','domain','image processing',    'fn','cd_d4_segment',   'need',{{'Image Processing Toolbox'}},'split','dev'); ...
  struct('id','D5','domain','control',             'fn','cd_d5_statespace','need',{{'Control System Toolbox'}},'split','dev'); ...
  struct('id','D6','domain','Simulink',            'fn','cd_d6_simulink',  'need',{{'Simulink'}},'split','dev'); ...
  struct('id','D7','domain','power electronics',   'fn','cd_d7_boost',     'need',{{}},'split','dev'); ...
  struct('id','D8','domain','robotics',            'fn','cd_d8_kinematics','need',{{}},'split','dev'); ...
  struct('id','C1','domain','control (stable)',    'fn','cd_c1_stable',    'need',{{'Control System Toolbox'}},'split','dev'); ...
  struct('id','C2','domain','control (unstable)',  'fn','cd_c2_unstable',  'need',{{'Control System Toolbox'}},'split','dev'); ...
  struct('id','C3','domain','control (multi-cross)','fn','cd_c3_multicross','need',{{'Control System Toolbox'}},'split','dev'); ...
  struct('id','T1','domain','data cleaning',       'fn','cd_t1_clean',     'need',{{'Statistics and Machine Learning Toolbox'}},'split','dev'); ...
  struct('id','S1','domain','signal (held-out)',   'fn','cd_s1_ofdm',      'need',{{}},'split','heldout'); ...
  struct('id','R1','domain','robotics (held-out)', 'fn','cd_r1_ik',        'need',{{}},'split','heldout'); ...
  struct('id','G1','domain','codegen (held-out)',  'fn','cd_g1_codegen',   'need',{{'MATLAB Coder'}},'split','heldout') };

if nargin >= 2 && ~isempty(taskIds)
    keep = false(1, numel(T));
    for k = 1:numel(T), keep(k) = any(strcmpi(taskIds, T{k}.id)); end
    T = T(keep);
end

fprintf('===== cross-domain tasks (graded by mas_verify_task) =====\n');
fprintf('%-4s %-22s %-13s %8s  %s\n', 'id', 'domain', 'verdict', 'time', 'detail');
R = struct('id', {}, 'domain', {}, 'status', {}, 'selfVerdict', {}, ...
    'elapsedS', {}, 'values', {}, 'reference', {}, 'errorClass', {}, ...
    'detail', {}, 'need', {}, 'perCheck', {}, 'refHash', {}, 'split', {});

for k = 1:numel(T)
    t = T{k};
    missing = '';
    for q = 1:numel(t.need)
        d = mas_dep_probe('product', t.need{q});
        if ~d.pass
            missing = [missing ' ' t.need{q} '(' d.state ': ' d.detail ')']; %#ok<AGROW>
        end
    end
    if ~isempty(missing)
        fprintf('%-4s %-22s %-13s %8.2f  %s\n', t.id, t.domain, 'SKIP', 0, strtrim(missing));
        R(end+1) = row(t, 'SKIP', '', 0, struct(), struct(), 'MISSING_PRODUCT', ...
            strtrim(missing), struct([]), ''); %#ok<AGROW>
        continue;
    end

    t0 = tic;
    try
        out = feval(t.fn);
        el = toc(t0);
        ec = '';
        vals = out.values;
        selfV = out.status;
        ref = out.reference;
    catch ME
        el = toc(t0);
        vals = struct(); selfV = 'ERROR'; ref = struct();
        ec = classify(ME);
        out = struct('detail', ME.message);
    end
    if ~isfield(out, 'detail'), out.detail = ''; end

    v = mas_verify_task(t.id, vals);
    st = v.status;
    det = v.detail;
    if ~strcmp(selfV, st)
        det = sprintf('[self %s vs verifier %s] %s', selfV, st, det);
    end
    fprintf('%-4s %-22s %-13s %8.2f  %s\n', t.id, t.domain, st, el, shorten(det, 84));
    R(end+1) = row(t, st, selfV, el, vals, ref, ec, det, v.perCheck, v.refHash); %#ok<AGROW>
end

nP = nnz(strcmp({R.status}, 'PASS'));
nF = nnz(strcmp({R.status}, 'FAIL'));
nS = nnz(strcmp({R.status}, 'SKIP'));
nU = nnz(strcmp({R.status}, 'UNDETERMINED'));
nDis = nnz(~strcmp({R.selfVerdict}, {R.status}));

% The held-out set is reported separately and on its own line. Folding it into a
% single total would let a strong dev score carry a held-out failure, which is
% exactly the thing a held-out set exists to catch.
isHeld = strcmp({R.split}, 'heldout');
isDev  = ~isHeld;
dP = nnz(strcmp({R.status}, 'PASS') & isDev);
hP = nnz(strcmp({R.status}, 'PASS') & isHeld);
hN = nnz(isHeld);
dN = nnz(isDev);

fprintf('\nPASS %d / FAIL %d / UNDETERMINED %d / SKIP %d  (total %d)', ...
    nP, nF, nU, nS, numel(R));
if nDis > 0
    fprintf('  |  %d task(s) disagreed with their own verdict', nDis);
end
fprintf('\n     dev %d/%d   held-out %d/%d\n', dP, dN, hP, hN);

res = struct('level', 'crossdomain', 'tasks', R, 'nPass', nP, 'nFail', nF, ...
    'nSkip', nS, 'nUndetermined', nU, 'nSelfDisagreement', nDis, ...
    'dev', struct('pass', dP, 'total', dN), ...
    'heldout', struct('pass', hP, 'total', hN), ...
    'matlabVersion', version, 'outDir', outDir);
save(fullfile(outDir, 'crossdomain.mat'), 'res');
fid = fopen(fullfile(outDir, 'crossdomain.json'), 'w');
if fid >= 0, fwrite(fid, jsonencode(res), 'char'); fclose(fid); end
end

% ---------------------------------------------------------------------------
function r = row(t, st, selfV, el, vals, ref, ec, det, perCheck, refHash)
r = struct('id', t.id, 'domain', t.domain, 'status', st, 'selfVerdict', selfV, ...
    'elapsedS', el, 'values', vals, 'reference', ref, 'errorClass', ec, ...
    'detail', det, 'need', {t.need}, 'perCheck', perCheck, 'refHash', refHash, ...
    'split', tern(isfield(t, 'split'), t.split, 'dev'));
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end

function c = classify(ME)
id = ME.identifier;
if contains(id, 'license') || contains(id, 'License')
    c = 'LICENSE_ERROR';
elseif contains(id, 'Undefined') || contains(id, 'unrecognized')
    c = 'MISSING_FUNCTION';
elseif contains(id, 'MATLAB:')
    c = 'MATLAB_RUNTIME_ERROR';
else
    c = 'UNKNOWN';
end
end

function s = shorten(s, n)
if numel(s) > n, s = [s(1:n-3) '...']; end
end
