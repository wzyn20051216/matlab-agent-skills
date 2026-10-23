# Phase 5.6 Task 4.2：ODE 误差字段定义契约（H54-ODE-N 修复前后）

范围：只消除字段歧义。不改冻结答案，不调容差，不删断言，不改历史评分器。
`skills/matlab-data-analysis/` 与 `matlab-agent-skills` 之外的文件未触碰。

## 1. 缺陷证据（历史，只读）

Phase 5.5 冻结episode `R3/H54-ODE-N`（`artifacts/phase55/episodes/episodes_v3.json` seq 5）：

| 项 | 值 |
|---|---|
| 任务 | `y'=[y2;-y1]`, `tspan=[0,2π]`, `y0=[1;0]`, `relTol 1e-9 / absTol 1e-11` |
| `verdict` | PASS（与期望一致，`verdictOk = true`） |
| 字段 `error.maxScaled` | 判 **MISS**：`2.66239 <= 1e-08 + 0` |
| 其余字段 | `invariant.maxRelDrift 6.55e-10` OK，`stiffness.classified nonstiff` OK |
| `fieldsPass / fieldsTotal` | 2 / 3 → `taskPass = false` |

同一 episode 自己写出的 `result.json`（`MATLAB-bench-phase55-v3/R3/H54-ODE-N/result.json`）里
**两个数都算对了**，只是名字用错了：

```
error_maxAbs            = 3.275087e-10
error_scaled_relTol1e-8 = 3.2751e-10      % 除以 max(1, max|yRef|) —— 幅值约定
error_maxScaled         = 2.662392        % 除以 AbsTol+RelTol*|yRef| —— 求解器约定
```

Agent 把求解器约定填进了 `error_maxScaled` 这个键名，而答案键的 `1e-8` 判据是幅值约定。
2.66 与 3.3e-10 相差 8 个数量级，两者都"正确"，**只有一个字段名在说谎**。
更糟的是该除数在 `t=2π` 处 `|yRef|≈2.4e-16`，分母退化成 `AbsTol=1e-11`，
于是零交叉点附近的相对量必然被放大——这正是字段契约要禁止的"分母塌缩"。

历史结论保持不变：该 episode 仍记 `fieldsPass 2/3`、`taskPass false`。本文件不重算历史。

## 2. 字段审计（按 spec 的七项逐条）

| 审计项 | 修复前 | 修复后（`mas-ode-report/2`） |
|---|---|---|
| 误差分子 | 隐含在 `maxAbs`，未声明 | `numeratorRule = 'max \|y_candidate - y_reference\| over every state row and component'` |
| 归一化分母 | `maxScaled` 一个名字覆盖三种分母 | 三个独立名字 + 三条 rule：`maxScaled`（`max(1, max\|y_ref\|)`）、`maxSolverScaled`（`AbsTol + RelTol*|y_ref|` 逐元素）、`maxRel`（`max(|y_ref|, eps)` 逐元素） |
| 单位 | 未声明 | `unit = 'fraction of solution magnitude (dimensionless)'`；`solverScaledUnit = 'multiple of solver-tolerance (dimensionless)'` |
| 时间采样点 | `at` 取 `maxRel` 的 argmax，与 `maxAbs` 的 argmax 可能不同点 | `at` 明确取**分子 argmax 所在时刻**，与 `numeratorRule` 一致 |
| 多维聚合 | 未声明 | `rows` / `components` + `max(...)` 聚合规则；不变量另有 `aggregation = 'N samples x M component(s), max'` |
| 零参考值 | `maxRel` 用 `eps` 兜底但没写明；`maxScaled` 分母兜底在 1 | 兜底写进 rule 字符串；`maxSolverScaled` 的分母含 `AbsTol` 项，因此 \|y_ref\|→0 时不塌缩，且文档明确它是求解器诊断量、不是精度判据 |
| NaN/Inf | 候选非有限时提前 return，`r.error` **整个字段不存在**；无参考时只给 3 个字段 | 所有出口都产出同一字段集，缺证据者为 `NaN` 且带 `status` 说明；`r.schema` 在任何返回路径（含 FAIL 早退）都存在 |

