# 第一阶段 P0 安装安全重构说明

本文记录 `matlab-agent-skills` 第一阶段 P0 缺陷审计、修复范围、安全模型与测试证据。
本轮只处理“安装器会破坏用户环境 / 装完用不了”的问题，不新增 Skills、不改 README 宣传文案、不引入 Octave 后端。

---

## 1. 审计范围与方法

审计对象：`scripts/` 下全部安装与配置相关脚本。

| 脚本 | 行数（改前） | 职责 |
| --- | --- | --- |
| `Bootstrap-MatlabAgentSkills.ps1` | 146 | 一键下载仓库 + 二进制 + 同步 skills + 接客户端 |
| `Install-MatlabMcpClients.ps1` | 298 | 基础配置 + 多客户端注册 |
| `Setup-MatlabMcpExistingSession.ps1` | 221 | Toolbox 安装、ACL、startup.m、Codex 注册 |
| `Sync-Skills.ps1` | 31 | skills 目录同步 |
| `Test-MatlabMcpExistingSession.ps1` | 72 | 会话状态探针（只读） |

方法：

1. 逐行读代码，定位所有写文件 / 改 ACL / 起外部进程 / 联网的语句。
2. 用官方 MATLAB MCP Server 参数文档校验参数合法性。
3. 用最小复现（临时目录 + 桩程序）确认每个缺陷的真实影响。
4. 修复后用 Pester 覆盖首次安装、重复安装、冲突配置、无 Codex、existing 模式、故障回滚。

---

## 2. 缺陷清单与复现路径

严重级：P0 = 会破坏用户环境或让功能完全不可用；P1 = 可靠性/可维护性缺陷；P2 = 体验问题。

### F-01 [P0] existing 模式携带非法参数 `--matlab-display-mode`

- 位置：`Install-MatlabMcpClients.ps1` 的 `Get-ServerArgs`、`Setup-MatlabMcpExistingSession.ps1` 的 `Ensure-CodexMcpServer`。
- 现象：两处都无条件拼接 `--matlab-display-mode=desktop`。
- 复现：`Install-MatlabMcpClients.ps1 -SessionMode existing -Clients generic -ProjectPath .` → 生成的 `.mcp.json` 里同时出现 `--matlab-session-mode=existing` 与 `--matlab-display-mode=desktop`。
- 影响：官方文档明确 `existing` 模式**不得**与 `matlab-root`、`initial-working-folder`、`matlab-display-mode` 同用；一旦这样配置，MCP server 启动即被参数校验拒绝，选择 existing 模式的用户 100% 连不上。
- 另：`--initialize-matlab-on-startup=true` 在 existing 模式下语义矛盾（不启动新会话），同样应省略。

### F-02 [P0] `.mcp.json` / `.vscode/mcp.json` 被整体覆盖

- 位置：`Install-VsCodeMcp`、`Install-GenericMcp`。
- 现象：新建一个只含 `matlab-official` 的对象，直接 `Set-Content` 覆盖目标文件。
- 复现：目标 `.mcp.json` 里已有 `my-own` server 和自定义顶层键 → 运行一次安装 → 只剩 `matlab-official`。
- 影响：用户其它 MCP server 配置永久丢失；无备份、无提示。
- 另：`Set-Content -Encoding UTF8` 在 Windows PowerShell 5.1 下会写 BOM，部分严格 JSON 解析器会失败。

### F-03 [P0] Codex / Claude 注册“先删后加”，失败后无法恢复

- 位置：`Install-CodexMcp`、`Install-ClaudeMcp`、`Ensure-CodexMcpServer`。
- 现象：先 `mcp remove`，再 `mcp add`；add 失败（参数错、权限、磁盘）时旧注册已删除。
- 影响：一次失败就把用户原本可用的 MCP 注册干掉；同日重复执行也总是产生两次破坏性操作。
- 另：`codex mcp list` 用 `2>$null` 吞掉错误，`$LASTEXITCODE` 未检查。

