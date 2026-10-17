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
| `compiler.mex-build` / `compiler.numeric` / `compiler.robustness` | L2 / L3 / L4 | SKIP | MATLAB Coder 已安装但 `license('test')` 为 false |
| `codegen.generate` / `codegen.compile` | L1 / L2 | SKIP | 同上，代码生成未授权 |
| `simulink.model-artifact` | L1 | PASS | 建模型 → 保存 → 卸载 → 重载 |
| `simulink.model-update` | L2 | PASS | `SimulationCommand=update` 成功 |
| `simulink.simulation` | L3 | PASS | Step×3 → 稳态 3.0（容差 1e-9） |
| `simulink.parameter-sweep` | L4 | PASS | 增益 2 / 3 / 5 三工况均符合解析预期 |
| `simulink.codegen-build` | L4 | SKIP | Simulink Coder 未授权 |

整体判定必须遵守"SKIP 不得折算为 PASS"：本机因为 Coder 未授权、且 L1 的
`feature.direct-import` 未能检测到目标 API，存在多条 SKIP，所以
`overallStatus=SKIP`（退出码 3）、`achievedLevel=L0` —— **不是 PASS**。

`achievedLevel` 之所以是 L0 而不是 L3：等级是按层**连续**达成的，L1 里只要有一条没通过
就没有"达成 L1"，后面更高的层再通过也只能记在报告里而不能抬高等级。
这不是苛刻，而是避免"有 12 项 PASS 就宣称到达某一级"这种自我安慰。
真要抬高它，唯一的办法是把那条 SKIP 变成有证据的 PASS 或解释清楚为什么它不该在这一层。

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

## 四、未验证内容与已知风险

必须在 PR 评审时如实告知：

1. **MATLAB 侧 `.m` 改动已在真机执行验证，但仍然只覆盖已授权的能力。** `matlab_toolbox_inventory` / `matlab_feature_probe` / `matlab_skill_smoke` / `simulink_coder_smoke` 四个脚本的改动已在 R2026a 上真实跑通（见 3.4.4）；`matlab_compiler_chain_smoke` 与 `matlab_codegen_smoke` 的核心分支（MEX 构建、`codegen -config lib` 真实编译、golden 数值对照、NaN/非法尺寸鲁棒性）因为本机 **MATLAB Coder 未授权** 全部输出 SKIP，这四类断言仍未经真机确认 —— 需要一台有 Coder 许可证的机器或层 B CI。
2. **`+masacc/jsonNulls.m` 已随真机写报告跑过，但没有专门针对 `errorClass` / `exitCode` 的边界用例。** 本次真实报告能通过 PowerShell 侧 schema 校验，说明 `""` → `null` 这条路径是通的（PASS 项的 `errorClass` 就是空串）；不过"所有空值形态都覆盖到"仍属推断，不是穷举验证。
3. **MCP 探测未对真实 MATLAB MCP 服务端执行。** 除 3.3 的会话配置阶段外，握手与工具调用全部来自假服务端的故障注入。真实服务端的 `initialize` 参数、工具名、返回结构可能与假定不同。
4. **层 C 全部未执行。** MATLAB Coder / Simulink Coder / Embedded Coder 的真实编译、STM32 目标板下载与回读、外部工具链集成，均未验证；报告中以 `SKIP` 出现，原因是 `license('test')` 返回 false。
5. **CI workflow 未在 GitHub 上实际跑过。** 层 A / 层 B 的 workflow 改动只做了本地等价命令验证，未触发真实 GitHub Actions 运行。

## 五、复现方式

```powershell
# 层 A：免费环境
powershell -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Layer free

# 层 B：需要已安装 MATLAB
powershell -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Layer matlab
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabSkills.ps1 -TimeoutSeconds 1800

# MCP 五阶段探测
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabMcpExistingSession.ps1 -Json
```

验收报告位置：

- 主报告：`artifacts/validation/acceptance_report.json`
- 阶段子报告：`artifacts/validation/acceptance/<stage>.json`
- 阶段日志：`artifacts/logs/`
- 测试层报告：`artifacts/validation/tests/layer_report.json`
