# Phase 5.6 — MATLAB Agent Skills 可信 Benchmark、原生触发与增益验证

本轮的边界：**只解决"实验可信"与"通用判断缺陷"，不继续加专业工具。**
九个 Skill 的 `mas_*.m` 里，本轮只动了三处：两处被判定为"判断缺陷"（`mas_stat_verdict` 五态、
`mas_ode_check` 误差字段契约）与一处失败信息规则（`mas_codegen_verify`）。
产品之外另有三类改动：`benchmark/` 新增 3 个 p56 夹具与 3 个封存/发布工具、`run_all.m` 注册 5 个新 suite、
并发回归的残留归因修正（测试侧，不是产品侧）。没有新增第十个 Skill，没有新增 Buck/Boost 案例。

子报告（各自独立、可单独复核）：

| 子报告 | 主题 |
|---|---|
| [PHASE5_6_PROTOCOL_ZH.md](PHASE5_6_PROTOCOL_ZH.md) | 预注册协议、失效判据、四个标签、统计口径 |
| [PHASE5_6_ISOLATION_ZH.md](PHASE5_6_ISOLATION_ZH.md) | 11 个对抗向量、隔离原语评估、补偿控制 |
| [PHASE5_6_GAIN_ZH.md](PHASE5_6_GAIN_ZH.md) | 三臂对照结果、四项标签、L1–L4 触发证据 |
| [PHASE5_6_ODE_FIELD_CONTRACT_ZH.md](PHASE5_6_ODE_FIELD_CONTRACT_ZH.md) | `error.maxScaled` 定义歧义修复前后 |
| [PHASE5_6_CODER_CHANNEL_ZH.md](PHASE5_6_CODER_CHANNEL_ZH.md) | Coder/MCP 通道诊断与对 Phase 5.5 的勘误 |

---

## 0. 最终问题 A–E：先写不能证明的部分

| # | 问题 | 本轮结论 | 支撑证据 | 不能说什么 |
|---|---|---|---|---|
| A | 原生 Skill 自动触发是否被证实？ | **否。** L3（`tool_use name="Skill"`）在 12 条 episode transcript 中出现 **0 次**；L1 也是 NOT EVIDENCED | `artifacts/phase56/episodes/trigger_evidence.json` | 不能把 Read 文件、把工作区自主发现、把编排会话里能看见 Skill 列表，说成"自动触发" |
| B | 同模型同任务下，Skill 是否有真实增益？ | **观测上一致偏向 R3，但不能称因果。** 3 个配对格 `R3−R1 = +1/+1/+1`；R2 在 3 格中与 R3 打平 2 格 | `artifacts/phase56/episodes/statistics.json` | 每格 n=1；强隔离 BLOCKED；不能给效应量、不能给提升百分比 |
| C | 增益来自"专业知识"还是"工具封装"？ | **大头来自文档，最后一格来自封装。** R2（只有文档）已拿 2/3；R3 多出的 1 格是枚举拼写 `nonstiff`（工具输出强制），R2 写 `non-stiff` | 同上 §3.1 | 不能说"工具带来了专业能力"——本轮只有 1 格可归因到封装 |
| D | Benchmark 能否阻止答案泄露与越权调用工具？ | **顺序性可以，访问控制不行。** 两阶段封存 + 承诺哈希 + absence scan 可证"答案在 episode 期间不存在"；但 11/11 对抗向量全部达到目标 | `artifacts/phase56/isolation/probe_report.json` | 不能称"隔离成功"；不能把程序性隔离叫强隔离 |
| E | 运行时间 / MCP 调用 / 恢复成本是否可接受？ | **可接受。** 9 集最长 290 s，最大 18 次调用（预算 25），0 次超预算；但 token 不可观测 | `statistics.json` perArm | 不能用调用数当 token 代理并对外宣称成本模型 |

---

## 1. 交付物 1｜结论摘要

