---
name: matlab-simulink-modeling
description: MATLAB R2026a and Simulink workflow for creating, inspecting, modifying, simulating, validating, and exporting .slx models. Use for Simulink, Stateflow, Simscape, model-based design, parameter sweeps, signal logging, requirements, and simulation automation. On this machine, Simulink tasks should be visual-first: open the model in a visible Simulink window before doing substantial automated modeling or simulation so the user can watch the process.
---

# MATLAB Simulink Modeling

Use this skill for model-based design and simulation workflows.

## First Checks

1. Confirm `Simulink` is installed with `ver` and licensed with `license('test','Simulink')`.
2. Open or create the model in a visible MATLAB/Simulink session before substantial edits. Use `load_system`, `open_system`, and `set_param(modelName,"ZoomFactor","FitSystem")` so the user can see the model.
3. Audit topology before editing: blocks, lines, solver config, sample times, logged signals.
4. Prefer existing model architecture and naming.
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

- The model loads without errors.
- Solver and stop time are explicit.
- Simulation completes to the requested stop time.
- Required signals are logged and nonempty.
- Generated `.slx`, `.mat`, `.png`, or report artifacts are saved.

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
