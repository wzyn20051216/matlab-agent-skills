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
powershell -ExecutionPolicy Bypass -File $skillRoot\scripts\Test-MatlabMcpExistingSession.ps1 -ProjectRoot (Get-Location).Path -Json
```

| Stage | Check id | Level | Proves |
|---|---|---|---|
| 1 | `mcp.matlab-install` | L1 | MATLAB executable resolved, `VersionInfo.xml` readable |
| 2 | `mcp.matlab-license` | L1 | license usable (SKIP by default, `-VerifyLicense` to force) |
| 2 | `mcp.session-config` | L1 | session JSON parses, certificate exists, port valid |
| 2 | `mcp.client-registration` | L2 | client args have no `display-mode`, `command` really exists |
| 3 | `mcp.protocol-handshake` | L2 | `initialize` returns a valid `result` on the live channel |
| 4 | `mcp.readonly-exec` | L3 | a read-only command really executed through `tools/call` |
| 5 | `mcp.file-io` | L4 | token written to an isolated dir and read back identical |

## Transport

`-Transport` selects how stages 3–5 reach MATLAB: `auto` (default) | `stdio` | `https`.

- **`stdio` is the only path the official server supports.** The probe starts the
  official `matlab-mcp-server` as a child process and speaks newline-delimited JSON-RPC
  over its stdin/stdout. The binary must already exist on the machine and must match
  `config/mcp-server-manifest.json` (SHA-256); the probe never downloads one. Search
  order: `-ServerExe` (then nothing else — an explicitly named binary that fails
  verification is reported, not silently replaced) → `MATLAB_MCP_SERVER` → the `command`
  of a registered client → the fixed candidate paths.
- **`https` is observation only.** Direct `POST /mcp` against the MATLAB connector
  returns `403` for every authentication header style on R2026a — that is the
  connector's design, not a misconfiguration on your side. Do not conclude "the key is
  wrong" from a 403, and do not treat a 403 as a handshake failure of the Skill.
- **Never start with `-SkipTlsValidation`.** The connector certificate is self-signed
  with `CN=127.0.0.1` and no SAN, so a trust-store check fails by construction. The probe
  pins the certificate fingerprint declared by the session descriptor for loopback only;
  `-SkipTlsValidation` replaces that with a process-wide accept-all callback, which is
  why it is opt-in and why a run that needs it is not a pass.
- `-Transport stdio` does not fall back to `https`. If the stdio channel cannot be
  built, stages 3–5 are SKIP with the real reason (`missing binary`, `HASH_MISMATCH`,
  `会话证书无法解析出指纹`, …) — a fallback would describe our own misconfiguration as
  "the connector returned 403".


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

`Setup-MatlabMcpExistingSession.ps1` is a repository-only developer operation for
maintainers of the source repository. It is **not shipped** inside the installed
Skill. An installed user configures the official MATLAB MCP entry through their MCP
client and then runs the shipped probe above; do not ask them to find a development
checkout, and do not scan for a similarly named script elsewhere on disk.

## 自动打开可见 MATLAB 桌面

仓库开发者辅助脚本 `scripts/Start-MatlabDesktop.ps1`（**不随 Skill 安装**）用于
维护者复现可见桌面启动流程，不属于安装后流程：优先复用匹配的现有共享运行时及
桌面窗口；没有 MATLAB 时自动经 Windows Shell 打开可见桌面，等待本次唯一
receipt，再重建官方 stdio `auto` 连接并用真实工具执行验证。
如存在未就绪实例，先读报告决定是否用 `-NewSession` 另开，不关闭用户原会话。
`REUSED_EXISTING` 不计作新启动；仅 `newSessionVerified=true` 且启动前没有
MATLAB 进程时才可记录 `coldStartVerified=true`。端口、PID 或 receipt 单独成立
都不能替代 MCP 执行验证。
需要精确复现手动入口时可用 `-LaunchMode Shortcut`；候选返回后，用官方 MCP 执行
报告指定的 `mcpCodeFile`，再以 `-ConfirmReport` 核对回执。候选本身不算启动成功。
可显式用 `-LaunchMode ComDesktop` 由独立 STA holder 激活已注册的可见桌面并保留 COM 引用；
共享 COM 返回旧 PID 时为 `NOT_NEW`，不会重写该用户会话或算作新启动。
holder 就绪后仍须重建官方 stdio `auto` 并验证实际执行；还需在启动工具退出后复核持续存活。
