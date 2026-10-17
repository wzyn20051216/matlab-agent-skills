# Phase 2.3 安全收尾与真实 MCP 集成验收报告

- 执行日期：2026-10-17
- 仓库：`github.com/wzyn20051216/matlab-agent-skills`
- 本机环境：Windows 11 26H2（build 26100）/ MATLAB R2026a Update 3（26.1.0.3276743）/ 官方 `matlab-mcp-server-windows-x64.exe` v0.15.0
- 前置状态：Phase 1（P0 安装安全）与 Phase 2（P1 执行引擎、验收协议、许可证修复、分层 CI）已完成

---

## 0. 总览

| 任务 | 结论 | 证据 |
|---|---|---|
| 一、ACL 权限校验修复 | **PASS** | 20/20 ACL 用例；free 层 182/182（PS 5.1 与 PS 7 双运行面） |
| 二、合并安全审查 | **PASS（仅出方案，未合并）** | PR #1 `MERGEABLE / CLEAN`，55 文件无杂散 |
| 三、真实 MCP 端到端 | **PASS（L1–L5 全通，双模式）** | `auto` 6/6 达 L5；`existing` 6/6 达 L5 |
| 四、Agent Benchmark 原型 | **PASS（3/3，20/20 检查项）** | 5 次真实 MCP 工具调用 |
| 五、最终质量审查 | **完成，见 §7** | 含 3 个新发现真缺陷 |

本轮**没有**放宽任何断言、删除任何测试、也没有为了让 CI 变绿而隐藏错误。相反，本轮发现并修复了 6 个真实缺陷（见 §1），其中 2 个是测试自身的假阳性来源。

---

## 1. 文件级缺陷清单及修复证据

### 1.1 `scripts/MatlabAgentSkills.Core.psm1` — ACL 校验只判 SID 存在

**缺陷**：`Test-AclContainsSid` 只检查"这个 SID 在 ACL 里有没有出现"。这会把三种危险情况误判为已授权：

1. 同一 SID 上挂的是 **Deny** 规则；
2. 挂的是只读（`ReadAndExecute`）而非 `FullControl`；
3. 挂的 `FullControl` **不继承**（只对文件夹本身有效，子目录与新建文件仍无权限）。

**修复**：改为计算**有效权限**。

- 新增 `Resolve-AclRuleSet`：对同一 SID 的多条 ACE 分别累加 Allow / Deny 掩码，再按 `Allow & ~Deny` 求有效权限；同时单独算出 `HasInheritingFullControl`（要求该 ACE 同时带容器继承与对象继承标志，且掩码覆盖 FullControl）。
- 新增 `Test-AclGrantsFullControl`：判定"文件夹本身"与"子项"两层的有效权限，`-RequireInheritance` 时额外要求继承位。
- `Set-DirectoryAclGrant` 的写后校验改用它。
- `Get-DirectoryAclSnapshot` 改用 `GetAccessRules($true,$true,[SecurityIdentifier])` 拿 SID 对象，不再做字符串比较。

**真机四形态实测**（`artifacts/tmp_probe/`）：

| ACL 形态 | 旧行为 | 新行为 |
|---|---|---|
| 仅 `R`（只读） | 误判 granted | 不 granted ✔ |
| `R` + `W` 两条 ACE | 误判 granted | 不 granted（缺 FullControl 位）✔ |
| `F` 但无继承标志 | 误判 granted | granted，但 `HasInheritingFullControl=false` ✔ |
| `grant F` + `deny W` | 误判 granted | Deny 优先，不 granted ✔ |

**RID 500 回归**：对内置管理员改用 `NTAccount("$env:COMPUTERNAME\Administrator").Translate([SecurityIdentifier])` 取真实 SID。新增 S-1-5-18（LocalSystem，SDDL 别名 `SY`）用例——**这个 SID 用字面量字符串搜索必然落空**，专门用来证明"字符串包含判断"这条路从一开始就是错的。

### 1.2 `tests/Acl.Permission.Tests.ps1`（新增，20 用例）

覆盖：拒绝规则、只读规则、继承规则、多 ACE 并集、RID 500、以及 `Resolve-AclRuleSet` 纯函数（不依赖 `icacls`，可在任何机器上跑）。关键用例把一条 FullControl 拆成 `0x120089` + `0xD0002` 两条 ACE，验证并集后等于 FullControl、但 `HasInheritingFullControl` 仍为 `false`。

