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
- Fixed: `Invoke-MatlabBatch.ps1` 用 `run()` 执行脚本，但 MATLAB 的 `run` 只接受合法标识符：脚本名含连字符、以数字或下划线开头时直接抛 `MATLAB:m_illegal_character`。现在遇到非法标识符会在同目录建一个合法标识符的别名副本，跑完即删（必须同目录，否则 `mfilename('fullpath')` 解析出的仓库根会错）；`-Code` 生成的临时脚本名也改成合法标识符。
- Fixed: `Merge-AcceptanceReport` 在父报告 `toolboxInventory` 为空时继承子报告清单，否则主报告里这个字段只是空数组（空数组同样满足 schema，等于"有字段没内容"）。
- Fixed: `RealExecution.Matlab.Tests.ps1` 的别名用例改为从 summary 的 `stdout=` 读 MATLAB 真实输出日志，而不是匹配封装脚本的控制台输出。
- Fixed: `+masacc/new.m` 用 `computer("os")` 取 OS 触发 `MATLAB:badopt`，六个验收脚本在真机上全部在第 26 行挂掉；改为 `string(computer)`。
- Fixed: `+masacc/write.m` 直接 `jsonencode(report)` 时，只有一条检查项的结构体数组会被编码成 JSON 对象，导致 PowerShell 侧 schema 校验报 `$.checks 类型应为 array，实际为 object`；改为 `num2cell` 强制数组。
- Fixed: `simulink_coder_smoke.m` 用 `"StepTime"` 设置阶跃时刻，真机报 `Step block 没有名为 'StepTime' 的参数`；按实测 `DialogParameters` 改为 `"Time"`。
- Fixed: `matlab_skill_smoke.m` 的 Sine 仿真只跑到 1 秒、2 秒，峰值/谷值永远到不了 ±2（实测 1.6829 = 2·sin(1)、谷值 0.0000）；改为 5 秒覆盖 3π/2 并设 `MaxStep=0.01`，采样点 51 → 501。
- Fixed: PowerShell 5.1 下 `ConvertFrom-Json` 对 UTF-8 BOM-less 文件按 ANSI 解码导致 schema 解析失败；新增 `Read-AcceptanceJsonFile` 显式 UTF-8 读取。
- Fixed: PowerShell 5.1 下 `Start-Process` 在环境变量存在大小写重复键（`HTTPS_PROXY` / `https_proxy`）时抛"字典中的关键字重复"；改用 `ProcessStartInfo`。
- Fixed: PowerShell 5.1 下 `@($list)` 对 `List[object]` 抛"参数类型不匹配"；统一改用 `$list.ToArray()`。
- Changed: `Test-MatlabSkills.ps1` 改为 6 阶段编排，逐阶段产出并合并验收报告，退出码区分 PASS/FAIL/SKIP。
- Changed: CI 分为层 A（免费环境，仅 free 层）与层 B（带许可证的 MATLAB 环境），层 C（Pro 许可证 / 硬件）明确标注为不在默认 workflow 执行。
- Docs: 重写 `docs/VALIDATION.md`；新增 `docs/P1_ACCEPTANCE_ZH.md`（缺陷清单、设计、证据、未验证项）。
- Tested: `-Layer free` 122 例全通过、退出码 `0`；`-Layer matlab` 5 例全通过、退出码 `0`（含真实 `-batch` 执行 18.8 s、真实超时终止 45.7 s、非法脚本名别名 19.7 s）。
- Tested: `Test-MatlabSkills.ps1` 在本机 MATLAB R2026a 上真实跑完六个阶段：19 项检查中 12 项 PASS、7 项 SKIP（均为 MATLAB Coder / Simulink Coder 未授权，或目标 API 未检测到）、0 项 FAIL；整体按"存在 SKIP 即 SKIP"判为 `SKIP`（退出码 3），因 L1 存在 SKIP，按连续达成规则 `achievedLevel=L0`。
- Note: 排查中发现 Windows PowerShell 5.1 下读取 `ProcessStartInfo.EnvironmentVariables` 会得到空集合，子进程因此拿不到 `SystemRoot`/`TEMP`/`PATH`，MATLAB 直接 abort（0x00000003）。执行模块已加注释禁止该用法；据此否决了曾考虑过的 `-ClearProxyEnvironment` 方案（代理不是根因，带代理同样 16 秒启动成功）。

