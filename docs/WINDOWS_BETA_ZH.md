# Windows 测试版发布候选（Release Candidate 说明）

版本定位：**Windows 技术预览（technical preview）**，面向已经拥有合法 MATLAB 许可证的 Codex 用户。
本文件只写有证据的结论；未验证项一律标注 NOT VERIFIED，不作为卖点。

最后更新：2026-10-20（Phase 4.5）

## 1. 它是什么 / 不是什么

**是**：一套把 MATLAB / Simulink 工作流包装成 Codex Skills 的开源集合（9 个技能），
配套官方 MATLAB MCP 的启动、安装、诊断与验收脚本。

**不是**：
- 不是 MATLAB 的替代品或破解；**本项目开源不代表 MATLAB 免费**，运行需要 MathWorks 许可。
- 不是"全平台兼容"。Windows 之外只有路径解析逻辑，**未在实机验证**。
- 不是"全面自主执行"。真实自主执行依赖客户端账号、网络和模型可用性，本轮 CLI/Desktop 均受限。

## 2. 快速开始（Windows，三步）

前置：Windows 10/11；已安装 MATLAB R2026a（建议；更早版本未验证）；已安装 Codex CLI 或 Codex Desktop。

> **版本入口（必读）**：`main` 目前仍是早期快照——有 9 个技能，但是旧版内容，
> 且**没有**桌面启动器、MCP 代码执行器、卸载器和本批发布文档。
> 直接 `git clone`（默认主分支）装到的是**旧技能**，不是本文档描述的版本。
> 在审查通过并合并进 `main` 之前，请使用下面的**固定版本入口**。

```powershell
# 1) 取仓库并固定到已验证的预览标签
git clone --branch v0.6.0-preview.1 --depth 1 https://github.com/wzyn20051216/matlab-agent-skills.git
cd matlab-agent-skills
git rev-parse HEAD
git rev-parse 'v0.6.0-preview.1^{commit}'   # 两个值必须一致

# 2) 安装 9 个 Skills（默认装到当前用户 %USERPROFILE%\.agents\skills，无需 -SkillRoot）
powershell -ExecutionPolicy Bypass -File .\scripts\Sync-Skills.ps1

# 3) 配置官方 MATLAB MCP（生成/合并客户端配置，并校验服务器二进制）
powershell -ExecutionPolicy Bypass -File .\scripts\Install-MatlabMcpClients.ps1 -McpServerName matlab-official
```

`release/windows-preview` 是同一内容的分支形式（可变，预览重切时指向新提交）；
两者都不是 GitHub Release。合并进 `main` 之后，默认 `git clone` 才会指向同一版本，
届时本文档的版本提示会被移除。

重启（或新开）Codex 会话后用一句话自检：

```text
列出你能看到的 matlab-* 技能名称，并说明每个技能一句话用途。
```

预期：能看到 `matlab-codegen-deploy / matlab-control-optimization / matlab-data-analysis /
matlab-orchestrator / matlab-robotics-autonomy / matlab-runner / matlab-signal-vision-ai /
matlab-simulink-modeling / matlab-testing-ci` 共 9 个。

