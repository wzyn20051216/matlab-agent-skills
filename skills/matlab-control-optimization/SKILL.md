---
name: matlab-control-optimization
description: MATLAB workflow for control systems, system identification, robust control, MPC, Simulink Control Design, parameter tuning, constrained optimization, and numerical validation. Use whenever the user asks for controllers, transfer functions, state-space models, tuning, identification, optimal control, or solver-based engineering.
---

# MATLAB Control Optimization

Use this skill for control design and optimization workflows.

## Skill Root

The installed directory containing this `SKILL.md` is the resource root. Add its
helper folder for the current MATLAB session only — never through `savepath`,
`startup.m`, or a global path edit:

```matlab
skillRoot = '<absolute path to the installed matlab-control-optimization Skill directory>';
addpath(fullfile(skillRoot, 'scripts'));
```

Resolve `references/`, `tests/`, and helper calls from that root, not from the
caller's working directory. If a shipped helper or reference is missing, report the
exact path and reinstall the Skill; do not scan the disk for a substitute.

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

## Stability Is Three Answers, Not One

Use `mas_stability_verdict` before reporting any stability conclusion:

```matlab
r = mas_ctrl_analyze(L);                 % every crossing, poles, notes
v = mas_stability_verdict(L);            % or mas_stability_verdict(r)
v.math.stability                         % STABLE | UNSTABLE | UNDETERMINED
v.target.status                          % PASS | FAIL | UNDETERMINED
v.evidence.quality                       % VERIFIED | PARTIAL | NOT VERIFIED
v.notes                                  % why a value is NaN / undetermined
r = mas_ctrl_pid_design(P, struct('pmTarget',50,'gmTarget',6));
r = mas_ctrl_aw_sim(P, cfg, opts);       % saturation + 'none'|'clamp'|'backcalc'
```

Never turn "MATLAB ran", "poles are stable", "PM passed", or "the curve looks
smooth" into one of the other answers. A missing margin is `UNDETERMINED`, not
`PASS`. When the closed-loop poles and the frequency margins disagree, the verdict
is `UNDETERMINED` with an `EVIDENCE_CONFLICT` note.

Boundary rules this tool encodes (each one a paid-for defect):

- `margin()` returns `Gm` as an **absolute ratio**, not dB; `allmargin` also
  reports a ratio. `c2d(10/(s+1),0.01)` has ratio 20.0002 = **26.02 dB**.
- Phase is unwrapped and PM is wrapped into `(-180,180]`. Without the wrap a
  negative-gain loop reports `+275.7 deg` instead of `-84.26 deg`.
- DC unity gain has its PM **at DC** (`1/(s+1)` -> 180 deg), not NaN.
- Phase = -180 at DC with `|L|>1` is a negative GM at `w=0`; `-10/(s+1)` is
  UNSTABLE although its 0 dB crossing looks healthy.
- Discrete loops reach -180 at `pi/Ts`; that Nyquist boundary must be checked.
- Multiple crossings: the worst one binds, never the first.
- Delay: rational closed-loop poles exclude the delay, so evidence is `PARTIAL`.

Units are explicit: every crossing carries `f` (Hz) and `wRadPerSec` (rad/s), and
`opts.freqUnit` selects how `wmin/wmax` are interpreted. Verify `w = 2*pi*f`.

Full definitions, boundary table, and independent reference values:
`references/stability-contracts.md`.

`tests/test_ctrl_analyze.m` covers the known-stable loop, known-unstable plant,
multi-crossing loop, discrete and delayed loops, PID design and anti-windup.
`tests/test_stability_contract.m` covers the negative-gain encirclement, DC unity,
double integrator, discrete Nyquist margin, no-crossing target, target-not-met,
Hz/rad-s equivalence, NaN/Inf/empty inputs, and `margin` return-order units.
