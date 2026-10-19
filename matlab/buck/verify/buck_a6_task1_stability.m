function res = buck_a6_task1_stability(outDir)
%BUCK_A6_TASK1_STABILITY  Independent stability evidence for the switching level.
%
% Phase 3A.5 graded the switching-level cases (D) with S1 = "the 60 ms run
% converged and the steady-state error is small". That is a finite-time
% observation, not a stability statement. This script replaces it with the
% Floquet (monodromy) multipliers of the closed-loop period map, plus separate
% switching-level robustness margins, and it reports the average-model PM/GM as
% DESIGN VALUES ONLY.
%
% WHAT IS INDEPENDENTLY VERIFIED AT THE SWITCHING LEVEL (this file)
%   S1  local asymptotic stability of the periodic orbit: max|eig(DP)| < 1
%   margin 1-max|eig(DP)|            distance to the unit circle
%   delay margin                    largest integer computation delay still stable
%   controller-gain margin          factor on Kpe at which max|eig| reaches 1
%
% WHAT IS *NOT* INDEPENDENTLY VERIFIED AT THE SWITCHING LEVEL
%   S2 PM >= 50 deg and S3 GM >= 6 dB. A phase/gain margin is a small-signal
%   frequency-domain quantity; the switching model has no single linear loop to
%   measure it on. The numbers in the PM/GM columns are the DISCRETE AVERAGE
%   MODEL design values, carried over unchanged from Phase 3A.5. They are NOT a
%   switching-level verification and are flagged as such in every table and in
%   the JSON ("s2s3Source").
%
% The delay and gain margins above are the switching-level substitutes: they are
% weaker claims than PM/GM (scalar, one knob at a time) but they are measured on
% the real switching dynamics rather than inherited.

if nargin < 1 || isempty(outDir), outDir = getenv('BUCK_OUT'); end
outDir = strrep(outDir,'/',filesep);
here = fileparts(mfilename('fullpath')); addpath(fileparts(here));
if ~exist(outDir,'dir'), mkdir(outDir); end

Vref = 12; Ts = 20e-6;
conds = [ ...
    struct('id','C1','Vin',48,'R',6,  'L',150e-6)
    struct('id','C2','Vin',42,'R',6,  'L',150e-6)
    struct('id','C3','Vin',54,'R',6,  'L',150e-6)
    struct('id','C4','Vin',48,'R',12, 'L',150e-6)
    struct('id','C5','Vin',48,'R',3,  'L',150e-6)
    struct('id','C6','Vin',54,'R',3,  'L',150e-6)
    struct('id','C7','Vin',48,'R',6,  'L',195e-6) ];

fprintf('=========== 3A.6 Task 1: switching-level stability (Floquet) ===========\n');
fprintf('map: one switching period, closed loop, boundary sampling, half-ripple comp.\n');
fprintf('S1 here = max|eig(DP)| < 1 (exact local stability of the periodic orbit).\n');
fprintf('S2/S3 columns are DISCRETE AVERAGE-MODEL DESIGN VALUES, not switch-level.\n\n');

R = struct('cond',{},'phase',{},'maxAbs',{},'margin',{},'iter',{}, ...
    'converged',{},'lamEmp',{},'nDly',{},'pmDesign',{},'gmDesign',{}, ...
    'maxAbsZ',{},'s1Pass',{},'s1Verdict',{},'note','');

for ic = 1:numel(conds)
    c = conds(ic);
    % pre-step and post-step orbits are different: both must be stable
    phases = {'pre', c.R; 'post', c.R/2};
    for ip = 1:2
        Rorb = phases{ip,2};
        p = dual_params(c.Vin, Rorb, c.L, 'nDly', 1);
        rr = sw_floquet(p, struct('verbose', true));

        % average-model discrete design values (PM/GM) for reference only
        q = struct('Vin',c.Vin,'L',c.L,'C',220e-6,'R',Rorb,'Vref',Vref,'fs',50e3);
        Gv = tf(dual_loop_gain(q, Rorb, p.Kci, p.Kpe, p.Kie, 1, 'plant'));
        Cs = tf([p.Kpe p.Kie],[1 0]);
        Ld = c2d(Cs,Ts,'zoh')*tf(1,[1 0],Ts)*c2d(Gv,Ts,'zoh');
        [pmD, gmD] = margin_fast(Ld, 4000);
        maxAbsZ = max(abs(pole(feedback(Ld,1))));

        % S1 uses the SINGLE shared rule (s1_verdict.m) so this script and the
        % regression test cannot drift apart.
        [s1, v] = s1_verdict(rr.converged, rr.maxAbs);
        rec = struct('cond',c.id,'phase',phases{ip,1},'maxAbs',rr.maxAbs, ...
            'margin',rr.margin,'iter',rr.iter,'converged',rr.converged, ...
            'lamEmp',rr.lamEmp,'nDly',1,'pmDesign',pmD,'gmDesign',gmD, ...
            'maxAbsZ',maxAbsZ,'s1Pass',s1,'s1Verdict',v, ...
            'note','S2/S3 columns are average-model design values, not measured at switching level');
        R(end+1) = rec; %#ok<AGROW>
        fprintf('  %s %-4s : max|lam|=%.5f margin=%.5f (avg-model max|z|=%.5f, dev=%.2f%%) PM=%.2f GM=%.2f -> S1 %s\n', ...
            c.id, phases{ip,1}, rr.maxAbs, rr.margin, maxAbsZ, ...
            (rr.maxAbs-maxAbsZ)/maxAbsZ*100, pmD, gmD, v);
    end
