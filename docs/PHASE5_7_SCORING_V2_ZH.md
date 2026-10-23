# Phase 5.7 · 版本化评分协议 v2（Task 3）

日期：2026-10-23　文件：`benchmark/benchmark_grade_v2.m`
Schema：`mas-benchmark-grade/2`　评分声明：`benchmark/scoring_p56_retro.json`

## 1. 为什么需要 v2

v1（`benchmark/benchmark_grade.m`，schema `mas-benchmark-grade/1`）规定：

```matlab
row.pass = row.routeOk && row.toolOk && row.verdictOk && fieldsOk;
```

Phase 5.6 的三个 prompt **既没有要求路由，也没有要求申报工具**；R1 工作区更是
没有 Skill（3 文件、0 `.m`）。于是 v1 对三臂都给出 0/3。这不是三臂都失败，而是
**判据不适配**。Phase 5.6 当时如实保留了这个 0/3，没有回改。

v2 的原则：

1. **只在任务确实要求时评分**。任务没要求路由，就不拿 routeOk 当门槛；R1 没有
   Skill，就不能暗中要求它调用一个不存在的 Skill。
2. **适用但没有记录 ≠ 通过**。要求了路由/工具，结果里却没有证据 → `UNRECORDED`
   → 整题 `UNDETERMINED`，绝不折算成 PASS。
3. **N/A 不进分母**。`NOT_REQUIRED`、`NOT_APPLICABLE_ARM` 单独计数并披露。
4. **缺失不是失败**。没有结果文件 → `MISSING`，不进入 false reject。
5. **旧结果只读**。v1 评分器与 `grade_R*.json` 只做哈希对照，v2 不覆盖。

## 2. 六个独立维度（规格指定的名称与顺序）

`G.dimensions` 与每行的 `row.required` 使用下列六个名称，逐题、按域、按任务类型分别报告：

| # | 维度 | 由什么构成 | FAIL 的例子 |
| --- | --- | --- | --- |
| 1 | `mathematicalCorrectness` | 答案声明的字段按 `exact/abs/rel/maxabsdiff/min/max` 比较 | 任一字段超出容差、或结果缺少已声明字段 |
| 2 | `engineeringVerdictCorrect` | 期望 verdict vs 交付 verdict | 期望 `FAIL`，实际 `PASS` |
| 3 | `outputSchemaValid` | 版本化形状、`taskId` 身份、合法枚举、`fields` 为对象 | verdict 写成 `MAYBE`；profile 2 缺 `schema`/`taskId` |
| 4 | `workflowCompliance` | `executed` + `route` + `tool`，后两者按适用性 | 应路由到 `skill-x`，实际 `skill-y`；要求了工具却无记录 |
| 5 | `withinBudget` | 评分文件声明的 `maxToolCalls`/`maxWallSeconds` 与结果记录 | `toolCalls 12 > 5`；声明了预算但结果没记用量 |
| 6 | `deliveryValid` | 结果存在且可读、无 false accept、runner 未报 ERROR | 期望 FAIL 却报 PASS；结果文件缺失 |

内部细项 `row.dims`（`executed`、`route`、`tool`、`verdict`、`fields`、`schema`、
`budget`、`integrity`）保留，用于说明某个维度由哪条细项驱动；
`G.detailDimensions` 是这些细项的聚合。

整题状态与优先级：

```
MISSING         → 没有结果文件（六个维度全记 MISSING）
ERROR           → 结果不可读或 runner 报错
FAIL            → 任一维度 FAIL（确定的失败优先于证据缺口）
UNDETERMINED    → 没有 FAIL，但任一适用维度 UNRECORDED
PASS            → 其余
```

`FAIL` 优先于 `UNRECORDED` 是有意为之：一个答案已经被证明算错，不会因为
另一项证据缺失就变成"无法判断"。`UNRECORDED` 只阻止把**未知**写成 PASS。

Schema profile 由评分文件声明：`mas-result/1-legacy`（Phase 5.6 形状，无
`schema`/`taskId`，文件名承载任务身份）或 `mas-result/2`（要求
`schema="mas-result/2"` 且 `taskId` 与任务一致）。两种情况都要求 verdict 属于
`PASS/FAIL/UNDETERMINED/UNKNOWN`，且任务声明了字段时结果必须带 `fields` 对象。

预算同样由评分文件声明：

```json
"budget": { "required": true, "maxToolCalls": 8, "maxWallSeconds": 120 }
```

