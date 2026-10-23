# Phase 5.8 · 交付评分协议 v3：七维独立与枚举/数值分离

日期：2026-10-23
分支：`phase5.1-audit`
范围：Task 4（把 Phase 5.7 的 4 例"不达标"按性质重新归类，而不是按标签继承）
实现：`skills/matlab-testing-ci/scripts/mas_delivery_check.m`（`dimensionSchema = mas-delivery-dimensions/3`）
重放：`matlab/validation/phase58/p58_scoring_v3_replay.m` → `artifacts/phase58/scoring/scoring_v3_replay.json`
回归：`skills/matlab-testing-ci/tests/test_delivery_check.m` 145/145 PASS

## 0. 结论先行

| 问题 | 结论 |
| --- | --- |
| v3 是否已实现 | **是**：7 个维度由 `mas_delivery_check` 直接产出，每个维度记录派生自哪些 v1 字段 |
| 枚举错误还算数学错误吗 | **不算**：9/9 交付的 `numericalCorrectness` 全为 PASS；4 例失败全部落在 `enumContractValid=FAIL` |
| 数值正确性能否放宽交付契约 | **不能**：声明 workflow 阶段后，5 例数值与结构都正确的 `deliveryValid` 从 PASS 降为 **UNDETERMINED**，不是 PASS |
| 历史 v1/v2 结果是否被改写 | **没有**：10 个输入文件重放前后 SHA-256 逐一相同；9/9 行的 `v1Overall`/`v1Math` 与 `artifacts/phase57/delivery/delivery_audit.json` 归档一致 |
| 冻结阈值是否被改 | **没有**：`rules.frozenThresholdsModified = false`；本轮未接触 `benchmark/` 的容差与阈值文件 |
| 真实交付上跑通过吗 | **跑通**：Task 3 的 Codex Desktop PID 闭环，7 维全 PASS，`workflowCompleted` 由 5 个声明阶段判定 |
| 能不能当作新 Benchmark 或 Skill 增益 | **不能**：`kind` 字段写明 retrospective replay，样本仍是 Phase 5.6 已封存的 9 份结果 |

## 1. 问题：一个标签分不清两种错

Phase 5.7 §4 把 9 份交付记为"9/9 格式合法、5/9 数学达标、4 例格式合规但数值错误"。
逐字段回查后，这 4 例的失败字段是**分类词表**，不是数：

| 臂 | 任务 | 被判"数值错误"的字段 | 字段类型 |
| --- | --- | --- | --- |
| R1 | P56-SIG-B | `state` | 字符串枚举 |
| R1 | P56-SIG-F | `state` | 字符串枚举 |
| R1 | P56-ODE-N | `stiffnessClassified` | 字符串枚举 |
| R2 | P56-ODE-N | `stiffnessClassified` | 字符串枚举 |

`numericBadFields` 在 4 例中全部为空——没有任何一个数字超出容差。

这个误标在 v2 里是结构性的，不是笔误。`benchmark/benchmark_grade_v2.m:271-278`
把 `fields` 维度算成 `passfail(all(fieldResults.ok))`，而 `fieldResults` 同时容纳
数值比较和字符串精确比较；于是维度名 `mathematicalCorrectness` 会吞下拼写差异，
detail 文本甚至写成 `out of tolerance: state`——把一个枚举值说成"超出容差"。
后果有两头：枚举错会被当成"模型算错了"（低估契约问题、高估数值问题），
而数值全对又会被当成"交付没问题"（放宽契约）。v3 要同时堵住这两头。

## 2. 七个维度与派生来源

维度不是新算一遍判定，而是把已有的 v1 判定**按性质分流**。每条维度的 `sources`
字段就是它的出处，写进 JSON，可以逐条回查。

