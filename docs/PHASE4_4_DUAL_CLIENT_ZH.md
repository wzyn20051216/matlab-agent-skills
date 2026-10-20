# Phase 4.4 双客户端验收记录

本轮把“客户端发现技能”“读取技能正文”“官方 MCP 实际执行”“数值正确”分开判断。
CLI 与 Desktop 各自产生报告，任何一端的执行或结果都不能替代另一端。
派生报告顶层 `overall` 保持 `PARTIAL`：已测路径有实证，尚未覆盖全部环境。
当前任务结论对应 2026-10-20 22:09 生成的报告快照；自动打开新实例与零进程冷启动
均已取得实测证据（见下文「自动启动验收」），其余未测部署环境仍保持 `NOT_EXECUTED`。

## 已测路径和未测边界

| 项目 | 本轮证据与边界 |
|---|---|
| 同一 Windows 用户同时安装 CLI / Desktop | 原生共享目录；CLI `0.147.0` 与 Desktop 内置引擎 `0.163.0-alpha.10.2` 分别冷启动，升级 9 / 卸载 0 / 重装 9 |
| Desktop 平台发现和正文读取 | 真实 Desktop 会话注入 9 个 MATLAB 技能；加载证据只留观察名称、哈希和事件指针，不复制混合工具调用原文 |
| Desktop 控制任务 | 当前 Desktop Agent 直接使用官方 stdio MCP 的 `auto` 会话模式，已取得真实执行返回和结果 |
| Desktop 原生 connector 绑定 | 原绑定存在超时和 worker 启动错误；官方 stdio 成功不能表述为原生绑定已经恢复 |
| CLI 独立任务 | 独立 CLI 自选技能、读取正文并调用官方 MCP；恢复任务已完成，退出码 0，verifier 与报告器分别核验，五层检查通过 |
| 只安装 CLI / 只安装 Desktop 的独立物理机 | 未测 |
| 真实 WSL | 未测；路径解析模拟不替代真实操作系统验收 |
| 完整 Desktop UI 应用重启 | 未测；内置发现引擎冷启动已经实测 |
| 自动打开新 MATLAB 实例 | 已实测：22:04:39 在已有实例时 `-NewSession` 新开 39224/11216，`newSessionVerified=true`、`coldStartVerified=false` |
| 零既有 MATLAB 进程条件下的冷启动 | 已实测：2026-10-20 22:09:09 零进程且残留失效会话下 9724/25692，`coldStartVerified=true` |
| 工具 Job 禁止 breakaway 时的 ComDesktop | 本机实测 `START_FAILED`（Win32 错误 5）；默认 `StartupCommand` 不受此限 |

历史模型不可用、额度限制、MCP 超时和任务初次断言失败均保留原始文件。
报告从当前 verifier 选择的本端结果验收，同时保留先前失败来源，不改写旧记录。
CLI 成功恢复会话从 16:20:36 到 16:29:33，用时 `537.235 s`；这是包含技能读取、
多次真实 MCP 调用、纠错及回读的会话总耗时，不能当作单次 MATLAB 求解耗时。

## 本端证据索引

