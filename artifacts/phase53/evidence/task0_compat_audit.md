# Phase 5.3 Task 0 — Phase 5.2 freeze & compatibility audit

Date: 2026-10-21 · Branch: `phase5.1-audit` · MATLAB R2026a Update 3 (26.1.0.3276743)

This file is the evidence record for Task 0: before committing the Phase 5.2
changes, every compatibility claim in
`docs/PHASE5_2_ENGINEERING_CONTRACTS_ZH.md` was re-verified against the current
working tree. Nothing below is self-graded: counts come from `run_all`, the
cross-domain grader `mas_verify_task`, `mas_capability_check`, `mas_dep_probe`
and the bootstrap installer's own JSON report.

## 1. Full regression reproduced (311/311)

`run_task0_regression.m` → `run_all('artifacts/validation/phase53')`:

| Metric | Result |
|---|---|
| Skill suites | **311 / 311**, 0 suites errored, 18/18 suites ran |
| Frozen references | 15 / 15 |
| Cross-domain tasks | 15 / 15 (fail 0, undetermined 0, skip 0) |
| Routed pipeline | 15 / 15, skillMatchRate 1.0, selfDisagreement 0 |
| Elapsed | 172.1 s |

New Phase 5.2 suites inside the total: `stabilityContract` 32/32,
`distEnter` 19/19, `routingContract` 16/16. Evidence:
`task0_regression.log`, `task0_regression_summary.json`,
`../validation/phase53/phase4_all.json`.

## 2. Three P0 tools — real invocation interfaces

All three ran inside the regression above against real MATLAB objects (tf /
feedback / pole, real `.slx` via `sim`, real routing table), not mocks:
`mas_stability_verdict` (32 checks), `mas_dist_enter` (19 checks incl. 4 real
Simulink cases), `mas_route` schema 1.1 (16 checks). No interface drift.

## 3. Legacy `mas_ctrl_analyze.verdict` — every caller audited

| Caller | Reads | Verdict under new semantics |
|---|---|---|
| `skills/matlab-control-optimization/scripts/mas_ctrl_pid_design.m:60` | `pmWorst`, `gmWorst`, `verdict` | Only change: evidence-conflict case is now `UNDETERMINED` instead of `STABLE` → a candidate may be **rejected more often**, never falsely accepted. Safe direction. |
| `matlab/validation/crossdomain/tasks/cd_c1_stable.m` | `verdict=='STABLE'` | Loop has one crossing, PM +95.7° → still `STABLE`; task PASSes (15/15 run). |
| `matlab/validation/crossdomain/tasks/cd_c2_unstable.m` | `verdict~='STABLE'` | Unstable loop → `UNSTABLE`; task PASSes. |
| `matlab/validation/crossdomain/tasks/cd_c3_multicross.m` | logs verdict only; decides on `nDown`/`pmWorst` | Unaffected; PASSes. |
| `matlab/validation/phase44/desktop_control_task.m:39` | `pmWorst` only | Unaffected. |
| `mas_stability_verdict.m` | whole struct (by design) | The new contract layer. |

No production caller breaks, and no caller can now read `STABLE` for a loop
whose frequency evidence says otherwise. Residual (documented in the Phase 5.2
report): a caller that reads *only* `r.verdict` still sees "mathematical
stability", not the engineering verdict — that is why new contract consumers go
through `mas_stability_verdict`.

## 4. `mas_dist_enter` cross-model applicability

`probe_dist_models.m` — three models structurally different from the test
suite's:

| Case | Model | Result |
|---|---|---|
| M1 | matrix-form discrete `A=[0.9 0;0 0.5]`, `B=[0.1;0.2]`, parameter `a` 0.9→0.5 | PASS, VERIFIED, delta −0.8 exactly |
| M2 | two-input `x=0.8x+[0.5 0.2][u1;u2]`, perturbation on `u1` only (u2 present in log) | PASS, VERIFIED, delta +2.5 |
| M3 | decoupled states, perturbation on `x2_0`, output reads `x1` (insensitive output) | PASS, VERIFIED, delta 0 — refuses to claim a change |

3/3 PASS. Evidence: `task0_dist_models.json`, `probe_dist_models.log`.

## 5. `mas_route` schema 1.1 vs old consumers

- Legacy suite `test_routing` 9/9 and new `test_routing_contract` 16/16 in the
  same run; routed pipeline 15/15 with skillMatchRate 1.0.
- Every pre-1.1 field (`ranked`, `alwaysLoaded`, `prompt`, `decision`,
  `primary`, `secondary`, `loadOrder`, `reason`) is still populated;
  `with_always` keeps `loadOrder = alwaysIds` for CLARIFY/AMBIGUOUS exactly as
  before. Only new behavior: the new `BLOCKED` decision replaces what used to
  be a non-empty `loadOrder` on unavailable paths (previously a caller could
  proceed with a skill that was not installable).

## 6. Discoverability of the new tools

`mas_capability_check('all')` — CONSISTENT, 5/5:
tools 34 on disk / 34 listed; every tool under its real skill; counts match;
every VERIFIED claim cites an existing test; **13/13 reference pointers
resolve** (includes the three new reference files).

`mas_skill_graph('all')` — 3/4:

| Check | Result |
|---|---|
| cycles | pass — no cycle among 9 edges over 9 skills |
| dangling | pass — all 8 routed skills exist on disk |
| coverage | pass — all 8 non-router skills are routable |
| duplication | **fail — pre-existing, not a Phase 5.2 regression**: `matlab-runner` is referenced by `matlab-orchestrator/SKILL.md:128` (always-loaded table) and `matlab-simulink-modeling/SKILL.md:21` (pointer to `../matlab-runner/references/toolbox-feature-map.md`). Both lines exist at HEAD (`git show HEAD:...`); `test_skill_graph` has no duplication assertion, which is why the suite is green. An always-loaded skill referenced by its consumers is by design; the check is recorded as a residual finding (P5.3-R1), not silently "fixed". |

## 7. Installation integrity

Bootstrap installer dry-run (`scripts/Bootstrap-MatlabAgentSkills.ps1 -InstallDir
E:/desktop/MATLAB -DryRun -SkipBaseSetup -SkillRoot <temp>`), exit 0:

- `install.ok = true`, `dryRun = true`, `failed = false`
- 9/9 skills decided `install`, 0 updated, 0 unchanged, **0 conflicts**
- sourceRoot = repo `skills/`, target = empty temp dir (never the real skill
  root — dry-run writes nothing)

Evidence: `task0_installer_sync_dryrun.log`.

## 8. Toolbox / licence status for the three Phase 5.3 domains

`phase53_license_probe.m` via `mas_dep_probe` (deep): **31/31 functions OK,
level 1** — signal 7/7, data 8/8, robotics 8/8, control 4/4, simulink 4/4.
Robotics System Toolbox is fully present (`rigidBodyTree`,
`inverseKinematics`, `generalizedInverseKinematics`, `rotm2quat`, all OK);
note `ikunc` no longer exists in this release and was replaced in the probe
list. No domain needs a licence-SKIP for tool-level work; hardware/ROS/SLAM
remain unavailable and stay SKIP at Agent level.

## Verdict

All seven Task 0 checks pass; the one `mas_skill_graph` duplication finding
pre-dates Phase 5.2 and is recorded as a residual. The verified Phase 5.2
changes are committed in an independent commit on `phase5.1-audit`, with
before-fix failure evidence force-added from `artifacts/phase52/` (artifacts
are gitignored; only the evidence files listed in the commit are tracked).
No push, no merge, `main` untouched.