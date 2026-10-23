# Phase 5.7 · 工程判断与交付 Schema 的一致性（Task 6）

日期：2026-10-23
实现：`skills/matlab-testing-ci/scripts/mas_delivery_check.m`
版本化 Schema：`schemas/mas-result-2.schema.json`
真实数据审计：`matlab/validation/phase57/p57_delivery_audit.m`

## 1. 问题

Phase 5.6 的三臂都能给出正确 verdict 与数值，但 R1 的字段词表与答案契约不一致
（`state="neither"`、`"REFUTE"`、`stiffnessClassified="non-stiff"`），R2 的 ODE
任务同样在 `stiffnessClassified` 上不一致。历史评分只给了一个布尔量，读者无法
区分：

- **数字算错了**（工程判断错误）；
- **数字对、Schema/词表不符**（交付契约错误）；
- **数字对、格式也对，但 verdict 错**（判断错误）；
- **根本没有交付**（缺失）。

把三者压成一个布尔值，最危险的后果是有人为了"让它通过"去改 verdict 或改容差。
本轮不这样做：`mas_delivery_check` 永不改写结果，且格式与数学分别评分。

## 2. 版本化 Schema

`schemas/mas-result-2.schema.json`（`mas-result/2`）规定：

| 字段 | 要求 |
| --- | --- |
| `schema` | 固定为 `mas-result/2` |
| `taskId` | 非空，`^[A-Za-z0-9][A-Za-z0-9._-]*$` |
| `verdict` | `PASS` / `FAIL` / `UNDETERMINED` / `UNKNOWN` |
| `fields` | 对象；值可为数值、字符串、布尔或数组 |
| `units` | 契约声明了单位的字段，必须逐项给出单位字符串 |
| `budget` | 契约声明预算时必填：`toolCalls`、`wallSeconds` |
| `status` | `OK` / `ERROR`；`ERROR` 走结构化错误，不伪装成 verdict |

`UNKNOWN` 与 `UNDETERMINED` 是**合法状态**，不是 Schema 错误。它们表示"没有
做出判断"，与"判断错误"是两件事。

Phase 5.6 的结果没有版本化 Schema，使用 `mas-result/1-legacy` 档案：不要求
`schema`/`taskId`（文件名承载任务身份），但仍要求合法 verdict 与 `fields` 对象。
旧结果按旧档案重放，不补写、不改写。

## 3. 检查器输出

`R = mas_delivery_check(result, spec, ...)`，输出 schema `mas-delivery-check/1`：

```
format    版本化形状、taskId、verdict/fields 存在性
required  契约声明的必填字段是否齐全
enums     枚举值是否合法
units     单位是否存在且一致（未知单位是 warning，不是 failure）
verdict   期望 verdict vs 实际交付（永不改写）
math      调用 mas_grade 比较数值/域约束（不重复实现比较器）
budget    声明预算与记录用量
reference 可选：调用 mas_refcheck('verify', manifest) 校验冻结参考
separation 数值有效但格式错误 / 格式有效但数值错误 的独立提示
overall    FAIL > UNDETERMINED > PASS；ERROR 单独上报
```

两个关键约束：

1. **不修正 verdict 去满足 Schema。** 期望 `FAIL`、交付 `PASS` 时，输出
   `VERDICT_WRONG` 且 `verdictCoerced=false`。
2. **格式检查不替代工程计算。** `math` 一律委托 `mas_grade`；`reference` 一律委托
   `mas_refcheck`。`mas_delivery_check` 只做契约层编排。

`separation` 的两个标志是：

| 标志 | 含义 | 提示 |
| --- | --- | --- |
| `numericValidFormatInvalid` | 数值通过独立参考，但交付契约不合法 | 修格式，不要改数字 |
| `formatValidNumericInvalid` | 契约合法，但工程数值不达标 | 格式合规的错误答案仍然是错的 |

verdict 错误不属于这两个轴：它是独立维度，有自己的错误码。

