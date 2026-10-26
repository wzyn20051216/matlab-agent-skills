# MATLAB Agent Skills — S3 交付报告：解除真实 MCP 阻塞并取得真实 L3/L4 执行证据

日期：2026-10-26
分支：`phase5.1-audit`
基线 HEAD：`876a2b0c67dae275c199415752226ed71c9c344f`（未 commit、未 push）
证据根：`artifacts/s3/evidence/`

## 0. 任务来源

用户给出 S2 报告第五节的四条下一步指令，并明确授权本轮处理此前保留给人工的会话重启、凭据更新与证书信任：

1. 轮换或撤销此前暴露的会话凭据，不能假定它已失效。
2. 恢复 MATLAB MCP 会话与 TLS 信任；不得修改系统信任配置来掩盖问题。
3. 重新运行安装副本的只读探针，首先不使用 `-SkipTlsValidation`；若仍失败，保留真实错误。
4. 验证真实执行层级；L3/L4 必须有真实执行证据，不能仅凭安装成功、探针能运行或 HTTP 请求已发出判定通过。

结论：四条全部完成。步骤 3 与 4 在 Windows PowerShell 5.1 与 PowerShell 7.6.9 两个宿主上、
在隔离安装副本中、在未使用 `-SkipTlsValidation` 的条件下取得 `overall=PASS / achieved=L4 / exit=0`。
未解决的负面结果原样保留在 §6。

## 1. 步骤 1：此前暴露凭据的处置

证据：`credential_rotation.json`、`apikey_leak_scan.json`。全程只记录 SHA-256 前缀、长度、
端口与 PID，任何终端输出、报告与夹具都不含凭据值。

| 项 | 暴露快照（S1 审计 13:49:09） | 当前会话（19:14:53 重写） |
| --- | --- | --- |
| `apiKey` 长度 | 48 | 16 |
| SHA-256 前 16 位 | `852b6e6d822c1bd9` | `a1c4d3f5e289147c` |
| 端口 | 31519 | 31520 |
| MATLAB PID | 7008（已退出） | 42956（存活，且是 31520 的监听属主） |

失效判定依据（`conclusion.revocationBasis`）：

- 铸造该凭据的 MATLAB 进程 pid 7008 已退出；连接器凭据只存活于该进程，因此无法再对任何当前服务生效。
- 会话描述符已不再携带该值：`852b6e6d…` 在 `sessionDetails.json` 中不存在，替换值的哈希与长度均不同。

判定限制（`conclusion.revocationLimits`，不做夸大）：

- 没有正向重放测试。原值从未被本项目复制，且已不可从磁盘读取，因此无法把它呈交给存活服务做"接受/拒绝"验证。
- **一处早期判定依据已撤回**（`session/provenance_correction.json`）：`credential_rotation.json`
  在 19:23 生成时把"端口 31519 已被一个无关联 MATLAB 进程复用"列为佐证。20:40 复核进程树后确认该说法**错误**：
  现在占用 31519 的 pid 15392 正是本轮 `Start-MatlabSharedSession.ps1` 自己启动的无头共享会话
  （其父启动器 51072 已退出），因此端口复用对旧凭据是否失效**不构成任何证据**。
  该佐证已从判定依据中撤回；原证据文件按历史保持逐字节不变，撤回记录写在新文件里。
  撤回后仍成立的依据只有两条：铸造该值的进程 pid 7008 已退出且凭据只存活于该进程，以及描述符已不含该值。

仓库扫描：3878 个文件、17 处凭据形态命中、0 处等于暴露值。

仍需人工确认（未擅自处理）：

- `artifacts/tmp_probe/session_ready.json`（2026-10-17，未被 git 跟踪、被 `.gitignore:1` 忽略）
  仍存有陈旧 `apiKey`/证书副本，记录哈希前缀 `e87d592931843721`、端口 31516、pid 38668（已退出），
  与当前存活会话不匹配，可证明惰性。本轮保留而非删除，因为未经批准不销毁历史。
- 更早的 S1 Trace 若曾携带该值，需要人工决定是否清理；本轮不删除历史 Trace、事件记录或费用账本。

未调用任何外部服务，未尝试使用发现的凭据，未通过外部渠道轮换。

## 2. 步骤 2：会话与 TLS 信任恢复

- 新会话：端口 31520，MATLAB pid 42956，R2026a `26.1.0.3276743 Update 3`。
- R2026a 的 `thisMatlab.pem` 是自签证书，`CN=127.0.0.1` 且**没有 SAN**，所以按主机名校验必然失败。
  采用的补救是**回环证书指纹固定**：指纹取自会话描述符自身（`EBB7E02ABC94A565A9E9328CDCC3EC06B3E25D7A`）。
- 明确没有做的事：未修改系统信任存储、未安装受信任根证书、未使用 accept-all 回调、
  未使用 `-SkipTlsValidation`（`skipTlsValidation=false` 记录在每次安装的驱动 JSON 中）。