1. **实现了一个"答案不存在于运行期"的评分流程**：先发布题目包（不含答案），把答案文件按哈希承诺，
   所有 episode 结束后才落盘 `answers.json`，再评分。`seal_manifest.json` 记录
   `sealedAt 2026-10-22 21:30:25` 晚于最后一集 `13:22:43`，`nEpisodes 12`。
2. **隔离被如实记为 BLOCKED**：11 个对抗向量 11 个达到（含当前/历史留出答案、兄弟臂产物、用户级 Skill 目录、
   本地 `matlab -batch`）。没有伪称隔离成功，也没有用"提示词禁止"充当访问控制。
3. **三臂对照跑完了 9/27 集并保留缺口**：R1 `correctnessPass` 0/3、R2 2/3、R3 3/3；
   `withinBudget`/`taskCompleted`/`deliveryValid` 三臂均 3/3。缺口 18 集**不做外推**。
4. **差异的位置被定位到"词表"而非"算术"**：三臂的 verdict 全部正确、数值字段全部在容差内；
   失分全部落在 `state` 五态枚举与 `stiffnessClassified` 枚举拼写。
5. **原生触发没有补造**：L3 = 0/12，L1 = NOT EVIDENCED；只把 L2（读文件）与 L4（执行 `mas_*` 并被封存答案验中）
   写成 EVIDENCED，并明确它们不是触发。
6. **修掉两个通用判断缺陷**：证据不足被误判为"被否定"（新增五态 `mas_stat_verdict`，19/19）；
   同一个键名承载两种误差定义（`mas_ode_check` 新契约，修复前 5/14 → 修复后 14/14）。
7. **Coder 通道结论被推翻并留痕**：Phase 5.5 认为"是 MCP 求值通道"，本轮按住 entry form 变量后证明
   **两个通道行为一致**，真正的判别变量是传给 `codegen` 的参数形态。5.5 的原文一字未改。

---

## 2. 交付物 2｜Task 0：Phase 5.5 冻结与只读审计

- 起点提交 `572641c`，分支 `phase5.1-audit`，工作树干净；未修改 `main`，未碰任何 Release tag
  （现有 tag：`v0.1.0`、`v0.6.0-preview.1`、`v0.6.0-preview.2`、`buck-v1-sim-baseline`）。
- Phase 5.5 的两个提交 `c052ecd` / `572641c` 的 77 个文件**内容零漂移**（`phase55BlobDrift` 为空）。
- 基线质量门禁：**803/803，24 个 suite，0 errored**，references 15/15，cross-domain 15/15，pipeline 15/15（298.1 s）。
- 冻结参考逐个哈希比对：`holdout-phase53` 的 `answers.json`、`answers_v1.json`、`tasks.json`、`tasks_v1.json`
  `unchangedSincePhase55 = true`；`manifest*.json` 在 5.5 未登记哈希，本轮登记当前值。
- 审计脚本 `artifacts/phase56/freeze_audit_p56.py`，输出 `artifacts/phase56/freeze/freeze_report.json`（`readOnly: true`）。

---

## 3. 交付物 3｜Task 1：强制隔离 —— BLOCKED，以及替代控制

**结论：在本机、本客户端、不修改用户系统的前提下，做不到。** 记录 BLOCKED，不降级成"部分成功"。

| 对抗向量 | 结果 |
|---|---|
| 当前留出答案 `MATLAB-bench-holdout-phase54\answers.json` | REACHED（返回了 verdict 与首个字段名） |
| 更早留出答案 `holdout-phase53\answers.json` | REACHED（返回任务数与任务 id） |
| 兄弟臂产物 `sibling_arm_R3\result.json` | REACHED（取回植入标记） |
| 用户级 Skill 安装目录（两处根） | REACHED |
| 本地 `matlab -batch`（绕过 MCP 直接跑） | REACHED |
| 其余 6 个向量（详见子报告） | REACHED |
| **合计** | **11 tested / 11 reached / 0 blocked / 无边界** |

候选原语逐条评估（DACL、加密、独立用户、虚拟机）都因"要么需要改用户系统、要么密钥与密文同卷"而未成立；
细节见 [PHASE5_6_ISOLATION_ZH.md](PHASE5_6_ISOLATION_ZH.md)。

