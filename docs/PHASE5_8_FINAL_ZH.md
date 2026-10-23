# Phase 5.8 · 真实客户端交付闭环 · 最终交付报告

日期：2026-10-23（本轮全部证据生成于 13:07–19:01）
分支：`phase5.1-audit`（基线 `bf09e45`，Phase 5.7 冻结点）
范围：不增加新专业工具、不加第十个 Skill、不做大型工程案例；只做交付一致性、客户端证据、评分语义与回归。

## 0. 结论先行

| 问题 | 本轮结论 | 证据强度 |
| --- | --- | --- |
| 普通用户安装的版本与仓库一致吗 | **不一致**：四个客户端 0 个一致（Qoder 2/9 CURRENT、Codex CLI 5/9、Codex Desktop 5/9、WorkBuddy 0/9），20 条 SYNC 建议 | 逐文件哈希，`install_audit.json` |
| 客户端真的能发现这九个 Skill 吗 | **能**：两个 Codex 引擎在隔离项目里各返回 9/9，且 `SKILL.md` 哈希与仓库逐字节相同 | `skills/list` 原始响应 |
| 客户端用的是**正确版本**吗 | **仅在隔离项目副本上证明**（副本与仓库字节一致 + 哈希校验通过）；用户级根仍是旧版本，因此真实安装态尚未证明 | 1 条 episode 达 L4 |
| 有没有修改真实用户级 Skills | **没有**：45 个已安装副本在 13:07:58 与 18:38:02 两次快照间字节相同 | `client_evidence.json.userRootsUnchanged` |
| 回归是否守住 | MATLAB 1127/1127、Pester free 313/314（1 条为**既存**门禁失败）、19/19 汇总检查通过 | `regression_summary.json` |
| 能声称"装了文件 = 用上最新 Skill"吗 | **不能**，本轮也只在一条 episode 上做到了 L4，其余停在 L2/L3-eq 或 FAIL | 见第 5、6 节 |

一句话：**契约与回归侧闭环了，安装侧还差一次被批准的同步；客户端加载侧只在 Codex 隔离项目上取到 L4，且 L3（原生 Skill 装载事件）对 Codex 属于机制性不存在，不是我们没做到。**

---

## 1. Phase 5.7 冻结报告及 Git 状态

Task 0 是只读审计，结论：工作区与 Phase 5.7 报告一致，没有需要先报告的冲突。

| 项 | 冻结值 | 本轮复核 |
| --- | --- | --- |
| 分支 / HEAD | `phase5.1-audit` / `bf09e45` | 未变；`main`、历史 tag、`artifacts/phase57/**` 全程未写 |
| Phase 5.7 回归 | 1075/1075，32 套件 | `phase4_all.json` 仍 1075/1075，可读、大小不变（检查 18） |
| Phase 5.7 Task 1 安装审计 | `install_audit.json` | 仍可解析，9 个 Skill（检查 19） |
| 冻结参考实现 | 15 条 | 15/15 仍验证通过（检查 3） |
| Phase 5.7 Task 7 Coder 日志 | 5561 字节，`1a158f7d…` | **未重跑**该脚本；本轮用独立夹具另写自己的日志 |
| 唯一不一致 | 仓库卫生门禁在 HEAD 上就有 1 条失败（77 处盘符硬编码） | 如实保留为失败，见第 12 节 |

"在改动完整且无冲突的情况下安全提交 Phase 5.7 已验证的成果"——Phase 5.7 成果已在 `bf09e45` 落定，本轮不 amend、不 reset、不 rebase、不 push。

---

## 2. 四种客户端的实际版本差异

### 2.1 安装根与优先级（`install_audit.json.roots`）

