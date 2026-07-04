---
name: matlab-orchestrator
description: MATLAB R2026a agentic workflow router. Use this whenever the user asks for MATLAB, Simulink, .m/.mlx/.slx work, toolbox-driven engineering, paper reproduction, simulation, code generation, data analysis, control, robotics, signal/image/AI workflows, or wants an end-to-end automated MATLAB task with validation.
---

# MATLAB Orchestrator

Use this skill as the entry point for MATLAB R2026a work. The goal is to turn a loose engineering request into a closed-loop workflow: select the right specialist skill, run MATLAB when possible, save artifacts, and verify the result before reporting back.

## First pass

1. Identify the task family.
2. Check local MATLAB availability with `matlab -batch "disp(version)"` or the shared runner script.
3. Inspect installed toolboxes with `ver` before choosing toolbox-specific APIs.
4. Prefer official MathWorks documentation and installed examples over memory.
5. Treat forum posts and blogs as hints only; verify every API and parameter locally.

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
