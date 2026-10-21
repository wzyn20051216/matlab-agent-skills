# MATLAB 官方 MCP 自动会话工作流

这套仓库现在默认 **优先走 MATLAB 官方 MCP auto 模式**，目标不是手工运行 `shareMATLABSession()` 或频繁切到 `MATLAB -batch`，而是让代理自动拉起或复用 MATLAB 桌面会话。

这样做有三个直接好处：

- `Simulink` 建模、连线、调参、仿真过程可以直接在桌面里可视化；
- AI 可以在同一会话里连续修改模型、读取结果、再迭代，而不是每轮都重启 MATLAB；
- 更适合控制系统、嵌入式部署、模型驱动开发这类需要“反复观察 + 快速调整”的任务。

## 默认模式

- **默认**：官方 `MCP auto`
- **可复用已有桌面 MATLAB**：若已有共享会话，auto 会优先复用
- **仅在用户明确要求时才允许**：仓库内 `Invoke-MatlabBatch.ps1` 批处理包装

也就是说：

1. Codex 调用 MATLAB 官方 MCP server；
2. MCP server 优先尝试连接已有共享 MATLAB 会话；
3. 若找不到共享会话，则自动按配置启动可见 MATLAB 桌面；
4. 只有当用户明确要求 headless / CI / batch 时，才允许走 `batch`。

## 一键配置

先准备好官方二进制：

- `matlab-mcp-server-windows-x64.exe`

然后执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Setup-MatlabMcpExistingSession.ps1 `
  -McpServerName matlab-official
```

说明：

- `ServerExePath` 和 `MatlabRoot` 现在默认会自动发现
- 只有自动发现失败时，才需要你手动传路径

这个脚本会做四件事：

1. 安装 `MATLAB MCP Server Toolbox`
2. 修正 `%APPDATA%\MathWorks\MATLAB MCP Server` ACL
3. 可选写入 `startup.m`，让 MATLAB 启动时自动共享会话
4. 把官方 MCP server 注册到 `Codex`（仅在检测到 `codex` 命令时执行；未安装则告警跳过，不影响前三步）

## 一句命令接入客户端

如果你希望开源项目用户一句命令就完成下载、skills 同步和 MCP 客户端接入，直接执行：

```powershell
irm https://raw.githubusercontent.com/wzyn20051216/matlab-agent-skills/main/scripts/Bootstrap-MatlabAgentSkills.ps1 | iex
```

如果你已经在本地仓库内，只想接入客户端，可以执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Install-MatlabMcpClients.ps1 `
  -Clients codex,claude
```

这个脚本会：

1. 先完成 MATLAB MCP 基础配置；
2. 自动把 `matlab-official` 注册到 `Codex`；
3. 自动把 `matlab-official` 注册到 `Claude Code`。

如果使用：

```powershell
-Clients auto
```

脚本会自动：

- 检测本机是否安装 `Codex`
- 检测本机是否安装 `Claude Code`
- 同时在当前目录写入通用 `.mcp.json`

如果要写入项目级 `VS Code` MCP 配置：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Install-MatlabMcpClients.ps1 `
  -Clients vscode `
  -ProjectPath .
```

生成的配置文件在：

```text
.vscode/mcp.json
```

## 客户端说明

- `Codex`：支持命令行一键注册
- `Claude Code`：支持命令行一键注册
- `VS Code`：支持一键写入项目级 `mcp.json`
- `Generic MCP clients`：支持一键写入通用 `.mcp.json`
- `Claude Desktop`：建议优先使用 MathWorks 官方发布的 `.mcpb` 或按同样参数手动导入

## 会话验证

打开 MATLAB，执行一次 `shareMATLABSession()`，然后运行分阶段探测：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabMcpExistingSession.ps1
```

成功后会生成：

```text
artifacts/validation/matlab_mcp_existing_session_probe.json
artifacts/validation/acceptance/mcp_probe.json
```

### 为什么不再有 ready / autoModeReady

旧版本输出的 `ready` 与 `autoModeReady` 是靠 `sessionDetails.json` 里的 `pid` 和配置字符串推断出来的，**没有真的连过 MCP server**。这两个字段已经删除，因为它们给出的是"配置看起来对"，而不是"现在能用"。

现在改成五个阶段，每段单独判定，任何一段失败都不会让后面的阶段假装成功：