## 3. 最小修改

只改 `skills/matlab-data-analysis/scripts/mas_ode_check.m`：

1. `r.schema = 'mas-ode-report/2'`，在候选非有限的早退路径之前赋值；
2. 新增局部构造器 `local_error_block(dAbs, yRef, tq, refTol, relTol, absTol)`，三个调用点
   （有参考 / 有终值断言但无参考 / 既无参考也无断言）与早退路径共用同一字段集；
3. `relTol`、`absTol`、`refTol` 上提到候选生成之前读取——候选由调用方提供时同样需要求解器约定分母；
4. `r.invariant` 增加 `numeratorRule` / `denominatorRule` / `unit` / `aggregation`；
5. 函数头注释块与 `SKILL.md`、`references/data-verification-contract.md` 同步（R2/R3 臂读的就是这三处）。

向后兼容是硬约束：**`error.maxScaled = maxAbs / scale` 的数值一个比特都没变**，
`error.maxAbs`、`error.maxRel`、`error.scale`、`error.tolRel` 全部原样保留，
新增项只加名字不改语义。因此旧冻结答案仍按原约定判分。

## 4. 修复前后测试（新契约单独运行，旧结果保留）

新建 `skills/matlab-data-analysis/tests/test_ode_field_contract.m`，14 例，期望值全部由
`4·exp(-t)` 手工算出、不从被测工具回读；误差注入在 `t=0.5`（`δ=1e-9`），使三种缩放
两两可区分。已在 `matlab/validation/phase4/run_all.m` 注册为 `odeFieldContract`。

| 运行 | 结果 |
|---|---|
| 修复前（工具未改） | **5 / 14** —— `schema NONE`；`maxSolverScaled / at / component / rows / components / numeratorRule / unit` 全部 `MATLAB:nonExistentField`；NaN 候选 `r.error` 缺失 |
| 修复后 | **14 / 14**（`artifacts/phase56/ode_field_contract_after.log`） |
| 回归 `test_ode_contract.m` | 56 / 56（不变） |
| 回归 `test_data_contract.m` | 118 / 118（不变） |
| 回归 `test_capability.m` / `test_refcheck.m` | 7 / 7、11 / 11（能力矩阵与参考清单同步后仍绿） |
| 兼容性断言（在 14 例内） | `maxScaled == maxAbs/scale` 逐比特一致；H54-ODE-N 冻结夹具（振子 + 能量不变量 + 终值）仍 **PASS** |

修复过程中我自己写错过两例并被测出来，属于测试缺陷而非工具缺陷，已改正并留在此处：
`fd_nan` 的候选时间写成 `(0:2).'`（=0,1,2）越出 `tspan=[0,1]`，触发 `mas_ode_check:candidate`；
`fd_invDrift` 用 `y` 本身当"不变量"，而 `y'=-y` 的解本就衰减（漂移 0.632 而非 2.5e-8），
改用真正的守恒量 `y·e^t`。另有一处规则字符串断言按测试内部变量名 `yRef` 写，
而报告用的是面向读者的 `y_reference`——统一到报告词表，没有放松断言强度。

## 5. 这一条对通用判断的意义

字段名歧义不是 ODE 特有问题：任何"同一个键名承载两种约定"的报告都会让最强臂在
算术全对的情况下被判 MISS，而这恰好会被误读成"工具/模型没能力"。
Phase 5.6 的判断是：**凡是被评分键引用的可观测量，必须自带分子、分母、单位、
采样点与聚合方式**，让"引用一个数"和"声明它的定义"不可分离。
同一条原则在 Task 4.1 的统计侧体现为 `mas_stat_verdict` 把"证据不足"与"被否定"分成不同状态。

## 6. 未做 / 边界

- 没有把 H54-ODE-N 从 MISS 改成 PASS，也没有重跑它；历史 artifacts 目录只读。
- 没有新增第十个 Skill，没有新增大型 Buck/Boost 案例。
- `maxSolverScaled` 只作为诊断量输出，评分判据仍走 `refTolRel` 与幅值约定，未引入新的自动 PASS 通道。
- 未改动官方 MATLAB MCP Server、用户路径、系统 ACL。