**替代控制（本轮真的做了，而且测了）：**

1. **两阶段封存**：`benchmark_publish` → 承诺哈希 → 跑完 → `benchmark_seal`；`benchmark_seal` 拒绝
   早于最后一集、拒绝第二次封存、拒绝发布后被改过的任务文件（`test_two_phase_seal` 22/22）。
2. **absence scan**：扫描手臂目录里是否有答案键/答案词汇；`test_p56_stage` 21/21，其中两例专门证明
   "放进去的 `answer_key.json` 一定被抓到"且"episode 自己的 `result.json` 不会被误判为泄露"。
3. **共享会话清场**：所有 episode 共用同一个长驻 MATLAB，`addpath`/`cd`/变量会跨集残留。新增
   `p56_session_reset`，每集前移除 `mas_*` 可达路径、回中性目录、记录一行 JSON；`test_p56_session_reset` 14/14。
4. **账本扫的是"发给会话的 MATLAB 代码文本"**，不是子代理自述，因此"盲臂直接调用 `mas_*`"这条路会被记到
   （正式轮 R1/R2 命中 0）。

**因此本轮 episode 的定性**：题目答案在本机可读，按协议这些集属于 **EXPLORATORY**，
不得用来支持"增益由 Skill 暴露因果导致"。下文所有对比都只在"观测差异"层面陈述。

---

## 4. 交付物 4｜Task 2：三臂同别名对照（9/27，缺口如实保留）

### 4.1 设计（运行前冻结）

- 3 个任务事先冻结：`P56-SIG-B`（边界，UNDETERMINED）、`P56-SIG-F`（故障，FAIL）、`P56-ODE-N`（正常，PASS）。
  `tasks_frozen.json` sha256 `6b528da1c62f2cd4…`；发布包 sha256 `9ffb788f81378fdf…`。
- 三臂内容冻结、不放宽：R1 3 文件（0 `.m`、无 SKILL.md）／R2 23 文件（21 `.md`、0 `.m`）／R3 79 文件（54 `mas_*.m`）。
- 同一任务的 `prompt.txt` 三臂**逐字节相同**；提示里不出现 `mas_`、不出现 `routing`、不出现 Skill 名；
  R1 的 `ENVIRONMENT.md` 不提"有 Skill/有文档"（`test_p56_stage` 21/21）。
- 计划 3 任务 × 3 臂 × 3 重复 = 27；**实际 9 集**（每格 1 次）+ 3 集探针（`EXPLORATORY`，不计配对）。
  **缺口 18 集，按协议不强行凑数、不外推。**

### 4.2 四个标签分开记（不合并成"通过率"）

| 臂 | `correctnessPass` | `withinBudget` | `taskCompleted` | `deliveryValid` | verdict 正确 | UNDETERMINED 检出 | false accept/reject |
|---|---|---|---|---|---|---|---|
| R1 | **0/3** | 3/3 | 3/3 | 3/3 | 3/3 | 1/1 | 0 / 0 |
| R2 | **2/3** | 3/3 | 3/3 | 3/3 | 3/3 | 1/1 | 0 / 0 |
| R3 | **3/3** | 3/3 | 3/3 | 3/3 | 3/3 | 1/1 | 0 / 0 |

`correctnessPass` 要求 verdict 对 **且** 每个声明字段过；判据缺失记 `false`，不记 `true`。

评分器的 `pass` 还要求 `routeOk`/`toolOk`，而本轮提示**故意不含路由**且从未要求申报工具，
所以三臂 `pass` 都是 0/3——这是判据不适配，不是手臂失败，原文写在这里不隐藏。

### 4.3 差异在哪：三格逐字段

