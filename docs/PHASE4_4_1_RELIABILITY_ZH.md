# Phase 4.4.1 — 安装与执行基础设施可靠性收尾

日期：2026-10-20
范围：只收尾安装/执行基础设施，**不新增任何专业 Skill**。
口径：`PARTIAL` 不写成 `PASS`；未测项一律写 `NOT VERIFIED` 并给出原因。

本轮相对 Phase 4.4 基线的变化：

| 指标 | Phase 4.4 | Phase 4.4.1 |
|---|---|---|
| 免费层测试 | 263/265（2 项历史失败） | **270/270**（PS 5.1 与 PS 7 均 0 失败） |
| 7 个启动缺陷 | 全部未修 | 6 项 FIXED，1 项 DEFERRED（写明原因） |
| ComDesktop | `START_FAILED`，原因不可归因 | **UNSUPPORTED + reasonCode + breakawayState**，不触碰 MATLAB |
| 默认安装覆盖用户文件 | 静默删除（仅备份） | 保留并报告 |
| 单技能安装失败 | 回滚缺失、退出码 0 | 就地回滚 + 非零退出 |
| Desktop 证据门 | 只查 originator，CLI 会话可冒充 | `source=vscode` + `<app-context>` + 引擎版本 |

## 1. 七个启动缺陷的逐项结果（交付 1）

逐项复现条件、影响、修复与证据见
`artifacts/validation/phase44/defects_task1.md`。摘要：

| 编号 | 结论 | 关键证据 |
|---|---|---|
| B1 `-NewSession` 假另开 | FIXED（语义） | `reused` 只在"共享会话 PID + 可见窗口"均成立时为 true；否则 `reused=false` 并给 `recommendedAction` |
| B2 breakaway 失败无归因 | FIXED + UNSUPPORTED | 实测 `status=UNSUPPORTED`、`reasonCode=COM_HOLDER_BREAKAWAY_DENIED`、`IN_JOB=1;LIMIT_FLAGS=0x2000`，耗时 1.1 s，启动前后 MATLAB PID 均为 `9724,25692` |
| B3 holder 存活是裸 PID | FIXED | 绑定 `holderStartedAt` + `ProcessName=powershell`；`-ConfirmReport` 同判据 |
| B4 分类只用 PID | FIXED | 身份 = (PID, 创建时间)；新增"PID 回收"回归 |
| B5 状态发布争用 | FIXED | `File.Replace`/`Move` + 20 次重试；读侧 `ReadWrite|Delete` 共享 |
| B6 结论用陈旧局部变量 | FIXED | 循环后重新采样；READY 前重新施加 holder 绑定门禁 |
| B7 `HOLDING` 未证明 bootstrap | **DEFERRED** | 本环境无法创建 holder，改了也无法验证；修法与验收条件已写入文档 |

新增回归：`DesktopStartup` 由 46 → **49** 例，其中三条专门钉住本次修复
（PID 回收、UNSUPPORTED 归因、NOT_NEW 不再谎报 `reused`）。

## 2. 263/265 的真实结论（交付 2）

`263/265` 的两项失败**不是同一类问题**：

| 失败 | 真实性质 | 处理 |
|---|---|---|
| 盘符硬编码 | **判据误报 + 真实缺陷混在一起** | 判据改为 `(?<![A-Za-z0-9_])[ED]:[\\/](?![A-Za-z]:)` 并加自检样本；真实硬编码逐个修掉 |
| UTF-8 BOM | **真实约定缺陷** | 给 `Invoke-Phase43McpTask.ps1` 补 BOM；实测 no-BOM 时 PS 5.1 按 cp936 解码，中文字面量直接解析失败 |

判据误报的证据：旧模式 `[ED]:\\` + `Select-String` 大小写不敏感且无左上下文，
把 `name:` 后紧跟空白转义序列的片段误当成盘符路径（同理 `allowed:` 后的换行转义被当成另一盘符）。
`Export-CodexDesktopSkillEvidence.ps1:78` 与 `buck_a5_task3_faults.m:110` 因此被误报——两处代码本身正确。

真实硬编码（已修）：4 个 Phase43 脚本把仓库根写成盘符绝对路径、服务器 exe 默认值同样硬编码、
`buck_a4_figure.m` 的输出目录写死为本机路径、`buck_a6_task6_accept.m` 的泄漏守卫字面量、
`mas_codegen_ready.m` 与 `buck_task1_verify_model.m` 的文档示例，以及旧判据看不见的
`Join-Path "E:" "matlab\bin\matlab.exe"` 拼接。

