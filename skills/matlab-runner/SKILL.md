---
name: matlab-runner
description: Run MATLAB R2026a tasks from Codex with reliable MCP-based execution, logs, artifacts, toolbox inventory, smoke tests, and reproducible validation. Use whenever MATLAB code, .m/.mlx scripts, MATLAB tests, local toolbox probing, or command-line automation is needed.
---

# MATLAB Runner

Use this skill to execute MATLAB work safely and repeatably through the official MATLAB MCP server, preferably in `auto` mode, and only use terminal batch workflows when the user explicitly asks for them. It is the foundation skill for all other MATLAB skills.

## Execution Rules

1. Prefer the official MATLAB MCP auto mode for MATLAB work on this machine.
2. Do not silently fall back to `matlab -batch` when MCP is expected.
3. Capture logs, version info, working directory, and artifact paths where applicable.
4. Run from a project root, not from a random temporary folder, unless isolation is required.
5. Put generated files under `artifacts/` or a user-specified output folder.
6. Keep scripts deterministic: seed random generators and record data sources.

## MCP Required By Default

When using this repository on this machine, use this decision rule:

1. Prefer official MATLAB MCP auto mode, so the server can reuse an existing shared session or start MATLAB automatically.
2. If the task requires repeated model edits, parameter sweeps with live inspection, or user-visible desktop interaction, stay on MCP.
3. Batch mode is reserved for explicit user requests such as CI, headless smoke tests, or reproducible one-shot runs.
4. If MCP is unavailable, report the blocker instead of silently changing execution mode.

## Preferred Wrapper

If the user explicitly requests batch execution in this repository, prefer:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Invoke-MatlabBatch.ps1 -Script .\path\to\script.m
```

For official MCP auto-mode setup and validation in this repository, prefer:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Setup-MatlabMcpExistingSession.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabMcpExistingSession.ps1
```

For a full local smoke test:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabSkills.ps1
```

If the wrapper is not available, call MATLAB directly:

```powershell
matlab -batch "disp(version); v=ver; disp({v.Name}')"
```

## MATLAB Discovery

Use this order to find MATLAB:

1. Official MATLAB MCP auto configuration
2. Existing official MATLAB shared session metadata when present
3. `$env:MATLAB_EXE`, `Get-Command matlab`, and known install paths only for setup/verification of the MCP environment

Verify before running expensive work:

```matlab
disp(version)
v = ver;
{v.Name}'
```

## Error Handling

When MATLAB fails:

- Read the first error and the deepest stack frame.
- Check missing toolbox with `license('test', product)` and `ver`.
- Check path ambiguity with `which functionName -all`.
- Re-run a minimal reproduction before editing large code.
- Save the failing command and log path.
- If the failure was on MCP, report the exact MCP blocker and stop hiding it behind a batch rerun.

## Acceptance Checks

Choose at least one:

- Unit test passes with `runtests` and `assertSuccess`.
- Numerical tolerance check passes.
- Simulink model simulates to stop time and logged signals are nonempty.
- Figure, data file, report, or generated code exists and has nonzero size.
- Static checks such as `checkcode` return no critical issues for touched files.

## Paper Reproduction Mode

For open-source paper projects:

1. Record paper URL, commit hash, dataset URL, MATLAB release, toolbox list.
2. Run the smallest official example first.
3. Reproduce one figure or table before scaling to the whole paper.
4. Save `manifest.json`, raw logs, processed data, and generated figures.
5. Mark differences from the paper explicitly instead of smoothing them over.
