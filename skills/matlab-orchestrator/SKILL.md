---
name: matlab-orchestrator
description: "MATLAB agentic workflow router. Use this whenever the user asks for MATLAB, Simulink, .m/.mlx/.slx work, toolbox-driven engineering, paper reproduction, simulation, code generation, data analysis, control, robotics, signal/image/AI workflows, or wants an end-to-end automated MATLAB task with validation. For Simulink tasks on this machine, default to a visible workflow: open MATLAB/Simulink windows first so the user can watch modeling, simulation, tuning, and plotting progress."
---

# MATLAB Orchestrator

Use this skill as the entry point for MATLAB work. The goal is to turn a loose engineering request into a closed-loop workflow: select the right specialist skill, run MATLAB when possible, save artifacts, and verify the result before reporting back.

## Skill Root Resolution

This Skill ships its own probe and runtime modules under `scripts/`, the
acceptance schema under `schemas/`, and the pinned MCP server release manifest under
`config/`, next to this `SKILL.md`. Commands must never
depend on the caller's working directory being the Skill root.

`$skillRoot` means the absolute path of the installed Skill directory that contains
this `SKILL.md`. Set it once per shell session from the path reported by the
client's Skill loader; do not infer it from the caller cwd and do not require a
development checkout.

```powershell
$skillRoot = '<absolute path to the installed matlab-orchestrator Skill directory>'
$probe = Join-Path $skillRoot 'scripts\Test-MatlabMcpExistingSession.ps1'
```

The router helper `mas_route` lives in the same root and reads `assets/` there. Add
it for the current MATLAB session only; never edit `savepath`, `startup.m`, or a
global MATLAB preference. (`mas_pipeline` is a repository-only benchmark harness and
is not part of the installed workflow.)

```matlab
skillRoot = '<absolute path to the installed matlab-orchestrator Skill directory>';
addpath(fullfile(skillRoot, 'scripts'));
```

If a shipped file is missing, stop and report the exact missing path. Reinstall the
Skill through the project installer; never scan the disk for a substitute script and
never execute an unknown local script.

## Execution Requirement On This Machine

On this machine, MATLAB and Simulink work should default to the official **MATLAB MCP auto** workflow, not a fresh `matlab -batch` session. Treat the visible MATLAB desktop as the primary and expected execution path for engineering tasks, especially Simulink modeling, iterative control tuning, and repeated read-modify-simulate loops.

Use this priority order:

1. Official MATLAB MCP in `auto` mode, reusing an existing shared MATLAB session when present.
2. Official MATLAB MCP in `existing` / `new` mode only if the user explicitly requests those modes.
3. `matlab -batch` only if the user explicitly asks for batch, CI, or headless execution.

## First pass

1. Identify the task family.
2. **Research before building.** Before writing any model or script, search the web for mature solutions and prior art for this exact task family: official toolboxes' shipped examples, vendor reference designs and application notes (e.g. TI / ST / Analog Devices / Infineon for power and control), open-source projects (GitHub, MATLAB Central File Exchange), and real component datasheets. For a physical/engineering task, pull parameters from real datasheets and reference designs, not from memory or plausible defaults. Record the source (URL, doc number, or datasheet part number) so the result is traceable.
3. Check whether an official MATLAB MCP auto configuration is available first.
4. If the task requires MATLAB work on this machine, stay on MCP unless the user explicitly requests a headless/batch path.
5. Inspect installed toolboxes with `ver` before choosing toolbox-specific APIs.
6. Prefer official MathWorks documentation and installed examples over memory.
7. Treat forum posts and blogs as hints only; verify every API and parameter locally.

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

## Readiness Gate Before Any MCP Run

Never infer MCP readiness from a config file, a recorded `pid`, or a listening port. Run the staged probe first and read the per-stage verdict:

```powershell
powershell -ExecutionPolicy Bypass -File $skillRoot\scripts\Test-MatlabMcpExistingSession.ps1 -ProjectRoot (Get-Location).Path -Json
```

For any task longer than a single call, use the fast gate instead — it decides in seconds:

```powershell
# exit 0 = provably executable; exit 1 = not ready, nextAction prints the exact two commands
powershell -ExecutionPolicy Bypass -File $skillRoot\scripts\Ensure-MatlabMcpReady.ps1 `
  -Work (Join-Path (Get-Location).Path 'artifacts\runtime') -Json
