function phase52_heldout_freeze()
%PHASE52_HELDOUT_FREEZE  Freeze independent references for the Phase 5.2 held-out set.
%
%   The values here are derived ONLY from analytic formulas or from the problem
%   construction. No value is read back from the tool the held-out case grades.
%   The runner loads the frozen JSON and measures separately, so this file is
%   never called during grading.
%
%   Cases were authored after the P0 fixes and were not used to tune them.

here = fileparts(mfilename('fullpath'));
outFile = fullfile(here, 'heldout_reference.json');

E = struct();

% ---- H1 math / numerics ---------------------------------------------------
A = [1 1 1 1; 1 2 4 8; 1 3 9 27; 1 4 16 64];
xt = [2; -1; 0.5; 3];
v = struct();
v.x = xt;
v.I = sqrt(pi)/2*erf(1);          % integral of exp(-t^2) on [0,1]
E.H1 = entry('H1', 'math/numerics', ...
    'Vandermonde solve built from x; Gaussian integral has a closed form', v, [ ...
    ck('x', xt, 'maxabsdiff', 1e-9, 'A*x=b was constructed from this x'); ...
    ck('I', sqrt(pi)/2*erf(1), 'absdiff', 1e-10, 'integral exp(-t^2), 0..1 = sqrt(pi)/2*erf(1)')]);

% ---- H2 dynamic systems ---------------------------------------------------
v = struct();
v.x1 = 1 - exp(-3);               % dx=-3x+3, x(0)=0
v.x2 = 1 - exp(-6);
E.H2 = entry('H2', 'dynamic systems', ...
    'first-order ODE step response against the closed form', v, [ ...
    ck('x1', 1-exp(-3), 'absdiff', 1e-6, 'x(1)=1-exp(-3)'); ...
    ck('x2', 1-exp(-6), 'absdiff', 1e-6, 'x(2)=1-exp(-6)')]);

% ---- H3 control: negative gain, continuous -------------------------------
% L = -4/((s+1)(s+3)). 1+L = 0 -> s^2+4s-1, roots -2 +/- sqrt(5).
v = struct();
v.maxRealPole = -2 + sqrt(5);
v.math = 'UNSTABLE';
v.target = 'FAIL';
v.evidence = 'VERIFIED';
E.H3 = entry('H3', 'control (negative gain)', ...
    'negative loop gain: closed-loop denominator s^2+4s-1 has one RHP pole', v, [ ...
    ck('maxRealPole', -2+sqrt(5), 'absdiff', 1e-7, '-2+sqrt(5) is the RHP closed-loop pole'); ...
    ck('math', 'UNSTABLE', 'str', 0, 'a RHP closed-loop pole is not asymptotically stable'); ...
    ck('target', 'FAIL', 'str', 0, 'the engineering target cannot pass an unstable loop'); ...
    ck('evidence', 'VERIFIED', 'str', 0, 'poles and margins both produced usable values')]);

% ---- H4 control: discrete Nyquist and a no-crossing loop ------------------
% L(z)=0.4/(z-0.8): 1+L=0 gives z=0.4; at z=-1 (w=pi/Ts) L=-0.4/1.8, phase -180.
v = struct();
v.discGmDb = -20*log10(0.4/1.8);
v.discMath = 'STABLE';
v.discTarget = 'PASS';
v.discEvidence = 'VERIFIED';
v.ncMath = 'STABLE';
v.ncTarget = 'UNDETERMINED';
v.ncEvidence = 'PARTIAL';
v.ncPmIsNaN = true;
E.H4 = entry('H4', 'control (discrete / no crossing)', ...
    'discrete GM at Nyquist, plus a loop with no 0 dB crossing', v, [ ...
    ck('discGmDb', -20*log10(0.4/1.8), 'absdiff', 1e-6, 'GM = 1/|L(-1)| = 4.5 = 13.064 dB'); ...
    ck('discMath', 'STABLE', 'str', 0, 'closed-loop pole is 0.4, inside the unit circle'); ...
    ck('discTarget', 'PASS', 'str', 0, 'both PM and GM meet their targets'); ...
    ck('discEvidence', 'VERIFIED', 'str', 0, 'poles and margins agree'); ...
    ck('ncMath', 'STABLE', 'str', 0, 'L=0.5/(s+1) has a closed-loop pole at -1.5'); ...
    ck('ncTarget', 'UNDETERMINED', 'str', 0, 'no 0 dB crossing means no PM to grade'); ...
    ck('ncEvidence', 'PARTIAL', 'str', 0, 'only the pole source is available'); ...
    ck('ncPmIsNaN', true, 'true', 0, 'a missing PM must be NaN, not a fabricated number')]);

