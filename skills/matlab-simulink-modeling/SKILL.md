---
name: matlab-simulink-modeling
description: "MATLAB and Simulink workflow for creating, inspecting, modifying, simulating, validating, and exporting .slx models. Use for Simulink, Stateflow, Simscape, model-based design, parameter sweeps, signal logging, requirements, and simulation automation. On this machine, Simulink tasks should be visual-first: open the model in a visible Simulink window before doing substantial automated modeling or simulation so the user can watch the process."
---

# MATLAB Simulink Modeling

Use this skill for model-based design and simulation workflows.

## Skill Root

The installed directory containing this `SKILL.md` is the resource root. Add its
helper folder for the current MATLAB session only — never through `savepath`,
`startup.m`, or a global path edit:

```matlab
skillRoot = '<absolute path to the installed matlab-simulink-modeling Skill directory>';
addpath(fullfile(skillRoot, 'scripts'));
```

Resolve `references/`, `tests/`, and helper calls from that root, not from the
caller's working directory. If a shipped helper or reference is missing, report the
exact path and reinstall the Skill; do not scan the disk for a substitute.

## First Checks

1. Confirm the product with the precheck, not by guessing a license string:

   ```matlab
   r = mas_precheck('toolbox', 'Simulink Coder');   % installed + licensed, with reason
   ```

   `license('test', X)` takes a FEATURE name, and passing the display name returns `0`
   even when the product is licensed (`Deep_Learning_Toolbox` → 0 while
   `Neural_Network_Toolbox` → 1 on R2026a). The verified map lives in
   `../matlab-runner/references/toolbox-feature-map.md`. An earlier revision of this
   file pointed at `masacc.availability`, which does not exist anywhere — removed.
2. **Research before modeling.** For any physical/engineering model (power electronics, control plant, mechanical/electrical system), search first for the vendor's reference design, application note, or a proven open-source model of the same topology, and pull component parameters from real datasheets — not from memory or plausible defaults. Record the source (URL, app-note number, or datasheet part number). A simulation built on real part numbers is far more likely to run correctly the first time and produce believable results.
3. Prefer an official MATLAB MCP auto session tied to a visible MATLAB/Simulink desktop before substantial edits. Use `load_system`, `open_system`, and `set_param(modelName,"ZoomFactor","FitSystem")` so the user can see the model.
4. Audit topology before editing: blocks, lines, solver config, sample times, logged signals.
5. Prefer existing model architecture and naming.
5. Save a copy before destructive edits to user models.

## Visible Workflow Requirement

The user specifically wants to watch Simulink modeling and simulation, not only receive final artifacts. Default to this sequence unless the user explicitly asks for headless-only execution:

1. Bring up a visible MATLAB/Simulink window first.
2. For an existing model, run:
   ```matlab
   load_system(modelPath)
   open_system(modelName)
   set_param(modelName,"ZoomFactor","FitSystem")
   ```
3. For a new model, call `new_system`, save it under `artifacts/models/` or the project model folder, then immediately `open_system` before adding the rest of the blocks.
4. During automated construction, save and refresh the model at meaningful milestones so the user can see progress: plant, controller, feedback path, logging/scopes, and final layout.
5. During simulation and tuning, open Scope blocks or MATLAB figures and update/plot each run so the user can see response changes.
6. If the model window does not appear, do not assume success. Verify the visible window title if possible and retry by focusing MATLAB's command window and executing `open_system` there.
7. Still export `.slx`, data, figures, logs, and validation reports for reproducibility after the visible demonstration.

## MCP Requirement

For this repository and machine:

1. Use official MATLAB MCP auto-mode control for model creation, block editing, simulation, and tuning by default.
2. Let MCP reuse an existing shared session when present, otherwise allow it to start visible MATLAB automatically.
3. Do not replace visible MCP-driven Simulink work with silent batch execution unless the user explicitly asks for headless execution.
4. In reports, clearly state that the modeling path was MCP-driven and note any exact blocker if a required MCP action could not be completed.

## Build and Modify

Use Simulink APIs rather than manual UI steps:

- `new_system`, `open_system`, `load_system`, `save_system`
- `add_block`, `delete_block`, `add_line`, `delete_line`
- `get_param`, `set_param`, `find_system`
- `Simulink.SimulationInput` for parameter sweeps
- signal logging or `To Workspace` blocks for measurable outputs

If SimuBridge MCP tools are available, prefer them for topology audit, library search, block editing, workspace variables, and waveform analysis.