MATLAB 没开时，Agent 应先自动拉起可见桌面：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Start-MatlabDesktop.ps1 -TimeoutSeconds 180
# 只看计划不启动：加 -DryRun
```

## 3. 九个 Skills 各自解决什么

| Skill | 适用场景 |
|---|---|
| `matlab-orchestrator` | 入口与路由：判断该用哪个专业技能、要求走官方 MCP、要求产物可验收 |
| `matlab-runner` | 执行基座：MCP 调用、日志、工具箱清单、冒烟测试、可复现产物 |
| `matlab-data-analysis` | 表格/时间表、统计、拟合、可视化、论文图 |
| `matlab-simulink-modeling` | `.slx` 建模、改拓扑、仿真、信号检查、参数扫描 |
| `matlab-control-optimization` | 控制器设计、系统辨识、鲁棒/MPC、调参与约束优化 |
| `matlab-signal-vision-ai` | 滤波、频谱、图像/视觉、激光雷达、深度学习流程 |
| `matlab-robotics-autonomy` | ROS、机器人、导航、UAV、传感器融合 |
| `matlab-codegen-deploy` | MATLAB Coder / Embedded Coder / MEX / HDL 代码生成与部署就绪 |
| `matlab-testing-ci` | `matlab.unittest`、Simulink Test、覆盖率、CI、验收报告 |

## 4. 许可与依赖

- **MATLAB 本身**：需要有效 MathWorks 许可证；本项目不提供、不包含、不绕过任何许可机制。
  缺少许可证时，涉及 MCP 执行、Simulink、代码生成的流程会失败或不可用。
- **工具箱**：不同技能依赖不同产品（Control System Toolbox、Signal Processing Toolbox、
  Simulink、MATLAB Coder 等）。用 `mas_precheck('toolbox', <名称>)` 或 `ver` 查，不要靠猜。
- **Codex 客户端**：需要 Codex CLI 或 Codex Desktop 及可用账号；账号额度/网络由用户侧决定。
- **本项目许可**：见仓库 LICENSE（开源不等于 MATLAB 免费）。

## 5. MCP 安装与配置

```powershell
# 安装/更新客户端 MCP 配置（可指定服务器路径与 MATLAB 根）
powershell -ExecutionPolicy Bypass -File .\scripts\Install-MatlabMcpClients.ps1 `
  -McpServerName matlab-official `
  -ServerExePath "C:\path\to\matlab-mcp-server-windows-x64.exe" `
  -MatlabRoot "C:\Program Files\MATLAB\R2026a"
```

要点：
- 官方 MCP 推荐 `--matlab-session-mode=auto`（有共享会话就复用，没有就拉起）。
- 技能安装与 MCP 注册是**两件独立的事**：技能装成功不代表 MCP 可用，反之亦然。
- 需要重连时用 `scripts\Invoke-MatlabMcpCode.ps1` 建独立 stdio 连接并保存原始返回。

## 6. 环境诊断

```powershell
# MATLAB 可见桌面：复用 / 冷启动 / 报告
powershell -ExecutionPolicy Bypass -File .\scripts\Start-MatlabDesktop.ps1 -DryRun

# MCP 端到端（握手 + 工具列表 + 一次真实执行）
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabMcpEndToEnd.ps1

# 技能安装状态与清单
powershell -ExecutionPolicy Bypass -File .\scripts\Sync-Skills.ps1 -DryRun

# 仓库自检（不需要 MATLAB）
powershell -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Layer free
```

## 7. 已实测功能（有证据）

| 项 | 结论 | 证据 |
|---|---|---|
| 免费层测试 | **270/270**，Windows PowerShell 5.1 与 PowerShell 7 各一遍，exit 0 | `free_tests_final_ps51.json` / `free_tests_final_ps7.json` |
| 默认安装 | 不带 `-SkillRoot` 装到 `%USERPROFILE%\.agents\skills`；9/9 目录、62/62 文件、树哈希与仓库一致 | `artifacts/validation/phase45/install/windows_install_acceptance.md`（76/76 断言 ×2 宿主） |
| 升级 / 幂等 | 旧版→新版 `updated=9`；连续两次 `updated=0`、不再新增备份目录 | 同上 |
| 用户文件保护 | 升级后用户新增文件保留且哈希不变；JSON 报 `preservedUserFiles` | 同上 |
| 失败回滚 | 目标文件被占用时退出码非零、`decision=error`、树哈希恢复、缺失 0 | 同上 |
| 卸载 | 只删未修改的 8 个；本地改过的技能与无关目录保留 | 同上 |
| 客户端发现 | CLI 0.147.0 与 Desktop 引擎 0.163.0-alpha.10.2 均 **9/9**、`discoveryErrors=[]` | `artifacts/validation/phase45/install/discovery/*/verification.json` |
| MATLAB 自动启动 | 零进程冷启动 `READY` / `coldStartVerified=true`；已开实例时可 `-NewSession` 另开 | `artifacts/validation/phase44/desktop/20261020-220909_73ceab9e/startup_report.json` |
| 真实数值执行 | 自动打开的实例上 `matlabPid` 与启动报告 `runtimePid` 一致，控制题数值经独立解析器 PASS | `artifacts/validation/phase44/desktop/cold_control_task/result.json` |
| Agent 自主工程能力 | 三个自然语言任务（拟合/滤波/Simulink）由 Agent 自主完成后，独立验证器 **20/20、22/22、21/21** | `artifacts/validation/phase45/agent/trajectory.md` |

