---
name: matlab-control-optimization
description: MATLAB R2026a workflow for control systems, system identification, robust control, MPC, Simulink Control Design, parameter tuning, constrained optimization, and numerical validation. Use whenever the user asks for controllers, transfer functions, state-space models, tuning, identification, optimal control, or solver-based engineering.
---

# MATLAB Control Optimization

Use this skill for control design and optimization workflows.

## Workflow

1. Define plant model, units, sample time, constraints, and performance goals.
2. Confirm required products: Control System Toolbox, System Identification Toolbox, Optimization Toolbox, Robust Control Toolbox, or MPC Toolbox.
3. Build an executable baseline model.
4. Tune or optimize with explicit objective and constraints.
5. Validate time-domain, frequency-domain, and robustness behavior when applicable.
6. Save plots, tuned parameters, and numerical metrics.

## Preferred APIs

- `tf`, `ss`, `zpk`, `c2d`, `d2c`
- `step`, `lsim`, `bode`, `margin`, `bandwidth`
- `pidtune`, `systune`, `hinfsyn`, `musyn` when licensed
- `iddata`, `tfest`, `ssest`, `compare`
- `optimproblem`, `fmincon`, `lsqnonlin`, `ga`, `particleswarm`

## Validation Metrics

Use checks such as:

- Rise time, settling time, overshoot.
- Gain margin, phase margin, bandwidth.
- Constraint violation count.
- Objective value and solver exit flag.
- Identification fit percentage on held-out data.

## Risk Checklist

Watch for:

- Continuous/discrete sample-time mismatch.
- Unscaled optimization variables.
- Local minima and solver sensitivity.
- Hidden actuator saturation.
- Controller instability outside nominal operating points.

## Margins Belong To Crossings, Not To Loops

```matlab
r = mas_ctrl_analyze(L);            % L = tf/ss/zpk; r.crossings has EVERY crossing
r.pmWorst, r.gmWorst, r.verdict     % worst over all of them, and a verdict
r = mas_ctrl_pid_design(P, struct('pmTarget',50,'gmTarget',6));
r = mas_ctrl_aw_sim(P, cfg, opts);  % saturation + 'none'|'clamp'|'backcalc'
```

`margin(L)` returns one number. A loop with a resonance crosses 0 dB twice, and the
first crossing can read +83 deg while the second reads -95 deg -- measured, see the
C3 case. A margin report that keeps the first crossing calls that loop healthy and
the closed loop oscillates. `mas_ctrl_analyze` reports every crossing, takes the
worst, and returns `UNSTABLE` when a crossing has a negative margin even if all poles
are in the LHP.

Other facts this tool encodes, each one a defect that was actually paid for:

- Phase must be **unwrapped** before interpolation. A loop with an integrator runs
  past -180 deg and `angle()` folds it back, turning the worst margin into the best.
- A **delay** leaves |L| untouched but adds -180 crossings, so a first-order loop
  with Inf gain margin can have a finite one. Measured: 10.1 dB at 5.1 Hz.
- **Anti-windup back-calculation must divide the deficit by Ki**: the integrator holds
  I = integral(e) and u = Kp*e + Ki*I. Without the 1/Ki the correction gain scales
  with Ki and the loop diverged to 1e300 in the first test.
- A **PID design that cannot meet the target** returns `feasible=false` and says so;
  it never returns the least-bad candidate as if it had succeeded.

`tests/test_ctrl_analyze.m` covers a known-stable loop, a known-unstable plant, the
multi-crossing loop, a discrete loop, a delayed loop, PID design (feasible and
impossible) and anti-windup.
