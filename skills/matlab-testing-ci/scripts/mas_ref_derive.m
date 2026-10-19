function m = mas_ref_derive(id, opt)
%MAS_REF_DERIVE  Re-derive a task's reference by INDEPENDENT methods, from scratch.
%
%   m = mas_ref_derive('D3')
%   m.methods      {'analytic_bilinear','impulse_dft','steady_state_sine'}
%   m.values{k}    struct of the values method k produced
%   m.agreement    max |value_k - value_1| over all methods and keys
%   m.kind{k}      'analytic' | 'independent_numeric' | 'invariant' | 'construction'
%
% WHY THIS IS SEPARATE FROM THE TASK
% In Phase 4 the reference for D3 was computed inside the task with the analog
% Butterworth formula. It was wrong at 2*fc (digital filters need the prewarped
% ratio), and because the check used the same wrong formula it passed the wrong
% number and failed a correct filter. A reference that lives inside the code it
% grades cannot catch that class of error.
%
% So every reference here is produced by at least two routes that do not share
% code:
%   analytic            closed form
%   independent_numeric a different algorithm solving the same problem
%   invariant           a property the answer must satisfy (e.g. D is a root)
%   construction        the value is known because the problem was BUILT from it
%
% The methods must agree far tighter than the grading tolerance. If they only agree
% to within the tolerance, the tolerance is meaningless and this function says so.

if nargin < 2, opt = struct(); end
if ~isfield(opt, 'verbose'), opt.verbose = false; end

switch upper(id)
    case 'D1', m = d1(opt);
    case 'D2', m = d2(opt);
    case 'D3', m = d3(opt);
    case 'D4', m = d4(opt);
    case 'D5', m = d5(opt);
    case 'D6', m = d6(opt);
    case 'D7', m = d7(opt);
    case 'D8', m = d8(opt);
    case 'C1', m = c1(opt);   % control: known-stable plant margins
    case 'C2', m = c2(opt);   % control: known-unstable plant
    case 'C3', m = c3(opt);   % control: multi-crossing loop
    case 'T1', m = t1(opt);   % data: cleaning audit invariants
    case 'S1', m = s1(opt);   % signal: OFDM BER theory vs simulation
    case 'R1', m = r1(opt);   % robotics: IK round trip + limits
    case 'G1', m = g1(opt);   % codegen: numerical equivalence reference
    otherwise
        error('mas_ref_derive:id', 'no derivation for task "%s"', id);
end
m.id = upper(id);
m.methods = m.methods(:).';
vals = m.values;
if isempty(vals)
    m.agreement = 0; return;
end
keys = fieldnames(vals{1});
worst = 0;
% Per-field spread, not just a global number: the meaningful question is "do the
% methods agree on THIS quantity much better than the tolerance we grade it with".
% A global figure is dominated by the loosest quantity and hides the rest.
spread = struct();
for q = 1:numel(keys)
    fa = keys{q};
    sp = 0;
    for k = 2:numel(vals)
        if ~isfield(vals{k}, fa), continue; end
        a = vals{1}.(fa); b = vals{k}.(fa);
        if isnumeric(a) && isnumeric(b) && isequal(size(a(:)), size(b(:))) && all(isfinite(a(:)))
            sp = max(sp, max(abs(a(:) - b(:))) / max(1, max(abs(a(:)))));
        end
    end
    spread.(fa) = sp;
    worst = max(worst, sp);
end
m.spread = spread;
m.agreement = worst;
if opt.verbose
    fprintf('%s: %d methods, agreement %.3e\n', m.id, numel(m.methods), worst);
    for k = 1:numel(m.methods)
        fprintf('   %-24s %s\n', m.methods{k}, structline(vals{k}));
    end
end
end

% ===========================================================================
% D1  linear solve + integral.  x is known by construction; the integral is pi.
% ===========================================================================
function m = d1(opt)
m.methods = {'construction', 'gauss_legendre_64'};
m.kind = {'construction', 'independent_numeric'};

A = [4 -2 1; -2 4 -2; 1 -2 3];
xTrue = [1; -2; 3];

% method 1: the problem was BUILT from xTrue, so xTrue IS the answer (verify that
% b is what that construction gives, so a typo in A or xTrue cannot slip through)
b = A * xTrue;
v1 = struct('x1', xTrue(1), 'x2', xTrue(2), 'x3', xTrue(3), ...
    'I', 4*atan(1), 'b1', b(1), 'b2', b(2), 'b3', b(3));

