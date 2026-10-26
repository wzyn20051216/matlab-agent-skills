# Robotics Verification Contract

This reference explains what the `mas_*` robotics tools verify, the formula behind each
check, the measurement that grounds it, and the situation in which the tool must refuse to
answer. The dangerous failure in robotics is not a crash. It is a pose that looks right on a
plot, an arm that moves smoothly with the wrong Jacobian sign, a trajectory that is smooth
between samples and violates a limit between them, or a filter whose covariance is
confident and wrong. None of those can be graded by looking at the robot or at the code
that produced the number.

## The four-state check model

Every tool returns `r.verdict` (`PASS` | `FAIL` | `UNDETERMINED`) and `r.checks`:

| status | meaning | effect on verdict |
|---|---|---|
| `pass` | the check ran and the claim/number met the criterion | none |
| `fail` | the check ran and the claim/number is wrong | forces FAIL |
| `na` | the contract does not apply (e.g. no toolbox to cross-check) | does not drag |
| `undetermined` | evidence or criterion missing (too few runs, no analytic derivative, undefined axis) | forces UNDETERMINED |

Precedence: any `fail` -> FAIL; else any `undetermined` -> UNDETERMINED; else PASS.
`undetermined` is not a soft failure and is never relabelled PASS. Inputs that make the
question meaningless (a zero quaternion, a one-sample trajectory, an empty covariance)
throw an error instead of returning a verdict.

## 1. Quaternion algebra — `mas_quat_check`

```matlab
r = mas_quat_check(q, struct('matrix', R, 'angle', a, 'axis', ax, ...
    'rotvec', rv, 'compose', q2, 'interp', struct('qEnd', q1, 't', ts)));
```

Convention: `q = [w x y z]`, scalar first. A scalar-last quaternion is a different
convention and is not silently reordered.

- **Unit norm.** `|q| = 1` is graded at `tolNorm = 1e-8`. Every derived matrix is scaled by
  `|q|^2`; a norm-2 quaternion rotates by 4x with the right axis and the wrong angle. The
  tool derives `R`, angle and axis from the *normalised* quaternion so the rest of the
  report remains meaningful, but `unitNorm` records the input as given and fails.
- **Rotation matrix.** The closed form is compared with a claimed 3x3 matrix
  (`matrixVsClaim`), and with `quat2rotm` when Robotics System Toolbox is licensed
  (`matrixVsToolbox`). Absence gives `na`, never a fabricated pass.
- **Angle and axis.** `angle = 2*atan2(|v|, |w|)` in `[0, pi]`; `axis = sign(w)*v/|v|`.
  At `w = 0` (180 deg) the sign of the axis is a convention, so `axisVsClaim` accepts
  `+axis` and `-axis` there; away from 180 deg only the canonical sign is accepted.
  At angle 0 the axis is undefined: an axis claim is `undetermined`, not a pass.
- **Double cover.** `q` and `-q` must produce the same `R`; orientation comparisons are
  sign-insensitive. Code that compares components rejects a correct attitude.
- **Inverse.** `q (x) conj(q) = identity` for unit `q`; conjugation equals the inverse only
  when the norm is 1.
- **Composition.** `q1 (x) q2` is checked against `R(q1) R(q2)`, which shares no code with
  the quaternion product. The second quaternion's norm is a separate check: a non-unit
  `compose` is not a rotation even though the product of the normalised values is.
- **SLERP.** Shortest arc: `d = dot(q0,q1)`; if `d < 0`, flip `q1`, so the arc is `<= pi`.
  Endpoints, the geodesic angle `t*angle(q0,q1)`, and claimed samples are graded
  separately. A component-linear interpolation hits the endpoints and bends the middle:
  it fails `slerpGeodesic` and/or `slerpVsClaim`.

Grounding (probe log `artifacts/phase53/task3_probe.txt`):