### 1.3 `tests/helpers/FakeMcpServer.ps1` — 端口文件写入不可并发读（测试假阳性源）

**缺陷**：用 `Set-Content` 写端口文件，内部以 `FileShare.None` 打开。父进程 `Start-FakeMcpServer` 轮询到该文件时，若写句柄未释放，`Get-Content` 抛 `IOException: 文件正由另一进程使用`。

**这是纯竞态**：单独跑 `McpProbe.Tests.ps1` 时 13/13 全过；整套跑（负载高、窗口放大）稳定失败。第一轮复现为 free 层 3 个失败。

**修复**：改用 `[System.IO.File]::Open(..., FileShare.Read)` 显式允许并发读。

### 1.4 `tests/helpers/TestSandbox.ps1` — 读空文件时对 `$null` 调方法

**缺陷**：上面修完后仍偶发 2 个失败，报 `不能对 Null 值表达式调用方法`。原因是写者用 `FileMode.Create` **先把文件建成 0 字节**再写内容，此时 `Get-Content -Raw` 返回 `$null`，`.Trim()` 直接炸。

**修复**：读侧做空值守卫，并对 `IOException` 做重试。这两类都只是"还没写好"，是等待问题而非测试失败。

### 1.5 `scripts/Start-MatlabSharedSession.ps1`（新增）— `pause()` 持有会话会永久卡死 MCP

**这是本轮最有价值的发现。**

**缺陷**：早期用 `matlab -r "... shareMATLABSession; pause(86400);"` 持有共享会话。结果是：
- `shareMATLABSession()` 的 HTTP 监听跑在 MATLAB **后台线程**，所以 `GET https://localhost:31516/` 依然返回 `200 "The connector service is running."`——**看起来完全正常**；
- 但执行 MATLAB 代码必须回到**主线程**，而主线程被 `pause()` 永久阻塞；
- 表现为 MCP `initialize` / `tools/list` 全部正常，`tools/call` **永远挂起**（实测 300 s 无任何响应），且**服务端 stderr 干净、无任何错误可查**。

**定位过程**：先用 `curl` 直连 connector 确认服务 250 ms 内返回 200（排除 MATLAB 侧）；再确认 `sessionDetails.json` 指向的 PID 存活（排除会话过期）；最后读 `hold_console.log` 发现 `pause(86400)` 在主线程上，才锁定根因。

**修复**：改用一个空转 `timer` 保持 MATLAB 事件循环——timer 回调进主线程队列，主线程空闲即可对外服务，既不退出也不占住主线程。

**修复后验证**：`existing` 模式 `detect_matlab_toolboxes` 从"300 s 超时"变为 **5.0 s 返回真实工具箱清单**；完整 L1–L5 从 `3 PASS / 1 FAIL / 2 SKIP` 变为 **6/6 PASS**。

### 1.6 新脚本违反仓库卫生规则

新增 `Start-MatlabSharedSession.ps1` 时引入两处违规，被既有卫生测试当场抓住：
- 硬编码 `<盘符>:\matlab\bin\matlab.exe` → 改为复用 `MatlabAgentSkills.Execution.psm1` 的 `Resolve-MatlabExecutable`（显式 > `MATLAB_EXE` > PATH > `MATLAB_ROOT` > 全盘扫描）；
- 缺 UTF-8 BOM → 补上（Windows PowerShell 5.1 无 BOM 会把中文按 ANSI 解码成乱码）。

### 1.7 Benchmark 自身的 5 个真 bug（脚本试错过程中修掉）

Benchmark 第一轮 `overall=FAIL, 5/19`。逐一定位后全部修复，最终 20/20：