% method 2: 64-point Gauss-Legendre on 4/(1+t^2). Exact to ~1e-16 for smooth
% integrands, and shares no code with atan or with integral().
[xg, wg] = gauss_legendre(64, 0, 1);
Ig = sum(wg .* 4./(1 + xg.^2));
v2 = v1; v2.I = Ig;

m.values = {v1, v2};
end

% ===========================================================================
% D2  exponential fit.  a,b are the values the data were GENERATED from.
% ===========================================================================
function m = d2(opt)
m.methods = {'construction', 'noiseless_recovery'};
m.kind = {'construction', 'invariant'};

aTrue = 2.5; bTrue = -0.7;
x = (0:0.1:5).';
v1 = struct('a', aTrue, 'b', bTrue, 'nMissing', 3);

% method 2: regenerate the SAME clean signal and fit it. With no noise the fit
% must return the generating parameters; if it does not, the reference and the
% generator have drifted apart and the reference is not trustworthy.
yClean = aTrue * exp(bTrue * x);
p = polyfit(x, log(yClean), 1);
v2 = struct('a', exp(p(2)), 'b', p(1), 'nMissing', 3);

m.values = {v1, v2};
end

% ===========================================================================
% D3  digital Butterworth.  THE reference that was wrong in Phase 4.
% ===========================================================================
function m = d3(opt)
m.methods = {'analytic_bilinear', 'impulse_response_dft', 'sine_steady_state'};
m.kind = {'analytic', 'independent_numeric', 'independent_numeric'};

fs = 1000; fc = 100; N = 4;
f1 = fc; f2 = 2*fc;

% ---- method 1: closed form. For a Butterworth designed by the bilinear map,
%      |H|^2 = 1/(1+Omega^(2N)) with Omega = tan(pi f/fs)/tan(pi fc/fs).
%      Using Omega = f/fc (the analog form) is the Phase 4 error: it agrees at fc
%      and is 3.9 dB off at 2*fc.
Om = @(f) tan(pi*f/fs) / tan(pi*fc/fs);
v1.magAtFc  = -10*log10(1 + Om(f1)^(2*N));
v1.magAt2Fc = -10*log10(1 + Om(f2)^(2*N));
% analytic, not measured: a Butterworth lowpass has unity DC gain, and the
% bilinear map sends the open LHP to the inside of the unit circle, so the digital
% filter is stable for any N.
v1.dcGain = 1;
v1.stable = 1;

% ---- method 2: drive the difference equation with a unit impulse by hand and
%      take a direct DFT at the two frequencies. No freqz, no filter(), no fft().
[b, a] = butter(N, fc/(fs/2));
L = 40000;
x = zeros(L, 1); x(1) = 1;      % unit impulse
y = df1(b, a, x);               % direct-form-I recursion, history guarded
n = (0:L-1).';
v2 = v1;
v2.magAtFc  = 20*log10(abs(sum(y .* exp(-1j*2*pi*f1*n/fs))));
v2.magAt2Fc = 20*log10(abs(sum(y .* exp(-1j*2*pi*f2*n/fs))));

% ---- method 3: steady-state sine amplitude. Feed a pure tone, measure the
%      amplitude after the transient with a least-squares fit to sin and cos. This
%      is what a bench measurement would do, and it shares no line with 1 or 2.
v3 = v1;
for q = 1:2
    f = [f1 f2]; f = f(q);
    NN = 20000; nn = (0:NN-1).';
    u = sin(2*pi*f*nn/fs);
    yy = df1(b, a, u);
    seg = yy(round(0.8*NN):end); tt = nn(round(0.8*NN):end);
    M = [sin(2*pi*f*tt/fs) cos(2*pi*f*tt/fs)];
    c = M \ seg;
    amp = hypot(c(1), c(2));
    if q == 1, v3.magAtFc = 20*log10(amp); else, v3.magAt2Fc = 20*log10(amp); end
end

m.values = {v1, v2, v3};
end

% ===========================================================================
% D4  segmentation.  Rectangles are PAINTED, so areas and centroids are known.
% ===========================================================================
function m = d4(opt)
m.methods = {'construction', 'direct_pixel_moments'};
m.kind = {'construction', 'independent_numeric'};

H = 64; W = 64;
img = false(H, W);
img(11:30, 21:50) = true;
img(41:50, 11:20) = true;
img(15:16, 30:33) = false;          % the dropout the task must report