- 诊断结论修正（这是 S2 BLOCKED 判定的真正原因）：官方连接器对 `POST /mcp` 的 HTTPS 直连
  对**任何**鉴权头风格都返回 403，这是设计行为，不代表"密钥错误"。官方支持的产品路径是
  `matlab-mcp-server-windows-x64.exe` 通过 **stdio** 承载 JSON-RPC，由它复用现有共享会话。
  因此把"真实执行"落到 stdio 传输，而不是在 HTTPS 观测路径上强行判定成功。
- 两处真实缺陷已修复并固化：
  1. PS 5.1 下 `ProcessStartInfo.StandardInputEncoding` 不存在，stdio 通道启动即崩（§6 保留红证据）。
  2. 安装副本缺少 stdio 依赖闭包，永远无法发现服务端。

## 3. 交付闭包（让安装副本真的能用）

- `config/skill-payloads.json`：新增 `scripts/MatlabAgentSkills.McpStdio.psm1` 与
  `config/mcp-server-manifest.json`（及 `McpProbe.psm1`、`schemas/acceptance-report.schema.json`），
  matlab-runner 9 个目标、matlab-orchestrator 8 个目标。
- `scripts/MatlabAgentSkills.SkillInstallation.psm1`：payload 目标根允许列表由 `scripts|schemas`
  扩为 `scripts|schemas|config`，并把"为什么 `config/` 必须在内"写进注释
  （`Get-McpServerManifest` 固定读 `<根>/config/mcp-server-manifest.json`，缺清单即 fail closed）。
  安全校验（相对路径、源根、密钥模式、与 Skill 自带文件冲突）全部保留。
- 先红后绿：
  - 红 `red/payload-install-target-root-rejected.json`：`payload 目标必须位于 Skill 根 scripts/ 或 schemas/ 内: config/mcp-server-manifest.json`，10/10 失败，原文保留于 `.log`。
  - 红 `red/payload-contract.json`：12 例中 2 例失败。
  - 绿 `green/payload-contract.json`：12/12；`green/payload-install.json`：`-Filter SkillPayload` 22/22。
- 文档同步（避免文档描述与实际行为不符）：`docs/ARCHITECTURE.md`、`docs/VALIDATION.md`、
  `docs/MCP_EXISTING_SESSION_ZH.md`（把过时的 401 段落改成真实的 403-by-design 说明并加传输表）、
  `skills/matlab-runner/SKILL.md`、`skills/matlab-orchestrator/SKILL.md`、
  `skills/matlab-runner/references/mcp-readiness-ladder.md`（新增 "Transport" 一节：查找顺序、
  403 按设计、"Never start with `-SkipTlsValidation`"、`-Transport stdio` 不回落）。

## 4. 步骤 3：安装副本探针复跑（不使用 `-SkipTlsValidation`）

驱动：`evidence/run-installed-verification.ps1`。它把九个 Skill 同步到 `%TEMP%\mas-s3-<tag>-<guid>`
的隔离安装根，对每个 payload 目标做 SHA-256 与仓库源逐文件比对，然后在独立子宿主进程里运行
**安装副本**的 `scripts\Test-MatlabMcpExistingSession.ps1`，解析安装副本自己写出的
`mcp_probe.json`。探测工程为 `D:\Temp\mas-s3-project`，其 `.mcp.json` 由真实安装器
`Install-MatlabMcpClients.ps1 -SkipBaseSetup` 生成，未触碰任何用户级配置。

| 宿主 | `-Transport` | overall | achieved | exit | 握手 |
| --- | --- | --- | --- | --- | --- |
| Windows PowerShell 5.1.26100 | `auto` → stdio | **PASS** | **L4** | 0 | PASS |
| PowerShell 7.6.9 | `auto` → stdio | **PASS** | **L4** | 0 | PASS |
| Windows PowerShell 5.1.26100 | `stdio`（显式 `-ServerExe`） | SKIP | L1 | — | PASS（见 §6） |
| Windows PowerShell 5.1.26100 | `https` | FAIL | L0 | 1 | FAIL（见 §6） |

两次 L4 运行的共同事实（`installed-5.1-auto-existing.report.json`、`installed-7-auto-existing.report.json`）：

- 安装侧：`installed=9`，全部 payload 目标 `matchesSource=true`，`skipTlsValidation=false`。
- `mcp.client-registration=PASS`，服务端来源 `registration:generic`（真实客户端注册，不是硬编码路径）。
- `mcp.protocol-handshake=PASS`，`transport=stdio`，`tlsMode=stdio`，
  `serverRelease=v0.15.0`，`serverIntegrity=VERIFIED_AGAINST_MANIFEST`，
  `serverSha256=A1F67DD917C5731F88399E1671EBE4F6959D2FD520C78DCAA1FAF3AD37EA9518`。