## Simulation Acceptance

A model task passes only when:

- The model diagram updates/compiles after editing, for example with `set_param(modelName,"SimulationCommand","update")` or an equivalent compile/update check.
- The model loads without errors.
- Solver and stop time are explicit.
- Simulation completes to the requested stop time.
- Required signals are logged and nonempty.
- Generated `.slx`, `.mat`, `.png`, or report artifacts are saved.

## Verify That The Disturbance Reached The Plant

When the task involves a step, load change, parameter sweep, initial-state
change, or timed injection, a moving output is not evidence that the
disturbance reached the plant. A controller can read the new value while the
plant never sees it; an insensitive output can stay flat while the plant is
correctly excited.

```matlab
r = mas_dist_enter(struct( ...
    'name','load step', 'base',struct('R',1), 'perturbed',struct('R',2), ...
    'tInject',0.5, 'simFcn',@run_case, ...
    'expect',struct('direction','increase','delta',1.0,'tol',0.02)));
r.verdict          % PASS | FAIL | UNDETERMINED
r.reasons          % PARAM_NOT_ENTERED_PLANT, OUTPUT_UNCHANGED, TIMING, ...
r.effectiveTime    % when the change actually took effect
```

`run_case` must return `t`, `y`, the parameter values the plant used
(`plantParams`), and ideally `x`, `paramLog`, and a `disturbanceLog` recorded at
the plant input. When the output is expected to be insensitive, `x` is
mandatory: no state evidence is UNDETERMINED, not PASS. `expect.delta` must be
an independent prediction, not a value read back from the same run.

The full chain, configuration fields, evidence rules, and the Simulink logging
recipe are in `references/excitation-checks.md`. Pinned by
`tests/test_dist_enter.m` 19/19, including four real `.slx` variants.

## Post-Edit Self Check

After writing or modifying a Simulink model, run a self-check before reporting completion:

1. Save the model.
2. Update/compile the diagram with `set_param(modelName,"SimulationCommand","update")`.
3. Fix unconnected ports, solver/sample-time errors, algebraic loops, missing variables, and block parameter errors found by the update step.
4. Run the requested simulation or a smoke simulation to the target stop time.
5. Verify logged signals are nonempty and finite.
6. If code generation is in scope, continue into Simulink Coder / Embedded Coder after simulation passes, then verify generated files exist and are nonempty.
7. If any compile, simulation, or code generation step cannot pass because a toolbox, support package, compiler, or hardware target is missing, state the exact blocker and save the current runnable model/artifacts for the next attempt.

## External Tool Hang Triage

When a Simulink build waits on external tools, diagnose the boundary instead of repeatedly rerunning `slbuild`:

- If the model simulates but build hangs, inspect generated build logs, `STM32CubeMX.log`, temporary script files, and active `java.exe`, compiler, or CubeMX processes.
- For STM32 builds, verify the `.ioc` is bound through `STM32CubeMX.ProjectFile`; a CubeMX installation alone is not enough.
- Check whether the project path contains non-ASCII characters, spaces, or very long segments. Copy to a short ASCII scratch path such as `<short-ascii-scratch>\project_name` for one isolation run.
- Distinguish direct tool availability from MATLAB registration. MATLAB may fail even when a desktop shortcut launches the tool.
- Record the exact phase that passed: diagram update, simulation, code generation, CubeMX generation, compiler build, or binary creation.

## Risk Checklist

Watch for:

- Algebraic loops.
- Unit/sample-time mismatches.
- Hidden Goto/From or Data Store dependencies.
- Unconnected ports.
- Solver stiffness and step-size drift.
- Simscape initialization failures.
- Stateflow unreachable states or missing default transitions.

## Reporting

Always report model path, stop time, solver, changed blocks, logged signals, and validation artifacts.

## Verify A Model By Level, Not By Hope

A saved `.slx` is not a working model. A converter model can simulate happily while
applying a zero duty for the first period, because a Unit Delay defaults to 0. Grade
the model instead of asserting it works:

```matlab
r = mas_model_check(fullfile(pwd, 'models', 'boost_avg.slx'), struct('tStop',0.01));
r.level   % L0 missing | L1 loads | L2 updates | L3 simulates with finite signals
```

`L3` is the first level that means anything numerically. Toolboxes are checked with
`mas_precheck('toolbox', ...)`, never by calling `license` with a product name.
The Skill's own `tests/test_model_check.m` pins a real model fixture at L3 and a
missing file at L0.