## 4. 真实数据审计（Phase 5.6 九个存储结果）

命令：

```matlab
addpath('matlab/validation/phase57'); p57_delivery_audit();
```

输出：`artifacts/phase57/delivery/delivery_audit.json`。契约由封存答案在内存中
生成；结果、答案、任务文件在审计前后逐字节哈希一致。

| 臂 | 任务 | format | math | verdict | overall | separation |
| --- | --- | --- | --- | --- | --- | --- |
| R1 | P56-SIG-B | PASS | FAIL | PASS | FAIL | format-ok/math-bad |
| R1 | P56-ODE-N | PASS | FAIL | PASS | FAIL | format-ok/math-bad |
| R1 | P56-SIG-F | PASS | FAIL | PASS | FAIL | format-ok/math-bad |
| R2 | P56-SIG-B | PASS | PASS | PASS | PASS | — |
| R2 | P56-ODE-N | PASS | FAIL | PASS | FAIL | format-ok/math-bad |
| R2 | P56-SIG-F | PASS | PASS | PASS | PASS | — |
| R3 | P56-SIG-B | PASS | PASS | PASS | PASS | — |
| R3 | P56-ODE-N | PASS | PASS | PASS | PASS | — |
| R3 | P56-SIG-F | PASS | PASS | PASS | PASS | — |

结论：

- **9/9 交付形状合法**：三臂都写出了 `verdict` 与 `fields` 对象，没有 Schema 违规。
- **5/9 工程数值达标**：R1 0/3、R2 2/3、R3 3/3，与 v2 评分器逐题一致（9/9 一致），
  说明两套独立代码路径对同一批存储结果给出相同判断。
- **4 例"格式合规但数值错误"**：全部来自字段词表不一致（`neither`/`REFUTE`/
  `non-stiff`），不是计算错误，也不是 Schema 错误。这正是 Phase 5.6 的核心事实，
  在这里被单独标出，而不是折算成 PASS。
- **0 例"数值正确但格式错误"**：本批历史结果使用 legacy 档案，没有版本化 Schema，
  因此这个组合只能在夹具测试中出现（`test_delivery_check` 明确覆盖）。
- **0 次 verdict 改写**：三臂交付的 verdict 与期望完全一致，检查器没有修改任何文件。

## 5. 能力边界

- 该检查器**不能**证明算出的数字来自真实执行；它只比较交付字段与独立参考。
- `mas-result/2` 是交付契约，不是"通过标准"；通过与否仍由工程参考与预算决定。
- 单位检查只比对字符串，不做量纲换算。契约写 `V`、结果写 `mV` 会失败，
  这是有意为之：静默换算会让单位错误不可见。
- `reference` 维度只在显式传入冻结 manifest 时启用；未传入时是 `NOT_REQUIRED`，
  不冒充"参考已验证"。
- 历史结果中的 4 例失败**保留原样**，不修改结果文件、不修改 Phase 5.6 报告。

## 6. 回归

`skills/matlab-testing-ci/tests/test_delivery_check.m` **93/93**：

- 合法交付；错误 verdict 不被改写；正确数字 + 非法 Schema 的分离提示；
- 必填字段缺失；非有限值（NaN）→ UNDETERMINED；
- `UNKNOWN`/`UNDETERMINED` 合法；合法但不同的 verdict 仍判 FAIL；
- 非法枚举；单位不符 / 未知单位（warning）；超容差数值；
- 预算超限 / 未记录 / 未声明；不可读结果；缺失结果；
- legacy 档案无法证明单位一致性时记 `UNRECORDED`；
- 未知 profile；taskId 不符；精确字符串不符；
- 篡改冻结 manifest → `REFERENCE_MISMATCH`，且不影响数学维度；
- `schemas/mas-result-2.schema.json` 的枚举与必填字段和检查器一致。

```matlab
addpath('skills/matlab-testing-ci/tests'); test_delivery_check(true);
```
