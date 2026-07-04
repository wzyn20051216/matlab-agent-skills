---
name: matlab-simulink-modeling
description: MATLAB R2026a and Simulink workflow for creating, inspecting, modifying, simulating, validating, and exporting .slx models. Use for Simulink, Stateflow, Simscape, model-based design, parameter sweeps, signal logging, requirements, and simulation automation.
---

# MATLAB Simulink Modeling

Use this skill for model-based design and simulation workflows.

## First Checks

1. Confirm `Simulink` is installed with `ver` and licensed with `license('test','Simulink')`.
2. Open or create the model from MATLAB batch where possible.
3. Audit topology before editing: blocks, lines, solver config, sample times, logged signals.
4. Prefer existing model architecture and naming.
5. Save a copy before destructive edits to user models.

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
