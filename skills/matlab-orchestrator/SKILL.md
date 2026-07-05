---
name: matlab-orchestrator
description: MATLAB R2026a agentic workflow router. Use this whenever the user asks for MATLAB, Simulink, .m/.mlx/.slx work, toolbox-driven engineering, paper reproduction, simulation, code generation, data analysis, control, robotics, signal/image/AI workflows, or wants an end-to-end automated MATLAB task with validation. For Simulink tasks on this machine, default to a visible workflow: open MATLAB/Simulink windows first so the user can watch modeling, simulation, tuning, and plotting progress.
---

# MATLAB Orchestrator

Use this skill as the entry point for MATLAB R2026a work. The goal is to turn a loose engineering request into a closed-loop workflow: select the right specialist skill, run MATLAB when possible, save artifacts, and verify the result before reporting back.

## Execution Requirement On This Machine

On this machine, MATLAB and Simulink work should default to the official **MATLAB MCP auto** workflow, not a fresh `matlab -batch` session. Treat the visible MATLAB desktop as the primary and expected execution path for engineering tasks, especially Simulink modeling, iterative control tuning, and repeated read-modify-simulate loops.

Use this priority order:

1. Official MATLAB MCP in `auto` mode, reusing an existing shared MATLAB session when present.
2. Official MATLAB MCP in `existing` / `new` mode only if the user explicitly requests those modes.
3. `matlab -batch` only if the user explicitly asks for batch, CI, or headless execution.

## First pass

1. Identify the task family.
2. Check whether an official MATLAB MCP auto configuration is available first.
3. If the task requires MATLAB work on this machine, stay on MCP unless the user explicitly requests a headless/batch path.
4. Inspect installed toolboxes with `ver` before choosing toolbox-specific APIs.
5. Prefer official MathWorks documentation and installed examples over memory.
6. Treat forum posts and blogs as hints only; verify every API and parameter locally.

## Local Simulink Visualization Preference

The user prefers to see Simulink work happen live, not only receive final files. For Simulink modeling, simulation, control tuning, or code generation tasks:

1. Start by opening a visible MATLAB/Simulink session and the relevant `.slx` model with `load_system` / `open_system`.
2. If creating a new model, create and save the model early, then open it before continuing with automated block edits.
3. Use `open_system(modelName)`, `set_param(modelName,"ZoomFactor","FitSystem")`, scopes, figures, and live plots so the user can watch the process.
4. Prefer a visible demonstration step before or alongside batch validation. Batch logs and exported artifacts are still required for acceptance, but they should not replace the visible model/plot experience.
5. When an already-open MATLAB window is present, try to execute `open_system` in that visible session or bring the Simulink model window to the front. Confirm the expected model window title in the final report.

## MCP-Specific Guidance

When an official MATLAB MCP auto path is available:

1. Treat the visible MATLAB desktop session as the primary control plane.
2. Prefer MCP-driven model edits, simulation commands, workspace inspection, and iterative tuning in that same session.
3. Do not silently switch to batch mode just because batch would be easier.
4. In the final report, explicitly say that the task ran through MCP, and note any remaining blocker if a required MCP action could not be completed.

## Routing

Use these specialist skills:

- `matlab-runner`: execution wrapper, logs, local validation, reproducible artifacts.
- `matlab-data-analysis`: tables, timetables, statistics, fitting, visualization, reports.
- `matlab-simulink-modeling`: `.slx` models, simulation, signal logging, parameter sweeps.
- `matlab-codegen-deploy`: MATLAB Coder, Embedded Coder, GPU Coder, HDL Coder, deployment.
- `matlab-control-optimization`: control design, system identification, MPC, optimization.
- `matlab-robotics-autonomy`: ROS, robotics, navigation, UAV, sensor fusion, trajectories.
- `matlab-signal-vision-ai`: signal processing, image processing, computer vision, deep learning.
- `matlab-testing-ci`: unit tests, Simulink Test, GitHub Actions, reproducible CI.

If multiple domains apply, start with `matlab-runner`, then load the narrowest domain skill for the core work, and finish with `matlab-testing-ci` when the task is meant to be reusable.

## Closed-loop Definition

A MATLAB task is complete only when it has:

- A runnable command or script.
- Logs captured from MATLAB.
- Artifacts saved in a predictable folder.
- A numerical, visual, or structural acceptance check.
- A short explanation of what was verified and what remains unverified.

## Default Artifact Layout

Use this layout for generated work unless the project already has a convention:

```text
artifacts/
  logs/
  figures/
  data/
  models/
  reports/
  validation/
```

For paper reproduction, add:

```text
repro/
  source/
  scripts/
  figures/
  results/
  manifest.json
```

## Source Discipline

Use sources in this order:

1. Local MATLAB `help`, `doc`, `ver`, `which`, `exist`, `license`.
2. MathWorks official documentation and release notes.
3. MathWorks GitHub repositories and MATLAB Actions.
4. Peer-reviewed paper, official dataset, or author repository.
5. GitHub issues, MathWorks Answers, Zhihu, blogs, and forums as untrusted heuristics.

Never cite a forum workaround as fact until a local MATLAB command confirms it.

## Reporting

Keep the final answer concise and practical:

- Which specialist path was used.
- Which command ran.
- Where artifacts were saved.
- What passed, failed, or was skipped.
- Any license, toolbox, hardware, or dataset limitations.