## 8. 未验证功能 / 已知限制（NOT VERIFIED）

| 项 | 状态与原因 |
|---|---|
| Codex CLI 自主执行（本轮） | **BLOCKED**：`chatgpt.com` / `api.openai.com` 本机不可达（10 s 超时，GitHub 可达）；客户端侧无法补救 |
| Codex Desktop 自主执行 | **NOT VERIFIED**：无可程序化 UI 通道；且同样受上述网络限制 |
| Desktop UI 层可见性/选中标识 | **NOT VERIFIED**：只能由引擎级 `skills/list` 与会话注入证明"被发现"，不能证明 UI 里可见 |
| Skills 是否带来可测量增益（R1/R2/R3） | **BLOCKED**：无可用 Agent 运行，故不作任何增益声明；任务/参考答案/验收规则已冻结（`artifacts/validation/phase45/benchmark/freeze_manifest.json`），runner 对 9 个 arm×task 全部输出 BLOCKED 并附网络证据，评分器自检 T1/T2/T3 = 18/18、17/17、51/51。待环境恢复后执行 |
| `ComDesktop` 启动模式 | **UNSUPPORTED**：本机 Windows Job 禁止 breakaway（Win32 5）；默认 `StartupCommand` 可依赖 |
| B7：holder `HOLDING` 未证明 bootstrap 已执行 | **DEFERRED**：本机无法创建 holder，无法验证；修法已写入 `docs/MATLAB_DESKTOP_STARTUP_ZH.md` |
| WSL / Linux / macOS | **未实测**：仅有路径解析逻辑，不能声称支持 |
| 只装 CLI 或只装 Desktop 的独立物理机 | **未实测** |
| 完整 Desktop UI 重启 | **未实测** |

## 9. 安全卸载与回滚

```powershell
# 卸载本项目管理的技能（只删 manifest 登记且未被本地修改的目录）
powershell -ExecutionPolicy Bypass -File .\scripts\Remove-Skills.ps1

# 回滚：每次同步的旧版本都在备份目录里
#   <SkillRoot>\.matlab-agent-skills\backups\<时间戳>-sync-skills\
# 失败时脚本会自动"只补缺失文件"恢复，被占用的文件保持原样；退出码非零表示需要人工复核
```

注意：
- 同步失败（任一技能 `decision=error`）时脚本**以非零退出**，不要当成成功。
- 冲突（外来同名目录）默认不覆盖、退出码 0；需要严格模式时加 `-Strict`（冲突退出 2）。
- 卸载不删除你的其它技能目录，也不改 MCP 配置。

## 10. 一个真实演示任务

自然语言（直接发给 Codex，不需要点名技能）：

```text
单位负反馈系统，开环传递函数 L(s)=10/((s+1)(s+2))。
请报告 0 dB 交越处的相位裕度、增益裕度、闭环是否稳定以及闭环极点，
并用官方 MATLAB MCP 在真实 MATLAB 里算，不要手算。
```

期望行为：Agent 路由到 `matlab-control-optimization`（并加载 `matlab-runner`），
经官方 MCP 执行，返回

```text
相位裕度 ≈ 55.862240°（解析值 55.862044°，误差 < 0.001°）
增益裕度 = Inf（无 -180° 相位交越）
闭环稳定，极点 = -1.5 ± 3.1224989992j
```

验收口径：数值必须来自 MATLAB 执行返回（不是模型口算）；`matlabPid` 必须等于当时
`sessionDetails.json` 中的 pid。

## 11. 发布前 checklist

- [x] 免费层 270/270（PS 5.1 + PS 7）
- [x] 安装验收 76/76 ×2 宿主，0 FAIL
- [x] 两端客户端 9/9 发现（引擎级）
- [x] 已去掉报告中的本机用户名路径
- [x] `.codex/`、`.workbuddy/`、`artifacts/`、`bin/` 均未进入版本库
- [ ] CLI/Desktop 自主执行（等网络恢复后补测）
- [ ] R1/R2/R3 增益评测（等 Agent 可运行后执行冻结方案）
- [ ] WSL/Linux/macOS 实机验证（不在本轮范围）

发布措辞约束：不得写"全平台兼容""全面自主执行""成功率提升"；只能说
"Windows 技术预览，安装与发现已验证，自主执行待环境恢复后补测"。
