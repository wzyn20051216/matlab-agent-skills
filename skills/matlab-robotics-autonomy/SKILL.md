---
name: matlab-robotics-autonomy
description: MATLAB robotics and autonomy workflow for rigid-body transforms, quaternions, forward/inverse kinematics, trajectory planning, rigid-body dynamics, ROS/ROS 2 bags, sensor fusion, state estimation, SLAM, and reproducible robot experiments. Use whenever the user asks MATLAB to verify a rotation or quaternion, compute FK/IK/Jacobians, check a trajectory against waypoints and limits, check dynamics (M/C/g, energy), or judge whether a recorded state estimate is consistent with its covariance. Missing toolbox, bag, robot model or hardware means SKIP, never a claimed result.
---

# MATLAB Robotics Autonomy

Use this skill when the deliverable is a pose, a motion, a torque, or a state estimate
that another engineer will act on. A plot of the arm or a smooth estimate trace is not
evidence: a sign error in a Jacobian drives the tip the wrong way, and a filter can be
smooth, stable and confidently wrong.

## Skill Root

The installed directory containing this `SKILL.md` is the resource root. Add its
helper folder for the current MATLAB session only — never through `savepath`,
`startup.m`, or a global path edit:

```matlab
skillRoot = '<absolute path to the installed matlab-robotics-autonomy Skill directory>';
addpath(fullfile(skillRoot, 'scripts'));
```

Resolve `references/`, `tests/`, and helper calls from that root, not from the
caller's working directory. If a shipped helper or reference is missing, report the
exact path and reinstall the Skill; do not scan the disk for a substitute.

## Workflow

1. 任务识别 — Name the frame convention, units, sign convention and the tolerance that
   makes the answer acceptable. State which independent route could contradict it
   (analytic formula, finite difference, energy, another sensor, hand algebra).
   A claim with no acceptance criterion has no PASS.
2. 能力选择 — `r = mas_route(prompt)`; confirm this skill is primary, then load only the
   matching tool contract below instead of the whole toolbox.
3. 环境检查 — `mas_precheck` before Robotics System Toolbox / Navigation / ROS / UAV
   APIs. Record what is missing. Missing toolbox, bag, URDF or hardware is **SKIP** with
   the reason, never a simulated substitute reported as the real result.
4. MATLAB 执行 — build the smallest loop first: one frame, one configuration, one
   recorded run. Save `q`, `t`, `M`, `P` and the inputs so a failing check can be
   inspected instead of guessed.
5. 独立验收 — grade with the tools below (or `mas_grade` for a manifest task). Every
   accepted number needs a second route: rotation matrix vs quaternion, analytic
   derivative vs stencil, Lagrange vs kinetic energy, NEES vs covariance.
6. 错误恢复 — a `fail`/`UNDETERMINED` is fixed for the named reason (fix the frame,
   supply the analytic derivative, extend the run, add the tolerance) and re-run. It is
   never skipped, relabelled, or averaged away.
7. 结果交付 — report value, frame, tolerance, and verdict; cite the check ids. SKIP and
   BLOCKED stay SKIP and BLOCKED.

## Verification tools

```matlab
q = mas_quat_check(q, struct('matrix',R,'angle',a,'axis',ax,'rotvec',rv, ...
        'compose',q2,'interp',struct('qEnd',q1,'t',ts)));
q.verdict  q.qUnit  q.R  q.angle  q.axis  q.slerp  q.inverseErr

F = mas_frame_check(T);                        % SE(3) hygiene, chain closure
F.verdict  F.orthErr  F.detR  F.closureErr  F.crossCheck

K = mas_kin_check(L, q);                       % FK + J vs finite difference
K.verdict  K.pos  K.J  K.jacErr  K.condJ  K.manip

I = mas_kin_ik(L, pTarget, q0, struct('maxIter',200));   % DLS IK
I.converged  I.feasible  I.limitHit  I.stepRawMax  I.maxStep

T = mas_traj_check(t, q, struct('waypoints',wp,'vMax',4,'aMax',12, ...
        'qMin',-2,'qMax',2,'vel',V,'acc',A));
T.verdict  T.waypointErr  T.vMax  T.aMax  T.certified  T.derivErrV

D = mas_dyn_check(p, q, qd, struct('M',M,'C',C,'g',g));
D.verdict  D.skewErr  D.coriolisErr  D.gravityErr  D.energyDrift

E = mas_estimate_check(truth, est, P, struct('maxBias',0.1, ...
        'innovation',nu,'S',S));
E.verdict  E.aneesMean  E.aneesBand  E.inBandFrac  E.minEigP  E.bias

% legacy Monte Carlo route (simulated truth, not recorded data)
r = mas_ekf_check(model);
```

Every tool returns `verdict` (PASS | FAIL | UNDETERMINED) and per-check status
(`pass | fail | na | undetermined`). `na` = the contract does not apply and does not drag
the verdict; `undetermined` = missing evidence or criterion and forces UNDETERMINED.
**No acceptance criterion, no PASS.**

## Boundary rules these tools encode

- A non-unit quaternion still yields a rotation (via `q/|q|`), but every derived claim
  is graded against the normalized value; the root cause is reported, not hidden.
  `q` and `-q` are the same rotation (double cover); SLERP flips the sign to take the
  shortest arc, and a bent path or an endpoint mismatch FAILS.
- A zero rotation has no axis: `[1 0 0]` and `[0 1 0]` are equally valid, so the axis
  check is UNDETERMINED, not a pass. A 180° rotation accepts either axis sign.