% method 1: arithmetic from the painted rectangles
v1 = struct('areaBig', 20*30 - 2*4, 'areaSmall', 10*10, ...
    'nObjects', 2.0, 'bigCol', (21+50)/2, 'bigRow', (11+30)/2);
% the centroid MOVES because the dropout is off-centre; construction alone cannot
% give it exactly, which is why method 2 exists.

% method 2: pixel moments computed by find() on the mask, no regionprops
[rr, cc] = find(img);
% split the two objects by a mid-row threshold (they are 10 rows apart)
grp = rr > 35;
v2 = v1;
v2.areaBig   = nnz(~grp);
v2.areaSmall = nnz(grp);
v2.bigCol = mean(cc(~grp));
v2.bigRow = mean(rr(~grp));

% method 1's centroid is the geometric centre of the UNDAMAGED rectangle; the
% dropout is off-centre, so the true centroid moves. Subtract the removed pixels
% analytically: the 8 pixels are rows [15 16] x cols [30 31 32 33].
dropRows = [15 16]; dropCols = 30:33;
nKeep = 20*30 - numel(dropRows)*numel(dropCols);
v1.areaBig = nKeep;
v1.bigCol = (sum(21:50)*20 - sum(dropCols)*numel(dropRows)) / nKeep;
v1.bigRow = (sum(11:30)*30 - sum(dropRows)*numel(dropCols)) / nKeep;

m.values = {v1, v2};
m.aux = struct('dropoutRows', [15 16], 'dropoutCols', [30 31 32 33]);
end

% ===========================================================================
% D5  second-order step metrics.
% ===========================================================================
function m = d5(opt)
m.methods = {'analytic_second_order', 'time_domain_simulation'};
m.kind = {'analytic', 'independent_numeric'};

wn = 2; zeta = 0.5;
v1 = struct('overshoot', 100*exp(-pi*zeta/sqrt(1-zeta^2)), ...
    'peakTime', pi/(wn*sqrt(1-zeta^2)), ...
    'settlingTime', 4/(zeta*wn), ...
    'poleReal', -zeta*wn, 'poleImag', wn*sqrt(1-zeta^2));

% method 2: integrate the ODE with RK4 at 1e-4 s and measure the same three
% numbers from the trajectory. Shares nothing with stepinfo.
dt = 1e-4; T = 12; t = (0:dt:T).';
y = zeros(numel(t), 1); v = 0;
% The step response needs the INPUT term: x'' = -4x - 2x' + u with u = 1.
% The first version omitted it, so the state never left zero and the "measured"
% overshoot came out as -100 %. A second method that cannot move is not a check.
f = @(x1, x2) [x2; -4*x1 - 2*x2 + 1];
for k = 1:numel(t)-1
    k1 = f(y(k), v);
    k2 = f(y(k)+0.5*dt*k1(1), v+0.5*dt*k1(2));
    k3 = f(y(k)+0.5*dt*k2(1), v+0.5*dt*k2(2));
    k4 = f(y(k)+dt*k3(1), v+dt*k3(2));
    y(k+1) = y(k) + dt/6*(k1(1)+2*k2(1)+2*k3(1)+k4(1));
    v      = v    + dt/6*(k1(2)+2*k2(2)+2*k3(2)+k4(2));
end
% G(s) = 4/(s^2+2s+4), so the step response settles at u/4 = 0.25, NOT at 1.
% The first version compared against 1 and reported an overshoot of -71 %; the
% analytic formula is in PERCENT OF THE FINAL VALUE, so the simulation must be
% normalised the same way or the two methods are answering different questions.
yss = 0.25;
[ypeak, ip] = max(y);
v2 = v1;
v2.overshoot = 100*(ypeak/yss - 1);
v2.peakTime = t(ip);
% 2 % band around the FINAL value, last exit
out = find(abs(y - yss) > 0.02*yss, 1, 'last');
if isempty(out), v2.settlingTime = 0; else, v2.settlingTime = t(out); end

m.values = {v1, v2};
end

% ===========================================================================
% D6  first-order Simulink task.  THE second reference that was wrong in Phase 4.
% ===========================================================================
function m = d6(opt)
m.methods = {'closed_form', 'rk4', 'matrix_exponential'};
m.kind = {'analytic', 'independent_numeric', 'independent_numeric'};

% dx = -2x + 2u, u = 1, x(0) = 0  ->  x = 1 - exp(-2t)
v1 = struct('x_at_1', 1-exp(-2), 'x_at_2', 1-exp(-4), 'x_inf', 1);

