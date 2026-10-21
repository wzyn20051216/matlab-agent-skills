# 闭环验收

本文件描述**怎样才算真的验证过**。核心原则只有一条：

> 配置文件存在、进程还在、文件被生成，都不是"能力已验证"的证据。
> 唯一可信的证据是：某条命令真的执行了、有退出码、有可比对的数值、有落盘的报告。

## 环境声明

本仓库是开源的，但要激活完整工作流能力，默认前提是具备已授权的 MATLAB 正版环境，以及任务所需的 Simulink、Coder、Embedded Coder、硬件支持包和相关第三方工具链。

缺少正版许可或相应工具箱时，脚本仍可运行，但只会输出 **SKIP（带原因）**，不会输出 PASS。`SKIP` 不会被折算成通过：只要报告里存在 SKIP，整体状态就是 `SKIP`，退出码为 `3`。

## 验收协议（单一定义源）

验收报告的结构定义在 [`schemas/acceptance-report.schema.json`](../schemas/acceptance-report.schema.json)，PowerShell 侧封装在 [`scripts/MatlabAgentSkills.Acceptance.psm1`](../scripts/MatlabAgentSkills.Acceptance.psm1)，MATLAB 侧封装在 `matlab/validation/+masacc/`。两边产出**同一个形状**的 JSON，因此 PowerShell 合并子报告时不需要任何特判。

报告的最小结构：

| 字段 | 说明 |
| --- | --- |
| `schemaVersion` | 验收协议版本（语义化版本号），当前 `1.0.0` |
| `taskId` | 本次任务标识，只含安全字符 |
| `backend` | `static` / `matlab-batch` / `matlab-mcp-auto` / `matlab-mcp-existing` / `matlab-mcp-new` |
| `matlabVersion` | MATLAB 版本串；未使用 MATLAB 时为 `null` |
| `toolboxInventory` | 工具箱清单（`name` / `version` / `licenseFeature` / `licensed` / `licenseSource`） |
| `startedAt` / `finishedAt` | 带时区的时间戳 |
| `environment` | 主机、OS、PowerShell 版本等 |
| `checks[]` | 检查项数组，见下表 |
| `summary` | 各状态的计数 |
| `overallStatus` | `PASS` / `FAIL` / `SKIP` |
| `achievedLevel` | `L0` ~ `L5` |

每个 `checks[]` 元素必须包含：

`id`、`title`、`level`、`status`、`command`、`exitCode`、`startedAt`、`finishedAt`、`durationSeconds`、`metrics`、`reason`、`errorClass`、`artifactPaths`、`retry`。

其中两条硬约束由代码强制，不是约定：

- `status` 不是 `PASS` 时，`reason` 不能为空。构造检查项时就抛错（`masacc:reasonRequired`），落盘后校验器还会再拦一次。
- `metrics` 必须是对象，用来放真正可复核的数字（`rmse`、`maxAbsDiff`、`sampleCount`、`toolCount` …），而不是一个布尔值。

## 五级验收

| 等级 | 含义 | 典型检查 |
| --- | --- | --- |
| L1 | 产物生成 | 文件/模型被创建且非空；代码生成产出 `.c`/`.h` |
| L2 | 编译构建成功 | MEX 构建成功；`slbuild` 产出库或可执行文件；模型 `update` 通过 |
| L3 | 数值结果一致 | 与 golden 结果比对，给出绝对/相对误差与容差 |
| L4 | 多工况与异常场景 | 参数扫描、NaN/Inf 传播、非法输入拒绝、非法尺寸拒绝 |
| L5 | 实际硬件运行验证 | 目标板下载、回读、时序对齐 |

`achievedLevel` 取**连续**达到的最高等级：L2 被跳过时，即使 L3 通过，`achievedLevel` 也只能是 `L1`。

### 明确不成立的推断

