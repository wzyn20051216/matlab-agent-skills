# Excitation Checks: Did the Disturbance Reach the Plant?

A simulation can look right for the wrong reason. Phase 3B.2 changed a load
parameter, saw the output move, and accepted the run; the parameter had only
reached a controller gain, not the plant. The opposite also happens: a
correctly applied disturbance produces no output change because the output is
insensitive by construction, and a curve-only check calls that a failure.

`mas_dist_enter` walks the chain in five separate steps and reports each one.

```matlab
r = mas_dist_enter(cfg);
r.verdict              % PASS | FAIL | UNDETERMINED
r.evidenceQuality      % VERIFIED | PARTIAL | NOT VERIFIED
r.reasons              % PARAM_NOT_ENTERED_PLANT, OUTPUT_UNCHANGED, ...
r.before / r.after     % requested and observed parameter values, levels, states
r.effectiveTime        % when the change actually took effect
```

## The chain

| Step | Evidence | Missing evidence means |
|---|---|---|
| requested change | `cfg.base` vs `cfg.perturbed` | nothing to verify |
| plant receipt | `plantParams`, `paramLog`, `disturbanceLog`, `x0` | UNDETERMINED |
| effect | output delta, or internal state delta when insensitive | FAIL / UNDETERMINED |
| timing | log change time, else first response divergence | UNDETERMINED |
| independent prediction | `cfg.expect.delta` from an independent calculation | PARTIAL |

A changed field that is absent from an existing `plantParams` is a FAIL: the
plant reported what it consumes, and it does not consume that field. A missing
`plantParams` is UNDETERMINED: there is no evidence either way.

## Configuration

```matlab
cfg.name       = 'load step';
cfg.base       = struct('R', 1);
cfg.perturbed  = struct('R', 2);
cfg.tInject    = 0.5;
cfg.simFcn     = @(p) run_case(p);   % returns t, y, x, plantParams, ...
cfg.expect     = struct('direction','increase', 'delta',1.0, 'tol',0.02, ...
                        'insensitive',false, 'minRel',1e-8, ...
                        'timeTol',0.02, 'maxResponseDelay',0.2, 'window',0.1);
```

`simFcn` must return:

- `t`, `y` — required, same length.
- `x` — internal states; required when `expect.insensitive` is true.
- `plantParams` — the parameter values the plant actually used at the end.
- `paramLog` — optional `struct('t', t, 'R', rTrace, ...)`.
- `disturbanceLog` — optional `struct('t', t, 'value', uTrace)` recorded at the
  plant input, after every gain and switch between the source and the plant.
- `x0` or `initialState` — optional struct of actual initial states.

Changed fields are parameters by default. Declare exceptions explicitly:

```matlab
cfg.inputFields = {'u0'};    % checked against disturbanceLog
cfg.stateFields = {'x0'};    % checked against x0/initialState
```

`disturbanceLog` must record the signal that reaches the plant, not an enable
flag. A flag that steps from 0 to 1 while a gain is zero proves nothing.

## Timing

A log-based change must occur at `tInject` within `timeTol`. When only the
response is available, the first divergence is allowed to lag by
`maxResponseDelay`; this is a response time, not an injection time, and the
report says so (`r.effectiveTimeSource = 'response'`). A change before
`tInject` is always a timing failure.

## Insensitive outputs

When `expect.insensitive` is true, output change is not required and is not
evidence. The verifier requires a change in `x`:

- state changed -> PASS for internal evidence;
- states present but unchanged -> FAIL `INTERNAL_EVIDENCE`;
- no state trace -> UNDETERMINED, never PASS.

This is the case that a curve-only acceptance rule gets wrong in both
directions. If the output is theoretically insensitive, inspect states,
parameters, or derivatives; do not infer propagation from the output.

## Independent prediction

`expect.delta` must come from a closed-form solution, a separately implemented
reference, or another tool — not from the same simulation being checked. The
measured value is the mean over the final `window` fraction of samples. Make
the window match the prediction: for a final-value prediction at `t = 1.5`,
use one sample (`window = 1/numel(t)`).

If no prediction is supplied, the run can still PASS but evidence quality is
PARTIAL. A PASS is never upgraded to VERIFIED without all four: plant receipt,
timing, effect, and prediction.

## Simulink instrumentation recipe

1. Read the parameter in the plant subsystem from a workspace variable, and log
   the value the plant used (`plantParams`) after the run.
2. Insert a `To Workspace` block on the plant input, after all gains and
   switches; save it as a timeseries for `disturbanceLog`.
3. Log the internal state that should move when the output is insensitive.
4. Set the Step block's `Time` from the same `tInject` used by the verifier.
5. Run base and perturbed cases with `sim`, and pass both result structs'
   evidence to `simFcn`.
6. Keep `mas_model_check` for L0-L3; `mas_dist_enter` answers a different
   question and does not replace it.

## What the test suite pins

`tests/test_dist_enter.m` runs 19 cases: 15 model-free cases and four real
`.slx` variants (proper, zero amplitude, controller-only, late step).

The model-free set covers a correct run, a disconnected disturbance, a
controller-only update, a late step, an insensitive output with a changing
state, an insensitive output with no change, wrong amplitude, wrong direction,
missing plant evidence, a simulation error, no prediction, an input-amplitude
change (`inputFields`), an initial-state change (`stateFields`), and missing
input/state evidence. The last four exist because a disturbance is not always a
parameter: a changed input amplitude or initial state must also be traced to the
plant, and a missing log for either is UNDETERMINED rather than PASS.

A verifier that only looks at the output passes B, C, and D. A verifier that
only looks at parameters fails E. Both are required.