| 证据 | 位置与结论 |
|---|---|
| CLI 派生报告 | [cli_acceptance_report.json](../artifacts/validation/phase44/cli_acceptance_report.json)：`taskAcceptanceStatus=PASS`，`overall=PARTIAL` |
| Desktop 派生报告 | [desktop_acceptance_report.json](../artifacts/validation/phase44/desktop_acceptance_report.json)：`taskAcceptanceStatus=PASS`，`overall=PARTIAL` |
| CLI 平台及执行核验 | [verification.json](../artifacts/validation/phase44/cli/verification.json)，包含独立 CLI 会话来源和历史失败 |
| CLI 成功任务原始事件 | [events.jsonl](../artifacts/validation/phase44/cli/20261020-162036-recovery-task/events.jsonl)，成功数值执行为 `item_29`、`item_39` 的 `run_matlab_file` 返回 |
| Desktop 实际执行 | [mcp_execution.json](../artifacts/validation/phase44/desktop/control_execution/mcp_execution.json)，官方 stdio 返回与本端结果对应 |
| Desktop 技能发现及读取 | [skill_evidence.json](../artifacts/validation/phase44/desktop/skill_evidence.json)，schema `/2`，包含 9 个发现项及 4 个观察到正文标识的技能名 |
| Windows 共享目录生命周期 | [summary.json](../artifacts/validation/phase44/native_lifecycle_retry/summary.json)，六次独立引擎检查均通过，原始发现错误列表均为空 |
| 自动启动冷启动报告 | [startup_report.json](../artifacts/validation/phase44/desktop/20261020-220909_73ceab9e/startup_report.json)：`status=READY`、`beforeProcesses=[]`、`coldStartVerified=true` |
| 冷启动实例上的数值执行 | [result.json](../artifacts/validation/phase44/desktop/cold_control_task/result.json) 与 [mcp_execution.json](../artifacts/validation/phase44/desktop/cold_control_execution/mcp_execution.json)：`matlabPid=25692` 与启动报告 `runtimePid` 一致 |

以上链接指向本地验收产物，源代码仓库副本不一定包含这些日志文件。
本端任务通过不包含 Desktop 原生绑定恢复、全部部署环境或完整 UI 重启通过的含义；
"自动启动"仅指下文实测的零进程冷启动，不包含 ComDesktop 路径。

## 自动启动验收（2026-10-20 22:09）

同一用户会话里分三步，避免把"另开"当成"冷启动"：

1. 22:04:39 已有两个 MATLAB 进程（含用户手动打开的 45800/46996）时运行
   `Start-MatlabDesktop.ps1 -NewSession`：经 Windows Shell 新开 39224/11216，
   `status=READY`、`newSessionVerified=true`、`coldStartVerified=false`；
   官方 MCP 在 11216 上算出与参考值一致的裕度和极点（`matlabPid=11216`）。
2. 关闭全部实例后用 `New-Object -ComObject Matlab.Desktop.Application` 复核：
   其返回的是**新建** PID 14736，说明手动打开的普通会话不会被 COM 复用；
   该实例随后 `exit` 退出。
3. 22:09:09 在**零 MATLAB 进程**、且 `sessionDetails.json` 仍指向已退出 PID 14736
   的条件下运行同一脚本：`status=READY`、`beforeProcesses=[]`、
   `newSessionVerified=true`、`coldStartVerified=true`，用时 23.3 s；
   随后官方 MCP 在该实例执行控制任务，`matlabPid=25692` 与 `runtimePid` 一致。

因此"自动打开软件"按用户真实条件（MATLAB 未运行）已通过，且执行能力由官方 MCP
的数值结果验证，而不是仅凭回执或进程存在。已有实例时脚本默认仍复用或拒绝重复启动，
只有显式 `-NewSession` 才另开；两种结果分别记录，不互相替代。
ComDesktop 模式在被 Job 禁止 breakaway 的宿主中会明确失败（Win32 错误 5），
本机自动打开应使用默认 `StartupCommand`。

## 数值验收方法

任务为开环 `L(s)=10/((s+1)(s+2))` 的单位负反馈。
报告器只用 Python 标准库独立推导参考，不调用 MATLAB、不读取被测任务的自评分数：

- 幅值交越满足 `(w²+1)(w²+4)=100`，因此 `w=sqrt((-5+sqrt(409))/2)`。
- 相位裕度由 `180-(atan(w)+atan(w/2))*180/pi` 得到；要求误差小于 `0.05°`。
- 有限正频率没有 `-180°` 相位交越，增益裕度应为正无穷大，JSON 使用字符串 `"Inf"`。
- 闭环特征多项式为 `s²+3s+12`，极点为 `(-3±j√39)/2`；检查两个极点及负实部稳定性。