- 文件存在 ≠ 编译成功。`codegen.generate`（L1）与 `codegen.compile`（L2）是两个独立检查项。
- 通用 C 代码生成成功 ≠ STM32 硬件部署成功。Coder 产出的是与目标无关的 C；STM32 链路需要 CubeMX 注册、目标硬件可见、`.ioc` 绑定、Cube firmware package，这些单独检查。
- 工具箱出现在 `ver` 输出里 ≠ 该产品可用。`installed` / `licenseExists` / `executionProven` 三个事实分开探测，`available = installed && licenseExists && executionProven !== false`。

### 许可证检测：产品名 ≠ license feature 名

`license('test', x)` 的第二个参数是 **license feature 名**。用产品显示名去测会得到 `0`，
看起来像"没有许可证"，实际只是查错了键。实测（MATLAB R2026a）：

| 调用 | 返回值 | 说明 |
| --- | --- | --- |
| `license('test','MATLAB Coder')` | `0` | 产品名，不是 feature 名 |
| `license('test','MATLAB_Coder')` | `1` | 正确 |
| `license('test','Simulink Coder')` | `0` | 产品名 |
| `license('test','Real-Time_Workshop')` | `1` | 正确 |
| `license('test','Embedded Coder')` | `0` | 产品名 |
| `license('test','RTW_Embedded_Coder')` | `1` | 正确 |

映射与判定逻辑集中在这三处，不要在各脚本里手写 `license('test', <产品名>)`：

- [`matlab/validation/+masacc/featureName.m`](../matlab/validation/+masacc/featureName.m)：已实测的产品名 → feature 名映射表
- [`matlab/validation/+masacc/licenseState.m`](../matlab/validation/+masacc/licenseState.m)：三态授权判定（`true` / `false` / `[]` 无法判定）
- [`matlab/validation/+masacc/availability.m`](../matlab/validation/+masacc/availability.m)：叠加真实执行探针

两个必须知道的限制：

1. **`license('test')` 的 feature 字符串上限是 27 字符**，超长直接抛 `MATLAB:license:toomanychars`
   （例如 `Satellite_Communications_Toolbox`、`Sensor_Fusion_and_Tracking_Toolbox`）。
   这种情况记"无法判定"，不能记"未授权"。
2. **归一化猜测只能用来确认，不能用来否定**。把产品名的空格换成下划线，命中时可信
   （`AUTOSAR Blockset` → `AUTOSAR_Blockset` 为真）；返回 `0` 时不可信
   （`Simulink Coder` → `Simulink_Coder` 为 `0`，而真实 feature 为 `1`）。
   因此猜测返回 `0` 一律记 `[]`。

## 验收范围（capability scope）

整套验收横跨"基础数值"到"硬件在环"，不能用一个整体状态当 CI 门禁：
可选能力（Coder 未授权、没有 STM32 板卡）产生的 SKIP 会让 CI 永远红；
而为了让 CI 变绿去删掉那些 SKIP 又是在造假。

因此引入范围。范围**只决定门禁**，不修改 `overallStatus`，也不删除任何检查项：

| 范围 | 必选能力 |
| --- | --- |
| `core` | `matlab.executable`、`inventory.products`、`inventory.gated-license`、`skill.numeric-fit`、`skill.figure-export`、`skill.data-export` |
| `simulink` | core + `skill.simulink-sim`、`simulink.model-artifact`、`simulink.model-update`、`simulink.simulation`、`simulink.parameter-sweep` |
| `coder` | core + `codegen.generate`、`codegen.compile`、`compiler.mex-build`、`compiler.numeric`、`compiler.robustness` |
| `full` | 以上全部 + `simulink.codegen-build`、`feature.*`、`embedded.hardware-in-loop` |

判定规则（`Get-AcceptanceScopeStatus`）：必选 FAIL → `FAIL`；必选 SKIP 或未产出 → `SKIP`；
全部必选 PASS → `PASS`。可选检查的 SKIP 只记录在 `optionalSkipped`，不影响门禁。

`Test-MatlabSkills.ps1 -Scope <name>` 用它决定退出码（`0` / `1` / `3`），
报告里同时写入所选 `scope` 与全部四个范围的求值结果 `scopes`。

## 状态语义