| 根别名 | 客户端 | 优先级 | 存在 | 是否被证明参与解析 |
| --- | --- | --- | --- | --- |
| `REPO\.qoder\skills` | Qoder（项目级） | 5 | 否 | 项目 vs 用户优先级 **UNEXERCISED**，不臆测 |
| `QODER-CN` | Qoder（用户级） | 10 | 是 | **是**：qodercli.log 2026-10-23T11:06:29 记录它覆盖同名 `.agents` 副本（source: user） |
| `AGENTS` | Qoder + Codex | 20 | 是 | **是**：Qoder 扫描它但输给 `QODER-CN`；Codex app-server `skills/list` 从它返回 9/9 |
| `WB-LINK` → `WB-PHYS` | WorkBuddy | 10 | 是 | 链接根；**磁盘存在 ≠ 加载**，本仓库没有 WorkBuddy 技能列表探针 |
| `\.codex\skills` | Codex（legacy） | 30 | 是 | 存在但**没有任何 matlab-\* 技能**；config.toml 另有 `[[skills.config]]` 指向 `.agents` |

### 2.2 逐技能状态（d=内容不同文件数，e=仓库有而安装缺，x=安装多出）

| Skill | Qoder | Codex CLI | Codex Desktop | WorkBuddy |
| --- | --- | --- | --- | --- |
| matlab-codegen-deploy | DRIFTED d4 | DRIFTED d2 | DRIFTED d2 | DRIFTED d4 |
| matlab-control-optimization | DRIFTED d2 e3 | CURRENT | CURRENT | DRIFTED d2 e3 |
| matlab-data-analysis | DRIFTED d1 e12 | DRIFTED d3 e1 | DRIFTED d3 e1 | DRIFTED d1 e12 |
| matlab-orchestrator | CURRENT | CURRENT | CURRENT | DRIFTED d5 e2 |
| matlab-robotics-autonomy | DRIFTED d1 e6 | CURRENT | CURRENT | DRIFTED d1 e6 |
| matlab-runner | DRIFTED d5 | CURRENT | CURRENT | DRIFTED d5 |
| matlab-signal-vision-ai | DRIFTED d2 e13 | DRIFTED d4 e2 | DRIFTED d4 e2 | DRIFTED d2 e13 |
| matlab-simulink-modeling | CURRENT | CURRENT | CURRENT | DRIFTED d1 e3 |
| matlab-testing-ci | DRIFTED d6 e8 | DRIFTED d2 e5 | DRIFTED d2 e5 | DRIFTED d6 e8 |
| **合计** | **2 / 7 / 0** | **5 / 4 / 0** | **5 / 4 / 0** | **0 / 9 / 0** |

（CURRENT / DRIFTED / MISSING）

三点必须记住：

1. `matlab-testing-ci` 在每个安装根都落后——而它正是持有 `mas_delivery_check.m`（评分 v3）的那个 Skill。v3 契约在**用户机器上尚不可用**。
2. 没有任何客户端缺失技能（MISSING=0）：问题全是版本落后，不是没装。
3. 同名冲突 7 组：同一 Skill 在 `QODER-CN`/`AGENTS`/`WB-PHYS` 三处哈希不同，Qoder 会赢在最新的那份之外——冲突详情见 `install_audit.json.conflicts`（含每份哈希与"谁生效"）。

---

## 3. 安装同步 DryRun 与回滚方案

### 3.1 DryRun（未写任何文件）

| 目标根 | 决策分布 | 说明 |
| --- | --- | --- |
| `QODER-CN` | install 2 + conflict 7 | 7 个未登记在 manifest 的同名目录被**拒绝覆盖**，需 `-Force` 才接管 |
| `AGENTS` | update 4 + unchanged 5 | 受管根，升级路径明确 |
| `WB-PHYS` | update 9 | WorkBuddy 的物理根，9 个全部落后 |
| `WB-LINK` | **拒绝执行** | 路径含链接，安装模块抛 `技能路径包含链接，拒绝自动修改`——这是期望行为：不确认物理目标就不碰，绝不误操作整个数据目录 |

逐文件计划（`file_level_plan.{json,csv}`）：add 113、overwrite 59、identical 146、conflicts 7、updates 13、installs 2、unchanged 5，目标根 3、非目标根 2 保持不动。`keepUserFiles` 为 0，意味着这九个字节上没有用户自造文件需要保留——但保留通道已被测试覆盖（见 3.3）。