### F-04 [P0] 基础配置与 Codex 强耦合

- 位置：`Setup-MatlabMcpExistingSession.ps1` 结尾无条件调用 `Ensure-CodexMcpServer`；`Install-MatlabMcpClients.ps1` 先跑基础配置（内含 Codex 注册）再自己注册一遍。
- 复现：机器上没有 codex、只想接 Claude → `-Clients claude` → 基础配置在 `& codex mcp list` 处抛 “不是内部或外部命令”，整个安装中止，Claude 一个都没配上。
- 影响：无法单独配置 Claude；且 Codex 被注册两次（`remove`+`add` 两轮）。

### F-05 [P0] `Sync-Skills` 无冲突检测、无备份、整目录删除

- 位置：`Sync-Skills.ps1`。
- 现象：目标目录存在就 `Remove-Item -Recurse -Force`，再整目录复制。
- 复现：用户手改过 `~/.codex/skills/matlab-runner/SKILL.md` → 再跑同步 → 修改被无声抹掉。
- 影响：本地定制丢失；也无法区分“本项目管理的目录”和“碰巧同名的外来目录”。

### F-06 [P0] `startup.m` 被隐式重写，无法定向回滚

- 位置：`Ensure-StartupShare`。
- 现象：直接 `Set-Content` 重写整个 `startup.m`；仅用 `-notmatch "shareMATLABSession"` 做去重。
- 影响：
  - 用户自己已经写过 `shareMATLABSession` 调用时会被误判为“已安装”而跳过，MCP 实际没配上；
  - 重复执行可能追加重复块；
  - 没有备份，改坏了只能手工回忆原文；
  - PS 5.1 下写 BOM，改变文件编码。

### F-07 [P0] ACL 修改剥离继承且不可回滚

- 位置：`Ensure-McpAcl`。
- 现象：`icacls /inheritance:r /grant:r <当前用户> <SYSTEM> <Administrators>` —— 一次把继承 ACE 全移除并重写整个授权列表。
- 影响：icacls 部分失败或 SID 解析异常时，目录可能对当前用户/SYSTEM 都不可访问；没有原始 SDDL 快照，无法回滚。

### F-08 [P0] 远程二进制下载无任何校验

- 位置：`Resolve-ServerExePath`、`Ensure-McpBinary`。
- 现象：`Invoke-WebRequest` 直接写最终路径；无哈希、无签名、无大小检查；下载失败会留下 0 字节或错误页文件；`-McpServerDownloadUrl` 可传任意 URL（含 http）。
- 影响：供应链完整性无保障；半截文件被当成可用二进制执行；Bootstrap 每次强制重下（不幂等）。

### F-09 [P1] 四个安装脚本都没有 DryRun / 回滚

- 影响：中途失败留下“半配置”状态（Toolbox 装了、ACL 改了、startup 写了、客户端没注册），用户无从判断如何恢复。

### F-10 [P0] 机器专属绝对路径

- `matlab/validation/matlab_feature_probe.m`：把外部技能目录硬编码为某台机器 E 盘 desktop 下的固定路径。
- `matlab/stm32_temp_fan_closed_loop.m`：Keil 路径兜底值硬编码为某台机器 E 盘下的固定安装位置。
- 影响：换机器后 feature probe 恒为 false；Keil 探测用错误路径。
- 为什么 CI 没拦住：`repository-checks.yml` 的路径检查只扫 `README.md` + `docs/` + `scripts/` + `.github/`，漏了 `matlab/`。
- 附带语义修正：`agentic.hasLocalAutomation` 原为“本地仓库 **且** 该固定机器路径存在”，现在改为“本地仓库 **或** 环境变量指定的外部目录存在”，避免结论绑定某台机器的目录布局。

### F-11 [P1] 幂等性缺失