扫描语义同时修正：只扫 **git 跟踪文件**（本机 318 个），无 git 时退回文件系统遍历并排除
`.git/.workbuddy/.codex/.vscode`、`artifacts/`、`bin/`、`.mcp.json`。
失败信息会打印 `[scan=git-tracked; files=N]` 或 `[scan=filesystem-walk; files=N]`。
理由：`.mcp.json`、`.workbuddy/**` 是 gitignored 的本机状态，扫描它们等于检查"这台机器"而不是仓库。
这不是放宽——跟踪文件里的盘符绝对路径仍然必定失败。

结果：**免费层 270/270**（PS 5.1 与 PS 7 各跑一遍，均 exit 0）：
`artifacts/validation/phase44/free_tests_final_ps51.json`、`free_tests_final_ps7.json`。

## 3. Codex CLI 独立验收（交付 3）

完整报告：`artifacts/validation/phase44/clients/cli_acceptance_4_4_1.md`。

| 项 | 结论 |
|---|---|
| 版本 | `codex-cli 0.147.0` |
| 技能根 | `~/.agents/skills`（`r1`，9 项全在此）；`~/.codex/skills` 也被扫描但无 matlab 技能 |
| 发现 9/9 | **PASS**（引擎 `skills/list` 与真实会话注入目录两路一致，`discoveryErrors=[]`） |
| 加载 orchestrator / 选择 runner | **PASS（观测性）**：真实会话中 4 次读取 `SKILL.md`（control-optimization、runner）；本机**无原生加载事件** |
| MCP 真实执行 | **PASS**：30 次 `mcp_tool_call`（evaluate 12 / check 8 / run_file 8 / detect 2） |
| 独立验收 | **PASS**：pm 误差 `1.955e-04°`（阈 0.05）、极点误差 `4.4e-16`、GM=`Inf`、闭环稳定 |
| 本轮重跑 | **NOT VERIFIED**：账户额度耗尽（`try again at Oct 21st, 2026 2:27 AM`），且默认模型 `gpt-6.1-sol` 对 ChatGPT 账户返回 400 |

附带记录：本机技能总量已顶到上下文预算——首次运行
`Exceeded skills context budget ... 94 additional skills were not included`，
换模型后降级为"描述被缩短"。即**引擎能发现 9 个 ≠ 模型能看到完整描述**。

## 4. Codex Desktop 独立验收（交付 4）

完整报告：`artifacts/validation/phase44/clients/desktop_acceptance_4_4_1.md`。

| 项 | 结论 |
|---|---|
| 引擎版本 | `0.163.0-alpha.10.2`（与 CLI 0.147.0 不同版，证据不可互替） |
| 用户级/项目级路径 | `~/.agents/skills` + 项目 `.codex/config.toml`（只定义 MATLAB MCP） |
| 九个技能可见性 | **PASS**：引擎 `skills/list` 9/9；真实 UI 会话 rollout 注入 9/9（`catalogSnapshots=5`） |
| 技能加载 | **PARTIAL**：有 `SKILL.md` 读取与哈希证据，无原生"已加载"事件 |
| 桌面版自主执行同题 | **NOT VERIFIED**：无程序化 UI 通道；22:09 那次执行是 Lead 经官方 MCP 驱动，不能算 Desktop Agent 自主执行 |
| 完整 UI 重启 | **NOT VERIFIED** |

本轮修掉一个**证据门缺陷**：`Export-CodexDesktopSkillEvidence.ps1` 原先只验
`originator=='Codex Desktop'`，而 CLI 0.147.0 的 exec rollout 也写这个值 → CLI 会话可以冒充
Desktop 证据。现在要求 `source=='vscode'` + 会话含 `<app-context>`，并把
`sessionSource`/`appContextPresent` 写进证据；新增 2 条负向回归（`source=exec` 必须拒绝、
缺标记必须拒绝），`DesktopEvidence` 7 → **9** 例。

## 5. 默认安装与自动发现（交付 5）

安装侧完整报告：`artifacts/validation/phase44/install/install_regression.md`
（55/55 断言，PS 5.1 与 PS 7 各一遍；该报告记录的是**修复前**状态）。

**默认目标（已确认）**：不带 `-SkillRoot` 时安装到 `%USERPROFILE%\.agents\skills`；
`CODEX_HOME` 不再重定向。旧结论"默认 -SkillRoot 是错的"对**旧提交 9d46cd7 之前**成立，
对当前代码不成立。`codex 0.147 skills/list` 在该目录返回 9/9。

修复前的三个缺口及本轮处理：