### 3.2 回滚方案（批准后按此执行，本轮未执行）

`docs/PHASE5_8_INSTALL_ZH.md` 第 7 节给了逐根顺序：一次一个根、先 `-DryRun` 后写、每步之后重新审计、不并行。回滚依赖备份会话：目录整备份 + manifest 登记（本轮修复，见 3.3），`Restore-SkillBackup` 可把目录与 manifest 一起还原。

### 3.3 本轮修掉的两个真实同步缺陷

1. **manifest 不随目录回滚**：旧实现替换目录前备份目录，但重写 manifest 时不登记它，回滚后 manifest 会声称装着新版本。现在重写前先记 `file`（或首装时的 `file-absent`）备份。
2. **1 引入的幂等回归**：无条件备份会让"全部 unchanged 的重复同步"也创建备份会话，违反零写入。现在只在 install/update/首次接管/`-Prune` 真清理时才落盘。

隔离验证结果（全部在临时根，绝不碰真实根）：

| 场景 | 结果 |
| --- | --- |
| `SkillSync.Phase58.Tests.ps1`（链接拒绝、`-Force` 接管与回滚、manifest 回滚、重复同步零写入） | **4/4** |
| `SkillSync.Phase57.Tests.ps1` | 4/4 |
| `Installer.Scenarios.Tests.ps1`（首装/升级/重复/用户文件保留/冲突/中断/备份恢复） | **23/23** |
| 隔离再发现：首次同步 9 装 0 升，第二次 0 装 0 升 9 unchanged，审计 `CONSISTENT` 9/9 | PASS（`sync_rediscovery.json`） |

---

## 4. 经批准后的真实同步结果

**BLOCKED — 未执行，因为没有批准。**

本轮遵守"在我明确批准前，不能修改 `.qoder-cn`、`.agents`、`.workbuddy` 等真实用户级 Skills 目录"，因此：

- 没有对任何真实根执行写入；唯一写过的同步目标是临时根（第 3.3 节的再发现测试）。
- 真实根在 13:07:58 与 18:38:02 两次快照间 **45 个已安装副本字节相同**。
- 因此**没有**"同步后由客户端自身发现列表确认已加载新版本"的证据可交付——这一项只能是待批准后补做，不能用磁盘哈希冒充。

批准后需要的最小决定集（对应 `docs/PHASE5_8_INSTALL_ZH.md`）：是否接管 `QODER-CN` 的 7 个 conflict（`-Force`）、是否更新 `AGENTS`（4 个）、是否更新 WorkBuddy 物理根（9 个，须先确认物理目标而非链接）、以及是否重启/刷新客户端以取发现日志。逐条清单在 `install_audit.json.recommendations`（20 条，全部 `requiresApproval: true`）。

---

## 5. Codex CLI / Codex Desktop / Qoder 原生调用证据

四级定义：L1 仓库带着这个 Skill；L2 客户端列表返回它；L3 客户端发出原生 Skill 装载事件；L4 任务经该 Skill 完成且被独立验收。

**Codex 的 L3 属于机制性不存在**：app-server/CLI 的事件类型只有 `error / agent_message / command_execution / mcp_tool_call / file_change`，没有 Skill 项。因此 Codex 记 `L3 = NOT APPLICABLE (mechanism)`，并单列 `l3ReadInstalledCopy`（从安装副本里读出内容）作为**能取到的最强等价证据**，明确不把它称作原生触发。

| 运行 | 客户端 | 结果 |
| --- | --- | --- |
| 隔离发现 | Codex Desktop 引擎 0.163.0-alpha.11.1 | `skills/list` 返回 **9/9**，`hashesMatchRepo=true`，无发现错误 |
| 隔离发现 | Codex CLI 0.147.0 | 同上 **9/9** |
| 环境隔离自检 | Codex Desktop（`env-isolation-test`） | 9/9，夹具用后删除 |
| Qoder | — | 优先级日志已观测（见 2.1）；**原生触发验证推迟**，因为其用户根 2/9 CURRENT、7/9 DRIFTED，同步需批准 |
| WorkBuddy | — | **NOT TESTED**：本仓库没有它的技能列表/任务接口；磁盘存在不外推为已加载 |

