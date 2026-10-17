# Changelog

All notable changes to this project will be documented here.

## Unreleased

### 安装器安全重构（第一阶段 P0）

- Fixed: `existing` 会话模式不再输出 `--matlab-display-mode` / `--matlab-root` / `--initialize-matlab-on-startup`，此前会被官方 MCP server 直接拒绝。
- Fixed: `.mcp.json` 与 `.vscode/mcp.json` 改为安全合并，保留用户已有的其它 server 与其它顶层键；JSON 非法时中止而不是覆盖。
- Fixed: Codex / Claude 注册改为幂等 + 快照 + 失败还原，不再“先删后加”导致注册丢失。
- Fixed: 基础 MCP 配置与客户端注册解耦，未安装 Codex 时也能单独配置 Claude Code。
- Fixed: `Sync-Skills` 增加目录指纹与 manifest，冲突默认不覆盖，更新前整目录备份。
- Fixed: `startup.m` 使用托管标记块，重复执行逐字节幂等，写前备份，用户自建钩子不覆盖。
- Fixed: ACL 改为追加式授权（默认不剥离继承），改动前快照 SDDL 并可回滚。
- Fixed: 二进制下载强制 HTTPS，支持 SHA256 校验、临时文件与原子替换，已存在文件默认复用。
- Fixed: 移除 MATLAB 验证脚本中的机器专属绝对路径（外部技能目录改由环境变量注入，Keil 改为可移植探测）。
- Fixed: PowerShell 脚本统一为 UTF-8 with BOM，修复 Windows PowerShell 5.1 下无法解析的问题。
- Added: `scripts/MatlabAgentSkills.Core.psm1` 共享核心模块（参数裁剪、JSON 合并、备份回滚、目录指纹、ACL、下载校验）。
- Added: 安装器统一支持 `-DryRun`、`-BackupRoot`、`-Force`，失败自动逆序回滚。
- Added: Pester 测试套件（`tests/`），覆盖首次安装、重复安装、冲突配置、无 Codex、existing 模式与故障回滚。
- Added: CI 增加安装器测试任务、全仓库机器路径检查与 BOM 检查。
- Docs: 新增 `docs/P0_HARDENING_ZH.md`（缺陷清单、修复设计、测试证据、未验证项）。

### 执行引擎与工程验收体系重构（第二阶段 P1）

- Added: `schemas/acceptance-report.schema.json` —— 统一验收协议的唯一定义源（JSON Schema draft-07 子集）。
- Added: `scripts/MatlabAgentSkills.Acceptance.psm1` —— 报告构造、UTF-8 读写、纯 PowerShell schema 校验器、语义校验、子报告合并、退出码映射。
- Added: `matlab/validation/+masacc/` —— MATLAB 侧同形状报告生成（`new` / `addCheck` / `classifyError` / `write`），与 PowerShell 侧字段完全一致。
- Added: `scripts/MatlabAgentSkills.Execution.psm1` —— 8 类错误分类、有限重试、进程超时与进程树终止、阶段日志、MATLAB 安装解析。
- Added: `scripts/MatlabAgentSkills.McpProbe.psm1` —— MCP 五阶段探测（安装 / 会话配置 / 客户端注册 / 协议握手 / 只读执行 / 文件回读）。
- Added: `tests/` 三个新套件（`Acceptance.Protocol.Tests.ps1` 21 例、`Execution.Reliability.Tests.ps1` 26 例、`McpProbe.Tests.ps1` 13 例）与 `tests/helpers/FakeMcpServer.ps1` 故障注入服务端。
- Added: `tests/RealExecution.Matlab.Tests.ps1`（matlab 层），验证真实 MATLAB 解析、真实 `-batch` 执行与真实超时终止。
- Added: 测试分层执行 —— `tests/Invoke-Tests.ps1 -Layer free|matlab|all`，并落盘 `artifacts/validation/tests/layer_report.json` 记录哪一层真的执行过。
- Fixed: MCP 可用性不再由 `pid` 或配置文件是否存在推断；`ready` / `autoModeReady` 改为五阶段独立判定，任一段失败后续段 SKIP。
- Fixed: `codegen` 的"生成源码"与"真实编译"拆成 L1 / L2 两个检查项，不再用代码生成冒充编译成功。
- Fixed: `simulink_coder_smoke.m` 增加模型重载、`update`、仿真数值比对、增益扫描，不再只判断 `.c` 文件存在。
- Fixed: 编译链路增加 5 组 golden 数值比对与 NaN / 非法尺寸 / 大数鲁棒性检查，此前 golden 结果未被使用。
- Fixed: 缺少许可证或工具箱时输出带原因的 SKIP，不再伪造成功状态；`Test-MatlabEmbeddedStack.ps1` 移除硬编码 `matlabValidation.passed = $true`。
- Fixed: 所有长任务增加可配置超时（`-TimeoutSeconds`）、阶段日志与超时进程树终止，超时返回 `124`。
- Fixed: PowerShell 5.1 下 `ConvertFrom-Json` 对 UTF-8 BOM-less 文件按 ANSI 解码导致 schema 解析失败；新增 `Read-AcceptanceJsonFile` 显式 UTF-8 读取。
- Fixed: PowerShell 5.1 下 `Start-Process` 在环境变量存在大小写重复键（`HTTPS_PROXY` / `https_proxy`）时抛"字典中的关键字重复"；改用 `ProcessStartInfo`。
- Fixed: PowerShell 5.1 下 `@($list)` 对 `List[object]` 抛"参数类型不匹配"；统一改用 `$list.ToArray()`。
- Changed: `Test-MatlabSkills.ps1` 改为 6 阶段编排，逐阶段产出并合并验收报告，退出码区分 PASS/FAIL/SKIP。
- Changed: CI 分为层 A（免费环境，仅 free 层）与层 B（带许可证的 MATLAB 环境），层 C（Pro 许可证 / 硬件）明确标注为不在默认 workflow 执行。
- Docs: 重写 `docs/VALIDATION.md`；新增 `docs/P1_ACCEPTANCE_ZH.md`（缺陷清单、设计、证据、未验证项）。

- Added MCP-first MATLAB workflow documentation.
- Added one-command MCP client installer for Codex, Claude Code, VS Code, and generic MCP clients.
- Added bootstrap installer for downloading skills, syncing local skills, and configuring MATLAB MCP.
- Added Chinese project introduction and short-video script drafts.
- Added STM32 / Raspberry Pi embedded toolchain acceptance checks.