### 最终验收修复（第二阶段 2.2）

#### 许可证检测纠正（上一轮 7 个 SKIP 的根因）

- Fixed: `license('test', <产品名>)` 是错误用法 —— 第二个参数要的是 **license feature 名**。
  实测 R2026a：`MATLAB Coder` → `0`，而 `MATLAB_Coder` → `1`；`Simulink Coder` → `0`，而 `Real-Time_Workshop` → `1`；
  `Embedded Coder` → `0`，而 `RTW_Embedded_Coder` → `1`。此前据此判定"Coder 未授权"，导致整条 Coder 验收 SKIP。
- Added: `+masacc/featureName.m` —— 产品名 → feature 名映射表（101 条，逐条在本机实测确认）。
- Added: `+masacc/licenseState.m` —— 三态授权判定（`true` / `false` / `[]` 无法判定），记录 `featureSource`
  与 `note`，不再把"测不了"写成"没授权"。
- Added: `+masacc/executionProbe.m` —— 真实执行探针（`coder.typeof` + `coder.config`、`new_system`），
  区分"有许可证"与"能执行"。
- Fixed: `license('test')` 的 feature 字符串 **上限 27 字符**，超长抛 `MATLAB:license:toomanychars`。
  旧代码用 `catch` 吞成 `[]` 且不留原因；现在明确记为"无法判定"并说明是该 API 限制。
- Fixed: 归一化猜测（空格→下划线）只用于**确认**授权，返回 `0` 时记"未知"。
  实测反例：`Simulink_Coder` 为 `0`，而真实 feature `Real-Time_Workshop` 为 `1`。
- Fixed: `+masacc/availability.m` 重写为 `installed` / `licenseFeature` / `licenseExists` /
  `executionProven` / `available` / `provenBy` / `reason`；`available` 不再等同于"已安装"。
- Fixed: `+masacc/inventory.m` 与 `matlab_toolbox_inventory.m` 去掉重复的 `license('test', 产品名)`，
  改为三态并附 `licenseFeature` / `licenseSource`。
- Added: `inventory.gated-license` 检查 —— 核心产品（MATLAB / Simulink / 三个 Coder）的授权结论必须是
  确定的布尔值，不允许停留在"无法判定"。
- Fixed: `matlab_feature_probe.m` 此前用"已安装"给 Coder / 块集放行，改为按 `available` 判定，
  并把"未安装"与"已安装但不可用"区分成两种 SKIP 原因。
- Tested: 117 个产品清点结果 **95 授权 / 5 未授权 / 17 无法判定**（修复前是 4 / 113，其中 17 个无原因）。

#### 依赖检查顺序

- Fixed: `matlab_codegen_smoke.m` 在依赖检测**之前**就调用 `coder.typeof` 构造参数，
  缺少 MATLAB Coder 时会抛出未捕获异常，根本走不到 SKIP 分支。参数构造已移入受保护的 try 块。
- Added: `tests/DependencyOrder.Tests.ps1` —— 静态扫描全部验证脚本，断言首次 `coder.typeof` /
  `coder.config` / `codegen` / `slbuild` 调用必须晚于首次 `masacc.availability`，且 `coder.typeof`
  必须位于 try 块内（8 个用例）。

#### CI 门禁按能力范围判定

- Added: `Test-MatlabSkills.ps1 -Scope core|simulink|coder|full`，范围只决定门禁与退出码，
  **不修改** `overallStatus`，也不删除任何检查项；范围外的 SKIP 原样保留在报告里。
- Added: `Get-AcceptanceScopeDefinition` / `Get-AcceptanceScopeStatus` / `Get-AcceptanceScopeEvaluations` /
  `Get-AcceptanceScopeExitCode`。必选 FAIL → `FAIL`；必选 SKIP 或未产出 → `SKIP`；全部必选 PASS → `PASS`。
