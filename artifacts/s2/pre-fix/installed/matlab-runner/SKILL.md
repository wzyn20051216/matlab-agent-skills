---
name: matlab-runner
description: Run MATLAB tasks from Codex with reliable MCP-based execution, logs, artifacts, toolbox inventory, smoke tests, and reproducible validation. Use whenever MATLAB code, .m/.mlx scripts, MATLAB tests, local toolbox probing, or command-line automation is needed.
---

# MATLAB Runner

Use this skill to execute MATLAB work safely and repeatably through the official MATLAB MCP server, preferably in `auto` mode, and only use terminal batch workflows when the user explicitly asks for them. It is the foundation skill for all other MATLAB skills.

## References — load on demand

This file carries the workflow. The tables below are **not** loaded unless the task
actually reaches them, because each is a few hundred tokens of detail that costs
context on every run and goes stale on every MATLAB release.

| Load this | when |
|---|---|
| `references/toolbox-feature-map.md` | resolving a product name to a licence feature |
| `references/mcp-readiness-ladder.md` | about to claim MCP is ready, or MCP failed |
| `references/acceptance-levels.md` | about to write an acceptance report |
| `references/failure-classes.md` | a run failed and you are deciding whether to retry |

## Execution Rules

1. Prefer the official MATLAB MCP auto mode for MATLAB work on this machine.
2. Do not silently fall back to `matlab -batch` when MCP is expected.
3. Capture logs, version info, working directory, and artifact paths where applicable.
4. Run from a project root, not from a random temporary folder, unless isolation is required.
5. Put generated files under `artifacts/` or a user-specified output folder.
6. Keep scripts deterministic: seed random generators and record data sources.

## Precheck Before A Long Run

Phase 3B.1 shipped five scripts and none ran on the first attempt; most of those
failures were detectable in seconds. Run the cheap checks first, in this order:

```matlab
r = mas_precheck('function', 'boost_params');                 % exists?
r = mas_precheck('struct',   cfg, {'Vin','L','C'});           % fields present?
r = mas_precheck('numeric',  x, struct('finite',true));        % NaN/Inf?
r = mas_precheck('index',    mask, numel(target));             % mask length
r = mas_precheck('toolbox',  'Control System Toolbox');        % product vs feature
r = mas_precheck('model',    'matlab/boost/models/boost_avg.slx');
```

The `index` check exists because MATLAB does **not** error when a logical mask is
shorter than the array it indexes: it silently returns the first `numel(mask)`
elements. In Phase 3B.2 that turned every `iLref` reading into `0` and nearly
produced the conclusion "the current command is railed". A length check makes it
loud. `tests/test_precheck.m` covers positive and must-fail cases.

Never start a 20-minute matrix after a failed precheck; fix the precheck first.

## MCP Required By Default

A config file never proves MCP works, and `sessionDetails.json`, a listening `pid`
or a client entry in `.mcp.json` all look identical to a file-existence check.

`sessionDetails.json` is a credential descriptor, not plain configuration: it holds
the live MCP `apiKey` and certificate. Never read, print, echo, copy, or archive its
contents, and never paste it into prompts, logs, or reports. Use the probe below,
which reads only the fields it needs. If a credential may have been exposed, report
the file path and field name without reproducing the value, then ask the user to
rotate it — a redacted report does not mean the underlying key is invalid.

