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

## MCP Readiness Is Not A Config Check

A `sessionDetails.json`, a listening `pid`, or a client entry in `.mcp.json` does **not** prove MCP works. Three states that look identical to a file-existence check are actually different: config present but server dead, server alive but handshake rejected, handshake fine but tool execution failing.

Before claiming MCP is ready, run the staged probe and read its verdict:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabMcpExistingSession.ps1 -Json
```

Each stage is graded independently and never inherits success from a previous stage:

| Stage | Check id | Level | Proves |
| --- | --- | --- | --- |
| 1 | `mcp.matlab-install` | L1 | MATLAB executable resolved, `VersionInfo.xml` readable |
| 2 | `mcp.matlab-license` | L1 | license usable (SKIP by default, `-VerifyLicense` to force) |
| 2 | `mcp.session-config` | L1 | session JSON parses, certificate exists, port valid |
| 2 | `mcp.client-registration` | L2 | client args have no `display-mode`, `command` really exists |
| 3 | `mcp.protocol-handshake` | L2 | TCP reachable and `initialize` returns a valid `result` |
| 4 | `mcp.readonly-exec` | L3 | a read-only command really executed through `tools/call` |
| 5 | `mcp.file-io` | L4 | token written to an isolated dir and read back identical |

Rules that must not be relaxed:

- Only stage 4 passing upgrades `mcp.matlab-license` from SKIP to PASS, and the evidence (`provenBy = mcp.readonly-exec`) is recorded in `metrics`.
- A failed stage makes every later stage `SKIP` with reason "upstream not passed". Never continue as if the earlier stage had succeeded.
- An HTTP error must keep both the status code and the JSON-RPC error in `reason`; a bare `unauthorized` string hides whether the server is down or the key is wrong.

## Preferred Wrapper

If the user explicitly requests batch execution in this repository, prefer:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Invoke-MatlabBatch.ps1 -Script .\path\to\script.m -TimeoutSeconds 1800
```

`-TimeoutSeconds` is mandatory in spirit: a batch run without a timeout can hang forever. The wrapper exits `124` on timeout, `2` when MATLAB cannot be found, and otherwise returns the real MATLAB exit code. A timed-out run terminates the whole process tree and still keeps the partial logs.

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

Report which level was actually proven, not a vague "it works". The levels are cumulative:

| Level | Meaning | Example evidence |
| --- | --- | --- |
| L1 | artifact produced | `.slx` created and non-empty; `.c`/`.h` generated |
| L2 | build/compile succeeded | MEX built; `slbuild` produced a library; model `update` passed |
| L3 | numeric result matches | `rmse`, `maxAbsDiff` within tolerance against a golden value |
| L4 | multi-scenario and failure modes | parameter sweep, NaN/Inf propagation, illegal size rejected |
| L5 | real hardware run | board download plus read-back |

Hard rules:

- File existence is an L1 claim only. It never substitutes for L2 compile success.
- Generic C codegen is not STM32 deployment. STM32 needs CubeMX registration, visible target hardware, bound `.ioc`, and a Cube firmware package — verify those separately.
- Every run must edit the acceptance report (`artifacts/validation/acceptance_report.json`), which carries `status`, `command`, `exitCode`, `metrics`, `reason`, `errorClass` per check.
- `SKIP` means "not executed", and it is not a pass. A report containing any SKIP has `overallStatus = SKIP` and exit code `3`.
- `FAIL` or `SKIP` without a `reason` is rejected by the validator at construction time.

Useful single checks:

- Unit test passes with `runtests` and `assertSuccess`.
- Numerical tolerance check passes with both absolute and relative tolerance recorded.
- Simulink model loads, updates, simulates to stop time, and logged signals are nonempty.
- Figure, data file, report, or generated code exists and has nonzero size (L1 only).
- Static checks such as `checkcode` return no critical issues for touched files.

## Failure Classification

When a run fails, classify before retrying. Retrying a `LICENSE_ERROR` or `ENVIRONMENT_ERROR` only wastes time.

| Class | Auto-retry | Typical cause |
| --- | --- | --- |
| `TIMEOUT` | yes | process exceeded its budget and was killed |
| `MCP_CONNECTION_ERROR` | yes | port closed, handshake rejected, bad API key |
| `ENVIRONMENT_ERROR` | no | compiler or executable missing |
| `LICENSE_ERROR` | no | product not licensed |
| `VALIDATION_ERROR` | no | numeric or content mismatch |
| `SIMULATION_ERROR` | no | solver error |
| `CODEGEN_ERROR` | no | build error |
| `MATLAB_RUNTIME_ERROR` | no | other runtime error |

Retries are capped at 5 attempts. Non-idempotent or destructive operations (downloads, installs, writes) must not be retried without explicit user approval.

## Paper Reproduction Mode

For open-source paper projects:

1. Record paper URL, commit hash, dataset URL, MATLAB release, toolbox list.
2. Run the smallest official example first.
3. Reproduce one figure or table before scaling to the whole paper.
4. Save `manifest.json`, raw logs, processed data, and generated figures.
5. Mark differences from the paper explicitly instead of smoothing them over.