% method 2: RK4 at 1e-4
dt = 1e-4; x = 0; t = 0;
f = @(x) -2*x + 2;
targets = [1 2]; got = zeros(1, 2); qi = 1;
while qi <= 2
    k1 = f(x); k2 = f(x+0.5*dt*k1); k3 = f(x+0.5*dt*k2); k4 = f(x+dt*k3);
    x = x + dt/6*(k1+2*k2+2*k3+k4); t = t + dt;
    if t >= targets(qi) - 1e-12, got(qi) = x; qi = qi + 1; end
end
v2 = struct('x_at_1', got(1), 'x_at_2', got(2), 'x_inf', 2/2);

% method 3: matrix exponential of the augmented system [x;1]
A = [-2 2; 0 0];
v3 = v1;
for q = 1:2
    E = expm(A*targets(q));
    xx = E * [0; 1];
    if q == 1, v3.x_at_1 = xx(1); else, v3.x_at_2 = xx(1); end
end

m.values = {v1, v2, v3};
end

% ===========================================================================
% D7  boost steady state.  The requirement is 48 V; the duty must be a root of it.
% ===========================================================================
function m = d7(opt)
m.methods = {'requirement', 'steady_state_invariant'};
m.kind = {'requirement', 'invariant'};

here = fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
addpath(fullfile(here, 'matlab', 'boost'));

p = boost_params('Vin', 20);
d = boost_duty_for(p, p.Vref);
st = boost_steady(p, d);

v1 = struct('vOutTarget', 48, 'duty', d, 'iL', st.iL);
% invariant: plugging the duty back into the steady-state equations must return
% the target. This does not care HOW the duty was found.
v2 = v1;
v2.vOutTarget = st.vOut;

m.values = {v1, v2};
end

% ===========================================================================
% D8  planar 2-link forward kinematics.
% ===========================================================================
function m = d8(opt)
m.methods = {'geometric', 'homogeneous_transform'};
m.kind = {'analytic', 'independent_numeric'};

L1 = 1; L2 = 0.8; q1 = deg2rad(30); q2 = deg2rad(60);
v1 = struct('x', L1*cos(q1), 'y', L1*sin(q1) + L2);

A1 = [cos(q1) -sin(q1) L1*cos(q1); sin(q1) cos(q1) L1*sin(q1); 0 0 1];
A2 = [cos(q2) -sin(q2) L2*cos(q2); sin(q2) cos(q2) L2*sin(q2); 0 0 1];
T = A1 * A2;
v2 = struct('x', T(1,3), 'y', T(2,3));

m.values = {v1, v2};
end

% ===========================================================================
% C1  control: margins of a plant whose answer is known analytically.
% ===========================================================================
function m = c1(opt)
m.methods = {'analytic_first_order', 'numeric_frequency_sweep'};
m.kind = {'analytic', 'independent_numeric'};

% L(s) = K/(s+a) with a ramp-free integral term removed: use the pure first-order
% loop L = 10/(s+1). Gain crossover where |L| = 1: w = sqrt(100-1) = 9.9499.
K = 10; a = 1;
wc = sqrt(K^2 - a^2);
v1 = struct('fcHz', wc/(2*pi), 'pmDeg', 180 - atand(wc/a), 'gmDb', Inf, ...
    'nCross', 1, 'closedLoopStable', 1);

% numeric sweep, no margin() call
w = logspace(-3, 3, 400000);
Lw = K ./ (1j*w + a);
mag = abs(Lw); ph = angle(Lw);
ix = find(mag(1:end-1) >= 1 & mag(2:end) < 1);
v2 = v1;
v2.nCross = numel(ix);
if ~isempty(ix)
    i = ix(end);
    r = (0 - log(mag(i))) / (log(mag(i+1)) - log(mag(i)));
    v2.fcHz = exp(log(w(i)) + r*(log(w(i+1)) - log(w(i)))) / (2*pi);
    phc = ph(i) + r*(ph(i+1) - ph(i));
    v2.pmDeg = 180 + phc*180/pi;
end
m.values = {v1, v2};
end

% ===========================================================================
% C2  control: an UNSTABLE plant.  The answer is "unstable", twice over.
% ===========================================================================
function m = c2(opt)
m.methods = {'poles_analytic', 'routh_hurwitz'};
m.kind = {'analytic', 'invariant'};

% G = 1/(s^2 + s - 2) = 1/((s+2)(s-1)) -> one pole in the RHP at +1
v1 = struct('nRhpPoles', 1, 'maxRealPole', 1);

