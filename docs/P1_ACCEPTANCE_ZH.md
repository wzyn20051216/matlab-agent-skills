# 第二阶段 P1：执行引擎与工程验收体系重构

本次重构解决的问题不是"脚本能不能跑通"，而是"脚本报的 PASS 到底能不能信"。

## 一、缺陷清单（按文件）

### 1. 执行探测：把"配置存在"当成"连接成功"

| 文件 | 缺陷 | 后果 |
| --- | --- | --- |
| `scripts/Test-MatlabMcpExistingSession.ps1` | 读 `sessionDetails.json` 拿到 `port`/`pid` 就判定 `ready`，从未发起 TCP 连接，也没有 `initialize` 握手 | 会话文件残留时（证书路径早已失效）依然输出 ready |
| 同上 | `autoModeReady` 由配置文件里的字符串推断，不验证客户端注册参数是否合法 | `display-mode` 这类会被服务端直接拒绝的参数也算"就绪" |
| 同上 | 没有"MATLAB 真的能执行一条命令"的检查 | 握手成功与执行成功被混为一谈 |
| `skills/matlab-runner/SKILL.md` | 只给出"优先用 MCP auto"的规则，没有定义如何确认 MCP 真的可用 | agent 会照着配置状态汇报成功 |
| `skills/matlab-orchestrator/SKILL.md` | 同上，且没有说明 SKIP 与 PASS 的区别 | 路由决策建立在不可靠的就绪信号上 |

### 2. 验收结构：报告碎片化，无法合并与复核

| 文件 | 缺陷 | 后果 |
| --- | --- | --- |
| 全部 `matlab/validation/*.m` | 每个脚本各自定义 `summary.json` 形状，字段名不一致 | 无法统一校验，无法跨阶段合并 |
| 同上 | 多数检查只记录 `passed = true/false`，不记录命令、退出码、耗时、指标 | 事后无法复核"为什么算通过" |
| 同上 | `status` 只有通过/不通过两态，缺少 `SKIP` | 缺工具箱时只能伪造成失败或伪造成通过 |
| `scripts/Test-MatlabSkills.ps1` | 把各阶段结果拼成一段文本，不产出机器可读的统一报告 | CI 无法据此判定，只能靠人看日志 |

### 3. 验证脚本真实性：L1 冒充 L2，golden 结果未使用

| 文件 | 缺陷 | 后果 |
| --- | --- | --- |
| `matlab/validation/matlab_codegen_smoke.m` | 只判断 `.c`/`.h` 文件存在即通过，`GenCodeOnly` 与真实编译混在一起 | "生成源码"被当成"编译成功" |
| `matlab/validation/matlab_codegen_smoke.m` | 缺少编译器可用性探测 | 编译器缺失时仍然输出通过 |
| `matlab/validation/matlab_compiler_chain_smoke.m` | 计算了 golden 结果但只用来判断"是否非空"，没有做数值比对 | 编译产物算错也算通过 |
| `matlab/validation/matlab_compiler_chain_smoke.m` | 没有容差概念，没有异常输入场景 | 无法发现边界行为差异 |
| `matlab/validation/simulink_coder_smoke.m` | 只检查模型 `.c` 文件是否存在，未验证模型能否重新加载、能否 `update`、仿真能否跑完 | 模型损坏也可能通过 |
| `matlab/validation/simulink_coder_smoke.m` | 未对仿真输出做数值断言 | 仿真结果错误无人发现 |
| `matlab/validation/matlab_skill_smoke.m` | 图像/数据导出只判断文件非空 | 0 字节与坏图无法区分 |
| `matlab/validation/matlab_feature_probe.m` | 直接导入、硬件块集、agent skill 一律写成固定状态 | 缺失即通过 |
| 全部 | 机器专属绝对路径（如外部技能目录、Keil 路径）写死在脚本里 | 换机器即失效或误判 |
| `scripts/Test-MatlabEmbeddedStack.ps1` | 硬编码 `matlabValidation.passed = $true` | 无论子检查结果如何都报通过 |
| `scripts/Test-MatlabEmbeddedStack.ps1` | 硬件与外部工具链缺失时没有 SKIP 语义 | 无法区分"没硬件"与"硬件验证失败" |

### 4. 执行可靠性：没有超时，没有错误分类，没有重试边界

| 文件 | 缺陷 | 后果 |
| --- | --- | --- |
| `scripts/Invoke-MatlabBatch.ps1` | `Start-Process -Wait` 无超时 | MATLAB 挂起时整个流程无限等待 |
| 同上 | 超时后不终止进程树 | 残留 MATLAB 子进程持续占用许可证 |
| 同上 | 使用 `Start-Process` | Windows PowerShell 5.1 在环境变量存在大小写重复键（`HTTPS_PROXY` / `https_proxy`）时抛"字典中的关键字重复" |
| 同上 | 失败原因只有一段文本，不分类 | 无法判断该重试还是该报环境问题 |
| 全部脚本 | 没有重试策略，或只有"再跑一次" | 要么一次失败就放弃，要么可能无限重试 |
| `MatlabAgentSkills.Execution.psm1`（重构中自测发现） | `StageLogPath` 是可选参数，不传就静默不写阶段日志 | 真实 MATLAB 挂起时只剩两个 0 字节 stdout/stderr，无法定位卡在哪一步 |
| `tests/Invoke-Tests.ps1`（重构中自测发现） | Windows PowerShell 5.1 对 `List[object]` 使用 `@($list)` 抛"参数类型不匹配"（`List[string]` / `List[hashtable]` 反而正常） | 层报告写盘失败；统一改用 `.ToArray()` |