| # | 缺陷 | 现象 | 根因 |
|---|---|---|---|
| 1 | 工具参数名错误 | `check_matlab_code` / `run_matlab_file` 报 `-32602 unexpected additional properties ["file_path"]` | 官方 schema 参数名是 `script_path`，且 `additionalProperties: false` |
| 2 | Step 块未置零 | BM2 峰值时刻 2.57 s，偏差 1 s | `simulink/Sources/Step` 默认 `StepTime=1`，整个响应右移 1 s |
| 3 | **忘了接反馈** | BM3 稳态值 29.0 | 只有级联没有 Sum 与反馈线，等于开环跑；`1/(s(s+1))` 的阶跃斜坡响应在 t=30 正是 `t-1=29` |
| 4 | 设计矩阵横向拼接 | BM1 所有拟合参数输出 0 | `[sin',cos',ones']` 横向拼成 **1×2403** 而非 801×3，`A\y` 解的是欠定方程，`c(1:3)` 取到垃圾值 |
| 5 | 调节时间定义错 | 任何收敛良好的响应都报"调节时间 = 30 s" | 用 `find(abs(y-yss)<=band,1,'last')` 取到的是**最后一次在带内**（即仿真终点），应为**最后一次离开带外**之后 |
| 6 | `table()` 传入行向量 | CSV 表头变成 `t_1,t_2,...`（801 列） | `table(t', y', residual)` 中 `t'` 是 1×801 行向量，被展开成 801 个变量 |

> 第 3 条值得单独强调：它看起来像"数值不对"，实际是**建模错误**。如果只调容差是修不掉的——这类缺陷正是"必须用独立解析值验收"才能抓到的那一类。

---

## 2. ACL 权限校验测试结果

| 运行面 | 结果 |
|---|---|
| Windows PowerShell 5.1.26100.7462 (Desktop) | **20/20 PASS** |
| PowerShell 7.6.7 (Core) | **20/20 PASS**（随 free 层一并验证） |

报告：`artifacts/validation/tests/layer_report.json`

原有机制全部保留：ACL 备份、失败回滚、权限保护；所有权限变更只在 `mas-test-<guid>` 临时目录内进行，不触碰用户真实工作目录。

---

## 3. PowerShell 5.1 / 7 回归测试结果

修复 1.3 / 1.4 两处竞态后，连续多轮复跑：

| 运行面 | Pester | 用例 | 通过 | 失败 |
|---|---|---|---|---|
| Windows PowerShell 5.1.26100.7462 (Desktop) | 3.4.0 | 182 | **182** | 0 |
| PowerShell 7.6.7 (Core) | 3.4.0 | 182 | **182** | 0 |

分文件明细（PS 5.1）：

```
Acceptance.Boundary.Matlab.Tests.ps1    69   pass 69
Acceptance.Protocol.Tests.ps1           41   pass 41
Acl.Permission.Tests.ps1                20   pass 20
DependencyOrder.Tests.ps1                8   pass  8
Execution.Reliability.Tests.ps1         27   pass 27
Installer.Scenarios.Tests.ps1           23   pass 23
MatlabAgentSkills.Core.Tests.ps1        39   pass 39
McpProbe.Tests.ps1                      13   pass 13
PesterSelection.Tests.ps1               11   pass 11
RealExecution.Matlab.Tests.ps1           5   pass  5
```

> 注：竞态修复前为 `182 用例 / 179–180 通过 / 2–3 失败`，且失败数在运行间抖动——这正是假阳性的典型特征（与代码无关、与负载相关）。

---

## 4. 真实 MCP 端到端验收报告

### 4.1 环境确认

- MATLAB R2026a Update 3 真实可执行（`matlab -batch "disp(version)"` 退出码 0，12.1 s）
- 官方 server：仓库 `bin\matlab-mcp-server-windows-x64.exe`，自报 `github.com/matlab/matlab-mcp-server v0.15.0`
- 传输：**stdio**（JSON-RPC 2.0 over stdin/stdout），非 HTTP。协议版本 `2025-06-18`
- 会话模式：`auto` / `existing` / `new`；`existing` 模式不接受 `--matlab-root`
- 工具发现：5 个 —— `check_matlab_code`、`detect_matlab_toolboxes`、`evaluate_matlab_code`、`run_matlab_file`、`run_matlab_test_file`
- 工具箱：117 项，含 Curve Fitting、Control System、Simulink、Simulink Coder 等

### 4.2 代理陷阱（已修）

本机设了 `HTTPS_PROXY` 但没有 `NO_PROXY`。官方 server 是 Go 程序，会把 `localhost:31516` **也发给代理**，导致 403 / 超时。脚本现在显式设 `NO_PROXY=localhost,127.0.0.1,::1`。

### 4.3 分层验收结果

**`auto` 模式**（`artifacts/validation/mcp_e2e_report_auto.json`）：