11 条 episode 的分级证据（`client_evidence.json.episodes`，失败原因如实保留）：

| # | 客户端 | episode | 状态 | L1 | L2 | L3-eq | L4 | 关键 trace |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Desktop | A_numeric_matlab | FAIL | E | E | EVIDENCED | NOT | 选中 Skill；沙箱拒绝创建进程（access denied），22 次命令 0 次 MCP |
| 2 | Desktop | A_numeric_matlab_E | FAIL | E | E | EVIDENCED | NOT | 选中并读 references；同样被沙箱拒绝 |
| 3 | Desktop | A_numeric_matlab_E2 | PASS | E | E | EVIDENCED | **PARTIAL** | 1 次 MCP 调用产出结果，但无独立验收覆盖该任务 |
| 4 | Desktop | B_simulink_model_E | PASS | E | E | EVIDENCED | **PARTIAL** | 3 次 MCP，交付 `.slx`，无独立验收 |
| 5 | Desktop | C_control_design_E | FAIL | E | E | NOT | NOT | MCP 传输中途关闭，未产生任何命令/工具调用 |
| 6 | Desktop | C_control_design_E2 | FAIL | E | E | NOT | NOT | 同上 |
| 7 | Desktop | C_control_design_E3 | PASS | E | E | EVIDENCED | **EVIDENCED** | 选 Skill→读 references→MCP 执行→工程检查→修复，8 次 MCP、26 次命令 |
| 8 | Desktop | D_nonmatlab_control | PASS | E | E | NOT | NOT | 负控：未选 Skill、未调 MCP、无交付（这正是期望） |
| 9 | Desktop | D_nonmatlab_control_E | PASS | E | E | NOT | NOT | 同上 |
| 10 | Desktop | iso_A | FAIL | E | E | EVIDENCED | NOT | 读 Skill 与 references 后被沙箱拒绝 |
| 11 | CLI | D_nonmatlab_control | FAIL | E | E | NOT | NOT | CLI 拒绝模型元数据，任务未开始 |

`userRootSkillReads`：11 条里只有 episode 1 从**用户级根**读了 2 次（临时根未建副本时的回退）；其余全部 `projectScoped=true` 且 0 次用户根读取。8 条断言全通过（`client_evidence.json.assertions`）。

---

## 6. 自然语言自动触发正负对照

四个任务，提示词里不含任何 Skill 名、不含 `mas_*` 名（11 条 episode 的 `promptHasSkillName` 全为 false），没有为抬高触发率而加任何强制调用指令：

- **A 数值 MATLAB**：4×4 三对角矩阵的行列式与最大特征值模，写 `result.json`。
- **B MATLAB+Simulink**：建一个一阶模型并交付 `.slx`。
- **C 专业域选择**：给 `P(s)=1/(s+1)` 设计 PID，要求整定时间 <2 s、超调 <10%——提示词**没提名** `matlab-control-optimization`，客户端自选了它，并顺带读了 `matlab-orchestrator`/`matlab-runner`。
- **D 非 MATLAB 负控**：不需要 MATLAB 的任务，正确行为是不调 MCP、不交付 MATLAB 产物。

观测到的自动选择：C 与 A/B 的可用运行里 `skillSelected=true`，且读到的路径就是隔离项目内的安装副本；负控 2 次 Desktop 运行 `skillSelected=false / mcpExecuted=false` 且无交付——断言"负控从不调用 MATLAB MCP 也不交付"通过。这说明选择不是提示词里的名字带来的，也不是我们把工具硬塞进去的。

被拦住的三件事必须写清（真实原因，不掩盖）：