| 维度 | 来源字段 | 判的是什么 |
| --- | --- | --- |
| `numericalCorrectness` | `math.numericStatus` | 只判数值轴与域轴（`mas_grade` 的 numeric / domain 检查） |
| `enumContractValid` | `enums.status` + `math.enumStatus` | 声明的枚举词表 + 分类字段的精确字符串轴 |
| `engineeringVerdictCorrect` | `verdict.status` | 交付 verdict 对期望 verdict；**永不改写**（`verdictCoerced=false`） |
| `structuralSchemaValid` | `format.status` + `required.status` + `units.status` | profile / schema / taskId、必填字段、单位表 |
| `workflowCompleted` | `workflow.status` | 契约**声明了哪些**阶段、是否被记录 |
| `withinBudget` | `budget.status` | 记录到的用量对声明上限 |
| `deliveryValid` | 上面六维 + `reference.status` | 聚合，且带上独立参照守卫 |

聚合规则（`combine()`，`mas_delivery_check.m:692-712`）：全 `NOT_REQUIRED` → `NOT_REQUIRED`；
任一 `FAIL` → `FAIL`；否则有 `UNRECORDED`/`UNDETERMINED` → `UNDETERMINED`；再否则 `PASS`。
`detail` 会把每个来源连同其状态列出来（本轮改过一次，让 detail 带上来源名，
例如 `enumContractValid: enums.status PASS, math.enumStatus NOT_REQUIRED`），
这样读日志的人不需要回头翻代码就能知道某一维是谁贡献的。

### 2.1 分轴落在哪里

`check_math()`（`mas_delivery_check.m:373-528`）在遍历契约字段时按 `ref` 的类型分流：
字符串 `ref` 走 `kind='exact'`，累加 `enumBad`；数值 `ref` 走 `kind='numeric'`/`'domain'`，
交给 `mas_grade`。三条状态由此独立产生：

- `M.status`：v1 合并标签，行为与 Phase 5.6/5.7 完全一致（历史报告因此能原样重放）；
- `M.numericStatus`：只看 `mas_grade` 的结果与非有限/缺失的数值字段；
- `M.enumStatus`：只看精确字符串轴与声明的枚举词表。

关键点是 **`M.status` 不动**。分离只发生在新增的两个轴和由它们派生的维度上，
所以任何还在读 `math.status` 的历史工具拿到的东西和以前一模一样。

## 3. 两条禁令变成机器断言

重放脚本把"禁止枚举算数值错"和"禁止数值正确放宽契约"写成必须为真的条件，
不满足就 `pass=false`（`p58_scoring_v3_replay.m:89-105, 147-150`）：

| 禁令 | 断言 | 实测 |
| --- | --- | --- |
| 枚举错误计为数学计算错误 = false | 4 例 `v1Math=FAIL` 的行必须 `numericalCorrectness=PASS` 且 `enumContractValid=FAIL`，且 `enumBadFields` 非空、`numericBadFields` 为空 | 4/4 成立，`enumOnlyFailuresSeparated=true` |
| 数值正确不能救回契约 = false | `deliveryValidSealed=PASS` 的行在契约声明 4 个阶段后必须 `workflowCompleted=UNRECORDED`、`deliveryValid=UNDETERMINED`（**不是 PASS**），而数值轴仍 PASS | 5/5 成立，`workflowNotRelaxed=true` |
| 历史 v1 字段被改写 = false | 9 行 `v1Overall`/`v1Math` 与归档一致 + 10 个输入文件重放前后哈希相同 | 9/9、`inputsUnchanged=true` |
| 冻结阈值被修改 = false | 本轮无阈值文件改动 | `true` |

第二行是最容易被做反的一条：如果 v3 把"未记录 workflow"当成通过，
数值正确的交付就会自动变绿。这里刻意让它变 `UNDETERMINED`——
证据不足不等于被否定，但**也绝不是一次通过**（与 Phase 5.5 §4.1 的结论一致）。

## 4. v1/v2 兼容与差异测试