- 五个工具真实列出：`check_matlab_code`、`detect_matlab_toolboxes`、`evaluate_matlab_code`、
  `run_matlab_file`、`run_matlab_test_file`。

## 5. 步骤 4：真实执行层级

判定不依赖"请求已发出"，而依赖回执内容与被测文件的独立复核。

| 层级 | 检查 | 5.1 证据 | 7 证据 |
| --- | --- | --- | --- |
| L2 | `mcp.protocol-handshake` | `initialize` 返回合法 `result`，547 ms | 同，握手通过 |
| L3 | `mcp.readonly-exec` | `evaluate_matlab_code` 返回 `"26.1.0.3276743 (R2026a) Update 3\n"`，须匹配 `\d+\.\d+`，472 ms | 同一真实版本串，207 ms |
| L4 | `mcp.file-io` | MATLAB 在隔离目录写入 token `cbc09a86…`，宿主回读一致，`hostVerified=true` | token `c7d1e27e…`，`hostVerified=true` |

- 许可证：`mcp.matlab-license=PASS`，`provenBy=mcp.readonly-exec`（只有阶段 4 真实执行才把它从 SKIP 升为 PASS）。
- `unexecuted=[]`：没有任何检查因宿主缺失而被跳过却仍算入通过。
- 仓库级端到端另有 L5 证据（`e2e-existing-ps7/report.json`：6/6 PASS，含 Simulink 模型步骤）。

## 6. 保留的负面结果（未强行判定成功）

1. **HTTPS 直连仍 403**（`installed-5.1-https-existing.report.json`）：`tlsMode=pinned`、
   `pinnedThumbprint=EBB7E02A…5D7A`、`tcpReachable=true`、`httpStatus=403`，
   原因原文 `HTTP 403（远程服务器返回错误: (403) 已禁止）`；L3/L4 依规则标 SKIP。
   这说明证书固定解决了信任问题，而 403 是连接器的设计行为，不是可"修好"的故障。
2. **显式 `-Transport stdio` 时 `overall=SKIP / achieved=L1`，但 L2–L4 检查本身全部 PASS**：
   原因是 `mcp.client-registration=SKIP`（未建注册、只用 `-ServerExe`），
   而 `achievedLevel` 按既有连续性规则从 L1 起连续判定，L2 未达成即不得声称 L3/L4 达成
   （`scripts/MatlabAgentSkills.Acceptance.psm1`）。本轮**没有放宽这条规则**，
   而是用注册后的 `auto` 运行（§4）在保持规则的前提下取得真实 L4。
3. **无任何注册/无环境变量/无 `-ServerExe` 时安装副本找不到服务端**
   （`installed-installed-5.1-auto-existing.report.json`）：握手 FAIL，
   `transportNote` 原文记录"没有发现可通过清单校验的 matlab-mcp-server（已尝试：core-candidates）"，
   随后回落到 HTTPS 得到 403。真实用户的补救路径是客户端注册或 `env:MATLAB_MCP_SERVER`，
   已写入 mcp-readiness-ladder 的 Transport 一节。
4. **A–J 验收 D 阶段在安装纯净副本里得到 FAIL/L0**（`s2-acceptance-5.1/D-probe.verdict.json`：
   7 项检查、handshake FAIL、`mcp.client-registration=SKIP`）：D 的判据是"探针产出分级结论"，
   所以 D 记 PASS，而探针自身的 FAIL 原文保留。可移植性由 A–J 证明，真实执行由 §4/§5 证明，
   二者不互相冒充。
5. **PS 5.1 stdio 修复前的端到端红证据保留**（`e2e-existing/report.json`）：
   `mcp.server-start FAIL`，原因原文指向 `StandardInputEncoding` 属性在该宿主不存在；
   L2–L5 依规则 FAIL/SKIP。修复后同一脚本在 PS 7 达 L5，安装副本在 5.1 与 7 均达 L4。

## 7. 质量门禁复跑（最终代码状态，双宿主）

> 标注（2026-10-26 21:35）：本节记录到 20:37 为止；§11.1 的归属修复落地后门禁计数有变，
> 最终一次复跑见 §11.3（free 层 367→379，安装副本 L4 双宿主复现）。本节原文不改写。

全部编辑时间戳 ≤ 20:08:53，晚于该时刻的证据均基于最终代码。