Before claiming readiness, run the staged probe and read its verdict:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabMcpExistingSession.ps1 -Json
```

The seven-stage ladder, the rules that must not be relaxed (only stage 4 upgrades a
licence SKIP to PASS; a failed stage makes every later stage SKIP), and the
machine-specific decision rule are in `references/mcp-readiness-ladder.md`. Load it
when you are about to make a readiness claim — not before.

If MCP is unavailable, **report the blocker** instead of silently changing execution
mode. A batch rerun that succeeds hides the problem the user needs to see.

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
- Check a missing toolbox with `mas_precheck('toolbox', X)` rather than by hand.
  `license('test', ...)` takes a **feature** name, not the product display name, and
  the two differ often enough to burn a run: on R2026a
  `license('test','Deep_Learning_Toolbox')` returns `0` while
  `license('test','Neural_Network_Toolbox')` returns `1` for the same installed
  product. The verified product→feature map, with its provenance, is in
  `references/toolbox-feature-map.md`.

  ```matlab
  r = mas_precheck('toolbox', 'Deep Learning Toolbox');
  r.pass, r.detail     % 1, "installed 1, feature Neural_Network_Toolbox licensed 1"
  ```

  A product missing from the map returns a failure that says so, rather than
  guessing. (An earlier revision of this file told the agent to call
  `masacc.availability`. No such package exists in this repository or in any
  installed toolbox — a call to it fails immediately. That instruction is removed,
  and `mas_capability_check` now fails the build if any file references it again.)
- Check path ambiguity with `which functionName -all`.
- Re-run a minimal reproduction before editing large code.
- Save the failing command and log path.
- If the failure was on MCP, report the exact MCP blocker and stop hiding it behind a batch rerun.

## Acceptance Checks

Report which level was actually proven, not a vague "it works". The levels are
cumulative and **never upgrade themselves**: producing a file is an L1 claim, and
calling that "deployed" is the most common overstatement here because the file
really is there.

| Level | Meaning |
|---|---|
| L1 | artifact produced |
| L2 | build/compile succeeded |
| L3 | numeric result matches a golden value |
| L4 | multi-scenario and failure modes |
| L5 | real hardware run, read back |

`SKIP` means "not executed" and is not a pass; a report containing any SKIP has
`overallStatus = SKIP` and exit code `3`. `FAIL` or `SKIP` without a `reason` is
rejected at construction time. Which single checks are worth running per situation
is in `references/acceptance-levels.md` — load it before writing the report, not
before every command.

## Failure Classification

Classify before retrying. Retrying a `LICENSE_ERROR` or an `ENVIRONMENT_ERROR` only
wastes time, and a retried `VALIDATION_ERROR` can turn a clear numeric mismatch into
a vague "flaky". The eight classes, which are auto-retryable, and the cap of 5
attempts are in `references/failure-classes.md`. The rule that matters most:
**non-idempotent or destructive operations (downloads, installs, writes) are never
retried without explicit user approval**, because the retry is the part that causes
damage.

## Paper Reproduction Mode

For open-source paper projects:

1. Record paper URL, commit hash, dataset URL, MATLAB release, toolbox list.
2. Run the smallest official example first.
3. Reproduce one figure or table before scaling to the whole paper.
4. Save `manifest.json`, raw logs, processed data, and generated figures.
5. Mark differences from the paper explicitly instead of smoothing them over.

## One Dependency Mechanism, Five Failure Classes

`mas_precheck('toolbox', X)` and `mas_dep_probe` now share a single product table
(`mas_product_map.m`). Before this there were two copies and they could drift; the
old one lived inside `mas_precheck` and the new one inside the probe.

```matlab
d = mas_dep_probe('product', 'Deep Learning Toolbox');
d.state    % OK | NOT_INSTALLED | NOT_LICENSED | UNKNOWN_PRODUCT | EXEC_FAILED
d.level    % 1 function resolved, 3 product installed, 4 feature licensed, 5 probe ran
```

`NOT_INSTALLED`, `NOT_LICENSED` and `UNKNOWN_PRODUCT` are different problems with
different fixes, so they are different states. The probe reports which level it
reached, so "it does not work" becomes a specific sentence.

Historical product names are aliases of the current row (`Neural Network Toolbox` ->
`Deep Learning Toolbox`, `Statistics Toolbox` -> `Statistics and Machine Learning
Toolbox`), because a user typing the old name must not get "not licensed". Covered
by `tests/test_dep_probe.m`, including must-fail dependency cases.