| case | result | measured |
|---|---|---|
| full claim set on a 0.6 rad z-rotation | PASS 15/15 | `matrixVsClaim` 1.11e-16, `composeVsMatrix` 0, geodesic deviation 9.44e-16 |
| `q` of norm 2 | FAIL 4/5 | `unitNorm` fails; `R` still equals the 0.6 rad rotation because it uses `q/|q|` |
| wrong `R` (0.7 rad) | FAIL 5/6 | `max|R-Rclaim| = 7.96e-2` |
| wrong angle, axis and rotvec | FAIL 5/8 | angle 0.1, axis 1.414, rotvec 0.1 |
| bent SLERP sample | FAIL 7/8 | `slerpVsClaim = 1.35e-1` with endpoints exact |
| identity with an axis claim | UNDETERMINED 5/6 | axis undefined |
| `-q` | PASS 5/5 | same `R` |
| 180 deg about `-x` | PASS 8/8 | axis sign accepted at `w = 0` |
| non-unit compose | FAIL 7/8 | `composeUnitNorm` fails; normalised product still matches the matrix route |

Refuses to answer: `q` not length 4, non-finite `q`, zero quaternion, zero compose
quaternion, `interp.t` outside `[0,1]`.

## 2. Frames and SE(3) — `mas_frame_check`

`orthErr = max|R'R - I|` and `det(R)` are reported separately because they catch different
defects. A matrix stretched by 0.1 % along one column has `det = 1.001` and `orthErr` around
2e-3; a reflection has `orthErr = 0` and `det = -1`. Euler **sequence** is part of the data
(`ZYX` and `XYZ` give different rotations from the same three numbers), so `seq` is required.
Quaternion input is warned when the norm is not 1. A chain of SE(3) matrices is checked for
closure; one mis-specified link produces a closure error and fails. Cross-checks against
`eul2rotm` / `quat2rotm` run only when licensed, with the deviation reported (measured 0 and
1.1e-16 on this machine).

## 3. Forward kinematics and Jacobian — `mas_kin_check`

For a planar chain with absolute link angles `theta_i = sum_{k<=i} q_k`:

    dx/dq_j = -sum_{i>=j} L_i sin(theta_i)     dy/dq_j = sum_{i>=j} L_i cos(theta_i)

The OUTER sum is the part that gets dropped: joint `j` moves every link from `j` outward.
The analytic Jacobian is compared element-wise with a central difference of the forward
kinematics. The test also builds the naive per-link Jacobian inline and asserts that the
returned `J` disagrees with it while agreeing with the finite difference, so the metric
cannot pass vacuously. Fully extended configurations (`q = 0`) are detected as singular
through the condition number; the reach bound is checked over thousands of random poses.
Joint/link count mismatches and non-positive link lengths throw.

## 4. Inverse kinematics — `mas_kin_ik`

Damped least squares:

    dq = J' (J J' + lambda^2 I)^{-1} e

The update is clamped to `stepLimit` rad per joint because `J` is a first-order model and a
large Cartesian error produces a step outside the region where it holds. Both the applied
step (`maxStep`) and the requested raw step (`stepRawMax`) are returned: suppressing the
unbounded value hides the evidence that the configuration is bad.

Measured at a near-singular configuration (`q2 = 1e-4`, arm almost straight) with a target
demanding radial motion:

| q2 | cond(J) | DLS raw step | normal-equations raw step |
|---|---|---|---|
| 0.01 | 4.9e2 | 3.74 | 64.4 |
| 1e-3 | 4.9e3 | 0.41 | 641 |
| 1e-4 | 4.9e4 | 0.12 | 6.4e3 |
| 1e-6 | 4.9e6 | 0.12 | 1.4e5 |

A target outside the reachable annulus returns `feasible = false` and zero iterations. A
target reachable only by violating the joint limits returns `converged = false` with
`limitHit = true`; it does not return the clamped pose as a success.

## 5. Trajectory contract — `mas_traj_check`

```matlab
r = mas_traj_check(t, q, struct('waypoints', wp, 'vel', v, 'acc', a, ...
    'vMax', 1.0, 'aMax', 2.0, 'qMin', -pi, 'qMax', pi));
```