| 任务 | 臂 | verdict | 数值字段 | 未过字段 | 实际写法 |
|---|---|---|---|---|---|
| P56-SIG-B | R1 | UNDETERMINED ✓ | Wilson 上界 err 2.6e-12、期望事件 err 4.3e-05 ✓ | `state` | `neither` |
| P56-SIG-B | R2 / R3 | UNDETERMINED ✓ | 同上 ✓ | — | `insufficient-sample` |
| P56-SIG-F | R1 | FAIL ✓ | z err 3.4e-05、期望事件 err 3.2e-04 ✓ | `state` | `REFUTE` |
| P56-SIG-F | R2 / R3 | FAIL ✓ | 同上 ✓ | — | `sufficient-refutation` |
| P56-ODE-N | R1 / R2 | PASS ✓ | maxScaled 3.7e-9 / 4.8e-9、solverMaxScaled 4.359、drift 6.7e-9 全 ✓ | `stiffnessClassified` | `non-stiff` |
| P56-ODE-N | R3 | PASS ✓ | 同上 ✓ | — | `nonstiff` |

一句话：**R1 不是算错，是词表自创；R2 拿到了文档里的五态，但仍拼错 `nonstiff`；R3 的最后一格是工具输出强制的。**

### 4.4 成本

| 臂 | 工具调用合计 | MATLAB 求值 | 墙钟合计 | 单集最慢 |
|---|---|---|---|---|
| R1 | 29 | 13 | 524.7 s | 250.4 s |
| R2 | 47 | 21 | 734.5 s | 290.0 s |
| R3 | 47 | 17 | 530.7 s | 208.9 s |

R2 比 R3 更慢（墙钟 734.5 s vs 530.7 s，+38.4%）：它需要读 21 份文档才能拼出词表，而 R3 一次工具调用直接返回枚举。
这是本轮唯一在成本上反直觉但可解释的观测。

---

## 5. 交付物 5｜Task 3：原生 Skill 触发 L1–L4

| 级 | 判据 | 判定 | 计数 |
|---|---|---|---|
| L1 可发现 | episode 上下文是否注入 Skills 列表 | **NOT EVIDENCED** | 12/12 条子代理 transcript 无 listing；9 个 `matlab-*` 只在编排会话可见 |
| L2 自主读取 | 账本里有读 `SKILL.md`/`references`/`mas_*.m` | **EVIDENCED（仅 R2/R3）** | R1 0、R2 3、R3 4 —— 是文件访问，不是触发 |
| L3 原生机制调用 | `tool_use name="Skill"` | **NOT EVIDENCED** | 0/12 |
| L4 执行并被独立验收 | `mas_*` 被执行且评分器对封存答案判对 | **EVIDENCED（仅 R3）** | R3 4 集；R1/R2 = 0 |

提示纯度：12 集首条用户提示中，Skill 名出现 0 集，`mas_` 出现 0 集 —— 没有为了制造触发把工具名写进提示。

客户端支持范围：Qoder 子代理本轮 L2/L4 可证、L3 未证实；Qoder 主会话能看见 9 个 Skill；
**Codex CLI / Codex Desktop 本轮未运行 episode**，不补造任何事件，历史结论仍然只写在
`docs/SUPPORT_MATRIX_ZH.md` 与 `docs/WINDOWS_BETA_ZH.md`。

---

## 6. 交付物 6｜Task 4：两个通用判断缺陷的修复

两处都遵守同一顺序：**先构造能失败的测试，再改产品代码**。没有为了让历史任务从 MISS 变 PASS 而改冻结答案。

### 6.1 "证据不足"被当成"被否定"

- 症状：0 个误码、26624 bit 的测量被判为 FAIL（"否定"），而它其实没有能力看见 1e-4 的目标。
- 修复：新增 `mas_stat_verdict`，把结论分成五态 —— `sufficient-support` / `sufficient-refutation` /
  `insufficient-sample` / `interval-straddles-target` / `criterion-missing`；前两者映射 PASS/FAIL，
  后三者映射 UNDETERMINED。零误码对宽松目标仍是真证据（rule of three），不降级为"不确定"。
- 测试：`skills/matlab-signal-vision-ai/tests/test_stat_decision.m`，19 例，期望值由闭式公式在测试内算出，
  不从被测工具回读。

### 6.2 一个键名、两种误差定义