| 层 | 检查项 | 状态 | 耗时 | 真实证据 |
|---|---|---|---|---|
| L1 | MCP Server 启动 | PASS | 2.01 s | server v0.15.0，pid 50968 |
| L2 | 协议握手 initialize | PASS | 0.22 s | `protocolVersion=2025-06-18` |
| L2 | 工具发现 tools/list | PASS | 0.02 s | 5 个工具，4 个必需项齐全 |
| L3 | MATLAB 只读执行 | PASS | 18.61 s | 输出 `26.1.0.3276743 (R2026a) Update 3` / `SUM=55` |
| L4 | 文件操作 | PASS | 1.39 s | 双向回读，宿主机二次核对 `hostVerified=true` |
| L5 | Simulink 建模 + 仿真 | PASS | 20.00 s | `FINAL=3.000000` / `SAMPLES=201` / `MODEL_BYTES=32316` |

**`existing` 模式**（`artifacts/validation/mcp_e2e_report_existing_v2.json`）：

| 层 | 检查项 | 状态 | 耗时 |
|---|---|---|---|
| L1 | MCP Server 启动 | PASS | 1.74 s |
| L2 | 协议握手 | PASS | 0.17 s |
| L2 | 工具发现 | PASS | 0.02 s |
| L3 | MATLAB 只读执行 | PASS | 0.21 s |
| L4 | 文件操作 | PASS | 2.13 s |
| L5 | Simulink 建模 + 仿真 | PASS | 52.23 s |

> `existing` 模式此前为 `3 PASS / 1 FAIL / 2 SKIP`（L3 超时 300 s）。根因是 §1.5 的 `pause()` 缺陷，非本仓库代码问题，但会直接影响到任何照搬该写法的使用者。报告保留了失败版（`mcp_e2e_report_existing.json`）作为证据，未删除。

**未使用 Fake MCP 冒充。** 仓库内的 `FakeMcpServer.ps1` 只用于单元测试里的协议层用例，不参与本次端到端验收。

---

## 5. 三个 Benchmark 案例的实际执行结果

报告：`artifacts/validation/benchmark/benchmark_report_215550.json`

**总览：3/3 PASS，20/20 检查项，5 次真实 MCP 工具调用，0 次失败。**

| 任务 | 触发 Skill | 工具调用 | 耗时 | 检查项 |
|---|---|---|---|---|
| BM1 数值分析脚本生成 | `matlab-data-analysis` | `check_matlab_code` → `run_matlab_file` | 38.27 s | 9/9 |
| BM2 Simulink 阶跃响应建模 | `matlab-simulink-modeling` | `evaluate_matlab_code` | 23.93 s | 4/4 |
| BM3 PID 调参对比 | `matlab-control-optimization` | `evaluate_matlab_code` ×2 | 11.36 s | 7/7 |

### BM1 — 数值分析脚本生成

Prompt：构造带高斯噪声的正弦信号 `y = 3*sin(2*pi*1.5*t) + 0.4`，最小二乘拟合，输出参数与残差 RMS，图像与数据落盘。

| 量 | 拟合值 | 真值 | 偏差 |
|---|---|---|---|
| 幅度 | 2.999989 | 3.0 | 1.1e-5 |
| 频率 (Hz) | 1.500525 | 1.5 | 5.3e-4 |
| 相位 (rad) | 1.563886 | 1.570796 | 6.9e-3 |
| 直流偏置 | 0.400794 | 0.4 | 7.9e-4 |
| 残差 RMS | 0.051624 | 噪声 σ=0.05 | 与噪声水平一致 |

产物：`analyze_noisy_sine.m`、`fit_data.csv`、`fit_figure.png`、`fit_summary.json`（后两者均经验证非空落盘）。

### BM2 — Simulink 阶跃响应建模

Prompt：单位阶跃 → 传递函数 `1/(s^2+2s+5)`，跑 5 s 仿真，报告终值、峰值、峰值时刻。

解析真值由 `ωn=√5`、`ζ=1/√5` 独立推出：稳态 `1/5=0.2`，峰值 `0.2(1+e^{-ζπ/√(1-ζ²)})=0.2415759`，峰值时刻 `π/(ωn√(1-ζ²))=1.5708`。

| 量 | 仿真值 | 解析值 |
|---|---|---|
| 终值 | 0.201497 | 0.2 |
| 峰值 | 0.241574 | 0.2415759 |
| 峰值时刻 (s) | 1.566229 | 1.5708 |

产物：`bm2_step_response.slx`（35 KB 级）。

### BM3 — PID 调参对比