- **v1 输出字段全部保留原义**：`schema/format/required/enums/units/verdict/math/budget/reference/separation/overall/errors`
  一个字都没改语义；`dimensions` 与 `dimensionSchema`、`mapping` 是**追加**的
  （`mapping.compatibility` 里写明了这一点，`mapping.removed = {}`）。
- **`math.status` 保持合并**（`mapping.mathStatusKeptCombined = true`），`mapping.enumErrorsCountAsNumericalErrors = false`。
- **v2 维度到 v3 的映射**（重放 JSON 的 `mapping` 数组）：
  `fields` → `numericalCorrectness + enumContractValid`（拆分点），
  `verdict` → `engineeringVerdictCorrect`，`schema` → `structuralSchemaValid`，
  `route`/`tool` → `workflowCompleted`（仅在声明时），
  `executed`/`integrity` → `deliveryValid`，`budget` → `withinBudget`。
- **差异测试**：`test_delivery_check.m` §18–27 共 10 个用例逐条锁定分离语义——
  干净交付 7 维全 PASS、恰好 7 个维度、`numericalCorrectness` 必须来自 `math.numericStatus`、
  `deliveryValid.sources` 末位必须是 `reference.status`；分类拼写错 → 数值 PASS / 枚举 FAIL /
  交付 FAIL 而 **`overall` 仍是 v1 的 FAIL**；数字错 → 数值 FAIL / 枚举 PASS；
  预算超 → 预算 FAIL / 数值 PASS；缺 schema → 结构 FAIL / 数值 PASS；
  未声明 workflow → `NOT_REQUIRED`（不能凭空造一维）；
  ERROR 路径下 7 维必须报 `NOT_RUN`（不能让某维在没跑的情况下静默算通过）。
  全套 145/145 PASS。

## 5. 重放结果（9 份已封存结果，未改动任何输入）

| 臂 | 任务 | v1 math | numericalCorrectness | enumContractValid | verdict | structural | workflow(声明) | deliveryValid(封存契约) | deliveryValid(声明阶段) | 失败字段 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| R1 | P56-SIG-B | FAIL | PASS | FAIL | PASS | PASS | UNRECORDED | FAIL | FAIL | `state` |
| R1 | P56-ODE-N | FAIL | PASS | FAIL | PASS | PASS | UNRECORDED | FAIL | FAIL | `stiffnessClassified` |
| R1 | P56-SIG-F | FAIL | PASS | FAIL | PASS | PASS | UNRECORDED | FAIL | FAIL | `state` |
| R2 | P56-SIG-B | PASS | PASS | PASS | PASS | PASS | UNRECORDED | PASS | UNDETERMINED | — |
| R2 | P56-ODE-N | FAIL | PASS | FAIL | PASS | PASS | UNRECORDED | FAIL | FAIL | `stiffnessClassified` |
| R2 | P56-SIG-F | PASS | PASS | PASS | PASS | PASS | UNRECORDED | PASS | UNDETERMINED | — |
| R3 | P56-SIG-B | PASS | PASS | PASS | PASS | PASS | UNRECORDED | PASS | UNDETERMINED | — |
| R3 | P56-ODE-N | PASS | PASS | PASS | PASS | PASS | UNRECORDED | PASS | UNDETERMINED | — |
| R3 | P56-SIG-F | PASS | PASS | PASS | PASS | PASS | UNRECORDED | PASS | UNDETERMINED | — |

`budget` 维在 9 行里全为 `NOT_REQUIRED`（Phase 5.6 的契约没声明上限），因此它不参与聚合。
`workflowCompletedSealed` 同样全为 `NOT_REQUIRED`——原封存契约不要求阶段，
v3 没有替历史任务追加要求；`workflowCompletedStaged` 那一列是**另一次判定**：
用同一份结果、但把契约改成要求 4 个阶段（`skillSelected / referencesLoaded / mcpExecuted / checksRun`），
用来检验"数值正确救不回契约"这条禁令，不改写任何已归档结论。