| 状态 | 含义 | 是否算通过 |
| --- | --- | --- |
| `PASS` | 命令真的跑了，退出码符合预期，指标落在容差内 | 是 |
| `FAIL` | 命令跑了但结果不对，或该跑却跑不起来 | 否 |
| `SKIP` | 缺少前置条件（无许可证、无工具箱、无硬件），未执行 | **否**，必须带 `reason` |

`overallStatus` 的判定顺序：任一 `FAIL` → `FAIL`；否则任一 `SKIP` → `SKIP`；全部 `PASS` → `PASS`。

退出码：`PASS` → `0`，`FAIL` → `1`，`SKIP` → `3`（与"失败"区分开，便于 CI 判断是环境缺失还是代码有问题）。

## 错误分类与重试

分类定义在 [`scripts/MatlabAgentSkills.Execution.psm1`](../scripts/MatlabAgentSkills.Execution.psm1)：

| 类别 | 是否可自动重试 | 说明 |
| --- | --- | --- |
| `TIMEOUT` | 是 | 超时后已终止进程树 |
| `MCP_CONNECTION_ERROR` | 是 | 端口未监听、握手失败、鉴权失败 |
| `ENVIRONMENT_ERROR` | 否 | 缺编译器、缺可执行文件 |
| `LICENSE_ERROR` | 否 | 许可证不可用，重试没有意义 |
| `VALIDATION_ERROR` | 否 | 数值/内容不一致 |
| `SIMULATION_ERROR` | 否 | 仿真报错 |
| `CODEGEN_ERROR` | 否 | 构建报错 |
| `MATLAB_RUNTIME_ERROR` | 否 | 其他运行时错误 |

重试策略：

- 最大尝试次数被硬性限制在 `1..5`，不存在无限重试。
- 重试前先判断可恢复性；不可恢复的错误直接返回 `NON_RECOVERABLE:<class>`，不再试。
- 非幂等操作默认不重试，必须显式 `-Approved` 才允许重试（防止重复下载、重复写入、重复安装）。
- 每次尝试单独记录 `attempts[]`（时间、耗时、错误类别、原因），写进验收报告。

## 超时与日志

所有外部进程调用都经过 `Invoke-MatlabBatchProcess` / `Invoke-ProcessWithTimeout`：

- 使用 `ProcessStartInfo` + `WaitForExit(timeoutMs)`，**不用** `Start-Process -Wait`（PowerShell 5.1 在环境变量存在大小写重复键时会抛"字典中的关键字重复"）。
- 超时后调用 `taskkill /T /F` 终止**整个进程树**，避免残留 MATLAB 子进程。
- stdout/stderr 通过异步流写入磁盘，超时后依然能读到已产生的日志。
- 每个阶段写一份 `*.stages.log`，记录 `launch` / `running` / `timeout` / `exited` / `classified`。

一个真实观察到的例子（无超时保护时的后果）：`matlab.exe -batch` 在本机启动后长时间不返回、CPU 接近 0，进程一直存活。加超时后同一条命令在阈值内被终止，`error_class=TIMEOUT`，`stages.log` 里留有 `[timeout]` 记录，且没有残留 MATLAB 进程。

不设超时到底要等多久？实测一次直连调用：`matlab.exe -batch "disp(version)" -logfile ...` 跑满 **68 分 57 秒**后以 `MATLAB error Exit Status: 0x00000001` 结束，退出码 `1`，而 `-logfile` 是 **0 字节**。也就是说没有超时保护时，一个启动阶段就卡死的环境会让人白等一小时以上，且拿不到任何可诊断的输出。这就是"可配置超时 + 阶段日志"必须存在的理由，而不是可选项。

## MCP 会话探测

只检查配置文件或 `sessionDetails.json` 是否存在，无法证明 MCP 可用。`Test-MatlabMcpExistingSession.ps1` 把探测拆成 5 个独立判定的阶段：

