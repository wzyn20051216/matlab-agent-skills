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