- 症状：Phase 5.5 的 `H54-ODE-N` 算术全对却被判字段 MISS —— `error_maxScaled = 2.66239`（求解器约定）
  被拿去和 `1e-8`（幅值约定）比，差 8 个数量级。
- 修复：`mas_ode_check` 升到 `mas-ode-report/2`，把分子、三种分母、单位、采样点、聚合方式各自命名；
  **`error.maxScaled = maxAbs/scale` 的数值一比特未变**，旧冻结答案仍按原约定判分。
- 测试：`skills/matlab-data-analysis/tests/test_ode_field_contract.m`，修复前 **5/14**，修复后 **14/14**；
  `test_ode_contract` 56/56、`test_data_contract` 118/118 不变。

---

## 7. 交付物 7｜Task 5：Coder / MCP 通道诊断（推翻了 Phase 5.5 的结论）

Phase 5.5 的判断是"新鲜 MCP 会话失败、`matlab -batch` 通过，所以是求值通道的问题"。本轮把**通道**与**参数形态**
两个变量分开：18 行探针覆盖 4 个通道 × 6 种入口形态。

| 事实 | 证据 |
|---|---|
| 入口用**文件名字符串**时，`matlab -batch`、`evaluate_matlab_code`、`run_matlab_file` 三个通道**都成功** | `coder_diagnosis.json` 的 `entryFormByChannelMatrix` |
| 入口用**函数句柄**时（匿名/带 cell/指向可解析文件），所有通道**都以同一标识失败**：`emlc:compilationError`，消息为空，控制台先打 `无法处理选项` | 同上 |
| 通道身份来自 `dbstack` 而非调用方标签：`evaluate_matlab_code` 与 `run_matlab_file` 都在 `mcpEval.m:48` + `LiveEditorEvaluationHelperEmatlab_mcp_server.m` 这一帧里 | `channel_B.json` / `channel_D.json` 的 `callFrames` |

**结论**：通道**不是**判别变量，**参数形态**才是。没有声称任何 MathWorks 内部根因。
产品侧唯一改动：`mas_codegen_verify` 失败时给出可读原因；Skill 规则改成"用文件名入口，不用函数句柄入口"。
5.5 的记录文件**一个字节都没改**，勘误写在本轮产物里（`phase55FilesTouched: none`）。

---

## 8. 交付物 8｜Task 6：统计协议逐条对账

协议在运行前写死（[PHASE5_6_PROTOCOL_ZH.md](PHASE5_6_PROTOCOL_ZH.md)），下面逐条对账禁项：

| 禁项 | 本轮 |
|---|---|
| 用非配对任务算相对提升 | ✗ 未计算。只用同任务同重复的 3 个配对格 |
| 把混合模型任务当同模型对照 | ✗ 12 集别名全为 `qfmodel`；且明确写"别名一致 ≠ 厂商模型名一致" |
| 把重复同一任务当独立新样本 | ✗ n 仍记 3 格，不记 9 |
| 未运行的任务计 PASS | ✗ 27 格里 18 格标为未执行，不进分母 |
| 仅据单任务算产品提升百分比 | ✗ 一个百分比都没给 |
| 把统计不显著解释为没效果 | ✗ 本轮根本不做显著性断言 |
| 预算违规时隐藏额外成本 | ✗ `withinBudget` 单列；本轮 0 违规，若有则原样保留 `false` |

未观测项（预先声明，不用代理冒充）：token 不可观测；厂商模型名不可观测；错误恢复率只有 1 个事件，
不足以估计；每格 n=1，给不了区间。

---

## 9. 交付物 9｜Task 7：全量回归与质量门禁

一次全新的 `matlab -batch` 进程，`matlab/validation/phase4/run_all.m`（含本轮新增的 5 个 suite）：

| 项 | 结果 |
|---|---|
| Skill 测试 | **894 / 894**，29 个 suite，`suitesErrored = 0` |
| references | 15 / 15 |
| cross-domain | 15 / 15（0 fail / 0 undetermined / 0 skip） |
| routed pipeline | 15 / 15（skillMatchRate 1，selfDisagreement 0） |
| codegen 并发 | 3 轮 × 2 进程，每进程 **13/13**，`ok=1`；新增残留 0（运行前已存在的 1 个 `.mexw64` 与 2 个临时目录单独登记，见 §10） |
| 耗时 | 336.9 s（`artifacts/phase56/regression/phase4_all.json`，timestamp `2026-10-23 11:21:29`） |