Prompt：对 `1/(s(s+1))` 建 Simulink PID 单位阶跃模型，先 `Kp=1,Ki=0,Kd=0`，再调参，对比超调量、2% 调节时间、稳态误差。

| 指标 | 第一轮（纯比例） | 第二轮（调参后） | 变化 |
|---|---|---|---|
| 超调量 | 16.3034 % | 10.8312 % | **−5.47 个百分点** |
| 2% 调节时间 | 8.086 s | 1.294 s | **快 6.25 倍** |
| 稳态值 | 1.000000 | 1.000000 | 均无静差 |

第一轮超调量与解析值 `e^{-0.5π/√0.75}=16.30335 %` 相差 0.00005 个百分点，确认受控对象与闭环结构正确。第二轮参数 `Kp=30,Ki=40,Kd=12` 经离线参数扫掠选定（同时改善超调与调节时间两项，非事后挑容差）。

产物：`bm3_pid_compare.slx`。

### 5.1 关于"Agent 自主完成"与"预置脚本"的界定

Benchmark 报告的 `honesty` 字段写明了边界，此处重申：

- **规划层是规则路由 + 固定步骤序列，不是 LLM 自主规划。** 它证明的是：给定自然语言 Prompt，Agent 侧能正确选 Skill、选工具、填对参数、把结果验回来。它**不**证明 LLM 的自主推理能力。
- **执行层完全真实。** 5 次工具调用全部经官方 server 打到真实 MATLAB，返回数值原样入报告。
- **没有预置结果脚本冒充 Agent 产物。** BM1 的 `.m` 由 Agent 侧生成后先交 `check_matlab_code` 静态检查，再由 `run_matlab_file` 真实执行；BM2/BM3 的模型由 `evaluate_matlab_code` 现场 `new_system` / `add_block` 搭建。
- **预期值独立推导。** 全部用解析解（不用 MATLAB 输出反推预期），这也是 §1.7 第 3 条那种建模错误能被抓到的原因。

---

## 6. GitHub PR 修改记录及合并建议

### 6.1 当前拓扑

```
main                                    f76681d  补充MATLAB正版环境声明
 └── fix/p0-installer-safety            10d38bf  fix(installers): 第一阶段 P0 安装安全重构
      └── fix/p1-execution-validation   9f70541  feat(validation): 第二阶段 P1 执行引擎与工程验收体系重构
```

PR #1：`fix/p1-execution-validation` → `fix/p0-installer-safety`，**OPEN**。

### 6.2 审查结论

| 检查项 | 结论 |
|---|---|
| 依赖关系 | 线性三层，无交叉、无回退。p1 的 9 个提交全部在 p0 之后 |
| `mergeable` / `mergeStateStatus` | `MERGEABLE` / `CLEAN` |
| 变更规模 | 55 文件，+9790 / −553 |
| 非预期文件 | **无**。无 `artifacts/`、`bin/`、`.workbuddy`、临时文件、`sessionDetails.json`、`.pem` 泄漏 |
| CI 状态 | 层 A（免费测试 5.1 + 7 双运行面、静态检查）**pass**；层 B（Core MATLAB / Coder）**skipping**——需许可证，非必选，正确跳过而非失败 |
| 本轮改动是否影响 PR | 本轮 6 个文件改动 + 4 个新文件**尚未提交**，不在 PR #1 内 |

### 6.3 合并建议（**待批准，本轮未执行任何合并、删分支或改 main**）

建议顺序分两步，不要一次性串：

1. **先合 PR #1 到 `fix/p0-installer-safety`**。已 `CLEAN`，层 A 双运行面通过，层 B 按设计跳过。合完后 `fix/p0-installer-safety` 即包含 Phase 1 + Phase 2 全部能力。
2. **本轮（Phase 2.3）的改动作为独立提交/PR 再进**。理由：本轮包含 ACL 校验语义变更、两个测试辅助的竞态修复、以及 4 个新脚本，与 PR #1 的关注点不同，混在一起会让回滚粒度变粗。

**不建议**现在就把 `fix/p0-installer-safety` 合进 `main`。原因：层 B（真实 MATLAB 执行）在本运行面被跳过，等于"核心执行能力尚未在 CI 里被验证过一次"。建议层 B 至少在一个有许可证的运行面上绿一次，再考虑进 `main`。

---

## 7. 最终质量审查