| 阶段 | 检查项 id | 等级 | 判据 |
| --- | --- | --- | --- |
| 1 | `mcp.matlab-install` | L1 | 解析到 MATLAB 可执行文件，读到 `VersionInfo.xml` |
| 2 | `mcp.matlab-license` | L1 | 默认 SKIP；只有显式 `-VerifyLicense` 或阶段 4 真实执行成功才升级为 PASS |
| 2 | `mcp.session-config` | L1 | `sessionDetails.json` 可解析、证书文件存在、端口合法 |
| 2 | `mcp.client-registration` | L2 | 客户端注册参数中不含 `display-mode`，`command` 真实存在 |
| 3 | `mcp.protocol-handshake` | L2 | TCP 可连 + `initialize` 返回合法 `result` |
| 4 | `mcp.readonly-exec` | L3 | 通过 `tools/call` 真实执行只读命令，输出匹配版本号模式 |
| 5 | `mcp.file-io` | L4 | 在隔离测试目录写入令牌文件再读回，内容一致 |

任何一阶段失败，后续阶段输出 `SKIP` 并写明"上游未通过"，不会假装成功。

## 本机验收

```powershell
# 完整验收（含 Coder / Simulink），单个阶段超时 1800 秒；full 范围要求全部必选能力
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabSkills.ps1 -TimeoutSeconds 1800 -Scope full

# 基础门禁：只要求 MATLAB 自身能力，可选能力的 SKIP 仍保留在报告里
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabSkills.ps1 -Scope core

# 只跑工具箱与功能探测，跳过耗时的代码生成
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabSkills.ps1 -SkipCodegen -SkipSimulink

# MCP 共享会话探测（5 阶段）
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabMcpExistingSession.ps1 -Json
```

主报告输出到 `artifacts/validation/acceptance_report.json`；各阶段的子报告在 `artifacts/validation/acceptance/<stage>.json`；每个阶段的日志在 `artifacts/logs/`。

真实运行记录见 [`docs/P1_ACCEPTANCE_ZH.md`](P1_ACCEPTANCE_ZH.md) 第 3.7 节（含命令、退出码与修复前后的对比）。
那里也记录了修复 `license('test', 产品名)` 误判前后的差异：同一个环境、同一台机器，
Coder 相关检查从全 SKIP 变成真实 PASS/L2/L4。

## 各阶段检查什么

`Test-MatlabSkills.ps1` 依次执行 6 个阶段，每个阶段产出一份独立验收报告，再合并进主报告：

| 阶段 | MATLAB 脚本 | 主要检查项 |
| --- | --- | --- |
| `toolbox_inventory` | `matlab_toolbox_inventory.m` | 工具箱安装/授权状态 |
| `feature_probe` | `matlab_feature_probe.m` | 直接导入模型、硬件块集、agent skill 可用性 |
| `skill_smoke` | `matlab_skill_smoke.m` | 数值拟合 RMSE、解析首样本值、图像与数据导出、最小 Simulink 仿真峰值 |
| `compiler_chain_smoke` | `matlab_compiler_chain_smoke.m` | MEX 构建、5 组数值比对、NaN/非法尺寸/大数鲁棒性 |
| `codegen_smoke` | `matlab_codegen_smoke.m` | 代码生成（L1）与真实编译产物（L2）分开判定 |
| `simulink_coder_smoke` | `simulink_coder_smoke.m` | 模型产物与重载、`update`、仿真数值、增益扫描、`slbuild` |

## 测试分层

测试靠文件名区分层次，`tests/Invoke-Tests.ps1` 按层执行，并把"哪一层真的跑了"写进 `artifacts/validation/tests/layer_report.json`：

| 层 | 触发 | 内容 | 缺少依赖时的行为 |
| --- | --- | --- | --- |
| free | `-Layer free`（默认） | 安装器安全、验收协议、验收范围、依赖顺序、Pester 版本选择、错误分类、MCP 探测（假服务端） | 不适用 |
| matlab | `-Layer matlab` | 真实解析 MATLAB、读 `VersionInfo.xml`、真实 `-batch` 执行、真实超时终止、MATLAB 侧 JSON 边界往返 | 输出"未执行"并返回退出码 `2`，不算通过 |

`matlab` 层有两级前置探测，区分"装了"和"能跑"：