- Added: 报告新增 `scope`（所选范围）与 `scopes`（四个范围全量求值），schema 同步增补定义。
- Changed: `matlab-validation.yml` 重写为 `core` 门禁 job + `coder` 可选 job（仅 `workflow_dispatch`
  且显式申请 Coder 产品时创建，push / PR 上不存在）。CI 只依据声明的必选能力判定成败，
  可选能力的 SKIP 全部保留在报告与 artifact 中。

#### 测试与 CI 的真实性

- Fixed: **CI 三轮全红的根因是 Pester 版本选择。** runner 上同时预装 Pester 3.4.0 与 5.9.0，
  旧实现 `Sort-Object Version -Descending | Select -First 1` 选中 5.9.0，而套件使用 Pester 3 的
  `Should Be` 语法，直接抛 `Legacy Should syntax is not supported in Pester 5`，124 个用例全失败。
  本机只有 3.4.0，所以本地一直全绿——这个 bug 只在 CI 暴露。
- Fixed: `tests/Invoke-Tests.ps1` 改为按 `主.次.构建` 精确匹配 `-PesterVersion`（默认 `3.4.0`），
  绝不降级/升级到别的的主版本；本地缺失时下载到 `artifacts/.pester`，仍缺失则抛错说明原因。
  选择逻辑抽为纯函数 `tests/helpers/PesterSelection.ps1`。
- Added: `tests/PesterSelection.Tests.ps1`（11 例）锁死"必须选 3.4.0、只有 5.x 时必须返回 null"。
- Fixed: **Pester 3.4 的 `Should Throw` 在 PowerShell 7 上不生效**，全部"应当抛错"的用例会失败，
  报 `Expected: the expression to throw an exception`。新增 `tests/helpers/Assertions.ps1` 的
  `Test-Throws`（try/catch 实现），把 11 处断言改为版本无关写法。
- Fixed: **`Get-JsonValueKind` 不认 `[datetime]`**。PowerShell 7 的 `ConvertFrom-Json` 会把 ISO 8601
  字符串自动解析成 `[datetime]`，于是一份完全合法的报告被判成
  `$.startedAt 类型应为 string，实际为 unknown`。现在把 `[datetime]` / `[datetimeoffset]` 按 string 处理，
  `date-time` 格式校验也改用 ISO 文本比对。
- Changed: 层 A 的 `free-tests` 用两个显式 shell 步骤（`powershell` 与 `pwsh`）跑同一套用例；
  `layer_report.json` 新增 `powerShellVersion` / `powerShellEdition`，让"用哪个运行面跑的"可审计。
- Fixed: **ACL 授权校验把成功的授权误判成失败并回滚。** `Get-Acl` 生成的 SDDL 会把知名 SID
  渲染成别名（`S-1-5-21-…-500` → `LA`，`S-1-5-18` → `SY`），旧实现用"SDDL 里搜 SID 字面量"判断，
  于是任何以本地内置管理员（RID 500）身份运行安装器的场景都会失败。新增
  `Test-AclContainsSid`（`GetAccessRules(..., SecurityIdentifier)` 按 SID 语义比较）并替换校验；
  回归用例用 `LocalSystem` 授权，先证明字面量搜索必然落空，再断言语义比较为真。
- Fixed: `-Layer matlab` 增加可执行性预检（`matlab -batch "disp(version)"`）。
  "装了 MATLAB" 与 "MATLAB 能跑" 分开判定：预检失败时本层记为**未执行**（退出码 2，reason 含退出码与
  stderr 尾部），而不是让 5 个与被测代码无关的用例全红。`layer_report.json` 新增
  `matlabAvailable` / `matlabRunnable` / `matlabRunFailure`。
- Fixed: `McpProbe.Tests.ps1` 的"全套正常"用例不再硬断言整体 `PASS`。没有 MATLAB 的运行面上
  `mcp.matlab-install` 必然 FAIL（这是正确行为），用例改为按该项真实结果推导整体状态，
  并要求 FAIL 只能由该项引起。
