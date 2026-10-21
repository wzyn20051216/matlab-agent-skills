function C = mas_ref_spec(id)
%MAS_REF_SPEC  Grading specification for one frozen reference.
%
%   C = mas_ref_spec('D3')
%
% Returns a struct array of checks. Each check says WHICH measured field to
% compare, WITH WHICH frozen reference value, USING WHICH comparison, AND WITH
% WHAT tolerance:
%
%   .field   field of the task's `values` struct
%   .ref     scalar or vector, copied from the frozen reference
%   .op      'absdiff' | 'reldiff' | 'maxabsdiff' | 'le' | 'ge' | 'true' | 'false'
%   .tol     tolerance for the diff ops
%   .why     one line a reviewer can read without opening the code
%
% The spec is frozen together with the values, so a later attempt to relax a
% tolerance has to change a committed, hashed file -- it cannot be done quietly in
% this function without failing mas_refcheck('verify').
%
% An empty C means "this task has a reference but no automatic grading spec yet";
% mas_verify_task then returns UNDETERMINED rather than PASS, because a reference
% nobody compares against is not evidence.

switch upper(id)
    case 'D1'
        C = [ ck('x',        [1 -2 3],  'maxabsdiff', 1e-8,  'exact integer solution'); ...
              ck('I_quad',   4*atan(1), 'absdiff',    1e-6,  'integral of 4/(1+t^2) on [0,1] = pi'); ...
              ck('I_trapz',  4*atan(1), 'absdiff',    1e-3,  'trapezoid, looser by design'); ...
              ck('residual', 0,         'absdiff',    1e-10, 'A*x-b must vanish') ];

    case 'D2'
        C = [ ck('aHat', 2.5, 'reldiff', 0.03, 'recover the generating amplitude'); ...
              ck('bHat', -0.7,'reldiff', 0.03, 'recover the generating rate'); ...
              ck('nMissing', 3, 'absdiff', 0,  'the 3 injected NaNs must be counted') ];

    case 'D3'
        C = [ ck('magAtFc',  -3.010299956639813, 'absdiff', 0.05, 'any Butterworth is -3.01 dB at fc'); ...
              ck('magAt2Fc', -27.9657,           'absdiff', 0.10, 'prewarped: -27.97 dB, analog formula says -24.10'); ...
              ck('stable',   1,                  'true',    0,    'poles inside the unit circle'); ...
              ck('dcGain',   1,                  'reldiff', 1e-9, 'lowpass DC gain is 1, not 0.707') ];

    case 'D4'
        C = [ ck('areas',       [592 100],       'maxabsdiff', 1,   'painted rectangles minus the 8-pixel dropout'); ...
              ck('centroidBig', [35.5541 20.5676],'maxabsdiff', 1.5, '[col row], not [row col]') ];

    case 'D5'
        C = [ ck('overshoot',    16.3034, 'absdiff', 0.25, 'exp(-pi*zeta/sqrt(1-zeta^2))'); ...
              ck('peakTime',     1.8138,  'absdiff', 0.02, 'pi/(wn*sqrt(1-zeta^2))'); ...
              ck('settlingTime', 4.0,     'absdiff', 0.20, '4/(zeta*wn)'); ...
              ck('stable',       1,       'true',    0,    'both poles in the LHP') ];

    case 'D6'
        C = [ ck('x_at_1', 0.864665, 'absdiff', 2e-3, '1-exp(-2)'); ...
              ck('x_at_2', 0.981684, 'absdiff', 2e-3, '1-exp(-4)') ];

    case 'D7'
        C = [ ck('ssErrPct', 0,    'absdiff', 0.5, 'the 48 V requirement, not what the model produced'); ...
              ck('iLrippleRatio', 1, 'reldiff', 0.10, 'measured ripple / analytic triangle = 1') ];

    case 'D8'
        C = [ ck('x', 0.8660254037844386, 'absdiff', 1e-9, 'sqrt(3)/2 by geometry'); ...
              ck('y', 1.3,                'absdiff', 1e-9, '0.5 + L2, the second link is vertical') ];

    case 'C1'
        C = [ ck('fcHz',  1.58357, 'absdiff', 1e-3, 'sqrt(K^2-a^2)/2pi for L=10/(s+1)'); ...
              ck('pmDeg', 95.7392, 'absdiff', 0.05, '180 - atan(wc/a)'); ...
              ck('nCross', 1,      'absdiff', 0,    'single well-behaved crossing'); ...
              ck('closedLoopStable', 1, 'true', 0,  'reported stable') ];

    case 'C2'
        C = [ ck('nRhpPoles', 1, 'absdiff', 0, '1/(s^2+s-2) has one pole at +1'); ...
              ck('maxRealPole', 1,'absdiff', 1e-9, 'that pole is +1, not -1'); ...
              ck('loopStable', 0, 'false', 0, 'must NOT be reported stable') ];

    case 'C3'
        C = [ ck('nCross', 2,        'absdiff', 0,    'two downward 0 dB crossings'); ...
              ck('pmWorst', -95.4124,'absdiff', 1.0,  'the WORST crossing, not the first'); ...
              ck('loopStable', 0,    'false',   0,    'a negative margin at any crossing is unstable') ];

    case 'T1'
        C = [ ck('nRowsIn',    40, 'absdiff', 0, 'input rows'); ...
              ck('nRowsOut',   33, 'absdiff', 0, '40 - 3 NaN - 2 dup - 2 outlier = 33'); ...
              ck('nMissing',   3,  'absdiff', 0, 'NaNs counted, not silently dropped'); ...
              ck('nDuplicate', 2,  'absdiff', 0, 'duplicates counted'); ...
              ck('nOutlier',   2,  'absdiff', 0, 'outliers counted') ];

    case 'S1'
        % Tolerances are set by COUNTING NOISE, not by taste. At 0 dB the BER is
        % ~0.079, so 256000 bits give ~20000 errors and the Poisson relative spread
        % is ~0.7 %; at 8 dB the BER is ~1.9e-4, which is only ~49 errors over the
        % same run, so the spread is ~1/sqrt(49) ~ 14 %. A 15 % pass mark at 8 dB is
        % therefore below the measurement noise floor: it rejects correct code
        % roughly half the time. The 8 dB tolerance is widened to 45 % (about 3
        % sigma) and this is stated rather than silently loosened -- mas_refcheck
        % marks S1 with spreadFactor 0.5 for the same reason.
        C = [ ck('ber0', 0.0786496, 'reldiff', 0.20, 'QPSK at 0 dB: 0.5*erfc(1), ~20k errors so noise is 0.7 %'); ...
              ck('ber4', 0.0125008, 'reldiff', 0.20, 'QPSK at 4 dB, ~3200 errors so noise is 1.8 %'); ...
              ck('ber8', 0.0001909, 'reldiff', 0.45, 'QPSK at 8 dB: only ~49 errors, noise is 14 % -- 45 % is ~3 sigma') ];

    case 'R1'
        C = [ ck('q1deg', 35, 'absdiff', 1e-6, 'IK must return the joint angles that generated the pose'); ...
              ck('q2deg', 50, 'absdiff', 1e-6, 'same for the second joint'); ...
              ck('fkErr',  0,  'absdiff', 1e-9, 'FK(IK(pose)) must reproduce the pose') ];

    case 'G1'
        C = [ ck('y', 192.5, 'absdiff', 0, 'generated code must reproduce MATLAB exactly'); ...
              ck('n', 10,    'absdiff', 0, 'loop trip count') ];

    otherwise
        C = struct('field', {}, 'ref', {}, 'op', {}, 'tol', {}, 'why', {});
end
end

% ---------------------------------------------------------------------------
function c = ck(field, ref, op, tol, why)
c = struct('field', field, 'ref', ref, 'op', op, 'tol', tol, 'why', why);
end