1. 解析不到可执行文件 → 本层未执行（`未发现已安装的 MATLAB`）；
2. 可执行文件存在，但 `matlab -batch "disp(version)"` 预检失败（典型是没有许可证）
   → 本层未执行，`reason` 里带退出码、耗时与 stderr 尾部。

两种情况都不记为失败：它们证明的是"这个运行面无法执行 MATLAB"，
而不是"被测能力坏了"。`layer_report.json` 里的 `matlabAvailable` / `matlabRunnable` /
`matlabRunFailure` 记录真实探测结果。

Pester 版本被**显式锁定**在 `3.4.0`（`-PesterVersion`，默认值在 `tests/Invoke-Tests.ps1`）。
套件使用的是 Pester 3 的 `Should Be` 语法，Pester 5 会直接抛
`Legacy Should syntax is not supported in Pester 5`。GitHub runner 上同时预装 3.4.0 与 5.9.0，
旧实现"取最高版本"因此选到 5.9.0，124 个用例全红——那是本仓库真实发生过的 CI 失败，
不是环境噪音。选择逻辑现在是可单测的纯函数（`tests/helpers/PesterSelection.ps1`）。

另外两个跨版本陷阱，都已在代码里绕开：

- **Pester 3.4 的 `Should Throw` 在 PowerShell 7 上失效**（用例报
  "Expected: the expression to throw an exception"）。需要断言抛错时用
  `tests/helpers/Assertions.ps1` 的 `Test-Throws`。
- **PowerShell 7 的 `ConvertFrom-Json` 会把 ISO 8601 字符串自动转成 `[datetime]`**，
  导致合法的 `startedAt` 被 schema 判成"类型应为 string，实际为 unknown"。
  `Get-JsonValueKind` 已把 `[datetime]` / `[datetimeoffset]` 归为 string。

层 A 的 `free-tests` 用矩阵在 **Windows PowerShell 5.1 与 PowerShell 7** 上各跑一次同一套用例，
`layer_report.json` 里的 `powerShellVersion` / `powerShellEdition` 记录实际运行面。
（这两个陷阱正是"只在一个运行面上测"造成的：本机 5.1 全绿、CI 的 pwsh 7 全红。）

层 A（GitHub Actions `Repository Checks`）只跑 free 层，是基础门禁，
且在 **Windows PowerShell 5.1 与 PowerShell 7** 两个运行面上各跑一次。
层 B（`MATLAB Validation`）在带许可证的环境跑 matlab 层与完整验收，门禁按 `core` 范围判定；
它需要仓库里配置 `MATLAB_VALIDATION_ENABLED=true`（Variables）与 `MLM_LICENSE_FILE`（Secret），
**未配置时该 job 显示为 skipped（未执行），不是 passed**：
公共 runner 上 `matlab-actions/setup-matlab` 能装好 MATLAB，但没有许可证时 `-batch`
会在 1~2 秒内退出码 1，跑出来的红灯与被测代码无关。
`coder` 范围放在 `workflow_dispatch` 且显式申请 Coder 产品的可选 job 里，push / PR 上不参与。
层 C 需要 Pro 许可证或硬件，不在任何默认 workflow 中执行，其检查项在报告里以 SKIP 出现，
`full` 范围因此永远不是 PASS——这是刻意的。

## 论文复现验收

论文复现任务至少需要：

- `manifest.json` 记录论文、代码、数据、MATLAB 版本和工具箱。
- 先复现一个最小图或表。
- 给出与论文结果的数值差异或可解释偏差。
- 保存原始日志、处理脚本、结果数据、图像。

## 报告与偏差声明

提交 PR 或发布时，必须区分三类内容，不允许混为一谈：

1. **已执行且通过**：附命令、退出码、验收报告路径。
2. **已执行但失败 / 跳过**：附失败原因与 `reason` 字段。
3. **未执行**：明确写"未执行"，并说明缺少什么前置条件。

"测试没报错"不等于"能力已验证"；"检查项 SKIP"不等于"环境支持该能力"。
