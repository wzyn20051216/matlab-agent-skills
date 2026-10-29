# 故障排查（Windows 技术预览）

本文只写**已实测**的失败模式与处理办法；没验证过的不写"应该能行"。

## 安装类

**本地是旧副本 / 9 个技能内容很旧**
`main` 自 2026-10-21 起就是通过验收的版本（`44052fd`），默认克隆即为最新。
如果你是更早克隆的旧副本：`git pull` 后用会话内 `git rev-parse HEAD` 确认，
再重跑 `scripts\Sync-Skills.ps1`（会以"更新 + 备份"的方式升级，不会覆盖你本地改过的文件）。

**装到了别的目录**
不带 `-SkillRoot` 时应为 `%USERPROFILE%\.agents\skills`。先 `-DryRun` 看解析结果：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Sync-Skills.ps1 -DryRun
```

**同步报错并以非零退出**
任一技能 `decision=error` 都会非零退出。看 JSON 的 `failed` 与 `skills[].message`；
被占用文件导致的失败会"只补缺失文件"恢复，原文件保持不动。关掉占用程序（编辑器、杀软、OneDrive
同步）后重跑即可。

**两个看似成功其实是冲突**
外来同名目录默认**不覆盖**、退出码 0；需要严格模式加 `-Strict`（冲突退出 2）。
`conflicts` 数组非空就说明有冲突，不要只看退出码。

**重复安装会不会多备份**
不会。第二次及以后 `updated=0`、不新建备份目录；manifest 的 `generatedAt` 会重写（已知）。

## 发现类

**客户端看不到技能**
1. 确认已装到 `%USERPROFILE%\.agents\skills` 且 9 个目录都在；
2. 关掉重开客户端会话（技能目录在会话启动时扫描）；
3. 离线确认（不花模型额度）：

```powershell
python -B .\scripts\Test-CodexSkillDiscovery.py --help
```

注意：引擎级"发现 9/9"不等于 UI 里一定可见；UI 可见性需要人工确认。

**客户端提示技能太多 / 描述被截断**
本机技能总量接近上下文预算时会看到
`Skill descriptions were shortened`/`Exceeded skills context budget`。这是客户端的预算问题，
不是安装失败；可禁用无关插件或技能。

## MCP / 执行类

**MCP 连不上 / 超时**
先看 `sessionDetails.json` 里的 PID 是否还活着（自动模式会复用已共享的会话）。确认可行后：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabMcpEndToEnd.ps1
```

**`tools/call` 永远不返回（`initialize` / `tools/list` 却都正常）**
症状：客户端能列出 5 个工具，但任何 `evaluate_matlab_code` / `run_matlab_file` 都挂到超时
（120–300 s），服务端 stderr 干净，会话目录里**既没有** `connector.securePort`、**也没有**
`mcp_startup_error.txt`。

2026-10-28 在 MATLAB R2026a Update 3 上实测：`auto`（`nodesktop` 与 `desktop` 两种显示模式）
与 `new` 共三条冷启动路径**全部挂起**，只有 `existing` 正常 —— 同一台机器、同一天、同一行代码，
`existing` 1.9 s 返回真实版本串。已排除的因素：会话目录、`cert.pem` / `cert.key`、Connector 本身
（`-batch` 里 `graphics 初始化 / ensureServiceOn / securePort` 三步合计 1.4 s 通过），
以及客户端侧协议（`initialize` 0.8 s PASS）。**把服务器用的那条完整命令行手工启动是成功的**
（会写出 `connector.securePort`），所以问题在「服务器启动子进程的上下文」，不在命令行本身。

处理：换成 `existing` 模式，两步。

```powershell
# 1) 先持有一个共享会话（内部用空转 timer 让事件循环活着，不用 pause 占住主线程）
powershell -ExecutionPolicy Bypass -File .\scripts\Start-MatlabSharedSession.ps1 -HoldMinutes 25

# 2) 用 existing 模式接入并验收
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabMcpExistingSession.ps1 `
  -Backend matlab-mcp-existing -Transport stdio -ProjectRoot . -Json
```

实测：`7/7 PASS`、`achievedLevel=L4`、`exit=0`，`evaluate_matlab_code` 1.9 s 返回
`26.1.0.3276743 (R2026a) Update 3`，文件读写 `hostVerified=true`。
要把客户端长期配成这种模式：`Install-MatlabMcpClients.ps1 -SessionMode existing`。

两条硬约束：

- 持有会话期间**不要再启动任何 MATLAB**（任何一次启动都会覆写 `sessionDetails.json`，
  `existing` 随即指向一个失效会话）；
- 结束时写 `<Work>\stop_session.flag` 温和退出，实测 15 s 内退出、无残留进程。

**同一现象反复出现：每次都要人工开 MATLAB，任务动不动 BLOCKED**
这是 `existing` 模式的固有代价，不是配置错了：会话是有寿命的（`-HoldMinutes` 到点即退出），
而它一旦失效，客户端仍会先成功 `initialize` / `tools/list`，然后在 `tools/call` 上干等
120 s 才判失败。所以"昨天还能用、今天必然 BLOCKED"是预期行为。

改用一次健康检查把失败提前到几秒：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Ensure-MatlabMcpReady.ps1 -Work .\artifacts\runtime
```