- `Ensure-McpBinary` 每次强制重新下载；`Ensure-Repo` 的 ZIP 分支用 `Copy-Item -Force` 覆盖且删除共用临时目录；Codex/Claude 每次 `remove`+`add`；`Sync-Skills` 无变更检测。重复安装总是产生写操作。

### F-12 [P1] Windows PowerShell 5.1 下脚本无法解析

- 现象：所有脚本是**无 BOM 的 UTF-8**，含中文注释与字符串。Windows PowerShell 5.1 按 ANSI 解码，导致字符串未终止、括号不匹配等语法错误。
- 复现：`powershell -ExecutionPolicy Bypass -File .\scripts\Install-MatlabMcpClients.ps1`（即 README 里给用户的命令）在 PS 5.1 下解析即失败，`pwsh` 7 才正常。
- 影响：README 承诺的用法在默认 Windows 环境不可用。

### F-13 [P2] 测试缺失

- 只有 `Test-MatlabMcpExistingSession.ps1` 一个探针（依赖真实 MATLAB + Codex），CI 只做 `ParseFile` 语法检查，没有任何参数化回归测试。

---

## 3. 修复设计

### 3.1 新增共享核心模块

`scripts/MatlabAgentSkills.Core.psm1`：把“要不要改、怎么改、改坏了怎么退”的逻辑集中，供四个脚本复用并被测试直接调用。

关键约定：

- 纯决策函数不碰文件系统，可脱离 MATLAB / Codex / Claude 单测；
- 所有写操作支持 `-DryRun`；
- 所有写操作在写之前登记到“备份会话”，失败可 `Invoke-BackupRollback` 逆序回退；
- 备份目录**延迟创建**：没有真实变更就不落盘，保证重复安装零写入。

### 3.2 参数构造（对应 F-01）

`New-MatlabMcpServerArgs` 按官方约束裁剪：

| SessionMode | `--matlab-session-mode` | `--matlab-display-mode` | `--matlab-root` | `--initialize-matlab-on-startup` |
| --- | --- | --- | --- | --- |
| `auto` | ✓ | ✓（默认 desktop，可 nodesktop/省略） | ✓ | 按需 |
| `new` | ✓ | ✓ | ✓ | 按需 |
| `existing` | ✓ | ✗ 强制省略 | ✗ 强制省略 | ✗ 强制省略 |

被省略的参数会进 `DroppedArguments` 并打印告警，安装摘要里也能看到，便于审计。
`Test-McpServerArgsCompatible` 作为二次自检：如果拼出的参数仍违规，脚本直接抛错而不是写出坏配置。

### 3.3 配置安全合并（对应 F-02）

`Merge-McpServerConfig`：

1. 读现有文件 → 解析失败**直接中止**（绝不把坏文件换成空配置）；
2. 只替换 `servers.<name>` / `mcpServers.<name>` 一个键，其余键与其它 server 原样保留，键顺序保持；
3. 内容相同 → `unchanged`，不写文件、不建备份；
4. 内容不同 → 先备份原文件再写；
5. 写入用临时文件 + `Move-Item -Force` 原子替换，UTF-8 **无 BOM**。

### 3.4 客户端注册解耦与幂等（对应 F-03 / F-04）

- `Setup-MatlabMcpExistingSession.ps1` 默认 `-Client codex`，但**检测不到 codex 只告警不中断**；新增 `-SkipClientRegistration`，`Install-MatlabMcpClients.ps1` 调用基础配置时固定传它，注册只做一次。
- `Register-ClientMcpServer`：先 `mcp get` 对比期望参数，一致则 `unchanged`（完全不碰）；需要变更时先把旧配置文本 + 解析出的 command/args 写入备份清单，再 `remove` + `add`；`add` 失败或 `get` 校验不通过立即尝试还原，并保留快照路径供人工恢复。

### 3.5 Skills 同步（对应 F-05）

