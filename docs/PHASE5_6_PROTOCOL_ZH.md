# Phase 5.6 正式三臂实验协议（预先注册）

本文件在**任何正式 episode 运行之前**写成并纳入提交。它预先固定：设计、失效判据、
统计口径、报告口径。事后不得修改本文件里影响结果的条款；若必须修改，只能新增一节
说明改动原因，并把受影响的 episode 全部作废重跑。

前提（来自 [PHASE5_6_ISOLATION_ZH.md](PHASE5_6_ISOLATION_ZH.md)）：本机**强隔离 = BLOCKED**
（11/11 对抗向量达到）。因此本实验的可信来源不是访问控制，而是三件事：
两阶段封存（答案在 episode 之后才存在）、承诺哈希（评分标准在 episode 之前已固定）、
逐条工具账本（实际读了什么可事后核查）。凡引用本实验数据，一律附此前提。

## 1. 设计（永久冻结）

| 项 | 值 |
|---|---|
| 臂 | R1 无 Skill（3 文件）／R2 仅文档（23 文件，0 个 `.m`）／R3 文档+工具（79 文件，54 个 `mas_*.m`） |
| 任务 | `P56-SIG-B`（边界/证据不足）、`P56-SIG-F`（常规/可判定）、`P56-ODE-N`（故障/定义歧义），均已在 `benchmark/tasks_p56.json` 冻结 |
| 冻结哈希 | tasks `9ffb788f…9cbdb`；公布 bundle `acb276af…7a4f8`；参考实现承诺 `8c85a00c…3fc9` |
| 模型 | 全程同一模型；客户端账本字段 `businessModelKey` 必须逐 episode 记录（本轮观测为别名 `qfmodel`） |
| 预算 | 每 episode 上限 25 次工具调用（含 MATLAB MCP），超时/超预算单独计 `withinBudget=false` |
| 重复 | 每格 3 次，共 3×3×3 = 27 episodes |
| 顺序 | 每一遍（repeat）内部对 9 个 (臂×任务) 格独立伪随机排序，seed `20261022` / `20261023` / `20261024`（`random.Random(seed).shuffle`），运行前写入 `episode_order.json`；遍与遍之间重新暂存并清空手臂目录，所以 repeat 2 看不到 repeat 1 的 `result.json` |
| 提示 | 逐字节使用 `arms/<arm>/<task>/prompt.txt`；不提及 Skill、`mas_*`、路由、工具名 |
| 工作区 | E 盘隔离区 `E:\desktop\MATLAB-bench-phase56`；不改动用户 Skill 安装目录、不改系统 ACL |

探针轮（3 个 episode，10-22 12:21–12:28Z，顺序 R1→R2→R3，仅 `P56-SIG-B`，未随机化）
**不计入正式配对统计**，只作为设计校准与账本可用性证据，标 `EXPLORATORY`。

## 2. 失效判据（预先注册，逐条对账本判定）

对每个 episode，从持久化 transcript（不是子代理自述）取全部工具调用，判定：

| 代号 | 判据 | 后果 |
|---|---|---|
| `answerLeak` | 观测到 `answers.json`／`seal_manifest.json`／`tasks_frozen.json`／仓库 `benchmark/dev/` 内容 | `INVALID_FOR_COMPARISON`，丢弃 |
| `crossArmRead` | 读取其他臂目录下的文件内容 | `INVALID_FOR_COMPARISON`，丢弃 |
| `armBlindnessBroken` | R1 读任何 `SKILL.md`/`references/*.md`，或 R1/R2 读取或执行任何 `mas_*.m` | `INVALID_FOR_COMPARISON`，丢弃 |
| `modelSwitch` | `businessModelKey` 与本实验首条记录不同 | `INVALID_FOR_COMPARISON`，不混入同模型统计 |
| `graderPathRead` | 读 `reference_p56.m` 或评分器源码 | `INVALID_FOR_COMPARISON`，丢弃 |
| `structureObservation` | 只列出评测根目录/本臂父目录的**名字**（未见内容） | **不作废**，但必须披露，并计入 `evalSidePathTouches` |
| `budgetBreach` | 工具调用 > 25 或超出运行时限 | 保留，`withinBudget=false`，不得隐藏额外成本 |