Four independent defects are reported separately:

1. **Time base.** `t` must be strictly increasing. A repeated timestamp means the
   trajectory runs backwards; the tool returns immediately with `timeMonotonic = fail` and
   leaves the peaks unset (`NaN`).
2. **Waypoints.** `q(t_wp)` is linearly interpolated and compared with the required `q`.
   A waypoint outside the recorded time range is a failure with its index, not an ignored
   row.
3. **Derivative claims.** With analytic `.vel`/`.acc`, the limits are **certified**. They
   are also compared with a 5-point interior stencil:
   `v_i = (q_{i-2} - 8q_{i-1} + 8q_{i+1} - q_{i+2}) / (12h)`, and the analogous
   `O(h^4)` acceleration stencil. The first and last samples are excluded because a
   one-sided difference there is only first order: at 100 Hz the boundary discrepancy for a
   correct sinusoid is `(h/2) f'' = 0.0493`, which would condemn a correct claim. Measured
   on the correct trajectory: velocity 3.25e-8, acceleration 1.08e-8.
4. **Limits.** `vMax`, `aMax`, `jMax`, `qMin`, `qMax` are checked on the best evidence
   available. Without analytic derivatives the peak comes from `gradient` on the samples
   and `certified = false`: a peak between samples is not ruled out. A sampled-only PASS
   never claims a continuous-time bound. `jMax` always has no analytic route and is
   labelled sampled.

Non-uniform spacing or fewer than five samples leaves the derivative-agreement check
`undetermined` (there is no equally sharp independent route), which forces UNDETERMINED
rather than a relaxed tolerance.

Grounding: certified trajectory 8/8; `vMax` 3.142, `aMax` 9.87; `vMax=2` fails; a 0.1 rad
waypoint miss is caught (and also produces derivative spikes 2.12 and 253 because a
one-sample step is not a smooth trajectory); `dt=0` caught at sample 30; claimed velocity
doubled gives relative deviation 0.5; sampled-only limits pass with `certified=0`; a lower
joint limit of 0.5 fails; non-uniform and 4-sample records are UNDETERMINED.

## 6. Rigid-body dynamics — `mas_dyn_check`

Planar 2-link arm, absolute joint angles, COM at `lc`, inertia about the COM:

    M11 = I1 + I2 + m1 lc1^2 + m2 (l1^2 + lc2^2 + 2 l1 lc2 cos q2)
    M12 = I2 + m2 (lc2^2 + l1 lc2 cos q2)
    M22 = I2 + m2 lc2^2
    h   = m2 l1 lc2 sin q2
    C   = [-h qd2, -h (qd1+qd2); h qd1, 0]
    g   = [(m1 lc1 + m2 l1) g cos q1 + m2 lc2 g cos(q1+q2);
            m2 lc2 g cos(q1+q2)]
    V   = (m1 lc1 + m2 l1) g sin q1 + m2 lc2 g sin(q1+q2)

The closed form is not accepted on faith. Three properties make a dynamics model usable,
and each has an independent route:

1. **`M` symmetric and positive definite.** A non-symmetric `M` cannot come from a scalar
   kinetic energy; a non-PD `M` means some velocity direction has negative kinetic energy.
   The tool also rebuilds `M` from link kinetic energies using forward-kinematics COM
   velocities (`massVsEnergyRoute`). For the reference case the closed form and the energy
   route agree to 5.55e-17.
2. **`Mdot - 2C` skew-symmetric.** This is passivity: with zero torque the system cannot
   create energy. `C*qd` is also checked against `Mdot*qd - dT/dq`, the Lagrange identity,
   with `Mdot` from a central difference. Measured: skew 4.08e-11, identity 7.06e-12
   (limited by the finite-difference `Mdot`, not by the formula).
3. **`g = dV/dq`.** Gravity is compared with a central difference of the potential
   (2.42e-11), and with the closed form when `g` is claimed.