计数：`nResults=9`，`v1Unchanged=9`，`mathFail=4`，`enumOnlyFail=4`，`numericalFail=0`，
`verdictCorrect=9`，`structuralValid=9`，`pass=true`。
输入 SHA-256 全部记录在 `scoring_v3_replay.json` 的 `inputsSha256`（10 个文件）。

## 6. v3 用在真实交付上（不是重放）

Task 3 的 Codex Desktop PID 闭环（`artifacts/phase58/closed-loop/codex_desktop_pid_acceptance.json`）
是 v3 维度第一次判一份**当场产生**的交付：

```
numericalCorrectness      PASS   math.numericStatus
enumContractValid         PASS   enums.status PASS, math.enumStatus NOT_REQUIRED
engineeringVerdictCorrect PASS   verdict.status
structuralSchemaValid     PASS   format.status PASS, required.status PASS, units.status PASS
workflowCompleted         PASS   5 stage(s) declared
withinBudget              PASS   budget.status
deliveryValid             PASS   reference.status NOT_REQUIRED
```

`workflowCompleted` 判的 5 个声明阶段是
`skillSelected / referencesLoaded / mcpExecuted / checksRun / repaired`，
它们不是客户端自述，而是 `p58_trace_evidence.m` 从 `events.jsonl` 的原始命令串与
MCP 调用项重建的：3 个 `SKILL.md`（orchestrator / runner / control-optimization）、
8 个 references 路径、26 次命令、按调用 id 去重后 8 次 MATLAB MCP 调用
（7 completed + 1 failed 后修复）、其中 3 次 `check_matlab_code`，
且全部路径分类为 `projectCopy`、用户级根读取 0 次。
`numericalCorrectness` 由独立复算背书——超调 4.9748%、调节时间 1.5049 s
与交付值到小数第 6 位一致。
`enumContractValid` 记 `enums.status PASS, math.enumStatus NOT_REQUIRED`：
这份交付声明的枚举词表合法，但没有字符串精确比较轴，所以那一半不参与判定。

## 7. 限制与未做的事

- **这不是新的测量**：样本仍是 Phase 5.6 的 9 份结果，`claimLimit` 字段写明
  不是新实验、不是 Skill 效应、也不作为客户端安装证据。触发率结论请回到
  `docs/PHASE5_8_CLIENT_EVIDENCE_ZH.md`。
- **枚举样本只有 2 个字段名**（`state`、`stiffnessClassified`），来自 3 个任务。
  v3 能区分这两类错，但"词表不匹配在真实使用中的发生率"仍未测量。
- **没有新增 JSON Schema 文件**。`schemas/` 下仍只有 `mas-result-2.schema.json` 与
  `acceptance-report.schema.json`；v3 的维度契约由 MATLAB 侧的 `mapping` 结构表达。
  如果外部工具要严格校验维度枚举，需要另开一轮。
- **`UNRECORDED` 与 `UNDETERMINED` 分开**：前者是"该记的没记"，后者是"记了但判不出"。
  两者都不算通过，但在聚合里都只降级到 `UNDETERMINED`，不会误判成 FAIL。
- **没改 `mas_grade`**：数值的唯一裁判仍是 `mas_grade`（含 NaN/Inf 与非有限值处理），
  `mas_delivery_check` 只做分流，不重新实现任何数值比较。
- **没动历史失败记录**：Phase 5.7 的 4 例不达标原文保留在新文档的叙述里，
  v1/v2 的归档文件只读；本轮没有出现"把 FAIL 改成 PASS"或删行。
- **没做第十个 Skill、没做大型仿真、没调用未授权付费模型。**

## 8. 下一轮如果要继续

1. 让 benchmark 的 scoring 文件直接声明 `enums`，这样 `enumContractValid` 能判词表本身而不只判拼写；
2. 把 v3 维度写入 `schemas/`，供外部读者校验；
3. 在真实客户端 episode 上积累枚举类失败样本，检验词表不匹配的实际发生率——
   这些都需要先有 Task 5 的隔离环境，因此被本轮的授权边界挡住。