CLI 的 `{real,imag}` 极点结构和 Desktop 的二维数值数组分别解析。
原始 MCP 返回还需与本端结果文件对应；仅有文件或结果自称 `PASS` 不构成执行证据。
缺字段、未执行、错误数值和正确数值分别保留状态。
评分器内含错误相位裕度、错误增益裕度、错误极点、错类型、数组、NaN 和缺字段负对照。
当前两端相位裕度均约 `55.8622398800°`，相对解析值误差约 `0.00019552°`；
增益裕度为 `Inf`，闭环稳定，极点为 `-1.5 ± 3.1224989992j`。两端各自的原始返回分别验证。

## 可复现生成

默认读取当前的 CLI verifier、Desktop 原始执行与平台证据；只生成派生报告，不启动客户端或 MATLAB：

```powershell
python -B .\scripts\Write-Phase44DualReports.py --self-test-only
python -B .\scripts\Write-Phase44DualReports.py
```

输出文件：

```text
artifacts/validation/phase44/cli_acceptance_report.json
artifacts/validation/phase44/desktop_acceptance_report.json
artifacts/validation/phase44/independent_numeric_grader_tests.json
```

CLI 本次 verifier 已更新；后续若重新开展独立任务，应等待该次 verifier 完成后再生成报告。
默认 Desktop 选择仍为 `control_task` 与 `control_execution`，不会自动采用较新的目录。
本次冷启动验收使用独立目录，显式选择该次结果、对应原始返回与启动报告（旧目录保持不动）：

```powershell
python -B .\scripts\Write-Phase44DualReports.py `
  --desktop-result .\artifacts\validation\phase44\desktop\cold_control_task\result.json `
  --desktop-execution .\artifacts\validation\phase44\desktop\cold_control_execution\mcp_execution.json `
  --startup-evidence .\artifacts\validation\phase44\desktop\20261020-220909_73ceab9e\startup_report.json
```

`--startup-evidence` 要求启动报告 `status=READY`、`newSessionVerified=true`，
且数值结果中的 `matlabPid` 必须等于该次 `runtimePid`；不满足时
`startupSessionBinding` 记 `FAIL` 而不是沿用旧会话的通过结果。

还可显式传入 `--startup-evidence <startup_report.json>`，将自动新实例与冷启动状态分开记录，
并核对该次数值结果中的 MATLAB PID 确实属于自动打开的新实例。
保留旧 MATLAB 会话的同时另开实例，不能记为零既有实例条件的冷启动。

Desktop 的 diary 可能因 LiveEditor 执行通道而为空。报告显式记录文件大小，空 diary 不记为有效日志；
该次实际 MATLAB 输出以非空的原始 MCP JSON 内容为准。

## 回归快照与限制

免费全套[当前快照](../artifacts/validation/phase44/free_tests_after_autostart.json)为 `263/265`
（2026-10-20 22:11，PS 5.1 / Pester 3.4.0，耗时 94.6 s）：既有硬编码盘符和
PowerShell UTF-8 BOM 两项失败仍保留，不声称免费全套通过。
Phase 4.3 grader [回归结果](../artifacts/validation/phase44/grader_tests.json)经真实官方 MCP 执行为 `43/43`；
Phase 4.3 的 53 份历史原始结果未改写。
Desktop 证据回归在 [PS5.1](../artifacts/validation/phase44/desktop_evidence_tests_ps51.json) /
[PS7](../artifacts/validation/phase44/desktop_evidence_tests_ps7.json) 分别为 `7/7`，
发现探针[模拟协议回归](../artifacts/validation/phase44/probe_protocol_tests.json)为 `8/8`。
MCP 执行包装器在 PS5.1 / PS7 均为 `6/6`：普通文本错误、提前返回、错误或重复完成回执
均不能判为执行通过；诊断内容在 JSON 序列化前脱敏。
报告器自身[独立评分回归](../artifacts/validation/phase44/independent_numeric_grader_tests.json)为 `9/9`，
包含解析正例与错误数值等负对照，每次生成时重跑。各回归属于各自范围，不能相互替代。

完成验收以报告中各层状态及所引用原始证据为准。全局可移植性、完整 UI 重启和原生绑定恢复仍需后续独立实测。
