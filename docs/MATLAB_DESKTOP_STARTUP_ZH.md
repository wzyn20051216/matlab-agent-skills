# MATLAB 可见桌面自动启动

`Start-MatlabDesktop.ps1` 自动复用现有共享桌面，或者在没有 MATLAB 时打开新桌面。
它不关闭 MATLAB，不清工作区，不改 `startup.m`、许可证、用户凭据或共享会话文件。
启动后 MATLAB 自己执行 `shareMATLABSession()`；脚本只读取必要的 PID/端口字段。

```powershell
# 自动复用；没有 MATLAB 时自动启动，最多等待 180 秒
./scripts/Start-MatlabDesktop.ps1 -TimeoutSeconds 180

# 预演：不启动、不创建日志目录
./scripts/Start-MatlabDesktop.ps1 -DryRun

# 明确另开实例，已有用户会话保持运行
./scripts/Start-MatlabDesktop.ps1 -NewSession -TimeoutSeconds 180

# 显式使用已注册的可见桌面 COM，独立持有引用；计算仍用官方 MCP
./scripts/Start-MatlabDesktop.ps1 -LaunchMode ComDesktop -NewSession -TimeoutSeconds 180
```

可传 `-MatlabExe`、`-WorkingDirectory`、`-OutputDirectory`。默认启动入口优先使用
桌面/开始菜单中无自定义参数的 MATLAB 快捷方式目标，之后才使用执行模块的安装发现。
新桌面采用 `-sd`、`-logfile`、`-r`，默认图形模式；不用 `-nodesktop`、`-batch`
或阻塞事件循环的等待命令。已有未共享实例时返回 `EXISTING_NOT_READY`，避免默认重复启动。

可显式选择 `-LaunchMode Shortcut -ShortcutPath '<真实 MATLAB.lnk>'`，让 Windows
只收到原始 `.lnk` 路径，不附加 `-r/-sd/-logfile`，也不覆盖快捷方式启动目录。
默认的 `StartupCommand` 模式仍保持原行为，两个入口的实测结果分别记录。
Shortcut 模式发现新共享桌面后只返回 `SHARED_DESKTOP_CANDIDATE`，
`newSessionVerified/coldStartVerified` 仍为 false。Agent 随后通过官方 MCP 执行报告中
`mcpCodeFile`（先核对实际 MATLAB PID，再写唯一回执），然后调用
`Start-MatlabDesktop.ps1 -ConfirmReport '<startup_report.json>'` 完成只读复核。
确认动作不创建进程，保留确认前报告；再次确认不会丢失原候选状态。

`ComDesktop` 只读核对 `Matlab.Desktop.Application` 的 64 位注册与所选 MATLAB 安装，
再通过 Windows `CreateProcessW` 创建独立隐藏 STA 持有进程，使用
`CREATE_BREAKAWAY_FROM_JOB | CREATE_NO_WINDOW` 且不继承工具管道或标准句柄。
Job 不允许脱离时明确失败，不降级为另一次启动。持有进程的 PowerShell 自身隐藏，
新 MATLAB 设置 `Visible=1`。默认仍为 `StartupCommand`，持久性须由真实新会话另验。

COM 先执行带唯一标记的只读 PID/安装查询。它是共享 COM 服务：若返回启动前已存在的 PID，
报告 `NOT_NEW / NOT_NEW_COM_SHARED_SERVER`，不执行 bootstrap、不改共享会话，也不计作另开成功。
新实例仅执行启动回执与分享；后续计算通过官方 MCP。回执就绪还要求 holder 状态为
`HOLDING`、PID 绑定一致且 holder 存活；`-ConfirmReport` 同样检查此条件。

holder 保留强 COM 引用，不调用 `Quit` 或杀进程。主脚本最多等待 `TimeoutSeconds`，
超时保留可能已产生的桌面与 holder；用户关闭对应 MATLAB 运行时后 holder 自行退出。
COM 激活已成功但身份查询失败时，仅对本次新建、同安装、创建时间匹配的进程候选保活，
报告保持 `FAILED`，以 `preservation=UNBOUND_NEW_PROCESSES` 和候选 PID 明确记录。
`desktop_holder_state.json` 保留状态；主脚本不会因激活后失败再自动另开 Shell 实例。

## 就绪证据

每次调用单独保存 `startup_report.json`。新启动另有 `desktop_bootstrap.m`、
`desktop_ready.json`、`matlab_startup.log`。回执由新 MATLAB 主线程的局部函数生成，
包含唯一 `launchId`、实际运行时 PID、桌面状态、版本及共享函数状态；不含共享密钥。
桌面探针优先使用本机 R2026a 的 `usejava('desktop')`，并保留旧/新 `desktop` 查询兼容路径。