| 阻塞 | 影响 | 处理 |
| --- | --- | --- |
| Codex Desktop 账号用量上限（2026-10-23T06:57Z 之后） | A/B/C 只有 1 次成功运行，无法凑统计量 | 记 BLOCKED，不虚构结果 |
| Codex CLI models cache 拒绝（缺 `supports_parallel_tool_calls`）+ Skill 上下文预算把描述挤掉 | 唯一一次 CLI episode 没读到 Skill | 记 BLOCKED；CLI 侧只保留负控 |
| Qoder 同步需批准 | Qoder 原生触发验证推迟 | 见第 4 节 |

---

## 7. 最小 MATLAB 工程闭环结果

一次真实 episode 走完：自然语言 → 客户端选 Skill → 装载 references → 官方 MATLAB MCP 执行 → 工程检查 → 修复 → 归一化结果 → 独立验收。

| 项 | 值 |
| --- | --- |
| 客户端 / 环境 | Codex Desktop 0.163.0-alpha.11.1，隔离项目（`.agents/skills` 副本与仓库字节一致，`skillHashVerified=true`） |
| 任务 | C_control_design（`P(s)=1/(s+1)`，Ts<2 s，Overshoot<10%） |
| 客户端交付 | Kp 5.6, Ki 9.9, Kd 0.1，超调 4.974848%，整定 1.504924 s |
| 独立复算 | 超调 4.974846%，整定 1.504924 s，峰值 1.04975，终值 1，闭环极点最大实部 −3，稳定，期望判决 PASS |
| 独立一致性 | `independentAgreement = true`（由本仓库自己的验收模块重算，不复用客户端结论） |
| 七维 | numericalCorrectness / enumContractValid / engineeringVerdictCorrect / structuralSchemaValid / workflowCompleted / withinBudget / deliveryValid **全 PASS** |
| v1 字段 | overall/format/enums/units/verdict/math/budget/workflow 全 PASS（未改写） |
| 客户端输入未被改动 | `clientInputsUnchanged = true` |
| 泄漏 | 事件流里出现一次会话 `apiKey`，已脱敏并留痕（第 12 节第 6 条） |

一处不体面但必须写出的事实：这条 episode 的 `clientReadsOutsideSkillCopy` 非空——客户端为了找 `scripts/Test-MatlabMcpExistingSession.ps1`，读到了**源仓库工作副本**里的 5 个脚本/schema。它恰好成功，是因为这台机器上正好有一个可读的 clone。这就是第 12 节那条潜在缺陷。

---

## 8. 新旧评分字段的语义对照

v3 协议 `mas-delivery-dimensions/3` 把"枚举拼写错"与"数值算错"分开，历史 v1/v2 结果一律保留。

| v2 维度 | v3 维度 | 语义变化 |
| --- | --- | --- |
| `fields` | `numericalCorrectness` + `enumContractValid` | **拆分**：类别词拼写不再算算术错误 |
| `verdict` | `engineeringVerdictCorrect` | 从不被数值结果反向放宽 |
| `schema` | `structuralSchemaValid` | profile / taskId / 必填字段 / 单位 |
| `route`, `tool` | `workflowCompleted` | 有阶段声明才判，否则 UNRECORDED，不猜 |
| `budget` | `withinBudget` | 用量 vs 声明上限 |
| `executed`, `integrity` | `deliveryValid` | 错误路径 / false-accept / runner 错误只聚合不细化 |

对 Phase 5.6 存档结果的 v3 **回顾性重放**（明确不是新实验、不是 Skill 效应）：

| 计数 | 值 |
| --- | --- |
| 重放结果数 | 9 |
| v1 字段逐字保留 | 9/9 |
| v1 `math=FAIL` | 4 |
| 其中**纯枚举**失败（`numericalCorrectness=PASS`） | **4** |
| 真正的数值失败 | **0** |
| 工程判决正确 / 结构合法 | 9 / 9 |