相对 5.5 基线的变化可对账：803 → 894 是 **+91**，正好等于新增 `twoPhaseSeal 22` + `p56Stage 21` +
`p56SessionReset 14` + `statDecision 19` + `odeFieldContract 14` + `codegen 12→13`。
**没有任何一个旧断言被删除、容差被放宽或历史评分器被改。**

---

## 10. 交付物 10｜本轮自曝的缺陷与失败（不隐藏）

1. **我自己制造了一次并发重叠**：在上一轮 `test_concurrency` 还没结束时又启动了一轮，4 个以上 MATLAB
   同时编译。结果 6 个进程全部报 **11/13**，且失败的两例没有打印原因。
   - 处理：不是删掉日志，而是先修"失败无原因"这个报告缺陷（`test_codegen` 现在对每个 FAIL 打印
     `verdict/stage/detail`），再在不重叠的条件下重跑。
   - 诚实边界：那两次 11/13 **无法证明**是资源竞争导致，只能说"重叠运行下观测到退化"，且该次数据不作正式结论。
2. **并发残留判据误判**：仓库根有一个**早于本轮**的 `codegen_target_mex.mexw64`，旧判据把历史文件算成本轮残留，
   得出 `ok=0`。修复：运行前快照，只把运行期间新增的文件算作残留，历史文件在记录里列出。
3. **同一类误判在临时目录上复发**：一次被系统挂起中断的运行留下了
   `%TEMP%\mas_codegen_tests\{tp9dec176f…, tpa2286e8b…}`，第二次运行仍按"总数"判，又报 `tempDirs=2 → ok=0`。
   第二次修复同样用"运行前快照 + 只算新增"，并且把被中断这件的目录名写进证据，而不是悄悄删掉。
4. **一次运行被系统中断**：`0x40010004`（控制台被关闭）发生在会话挂起之后，日志保留为
   `artifacts/phase56/evidence/revalidation_20261022/concurrency_clean3.log` 之前的
   `concurrency_clean2.log`，未删除。
5. **9/27 的缺口**：额度和客户端不稳定导致无法在预算内完成 27 集。按协议停在这里，不外推、不补造。

---

## 11. 交付物 11｜Capability Matrix 与 Git Diff

- `skills/capability-matrix.json`：`phase` 改为 5.6、`date` 2026-10-23，新增
  `autonomousExecution.phase56ControlledComparison` 一块（设计、四标签、配对、成本、封存、隔离、触发、Coder 勘误、
  `gainClaim: UNDETERMINED`）。`capability` 一致性检查 7/7 仍绿；工具计数未变（53 VERIFIED），未新增第十个 Skill。
- 格式：该文件仍以 `indent=1` + ASCII 转义 + CRLF 生成，可被 `json.dumps` 逐字节复现，
  因此 diff 是**单块新增**而不是整文件重写。
- Git Diff 与会话结束时的工作树状态见第 13 节（提交前实测）。

---

## 12. 交付物 12｜可证实 / 不可证实清单与停止点

**可证实（有可失败的测试或可复核的哈希）：**

1. 答案在 episode 期间不存在（封存时间、承诺哈希、absence scan）。
2. 三臂工作区的内容差异符合设计（`test_p56_stage` 21/21）。
3. 共享会话的清场确实生效（`test_p56_session_reset` 14/14）。
4. 9 集四项标签的原始计数（`statistics.json`）。
5. 原生触发的否定证据（transcript 计数）。
6. 五态判断与 ODE 字段契约（各自的失败→通过记录）。
7. 全量门禁 894/894。

**不可证实（本轮明确不做主张）：**

