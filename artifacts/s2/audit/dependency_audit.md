# S2 Task 1 — Skill resource dependency audit

- Repository: `E:\desktop\MATLAB`
- Branch: `phase5.1-audit`
- HEAD: `876a2b0c67dae275c199415752226ed71c9c344f`
- S1 workspace: verified unchanged against `artifacts/s2/baseline/s1_manifest.json` (14 files, all SHA-256 match).
- Audit date: 2026-10-26

## 1. Root cause

`skills/matlab-runner/SKILL.md` and `skills/matlab-orchestrator/SKILL.md` tell the
agent to run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabMcpExistingSession.ps1 -Json
```

The installer (`scripts/Sync-Skills.ps1` → `Sync-SkillDirectory`) copies only the
contents of each `skills/matlab-*` directory. Repository-level `scripts/` and
`schemas/` are never copied. Therefore the installed skill has no `scripts/` probe,
and the relative command can only succeed by leaving the installed skill and
reading the developer repository. That is exactly the Phase 5.8 defect.

Secondary defects found in the same class:

- `Test-MatlabMcpExistingSession.ps1` derives `$repoRoot` from its own parent and
  writes `artifacts/validation` under it. Installed at `<skill>/scripts/`, it would
  write into the installed skill directory, changing its managed hash.
- `Get-McpClientRegistrations` and the license probe use `RepositoryRoot`; the
  wrapper passed the skill's parent, not the user's project root.
- The skill docs use `.\scripts\...`, so they only work when the caller's cwd is
  the repository root.
- `matlab-runner/references/acceptance-levels.md` points at a nonexistent
  `matlab-codegen-deploy/references/stm32-deployment-chain.md`.
- `matlab-runner/references/mcp-readiness-ladder.md` points at repository-only
  `docs/MATLAB_DESKTOP_STARTUP_ZH.md` and `scripts/Start-MatlabDesktop.ps1`.
- Several `.m` scripts under the skills derive the repository root with
  `fileparts(fileparts(fileparts(here)))` and read repository-only data
  (`evals/`, `matlab/boost`, `skills/capability-matrix.json`, `schemas/`,
  `artifacts/`). These are recorded as known unresolved dependencies in section 5;
  they are not part of the installed MCP probe path.

## 2. Actual MCP probe dependency closure

| File | Bytes | SHA-256 (at audit) | Required by |
| --- | ---: | --- | --- |
| `scripts/Test-MatlabMcpExistingSession.ps1` | 3,887 | `424053c473624703725aa71db6e0894108ef2280d05361ced56f58422d16c621` | entry point |
| `scripts/MatlabAgentSkills.Acceptance.psm1` | 42,653 | `051db1dad6a6c49b481e50611b2fddc896ab66357c2911974614d70018054d41` | imports at probe line 43; report construction |
| `scripts/MatlabAgentSkills.Execution.psm1` | 29,085 | `34d4a898575f9d30669293404a56ab904c348db457a5cc12cf27003c4b88246a` | imports at probe line 44; MATLAB resolution and batch process |
| `scripts/MatlabAgentSkills.McpProbe.psm1` | 43,805 | `1bf95a5bbad2996f563fa2c7042fdae0c3dee1564b2060027737c83910d396b4` | imports at probe line 45; staged probe and JSON-RPC |
| `scripts/MatlabAgentSkills.Core.psm1` | 88,231 | `a7d405df925a2852d685f406a6b58ab76943a5661b71ebc92f191e2e35ff0476` | imported by McpProbe line 23 and Execution line 244; `Get-FileSha256`, `Test-McpServerArgsCompatible`, `Protect-MasText` |
| `schemas/acceptance-report.schema.json` | 9,689 | `47ddf8200e8a93cda93db38ea710369c080b11ad6429781dd64199f784fbf947` | `Test-AcceptanceReport` / `Test-MatlabSkills` contract validation; not called by the probe's default write path |

The Phase 5.8 evidence listed five files and omitted `Core.psm1`. The isolated
ladder in `artifacts/s2/pre-fix/evidence/closure_ladder.json` shows the actual
runtime order:

1. probe only → `Acceptance.psm1` missing;
2. + Acceptance → `Execution.psm1` missing;
3. + Execution → `McpProbe.psm1` missing;
4. + McpProbe → `Get-FileSha256` not recognized (Core missing);
5. + Core → probe runs and writes a report;
6. + schema → probe result unchanged.

`Invoke-MatlabBatch.ps1` is also declared by `matlab-runner` and needs
`Execution.psm1`, `Acceptance.psm1`, and `Core.psm1` — all already in the closure.

`Setup-MatlabMcpExistingSession.ps1`, `Test-MatlabSkills.ps1`, and
`Start-MatlabDesktop.ps1` are developer-repository operations. They are not part
of the installed probe closure and are documented as repository-only rather than
silently shipped with incomplete dependencies.

## 3. Installer behavior

- `Sync-Skills.ps1:94` enumerates `skills/matlab-*` directories.
- `Sync-SkillDirectory` (`scripts/MatlabAgentSkills.Core.psm1:1426`) copies the
  whole source directory, compares directory-tree hashes, backs up before update,
  stages into `.__incoming__<guid>`, and restores missing files on failure.
- There is no payload manifest and no support for repository-level files.
- `Remove-Skills.ps1` removes only manifest-owned directories whose hash still
  matches, so files written into an installed skill by the probe would make the
  skill non-removable.
- `Bootstrap-MatlabAgentSkills.ps1` delegates to `Sync-Skills.ps1` with
  `-RepositoryRoot`, so an install-time payload mechanism also works for the
  one-shot bootstrap path.

## 4. Nine-skill scan (summary)

Runtime-critical repository references are concentrated in:

- `matlab-runner`: probe, batch wrapper, setup, smoke test, `matlab/boost` model
  example, acceptance report path.
- `matlab-orchestrator`: probe, acceptance report path, schema path.
- `matlab-codegen-deploy`: `matlab -batch "test_codegen(true)"` requires cwd =
  the skill's `tests/`; an STM32CubeMX path is a machine-specific example.
- `matlab-simulink-modeling`: sibling `../matlab-runner/...` reference; repo
  `matlab/boost` model example; `C:\codex_build\...` example.
- `matlab-testing-ci`, `matlab-control-optimization`, `matlab-data-analysis`,
  `matlab-robotics-autonomy`, `matlab-signal-vision-ai`: their `.m` tests derive
  the repo root by fixed-depth `fileparts`; the docs cite those tests as evidence,
  not as installed commands. `matlab-control-optimization` also has a sibling
  dependency on `matlab-testing-ci/scripts` (`mas_grade`).

No committed duplicate of the probe exists under `skills/`; the payload must be
generated at install time from the canonical `scripts/` sources.

## 5. Known unresolved dependencies (reported, not silently fixed)

These are outside the S2 minimal fix. They are recorded so the final report does
not claim full self-containment for every `.m` helper:

- `skills/matlab-testing-ci/scripts/mas_verify_task.m:25-26`,
  `mas_refcheck.m:39-40`, `mas_phase43_grade.m:11-18`, `mas_bench_record.m:42-44`,
  `mas_skill_audit.m:41-43`, `mas_capability_check.m:33-35` read repository
  `evals/`, `artifacts/`, `skills/capability-matrix.json`, or `bin/`.
- `skills/matlab-testing-ci/scripts/mas_ref_derive.m:310-311` adds
  `matlab/boost`.
- `skills/matlab-orchestrator/scripts/mas_pipeline.m:54-62` adds sibling skills,
  `matlab/validation/crossdomain`, and its task directory.
- All `.m` test suites derive the repo root with three or four `fileparts` calls;
  they run in the repository, not from an installed skill.

Fixing these requires shipping evaluation data, MATLAB models, or restructuring
skill-local roots. That is a larger resource/install-manifest change than S2's
MCP probe closure and is left for review as an S3 candidate.