| 门禁 | 5.1 | 7.6.9 | 证据 |
| --- | --- | --- | --- |
| Pester free 层 | 367：366 通过 / 1 失败 | 367：366 通过 / 1 失败 | `free-layer.{json,log}`、`free-layer-ps7.{json,log}` |
| McpProbe | 23 / 23 | 23 / 23 | `mcpprobe-ps51.json`、`mcpprobe-ps7.json` |
| McpStdio | 5 / 5 | 5 / 5 | `green/stdio-ps51.json`、`green/stdio-ps7.json` |
| SkillPayload（契约+安装） | 22 / 22 | — | `green/payload-install.json`、`green/payload-contract.json` |
| 独立安装验收 A–J | 10 PASS / 0 FAIL / 0 SKIP | 10 PASS / 0 FAIL / 0 SKIP | `s2-acceptance-5.1/`、`s2-acceptance-7/` |
| 安装资源逐文件哈希一致 | 123 文件、0 失败、0 违禁 | 123 文件、0 失败、0 违禁 | `*/B-installed-sha256.json` |
| 安装副本真实 MCP L4（本次新增门禁） | PASS/L4/exit 0 | PASS/L4/exit 0 | `installed-{5.1,7}-auto-existing.report.json` |

S2 的门禁计数上升，是因为 S3 新增测试（McpProbe 14→23、McpStdio 5）与新增 payload 目标（安装文件 119→123）。

唯一失败仍是**既有**的仓库卫生门禁「仓库里没有盘符硬编码路径（E 盘 / D 盘）」：
两个宿主命中的 `file:line` 集合逐字节相同，全部落在 git 已跟踪的历史文件上，
本轮未新增此类违规。该失败继续记为 FAIL，不豁免、不删除、不放宽。

## 8. S1 安全回归与凭据卫生

- A–J 的 H 阶段在**安装后布局**中重跑 S1 保护：`sanitizerRedacted=true`、`sessionPresent=true`、
  `keyAvailable=true`、扫描 21 个产物、0 泄漏（两宿主一致）。
- 本轮新增证据文件二次复核：`installed-5.1-https-existing.report.json` 等文件中
  `apiKey` 值零命中，仅出现 `hasApiKey` / `apiKeyLength`；驱动 JSON 同样只含长度与前缀。
- 未修改任何真实用户级 Skills 目录：`~/.qoder-cn/skills` 仍为 2026-10-21 13:42，
  `~/.codex/config.toml` 仍为 11:34（早于本轮），`~/.claude.json` 仍为 2026-10-21。
  安装全部落在 `%TEMP%` / `D:\Temp` 的隔离根。
- 无孤儿进程：当前仅存 4 个 `matlab-mcp-server-windows-x64.exe`，父进程为 11:32 启动的 Qoder CN（7412/33136），
  本轮 stdio 通道全部自行关闭（报告 `limitations` 记录 `exit=0, forced=False`）。
- 证据生产脚本与会话日志已归位到 `evidence/tools/` 与 `evidence/session/`；一次性查看脚本已删除。
  唯一残留：`artifacts/s3/scratch/matlab_shared_session.log` 被 pid 15392 以 `-logfile` 独占持有，
  无法移动（`evidence/session/session_holder.log` 保留了该 `Delete` 异常的原文），
  已在 `evidence/session/matlab_shared_session.log` 存了一份副本。

## 9. 约束遵守

- 未 commit、未 push、未 merge、未 rebase、未 reset、未 clean；`main` 与既有 Release 未动。
- 未修改 C 盘与系统配置，未修改系统证书信任。
- 未删除或改写任何历史证据与失败记录；S2 冻结文件未被编辑，仅在 `artifacts/s2/S2_FINAL_REPORT_ZH.md`
  末尾追加一行指向本报告的日期标注。
- 未新增第十个 Skill，未开发大型仿真案例，未重构 Agent/Router/MCP Server（只增加 stdio 传输模块与探针接入），
  未调用付费模型。
- 失败均保留真实原因；没有把 HTTP 请求发出、解析成功或安装成功当作执行成功。

## 10. 遗留事项（需要用户决定）

1. **本轮启动的 MATLAB 会话仍在运行，关闭它需要用户点头。** 进程树（`session/provenance_correction.json`）：
   pid 15392 是 19:14:16 由 `Start-MatlabSharedSession.ps1` 启动的无头共享会话，监听 31519，
   带 600 秒循环定时器保活；pid 42956 是它的子进程（19:14:27），监听 31520，
   也是 `sessionDetails.json` 当前指向的会话。启动器 51072 已退出，所以运行时虽由本轮造成，
   但已脱离本轮句柄（归属文件记为 `session_runtime_not_owned`），本轮**没有擅自关闭**。
   副作用需要知悉：全局描述符自 19:14:53 起指向 31520/42956，因此任何以 existing/auto 模式启动的
   MCP 客户端都会连到本轮新建的会话；11:32 的既有 MCP 会话（服务进程 35928/36044，
   MATLAB 10040/35936/29872）仍在运行，但不再是描述符指向的对象。
   关闭 15392/42956 会终结这个存活会话，请确认后再执行。
   （标注：本条由 §11.1 关闭 —— 归属判定已在真实进程树上修好并复现，处置结论为 **KEEP（保留并记录）**，
   未终止任何进程；`session_runtime_not_owned` 是旧谓词的产物，非本轮遗漏清理。）