### 5. 测试与 CI：没跑过的能力也显示为通过

| 文件 | 缺陷 | 后果 |
| --- | --- | --- |
| `.github/workflows/repository-checks.yml` | 单一 job 跑全部 Pester | 无 MATLAB 环境时无法区分"没跑"与"通过" |
| `.github/workflows/matlab-validation.yml` | `run-command` 跑两个脚本，不检查退出码、不读验收报告 | 脚本内部全部 SKIP 也会显示绿色 |
| `tests/Invoke-Tests.ps1` | 不区分测试层次 | 需要 MATLAB 的测试在免费环境会被误算 |

## 二、重构设计

### 2.1 统一验收协议

`schemas/acceptance-report.schema.json` 是唯一定义源。PowerShell 侧（`MatlabAgentSkills.Acceptance.psm1`）与 MATLAB 侧（`matlab/validation/+masacc/`）产出同一形状的报告，合并时无需特判。

三条由代码强制的约束：

1. `status != PASS` 时 `reason` 不能为空 —— 构造检查项即抛错（`masacc:reasonRequired`），落盘后校验器再拦一次。
2. `metrics` 必须是对象，用来放可复核的数字，不接受布尔占位。
3. 存在任一 `SKIP` → `overallStatus = SKIP`，退出码 `3`。`SKIP` 不折算为通过。

`achievedLevel` 取连续达到的最高等级：L2 跳过时，L3 通过也只能记 L1。
同理，L1 里只要有一条 SKIP，等级就停在 L0 —— 本机真实报告就是这个结果（见 3.4.4）。

`toolboxInventory` 只有真正跑过 MATLAB 的那一层才拿得到，所以合并时如果父报告是空数组，
会继承子报告的清单；否则"报告里有这个字段"只是一句空话（空数组同样满足 schema）。

### 2.2 五级验收

| 等级 | 含义 |
| --- | --- |
| L1 | 产物生成 |
| L2 | 编译构建成功 |
| L3 | 数值结果一致 |
| L4 | 多工况与异常场景 |
| L5 | 实际硬件运行验证 |

关键的拆分解法：

- `codegen.generate`（L1，`GenCodeOnly = true`）与 `codegen.compile`（L2，产出库/可执行文件）是两个检查项。
- 通用 C 代码生成不等于 STM32 部署；STM32 链路单独检查 CubeMX 注册、目标硬件可见、`.ioc` 绑定、firmware package。
- 工具箱出现在 `ver` 里不等于可用：`installed` 与 `licensed` 分开记录，`available = installed && licensed`。

### 2.3 MCP 五阶段探测

`Invoke-McpStagedProbe` 把"就绪"拆成独立判定的阶段：安装 → 许可证 → 会话配置 → 客户端注册 → 协议握手 → 只读执行 → 文件回读。

- 任一阶段失败，后续阶段输出 `SKIP` 并写明"上游未通过"。
- 默认 `mcp.matlab-license` 为 `SKIP`；只有显式 `-VerifyLicense`，或阶段 4 通过共享会话真实执行 `disp(version)` 成功，才升级为 `PASS`，且 `metrics.provenBy` 记录证据来源。
- HTTP 4xx/5xx 时 `reason` 同时保留状态码与 JSON-RPC 错误体。只记录 `unauthorized` 会让人无法区分"服务没起"和"密钥错"。

### 2.4 错误分类与有限重试

8 个类别：`ENVIRONMENT_ERROR`、`LICENSE_ERROR`、`MCP_CONNECTION_ERROR`、`MATLAB_RUNTIME_ERROR`、`SIMULATION_ERROR`、`CODEGEN_ERROR`、`VALIDATION_ERROR`、`TIMEOUT`。

只有 `TIMEOUT` 与 `MCP_CONNECTION_ERROR` 可自动重试。`MaxAttempts` 被钳制在 `1..5`。非幂等操作默认不重试，必须显式 `-Approved`。不可恢复的类别直接返回 `NON_RECOVERABLE:<class>`。

### 2.5 超时与进程树

- 用 `ProcessStartInfo` + `WaitForExit(timeoutMs)`，不用 `Start-Process -Wait`。
- 超时后 `taskkill /T /F` 终止整个进程树。
- stdout/stderr 走异步流写盘，超时后仍能读到已产生的日志。
- 每个阶段写 `*.stages.log`：`launch` / `running` / `timeout` / `exited` / `classified`。

### 2.6 测试分层

`tests/Invoke-Tests.ps1 -Layer free|matlab|all`。文件名以 `.Matlab.Tests.ps1` 结尾的归入 matlab 层。

- 缺 MATLAB 时 matlab 层输出"未执行"并返回退出码 `2`，不算通过。
- 执行结果落盘 `artifacts/validation/tests/layer_report.json`，记录每层是否真的执行、用例数、耗时、未执行原因。

## 三、测试证据

### 3.1 free 层（本机实测，无 MATLAB 依赖）