| 缺口 | 本轮处理 | 验证 |
|---|---|---|
| 用户新增文件在升级时被静默删除 | 升级前快照、替换后回填，结果里报 `PreservedUserFiles` | 临时目录实测：加 `USER-NOTES.md` 后重同步 → "保留用户新增文件 1 个"，内容保留 |
| 单技能失败无回滚、且无 `-Strict` 时退出码 0 | 失败项按"补齐缺失文件"恢复（`RestoredFromBackup`/`RecreatedFiles`），并 `throw` 使退出码非零 | 临时目录实测：读共享锁下强制 update → `decision=error`、非零退出、文件数 3→3、缺失 0、被占用的 `SKILL.md` 未被改动 |
| Bootstrap 技能步与 MCP 步耦合、无跨脚本回滚 | 本轮**未改**（需单独评审），仅记录；`-SkipSkillsSync` 已存在 | 代码审阅，未执行 |

仍未改变：manifest 每次重写 `generatedAt`（"重复执行零写入"的措辞仍偏强，已在报告中记录）。

**回滚这一项在复核中被推翻了两次**，值得单独记下：
第一版"整目录回滚"复用了刚刚失败的 `Remove-Item` 去清理目标，再删一次会撞同一个锁；
更严重的是复现时发现 `Remove-Item -Recurse -Force` 对占用文件只产生**非终止错误**，
于是代码继续 `Move-Item` 到非空目录，最后把缺文件的目录报成
`已更新（旧版本已备份）`——**静默成功**比"半装"更危险。
现在：交换路径上的 `Remove-Item`/`Move-Item` 都显式 `-ErrorAction Stop`，
交换后逐个比对源文件是否都在，恢复改为"只补缺失文件、绝不删目标"，
并以"备份里每个文件都已存在"作为 `RestoredFromBackup` 的判据。

平台范围：Windows PS 5.1 / PS 7 **实测通过**；WSL、Linux、macOS 仅验证了路径解析逻辑，
**未实测**；Desktop 引擎的安装生命周期沿用 Phase 4.4 的 9/0/9 证据，本轮未重跑。

## 6. MATLAB MCP 自动冷启动与生命周期（交付 6）

沿用并保持 Phase 4.4 末的实测（本轮未回退）：

| 项 | 实测 |
|---|---|
| 零进程冷启动 | `READY`、`beforeProcesses=[]`、`coldStartVerified=true`，9724/25692，23.3 s |
| MCP 数值执行 | `matlabPid=25692` 等于启动报告 `runtimePid`，`startupSessionBinding=PASS` |
| 已有实例时另开 | `newSessionVerified=true`、`coldStartVerified=false` |
| ComDesktop | 本机 **UNSUPPORTED**（Job 禁止 breakaway），默认 `StartupCommand` 可用 |
| 清理 | 启动器不关闭 MATLAB；holder 释放只影响自己创建的实例 |

证据：`artifacts/validation/phase44/desktop/20261020-220909_73ceab9e/startup_report.json`、
`desktop/cold_control_task/result.json`、`desktop/20261020-223240_eaec0267/startup_report.json`（UNSUPPORTED）。

## 7. PowerShell 兼容性（交付 7）

| 宿主 | 免费层 | 说明 |
|---|---|---|
| Windows PowerShell 5.1.26100.7462 | **270/270**，exit 0 | Pester 3.4.0；`free_tests_final_ps51.json` |
| PowerShell 7.6.7 | **270/270**，exit 0 | 同一套用例；`free_tests_final_ps7.json` |

本轮两次踩到同一类坑：**编辑工具保存 UTF-8 无 BOM → PS 5.1 按 cp936 解码 → 中文字符串破坏引号 → 解析失败**。
处理方式是恢复 BOM 并在提交前对 `tests/`+`scripts/` 做 PS 5.1 `Parser::ParseFile` 全量校验。
这也从反面证明 BOM 那条检查是真实约束。

## 8. Skill → MCP → MATLAB 真实调用证据（交付 8）

两条链路分别取证，不互相顶替：

**(a) CLI 原生链路（今天 16:20 会话，0.147.0，`source=exec`）**
自然语言 prompt → 模型自述选 `matlab-orchestrator` + `matlab-control-optimization`
→ 4 次真实读取 `SKILL.md` → 30 次 `matlab-official` MCP 调用 → 写出 `result.json`
→ 独立 Python 解析器核对 PASS。
证据：`cli/20261020-162036-recovery-task/events.jsonl`（113 KB）、`result.json`、`cli/verification.json`。

**(b) Desktop 侧（引擎 + 会话注入 + 执行，分三层）**
9/9 引擎发现 + 9/9 UI 会话注入（原生）+ 16:19 的 MCP 执行（`matlabPid=41928`）
与本轮 22:09 冷启动实例执行（`matlabPid=25692`），数值均由独立解析器 PASS。
证据：`clients/discovery_fresh/desktop-engine/verification.json`、
`clients/desktop_skills_from_rollout.json`、`desktop/skill_evidence.json`（schema /2）、
`desktop/control_execution/mcp_execution.json`、`desktop/cold_control_execution/mcp_execution.json`。