- 用目录指纹（相对路径 + 文件 SHA256 聚合）判断 install / unchanged / update / conflict。
- `<SkillRoot>/.matlab-agent-skills-manifest.json` 记录“本项目管理的技能目录”。
- 非托管目录内容不同 → **默认不动**，报告中列为 conflict，需要显式 `-Force`。
- 覆盖前整目录备份到备份会话；替换通过暂存目录完成，失败可还原。
- `-Prune` 只清理“已从仓库移除”且“本地未被修改”的托管目录。

### 3.6 startup.m 托管块（对应 F-06）

- 写入内容用 `% BEGIN matlab-agent-skills ...` / `% END ...` 包住，重复执行只替换托管块；
- 统一成“单个结尾换行”再比较，第二次执行判定 `unchanged`，文件逐字节不变；
- 用户已有自己的 `shareMATLABSession` 调用（无托管标记）→ `skipped-foreign-hook`，完全不改文件；
- 写前备份原文件；UTF-8 无 BOM。

### 3.7 ACL 与下载（对应 F-07 / F-08）

ACL：

- 默认**追加式**授权：只对当前用户 SID 执行 `/grant:r`，不删其它 ACE、不剥离继承；
- 需要复刻历史行为时显式 `-RestrictAclInheritance`；
- 改动前快照 SDDL 记入备份清单，回滚时用 `SetSecurityDescriptorSddlForm` 还原；
- 写入后校验 SID 是否真的生效，不生效直接抛错触发回滚；
- 命令形态（`icacls ... /grant:r *SID:(OI)(CI)F`）写入摘要，可审计。

下载：

- 只允许 HTTPS（除非显式 `-AllowInsecure`）；
- 先落 `<dest>.part-<guid>`，校验最小字节数，可选 `-ExpectedServerSha256`（大小写/分隔符无关）；
- 校验通过才 `Move-Item` 到最终路径，失败清理临时文件；
- 未提供哈希时打印告警，并把实际 SHA256 记入安装摘要；
- 已存在文件默认复用（幂等），`-ForceDownload` 才重下。

### 3.8 机器路径与编码（对应 F-10 / F-12）

- `matlab_feature_probe.m`：外部技能目录改由环境变量 `MATLAB_AGENT_SKILLS_EMBEDDED_ROOT` 注入，未设置即 false，不再硬编码；
- `stm32_temp_fan_closed_loop.m`：新增 `findKeilExecutable`，按 `KEIL_EXE` → 常见安装根目录探测，找不到给明确 warning；
- 所有 `.ps1` / `.psm1` 统一为 UTF-8 **with BOM**，保证 Windows PowerShell 5.1 能正确解析；
- CI 的机器路径检查从“只扫 docs/scripts”扩展到全仓库，并新增 BOM 检查与 Pester 测试任务。

---

## 4. 向后兼容

保留全部原有公开参数与默认值：

- `Setup-MatlabMcpExistingSession.ps1`：`-ServerExePath -MatlabRoot -McpServerName -McpServerDownloadUrl -SessionMode -InitializeMatlabOnStartup -WriteStartupShare`
- `Install-MatlabMcpClients.ps1`：`-ServerExePath -MatlabRoot -ServerName -McpServerDownloadUrl -SessionMode -InitializeMatlabOnStartup -Clients -ProjectPath -SkipBaseSetup`
- `Sync-Skills.ps1`：`-RepositoryRoot -SkillRoot`
- `Bootstrap-MatlabAgentSkills.ps1`：`-InstallDir -RepoUrl -RepoZipUrl -McpServerDownloadUrl -ServerName -SessionMode -InitializeMatlabOnStartup -Clients -MatlabRoot`
- 内部函数 `Get-ServerArgs` 的旧扁平形状由 `Get-MatlabMcpServerArgv` 保留（第 0 项是 exe）。

新增参数全部是可选的开关：`-DryRun -Force -BackupRoot -DisplayMode -NoDownload -ForceDownload -ExpectedServerSha256 -SkipClientRegistration -Client -SkipAclFix -RestrictAclInheritance -McpDataDir -StartupDirectory -NoGeneric -Prune -Strict -SkipSkillsSync -FailAfterStep`。