判为 `READY` 必须同时满足：回执属于本次启动、PID 不在启动前列表、运行时仍存活、
桌面已启用、该运行时或父链上存在可见窗口、共享文件 PID 与实际运行时一致。
新进程及共享文件的时间必须晚于启动请求，运行时须属于选定的 MATLAB 安装；
复用也拒绝比当前进程更旧的共享文件。父链窗口的创建时间不能晚于对应子进程。
启动器 PID 与实际运行时 PID 分别记录，启动器退出不会单独判定失败。
`WindowsShell` 使用隐藏的 STA 辅助进程发送 Shell 启动请求；MATLAB 窗口正常显示。
辅助请求最多 20 秒，总等待受 `-TimeoutSeconds` 限制。超时仅记录证据，保留可能已打开的 MATLAB。
辅助进程的中文 stdout/stderr 均按 UTF-8 捕获并有界脱敏；退出码为零也保留警告。
`launchContext` 记录 Windows 会话、交互状态、PowerShell 版本及 Conda 是否活跃，
不修改父进程或全局环境。

| 字段/状态 | 含义 |
|---|---|
| `REUSED_EXISTING` | 观察到已有共享运行时及桌面窗口，未启动新实例 |
| `newSessionVerified` | 本次新启动的回执、进程和共享会话匹配 |
| `coldStartVerified` | 新启动通过，且启动前完全没有 MATLAB 进程 |
| `bootstrapReached` | 本次已收到 MATLAB 主线程回执 |
| `SHARED_DESKTOP_CANDIDATE` | 仅观察到新共享桌面，等待实际执行回执，尚未通过启动验收 |
| `NOT_NEW` | 共享 COM 返回已有实例，显式另开请求未实现 |
| `mcpExecutionVerified` | 本脚本始终为 false；必须另做官方 MCP 工具执行 |

复用不能算冷启动；已有 MATLAB 时另开实例也不能算冷启动。
自动启动成功后仍应重建官方 stdio `auto` 连接，再做真实工具执行与任务验收。
连接和数值任务可以使用仓库 `Invoke-MatlabMcpCode.ps1`，不采用旧绑定的超时结果冒充新连接结果。

## 2026-10-20 22:09 实测：零进程冷启动通过（默认 StartupCommand）

在**没有任何 MATLAB 进程**、且 `sessionDetails.json` 仍指向已退出 PID（残留失效会话）
的条件下，默认 `StartupCommand` 模式一次通过：

| 项 | 实测值 |
|---|---|
| `status` | `READY` |
| `beforeProcesses` | `[]`（零 MATLAB 前置进程） |
| `runtimePid` / `desktopPid` | 25692 / 9724 |
| `newSessionVerified` / `coldStartVerified` | `true` / `true` |
| 用时 | 23.3 s |
| 证据 | `artifacts/validation/phase44/desktop/20261020-220909_73ceab9e/startup_report.json` |

随后重建官方 stdio `auto` 连接执行同一控制任务，结果 `matlabPid=25692` 与本次
`runtimePid` 一致，相位裕度 55.86223988°、增益裕度 `Inf`、闭环稳定，故
`startupSessionBinding=PASS`（证据见双端验收记录）。

已有实例时另开也已实测：2026-10-20 22:04:39 在既有两个 MATLAB 进程存在时用
`-NewSession` 新开 39224/11216，`newSessionVerified=true`、`coldStartVerified=false`。
即"另开"与"冷启动"是两件事，前者不能被记作后者。

## ComDesktop 模式在当前工具 Job 下的限制

本机工具进程位于**不允许脱离**的 Windows Job 中，`CreateProcessW` 带
`CREATE_BREAKAWAY_FROM_JOB` 返回 Win32 错误 5（拒绝访问），因此
`-LaunchMode ComDesktop` 实测为 `START_FAILED`，原因为
"无法创建独立 MATLAB COM 持有进程"。

这是**明确失败而非降级**，符合本文件前述「Job 不允许脱离时明确失败」的约定；
同一机制在允许 breakaway 的父进程下曾成功创建新实例并取得回执
（`auto_start/persistent_com_20261020-215153/desktop_ready.json`），
但当时仅验证到"持有期间就绪"，不能替代冷启动验收。
需要在本机自动打开时使用默认 `StartupCommand`：它经 Windows Shell 启动，
MATLAB 进程不继承工具 Job，因此不会随工具调用结束被回收。
Conda、控制台、held-parent、breakaway 等对照见
`artifacts/validation/phase44/auto_start/diagnostic_summary.json`。

