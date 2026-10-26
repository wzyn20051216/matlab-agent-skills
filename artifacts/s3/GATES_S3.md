# S3 quality gates — real MCP unblock (final code)

- Branch: `phase5.1-audit`
- Pre-approval HEAD: `876a2b0c67dae275c199415752226ed71c9c344f`
- Landing commit: `3379067a3d383bf282b5a9087f1126fd12c8dc43` — one commit on this branch after explicit
  user approval ("提交到当前分支，暂不推送"). 551 files, +86389/−275, clean work tree afterwards,
  **not pushed**, `main` and existing Releases untouched. See report §11.6 for the pre-commit credential scan.
- Gate date: 2026-10-26 (rows marked *final* re-measured 21:20–21:34 after the §11.1 ownership fix)
- Supersedes the BLOCKED section of `artifacts/s2/evidence/task6/GATES.md` for the
  real-MCP item only. The S2 file itself is frozen evidence and was not rewritten;
  a dated pointer was appended to `artifacts/s2/S2_FINAL_REPORT_ZH.md`.
- Report: `artifacts/s3/S3_FINAL_REPORT_ZH.md`

## PASS

| Gate | 5.1 | 7.6.9 | Evidence |
| --- | --- | --- | --- |
| Installed-copy probe, `-Transport auto`, no `-SkipTlsValidation` | `overall=PASS achieved=L4 exit=0`, 7/7 checks PASS | same | `installed-5.1-auto-existing.report.json`, `installed-7-auto-existing.report.json` |
| L2 handshake over stdio | PASS, `serverRelease=v0.15.0`, `VERIFIED_AGAINST_MANIFEST` | same | both reports above |
| L3 readonly exec via `evaluate_matlab_code` | real `"26.1.0.3276743 (R2026a) Update 3"` | same | both reports above |
| L4 file-io token round-trip | `hostVerified=true`, token `cbc09a86…` | `hostVerified=true`, token `c7d1e27e…` | both reports above |
| Licence upgraded by real execution | `PASS provenBy=mcp.readonly-exec` | same | both reports above |
| Payload SHA-256 parity vs repo source | all targets `matchesSource=true` | same | `installed-*.json` (`payload` block) |
| Pester free layer | 366 / 367 | 366 / 367 | `free-layer.{json,log}`, `free-layer-ps7.{json,log}` |
| Pester free layer (final, after the ownership fix) | 378 / 379 | 378 / 379 | `green/free-layer-final.{json,log}`, `green/free-layer-final-ps7.{json,log}` |
| ProcessCleanup incl. the 12 new session-runtime ownership cases | 36 / 36 | 36 / 36 | `green/session-ownership.json`, `green/session-ownership-ps7.json` |
| Installed-copy probe re-run on final code (`-ProbeProjectRoot D:\Temp\mas-s3-project`) | `PASS L4 exit=0`, 7/7 | `PASS L4 exit=0`, 7/7 | `final/installed-5.1-auto-existing.report.json`, `final/installed-7-auto-existing.report.json` |
| Live process-tree ownership predicate, read-only (`ReportOnly`, nothing terminated) | 42956 `ALLOW hops=2`, 15392 `ALLOW hops=1`, control 6288 `SKIPPED_IDENTITY_MISMATCH` | n/a (run on 5.1) | `green/session-ownership-live-reportonly-v2.json` |
| Stale `session_ready.json` verified read-only, byte-for-byte unchanged | size/mtime/SHA-256 identical before and after; `EXPIRED_INFERRED` + `KEEP_UNCHANGED` | n/a | `session/stale-session-ready-verification-v2.json` |
| McpProbe suite | 23 / 23 | 23 / 23 | `mcpprobe-ps51.json`, `mcpprobe-ps7.json` |
| McpStdio suite | 5 / 5 | 5 / 5 | `green/stdio-ps51.json`, `green/stdio-ps7.json` |
| SkillPayload contract + install | 22 / 22 | — | `green/payload-contract.json`, `green/payload-install.json` |
| Independent install acceptance A–J | 10 PASS / 0 FAIL / 0 SKIP | 10 PASS / 0 FAIL / 0 SKIP | `s2-acceptance-5.1/`, `s2-acceptance-7/` |
| Installed resource parity | 123 files, 0 failures, 0 forbidden | same | `*/B-installed-sha256.json` |
| S1 protection in installed layout (phase H) | 21 scanned, 0 leaks | same | `*/H-credential-scan.json` |
| Credential rotation / invalidity record | exposed value absent, replacement issued | n/a | `credential_rotation.json`, `apikey_leak_scan.json` |
| Repo-wide credential scan | 3878 files, 17 shaped hits, 0 matching exposed value | n/a | `apikey_leak_scan.json` |
| End-to-end ladder from repo scripts | L0 (see FAIL below) | `PASS L5`, 6/6 | `e2e-existing/report.json`, `e2e-existing-ps7/report.json` |
| No orphan MCP server processes | only the 4 pre-existing 11:32 processes remain | same | process listing recorded in §8 of the report |