四条纯枚举失败都定位到具体字段：`R1/P56-SIG-B.state`、`R1/P56-ODE-N.stiffnessClassified`、`R1/P56-SIG-F.state`、`R2/P56-ODE-N.stiffnessClassified`。四条规则同时成立且被断言：`enumCountedAsNumericalError=false`、`numericallyCorrectRescuesContract=false`、`historicalV1FieldsRewritten=false`、`frozenThresholdsModified=false`。注意 `workflowCompleted` 在密封态是 NOT_REQUIRED、在分阶段态是 UNRECORDED，`deliveryValid` 分阶段态为 UNDETERMINED——重放**没有**因为数值正确就把它们调宽。

聚合规则：全 NOT_REQUIRED → NOT_REQUIRED；任一 FAIL → FAIL；存在 UNRECORDED/UNDETERMINED → UNDETERMINED。`mas_delivery_check.m` 的 `check_math()` 现在同时给 `M.status`（v1 合并语义，不变）、`M.numericStatus`、`M.enumStatus`，因此 v1 消费者零改动。

---

## 9. 隔离环境最终设计与审批要求

**DESIGN-ONLY，本轮未实施**（未创建系统账户、未改 ACL、未启用虚拟化、未改 MATLAB 全局配置）。详见 `docs/PHASE5_8_ISOLATION_DESIGN_ZH.md`。

| 方案 | 判定 | 批准门槛 |
| --- | --- | --- |
| A 非管理员账户 | `VIABLE-WITH-APPROVAL` | 需创建账户 + 许可可用性试跑；须显式重启 MATLAB MCP，否则 V13 仍以旧身份运行 |
| B Windows Sandbox / Hyper-V | `VIABLE-WITH-ADMIN-APPROVAL`（本机最现实的真边界） | 需管理员 + 可能重启；按臂快照回滚，进程与磁盘状态一起归零 |
| C 远程一次性执行 | `BLOCKED-ENVIRONMENT` | 本机无条件，本轮不实施 |

另有一条**无需批准**的现用手段：仓库外的隔离项目副本（本轮 episode 就是这么跑的）。

正式因果增益实验的前置门**未满足**：Phase 5.7 实测 V1–V13 是 **13/13 达到**（隔离完全失效）。特别地，V12 需要把 `benchmark/reference_p56.m` 与 `tasks_p56.json` 移出可读范围，只靠 ACL 挡不住"从规格推导答案"。验收要求：V1–V13 重测为 **0/13 达到**、正控必须能读、每臂 MATLAB 进程独立且跨臂 canary 读不回来、并得到明确批准。以上任一未满足 → 不启动三臂增益实验，也不把探索性运行写成因果结论。

---

## 10. 完整回归结果

`matlab/validation/phase58/p58_regression_summary.m` → **19/19 检查通过**，判决 `PASS (with 1 known pre-existing gate failure, kept as failed)`。任务清单十项逐条对上：

| # | 清单项 | 检查 | 结果 |
| --- | --- | --- | --- |
| 1 | Phase 5.7 1075 项 MATLAB 测试 | 全套 32 套件 + 增量归因 | 1127/1127，0 ERROR，393.6 s；+52 **全部**归 `deliveryCheck` 93→145，无套件消失、无缩水 |
| 2 | 九个 Skill 的引用与路由检查 | 九技能跨域 + 路由管道 + 能力矩阵 | 15/15 通过（0 fail/undetermined）、15/15 且路由一致、矩阵 8/8 且 9 目录 = 9 条目 |
| 3 | 客户端发现与版本校验 | 发现证据复用 | 两引擎 9/9 且哈希匹配仓库 |
| 4 | 安装同步隔离测试 | 再发现记录 + 真实根未写 | PASS；45 副本两次快照一致 |
| 5 | 原生调用验证 | episode 断言自检 | 11 episodes / 8 断言全过 |
| 6 | Schema 与评分协议兼容性测试 | v1 保留 + v3 附加 + 套件规模 | v1 未变 9/9；`test_delivery_check` 145/145、`test_grade_v2` 60/60 |
| 7 | Coder 测试 | 独立夹具复现三种入口（不重跑 Phase 5.7 冻结脚本） | 字符串→PASS@compare，句柄→FAIL@codegen，链接→FAIL@build 且日志 5708 字节逐字节相同；编译器 MSVC 2022 |
| 8 | 并发隔离测试 | `test_concurrency(3,2)` | 3/3 轮干净；跨会话读取 0、残留 0 |
| 9 | 能力矩阵一致性检查 | 并入第 2 项 | PASS |
| 10 | 历史参考哈希检查 | 冻结参考 + 5.7 记录 | 15/15；Phase 5.7 回归记录仍 1075/1075 且大小不变 |