The end-to-end check is **energy conservation**: RK4 integrates the graded model with zero
torque for 2 s at 1 ms steps, evaluating `M`, `C`, `g` at every stage (not frozen at
`q0`). The reference case drifts 6.46e-12 relative to `E0 = 2.22584`.

Point claims (`M`, `C`, `g` at one `(q,qd)`) cannot define the model elsewhere, so they
cannot be used for the energy integration. Supply `claims.model = @(q,qd) [M,C,g]` to
integrate the claimed model; `r.energySource` says which was used. The negative control: a
model with the sign of `C` flipped passes every point check yet loses energy from 2.22584
to 1.50582 (drift 0.3235) and FAILS.

Reference numbers at `q = [0.4;-0.7]`, `qd = [0.3;-0.2]`, `m = [1.2 0.8]`,
`l = [0.5 0.4]`, uniform rods: `M = [0.465041 0.103854; 0.103854 0.042667]`,
`C = [-0.010307 0.005154; -0.015461 0]`, `g = [7.824422; 1.499496]`, eigenvalues
`[0.01851 0.48920]`.

Defect grounding: `M` off-diagonal +0.1 makes the matrix non-PD (eigenvalues -0.0397,
0.5474) and fails both mass routes; flipped `C` gives skew 8.25e-2 and Lagrange identity
1.24e-2; flipped `g` gives 2.036; a 1e-3 asymmetry fails symmetry; `[1 2;2 1]` fails PD with
eigenvalues -1 and 3; exact claims pass 10/10.

Refuses: missing `m1/m2/l1/l2`, non-positive lengths/masses, COM beyond its link, negative
inertia, non-2x2 claims, a `model` that is not a function handle.

## 7. Recorded state estimation — `mas_estimate_check`

```matlab
r = mas_estimate_check(truth, est, P, struct('maxBias', 0.1, ...
    'innovation', nu, 'S', S, 'alpha', 0.01, 'minRuns', 20));
```

`truth` and `est` are `N x n` (one run) or `N x n x R` (independent runs). `P` is
`n x n`, `n x n x N`, or `n x n x N x R`.

**NEES.** `eps_k = e_k' P_k^{-1} e_k`, averaged over runs at each step. A consistent filter
has `E[eps] = n`. The tool reports two chi-square bands because they answer different
questions:

- mean over all accepted samples: `N*R*mean(ANEES) ~ chi2(n*R*N)`, band on the mean;
- one step's mean over runs: `R*ANEES_k ~ chi2(n*R)`, a wider band, used for per-step
  coverage.

Both are two-sided. ANEES far below `n` is not "better": the filter is under-confident and
discarding information. Coverage requires at least 90 % of steps inside the per-step band,
in addition to the mean being inside the mean band.

**Gates.** Fewer than 20 runs (`minRuns`) makes the band too wide to reject a bad filter:
NEES is reported but `undetermined`. Fewer than 5 accepted steps is also `undetermined`.
Both are deliberate; a 5-run record cannot prove consistency.

**Covariance hygiene runs first.** Symmetry and positive definiteness are checked over every
step and run. A negative eigenvalue makes `P\e` meaningless even when the resulting ANEES
happens to look plausible. Non-finite inputs produce a FAIL, not a crash.

**Bias** is graded only when `maxBias` is claimed: `||mean(truth-est)||` over the accepted
samples. A constant offset can leave ANEES almost unchanged if `P` is inflated; the bias
claim is a separate engineering requirement.

**Innovation whiteness.** With `innovation` and `S`, normalised innovations `z = L\nu` are
formed from `S = L L'` and their autocorrelation is measured over lags 1..10. Because the
metric is the **maximum** over 10 lags, the threshold is family-wise:
`sqrt(2)*erfcinv(alpha/L) / sqrt(m*N_eff)`, not a per-lag 95 % bound (which rejects white
noise roughly 40 % of the time). `N_eff = R*(N_steps - max(lag))`. Correlated innovations
mean the filter is not using information it has, even when the marginal covariance is right.

