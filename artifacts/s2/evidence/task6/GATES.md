# S2 Task 6 — quality gates (final code)

- Branch: `phase5.1-audit`
- HEAD: `876a2b0c67dae275c199415752226ed71c9c344f`
- Working tree: 32 changed paths, no commits made
- Gate date: 2026-10-26
- Code state: final S2 payload (`McpProbe.psm1` SHA-256 `ACE784F5...83CA59`)

## PASS

| Gate | Result | Evidence |
| --- | --- | --- |
| S1 credential sanitizer (Windows PowerShell 5.1) | 11 / 11 | `s1-credential-final` |
| S1 credential sanitizer (PowerShell 7.6.9) | 11 / 11 | `s1-credential-final-pwsh7` |
| S1 credential output protection (5.1) | 5 / 5 | `s1-mcpcred-final` |
| S1 credential output protection (7.6.9) | 5 / 5 | `s1-mcpcred-final-pwsh7` |
| McpProbe suite (5.1) | 14 / 14 | `mcpprobe-final-ps51` |
| McpProbe suite (7.6.9) | 14 / 14 | `mcpprobe-final-pwsh7` |
| Pester free layer (5.1) | 352 / 353 | `free-ps51-final`, `core-suite-final.console.txt` |
| Pester free layer (7.6.9) | 352 / 353 | `free-pwsh7-final`, `core-suite-final-pwsh7.console.txt` |
| MATLAB skill regression | 1127 / 1127 | `matlab-regression-final/s2_regression_final_20261026_134856.stdout.log` |
| MATLAB reference / cross-domain / pipeline | 15/15, 15/15, 15/15 | same run, 32 suites, `allOk=1` |
| Nine-Skill routing | 7 prompts ROUTE with expected primary + runner | `matlab-logs/s2_task6_consistency_20261026_133710.*` |
| Capability matrix consistency | 5 checks, `verdict=CONSISTENT` | same consistency run |
| Independent install acceptance A–J | 10 PASS / 0 FAIL / 0 SKIP | `../acceptance/20261026-134858/` |
| Installed resource parity | 119 files, 0 hash failures, 0 forbidden | `../acceptance/20261026-134858/B-installed-sha256.json` |
| Repeat install zero-write | unchanged=9, diff=0 | `../acceptance/20261026-134858/F-repeat.summary.json` |
| Failed upgrade rollback | restored=True, diff=0, staging=0 | `../acceptance/20261026-134858/G-upgrade.summary.json` |
| S1 protection in installed layout | 21 scanned, 0 leaks | `../acceptance/20261026-134858/H-credential-scan.json` |
| No new S2 drive-path violations | 21 S2 files, 0 hits | `s2-drive-path-scan.json` |

The two full-layer runs execute the same 353 tests. The single failure is the
pre-existing repository-hygiene gate; details below.

## FAIL (pre-existing, not introduced by S2)

| Failure | Result | Evidence |
| --- | --- | --- |
| “仓库里没有盘符硬编码路径（E 盘 / D 盘）” | 77 hits / 449 files | `core-suite-final.console.txt`, `core-suite-final-pwsh7.console.txt` |

- The hit set is byte-identical between the PS 5.1 and PS 7 runs and across
  earlier S2 runs: 77 unique `file:line` entries, 449 scanned files.
- None of the 77 hits is in an S2 changed or new file. The dedicated scan of all
  21 S2-only paths reports 0 hits (`s2-drive-path-scan.json`).
- The failure is therefore recorded as pre-existing and unchanged, not waived,
  deleted, or relaxed.

## SKIP

| Item | Reason |
| --- | --- |
| `mcp.matlab-license` | The probe only starts MATLAB to verify the license when `-VerifyLicense` is passed; no license claim is made. |
| `mcp.readonly-exec` / `mcp.file-io` | Upstream protocol handshake did not succeed, so L3/L4 are marked SKIP rather than fabricated PASS. |

## BLOCKED (real MCP execution)

The installed probe runs from an isolated install and produces a staged verdict,
but real L3/L4 execution is not achieved.

- Default probe (`../acceptance/20261026-134858/D-probe.report.json`):
  `mcp.matlab-install=PASS`, `mcp.session-config=PASS`,
  `mcp.protocol-handshake=FAIL` with a TLS trust error, L3/L4 SKIP,
  `overall=FAIL`, `achieved=L0`.
- Loopback smoke from the installed Skill with the documented
  `-SkipTlsValidation` option (`real-mcp-smoke/probe.json`):
  handshake reaches HTTP 403 (authentication rejected by the server),
  L3/L4 SKIP. No credential value appears in the evidence.
- Session metadata: `sessionDetails.json` parses, PID 7008 is alive, port 31519
  is reachable. The current credential/TLS trust is not accepted by the live
  server. Resolving this requires an operator action (restart the MCP session
  and/or rotate the credential), which is outside S2 and was not attempted.
- Consequence: **S2 does not claim real MATLAB MCP execution.** The probe path,
  resource closure, and staged failure reporting are verified; L3/L4 remain
  BLOCKED by environment authentication/trust.

## Notes

- `Invoke-MatlabBatch.ps1` reports `error_class=CODEGEN_ERROR` on successful
  runs (`exit_code=0`). This is a pre-existing classifier quirk, recorded as a
  note, not as a math or delivery failure.
- PowerShell 7 JSON parsing of configs with case-variant keys was fixed by the
  `System.Text.Json.JsonDocument` fallback and pinned by a new regression test.