- Changed: `matlab-validation.yml` 的层 B job 需要仓库变量 `MATLAB_VALIDATION_ENABLED=true`
  与 Secret `MLM_LICENSE_FILE` 才运行；未配置时显示 skipped 而不是 passed
  （公共 runner 没有许可证，`-batch` 1~2 秒即失败，跑出来的红灯与被测代码无关）。
- Tested: `Repository Checks` 在 GitHub 上**真实通过**：`层 A - 免费测试（5.1 + 7 双运行面）`
  两步各 162/162。此前三轮 CI 分别因 Pester 版本选择、PowerShell 7 语义差异、ACL SID 别名而红，
  三个根因都已定位并修复，不是"重跑就好了"。
- Added: `tests/Acceptance.Boundary.Matlab.Tests.ps1` + `matlab/validation/tests/masacc_boundary_probe.m` ——
  MATLAB 侧产出 9 类边界报告（单条/多条检查、全空字段、空清单、中文原因、许可证缺失、
  授权无法判定、运行异常、空报告拒绝），PowerShell 侧用同一份 schema 逐项校验（69 个断言）。
- Added: `Acceptance.Protocol.Tests.ps1` 增补 20 个用例：验收范围语义、`exitCode` / `durationSeconds` /
  `errorClass` / `licensed` 的取值域、单条检查数组编码、原子覆盖写。
- Fixed: 覆盖写报告不是原子操作。旧实现 `Remove-Item` + `Move-Item` 之间存在真空期，
  删除失败（被安全删除钩子拦截、文件被占用）会留下"目标消失、临时文件还在"的破损状态。
  改为 `File.Replace` / `File.Move` 单步替换，并新增回归用例。

#### 真机执行抓到的两个被掩盖的缺陷

- Fixed: `codegen -d <变量名>` 的命令行解析器把变量名当**字面量**，实测在当前目录建出名为 `genDir`
  的文件夹，产物落在那里，而断言去绝对路径找，表现为"codegen 成功但找不到产物"。
  `matlab_codegen_smoke.m` 与 `matlab_compiler_chain_smoke.m` 均改为切到目标目录执行，
  产物查找改回递归（真实产物在 `<dir>/codegen/lib/<fcn>/` 下）。
  这两个脚本此前从未真正跑到这一步，缺陷一直被许可证误判掩盖。
- Docs: `skills/matlab-runner/SKILL.md`、`skills/matlab-simulink-modeling/SKILL.md` 更正
  `license('test', product)` 的错误示例，补充产品名 → feature 名对照表与 27 字符限制。
- Tested: `-Layer free` **162 例全通过**、退出码 `0`，且在 Windows PowerShell 5.1 与 PowerShell 7.6
  两个运行面上各跑一遍都通过——这一条是 GitHub Actions 的真实结果，不是本地推测
  （`Repository Checks` 运行 39028581728 成功，层报告 artifact 记录了两个运行面的版本号）。
- Tested: `-Layer matlab` **74 例全通过**、退出码 `0`，在 PowerShell 5.1 与 7.6 两个运行面各跑一遍均通过
  （含 MATLAB 侧边界往返 69 个断言）。这一层需要真实许可证，公共 runner 上无法执行，见下一条。
- Tested: `Test-MatlabSkills.ps1 -Scope full` 在 R2026a 上真实跑完六个阶段：
  **20 项检查 19 PASS / 1 SKIP / 0 FAIL**；`core` / `simulink` / `coder` 三个范围均 PASS，
  `full` 因 `embedded.hardware-in-loop` 未执行而 SKIP（退出码 3）。唯一 SKIP 是
  `feature.direct-import`（目标 API 未检测到），不是许可证问题。
  与修复前对比：同机同环境从 12 PASS / 7 SKIP 变为 19 PASS / 1 SKIP。

- Added MCP-first MATLAB workflow documentation.
- Added one-command MCP client installer for Codex, Claude Code, VS Code, and generic MCP clients.
- Added bootstrap installer for downloading skills, syncing local skills, and configuring MATLAB MCP.
- Added Chinese project introduction and short-video script drafts.
- Added STM32 / Raspberry Pi embedded toolchain acceptance checks.