| 检查项 | 等级 | 判定依据 |
| --- | --- | --- |
| `mcp.matlab-install` | L1 | 能解析到 MATLAB 可执行文件并读到 `VersionInfo.xml` |
| `mcp.matlab-license` | L1 | 默认 SKIP；只有 `-VerifyLicense` 或阶段 4 真实执行成功才升级为 PASS |
| `mcp.session-config` | L1 | `sessionDetails.json` 可解析、证书文件存在、端口合法 |
| `mcp.client-registration` | L2 | 客户端注册参数不含 `display-mode`，`command` 真实存在 |
| `mcp.protocol-handshake` | L2 | TCP 可连且 `initialize` 返回合法 `result` |
| `mcp.readonly-exec` | L3 | 通过 `tools/call` 真实执行只读命令，输出匹配版本号 |
| `mcp.file-io` | L4 | 在隔离目录写入令牌再读回，内容一致 |

只看最后一行即可：

```text
==> overall=SKIP achievedLevel=L0 pass=1 fail=0 skip=6
```

`overall=PASS` 才是真的可用。`overall=SKIP` 表示有检查项没执行（缺许可证、缺会话、缺工具），`overall=FAIL` 表示执行了但结果不对。退出码分别是 `0` / `3` / `1`。

### 常见失败与对应原因

`mcp.session-config` 报"会话证书不可读"：

```text
会话证书不可读（...\cert.pem）：通常意味着会话已失效，需要重新 shareMATLABSession()
```

这是最常见的情况：`sessionDetails.json` 是上一次会话留下的，证书文件早已不在，`pid` 也不指向活着的进程。旧版本会把这种状态报成 `ready = true`。修复方式是在 MATLAB 命令行再执行一次：

```matlab
shareMATLABSession()
```

`mcp.protocol-handshake` 报 `HTTP 401`：密钥不匹配。`reason` 会同时给出状态码和 JSON-RPC 错误体，便于区分"服务没起"（TCP 连不上）和"密钥错"（401）。

`mcp.readonly-exec` 为 SKIP 且 `metrics.tools` 里没有执行类工具：服务端只暴露了工作区检查之类的工具，握手成功并不代表能执行 MATLAB 代码。

## Skills 默认策略

从现在开始，这个仓库里的 MATLAB skills 默认遵循：

1. **先走 MCP auto**
2. **优先复用已有共享 MATLAB/Simulink 桌面**
3. **没有共享会话时允许 MCP 自动启动 MATLAB 桌面**
4. **如果 MCP 有问题，直接暴露问题，不要悄悄切 batch**
5. **只有用户明确要求时，才允许 batch**

## 适合走 MCP 的任务

- `Simulink` 自动建模
- `PID`/控制器参数自动调节
- 连续仿真与结果读回
- 模型拓扑检查与修改
- 在桌面 MATLAB 中做可视化演示

## 适合显式走 batch 的任务

- CI / GitHub Actions
- 纯命令行烟雾测试
- 批量导出图表/数据
- 不依赖桌面可视化的可重复验证

## 安装器安全行为（第一阶段 P0 重构）

安装脚本现在默认安全：所有写操作都可预演、都有备份、失败会回滚。

```powershell
# 只看计划，不写任何文件
powershell -ExecutionPolicy Bypass -File .\scripts\Install-MatlabMcpClients.ps1 `
  -Clients auto -DryRun

# 只配置 Claude Code（不需要安装 Codex）
powershell -ExecutionPolicy Bypass -File .\scripts\Install-MatlabMcpClients.ps1 `
  -Clients claude

# existing 模式下不要传 display-mode：脚本会自动省略并告警
powershell -ExecutionPolicy Bypass -File .\scripts\Install-MatlabMcpClients.ps1 `
  -SessionMode existing -Clients codex
```

要点：

1. `existing` 模式不会再生成 `--matlab-display-mode` / `--matlab-root` / `--initialize-matlab-on-startup`（官方参数约束）。
2. `.mcp.json`、`.vscode/mcp.json` 采用合并写入，用户其它 server 配置保留；文件 JSON 语法错误时直接中止。
3. Codex / Claude 注册参数一致时完全不动；需要变更时先存快照，失败自动还原。
4. `startup.m` 用托管标记块包裹，重复执行不会重复追加，也不会覆盖你自己写的钩子。
5. ACL 改为“给当前用户追加授权”，不再剥离继承；需要旧行为时加 `-RestrictAclInheritance`。
6. 备份目录默认 `artifacts/backups/<时间戳>-<动作>/`，内含 `manifest.json` 记录每次改动。

