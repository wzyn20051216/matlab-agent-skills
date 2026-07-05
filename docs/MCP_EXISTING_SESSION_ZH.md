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
4. 把官方 MCP server 注册到 `Codex`

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

打开 MATLAB 之后，执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabMcpExistingSession.ps1
```

成功后会生成：

```text
artifacts/validation/matlab_mcp_existing_session_probe.json
```

如果 `ready = true`，说明当前桌面 MATLAB 会话已可供官方 MCP 接管。  
如果 `autoModeReady = true`，说明就算当前没有共享会话，Codex 也已经具备自动启动 MATLAB 的配置条件。

如果 `ready = false`，但你明明已经打开了 MATLAB，最常见原因是：

- `sessionDetails.json` 里记录的是旧 `pid`
- 当前桌面 MATLAB 还没有重新共享

这时直接在 MATLAB 命令行执行一次：

```matlab
shareMATLABSession()
```

然后重新运行验证脚本即可。

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