命令：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Layer free
```

结果：`共 122 个用例，通过 122，失败 0`，退出码 `0`。

| 测试文件 | 用例数 | 覆盖内容 |
| --- | --- | --- |
| `Installer.Scenarios.Tests.ps1` | 22 | 第一阶段安装器安全行为（回归保护） |
| `MatlabAgentSkills.Core.Tests.ps1` | 39 | 参数裁剪、JSON 合并、备份回滚、下载校验 |
| `Acceptance.Protocol.Tests.ps1` | 21 | schema 校验、语义约束、等级判定、合并、退出码 |
| `Execution.Reliability.Tests.ps1` | 27 | 8 类错误分类、重试边界、超时、进程终止、阶段日志默认落盘、安装解析 |
| `McpProbe.Tests.ps1` | 13 | 五阶段在正常/不可达/无工具/IO 不一致/500/401/挂起/非法注册下的判定 |

### 3.2 故障注入

`tests/helpers/FakeMcpServer.ps1` 是一个最小 HTTP/1.1 MCP 服务端，支持 6 种模式，用于在无 MATLAB 环境下制造真实故障：

| 模式 | 注入的故障 | 期望判定 |
| --- | --- | --- |
| `pass` | 无 | 五个阶段全 PASS，整体 PASS |
| `bad-handshake` | 握手返回 HTTP 500 | 握手 FAIL，后续 SKIP，整体 FAIL |
| `auth-fail` | 握手返回 HTTP 401 | 握手 FAIL，`reason` 含 `401` |
| `no-tool` | `tools/list` 不返回执行工具 | 只读阶段 SKIP，`metrics` 记录工具清单 |
| `wrong-io` | 回读内容与写入不一致 | 文件回读 FAIL / `VALIDATION_ERROR` |
| `slow` | 握手不响应 | 握手在超时后 FAIL，不无限等待 |

另外覆盖：端口不可达、只有配置无会话、会话 JSON 损坏、证书缺失。

### 3.3 未执行项的语义验证

| 场景 | 命令 | 结果 |
| --- | --- | --- |
| 指定不存在的 MATLAB 路径 | `Invoke-Tests.ps1 -Layer matlab -MatlabPath <不存在路径>` | 层标记"未执行"，退出码 `2`，用例数 0 |
| 无有效 MCP 会话 | `Test-MatlabMcpExistingSession.ps1` | `overall=SKIP achievedLevel=L0 pass=1 fail=0 skip=6`，退出码 `3` |

第二条是本机真实环境的实测结果。这台机器上的 `sessionDetails.json` 是上一次会话留下的：

```text
mcp.matlab-install       L1 PASS
mcp.matlab-license       L1 SKIP  许可证只能通过启动 MATLAB 验证；未指定 -VerifyLicense
mcp.session-config       L1 SKIP  会话证书不可读（...\cert.pem）：通常意味着会话已失效
mcp.client-registration  L2 SKIP  未发现包含 'matlab-official' 的有效注册
mcp.protocol-handshake   L2 SKIP  阶段 2 未给出可用会话（SKIP）
mcp.readonly-exec        L3 SKIP  阶段 3 未通过，无法执行只读命令
mcp.file-io              L4 SKIP  上游阶段未通过（handshake=SKIP, readonly=SKIP）
==> overall=SKIP achievedLevel=L0 pass=1 fail=0 skip=6
```

旧版脚本对同一份文件的判定是 `ready = true`。这就是本次重构要消除的那类假信号。

这份真实报告同时通过了 schema 与语义校验（`Valid=True`），说明协议在真实数据上成立，而不只是在单元测试的构造对象上成立。

### 3.4 真实 MATLAB 层（本机实测）

#### 3.4.1 第一次尝试：受控超时下的失败

命令与结果：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Layer matlab
# Passed: 3  Failed: 1  Total: 4   退出码 1
```

| 用例 | 结果 |
| --- | --- |
| 能解析出真实 MATLAB 可执行文件路径 | PASS（805 ms） |
| 能从真实安装目录读出 Release 与完整版本号 | PASS（143 ms，读到 R2026a） |
| 真实 `-batch` 执行 `disp(version)` | **FAIL（181 s）** |
| 超时保护会在阈值内终止真实 MATLAB 进程 | PASS（46 s） |

失败原因不是断言写错，而是这台机器上 MATLAB 无法以 `-batch` 启动。阶段日志记录了完整过程：

```text
2026-10-17T16:08:11.828 [launch] matlab.exe -batch disp(version)
2026-10-17T16:08:11.879 [running] pid=45948 timeout=180s
2026-10-17T16:11:11.895 [timeout] 超过 180s，终止进程树
2026-10-17T16:11:12.690 [classified] TIMEOUT
```

配套的 `pause(600)` 用例证明超时机制本身是有效的：

```text
2026-10-17T16:11:12.970 [launch] matlab.exe -batch pause(600)
2026-10-17T16:11:12.992 [running] pid=39692 timeout=45s
2026-10-17T16:11:58.006 [timeout] 超过 45s，终止进程树
2026-10-17T16:11:58.789 [classified] TIMEOUT
```

要点：

- 超时后进程树被完整终止，运行前后对比无新增残留 `matlab.exe` / `MATLAB.exe`。
- 两次超时中 `stdout` 与 `stderr` 都是 **0 字节**，说明卡在启动阶段，而不是被测脚本报错。

#### 3.4.2 追查：不设超时到底要等多久

为了排除"只是 180 秒不够久"，随后在测试框架之外单独跑了一次不设超时的直连调用：