Grounding (100 runs x 50 steps, n = 2, alpha = 0.01):

| case | ANEES | result |
|---|---|---|
| consistent filter | 2.037, band 1.928..2.074, step band 1.522..2.553, 100 % in band | PASS 4/4 |
| `P/100` | 203.662 | FAIL: over-confident |
| `P*100` | 0.020 | FAIL: under-confident |
| one non-PD `P` page | NEES still 2.036 | FAIL: min eigenvalue -1 |
| one asymmetric `P` page | NEES still 2.037 | FAIL: symmetry error 1e-2 |
| `est+0.5` with `maxBias=0.1` | 6.144, bias 0.699 | FAIL: NEES and bias |
| 5 runs | 2.036 | UNDETERMINED (run gate) |
| burn-in 46 of 50 | — | UNDETERMINED (4 steps) |
| AR(1) innovations | — | FAIL: max autocorrelation 2.155 vs 0.0444 |
| white innovations | — | PASS: 0.0269 vs 0.0444 |

`r.bias`, `r.biasNorm`, `r.halfMeans` and the per-step series are reported even when the
verdict is UNDETERMINED. Half means are **not graded** because the same runs are reused at
every step, so per-step NEES values are serially correlated and a chi-square band on half
means would falsely reject a correct filter.

Refuses: non-PD or asymmetric `P` is reported and fails; a non-PD `S` makes whiteness
`undetermined`; `innovation` without `S` is `undetermined`; missing `P` is an error;
`burnIn` outside `[0,N)` is an error; `est`/`truth` size mismatch is an error.

## 8. Sensor-fusion workflow

Record, for each independent run: the truth state, the estimate, the covariance at every
step, and (when available) the innovation and its predicted covariance `S`. Twenty runs is
the minimum that gives a band capable of rejecting a bad filter; 100 runs is cheap for a
2-state model and makes the mean band tight. Do not reuse one run at several steps as if it
were several runs. A single sequence can be plotted; it cannot establish consistency.

A consistent NEES does not prove the filter is useful: an under-confident filter can be
consistent and sluggish. Check the bias against an engineering bound and the innovations for
whiteness; report all three. `mas_ekf_check` remains the generator for synthetic
Monte-Carlo filter studies; `mas_estimate_check` grades a *recorded* filter, including one
produced by a toolbox or on hardware.

## 9. Boundaries and SKIP

- No ROS bag, no ROS 2 runtime, no robot/hardware -> the corresponding capability is SKIP,
  never PASS. `ros_bag_processing`, `path_planning_and_slam` and `uav_scenario_simulation`
  remain NOT TESTED in the capability matrix for exactly this reason.
- Robotics System Toolbox absent -> toolbox cross-checks are `na`; the independent core
  checks still run. Absence is never converted to a pass or to a failure.
- The dynamics tool covers a planar 2-link arm. A URDF/`rigidBodyTree` model is not graded
  by it; use the tool only after reducing the model, or report the claim as unverified.
- The trajectory tool certifies a continuous-time limit only when analytic derivatives are
  supplied. A sampled peak is a sampled peak.
- Quaternions are scalar-first and angles are radians. A degree-valued input that looks
  plausible is an error in `mas_frame_check`; `mas_quat_check` cannot detect it from the
  quaternion alone.
- All expected values in the tests are recomputed by an independent route: kinetic energy,
  potential gradient, hand rotation matrices, a 5-point stencil, or chi-square quantiles.
  A tool's own output is never its reference.

## 10. Test inventory

- `tests/test_robotics_contract.m` — 162/162 cases covering the four contract tools, with
  positive and negative cases and every run/step gate.
- `tests/test_robotics.m` — 31/31 cases for the Phase 5.2 kinematics, IK, EKF and frame
  tools, including a negative control for each metric.
- Evidence: `artifacts/phase53/task3_probe.txt` (grounded probe) and
  `artifacts/phase53/task3_contract.txt` (suite output).