- Euler **sequence is data**: the same three numbers mean different orientations under
  `ZYX` and `XYZ`. `.seq` is required and echoed back; degree-valued input under
  `angleUnit='rad'` is rejected.
- The Jacobian is checked against a central difference of the FK, and the test pins the
  **outer sum** — joint j moves every link from j outward. A per-link Jacobian is the
  documented wrong answer and disagrees at ~1e-1 while the correct one agrees at ~1e-9.
- IK is DLS (`J'(JJ'+λ²I)⁻¹e`) with a per-joint step clamp; `stepRawMax` is still
  reported because suppressing it hides the bad configuration. Unreachable target →
  `feasible=false`, zero iterations. Joint-limit-only reachable → `converged=false` with
  `limitHit=true`, never the clamped pose reported as success.
- A trajectory peak is only a **sample** unless analytic `vel`/`acc` were supplied
  (`certified=false`). Non-uniform time or fewer than 5 samples makes derivative claims
  UNDETERMINED while the sampled limits are still graded. A waypoint between samples is
  interpolated linearly and its miss is measured, not excused.
- Dynamics is graded by three independent identities: `Mdot − 2C` skew, `C qd =
  Mdot qd − ∂T/∂q`, and `g = ∂V/∂q`, plus RK4 energy conservation under zero torque.
  The energy route integrates the **claimed** model when M/C/g are supplied, so a wrong
  C is caught by the leak it causes, not just by comparison to the reference.
- NEES has two correct denominators: the mean over all accepted samples (nRuns×nSteps)
  and one step's mean over runs (nRuns). Its bands differ; using one band for both is a
  false FAIL. Fewer than 20 runs or 5 steps is UNDETERMINED; covariance symmetry and
  positive definiteness are checked **before** NEES, since NEES on a non-PD P is noise.
- Innovation whiteness is a family of autocorrelation tests, so the threshold is
  family-wise: `sqrt(2)·erfcinv(α/L)/sqrt(m·N_eff)` ≈ 0.0444 for the fixture — not
  `sqrt(2)·erfcinv(α/2)`. Serial correlation makes a single-lag test a coin flip.
- Bias is a separate claim from consistency: a filter can pass NEES while biased, and a
  bias bound with no argument is UNDETERMINED.

Full formulas, worked numbers, negative controls and the SKIP matrix:
`references/robotics-verification-contract.md`.

## Frames, kinematics and IK in one paragraph each

`mas_frame_check` reports `orthErr` and `det(R)` separately: a matrix stretched 0.1 %
still has `det=1.001` while `orthErr` reads 2e-3; a reflection has `orthErr=0` and
`det=-1`. Cross-checks against `eul2rotm`/`quat2rotm` run only when the toolbox is
licensed, and absence is `crossCheck.checked=false`, never faked.

`mas_kin_check` returns the analytic J and the finite-difference J. For a planar chain
with absolute angles `theta_i = sum_{k<=i} q_k`:
`dx/dq_j = -sum_{i>=j} L_i sin(theta_i)`, `dy/dq_j = sum_{i>=j} L_i cos(theta_i)`.
`condJ` and `manip` are reported at every configuration; a near-straight arm is flagged
`s singular` rather than left for the controller to discover.

`mas_kin_ik` at `q2 = 1e-4` with a radial target: cond(J) 4.9e4, DLS raw step 0.12,
normal-equations raw step 6.4e3. `method='normal'` is kept as the negative control.

## Estimation from recorded data vs simulation

- `mas_estimate_check(truth, est, P)` is the **recorded** route: truth is a reference
  trajectory or simulator log supplied by the caller; the tool never generates it.
  It computes NEES per step and per run, the two chi-square bands, bias, covariance
  hygiene, and innovation whiteness when `innovation`/`S` are supplied.
- `mas_ekf_check(model)` is the **simulated** route: it draws truth from `Qtrue`/`Rtrue`
  and averages over runs. Use it to tune a filter design; use `mas_estimate_check` to
  judge a log. A simulated pass does not certify a recorded run.
- Deliver the number, the band, the sample count and the verdict. `halfMeans` is
  reported but not graded: with serially correlated NEES its difference is not a test.

## Environment and SKIP

Record before claiming: MATLAB release, toolbox license (`mas_precheck`), ROS/ROS 2
middleware and domain id, bag path and size, URDF/robot model and frame tree, sensor
rates, and the seed for any Monte Carlo. Then:

- No ROS Toolbox / bag / robot model / hardware → **SKIP**, with the missing item named.
- Bag too large for the session → process a deterministic sample; report the sample
  window and never call the sampled result a full-bag validation.
- Unverified timing or clock sync → state it; do not hide it inside a tolerance.

## Legacy toolbox APIs

- ROS/ROS 2: `ros2bagreader`, `rosbagreader`, message selectors.
- Robotics: `rigidBodyTree`, `inverseKinematics`, `manipulatorRRT`.
- Navigation: occupancy maps, planners, controllers, localization.
- Sensor fusion: `trackingKF`, `trackingEKF`, `trackingUKF`, `transformTree`.
- UAV: scenario, trajectory and sensor simulation APIs when installed.

Tests: `tests/test_robotics_contract.m` (162/162) and `tests/test_robotics.m` (31/31).
Every expected value is a physical property recomputed independently — hand algebra,
a second numerical route, or MATLAB's own implementation — never the tool under test.