end

%% ---------- switching-level robustness margins (C1, pre-step orbit) ----------
fprintf('\n--- switching-level robustness margins (C1 pre-step) ---\n');
p1 = dual_params(48, 6, 150e-6, 'nDly', 1);

% (a) delay margin: largest integer delay that is still stable
delayMargin = NaN;
for dl = 0:4
    pd = dual_params(48, 6, 150e-6, 'nDly', dl);
    rd = sw_floquet(pd, struct('verbose', false, 'maxIter', 1500));
    % If there is no period-1 orbit the multiplier is evaluated on a point that is
    % NOT an orbit, so quoting it as "unstable, lambda=0.99" would be wrong
    % reasoning. The honest statement is "no period-1 orbit exists".
    if rd.converged
        [okd, vd] = s1_verdict(rd.converged, rd.maxAbs);
        fprintf('  nDly=%d : max|lam|=%.5f %s\n', dl, rd.maxAbs, vd); %#ok<NASGU>
    else
        fprintf('  nDly=%d : NO period-1 orbit within %d periods (multiplier not defined; time domain shows a limit cycle)\n', ...
            dl, 1500);
    end
    if rd.converged && rd.maxAbs < 1
        delayMargin = dl;
    elseif ~isnan(delayMargin)
        break;                       % first unstable delay ends the margin
    end
end
fprintf('  => delay margin = %d period(s)\n', delayMargin);

% (b) controller-gain margin measured on the switching dynamics:
%     scale Kpe until max|lambda| reaches 1 (bisection). This is the switching
%     equivalent of a gain margin, in controller-gain terms rather than dB of loop gain.
gLo = 1; gHi = 1;
while gHi < 8
    gHi = gHi*1.5;
    pk = dual_params(48, 6, 150e-6, 'nDly', 1, 'Kpe', p1.Kpe*gHi);
    rk = sw_floquet(pk, struct('verbose', false, 'maxIter', 2000));
    if ~(rk.converged && rk.maxAbs < 1), break; end
end
fprintf('  Kpe x%.2f : max|lam|=%.5f (search bracket)\n', gHi, rk.maxAbs);
for it = 1:12
    gMid = 0.5*(gLo+gHi);
    pk = dual_params(48, 6, 150e-6, 'nDly', 1, 'Kpe', p1.Kpe*gMid);
    rk = sw_floquet(pk, struct('verbose', false, 'maxIter', 2000));
    if rk.converged && rk.maxAbs < 1, gLo = gMid; else, gHi = gMid; end
end
kpeMargin = gLo;
fprintf('  => controller-gain margin (Kpe) = x%.3f  (%.2f dB)\n', kpeMargin, 20*log10(kpeMargin));

margins = struct('delayMarginPeriods', delayMargin, ...
    'kpeMarginFactor', kpeMargin, 'kpeMarginDB', 20*log10(kpeMargin), ...
    'note',['scalar one-knob-at-a-time margins measured on the switching map; ' ...
            'they are NOT a phase margin and NOT a gain margin in dB of loop gain']);

%% ---------- summary ----------
nPass = nnz([R.s1Pass]);
nDet  = nnz([R.converged]);
fprintf('\n---- Task 1 summary ----\n');
fprintf('  orbits analysed : %d (7 conditions x pre/post step)\n', numel(R));
fprintf('  period-1 orbits found : %d / %d\n', nDet, numel(R));
fprintf('  S1 PASS (Floquet < 1) : %d / %d\n', nPass, numel(R));
fprintf('  delay margin = %d period(s) ; Kpe margin = x%.3f\n', delayMargin, kpeMargin);

res = struct('level','D-stability', ...
    'method','Floquet multipliers of the closed-loop switching period map', ...
    's1Definition','max|eig(DP(x*))| < 1 on a converged period-1 orbit', ...
    's2s3Source',['average-model discrete design values (not switching-level); ' ...
                  'substituted by the scalar margins below'], ...
    'margins', margins, 'records', R, 'nPass', nPass, 'nDetermined', nDet, ...
    'nOrbits', numel(R), 'matlabVersion', version);
save(fullfile(outDir,'a6_stability.mat'),'res');
txt = jsonencode(res);
fid = fopen(fullfile(outDir,'a6_stability.json'),'w');
if fid >= 0, fwrite(fid, txt, 'char'); fclose(fid); end
fprintf('saved a6_stability.mat/.json\n');
end

function s = tern(c,a,b)
if c, s = a; else, s = b; end
end
