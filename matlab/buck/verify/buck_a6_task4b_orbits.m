function res = buck_a6_task4b_orbits(outDir)
%BUCK_A6_TASK4B_ORBITS  What is the attractor when no period-1 orbit is found?
%
% Phase 3A.6 Task 4 found configurations where sw_floquet reports "no period-1
% orbit". That is an honest statement but a coarse one: the trajectory could be
%   (a) still converging, just slower than the iteration budget,
%   (b) settled on a stable period-2 (or period-4) orbit -- a period-doubling
%       bifurcation, which still produces a bounded, repeatable waveform and can
%       still pass every engineering metric, or
%   (c) a non-periodic attractor (quasi-periodic / chaotic).
% These are different engineering facts and the report must not merge them.
%
% METHOD
% Run the map for N periods, then measure the residual of x_{k+p} - x_k for
% p = 1,2,3,4 over the tail. A period-p orbit is claimed only if that residual is
% at machine level. For a period-p orbit the Floquet multipliers are the
% eigenvalues of the product of the p one-period Jacobians, which is what
% sw_floquet does for p = 1.

if nargin < 1 || isempty(outDir), outDir = getenv('BUCK_OUT'); end
outDir = strrep(outDir,'/',filesep);
here = fileparts(mfilename('fullpath')); addpath(fileparts(here));
if ~exist(outDir,'dir'), mkdir(outDir); end

N = 4000;
% name, nDly, phi, parameter to scale, factor
cases = { ...
  'baseline',        1, 0,     'Kci', 1.0; ...
  'delay2',          2, 0,     'Kci', 1.0; ...
  'delay2_phi0.125', 2, 0.125, 'Kci', 1.0; ...
  'delay2_phi0.25',  2, 0.25,  'Kci', 1.0; ...
  'phi0.25_Kci1.2',  1, 0.25,  'Kci', 1.2; ...
  'phi0.25_Kpe1.2',  1, 0.25,  'Kpe', 1.2; ...
  'phi0_Kci1.2',     1, 0,     'Kci', 1.2; ...
  'L_minus20pct',    1, 0,     'L',   0.8; ...
  'L_minus10pct',    1, 0,     'L',   0.9};

fprintf('=== 3A.6 Task 4b: attractor classification ===\n');
fprintf('%-18s %7s %6s %10s %10s %10s %10s | %s\n', ...
    'case','maxAbs','conv','res p=1','res p=2','res p=4','spread','verdict');
R = struct('name',{},'maxAbs',{},'converged',{},'r1',{},'r2',{},'r4',{}, ...
    'spread',{},'order',{},'lam2',{});

for q = 1:size(cases,1)
    nm = cases{q,1};
    p = dual_params(48,6,150e-6,'nDly',cases{q,2},'sampPhase',cases{q,3});
    if cases{q,5} ~= 1
        p.(cases{q,4}) = p.(cases{q,4})*cases{q,5};
    end
    L = sw_state_layout(p);

    % iterate and keep a tail buffer
    x = zeros(L.n,1); x(L.iIL)=p.Vref/p.R; x(L.iVC)=p.Vref;
    x(L.iXI)=0; if L.np>=1, x(L.idx)=p.Vref/p.Vin; end
    x(L.iYS)=p.Vref/p.R; if L.hasDxI, x(L.iDxI)=0; end
    buf = zeros(L.n, 8);
    for k = 1:N
        x = sw_period_map(x,p);
        if k > N-8, buf(:, k-(N-8)) = x; end
    end
    r1 = max(abs(buf(:,8)-buf(:,7)));
    r2 = max(abs(buf(:,8)-buf(:,6)));
    r4 = max(abs(buf(:,8)-buf(:,4)));
    spread = max(max(buf,[],2)-min(buf,[],2));

    rf = sw_floquet(p, struct('verbose',false,'maxIter',1200));

    % multipliers of the period-2 orbit, if there is one
    lam2 = NaN;
    if r2 < 1e-9 && r1 > 1e-9
        lam2 = per2_multipliers(p, buf(:,8));
    end

    if r1 < 1e-9
        ord = 'period-1';
    elseif r2 < 1e-9
        ord = 'period-2';
    elseif r4 < 1e-9
        ord = 'period-4';
    elseif spread < 1e-3
        ord = 'bounded, not low-period';
    else
        ord = 'large excursion';
    end
    fprintf('%-18s %7.4f %6d %10.2e %10.2e %10.2e %10.2e | %s\n', nm, rf.maxAbs, ...
        rf.converged, r1, r2, r4, spread, ord);
    R(end+1) = struct('name',nm,'maxAbs',rf.maxAbs,'converged',rf.converged, ...
        'r1',r1,'r2',r2,'r4',r4,'spread',spread,'order',ord,'lam2',lam2); %#ok<AGROW>
end

fprintf('\nREADING\n');
fprintf('  period-2 with |lambda|<1 means a stable period-doubling bifurcation: the\n');
fprintf('  waveform repeats every two switching periods. That is NOT the same failure\n');
fprintf('  as an unbounded or non-periodic response, and it is the reason the time\n');
fprintf('  domain can look "settled" while S1 (period-1 stability) is undetermined.\n');

res = struct('level','3A.6-Task4b','N',N,'records',R, ...
    'note',['sw_floquet reports "no period-1 orbit"; this file says WHAT the ' ...
            'attractor is instead. A period-2 orbit with all |lambda|<1 is a ' ...
            'bifurcation, not a divergence.']);
save(fullfile(outDir,'a6_task4b_orbits.mat'),'res');
fid = fopen(fullfile(outDir,'a6_task4b_orbits.json'),'w');
if fid >= 0, fwrite(fid, jsonencode(res), 'char'); fclose(fid); end
fprintf('saved a6_task4b_orbits.json/.mat\n');
end

% ---------------------------------------------------------------------------
function lmax = per2_multipliers(p, x2)
% eigenvalues of DP(x1)*DP(x2) for a period-2 orbit through x2
x1 = sw_period_map(x2, p);
n = numel(x2);
J = eye(n);
for xx = {x2, x1}
    J = jac(xx{1}, p) * J;
end
lmax = max(abs(eig(J)));
end

function J = jac(x, p)
n = numel(x);
J = zeros(n,n);
x0 = sw_period_map(x,p);
for q = 1:n
    h = 1e-7*max(1,abs(x(q)));
    xp = x; xp(q) = xp(q) + h;
    J(:,q) = (sw_period_map(xp,p) - x0)/h;
end
end