```text
E:/matlab/bin/matlab.exe -batch "fprintf('STARTUP_OK=%d\n',1); disp(version)" -logfile D:/Temp/ml-startup.log
实际耗时 68 分 57 秒 → 输出 "MATLAB error Exit Status: 0x00000001" → 退出码 1
```

配套证据：

| 观察项 | 结果 |
| --- | --- |
| `-logfile` 产物大小 | **0 字节**（MATLAB 内核未进入解释器阶段） |
| `%TEMP%\.mathworks\` 会话临时文件 | 只有 0 字节的实例文件与 `.lock`，无许可日志内容 |
| 崩溃转储 | 无 |
| 运行后残留进程 | 无（`MATLAB.exe` 计数 0） |
| MathWorks 许可服务器连通性 | `https://login.mathworks.com` 直连与经代理均返回 HTTP 302，约 1.0 s |
| 许可模式 | `<matlabroot>` 下 `licenses\license_info.xml` 中 `licmode = onlinelicensing` |

#### 3.4.3 结论修正：机器是可用的，前面那次是瞬时故障

继续排查时，同样的调用在同一个 shell（代理变量仍在）下 16 秒正常返回：

```text
matlab.exe -batch "disp(version)"  →  26.1.0.3276743 (R2026a) Update 3，exit 0，16 s
```

因此先前"这台机器不能跑 `-batch`"的判断是错的，必须撤回。准确的说法是：
**本机 `-batch` 启动曾在许可检查阶段长时间重试后以 `0x00000001` 退出（一次性、随后自愈），
之后再未复现；代理变量不是根因（带代理同样 16 秒成功）。**

这正是本阶段要建立的纪律：一次失败只能证明"这一次失败"，不能直接上升为"能力不可用"；
反过来，一次成功也不能用来覆盖先前 FAIL 的证据，两者都要留在报告里。

同一层测试在恢复后重跑，5 个用例全部通过、退出码 0：

| 用例 | 结果 |
| --- | --- |
| 能解析出真实 MATLAB 可执行文件路径 | PASS |
| 能从真实安装目录读出 Release 与完整版本号 | PASS（R2026a） |
| 真实 `-batch` 执行 `disp(version)` | PASS（18.8 s，exit 0） |
| 超时保护会在阈值内终止真实 MATLAB 进程 | PASS（45.7 s 后终止） |
| 脚本名不是合法标识符时用同目录别名跑通 | PASS（19.7 s，别名文件已清理） |

#### 3.4.4 真实跑通六个验收脚本（本阶段的主证据）

MATLAB 可用之后，`Test-MatlabSkills.ps1` 的六个阶段全部真实执行，结果如下
（`artifacts/validation/acceptance_report.json`）：

| 检查项 | 等级 | 结果 | 说明 |
| --- | --- | --- | --- |
| `matlab.executable` | L1 | PASS | 解析到 `matlab.exe` 并读到 R2026a |
| `inventory.products` | L1 | PASS | `ver` + `license('test')` 真实枚举 117 个产品，并继承进主报告的 `toolboxInventory` |
| `feature.direct-import` | L1 | SKIP | 已装 Coder 与深度学习工具箱，但未检测到 `loadPyTorchExportedProgram` |
| `feature.blocksets` | L1 | PASS | 相关块集可用 |
| `feature.agentic` | L1 | PASS | 智能体调用面可用 |
| `skill.numeric-fit` | L3 | PASS | RMSE 0.0345 < 0.08，且首点解析误差 ≤ 1e-12 |
| `skill.figure-export` | L1 | PASS | 图窗真实导出非空文件 |
| `skill.data-export` | L1 | PASS | 数据文件真实落盘并可回读 |
| `skill.simulink-sim` | L3 | PASS | 501 采样点，peak 1.99999936 / trough −1.99999429（期望 ±2，容差 0.01） |
| `compiler.mex-build` / `compiler.numeric` / `compiler.robustness` | L2 / L3 / L4 | SKIP（当时） | 当时判为"MATLAB Coder 未授权" —— 该结论在 3.5 节被证伪，现已 PASS |
| `codegen.generate` / `codegen.compile` | L1 / L2 | SKIP（当时） | 同上，代码生成未授权 —— 已在 3.5 节纠正，现已 PASS |
| `simulink.model-artifact` | L1 | PASS | 建模型 → 保存 → 卸载 → 重载 |
| `simulink.model-update` | L2 | PASS | `SimulationCommand=update` 成功 |
| `simulink.simulation` | L3 | PASS | Step×3 → 稳态 3.0（容差 1e-9） |
| `simulink.parameter-sweep` | L4 | PASS | 增益 2 / 3 / 5 三工况均符合解析预期 |
| `simulink.codegen-build` | L4 | SKIP（当时） | 当时判为"Simulink Coder 未授权" —— 已在 3.5 节纠正，现已 PASS |

当时整体判定遵守"SKIP 不得折算为 PASS"：因为存在多条 SKIP，`overallStatus=SKIP`（退出码 3）、`achievedLevel=L0`。

> **后续更正（第二阶段 2.2）**：上面 4 条 SKIP 全部是**误判**。`license('test')` 第二个参数要的是
> license feature 名（`MATLAB_Coder` / `Real-Time_Workshop` / `RTW_Embedded_Coder`），
> 而不是产品显示名。用产品名去测必然返回 0。纠正后同机同环境实测为
> **19 PASS / 1 SKIP / 0 FAIL**，Coder 相关的 MEX 构建、真实编译、数值一致性、`slbuild`
> 全部真实通过。详见 3.5 节；最新数据见 3.6 节。