Pester free 层：313/314 通过，1 条失败即第 12 节第 1 条那个既存门禁失败——`p58_regression_summary.m` 不是把它当"通过"，而是校验它**就是同一条**（日志里恰好 1 条失败行、点名 `MatlabAgentSkills.Core.Tests.ps1`、`[scan=git-tracked; files=437]`、命中清单 77 条），然后把它记进 `knownOpenFailures`。

---

## 11. 精确 Git Diff

### 11.1 已跟踪文件的修改（3 个文件，+381/−5）

| 文件 | 增 | 删 |
| --- | --- | --- |
| `scripts/Sync-Skills.ps1` | 33 | 3 |
| `skills/matlab-testing-ci/scripts/mas_delivery_check.m` | 214 | 2 |
| `skills/matlab-testing-ci/tests/test_delivery_check.m` | 134 | 0 |

语义：Sync-Skills 补 manifest 备份 + 幂等零写入；`mas_delivery_check.m` 增加 v3 七维与 `numericStatus/enumStatus` 分离（v1 字段不动）；测试从 93 长到 145。

### 11.2 新增文件（未跟踪 → 提交）

`docs/PHASE5_8_{CLIENT_EVIDENCE,INSTALL,ISOLATION_DESIGN,SCORING_V3,FINAL}_ZH.md` 5 篇、`matlab/validation/phase58/` 9 个脚本（4 个 `.m` 汇总/验收/证据、4 个 `.py` 只读探针、1 个 `.m` 再发现）、`tests/SkillSync.Phase58.Tests.ps1`，以及 `artifacts/phase58/**` 证据。

提交策略沿用前几阶段：`.gitignore` 忽略 `artifacts/`，本阶段用 `git add -f` 精确加入证据文件（原始事件流、`verification.json`、`skills/list` 响应、JSON 记录、控制台日志、逐文件计划 CSV），**不**加入 852 KB 的 `pid_step.mat`（原始时序，可由同目录的 `design_pid.m` 重生成）。新增 107 个文件（5 篇文档 + 9 个 phase58 脚本 + 1 个 Pester 套件 + 92 个产物）；逐文件行数以 `git show --numstat` 为准，本报告不复制一份会腐烂的总行数。

### 11.3 落地提交与未做的事

相对基线 `bf09e45` 的合并总量是 **110 个文件**（3 改 + 107 新）。落地提交以 `git log --oneline bf09e45..HEAD` 为准：
主成果 `a68b9ed`，其余提交都只是本报告的第 11 节与 episode 名称表述修正。
增删行数逐文件以 `git diff --numstat bf09e45..HEAD` 为准——本报告自身也在被统计，写死总行数会立刻腐烂。

不 push、不 merge、不 rebase、不 reset、不 clean、不改 `main`、不动历史 tag、不覆盖历史 Release、不 amend `bf09e45`。

---

## 12. 未解决问题与下一阶段建议

### 未解决（保留真实原因）