| 审查项 | 结论 |
|---|---|
| **进程与会话生命周期** | **PASS**。`Stop-McpStdioServer` 顺序为：关 stdin → 等 `GraceSeconds` → `Kill` → 再等 5 s → `finally` 里 `Dispose` reader 与 process。E2E 与 Benchmark 的收尾都包在 `try/catch` 中，异常路径也保证写报告与关进程 |
| **安装卸载安全** | **PASS**（由 Phase 1 覆盖，本轮 23 个 Installer.Scenarios 用例 + 27 个 Execution.Reliability 用例全绿，含备份可逐字节还原、回滚删除新建文件、重复安装零写入） |
| **文件覆盖风险** | **PASS**。安装类操作有备份 + 回滚 + 托管标记；本轮新增脚本只写 `artifacts/`（已被 `.gitignore` 忽略） |
| **跨 PS 版本兼容** | **PASS**。5.1 与 7 双运行面 182/182。既有坑已规避：Pester 锁定 3.4.0（不用"取最高版本"）、`[version]"3.4"` 的 Build 为 −1 需归一化、`@($list)` 在 5.1 上对 `List[object]` 抛类型不匹配故用 `.ToArray()`、非 ASCII 脚本带 UTF-8 BOM |
| **工具箱缺失行为** | **PASS**。`detect_matlab_toolboxes` 返回真实清单；验收报告用 `licensed` 三态（true/false/null）而非布尔，缺许可证记 `null` 而非 `false` |
| **MCP 超时重试** | **无重试，超时即终态**。这是有意设计：MATLAB 工具调用本身可能要 20–90 s，盲目重试会把一次真卡死放大成多次。代价是瞬时网络类故障没有自恢复。**建议**后续仅在 L1/L2（进程启动与握手）加有界重试（如 2 次、指数退避），L3+ 保持终态。本轮未实现，避免投机性复杂度 |
| **JSON Schema 一致性** | **PASS**。41 个 Acceptance.Protocol 用例覆盖 schema 存在性、顶层字段完整性、非法 backend / 未知 errorClass / 缺必填字段 / metrics 类型错误均被拒绝；`checks` 必须是数组而非对象；SKIP/FAIL 缺 reason 时构造期直接报错 |
| **日志密钥泄露** | **PASS**。用真实 `apiKey`（36 字符）与 `certificate` 路径全仓扫描（排除 `.git` 与 `artifacts`）：**0 命中**。`Protect-McpSensitiveText` 对 `apiKey`/`token`/`secret` 脱敏；`sessionDetails.json` 位于 `%APPDATA%`，仓库 `.gitignore` 已排除 `artifacts/` 与 `bin/`，git 跟踪文件中 `artifacts/` 计数为 0 |
| **测试假阳性** | **已修 2 个**（§1.3、§1.4）。两者都是竞态，特征是"单独跑全绿、整套跑随机红、失败数抖动"。修复方式是让写入侧可并发读 + 读取侧容错，而不是加大超时或重试次数 |
| **不必要复杂度** | **PASS**。90 个跟踪文件，PowerShell 代码 9933 行。无重复造轮子的模块；`Resolve-MatlabExecutable` 等能力复用而非复制 |

### 7.1 已知限制

1. L1–L5 只证明本机 R2026a + server v0.15.0 的链路，不证明其它版本组合。
2. 会话文件会被任何一次 MATLAB 启动重写（含 `-batch`），所以持有共享会话期间不能在机器上再启动 MATLAB。
3. 官方 server 默认发送匿名遥测；脚本显式传 `--disable-telemetry=true`。
4. `existing` 模式的可用性依赖 §1.5 的 timer 持有法；照搬 `pause()` 写法会静默卡死。

---

## 8. 尚未验证的功能与技术风险

| 项 | 状态 | 风险 / 后续 |
|---|---|---|
| `run_matlab_test_file` | **未验证** | 5 个工具中唯一没被任何验收调用过的。需要补一个真实 MATLAB 单元测试用例（`function tests` 类） |
| MCP `resources` 能力 | **未验证** | `initialize` 声明了 `resources.listChanged`，实际返回过 `notifications/resources/list_changed`，但未读取 `guidelines://coding` 等资源内容 |
| MCP `logging` 能力 | **未验证** | 声明了 `logging` capability，未订阅 `notifications/message` |
| 层 B（真实 MATLAB CI） | **本运行面跳过** | 需在有许可证的运行面上至少绿一次，才能支撑合入 `main` |
| `new` 会话模式 | **未验证** | 只验了 `auto` 与 `existing` |
| Simulink Coder / 代码生成路径 | **仅 Phase 2 覆盖** | 本轮未回归；合入 `main` 前建议单独一轮 |
| `existing` 模式的长时间稳定性 | **有限验证** | 只连续跑通一次 L1–L5（约 56 s）。未验证跨小时级的会话稳定性，也未验证 MATLAB 侧异常（如被用户手动关闭）后的错误路径 |