`achievedLevel` 之所以是 L0 而不是 L3：等级是按层**连续**达成的，L1 里只要有一条没通过
就没有"达成 L1"，后面更高的层再通过也只能记在报告里而不能抬高等级。
这不是苛刻，而是避免"有一堆 PASS 就宣称到达某一级"这种自我安慰。
真要抬高它，唯一的办法是把那条 SKIP 变成有证据的 PASS 或解释清楚为什么它不该在这一层。
（纠正许可证误判后，19 PASS / 1 SKIP 的 `achievedLevel` 仍然是 L0 —— 因为剩下的
`feature.direct-import` 也是 L1。等级规则没有被"改绿"的动机动摇过。）

#### 3.4.5 真实执行抓到了 4 个脚本自身的缺陷

这是"必须真的跑"最直接的收益。这些缺陷只有真机执行才会暴露：

| 缺陷 | 现象 | 修复 |
| --- | --- | --- |
| `+masacc/new.m` 用 `computer("os")` 取 OS | `MATLAB:badopt 未知的命令选项`，六个脚本全部在各自第 26 行挂掉 | 改为 `string(computer)`（实测返回 `PCWIN64`）；另实测确认 `version("-release")` 合法 |
| `+masacc/write.m` 直接用 `jsonencode(report)` | 单条检查时 `checks` 被编码成**对象**，PowerShell 侧 schema 校验报 `$.checks 类型应为 array，实际为 object` | 转 `num2cell` 强制数组（实测：`jsonencode(结构体)`→对象，`jsonencode(num2cell(...))`→数组） |
| `simulink_coder_smoke.m` 用 `"StepTime"` 设置阶跃时刻 | `Step block 没有名为 'StepTime' 的参数` | 实测 `DialogParameters` 为 `Time, InitialValue, FinalValue, ...`，改用 `"Time"` |
| `matlab_skill_smoke.m` 的 Sine 仿真只跑到 1 秒、2 秒 | 峰值 1.6829 = 2·sin(1)；改到 2 秒后谷值仍是 0.0000。两次都判 FAIL | 仿真时长改为 5 秒（覆盖 3π/2 谷值）并设 `MaxStep=0.01`，采样点 51 → 501 |

Sine 那一条尤其说明问题：**是验收断言抓出了验收脚本自己的错**，而不是脚本"写错了却照样 PASS"。

#### 3.4.6 一个被否掉的"修复"（顺手记下 .NET 陷阱）

排查中曾怀疑是代理变量导致许可检出失败，于是给执行模块加了 `-ClearProxyEnvironment`。
用变体实验（同一台机器、同样参数、只改一个条件）测出：

| 变体 | 结果 |
| --- | --- |
| 不碰 `ProcessStartInfo.EnvironmentVariables` | exit 0，16 s，拿到版本号 |
| 只读取 `$psi.EnvironmentVariables`（`Count` = 0） | exit 3，1.6 s，MATLAB abort（0x00000003），MWSH 崩溃转储 |
| 再回到不碰该属性 | exit 0，15.9 s |

即：在 Windows PowerShell 5.1 / .NET Framework 下读取该属性得到的是**空集合**；一旦读取，
`Start()` 交给子进程的就是一个空环境，MATLAB 因缺少 `SystemRoot` / `TEMP` / `PATH` 直接 abort。
另外 `[Environment]::SetEnvironmentVariable(name, "")` 在该实现下等价于删除，会回落到用户级变量，
因此"清空父进程变量"也达不到屏蔽效果；`NODE_OPTIONS` 这类变量连赋值都会抛"无法对 Null 数组进行索引"。

结论：**不引入这个开关**。既然证据表明代理不是根因（带代理同样 16 秒成功），
为一个未被证实的猜测去改子进程环境，只会换来一个更难查的启动失败。
代码里保留这条警告注释，防止后来者重复踩坑。

## 三·续、第二阶段 2.2 的修复

### 3.5 许可证检测纠正：产品名 ≠ license feature 名

**这是上一轮 7 个 SKIP 的根因，也是本轮最重要的修复。**

`license('test', x)` 的第二个参数是 **license feature 名**，不是产品显示名。两者经常不同，
用产品名去测会返回 0，看起来像"没有许可证"，实际只是查错了键。同一台机器、同一个
MATLAB R2026a 实测：

| 产品 | `license('test', 产品名)` | 真实 feature | `license('test', feature)` |
| --- | --- | --- | --- |
| MATLAB Coder | `0` | `MATLAB_Coder` | **`1`** |
| Simulink Coder | `0` | `Real-Time_Workshop` | **`1`** |
| Embedded Coder | `0` | `RTW_Embedded_Coder` | **`1`** |
| Simulink | `1` | `Simulink` | `1` |
| Stateflow | `1` | `Stateflow` | `1` |
| Fixed-Point Designer | `0` | `Fixed_Point_Toolbox` | **`1`** |
| Deep Learning Toolbox | `0` | `Neural_Network_Toolbox` | **`1`** |
| Signal Processing Toolbox | `0` | `Signal_Toolbox` | **`1`** |
| DSP System Toolbox | `0` | `Signal_Blocks` | **`1`** |
| Statistics and Machine Learning Toolbox | **抛错** | `Statistics_Toolbox` | `1` |
| HDL Coder | `0` | `HDL_Coder` | `0`（确实未授权） |