它只认一个证据：`mcp.readonly-exec` = `PASS`（真实 `tools/call` 返回真实数值，默认 20 s 超时）。
`sessionDetails.json` 存在、pid 存活、端口在听这三项只用来快速短路，**不能单独宣布健康**——
`pause()` 持有会话时端口照样返回 200，但每次 `tools/call` 都挂死。

`status=NOT_READY` 时，脚本会把两条命令直接打印在 `nextAction` 里：先按 `startCommand`
**在后台**启动共享会话，等 `<Work>\session_ready.json` 出现（约 30 s），再跑 `recheckCommand`。
脚本自己不去拉起 MATLAB —— 受管环境里 `Start-Process` 启动解释器会被安全策略拒绝，
而且持有会话必须是独立长驻进程，脚本活不到那一刻。

建议的用法：任何超过单次调用的 MATLAB 任务，第一步就跑这个门禁；`READY` 再开工，
`NOT_READY` 照 `nextAction` 执行，不要盲目重试。

两个不要被带偏的现象：

- `Start-MatlabSharedSession.ps1` 产出的 `session_ready.json` 里 `PortProbe` 可能是 `false`，
  但 MCP 实际可用 —— 那是脚本自身 HTTPS 探测（自签证书）的误报，不是会话不可用。
- MCP server v0.15.0 仍传 `-softwareopengl`，而 R2026a **已移除该选项**，启动时会打印
  `[警告: OpenGL 启动选项已删除。]` 与 `刷新时出错`。带该选项手工启动仍成功，所以它不是挂起的
  充分原因，只是噪声。

**MATLAB 没开，任务直接失败**
先让 Agent 自动拉起可见桌面：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Start-MatlabDesktop.ps1 -TimeoutSeconds 180
```

失败时报告里会写 `status`/`reasonCode`。`UNSUPPORTED` + `COM_HOLDER_BREAKAWAY_DENIED` 表示
当前宿主 Job 不允许 breakaway（本机就是这种情况），请改用默认 `StartupCommand`（不加
`-LaunchMode ComDesktop`）。

**含中文的 MATLAB 代码执行后变成 `?` 或空**
Phase 4.5 已修：MCP stdio 客户端现在把 stdin/stdout/stderr 都钉成 UTF-8。若仍出现，
确认用的是本仓库 `scripts\Invoke-MatlabMcpCode.ps1`（旧版会按 OEM 代码页转码）。

**安装器报 `A parameter cannot be found that matches parameter name 'McpServerName'`**
旧版 Windows 测试版文档写过 `Install-MatlabMcpClients.ps1 -McpServerName`，该参数只存在于
`Setup-MatlabMcpExistingSession.ps1`。安装客户端配置请用 `-ServerName matlab-official`
（已修正 `docs/WINDOWS_BETA_ZH.md` 与 `docs/RELEASE_NOTES_WINDOWS_BETA_ZH.md`）。

**Simulink 任务卡住不返回**
实测过两种：`new_system` 后未 `load_system` 就 `add_block`、以及把模型另存为与已打开模型
不同名的文件，都会报"模型不存在/同名模型已打开"。处理：`new_system` 后立刻 `load_system`，
并让 `.slx` 文件名与模型名一致。另：卡住的实例会占住 MATLAB，后续 MCP 调用全部超时——
结束该实例再重开即可。

## 许可证与平台

**`matlab -batch` 报错误 5201 / 安装器提示 `MATLAB MCP Server Toolbox 安装失败（exit=1）`**
本机实测的许可证模式是在线许可（`license_info.xml` 中 `licmode=onlinelicensing`），激活状态按
Windows 用户档案保存。换到没有激活记录的用户档案（例如临时重定向 `%USERPROFILE%` 的新环境）时，
MATLAB 会尝试联网校验并以 **LME 5201** 失败（本机实测 `matlab -batch` 154.8 s 后退出 1）；
`Setup-MatlabMcpExistingSession.ps1` 会等待约 10 分钟，然后以上面这句通用错误结束，服务端日志里
是 `timeout waiting for worker to start`。这不是 MCP 配置错误：请用拥有 MATLAB 许可证的正常
Windows 账户登录，先手工启动一次 MATLAB 完成激活，再重跑安装器；安装器失败不会留下半装的
Toolbox 状态。另外，新档案下 `%USERPROFILE%\Documents` 不存在时会看到
`failed to determine MATLAB starting directory, proceeding without one`，这是警告，不是失败原因。

**提示某个工具箱未授权**
本项目**不提供** MATLAB 许可。用 `mas_precheck('toolbox','<产品名>')` 查实际状态，
不要用 `license('test','<显示名>')`（显示名会误报 0）。

**在 WSL / Linux / macOS 上能用吗**
未实测。只有路径解析逻辑（`$HOME/.agents/skills`），不能声称兼容。Windows 之外请自行评估。

## 卸载与回滚

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Remove-Skills.ps1
```

只删 manifest 登记且未被本地修改的目录；改过的技能会保留并给出原因。备份在
`<SkillRoot>\.matlab-agent-skills\backups\` 下，可手工回滚。