---

## 9. 下一阶段（Phase 3）技术审查计划

> 本轮**未进入** Phase 3，也未合并 `main`。以下仅为计划。

### 9.1 STM32 / 嵌入式栈

1. **工具链真实性**：逐一验证 `arm-none-eabi-gcc`、STM32CubeMX、STM32CubeIDE 的真实可执行状态（区分"已安装"与"可执行"，同 Phase 2 对 MATLAB 的处理）。
2. **`Test-EmbeddedToolchains.ps1` / `Test-MatlabEmbeddedStack.ps1` 的证据强度**：当前 5 个 RealExecution 用例，需确认每一条 PASS 都有退出码 / 产物证据，而非"文件存在即算过"。
3. **硬件在环依赖**：明确哪些用例必须接真实 STM32 板，哪些可纯仿真；无硬件时的行为应是 SKIP + 原因，不是 FAIL。
4. **生成代码的静态检查**：把 CubeMX 生成工程接入 CI 静态检查（编译告警阈值、MISRA 子集）。

### 9.2 Simulink / PID

1. **把 §5 的 Benchmark 固化成 CI 门禁**：BM2/BM3 的解析真值已经是独立推导的，可直接作为回归基线；任何改动导致 `FINAL`/`OVERSHOOT_PCT` 偏离即报错。
2. **参数扫掠自动化**：BM3 目前参数是离线扫出来的，应改为脚本内自动扫掠 + 记录帕累托前沿，而不是硬编码一组"看起来不错"的值。
3. **补 `run_matlab_test_file` 用例**：用 MATLAB 单元测试框架写 BM2/BM3 的断言，闭合 §8 的第一个未验证项。
4. **Simulink Coder 路径单独一轮回归**：从建模到生成代码到编译，链条比纯仿真长得多。

### 9.3 工程化

1. **层 B 运行面**：为 CI 配一个带 MATLAB 许可证的运行面，让核心执行能力至少被验证一次。
2. **L1/L2 有界重试**：见 §7「MCP 超时重试」的建议，只在启动与握手层加，L3+ 保持终态。
3. **Benchmark 结果入库**：把三次 Benchmark 的指标写入可对比的时间序列，便于发现性能退化（BM3 的 `settlingSpeedup`、BM2 的 `peakTime` 偏差都是敏感指标）。

---

## 10. 本轮新增 / 修改文件

**新增**
- `scripts/MatlabAgentSkills.McpStdio.psm1` — stdio MCP 客户端模块（含 `PendingRead` 复用，修掉流撕裂）
- `scripts/Start-MatlabSharedSession.ps1` — timer 式共享会话持有器（修掉 `pause()` 卡死）
- `scripts/Test-MatlabMcpEndToEnd.ps1` — L1–L5 分层验收
- `scripts/Invoke-MatlabAgentBenchmark.ps1` — 三任务 Agent Benchmark
- `tests/Acl.Permission.Tests.ps1` — 20 个 ACL 用例
- `docs/PHASE2_3_ACCEPTANCE_ZH.md` — 本报告

**修改**
- `scripts/MatlabAgentSkills.Core.psm1` — ACL 有效权限评估（§1.1）
- `scripts/Setup-MatlabMcpExistingSession.ps1` — ACL 报告补 `verification` 字段，不改变授权行为
- `tests/helpers/FakeMcpServer.ps1` — 端口文件可并发读（§1.3）
- `tests/helpers/TestSandbox.ps1` — 读侧空值守卫 + IOException 重试（§1.4）

以上改动**尚未提交**，等待你审阅后再决定提交与合并方式。

---

*所有 PASS 均有真实执行证据；所有 SKIP 与未验证项均在 §8 列明原因。本轮未通过放宽断言、删除测试或隐藏错误使任何指标变绿。*