顺带发现两个此前完全没被注意到的坑：

1. **`license('test')` 的 feature 字符串上限是 27 字符。** 长度 ≥ 28 时直接抛
   `MATLAB:license:toomanychars`，例如 `C2000_Microcontroller_Blockset`（30）、
   `Satellite_Communications_Toolbox`（32）、`Sensor_Fusion_and_Tracking_Toolbox`（36）。
   旧代码用 `catch` 把异常吞成 `[]`，于是这些产品在清单里既不是 `true` 也不是 `false`，
   而报告里根本看不到原因。现在明确记为"无法判定"并写明是 27 字符上限。
2. **归一化猜测只能确认、不能否定。** 把产品名的空格换成下划线，命中时可信
   （`AUTOSAR Blockset` → `AUTOSAR_Blockset` 为 `1`）；返回 `0` 时不可信
   （`Simulink Coder` → `Simulink_Coder` 为 `0`，真实 feature 却是 `Real-Time_Workshop` = `1`）。
   所以猜测值为 `0` 一律记"未知"，绝不记"未授权"。

修复后新增三个模块，任何脚本都不应再手写 `license('test', <产品名>)`：

| 文件 | 职责 |
| --- | --- |
| `+masacc/featureName.m` | 产品名 → feature 名映射表（101 条，逐条在本机实测） |
| `+masacc/licenseState.m` | 三态授权判定：`true` / `false` / `[]`（无法判定），并记录 `featureSource`（`table` / `normalized-guess` / `override`） |
| `+masacc/executionProbe.m` | 真实执行探针（`coder.typeof` + `coder.config`、`new_system`），用于区分"有许可证"与"能执行" |

`+masacc/availability.m` 现在返回互不覆盖的几个事实：`installed`、`licenseFeature`、
`licenseExists`、`executionProven`、`available`、`provenBy`、`reason`。
`inventory.m` / `matlab_toolbox_inventory.m` 同步改为三态，并在主报告里新增一条检查
`inventory.gated-license`：**核心产品（MATLAB / Simulink / 三个 Coder）的授权结论必须是确定的布尔值，
不允许停留在"无法判定"。**

本机 117 个产品的清点结果：**95 已授权 / 5 未授权 / 17 无法判定**。修复前这个数字是
4 已授权 / 113 未授权（且其中 17 个连原因都没有）——错的不是环境，是检测方式。

### 3.6 六阶段复跑（本轮主证据）

```powershell
./scripts/Test-MatlabSkills.ps1 -TimeoutSeconds 1800 -Scope full
# 退出码 3（full 范围要求硬件在环，本机没有）
```

MATLAB R2026a，20 项检查：**19 PASS / 1 SKIP / 0 FAIL**。

| 检查项 | 等级 | 结果 | 耗时 |
| --- | --- | --- | --- |
| `matlab.executable` | L1 | PASS | 0s |
| `inventory.products` | L1 | PASS | 0.4s |
| `inventory.gated-license` | L1 | PASS | 0s |
| `feature.direct-import` | L1 | **SKIP** | 0s |
| `feature.blocksets` | L1 | PASS | 0s |
| `feature.agentic` | L1 | PASS | 0s |
| `skill.numeric-fit` | L3 | PASS | 0s |
| `skill.figure-export` | L1 | PASS | 0s |
| `skill.data-export` | L1 | PASS | 0s |
| `skill.simulink-sim` | L3 | PASS | 6.4s |
| `compiler.mex-build` | L2 | PASS | 13.2s |
| `compiler.numeric` | L3 | PASS | 0.1s |
| `compiler.robustness` | L4 | PASS | 0.2s |
| `codegen.generate` | L1 | PASS | 16.3s |
| `codegen.compile` | L2 | PASS | 7.0s |
| `simulink.model-artifact` | L1 | PASS | 5.5s |
| `simulink.model-update` | L2 | PASS | 2.5s |
| `simulink.simulation` | L3 | PASS | 0.4s |
| `simulink.parameter-sweep` | L4 | PASS | 0.4s |
| `simulink.codegen-build` | L4 | PASS | 11.6s |

唯一剩下的 SKIP 是 `feature.direct-import`：产品已安装且可用，但没检测到
`loadPyTorchExportedProgram` / `loadLiteRTModel` 这两个 API。这是"目标 API 不存在"，
不是"缺许可证"，`reason` 里写清楚了。

**四类失败路径在这一轮都被真实触发过**，不是纸上推演：

| 触发方式 | 观察到的结果 |
| --- | --- |
| `masacc.availability("MATLAB Coder", LicenseFeature="__no_such_feature__")` | `licenseExists=false` → SKIP，reason 说明未授权 |
| `LicenseFeature` 传 40 字符 | `licenseExists=[]` → SKIP，reason 说明超 27 字符上限无法判定 |
| 主动 `error("masacc:testFault", ...)` | FAIL，`errorClass=MATLAB_RUNTIME_ERROR`，保留原始 message |
| 空报告直接 `masacc.write` | 抛 `masacc:emptyReport`，拒绝写出零检查项报告 |

### 3.7 一个被许可证误判掩盖的真 bug：`codegen -d <变量名>`

许可证误判不只是"少跑了几条检查"，它把后面的脚本缺陷全遮住了。修好授权后，
`codegen_smoke` 第一次真正执行就 FAIL，原因不是编译失败，而是**产物找不到**：

