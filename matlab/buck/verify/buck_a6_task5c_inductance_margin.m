function res = buck_a6_task5c_inductance_margin(outDir)
%BUCK_A6_TASK5C_INDUCTANCE_MARGIN  Where is the inductance stability boundary?
%
% Phase 3A.6 Task 5 swept L by only +-20 % and found L -20 % failing. Task 4b
% then showed that even L -10 % (135 uH) does not settle, which turns the
% inductance tolerance into the binding constraint of the whole design. This
% script brackets the boundary instead of reporting a single failing point.
%
% WHY IT SHOULD BE TIGHT
% The inner current loop is a proportional gain Kci implemented digitally with a
% one-period sampling delay. Its discrete pole is
%     z_inner = 1 - Kci*Ts/L
% so z_inner >= 0 requires L >= Kci*Ts = 6 * 20 us = 120 uH. At the nominal
% 150 uH, z_inner = 0.20 -- that is only 25 % of the way from the unit circle
% to the origin, and it is a NECESSARY condition, not a sufficient one. The
% measured boundary below tells us how much of that 25 % is actually usable,
% which is the number a hardware tolerance must be compared against.

if nargin < 1 || isempty(outDir), outDir = getenv('BUCK_OUT'); end
outDir = strrep(outDir,'/',filesep);
here = fileparts(mfilename('fullpath')); addpath(fileparts(here));
if ~exist(outDir,'dir'), mkdir(outDir); end
Vref = 12;
STD = struct('sserr_max',0.1,'s5_max',1.0,'os_max',5,'dip_max',12, ...
             'dlo',0.05,'dhi',0.85,'imax',12);
oRun = struct('ratio',2,'tStep',0.06,'tEnd',0.08,'nSub',200,'Tss',5e-3);

Lset = [120 130 135 140 145 150 160 180 220 330]*1e-6;
fprintf('=== 3A.6 Task 5c: inductance stability boundary ===\n');
fprintf('Kci=%.1f ohm, Ts=20 us -> necessary condition L >= %.0f uH (z_inner >= 0)\n', ...
    6, 6*20e-6*1e6);
fprintf('%6s %8s %8s %8s %6s | %9s %9s %8s %8s | %s\n', ...
    'L uH','z_inner','maxAbs','margin','conv','ssErr%','S5 ms','dip%','iLpk','verdict');
R = struct('L',{},'zInner',{},'maxAbs',{},'margin',{},'converged',{}, ...
    'ssErr',{},'s5',{},'dip',{},'iLpk',{},'verdict',{});
for q = 1:numel(Lset)
    L = Lset(q);
    p = dual_params(48,6,L,'nDly',1);
    rf = sw_floquet(p, struct('verbose',false,'maxIter',1500));
    m = cfg_metrics(p,oRun,Vref);
    z = 1 - p.Kci*(1/p.fs)/L;
    [ok, v] = s1_verdict(rf.converged, rf.maxAbs);
    if ok && abs(m.ssErr)<=STD.sserr_max && isfinite(m.settleMs) && m.settleMs<=STD.s5_max
        vd = 'STABLE+METRICS-PASS';
    elseif ok
        vd = 'STABLE+METRICS-FAIL';
    else
        vd = 'NO-PERIOD-1-ORBIT';
    end
    fprintf('%6.0f %8.3f %8.4f %8.4f %6d | %9.4f %9.4f %8.3f %8.3f | %s\n', ...
        L*1e6, z, rf.maxAbs, rf.margin, rf.converged, m.ssErr, m.settleMs, ...
        m.dipPct, m.iLpkAll, vd);
    R(end+1) = struct('L',L,'zInner',z,'maxAbs',rf.maxAbs,'margin',rf.margin, ...
        'converged',rf.converged,'ssErr',m.ssErr,'s5',m.settleMs,'dip',m.dipPct, ...
        'iLpk',m.iLpkAll,'verdict',vd); %#ok<AGROW>
end

% bracket the boundary: the SMALLEST stable inductance, and the largest failing
% point below it (the first version took max/min over the whole set, which
% reported "stable down to 330 uH" -- the maximum instead of the minimum)
st = [R.converged] & [R.maxAbs] < 1 & isfinite([R.s5]);
Ls = min([R(st).L]);
bad = [R(~st).L];
Lu = max(bad(bad < Ls));
fprintf('\nstable down to L = %.0f uH (%+.1f %% of nominal); first failing point %.0f uH\n', ...
    Ls*1e6, (Ls/150e-6-1)*100, Lu*1e6);
fprintf('=> an inductance tolerance of -10 %% (135 uH) is NOT acceptable; the design\n');
fprintf('   needs L >= %.0f uH, i.e. a tolerance of about %+.1f %% from nominal.\n', ...
    Ls*1e6, (Ls/150e-6-1)*100);

res = struct('level','3A.6-Task5c','records',R,'LstableMin',Ls,'LfirstFail',Lu, ...
    'necessaryCondition_uH', 6*20e-6*1e6, ...
    'note',['z_inner >= 0 (L >= 120 uH) is necessary, not sufficient. The measured ' ...
            'boundary is what a hardware inductance tolerance has to clear.']);
save(fullfile(outDir,'a6_task5c_inductance_margin.mat'),'res');
fid = fopen(fullfile(outDir,'a6_task5c_inductance_margin.json'),'w');
if fid >= 0, fwrite(fid, jsonencode(res), 'char'); fclose(fid); end
fprintf('saved a6_task5c_inductance_margin.json/.mat\n');
end
