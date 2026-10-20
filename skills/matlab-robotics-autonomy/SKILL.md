---
name: matlab-robotics-autonomy
description: MATLAB robotics and autonomy workflow for ROS Toolbox, Robotics System Toolbox, Navigation Toolbox, UAV Toolbox, sensor fusion, trajectory planning, simulation, and reproducible robot experiments. Use for ROS/ROS 2 bags, robot models, path planning, SLAM, state estimation, and autonomy prototyping.
---

# MATLAB Robotics Autonomy

Use this skill for robotics, autonomy, and ROS workflows.

## Workflow

1. Confirm environment: ROS or ROS 2, bag files, robot model, coordinate frames, sensors, and MATLAB toolboxes.
2. Load data or simulator deterministically.
3. Validate frames, units, timestamps, and message types before algorithms.
4. Build the smallest loop first: read data, process one frame, save one metric.
5. Scale to full trajectory, bag, or simulation only after the small loop passes.

## Preferred APIs

- ROS: `ros2bagreader`, `rosbagreader`, message readers, publishers, subscribers.
- Robotics: `rigidBodyTree`, `inverseKinematics`, `manipulatorRRT`.
- Navigation: occupancy maps, planners, controllers, localization.
- Sensor fusion: Kalman filters, tracking filters, coordinate transforms.
- UAV: scenario, trajectory, and sensor simulation APIs when installed.

## Acceptance Checks

Use at least one:

- Bag metadata and topic count parsed correctly.
- Frame transform chain is valid.
- Path has finite waypoints and no obvious obstacle collision.
- State estimator output has finite covariance.
- Trajectory tracking error is within tolerance.
- Figures or videos are exported with reproducible scripts.

## Risk Checklist

Watch for:

- ENU/NED/body/world frame mixups.
- Degrees vs radians.
- Timestamp drift.
- Sensor rate mismatch.
- ROS domain ID or middleware mismatch.
- Large bag files that need sampled processing.

## Tools

```matlab
r = mas_kin_check(L, q);                    % FK + Jacobian vs finite difference
r = mas_kin_ik(L, pTarget, q0, opts);       % DLS IK, joint limits, step diagnostics
r = mas_ekf_check(model);                   % NEES / NIS consistency, Monte Carlo
r = mas_frame_check(T);                     % SE(3)/SO(3) hygiene, chain closure
```

### Check the Jacobian against something that is not the Jacobian

`mas_kin_check` returns the analytic Jacobian **and** a central-difference Jacobian
computed by differentiating the forward kinematics, then reports the disagreement.
Every consumer of J -- resolved-rate control, IK, singularity maps, the
manipulability ellipsoid, force/torque mapping -- is built on it, and a sign error
or a dropped outer sum does not throw and does not look wrong on a plot of the arm;
it produces a controller that drives the tip the wrong way.

The analytic form: for a planar chain with absolute link angles
`theta_i = sum_{k<=i} q_k`,

    dx/dq_j = -sum_{i>=j} L_i sin(theta_i)     dy/dq_j = sum_{i>=j} L_i cos(theta_i)

The OUTER sum is the part that gets dropped: joint j moves every link from j
outward. The test pins this by building the naive per-link Jacobian inline and
asserting that the returned J disagrees with it while agreeing with the finite
difference to ~1e-9.

### IK: bounded steps, and the unbounded value still reported

`mas_kin_ik` solves `dq = J'(JJ' + lambda^2 I)^{-1} e`. The update is then
clamped to `stepLimit` rad per joint, because J is a first-order model and a large
Cartesian error produces a step that overshoots the region where that model holds.

Measured at a near-singular configuration (q2 = 1e-4, arm almost straight) with a
target demanding radial motion:

| q2     | cond(J) | DLS raw step | normal-equations raw step |
|--------|---------|--------------|---------------------------|
| 0.01   | 4.9e2   | 3.74         | 64.4                      |
| 1e-3   | 4.9e3   | 0.41         | 641                       |
| 1e-4   | 4.9e4   | 0.12         | 6.4e3                     |
| 1e-6   | 4.9e6   | 0.12         | 1.4e5                     |

DLS stays bounded; `(J'J)\J'e` grows like 1/q2. `method='normal'` is kept
deliberately as that negative control, and both `maxStep` (applied) and
`stepRawMax` (requested) are returned, because suppressing the unbounded value
would hide the information that tells you the configuration is bad.

A target outside the reachable annulus returns `feasible=false` and runs zero
iterations. A target reachable only by violating the joint limits returns
`converged=false` with `limitHit=true` -- it does not return the clamped pose as
if it had succeeded.

### Is the filter's uncertainty honest?

A filter can be stable, smooth, and confidently wrong. `mas_ekf_check` answers the
one question that the estimate plot cannot:

    eps_k = (x_k - xhat_k)' P_k^{-1} (x_k - xhat_k)          E[eps] = n

It draws ground truth from `Qtrue`/`Rtrue` and gives the filter `Q`/`R`, averages
NEES over `nRuns` independent runs, and applies the two-sided band from
`N*ANEES ~ chi2(N*n)`.

Measured (2-state constant-velocity model, 120 runs x 60 steps, band 1.66..2.38):

| case                        | ANEES  | verdict |
|-----------------------------|--------|---------|
| correctly tuned             | 1.92   | PASS    |
| R_filter = R_true/100       | 107    | FAIL    |
| Q_filter = Q_true/100       | 51     | FAIL    |
| R_filter = R_true*100       | 0.81   | FAIL    |

The band is two-sided on purpose: "close to n" is not the same as "consistent", and a
filter tuned by inflating R is pessimistic, not correct. The verdict also checks the
fraction of time steps inside the band, since a filter can have the right mean while
being inconsistent during transients.

### Frames: the two checks that catch convention errors

`mas_frame_check` reports `orthErr = max|R'R - I|` and `det(R)` separately, because
they catch different defects. A matrix stretched 0.1 % along one column still has
`det(R) = 1.001` -- det alone calls it a rotation -- while `orthErr` reads 2.0e-3.
Conversely a reflection has `orthErr = 0` and `det(R) = -1`.

Euler **sequence is part of the data**: the same three numbers mean different
orientations under `ZYX` and `XYZ`, so `.seq` is required and never defaulted, and
the sequence used is reported back. Where Robotics System Toolbox is licensed the
result is cross-checked against `eul2rotm` / `quat2rotm` and the deviation reported
(measured: 0 and 1.1e-16). Absence is reported as `crossCheck.checked = false`,
never faked. `angleUnit='rad'` rejects input whose magnitude exceeds 2*pi, which is
what degree-valued data looks like.

`tests/test_robotics.m` — cases are graded against an independent value, with a
negative control for every metric that could pass vacuously.
