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

### 3.4 真实 MATLAB 层（本机实测，结果为失败）

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
- 两次超时中 `stdout` 与 `stderr` 都是 **0 字节**，说明 MATLAB 卡在启动阶段，而不是被执行的内测脚本报错。
- 这条 FAIL 保留在测试里，不改成 SKIP。它就是当前环境的真实结论：这台机器上不能跑 `-batch`。

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

结论按证据收窄为：**本机 `-batch` 会在许可检查阶段长时间重试（70 分钟量级）后以 0x00000001 退出，期间零输出**。这既不是仓库脚本的错误，也不能归因为网络不通（许可服务器可达）。它是环境级阻塞，仓库存量无法绕过，只能如实记录并交给层 B CI。

## 四、未验证内容与已知风险

必须在 PR 评审时如实告知：

1. **MATLAB 侧 `.m` 改动未经成功执行验证。** 本机 MATLAB R2026a（`onlinelicensing`）在 `matlab.exe -batch` 下不产出任何输出：受控超时在 180 s 终止（见 3.4），不设超时的直连调用跑满 68 分 57 秒后以 `0x00000001` 退出、`-logfile` 为 0 字节。因此 `matlab/validation/*.m` 与 `+masacc/` 的语法以外的行为、数值断言与容差设定尚未由执行确认，需要层 B CI 才能最终确认。
2. **`matlab/validation/+masacc/jsonNulls.m` 的存在本身就说明两侧对齐是手工保证的。** MATLAB `jsonencode` 把空值写成 `[]` / `""`，而 schema 要求 `null`；如果不做这一步，`errorClass: ""` 会直接违反枚举、`exitCode: []` 会被判成类型错误。这段正则改写尚未在真实 MATLAB 上跑过。
3. **MCP 探测未对真实 MATLAB MCP 服务端执行。** 除 3.3 的会话配置阶段外，握手与工具调用全部来自假服务端的故障注入。真实服务端的 `initialize` 参数、工具名、返回结构可能与假定不同。
4. **层 C 全部未执行。** MATLAB Coder / Simulink Coder / Embedded Coder 的真实编译、STM32 目标板下载与回读、外部工具链集成，均未验证；报告中以 `SKIP` 出现。
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