```matlab
codegen -config cfg pi_control_step -args args -d genDir   % 错
```

`codegen` 的命令行解析器把 `-d` 后面的**变量名当成字面量**，于是在当前目录
（`matlab/validation/`）建了一个名为 `genDir` 的文件夹，产物全落在那里；
而校验去 `artifacts/validation/codegen_smoke/codegen_only` 找，自然找不到。
表现为"codegen 报告成功，但断言说没有产物"。

修复方式：切到目标目录再执行，产物位置没有歧义；并且把查找改回递归
（真实产物在 `genDir/codegen/lib/pi_control_step/` 下）。

```matlab
cd(genDir);
codegen -config cfg pi_control_step -args args
```

`matlab_compiler_chain_smoke.m` 的 `-d mexDir` 有同样问题，一并修复。
这两个脚本此前从未真正跑到这一步，所以缺陷一直存在却不可见。

### 3.8 写报告不是原子操作

跑六阶段时最后一步失败，报 `safe-delete ... trash-failed`。追下去发现
`Write-AcceptanceReport` 用的是 `Remove-Item` + `Move-Item`：

- 两步之间存在真空期，目标文件一度不存在；
- 删除这一步一旦失败（被安全删除钩子拦截、文件被占用），就留下
  "目标已消失、临时文件还在"的破损状态。

改为 `[System.IO.File]::Replace`（目标存在时）/ `File.Move`（目标不存在时），
单步完成替换，失败则原文件不动；文件系统不支持 `Replace` 时退化为覆盖写，
仍然不经过删除步骤。新增回归用例：连续写两次同一路径，读回的是新内容且不残留 `*.tmp-*`。

### 3.9 CI 三轮全红：根因是"取最高版本"的 Pester

这一点必须单独写，因为它最容易被误读成"代码坏了"。

| 事实 | 证据 |
| --- | --- |
| 3 次 push / PR 触发的 6 个 CI run **全部 failure** | `gh run list`：39022905018 / 39022905014 / 39022900598 / 39022900576 / 39016668585 / 39016668448 … |
| 失败信息是 `Legacy Should syntax (without dashes) is not supported in Pester 5` | 层 A 日志 |
| runner 上同时有 Pester **3.4.0** 与 **5.9.0**，旧实现 `Sort-Object Version -Descending \| Select -First 1` 选中 5.9.0 | `Ensure Pester is available` 步骤输出 |
| 本机只有 3.4.0，所以本地一直 124/124 通过 | `Get-Module -ListAvailable Pester` |

也就是说：**"本地全绿、CI 全红"不是环境噪音，是版本选择逻辑本身有 bug。**
"取最高版本"看似稳妥，实则把不兼容的主版本当成升级。

修复：显式锁定 `-PesterVersion 3.4.0`，按 `主.次.构建` 精确匹配，绝不降级/升级到别的
主版本；本地没有就下载到 `artifacts/.pester`（不写用户模块目录），仍没有则抛错并说明原因。
选择逻辑抽成可单测的纯函数 `tests/helpers/PesterSelection.ps1`，
新增 11 个用例锁死"必须选 3.4.0、只有 5.x 时必须返回 null"。

### 3.10 验收范围：让 CI 门禁只依赖声明的必选能力

整体状态必须保持真实（有 SKIP 就是 SKIP），但**门禁不能等于整体状态**，
否则可选能力的 SKIP 会让 CI 永远红，而删掉这些 SKIP 又是造假。

于是把范围与状态分开：

| 范围 | 必选 | 本机结果 |
| --- | --- | --- |
| `core` | MATLAB 可启动、产品清点、核心授权结论、数值与导出 | **PASS**（可选 SKIP 1 项） |
| `simulink` | core + 模型加载/更新/仿真/多工况 | **PASS**（可选 SKIP 1 项） |
| `coder` | core + 代码生成、真实编译、MEX 数值一致性 | **PASS**（可选 SKIP 1 项） |
| `full` | 以上全部 + `simulink.codegen-build`、`feature.*`、`embedded.hardware-in-loop` | **SKIP**（缺硬件在环） |

`overallStatus` 仍是 `SKIP`，`achievedLevel` 仍是 `L0`（L1 有一条 SKIP）——
**范围没有把任何 SKIP 变成 PASS**，只是把"哪一档能力可以交付"说清楚。
报告里同时写入所选 `scope` 和四个范围的求值结果 `scopes`，
CI 只对 `core` 设门禁，`coder` 放到需要显式申请 Coder 产品的可选 job。

### 3.11 CI 真实运行的三轮：修了什么，还剩什么

| 轮次 | 结果 | 原因 | 处理 |
| --- | --- | --- | --- |
| 第 1 轮 | free 层 0/124 全红 | Pester 版本选择（5.9.0 vs 3.4.0） | 显式锁定 3.4.0 + 纯函数单测 |
| 第 2 轮 | free 层 146/161 | `Should Throw` 在 PowerShell 7 失效；`Get-JsonValueKind` 不认 `[datetime]` | `Test-Throws` 助手；日期按 string 处理 |
| 第 3 轮 | free 层 160/161，双运行面一致 | ACL 授权校验用 SDDL 字面量搜 SID，命中别名（`LA`/`SY`）→ 误判失败并回滚 | 改用 `GetAccessRules(..., SecurityIdentifier)` 按 SID 语义比较 |
| 第 4 轮 | **free 层 161/161（5.1 与 7 都通过），Repository Checks 绿** | — | — |