2. `artifacts/tmp_probe/session_ready.json` 的陈旧凭据副本建议人工删除（本轮保留以待批准）。
   （标注：本条的"建议删除"已被 §11.2 推翻 —— 只读核验结论为 **EXPIRED_INFERRED + KEEP_UNCHANGED**，
   前后逐字节一致，无正向重放手段确证，因此默认保留并记录，删除与否交人工决定。）
3. `mcp.matlab-license` 只在有真实执行佐证时才 PASS；如需独立许可证校验，需显式 `-VerifyLicense`。
4. 盘符硬编码卫生门禁（本条原文写 77 条，§11.3 按证据更正为 78 处命中 / 449 个扫描文件）仍未修复，属独立范围。
5. S3 到此停止，不自行进入 Phase 5.9，不提交。

## 11. 收尾（2026-10-26 21:00–21:35）：进程归属、陈旧证据核验与最终门禁复跑

本节按审查意见的两个收尾项组织，并把两项处理过程中新产生的代码改动、证据与自纠全部记录在此。
§7、§10 保持原文不改写，只在各自条目下加指向本节的标注。

### 11.1 收尾项 1：本轮 MATLAB 会话的归属与处置 —— 结论 **KEEP（保留并记录）**

**根因（不是"清理没做"，是判定谓词与真实进程树形状不符）**
`bin\matlab.exe` 是启动器存根，真正的会话由 `bin\win64\MATLAB.exe` 承载，后者再派生
`sessionDetails.json` 里点名的引擎进程——会话运行时是启动器的**孙进程**。
旧的 `Test-MasOwnedProcess` 只看直接父进程且只比存根路径，因此对孙进程恒判不归属，
这就是 §10.1 里 `session_runtime_not_owned` 的来历（`session/provenance_correction.json` 记录了实测树形）。

