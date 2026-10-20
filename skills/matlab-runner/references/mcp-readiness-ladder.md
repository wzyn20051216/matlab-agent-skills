# MCP readiness ladder

Loaded on demand by `matlab-runner`. The Agent does not need this table unless it is
about to claim MCP is ready — which is exactly the claim that must not be made from
a config file.

## A config check is not a readiness check

A `sessionDetails.json` on disk, a listening PID, or a client entry in `.mcp.json`
all look identical to a file-existence test and all prove nothing about whether a
tool call will work. There are at least five distinct states, and only the fourth
means "usable":

| # | State | Looks fine? | Actually means |
|---|---|---|---|
| 1 | server process not running | yes | nothing is listening |
| 2 | process running, wrong port | yes | the client will connect to the wrong thing |
| 3 | handshake rejected | yes | auth or protocol mismatch |
| 4 | handshake OK, `tools/call` fails | **yes** | the only state a config check cannot detect |

## The ladder

Run the staged probe and read its verdict, never a file listing:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabMcpExistingSession.ps1 -Json
```

| Stage | Check id | Level | Proves |
|---|---|---|---|
| 1 | `mcp.matlab-install` | L1 | MATLAB executable resolved, `VersionInfo.xml` readable |
| 2 | `mcp.matlab-license` | L1 | license usable (SKIP by default, `-VerifyLicense` to force) |
| 2 | `mcp.session-config` | L1 | session JSON parses, certificate exists, port valid |
| 2 | `mcp.client-registration` | L2 | client args have no `display-mode`, `command` really exists |
| 3 | `mcp.protocol-handshake` | L2 | TCP reachable and `initialize` returns a valid `result` |
| 4 | `mcp.readonly-exec` | L3 | a read-only command really executed through `tools/call` |
| 5 | `mcp.file-io` | L4 | token written to an isolated dir and read back identical |

## Rules that must not be relaxed

- **Only stage 4 passing upgrades `mcp.matlab-license` from SKIP to PASS**, and the
  evidence (`provenBy = mcp.readonly-exec`) is recorded in `metrics`. A licence that
  has merely not been tested is SKIP, never PASS.
- **A failed stage makes every later stage SKIP** with reason "upstream not passed".
  Never continue as if the earlier stage had succeeded — this is how a broken
  session produces a report full of unexplained later failures.
- **An HTTP error must keep both the status code and the JSON-RPC error** in
  `reason`. A bare `unauthorized` string hides the difference between "the server
  is down" and "the key is wrong", which have opposite fixes.

## Decision rule for this machine

1. Prefer official MATLAB MCP auto mode, so the server reuses an existing shared
   session or starts MATLAB automatically.
2. Stay on MCP when the task needs repeated model edits, parameter sweeps with live
   inspection, or anything user-visible on the desktop.
3. Reserve `matlab -batch` for explicit requests: CI, headless smoke tests,
   reproducible one-shot runs.
4. If MCP is unavailable, **report the blocker**. Do not silently change execution
   mode — a batch rerun that succeeds hides the problem the user needs to see.

## Setup

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Setup-MatlabMcpExistingSession.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabMcpExistingSession.ps1
```