`structureObservation` 与 `answerLeak` 必须分开：本布局下 `ls ..` 能看到 `bundle/` 的
存在，这是布局弱点（Phase 5.7 建议把 bundle/manifest 移到手臂不可枚举的兄弟根），
但它不构成期望答案泄漏——正式轮期间 bundle 内没有期望值，`answers.json` 尚不存在。

## 3. 四个独立标签（不得合并成一个"通过率"）

| 标签 | 定义 |
|---|---|
| `correctnessPass` | 由 `benchmark_grade` 对封存答案判定：verdict 与全部声明字段通过 |
| `withinBudget` | 工具调用数 ≤ 25 且未超时（事实判定，不看结果好坏） |
| `taskCompleted` | 手臂交付了 `result.json` 且字段名与要求完全一致（结构交付，不看对错） |
| `deliveryValid` | 交付可被评分器解析（JSON 合法、可 decode、无缺字段） |

四者独立报告。超时但最终算对 → `correctnessPass=true, withinBudget=false`，
**不得**记为预算内成功；判据缺失 → `correctnessPass=false`（不是 `true`），并单独计
`criterion-missing`。未运行的格**不得**计为 PASS。

## 4. 统计口径

- 只用**配对**比较：同一 task、同一 repeat 的 R1/R2/R3 才允许相减；
  禁止用非配对任务算相对提升，禁止把重复同一任务当独立新样本扩大 n。
- 报告：每臂 `correctnessPass` 原始计数、配对成功差、`withinBudget` 完成率、
  错误恢复（首次 MATLAB 调用报错后是否在预算内得到正确交付）、false accept、
  false reject、`UNDETERMINED` 检出率、MCP 调用数、墙钟时长。
- 置信区间/效应量只在三格数据完整且可比时给出；不完整时只给原始计数 + 缺口说明。
- 混合模型、作废、`structureObservation` 命中但未作废的 episode 数量，全部单列。
- 统计不显著 ≠ 没有效果；单任务结果不得写成产品性能提升百分比。
- 结论强度：本实验能支撑"同模型同任务下三臂观测差异 + 成本"，
  **不能**支撑"差异由 Skill 暴露因果导致"——因为暴露未被强制（见 §前提）。

## 5. 原生触发 L1–L4 的判据（防止把 Read 冒充触发）

| 级 | 判据 | 证据来源 |
|---|---|---|
| L1 已安装/可发现 | 客户端 Skills 列表含 `matlab-*` | 编排会话 skill listing |
| L2 自主读取 Skill 文件 | 账本中出现 `SKILL.md`/`references` 路径的读取调用 | episode transcript |
| L3 原生机制调用 | 客户端 `Skill` 工具（或等价原生事件）被调用 | episode transcript 的 `tool_use name="Skill"` |
| L4 工作流执行并被独立验收 | 契约工具实际执行且评分器对封存答案判对 | MATLAB 结果 + `benchmark_grade` |

`Read`/`Grep`/`find`/文本提及**永不**计入 L3。某客户端若没有原生 Skill 调用事件，
就记 `NOT EVIDENCED`，不得补造。

## 6. 本轮已知不可回答的问题（预先声明，不用数据掩盖）

1. 强隔离下的因果增益：BLOCKED（需手臂以非属主身份运行，或 MATLAB 一起进 VM/容器）。
2. 公开模型名：客户端账本只提供别名 `qfmodel`，不暴露厂商模型名；别名一致 ≠ 模型名可比。
3. token 可观测性：episode 账本无 token 字段，只能用调用数与墙钟时长代理。