## 本机调查及边界

> 以下 2026-10-20 早些时候的只读调查结论保留原样；其中"常规启动器未形成持久新实例"
> 已被 22:09 的冷启动实测取代——差别在于当时用的是**直接子进程**（随工具 Job 回收），
> 而通过 Windows Shell 启动不继承该 Job。

2026-10-20 只读调查：桌面和开始菜单的 MATLAB 快捷方式均指向安装目录下
`bin/matlab.exe`，没有额外参数。手动成功会话中，可见窗口属于 `bin/win64/MATLAB.exe`
的父桌面进程，实际计算运行时是另一个 MATLAB PID；`sessionDetails.json` 写的是后者。
当前用户会话的运行时没有主窗口句柄，父桌面进程有窗口，不能要求运行时本身必须有窗口。

此前失败记录未生成 MATLAB 启动日志，最多说明尚未观察到日志/启动命令执行；
不能据此断言共享函数失败。专用 MATLAB 环境变量未观察到进程/用户/系统级覆盖。
Shell 启动与直接子进程启动的差异仍需新实例实测，当前不把机制推断写成已证实根因。

已观察到执行工具带 `KILL_ON_JOB_CLOSE` Job 限制；本机清理 Conda 子环境、无参数 Shell
和独立控制台试验均未产生成功回执，代码不因此改写用户或全局环境。普通 COM 激活曾产生
新桌面和回执，但引用释放后实例退出，因此该记录不能证明持续存活。
独立 holder 的持续存活须在启动工具退出后再次查对应 PID，并通过官方 MCP 验证，
不能只以创建进程或第一次回执当作完整验收。

新脚本只读、不使用原共享持有脚本的到期强制终止策略。
命令参数语义参考 [MathWorks Windows 启动说明](https://www.mathworks.com/help/matlab/ref/matlabwindows.html)，
Shell 显示行为参考 [Microsoft Shell.ShellExecute](https://learn.microsoft.com/en-us/windows/win32/shell/shell-shellexecute)。
桌面 COM 语义参考 [MathWorks Create MATLAB Server](https://www.mathworks.com/help/matlab/matlab_external/creating-the-matlab-server.html)，
独立进程标志参考 [Microsoft Process Creation Flags](https://learn.microsoft.com/en-us/windows/win32/procthread/process-creation-flags)。
`-r` 用于交互工作流；`-wait` 等待 MATLAB 退出，不能证明共享会话就绪。

## 已知缺陷（2026-10-20 静态审查，未修复）

对启动器做过一次只读静态审查，全文见
`artifacts/validation/phase44/auto_start/code_audit.md`。本次冷启动证据走的是
`StartupCommand`，下列缺陷集中在 `ComDesktop` 路径，尚未修复；修好之前不应把
`ComDesktop` 当作可靠路径：

- `-NewSession` 对 `ComDesktop` 并未真正"另开"：共享 COM 只要返回启动前已存在的
  PID 就是 `NOT_NEW`（本机 2026-10-20 21:56 实测即为该状态）。
- 禁止 breakaway 的 Job 中在 holder 创建阶段直接失败，且失败信息不带 Win32 错误码；
  建议在 `DesktopProcessNative.StartDetached` 中附加 `NativeErrorCode` 便于归因。
- holder 存活判定是裸 PID 查询，PID 复用可能让已结束的 holder 仍被当作 `HOLDING`，
  `-ConfirmReport` 据此可能确认一个已死的持有进程。
- 启动前/新实例分类仅用 PID，存在 PID 回收导致的误判。
- 状态文件发布发生在 `HOLDING` 之后，写状态失败会进入 catch 并结束 holder。
- `HOLDING` 只表示 `Execute` 返回，未证明 bootstrap 真的执行成功。

这些都是实现与回归测试问题，不是文档措辞问题；`ComDesktop` 需要重做后再验收。

## 可复现测试

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ./tests/Invoke-Tests.ps1 -Layer free -Filter DesktopStartup
```

定向测试只模拟启动器，覆盖旧回执、共享 PID 冲突、父窗口归属、复用与新启动分离、
超时、日志和凭据隔离，以及 COM 共享实例保护、持有生命周期、确认保护与原生创建标志。
测试中的真实 PowerShell 辅助进程只打印文本，不激活 COM 或 MATLAB；模拟测试不算真实冷启动证据。