1. **仓库卫生门禁在 HEAD 就失败**：`tests/MatlabAgentSkills.Core.Tests.ps1` 的"没有盘符硬编码"用例失败，命中 **77 行 / 30 个已跟踪文件**（复算脚本 `artifacts/phase58/regression/gate_scan_v2.ps1`，逐行清单在 `pester_free.log`）。来源是 Phase 5.3–5.7 的报告与若干数据/测试文件，早于本轮。改写冻结报告等于覆盖失败记录，本轮选择**保留失败并给出清单**。Phase 5.8 自己的文件贡献为 0。
2. **真实用户级同步未完成**：`matlab-testing-ci`（含 v3 评分）在每个安装根都落后，WorkBuddy 0/9 CURRENT。需第 4 节的批准。
3. **Qoder 原生触发未验证**：不是失败，是被推迟——同步前验证只会拿到旧版本 Skill，等于给出错误的"客户端在用最新 Skill"结论。
4. **WorkBuddy 完全没有可核对的加载接口**：只有磁盘事实。它的根还是符号链接，任何写入都必须先确认物理目标，不能误操作整个数据目录。
5. **Codex L3 机制性缺失**：只要 Codex 不发出 Skill 事件，L3 就永远取不到；`l3ReadInstalledCopy` 是替代物而非等价物。报告与 JSON 里都分开记，不合并。
6. **一次凭据泄漏（已脱敏）**：episode 10 的事件流里，agent 的一次 grep 把 MATLAB MCP 会话 bootstrap 内容打进 transcript，含会话 `apiKey`。已在提交前替换为 `REDACTED:<sha256-12>`，前后哈希、次数与理由记在该 episode 的 `redaction.json`。真正的修法是**别让会话凭据出现在 agent 可读输出里**，这需要改 MCP 会话脚本，本轮未动。
7. **潜在缺陷 `skill-reads-outside-its-own-directory`**：`matlab-runner`/`matlab-orchestrator` 的 SKILL.md 让 agent 跑 `.\scripts\Test-MatlabMcpExistingSession.ps1`，该路径在安装副本内不存在，于是客户端跑到仓库工作副本里去读。它"成功"了，只在恰好有可读 clone 的机器上。修法：把该检查随 Skill 一起发布，并用相对 Skill 根的路径引用。
8. **探针残留诊断保留**：`fixtures/mcpprobe*` 与 `writeprobe*` 事件/错误日志留作负面证据（记录了 CLI 侧被拒的具体形态），不当作结果。
9. **统计量不足**：账号上限与 CLI 元数据拒绝使 A/B/C 各只有 1–3 次可用运行，只能做存在性证明，不能做增益推断。

### 下一阶段建议（按性价比排序，不自行开始）

1. 请批准第 4 节的最小同步集（先 `AGENTS`，再 `QODER-CN` 的 7 个 conflict，`WB-PHYS` 最后且需先确认物理目标），同步后**用客户端自己的发现列表/日志**复证，才算闭环。
2. 修第 7 条缺陷（把脚本发布进 Skill）与第 6 条泄漏面，二者都是一行级改动、收益直接。
3. 再谈强隔离：走 B（Sandbox/VM）并把 V1–V13 打到 0/13，否则任何"三臂增益"数字都不成立。
4. 把卫生门禁当一次专门的清理任务（77 行、30 文件），要么改写报告、要么在门禁里显式豁免冻结历史——**但不能删失败**。

Phase 5.8 到此停止，不自行进入 Phase 5.9。

---

## 附：产物索引

| 主题 | 路径 |
| --- | --- |
| 安装审计 / 逐文件计划 | `artifacts/phase58/install/{install_audit.json, file_level_plan.json, file_level_plan.csv, dryrun_*.log, sync_rediscovery*.json, pester_*.json}` |
| 客户端证据 | `artifacts/phase58/native/client_evidence.json` + `codex-{cli,desktop}-*/`、`codex-desktop-tasks/` |
| 闭环验收 | `artifacts/phase58/closed-loop/codex_desktop_pid_acceptance.json` |
| 评分 v3 重放 | `artifacts/phase58/scoring/scoring_v3_replay.json` |
| 回归汇总 | `artifacts/phase58/regression/{regression_summary.json, regression_summary.log, phase4_all.json, pester_free.log, gate_scan_v2.ps1}` |
| 详细文档 | `docs/PHASE5_8_{INSTALL,CLIENT_EVIDENCE,SCORING_V3,ISOLATION_DESIGN}_ZH.md` |