**先红后绿**：S3-T6 先落失败测试——`evidence/red/session-ownership.json`（20:49，`-Filter ProcessCleanup`
34 例中 **10 失败**，失败名逐条指向"父链是 MATLAB 时应判 owned"这类断言），S3-T7 再实现。生产改动在
[scripts/Start-MatlabSharedSession.ps1](file:///E:/desktop/MATLAB/scripts/Start-MatlabSharedSession.ps1)：

- 新增 `Get-MasAncestorChain`（有界上溯，父进程已退出时记占位跳）与
  `Test-MasSessionRuntimeOwnership`（唯一归属判定入口），新增参数 `-SessionRuntimeMaxAncestorDepth`（默认 3）。
- 允许父链在 N 跳内到达启动器 PID，但**每一跳都必须自证**：进程名为 MATLAB、
  可执行文件在本次运行接受的清单内、启动时间落在本轮时间窗、同一 Windows 会话、身份字段齐全。
  任一跳自证不了就 `SKIPPED_ANCESTOR_*`，跳数用尽仍未见启动器则 `SKIPPED_LAUNCHER_NOT_IN_CHAIN`。
  多跳只是把判定放宽到真实树形状，**不是放宽证据要求**；放大深度参数等于扩大"自家进程"范围，
  因此 `.PARAMETER` 文档明确写了不要为了通过清理而调大。
- 审计事件 `session_runtime_owned` / `session_runtime_not_owned` 现在带 `reason`/`hops`/`launcherPid`/`chain`，
  归属结论可事后复核，不留黑盒。
- 对比 HEAD：`scripts/Start-MatlabSharedSession.ps1` +241/−43，`tests/ProcessCleanup.Tests.ps1` +227（全部为本节改动）。

**测试**：`tests/ProcessCleanup.Tests.ps1` 36/36 通过，PS 5.1 与 7.6.9 双宿主一致
（`evidence/green/session-ownership.json`、`session-ownership-ps7.json`）。用例数从红基线的 34 涨到 36，
是修复后又补的两条形状用例（启动器已退出但 PID 有在案记录、对真实存活进程上溯父链）；
归属 Describe 共 12 条：3 条断言"应当判 owned"（孙进程、直接子进程、启动器存根已退出但有在案 PID），
7 条断言"不应当判 owned"（父链不含启动器、中间跳不是 MATLAB、中间跳早于本轮启动即 PID 复用、
超出有界跳数、候选可执行路径不符、候选与启动器不同 Windows 会话、候选已退出），
另外 2 条钉住实现形状（对真实存活进程上溯父链不抛错且返回数组、主流程改用父链谓词而不再只认直接父子）。
反向那 7 条是重点：它们证明放宽跳数之后"证据不齐的父链"仍然一律不认。
其中包含一条只在实机上才会暴露的主机缺陷：`Get-MasAncestorChain` 原写 `return @($chain)`，
在 Windows PowerShell 5.1 上对泛型列表抛 `ArgumentException`，已改为 `.ToArray()` 并补了实机存活进程守卫用例。

**实机只读验证（不终止任何进程）**：`evidence/tools/live-session-ownership-report.ps1`
以 `-CleanupMode ReportOnly` 对真实进程树跑生产谓词
（`evidence/green/session-ownership-live-reportonly.json`，判断文字更正版 `-v2.json`）：

| 角色 | PID | 谓词 | hops | 说明 |
| --- | --- | --- | --- | --- |
| 会话运行时（描述符点名） | 42956 | ALLOW | 2 | 父 15392 → 已退出启动器 51072 |
| 会话主进程 | 15392 | ALLOW | 1 | 父为已退出启动器 51072 |
| 对照：非本轮启动的 MATLAB | 6288 | SKIPPED_IDENTITY_MISMATCH | — | 证明放宽后仍不过度信任 |

同一棵树在旧谓词下只会得到 `SKIPPED_LAUNCHER_NOT_IN_CHAIN`。

文档无需随之修改：本轮逐文件检索 `docs/`，没有任何文档描述过"只认直接父子"这条谓词，
因此不存在被本次改动打成过时陈述的段落；`docs/RELEASE_NOTES_WINDOWS_BETA_ZH.md:95` 那句
"共享会话清理改为归属校验（PID + 启动时间 + 可执行路径 + 会话 id）"仍然成立。
如实说明变化的性质：判定覆盖的**进程树形状变宽**了（孙进程现在也可能被认属），
但每一跳的证据要求只增不减，所以这不是把门禁调松；候选自身的四项身份字段校验一条都没动。
历史发布说明因此无需改写，也未被改写。

**为什么保留而不是清理**（审查意见明确要求"后续还要使用的会话就保留并明确记录，不能为了追求清理通过而误关"）：

1. 42956 仍是 `sessionDetails.json` 对外公布的会话，§11.3 的最终门禁复跑要用它，此刻终止会把 L3/L4 打成重新铸会话；
2. 归属判定虽已成立，但生产终止入口只认该轮写出的 `owner-<runid>.json`；该轮文件已不在磁盘上
   （仓库与临时目录检索无命中，`ownerRecordOnDiskForThatRun=false`）。用事后重建的记录去杀进程，
   正是失败关闭不变量要防的"事后授权"，本轮不做；
3. 需要释放时由人工在该 MATLAB 内执行 `exit`（或关窗），程序已写入证据的 `stopProcedure`；
   修复后的启动器在自己启动的那一轮会把存根与运行时都记进 owner 文件，届时默认 `-CleanupMode Graceful` 即可安全释放。

### 11.2 收尾项 2：`artifacts/tmp_probe/session_ready.json` —— **EXPIRED_INFERRED + KEEP_UNCHANGED**

只读核验脚本 `evidence/tools/verify-stale-session-ready.ps1`，结论文件
`evidence/session/stale-session-ready-verification.json`（原文保留）与 `-v2.json`（判断依据更正版）：

- 未删除、未覆盖：核验前后 size 244、mtime `2026-10-17T12:52:34Z`、SHA-256 `fbaa0d7a…d508f6` 逐字节一致。
  该文件未被 git 跟踪且被 `.gitignore` 忽略，不会随提交外泄。
- 判定为**推断惰性**而非"已验证被拒绝"：铸造该凭据的 MATLAB 进程（pid 38668）已退出，
  连接器凭据只存活于该进程内部；会话描述符已不再描述那个端口，且描述符里的凭据与本文件的、
  S1 泄露的那份互不相同（三份哈希各不相同，仅记录 16 位前缀，未回显任何凭据值）。
- **没有正向重放**：拿这份凭据去连当前服务等于使用发现的凭据，被本轮约束禁止，所以"失效"只能是推断。
  这一点连同"端口被别的进程复用不构成失效证据"一起写在 `limits` 里。
- 自我纠正（如实记录）：v1 把"当前监听进程自己铸造了另一份凭据"写成依据，但描述符已不覆盖那个端口，
  该值并不可观测——这与 S3 §1 撤回过的误判同属一类。v1 原文一字未改地保留，v2 重写依据与限制，
  并把端口复用那条降级为事实记录而非依据。
- 因此 **§10.2 的"建议人工删除"不再成立**：既然无法证明它是无用垃圾、删除又不可逆，
  默认动作是保留 + 记录；确需清除时由人工决定并留痕。若日后要确证凭据是否仍有效，
  唯一正路是人工在授权环境做一次鉴权测试，只记录接受/拒绝。

### 11.3 最终门禁复跑（基于 §11.1 修复后的代码，双宿主）

第一次复跑失败，且失败原因属于**操作方漏参**，不是产品退化；两份证据都保留：

| 次序 | 命令差异 | overall / achieved | 关键事实 | 证据 |
| --- | --- | --- | --- | --- |
| 21:28 | 未传 `-ProbeProjectRoot`（探测工程为空的 `%TEMP%\…\project`） | **FAIL / L0**，exit 1 | `client-registration=SKIP`（无注册）→ stdio 服务端只剩 `core-candidates` 且无法过清单校验 → `auto` 回落 `transport=https` → `POST /mcp` 得 **403（按设计）** | `evidence/final/attempt1-invocation-error/`（原文保留） |
| 21:33–21:34 | `-ProbeProjectRoot D:\Temp\mas-s3-project`（与 §4 同一探测工程，其 `.mcp.json` 由真实安装器写出，SHA-256 `939938b6…94ccdc`） | **PASS / L4**，exit 0 ×2 | `transport=stdio`、`serverOrigin=registration:generic`、`serverIntegrity=VERIFIED_AGAINST_MANIFEST`、`serverRelease=v0.15.0`、`skipTlsValidation=false` | `evidence/final/installed-{5.1,7}-auto-existing.report.json` |

归因依据（不是推测）：两次运行的 payload 逐文件哈希与历史 PASS 运行完全一致
（`Test-MatlabMcpExistingSession.ps1` `28ACC07D…`、`McpProbe.psm1` `19F63B3A…`），
驱动记录的 `transport`/`serverExe`/`sessionMode`/`skipTlsValidation` 四项参数也一致，
唯一差别就是探测工程根；而 `client-registration` 的 `source` 字段在历史 PASS 与本次 PASS 里
都指向 `D:\Temp\mas-s3-project\.mcp.json`。教训写进报告而不是写进代码：`auto` 的回落会把
"找不到受清单信任的二进制"表现成 403，操作方必须显式记录探测工程，不能把这类 FAIL 归因给产品，
也不能靠改门禁把它变绿。

真实执行仍未降级为"请求已发出"：L3 由 `evaluate_matlab_code` 回执 `26.1.0.3276743 (R2026a) Update 3`
（5.1 用时 591ms、7.6.9 用时 87ms，五个工具真实列出）；L4 由 MATLAB 在隔离根写入随机 token 文件、
宿主独立回读比对（`fileBytes=32`、`hostVerified=true`）。stdio 通道自行关闭，`exit=0, forced=False`，
本轮探针未遗留孤儿进程。

| 门禁 | 5.1 | 7.6.9 | 证据（UTC+8 时间戳） |
| --- | --- | --- | --- |
| ProcessCleanup（含 §11.1 新增 12 例） | 36 / 36 | 36 / 36 | `green/session-ownership{,-ps7}.json` 21:20 |
| Pester free 层 | 379：378 通过 / 1 失败 | 379：378 通过 / 1 失败 | `green/free-layer-final{,-ps7}.{json,log}` 21:24 / 21:27 |
| 安装副本真实 MCP（无 `-SkipTlsValidation`） | PASS / L4 / exit 0 | PASS / L4 / exit 0 | `final/installed-{5.1,7}-auto-existing.report.json` 21:34 |
| 安装副本首跑（漏参，保留为负面证据） | FAIL / L0 / exit 1 | FAIL / L0 / exit 1 | `final/attempt1-invocation-error/` 21:28 |

工作区与证据的时间关系已核对：本轮改动过的源文件里最晚的写入时间戳是 `tests/ProcessCleanup.Tests.ps1` 的
21:19，晚于它的第一份门禁证据是 21:20 的 ProcessCleanup 36/36，再往后是 21:24 / 21:27 的 free 层与
21:33 / 21:34 的安装副本 L4。即**没有源文件在任何一次最终门禁之后被改过**，表里的数字都成立于当前工作区状态。
`docs/*.md` 停在 20:08，§11.1 说明了为什么归属改动不需要跟着改文档。

free 层从 §7 的 367 升到 379，全部来自 §11.1 新增的 ProcessCleanup 用例。唯一失败仍是既有的
「仓库里没有盘符硬编码路径（E 盘 / D 盘）」：**78 处命中 / 449 个扫描文件 / 31 个文件**，
双宿主命中的 `file:line` 集合逐字节相同，且与修复前 20:13 / 20:30 两次运行的集合也逐字节相同；
本轮改动过的文件在命中集合里零出现（已按同一正则复扫确认）。该失败继续记 FAIL，不豁免、不删除、不放宽。
§10.4 原文写的"77 条"是转录错误，以证据里的 78 为准。

MATLAB 1127 用例层本轮**未复跑**，理由如实记录而非省略：§11.1 改动只涉及 PowerShell 归属谓词与测试，
没有 `.m` 文件引用 `Start-MatlabSharedSession.ps1`；该层最后一次全量运行为 Phase 5.8 提交 `a68b9ed`。
如审查要求"改一处即重跑全量"，请在批准提交时一并说明，本轮不擅自宣称该层已复现。

### 11.4 本轮自查引入并已修正的问题（不隐藏）

1. **编码回归**：修 BOM 判据时反向操作，剥掉了 5 个 `.ps1` 的 BOM，导致 PS 5.1 解析含中文的
   `CredentialSanitizer.Tests.ps1`、`McpCredentialOutput.Tests.ps1` 失败（Pester 只报
   "Error occurred in test script"）。已中止当时在跑的自由层，把本轮改动/新增的 `.ps1` 全部重写为
   UTF-8 BOM + CRLF 后重跑，才有 §11.3 的数字。
2. **自家卫生违规**：`ProcessCleanup.Tests.ps1` 引入 4 条 `E:`/`D:` 字面量，被盘符门禁抓个正着。
   改为运行期推导的 `$script:MasFixtureRoot`（含 UNC 回退），并加注释说明该门禁的存在。
3. **过度声明一次**：见 §11.2 v1→v2。
4. **漏参复跑**：见 §11.3 attempt1。

### 11.5 约束遵守（本节增量）

- 未 commit、未 push、未 merge、未 rebase、未 reset、未 clean；`main`、既有 Release、HEAD（`876a2b0`）未动。
- 未终止任何进程（含 15392/42956）；§11.1 的实机验证全程 `ReportOnly`。
- 未删除或改写任何历史证据与失败记录；`attempt1-invocation-error/`、v1 判断文件均原文保留。
- 未修改任何安全门禁的判定强度：`achievedLevel` 连续性规则、清单校验失败即拒绝、
  `-SessionRuntimeMaxAncestorDepth` 的默认值与告警文档，都比改前更严或等价。
- 未修改真实用户级 Skills 目录、C 盘与系统证书信任；未新增第十个 Skill；未调用付费模型。
- §10 的 5 条遗留里，第 1、2 条由本节关闭（结论为保留 + 记录），第 3、4 条维持原状，第 5 条仍然成立：
  **S3 到此停止，是否提交与推送由用户决定；未获批准前不动 git。**

收尾后的两次复核（22:06，均在最终门禁之后，不影响任何测试结论）：
`artifacts/tmp_probe/session_ready.json` 仍为 244 字节、mtime 2026-10-17 20:52:34(+08:00)、
SHA-256 `fbaa0d7a…d508f6`，与核验前逐字节一致，KEEP_UNCHANGED 成立；
pid 15392 / 42956 仍存活（启动时间 19:14:16 / 19:14:27），未被本轮终止，与 §11.1 的保留决定一致。
### 11.6 落地提交（2026-10-26 22:20 前后，用户明确批准）

审查结论出来后，就 git 处置给出四个选项（仅提交 / 提交并推送 / 暂不提交 / 只提交归属修复），
用户选择 **"提交到当前分支，暂不推送"**。据此把 S1–S3 全部工作区改动与证据作为**单次提交**
落在 `phase5.1-audit`：

| 项 | 值 |
| --- | --- |
| 提交 | `3379067a3d383bf282b5a9087f1126fd12c8dc43`（父提交即 §11.5 所述 HEAD `876a2b0`） |
| 规模 | 551 个文件、+86389 / −275（新增 524 个文件全部为 `artifacts/s2`、`artifacts/s3` 证据与本轮新测试，修改 27 个） |
| 工作区 | 提交后 `git status --porcelain` 为 0 条，报告、证据与磁盘状态一致 |
| 推送 | **未推送**；分支显示 `ahead 14`（相对 `origin/main`），`main` 与既有 Release 未动 |

提交前的凭据复核（不再依赖 §11.5 时的推断，改为对**实际暂存集合**逐文件扫描，
证据 `evidence/precommit-leak-scan.json` 已随提交入库）：550 个候选路径 / 526 个实际扫描 /
3 处凭据形状命中**全部为合成夹具**（`artifacts/s2/pre-fix/` 两处同一合成值、
`tests/ProcessCleanup.Tests.ps1:659` 一条 15 字符构造值）；泄露值副本 0 份、
当前会话密钥字面量命中 0 个文件、私钥块 0 个（`artifacts/s2/pre-fix/fake-cert.pem` 为公钥块）。
只记录路径、行号、字段名、长度与 16 位哈希前缀，未回显任何凭据值。

对 §11.5 的处理：该节文字**原文保留不改写**，因为它记录的是"批准前"的真实状态（含"未 commit、
未 push"与"是否提交由用户决定"）；本节即为它的日期化续写，两条并读才是完整链条。
提交内容不改变 §11.3 的任何门禁结论：盘符硬编码卫生门禁扫描 `artifacts/` 被排除，
故本提交既不新增也不减少那 78 处命中，该失败仍以 FAIL 状态入库而非被豁免。

MATLAB 1127 用例层仍未复跑，理由与 §11.3 末尾一致；本提交没有声称该层已复现。