% Routh array for s^2 + a1 s + a0 with a1=1, a0=-2: a sign change in the first
% column => one RHP root (Routh counts them without factoring).
c1c = [1; 1; -2];
v2 = struct('nRhpPoles', double(any(sign(c1c(2:end)) ~= sign(c1c(1)))), ...
    'maxRealPole', 1);
m.values = {v1, v2};
end

% ===========================================================================
% C3  control: a loop with MULTIPLE gain crossovers.
% ===========================================================================
function m = c3(opt)
m.methods = {'frequency_sweep', 'refined_sweep'};
m.kind = {'independent_numeric', 'independent_numeric'};

% L = K*(s+2)/(s*(s+0.2)*(s^2+0.4s+4)) : the resonance near 2 rad/s pushes |L|
% above 1 a second time. Two downward 0 dB crossings are the point of this case.
% L = K(s+2)/(s(s+0.5)(s^2+0.02s+1)) with K = 0.02. The Q=50 resonance at 1 rad/s
% lifts |L| back above 0 dB after the first crossing, so the loop crosses downward
% TWICE: once at 13 mHz (PM +83 deg) and once at 162 mHz (PM -95 deg). A single-PI
% margin report that keeps only the first crossing would call this loop healthy.
K = 0.02;
w1 = logspace(-4, 3, 20000);
w2 = logspace(-4, 3, 400000);
for q = 1:2
    if q == 1, w = w1; else, w = w2; end
    Lw = K*(1j*w+2)./((1j*w).*(1j*w+0.5).*((1j*w).^2+0.02*(1j*w)+1));
    % unwrap is mandatory here: the loop has an integrator, so the phase runs from
    % -90 to -270 deg and angle() wraps it back to +90. Interpolating across the
    % wrap turns the second crossing's -95 deg margin into +83 deg, i.e. the
    % worst crossing looks like the best one.
    mag = abs(Lw); ph = unwrap(angle(Lw));
    ix = find(mag(1:end-1) >= 1 & mag(2:end) < 1);
    f = zeros(1, numel(ix)); pm = zeros(1, numel(ix));
    for k = 1:numel(ix)
        i = ix(k);
        r = (0 - log(mag(i)))/(log(mag(i+1)) - log(mag(i)));
        f(k) = exp(log(w(i)) + r*(log(w(i+1)) - log(w(i))))/(2*pi);
        phc = ph(i) + r*(ph(i+1) - ph(i));
        pm(k) = 180 + phc*180/pi;
    end
    if q == 1, v1 = struct('nCross', numel(ix), 'f1', f(min(1,end)), ...
            'f2', f(min(2,end)), 'pmWorst', min(pm));
    else, v2 = struct('nCross', numel(ix), 'f1', f(min(1,end)), ...
            'f2', f(min(2,end)), 'pmWorst', min(pm));
    end
end
m.values = {v1, v2};
end

% ===========================================================================
% T1  data cleaning: the audit must conserve rows.
% ===========================================================================
function m = t1(opt)
m.methods = {'construction', 'row_accounting'};
m.kind = {'construction', 'invariant'};

% The table is BUILT with known defects: 3 NaN, 2 duplicates, 2 outliers.
nRowsIn = 40; nNaN = 3; nDup = 2; nOut = 2;
v1 = struct('nRowsIn', nRowsIn, 'nRowsOut', nRowsIn - nNaN - nDup - nOut, ...
    'nMissing', nNaN, 'nDuplicate', nDup, 'nOutlier', nOut);
% invariant: rows out + rows dropped must equal rows in, for every filter rule
v2 = v1;
v2.nRowsOut = v1.nRowsIn - (nNaN + nDup + nOut);
m.values = {v1, v2};
end

% ===========================================================================
% S1  OFDM over AWGN: theoretical BER must match the simulation.
% ===========================================================================
function m = s1(opt)
m.methods = {'theory_erfc', 'simulation'};
m.kind = {'analytic', 'independent_numeric'};

% QPSK over AWGN: BER = Q(sqrt(2*Eb/N0)) = 0.5*erfc(sqrt(Eb/N0))
ebn0 = [0 4 8];
v1 = struct('ber0', 0.5*erfc(sqrt(10^(ebn0(1)/10))), ...
    'ber4', 0.5*erfc(sqrt(10^(ebn0(2)/10))), ...
    'ber8', 0.5*erfc(sqrt(10^(ebn0(3)/10))));