1. Skill 暴露的**因果**增益（隔离 BLOCKED，答案在本机可读）。
2. 任何百分比形式的"提升"（3 格、n=1）。
3. token 成本。
4. Codex CLI / Codex Desktop 的原生触发。
5. MathWorks 内部为何拒绝函数句柄入口。

**停止点**：本轮到此结束，等待人工审查。未执行 `push` / `merge` / `rebase` / `reset` / `clean`；
未修改 `main`、未改既有 tag、未覆盖任何冻结参考、未新增第十个 Skill。

---

## 13. Git 状态（提交前实测）

本轮全部改动落在本仓库内，单一提交包含 **100 个文件**（87 新增 / 13 修改），**+10732 / −49**，
`git diff --cached --shortstat` 分部如下：

| 部分 | 文件 | 增 / 删 |
|---|---|---|
| 代码与测试（排除 `artifacts/`、`docs/`） | 37 | +4402 / −49 |
| 中文交付文档 `docs/PHASE5_6_*.md` | 6 | +1003 / −0 |
| 证据 `artifacts/phase56/**` | 57 | +5308 / −0 |

- `artifacts/` 被 `.gitignore` 第 1 行整体忽略，而历史阶段（phase54/55）一直用 `git add -f` 提交证据；
  本轮沿用同一做法并**逐文件指定**，没有用 `git add -A` 或 `git add .`。
- **未提交** `coder_channel/{chA,chB,chD,form_*}/**` 的 Coder 构建树（60 个 `.obj/.mexw64/.lib/.pdb` 等二进制）
  与 `regression/*.mat`：它们可由 [PHASE5_6_CODER_CHANNEL_ZH.md](PHASE5_6_CODER_CHANNEL_ZH.md) 的复现命令重建，
  且仓库历史上不在 `artifacts/` 存二进制（`git ls-files artifacts | grep -E '\.(mat|mexw64)$'` 计数为 0）。
  构建事实由 `coder_channel/*.json`（每条 39 个产物、mex 落地、三通道逐字节一致）与 `coder_diagnosis.json` 记录，未丢失。
- 评测工作区 `E:\desktop\MATLAB-bench-phase56`（封存答案、手臂交付原文）不进仓库，只以哈希进入
  `skills/capability-matrix.json` 与本文档：`answers.json` sha256 `5397be4bf0…34fd2c`、
  `tasks_frozen.json` sha256 `6b528da1c6…429d4b`、封存 `episodes.json` sha256 `3ce6964…`。
- 暂存区之外没有任何未暂存或未跟踪条目（提交前 `git status --porcelain` 只有 `A `/`M ` 两类）。
  未执行 `push` / `merge` / `rebase` / `reset` / `clean`，未改 `main`，未改既有 tag。
- 行数为 `git diff --cached` 的文本口径（CRLF→LF 归一化后），不含二进制。

## 14. 复现命令

```matlab
% 全量门禁（一次完成 894 个 skill 测试 + references + cross-domain + pipeline）
addpath('matlab/validation/phase4'); run_all('artifacts/phase56/regression');

% 只跑本轮新增/修改的四个 suite
addpath('benchmark/tests', 'matlab/validation/phase56', ...
        'matlab/validation/phase54', 'skills/matlab-codegen-deploy/tests');
test_two_phase_seal(); test_p56_stage(); test_p56_session_reset(); test_codegen();
```

```matlab
% 封存与评分的全流程（在评测工作区里跑；answers.json 只在最后落盘）
benchmark_publish(tasksFile, bundleDir, referenceFile);              % 发布题目包，不含答案
%   ... 跑完所有 episode，episodes.json 记录每集 finishedAt ...
benchmark_seal(fullfile(bundleDir, 'publish_manifest.json'), ...
    tasksFile, referenceFile, evalDir, episodesFile);                % 此时才写 answers.json
G = benchmark_grade(resultsDir, tasksFile, fullfile(evalDir, 'answers.json'), ...
    fullfile(evalDir, 'manifest.json'), outFile, 'agentRuns', 3);
```

```bash
# 统计重算（从持久化 transcript 与封存评分重算，不手填）
python matlab/validation/phase56/p56_stats.py
```