```

Why this gate exists: in `existing` mode an expired or overwritten shared session still passes `initialize` and `tools/list`, then `tools/call` blocks for the full client timeout and the task ends BLOCKED after several minutes of silence. The gate accepts exactly one proof — real `tools/call` returning a real value (`mcp.readonly-exec` = `PASS`, 20 s timeout by default) — and treats pid/port checks only as cheap early exits. A `pause()`-held session proves why: the port answers `200` while every call hangs.

On `NOT_READY`, run the printed `startCommand` as a **background task** (the session must outlive this shell), wait for `session_ready.json`, then re-run the gate. Do not start substantive work before it reports `READY`.

The probe grades install, session config, client registration, protocol handshake, read-only execution, and file read-back as **separate checks**. It drives the official MATLAB MCP server over **stdio** by default (`-Transport auto`); the `https` path exists only to observe the connector, whose direct `POST /mcp` answers `403` by design. Run it without `-SkipTlsValidation`, and route the SKIP/FAIL reason it reports rather than inventing a fallback.

Consequences you must respect when routing work:

- If `mcp.protocol-handshake` is `FAIL`, do not attempt MCP edits; report the exact blocker (HTTP status plus JSON-RPC error) and ask before switching to batch.
- If `mcp.readonly-exec` is `SKIP` because the server exposes no evaluation tool, say so — a successful handshake only proves the protocol layer, not that MATLAB can run anything.
- If the session file is stale (missing certificate, dead pid), the honest report is "existing session is stale", not "MCP is configured".

## Closed-loop Definition

A MATLAB task is complete only when it has:

- A runnable command or script.
- Logs captured from MATLAB.
- Artifacts saved in a predictable folder.
- A numerical, visual, or structural acceptance check.
- A short explanation of what was verified and what remains unverified.

The acceptance verdict must come from the unified report, not from your impression:

- Report file: `artifacts/validation/acceptance_report.json` in the user's project, validated against `$skillRoot/schemas/acceptance-report.schema.json`.
- `overallStatus` is `PASS` only when every check passed. Any `SKIP` makes it `SKIP` (exit code `3`), and `SKIP` is never converted into a pass.
- `achievedLevel` is the highest **contiguous** level reached: if L2 was skipped, a passing L3 still only yields L1.
- Route the work so that at least the level the user asked for is genuinely executed. If it cannot be executed here (no license, no toolbox, no board), say that explicitly instead of producing an L1 artifact and calling it done.

Level routing hints:

| If the user asks for | The minimum honest evidence is |
| --- | --- |
| "generate code" | L2: real compile artifact (library/executable), not just `.c` files |
| "make the model work" | L3: simulation reaches stop time and key signals match expectations |
| "make it robust" | L4: parameter sweep plus failure-mode checks (NaN, illegal inputs) |
| "deploy to the board" | L5: download plus read-back — generic C codegen is not deployment |

Failure classification and retry policy live in `matlab-runner`; classify before retrying, and never auto-retry destructive or non-idempotent operations.

## Routing

Do not choose a skill from memory. Run the matcher, which reads the weighted term
table in `assets/routing.json`:

```matlab
r = mas_route("设计三相逆变器并分析 THD");
r.schemaVersion   % '1.1'
r.decision        % 'ROUTE' | 'CLARIFY' | 'AMBIGUOUS' | 'BLOCKED'
r.loadOrder       % {'matlab-runner','matlab-simulink-modeling','matlab-signal-vision-ai'}
r.nextAction      % 'load' | 'ask' | 'stop'
```

Consume the decision before anything else, and do not override it:

- `ROUTE` → load `loadOrder` in order. It is already dependency-sorted;
  `matlab-runner` is always first because every route needs execution.
- `CLARIFY` → the best score is below `minScore`. Ask one question; never use
  `ranked(1)` as if it were a decision.
- `AMBIGUOUS` → two domains tied. Ask which one carries the core work.
- `BLOCKED` → stop. `missing` names the absent skill, damaged `SKILL.md`,
  unlicensed hard toolbox, missing dependency, or dependency cycle. Do not
  substitute a different domain and do not run a partial workflow; `loadOrder`
  is empty by contract.

Secondary skills join when their score is at least `multiSkillRatio * top`.
`matlab-testing-ci` joins only when the task is meant to be reusable or
explicitly needs acceptance/regression. A soft requirement that is unlicensed
appears in `notes` and does not block.

The router is lexical. Negation is handled per clause, and ASCII terms of three
characters or fewer match on word boundaries, but a prompt with no matching
terms must come back as `CLARIFY` rather than a guess. The full field list,
blocker kinds, and consumer rules are in
[`references/routing-contract.md`](references/routing-contract.md).

| Skill | Domain |
| --- | --- |
| `matlab-runner` | execution, logs, prechecks, artifacts (always loaded) |
| `matlab-simulink-modeling` | `.slx`, Stateflow, Simscape, simulation, sweeps |
| `matlab-signal-vision-ai` | signals, filters, spectra, images, video, AI |
| `matlab-control-optimization` | controllers, state space, identification, MPC, optimization |
| `matlab-data-analysis` | tables, statistics, fitting, figures, reports |
| `matlab-codegen-deploy` | C/C++/CUDA/HDL generation, MEX, embedded deployment |
| `matlab-robotics-autonomy` | ROS, kinematics, planning, navigation, sensor fusion |
| `matlab-testing-ci` | unit tests, Simulink Test, coverage, CI, acceptance |

`tests/test_routing.m` 9/9 preserves the Phase 4 brief examples and the two
"must not guess" cases. `tests/test_routing_contract.m` 16/16 pins the
versioned contract, including refusal, dependency order, and availability
blockers. Routing changes are covered by both.

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
3. Vendor reference designs, application notes, and real component datasheets (for any physical/engineering task, these override memory and plausible defaults for component values).
4. MathWorks GitHub repositories and MATLAB Actions.
5. Peer-reviewed paper, official dataset, or author repository.
6. GitHub issues, MathWorks Answers, Zhihu, blogs, and forums as untrusted heuristics.

Never cite a forum workaround as fact until a local MATLAB command confirms it. Never pick a component value from memory when a datasheet or reference design for that part is reachable.

## Reporting

Keep the final answer concise and practical, and keep the three categories separate:

1. **Verified**: command, exit code, and the acceptance report path.
2. **Executed but failed or skipped**: the `reason` field, verbatim.
3. **Not executed**: state it plainly and name the missing prerequisite (license, toolbox, hardware, network).

Never present a skipped check as a supported capability, and never present a generated artifact as a successful build.