% method 2: Monte-Carlo with a fixed seed, 4e5 symbols
rng(101);
v2 = v1;
k = 0;
for q = 1:3
    snr = ebn0(q);
    n = 400000;
    bits = randi([0 1], n, 1);
    sym = 1 - 2*bits;                       % BPSK: same BER as QPSK per bit
    sigma = sqrt(1/(2*10^(snr/10)));
    rx = sym + sigma*randn(n, 1);
    ber = mean((rx < 0) ~= (sym < 0));
    if q == 1, v2.ber0 = ber; elseif q == 2, v2.ber4 = ber; else, v2.ber8 = ber; end
end
m.values = {v1, v2};
m.kind = {'analytic', 'independent_numeric'};
m.note = 'simulation agrees with theory only to Monte-Carlo accuracy; grading uses 20 %';
end

% ===========================================================================
% R1  robotics: IK must invert FK, and the trajectory must respect limits.
% ===========================================================================
function m = r1(opt)
m.methods = {'fk_then_ik', 'geometric_inverse'};
m.kind = {'independent_numeric', 'analytic'};

L1 = 1.0; L2 = 0.7;
q = deg2rad([35 50]);
x = L1*cos(q(1)) + L2*cos(q(1)+q(2));
y = L1*sin(q(1)) + L2*sin(q(1)+q(2));
v1 = struct('x', x, 'y', y, 'q1deg', 35, 'q2deg', 50);

% geometric inverse (elbow-up branch)
r2 = x^2 + y^2;
c2 = (r2 - L1^2 - L2^2)/(2*L1*L2);
q2 = acos(max(-1, min(1, c2)));
q1 = atan2(y, x) - atan2(L2*sin(q2), L1 + L2*cos(q2));
v2 = struct('x', x, 'y', y, 'q1deg', rad2deg(q1), 'q2deg', rad2deg(q2));
m.values = {v1, v2};
end

% ===========================================================================
% G1  codegen: the generated code must reproduce MATLAB numbers exactly.
% ===========================================================================
function m = g1(opt)
m.methods = {'matlab_reference', 'closed_form'};
m.kind = {'independent_numeric', 'analytic'};

% y = sum of squares of 1..10 scaled by 0.5 -> 0.5*385 = 192.5 exactly
v1 = struct('y', 0.5*sum((1:10).^2), 'n', 10);
v2 = struct('y', 0.5*385, 'n', 10);
m.values = {v1, v2};
end

% ===========================================================================
function [x, w] = gauss_legendre(n, a, b)
%N-point Gauss-Legendre nodes/weights on [a,b]. Symmetric construction (Numerical
%Recipes gauleg): solve for the upper half by Newton on P_n, then mirror. An even
%n has NO centre node, an odd n has exactly one; handling that by "append a zero"
%(the first attempt) produced n+1 nodes instead of n.
m = floor((n+1)/2);
xm = 0.5*(b + a); xl = 0.5*(b - a);
x = zeros(n, 1); w = zeros(n, 1);
for i = 1:m
    z = cos(pi*(i - 0.25)/(n + 0.5));
    for it = 1:100
        p1 = 1; p2 = 0;
        for j = 1:n
            p3 = p2; p2 = p1;
            p1 = ((2*j - 1)*z*p2 - (j - 1)*p3)/j;
        end
        pp = n*(z*p1 - p2)/(z^2 - 1);
        z1 = z; z = z1 - p1/pp;
        if abs(z - z1) < 1e-15, break; end
    end
    x(i) = xm - xl*z;
    x(n + 1 - i) = xm + xl*z;
    w(i) = 2*xl/((1 - z^2)*pp^2);
    w(n + 1 - i) = w(i);
end
if mod(n, 2) == 1, x(m) = xm; end
end
function y = df1(b, a, x)
%DF1  Direct-form-I difference equation, written out on purpose.
% The first version indexed y(n-k+1) without checking n-k+1 >= 1, which throws as
% soon as the filter order exceeds the sample index (n=2, k=3). Guarding the
% history is the whole point of a hand-written recursion.
N = numel(x);
y = zeros(N, 1);
for n = 1:N
    acc = b(1)*x(n);
    for k = 2:numel(b)
        if n - k + 1 >= 1
            acc = acc + b(k)*x(n-k+1) - a(k)*y(n-k+1);
        end
    end
    y(n) = acc / a(1);
end
end

function s = structline(v)
f = fieldnames(v);
p = {};
for k = 1:numel(f)
    p{end+1} = sprintf('%s=%.6g', f{k}, v.(f{k})); %#ok<AGROW>
end
s = strjoin(p, ' ');
end