## FAIL (kept, not waived)

| Failure | Verdict | Real reason (verbatim from evidence) |
| --- | --- | --- |
| HTTPS transport, pinned loopback certificate (`installed-5.1-https-existing`) | `overall=FAIL achieved=L0` | `HTTP 403（远程服务器返回错误: (403) 已禁止）`, `tlsMode=pinned`, `tcpReachable=true` — 403 is the official connector's designed behaviour for direct HTTPS, not a wrong key |
| Installed copy with no client registration, no env var, no `-ServerExe` (`installed-installed-5.1-auto-existing`) | `overall=FAIL achieved=L0` | `没有发现可通过清单校验的 matlab-mcp-server（已尝试：core-candidates）`, then HTTPS 403 |
| PS 5.1 stdio channel before the S3 fix (`e2e-existing`) | `mcp.server-start FAIL` | `无法启动stdio 服务器：在此对象上找不到属性“StandardInputEncoding”` — red baseline kept, fixed by S3-T2, superseded by the L4 installed-copy runs |
| Re-run of the installed copy with `-ProbeProjectRoot` omitted (21:28, operator invocation error) | `overall=FAIL achieved=L0 exit=1` | `未发现包含 'matlab-official' 的有效注册（检查 Codex / Claude / VS Code / .mcp.json）`, then `没有发现可通过清单校验的 matlab-mcp-server（已尝试：core-candidates）`, then HTTPS 403. Payload hashes and the other four recorded driver inputs match the L4 runs, so this is an invocation difference, not a product regression; evidence kept at `final/attempt1-invocation-error/`. |
| 仓库里没有盘符硬编码路径（E 盘 / D 盘） | 1 failure per host, identical hit set | pre-existing repository-hygiene gate; **78 hits over 449 scanned files (31 files)**, hit set byte-identical across both hosts and identical to the pre-fix runs; no new violation introduced by S3 |

## SKIP (rule-driven, not fabricated PASS)

| Item | Reason |
| --- | --- |
| `-Transport stdio` with explicit `-ServerExe` only | `mcp.client-registration=SKIP`, so the documented continuity rule caps `achievedLevel` at L1 even though `mcp.protocol-handshake`, `mcp.readonly-exec` and `mcp.file-io` each PASS. The rule in `scripts/MatlabAgentSkills.Acceptance.psm1` was not relaxed; the registration-based `auto` run is what earns L4. |
| `mcp.matlab-license` without `-VerifyLicense` | remains SKIP until stage 4 really executes; promoted to PASS only via `provenBy=mcp.readonly-exec` |
| Downstream stages of a failed upstream stage | marked SKIP with `上游阶段未通过`, never continued as if it had succeeded |

## Deliberately not done

- No `-SkipTlsValidation`, no accept-all certificate callback, no system trust-store change, no C: or system configuration change.
- No real user-level Skills directory touched (`~/.qoder-cn/skills` still 2026-10-21 13:42).
- No credential value printed, copied into a fixture, or used against an external service; no external rotation call.
- No history deleted or rewritten: S2 frozen evidence, S1 traces, and every red run above remain in place.
- No push, merge, rebase, reset or clean. No commit was made while the work awaited review; the single
  landing commit above exists only because the user explicitly approved committing on this branch without pushing.
- The MATLAB session started by this work was **kept running on purpose**: pid 15392 (headless shared session,
  port 31519, 600 s keep-alive timer) and its child pid 42956 (port 31520, the session named by
  `sessionDetails.json`). It is still the advertised live session and the final L4 gates above ran through it.
  Closing a live session is the user's decision; the release procedure for a human is recorded in
  `green/session-ownership-live-reportonly-v2.json` (`stopProcedure`).
  The original `session_runtime_not_owned` record (`evidence/session/provenance_correction.json`) was produced by
  the old direct-parent-only predicate and is kept unedited; the predicate was fixed in S3-T7, and terminating the
  processes was still refused because that run left no `owner-<runid>.json` on disk — rebuilding one after the fact
  is exactly the retrospective authority the fail-closed invariant forbids.
- That same file carries a **withdrawn basis**: `credential_rotation.json` had cited "port 31519 reused by an
  unrelated MATLAB process" as support for the exposed credential being invalid. Process-tree review shows the
  new owner is this run's own session, so the basis is withdrawn. The two remaining bases (minting process
  7008 exited; descriptor no longer carries the value) are unaffected, and the original evidence file was
  not edited.