**语义变化（有意为之，均只影响错误用法或危险默认值）：**

1. `existing` 模式不再输出 `--matlab-display-mode` / `--matlab-root` / `--initialize-matlab-on-startup`——这是官方不允许的组合。
2. 没有 Codex 时基础配置不再失败，改为告警跳过。
3. `.mcp.json` / `.vscode/mcp.json` 改为合并，不再整文件覆盖。
4. `Sync-Skills` 遇到“非本项目管理的同名目录”默认不覆盖（此前会删除）。
5. ACL 默认追加授权，不再剥离继承（`-RestrictAclInheritance` 可复刻旧行为）。

---

## 5. 测试证据

运行命令（本机 Windows PowerShell 5.1，Pester 3.4.0）：

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1
```

| 测试文件 | 用例数 | 结果 |
| --- | --- | --- |
| `tests/MatlabAgentSkills.Core.Tests.ps1` | 39 | 39 passed / 0 failed |
| `tests/Installer.Scenarios.Tests.ps1` | 22 | 22 passed / 0 failed |
| 合计 | 61 | 61 passed / 0 failed |

覆盖矩阵：

| 要求 | 对应用例 |
| --- | --- |
| 首次安装 | 首次安装 generic / vscode / claude，配置结构与 args 断言 |
| 重复安装 | `.mcp.json` 二次安装字节不变 + `unchanged`；`Sync-Skills` 二次全 unchanged 且不新建备份目录；Claude 二次注册 unchanged |
| 冲突配置 | 已有 `my-own` server 保留；非法 JSON 中止且原文件字节不变；外来同名 skills 目录默认不动 |
| 无 Codex | PATH 只放 claude 桩 → 仍成功注册 Claude；显式 `-Clients codex` 且未安装 → 明确报错 |
| existing 模式 | 生成的 `.mcp.json` 无 display-mode/root/initialize；注册到 claude 的文本同样不含 |
| 故障回滚 | codex `add` 瞬时失败 → 恢复旧的 `command/args`；Setup 在 startup 步骤后注入失败 → `startup.m` 还原为用户原文 |
| DryRun | install / sync / setup / 下载 / 合并 全部零写入 |
| 仓库卫生 | 无 E/D 盘硬编码路径；所有脚本可被 PS 5.1 解析；含中文的脚本带 BOM |

CI 侧新增：`repository-checks.yml` 增加 `installer-tests` 任务（`pwsh` 下跑 Pester），并把机器路径检查扩到全仓库 + 新增 BOM 检查。

---

## 6. 未在真实环境验证的项目

以下项目需要真实 MATLAB / 真实客户端，本轮**没有**在真机验证，只做了参数级与沙箱级验证：

1. `matlab-mcp-server --setup-matlab` 真实安装 Toolbox 的返回值与副作用（测试里用返回 0 的桩程序代替）。
2. 真实 MCP server 在 `existing` / `auto` / `new` 三种模式下的握手行为与工具可用性。
3. `icacls` 对真实 `%APPDATA%\MathWorks\MATLAB MCP Server` 目录的最终授权结果（测试只在临时目录验证追加与还原语义）。
4. `startup.m` 托管块在 MATLAB 启动时是否真的成功执行 `shareMATLABSession()`。
5. 真实 `codex mcp add` / `claude mcp add` 的参数形态与 `mcp get` 输出格式（测试用桩程序模拟，解析器已做成宽松 + 失败可降级）。
6. 真实二进制下载的 SHA256 校验（本轮没有硬编码官方哈希；需要维护者补充 `-ExpectedServerSha256` 或提供签名清单）。
7. `Bootstrap` 的 git clone / ZIP 分支只做了 `-DryRun` 冒烟，未做全量真实安装。

建议在合并后由维护者在装有 MATLAB R2023a+ 的机器上补一次真实链路验证，并把结果追加到 `docs/VALIDATION.md`。
