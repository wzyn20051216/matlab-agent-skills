# Phase 5.2 evidence index

All runs: Windows 10.0.26100, MATLAB 26.1.0.3276743 (R2026a) Update 3,
real Control System Toolbox / Simulink / MATLAB Coder licences.
Branch `phase5.1-audit`, baseline `v0.6.0-preview.2`. Nothing here was
produced by an LLM benchmark or a paid model.

Logs are written with `evalc` + `fwrite`; `diary` in this MATLAB MCP session
created 0-byte files and is not used as evidence.

## P0-A — stability verdict

| File | What it proves |
|---|---|
| `P0A_before_fail.log` | Pre-fix contract suite: **8 / 29** (21 failures across negative gain, DC unity, double integrator, discrete Nyquist, `margin()` unit, `allmargin` agreement, and the missing three-dimension API). The log was captured with `diary` and contains NUL bytes; `strings` is needed to read it. |
| `P0A_after_partial.log`, `P0A_after.log` | Intermediate post-fix snapshots, superseded by `P0A_after_32.log`. Kept to show the suite grew from 29 to 32 cases; not used as the final number. |
| `P0A_after_32.log` | Final contract suite: **32 / 32**. The original 29 case IDs all appear and pass; C10–C12 (NaN / Inf / invalid struct) were added. |
| `P0A_ctrl_hist.log` | Historical `test_ctrl_analyze`: **14 / 14**, no regression. |
| `stability_probe.txt` | First-hand probe of `margin` / `allmargin` return order and Nyquist values, used before changing code. |

## P0-B — disturbance propagation

| File | What it proves |
|---|---|
| `P0B_before_fail_replay.log` | `mas_dist_enter.m` moved aside, suite re-run: **0 passed, 15 failed, 4 skipped**. This is an absence replay, not a buggy-behaviour replay: the function did not exist before P0-B. |
| `P0B_after_19.log` | Final suite: **19 / 19** (15 model-free + 4 real `.slx`). |
| `P0B_model_hist.log` | Historical `test_model_check`: **2 / 2**, no regression. |

## P0-C — routing output contract

| File | What it proves |
|---|---|
| `P0C_before_fail_replay.log` | HEAD `mas_route.m` restored: **2 / 16**. The old router has no `missing` / `matched` fields and returns a load order even when blocked. |
| `P0C_after.log` | New contract suite: **16 / 16**. |
| `P0C_routing_hist.log` | Historical `test_routing`: **9 / 9**, no regression. |
| `P0C_grade_hist.log` | Historical grading suite: **6 / 6**, no regression. |
| `P0C_pipeline_after.log/.json/.mat` | Routed pipeline: **15 / 15 PASS, skill match 15 / 15**. |
| `phase52_before_replay.json` | Machine-readable before/after counts for all three replays. |

## Full regression and held-out

| File | What it proves |
|---|---|
| `phase52_suites.json` | Per-suite counts listed above, as data. |
| `full_suite_after.log` | `run_all` with the three new suites: **311 / 311 skill tests**, 18 suites, 0 errors; **15 / 15** references; **15 / 15** cross-domain; **15 / 15** pipeline; 169.7 s. The two 14/15 reference tables inside this log are the deliberate D3 tamper attacks (value-only and value+hash), not the frozen manifest; the frozen manifest verifies **15 / 15**. |
| `heldout_after.log` | Held-out set H1–H7: **7 / 7** against references frozen before measurement. H4's first authored reference had the wrong sign and was corrected *before* freezing; see the report. |
| `installer_sync_dryrun.log` | `Sync-Skills.ps1 -DryRun` over the real repo: all **9** skills plan an install, 0 conflicts, 0 failures. No files were written outside the temp root. |

Machine-readable results live next to the logs:
`artifacts/validation/phase52/phase4_all.json` (full regression) and
`artifacts/phase52/heldout_results.json` (held-out).

## What is not here

- No runtime Agent auto-trigger run: Phase 4.3 receipts prove client discovery
  and loading, but this phase did not execute an LLM agent against the skills.
- No paid-model benchmark.
- No Pester suite run for the installer; only the dry-run above.