证据限制（必须保留）：
1. 本机**没有**"技能已加载/被选中"的原生事件（协议有 `SkillUserInput` 但全库 0 命中）；
   加载只能以"成功读取 `SKILL.md`"为观测证据。
2. 不能从输出文字反推"技能被自动触发"；模型选了哪个技能，日志只有聚合计数。
3. Desktop UI 内的可见性/选中状态**未验证**。

## 9. Git 与发布安全（交付 9）

| 检查 | 结果 |
|---|---|
| `.codex/config.toml`（本机绝对路径 + MCP 注册） | 已 `.gitignore`，**未提交** |
| `.workbuddy/memory/**`（本地对话记录） | 已 `.gitignore`，**未提交** |
| 跟踪文件中的密钥/令牌 | 仅脱敏逻辑与测试占位符（`PRIVATE`、`DO_NOT_LOG_THIS`），无真实凭据 |
| 跟踪文件中的个人目录 | 无用户主目录绝对路径、无仓库绝对路径 |
| 会话文件/PID | 只出现在 artifacts/（gitignored） |
| 分支 | `feat/phase3b1-boost`，本地领先 origin；**不合并 main、不强推** |

## 10. 仍无法验证的环境（交付 10）

| 项 | 原因 |
|---|---|
| ComDesktop holder 端到端 | 本机 Job 禁止 breakaway（`LIMIT_FLAGS=0x2000`），无法创建 holder |
| B7 修复验证 | 同上，没有 holder 就无法验"bootstrap 真的执行" |
| CLI 本轮重跑 | ChatGPT 账户额度耗尽（10-21 02:27 恢复）+ 默认模型对账户不可用 |
| Desktop UI 层（菜单/选中/加载标识） | Windows 无 daemon/socket，无程序化驱动通道 |
| Desktop 完整 UI 重启 | 未重启 |
| WSL / Linux / macOS | 仅路径解析逻辑；无对应实机 |
| 只装单客户端的独立物理机 | 无设备 |
| `.workbuddy/skills` 安装 | 它不是 Codex 技能根，且内容是陈旧副本（hash 与 `.agents` 不同） |

## 结论（A–E）

**A. 用户是否能默认安装全部九个 Skills？**
**能（Windows，PS 5.1 与 PS 7 已实测）**。README 命令不带 `-SkillRoot` 即装到
`%USERPROFILE%\.agents\skills`，9/9 完整、幂等、可卸载且只删本项目管理的文件；
用户新增文件现在会被保留。WSL/Linux/macOS 未实测，**不能从这台 Windows 推断**。

**B. Codex CLI 是否能真实发现并调用？**
**能（有今天的原生证据）**：0.147.0 发现 9/9、真实会话读取 `SKILL.md`、30 次
`matlab-official` 调用、独立验收 PASS。但**本轮无法重跑**（账户额度），
且本机无"技能已加载"原生事件——加载是观测性证据，不是直接事件。

**C. Codex Desktop 是否能真实发现并调用？**
**发现：能**（引擎 9/9 + 真实 UI 会话注入 9/9）。
**自主调用：NOT VERIFIED**——无法程序化驱动 UI；已给出最小人工清单与可核验日志。
22:09 在自动打开的实例上跑出的数值是 Lead 经 MCP 执行的，**不能**算 Desktop Agent 自主执行。

**D. MATLAB MCP 是否能够可靠自动启动、复用及清理？**
**自动启动与复用：能**（零进程冷启动 + 已有实例另开均已实测，PID 绑定一致）。
**清理：保守**——启动器从不关闭 MATLAB；holder 只影响自己创建的实例。
**ComDesktop 路径：UNSUPPORTED**（本机 Job 限制），默认 `StartupCommand` 是可依赖路径。
"可靠"仅覆盖本机这一种 Windows + Job 环境；换了宿主 Job 或平台需重测。

**E. 是否具备对外发布安装器的条件？**
**有条件具备，但只应声明 Windows**：
- Windows：默认安装、内容完整性、幂等、卸载范围、PS 5.1/7 均有实测；
- 仍需人工复核：Bootstrap 的技能步与 MCP 步耦合（无跨脚本回滚）、manifest 每次重写导致
  "零写入"措辞偏强、B7 未修；
- 非 Windows：仅路径逻辑，**不能声称支持**。
因此发布说明必须写明平台范围与技术预览状态，不写"全平台可用"。