第 3 轮那条是个**真实产品缺陷**，不是测试问题：`Get-Acl` 生成的 SDDL 会把知名 SID
渲染成别名（`S-1-5-21-…-500` → `LA`，`S-1-5-18` → `SY`）。GitHub runner 的账户
`runneradmin` 恰好是 RID 500，于是"给当前用户授权"这一步明明成功
（SDDL 里出现 `(A;OICI;FA;;;LA)`），校验却搜不到 SID 字面量，判定失败并触发回滚。
本机账户 RID 不是 500，所以本地一直通过——CI 是唯一能暴露它的地方。

同一个缺陷对真实用户也成立：任何以本地内置管理员（RID 500）身份运行安装器的人都会踩到。
修复后新增回归用例：给 `LocalSystem`（`S-1-5-18`）授权，断言 SDDL 里出现的是别名 `SY`
（证明字面量搜索必然落空），同时 `Test-AclContainsSid` 必须返回 `true`。

第 4 轮之后 `MATLAB Validation` 仍未在公共 runner 上执行：`matlab-actions/setup-matlab`
能装好 MATLAB，但没有许可证时 `-batch` 在 1~2 秒内以退出码 1 结束。
`-Layer matlab` 现在会把这种情形如实记为"本层未执行（已安装 ≠ 可执行）"，
workflow 也改为需要 `MATLAB_VALIDATION_ENABLED=true` 才运行，未启用时显示 **skipped**，
不会伪装成 passed。MATLAB 侧的真实验收证据来自本机 R2026a 运行（3.6 节）。

## 四、未验证内容与已知风险

必须在 PR 评审时如实告知：

1. **MATLAB 侧 `.m` 改动已在真机执行验证，覆盖到本轮已修正的授权范围。** 六个脚本在 R2026a 上真实跑通，
   包括此前被误判为"无授权"的 MEX 构建、`codegen -config lib` 真实编译、golden 数值对照、
   NaN/非法尺寸鲁棒性、`slbuild` + GRT 可执行文件产出（见 3.6）。**但"通用 C 代码生成 + 本机编译成功"
   仍然不等于 STM32 目标部署**。这一点没有变。
2. **`jsonNulls.m` 的边界覆盖已补齐，但仍不是穷举。** `matlab/validation/tests/masacc_boundary_probe.m`
   在真机上产出 9 类报告（单条/多条检查、全空字段、空清单、中文原因、许可证缺失、授权无法判定、
   运行异常、空报告拒绝），由 `tests/Acceptance.Boundary.Matlab.Tests.ps1` 用同一份 schema 逐项校验
   （69 个断言全通过）。`null` / `""` / `[]` 三种形态都已覆盖；未覆盖的是嵌套 metrics 内部的自定义结构。
3. **MCP 探测未对真实 MATLAB MCP 服务端执行。** 握手与工具调用全部来自假服务端的故障注入。
   真实服务端的 `initialize` 参数、工具名、返回结构可能与假定不同。本轮未新增真实 MCP 验证。
4. **层 C 全部未执行（只到了 Coder 编译层）。** MATLAB Coder / Simulink Coder / Embedded Coder 的
   **PC 端**代码生成与编译已真实通过，但 STM32 目标板下载与回读、外部工具链（Keil / IAR / CubeMX）
   集成、硬件在环闭环仍无证据。报告里 `embedded.hardware-in-loop` 是 L5 的 SKIP，
   `full` 范围因此必然不是 PASS。
5. **层 B（带许可证的 MATLAB CI）在公共 runner 上仍未执行。** 三轮 CI 失败的真实原因已全部定位并修复
   （见 3.11），`Repository Checks` 现已在 PowerShell 5.1 与 7 两个运行面上通过。
   但 `MATLAB Validation` 需要真实许可证：公共 runner 上没有，`matlab -batch` 会在 1~2 秒内退出码 1。
   现在 `-Layer matlab` 把这种情形记为"未执行"而不是"失败"，workflow 需要
   `MATLAB_VALIDATION_ENABLED=true` 才启用，未启用时显示 skipped。
   因此"MATLAB 能力已由 CI 验证"这句话仍然不成立——证据只有本机 R2026a 的运行记录。
6. **`license('test')` 的 27 字符上限是不可绕过的 API 限制。** 长 feature 名的产品（如
   `Sensor_Fusion_and_Tracking_Toolbox`）永远无法用该 API 判定授权，只能记"无法判定"，
   或改用真实执行探针（目前只为 MATLAB Coder / Embedded Coder / Simulink 实现了探针）。

## 五、复现方式

```powershell
# 层 A：免费环境（锁定 Pester 3.4.0）
powershell -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Layer free -PesterVersion 3.4.0

# 层 B：需要已安装 MATLAB
powershell -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Layer matlab
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabSkills.ps1 -TimeoutSeconds 1800 -Scope core
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabSkills.ps1 -TimeoutSeconds 1800 -Scope full

# MCP 五阶段探测
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabMcpExistingSession.ps1 -Json
```

验收报告位置：

- 主报告：`artifacts/validation/acceptance_report.json`
- 阶段子报告：`artifacts/validation/acceptance/<stage>.json`
- 阶段日志：`artifacts/logs/`
- 测试层报告：`artifacts/validation/tests/layer_report.json`