未声明 → `NOT_REQUIRED`；声明了但结果没有用量 → `UNRECORDED`；
超限 → `FAIL`。Phase 5.6 从未记录工具调用预算，因此回顾重放中该维度为
`NOT_REQUIRED`，不虚增也不虚减历史结果。

## 3. 适用性判定（在跑任务前声明）

评分文件必须显式声明：

```json
"arms": {
  "R1": { "hasSkills": false, "hasTools": false, "reason": "..." },
  "R2": { "hasSkills": false, "hasTools": false, "reason": "..." },
  "R3": { "hasSkills": true,  "hasTools": true,  "reason": "..." }
},
"tasks": {
  "P56-SIG-B": { "routeRequired": false, "toolRequired": false, "routeReason": "...", "toolReason": "..." }
}
```

生效规则：

| 任务要求 | 臂能力 | route 维度 |
| --- | --- | --- |
| 否 | 任意 | `NOT_REQUIRED`，不进分母 |
| 是 | 无 Skills | `NOT_APPLICABLE_ARM`，不进分母，并写明"缺失的能力不能被要求" |
| 是 | 有 Skills | 有记录 → PASS/FAIL；无记录 → `UNRECORDED` → 整题 `UNDETERMINED` |

工具维度同理。`requireArmDeclaration=true` 时，未声明的臂直接报错，不允许悄悄用默认值。

**先声明、后运行。** 任何在看过结果后才添加的 `routeRequired` 都属于事后加码，不能
用于新任务；本轮的 `scoring_p56_retro.json` 是**回顾性重放**，标签已写明。

## 4. Phase 5.6 回顾性重放（不是新实验）

命令：

```matlab
addpath('matlab/validation/phase57'); p57_grade_v2_replay();
```

输出：`artifacts/phase57/grading/replay_R{1,2,3}.json`、`replay_summary.json`。

| 臂 | v1 pass | v2 pass | v2 失败 | 失败原因 |
| --- | ---: | ---: | ---: | --- |
| R1 | 0/3 | 0/3 | 3 | `state` 写成 `neither`/`REFUTE`，`stiffnessClassified` 写成 `non-stiff` |
| R2 | 0/3 | 2/3 | 1 | ODE 的 `stiffnessClassified` 写成 `non-stiff`（期望 `nonstiff`） |
| R3 | 0/3 | 3/3 | 0 | — |

- route/tool 在三臂均为 `NOT_REQUIRED`（3 条），因为 Phase 5.6 的 prompt 没要求；
  这不是 v2"放过"了它们，而是原任务本就没有这项交付。对应地，
  `workflowCompliance` 在九格中全部为 PASS（只由 `executed` 决定）。
- schema profile 取 `mas-result/1-legacy`：Phase 5.6 的结果没有版本化 schema，
  这是当时的事实，不是本轮的失败；`outputSchemaValid` 只按当时声明的形状检查。
- budget 未声明 → `withinBudget` 九格全为 `NOT_REQUIRED`；不把"没记预算"
  写成"遵守预算"。
- v2 的 0/2/3 与 Phase 5.6 自己记录的 `correctnessPass` **完全一致**，说明 v2
  没有改变事实，只修正了判据。
- 三臂 verdict 全对；差异在**枚举词表**，与 Phase 5.6 的结论相同。
- `replay_summary.json` 中 `inputsAndV1Unchanged=true`，v1 评分器与三个 v1 评分文件
  的哈希在重放前后相同。

**不能从这个表得出**：Skill 有因果增益、R3 优于 R1 的效应量、或 2/3 与 3/3 的
统计显著性。样本是 3 个任务、每格一个主结果，部分臂有重复；强隔离仍 BLOCKED。

## 5. 新任务的使用方式

1. 先写任务与 `scoring_<phase>.json`，声明每个任务的 `routeRequired`/`toolRequired`、
   `schemaProfile`、`budget`，以及每臂的 `hasSkills`/`hasTools`；
2. 封存答案哈希后再跑；
3. 用 `benchmark_grade_v2` 评分，输出 schema v2；
4. 与 v1 结果**分目录、分表**记录；不得把 v2 的数字写回 v1 报告。

## 6. 回归

`benchmark/tests/test_grade_v2.m` **60/60**，覆盖：不要求路由、要求且记录、
要求但未记录、臂无 Skills、缺失结果、false accept、错误字段、非法枚举、
预算合规/超限/未声明、六维名称与聚合、FAIL 优先于 UNRECORDED、哈希篡改、
错误 schema、未声明臂、v1 字节不变、回顾文件可解析。

```matlab
addpath('benchmark/tests'); test_grade_v2(true);
```