% ---- H5 Simulink: parameter change reaches the plant ----------------------
% K = 2 -> 5 on 1/(s+1), constant input 1. At t=2:
% y = K*(1-exp(-2)); delta = 3*(1-exp(-2)).
v = struct();
v.delta = 3*(1 - exp(-2));
v.effectiveTime = 0;
v.verdict = 'PASS';
v.evidence = 'VERIFIED';
E.H5 = entry('H5', 'Simulink (parameter propagation)', ...
    'gain K 2 -> 5 must reach the plant and change y by 3*(1-exp(-2))', v, [ ...
    ck('delta', 3*(1-exp(-2)), 'absdiff', 2e-3, 'linear in K: 3*(1-exp(-2)) at t=2'); ...
    ck('effectiveTime', 0.011, 'le', 0, 'no later than the first solver step (0.01 s): in force from t=0'); ...
    ck('verdict', 'PASS', 'str', 0, 'plant receipt + timing + prediction all verified'); ...
    ck('evidence', 'VERIFIED', 'str', 0, 'the evidence chain is complete')]);

% ---- H6 signal: OFDM BER at a held-out SNR -------------------------------
v = struct();
v.ber6 = 0.5*erfc(sqrt(10^(6/10)));
E.H6 = entry('H6', 'signal processing (OFDM)', ...
    'QPSK-OFDM at 6 dB, a point absent from the dev reference set', v, [ ...
    ck('ber6', 0.5*erfc(sqrt(10^(6/10))), 'reldiff', 0.15, 'counting-noise tolerance at ~600 errors')]);

% ---- H7 routing: multi-skill prompt --------------------------------------
v = struct();
v.decision = 'ROUTE';
v.primary = 'matlab-simulink-modeling';
v.hasSecondary = 'matlab-signal-vision-ai';
v.loadOrder = 'matlab-runner>matlab-simulink-modeling>matlab-signal-vision-ai';
E.H7 = entry('H7', 'multi-skill routing', ...
    'a compound prompt that needs Simulink execution plus signal filtering', v, [ ...
    ck('decision', 'ROUTE', 'str', 0, 'the prompt is well above the scoring threshold'); ...
    ck('primary', 'matlab-simulink-modeling', 'str', 0, 'the model/simulation work carries the task'); ...
    ck('hasSecondary', 'matlab-signal-vision-ai', 'str', 0, 'the low-pass filter work joins as secondary'); ...
    ck('loadOrder', 'matlab-runner>matlab-simulink-modeling>matlab-signal-vision-ai', ...
        'str', 0, 'runner first, then the dependency order')]);

M = struct();
M.schema = 'phase52-heldout/1';
M.frozenAt = datestr(now, 31);
M.matlabVersion = version;
M.hashAlgo = 'sha256';
M.entries = E;
fid = fopen(outFile, 'w');
fwrite(fid, jsonencode(M), 'char');
fclose(fid);
fprintf('froze %d held-out entries -> %s\n', numel(fieldnames(E)), outFile);
for id = fieldnames(E).'
    fprintf('  %s %-38s hash %s\n', id{1}, E.(id{1}).domain, E.(id{1}).hash(1:12));
end
end

% ---------------------------------------------------------------------------
function e = entry(id, domain, note, values, checks)
e = struct('id', id, 'domain', domain, 'note', note, 'values', values, ...
    'checks', checks, 'hash', phase52_hash(values, checks));
end

function c = ck(field, ref, op, tol, why)
c = struct('field', field, 'ref', ref, 'op', op, 'tol', tol, 'why', why);
end
