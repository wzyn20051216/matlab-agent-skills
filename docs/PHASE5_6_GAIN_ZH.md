# Phase 5.6 三臂对照结果与原生触发证据（Task 2 / 3 / 6）

本轮不再加工具，只回答一件事：**同模型、同任务下，把 Skill 暴露给 Agent 到底有没有可验证的增益。**
协议在运行之前写成并纳入提交（[PHASE5_6_PROTOCOL_ZH.md](PHASE5_6_PROTOCOL_ZH.md)），本文只报告结果，
不追认任何事后判据。

## 0. 一句话结论

**有增益，但增益的位置和多数人以为的不同。** 三个任务的**数值判断三臂全对**（verdict 各 3/3，
所有数值字段在容差内），臂间差异**全部落在输出契约词汇上**：`state` 五态枚举和
`stiffnessClassified` 枚举拼写。R1（无 Skill）0/3、R2（仅文档）2/3、R3（文档+工具）3/3。
原生 Skill 触发：**未证实**（12 条 episode 的 transcript 中 `tool_use name="Skill"` 出现 0 次）。

## 1. 前提：隔离仍然是 BLOCKED

强隔离在本机做不到（[PHASE5_6_ISOLATION_ZH.md](PHASE5_6_ISOLATION_ZH.md)：11/11 对抗向量全部达到）。
本实验的可信度来自三件可核查的事，而不是访问控制：

| 机制 | 本轮事实 |
|---|---|
| 两阶段封存 | 最后一集结束于 `2026-10-22 13:22:43`（本地时间，取自持久化 transcript），封存时间 `21:30:25` 在其之后；`answers.json` 在封存之前不存在，封存前 absence scan 复扫 315 个手臂文件干净 |
| 承诺哈希 | `reference_p56.m` = `8c85a00c…3fc9`，与公布时登记值一致（`generator hash matches commitment: 1`） |
| 逐调用账本 | 每条 episode 的工具序列取自持久化 transcript，不是子代理自述 |

封存产物：`tasks_frozen.json` sha256 `6b528da1c6…429d4b`，`answers.json` sha256 `5397be4bf0…34fd2c`。

本轮还堵上了一个**此前没意识到的通道**：所有 episode 共用同一个 MATLAB 会话，`addpath`/`cd`/变量会跨集残留。
探针后实测到 4 个 benchmark/skill 路径条目存活、`which('mas_ber_check')` 指向仓库脚本、MCP 帧残留 82 个变量、
`pwd` 停在手臂目录里（Windows 下还会把目录锁死）。这条通道**不打开任何文件**，因此纯文件账本看不见它。
对策：每集前执行 `p56_session_reset` + `clear`，并让账本扫描**实际发给会话的 MATLAB 代码文本**。
正式轮 9 集：重置 12/12 成功、移除 4 个残留路径条目、R1/R2 的 `mas_*` 符号命中 **0**。

## 2. 执行事实

| 项 | 值 |
|---|---|
| 设计 | 3 任务 × 3 臂 × 3 重复 = 27 |
| 实际 | **9 集正式**（3×3×1）+ 3 集探针（`EXPLORATORY`，不计配对） |
| 缺口 | 未达 27。按协议"额度/环境不允许就保留已完成数据并停止，不强行凑数量"，**不强行完成数量目标**，不对外推 |
| 模型 | 12 集客户端别名全部 `qfmodel`；`message.model` 同值。客户端不暴露厂商模型名 → 别名一致 ≠ 模型名可比 |
| 预算 | 每集 ≤ 25 次工具调用；实际最大 18 → `withinBudget` 9/9 |
| 作废 | `answerLeak` 0、`crossArmRead` 0、`armBlindnessBroken` 0、`graderPathRead` 0 → `INVALID_FOR_COMPARISON` **0 集** |
| 结构观察 | 正式轮 9 集 `evalSidePathTouches` = 0；探针轮 R1 有 3 次（列目录名，未见内容），按协议不作废、只披露 |

三臂工作区实测：R1 3 文件（0 个 `.m`、无 SKILL.md）／R2 23 文件（21 个 `.md`、0 个 `.m`）／R3 79 文件（54 个 `mas_*.m`）。

## 3. 四项标签（不合并成一个"通过率"）

| 臂 | `correctnessPass` | `withinBudget` | `taskCompleted` | `deliveryValid` | verdict 正确 | UNDETERMINED 检出 | false accept / reject |
|---|---|---|---|---|---|---|---|
| R1 | **0/3** | 3/3 | 3/3 | 3/3 | 3/3 | 1/1 | 0 / 0 |
| R2 | **2/3** | 3/3 | 3/3 | 3/3 | 3/3 | 1/1 | 0 / 0 |
| R3 | **3/3** | 3/3 | 3/3 | 3/3 | 3/3 | 1/1 | 0 / 0 |

`correctnessPass` = verdict 对 **且** 全部声明字段过（协议 §3）。判据缺失按协议记 `false`，不记 `true`。

### 3.1 差异到底在哪：逐字段

| 任务 | 臂 | verdict | 数值字段 | 未过字段 | 实际写法 |
|---|---|---|---|---|---|
| P56-SIG-B | R1 | UNDETERMINED ✓ | Wilson 上界 err 2.6e-12、期望事件 err 4.3e-05 ✓ | `state` | `neither` |
| P56-SIG-B | R2 / R3 | UNDETERMINED ✓ | 同上 ✓ | — | `insufficient-sample` |
| P56-SIG-F | R1 | FAIL ✓ | z err 3.4e-05、期望事件 err 3.2e-04 ✓ | `state` | `REFUTE` |
| P56-SIG-F | R2 / R3 | FAIL ✓ | 同上 ✓ | — | `sufficient-refutation` |
| P56-ODE-N | R1 / R2 | PASS ✓ | maxScaled 3.7e-9/4.8e-9、solverMaxScaled 4.359、drift 6.7e-9 全 ✓ | `stiffnessClassified` | `non-stiff` |
| P56-ODE-N | R3 | PASS ✓ | 同上 ✓ | — | `nonstiff` |

三点必须写清：

1. **R1 不是算错了。** 它每个数值都在容差内，误差量级与 R3 相同。它输在**词表**：自己发明了 `neither` / `REFUTE`。
2. **文档能传词表，传不动枚举拼写。** R2 读了 `SKILL.md`/`references` 就拿到了五态 `state`（Phase 5.4/5.5 把词表写进文档的收效），
   但 `stiffnessClassified` 仍写成 `non-stiff` —— 只有 `mas_ode_check` 的输出会强制 `nonstiff`。
   也就是说：**这一格的增益来自封装，不来自知识。**
3. 我没有为了让 R1/R2 好看而放宽 `exact` 匹配，也没有为了让 R3 好看而把 `pass` 当 `correctnessPass`。

### 3.2 评分器的 `pass` 与 `correctnessPass` 不是一回事

`benchmark_grade` 的 `pass` 还要求 `routeOk` 与 `toolOk`。本轮公布的提示**故意不含路由**，且从未要求手臂申报
skill/tool 名，所以三臂 `pass` 都是 **0/3**。这是判据不适配，不是手臂失败；本文一律用 `correctnessPass`，
并把 `route/tool = 0/3` 原样写在这里，不隐藏。

## 4. 成本与恢复

| 臂 | 工具调用合计 | MATLAB 求值次数 | 墙钟合计 | 均值 |
|---|---|---|---|---|
| R1 | 29 | 13 | 524.7 s | 8–11 次/集 |
| R2 | 47 | 21 | 734.5 s | 12–18 次/集 |
| R3 | 47 | 17 | 530.7 s | 14–18 次/集 |

- 错误恢复：正式轮只有 1 次工具层报错——R1 的 P56-SIG-F 调用了不存在的 `mcp__matlab__evaluate_matlab_code`
  （正确名是 `mcp__matlab_official__…`）。该集随后在预算内完成、交付完整、verdict 正确。
  两种口径分开写，不取更好看的那个：按"报错后仍完成"计 **1/1 恢复**；按 `statistics.json` 的
  `errorsRecovered` 口径（要求 `correctnessPass`）该集 `correctnessPass=false`，所以记 **0**。
  单次事件不足以估计恢复率。
- token 不可观测（episode 账本无 token 字段），只能用调用数与墙钟代理，这是协议 §6 预先声明的缺口。
- 回答 Task F：**成本可接受**。9 集最长 290 s，全部在 25 次预算内；最贵的一集（R2 SIG-F，18 次调用）也没有超预算。

## 5. 配对结果与统计口径

只用同任务、同重复配对（协议 §4）：

| 任务 | R1 | R2 | R3 | R3−R1 | R3−R2 |
|---|---|---|---|---|---|
| P56-ODE-N | ✗ | ✗ | ✓ | +1 | +1 |
| P56-SIG-B | ✗ | ✓ | ✓ | +1 | 0 |
| P56-SIG-F | ✗ | ✓ | ✓ | +1 | 0 |

配对格 3/3，`R3−R1` 差值分布 `{+1: 3}`，**平局 0/3**。但 n=1 重复：
按协议，**数据不完整时只给原始计数 + 缺口说明，不给置信区间和效应量**。

逐条自查禁用项：非配对相对提升 ✗ 未计算；混合模型当同模型 ✗（0 集异模型）；重复当独立样本 ✗（n 仍记 3 格）；
未运行记 PASS ✗（缺失字段显式列出）；单任务写成产品提升百分比 ✗；统计不显著解释为无效果 ✗（本轮根本不做显著性断言）；
预算违规隐藏成本 ✗（本轮 0 违规，若有时保留 `withinBudget=false`）。

**结论强度**：支持"同模型同任务三臂观测差异 + 成本"；**不**支持"差异由 Skill 暴露因果导致"——暴露未被强制
（历史留出集答案键在本机可读，R1 也能用绝对路径拿到 `mas_*.m`）。

## 6. 原生 Skill 自动触发 L1–L4（Task 3）

证据文件：`artifacts/phase56/episodes/trigger_evidence.json`（由 transcript 直接生成，非人工填写）。

| 级 | 判据 | 本轮判定 |
|---|---|---|
| L1 可发现 | episode 上下文里是否注入 Skills 列表 | **NOT EVIDENCED**：12/12 条子代理 transcript 均无 skills listing；9 个 `matlab-*` 只在**编排会话**可见 |
| L2 自主读取 | 账本中出现读 `SKILL.md`/`references`/`mas_*.m` 的调用 | **EVIDENCED（仅 R2/R3）**：R1 0、R2 3、R3 4 集有文件读取。**这是文件访问，不是触发** |
| L3 原生机制调用 | `tool_use name="Skill"` | **NOT EVIDENCED**：0/12。没有补造，也没有把 Read 冒充成触发 |
| L4 执行并被独立验收 | `mas_*` 真的被调用且评分器对封存答案判对 | **EVIDENCED（仅 R3）**：4 集执行代码里出现 `mas_ber_check` / `mas_ode_check`；R1/R2 为 0 |

提示纯度核查（防止"暗中把 Skill 名写进 Prompt 制造触发"）：**12 集首条用户提示中，出现 Skill 名 = 0 集，出现 `mas_` = 0 集**。

### 6.1 客户端支持范围

| 客户端 | 本轮范围 | 依据 |
|---|---|---|
| Qoder（子代理 episode） | L2/L4 可证，**L3 未证实**；L1 在 episode 上下文未证实 | 本轮 12 集，`entrypoint: cli`，客户端 1.1.69 |
| Qoder（主会话） | 9 个 Skill 在列表中可见，`Skill` 工具可被显式调用 | 编排会话上下文 |
| Codex CLI | **本轮未运行 episode**；历史为发现 9/9、工作流 BLOCKED | `docs/SUPPORT_MATRIX_ZH.md`、`RELEASE_NOTES_WINDOWS_BETA_ZH.md`（`codex-cli 0.147.0`） |
| Codex Desktop | **本轮未运行 episode**；历史为引擎发现 9/9、自主执行 NOT VERIFIED（无可程序化 UI 通道 + 网络不可达） | 同上，`docs/WINDOWS_BETA_ZH.md` |

没有为 Codex 两个客户端补造任何触发事件。

### 6.2 用户级 / 项目级优先级（实测，只读）

`artifacts/phase56/skills_install_audit.json`：

| 根 | 存在 | 安装 | 与仓库一致 | 分歧 | `mas_*.m` 脚本数 |
|---|---|---|---|---|---|
| `<home>\.qoder-cn\skills` | 是 | 7/9 | **0** | 7 | 26 |
| `<home>\.workbuddy\skills` | 是 | 9/9 | **0** | 9 | 30 |
| 项目级 `<repo>\.qoder\skills` | **不存在** | 0/9 | — | — | — |
| 仓库 `skills/` | 是 | 9/9 | 9 | 0 | 54 |

由此得出一条必须说出的限制：**真实会话里加载的 SKILL.md 不是仓库当前文本**，而且同名 Skill 同时存在于**两个用户级根**、
内容彼此不同（`matlab-orchestrator`/`matlab-simulink-modeling` 只在 `.workbuddy` 根有）。
所以"Skills 已安装可用"和"Agent 看到的就是仓库里的 Skill"是两个命题，本轮只有后者成立。
本轮**没有写入、改名或删除任何安装目录**（协议禁止），清理动作列为 Phase 5.7 待办并需要人工确认。

对本实验无影响：R2/R3 由 `p56_stage.m` 从仓库树暂存，不来自安装根。

## 7. 本轮已知不能回答的问题

1. 强隔离下的因果增益：BLOCKED。
2. 厂商模型名：只拿到别名 `qfmodel`。
3. token 成本：不可观测。
4. n=1 重复：3 格配对只能给原始计数，给不了区间。
5. Codex CLI / Desktop 的 L3：本轮未运行。

## 8. 证据索引

- `artifacts/phase56/episodes/episodes.json`（12 集，四项标签与逐集 leak 判定）
- `artifacts/phase56/episodes/probe_ledger.json`（schema `/2`，逐调用工具账本 + MATLAB 代码扫描）
- `artifacts/phase56/episodes/trigger_evidence.json`（L1–L4 与提示纯度）
- `artifacts/phase56/episodes/statistics.json`（配对表、成本、缺口、警告）
- `artifacts/phase56/episodes/session_reset.jsonl`（每集 1 行重置审计）
- `artifacts/phase56/episodes/{exploratory,pass1}/`（12 份手臂交付原文）
- `<repo>-bench-phase56\eval\`（`episodes.json` 封存输入、`answers.json`、`tasks_frozen.json`、
  `manifest.json`、`seal_manifest.json`、`absence_report.json`、`grade_R{1,2,3}.json`、`arm_R{1,2,3}/`）
- 工具：`matlab/validation/phase56/p56_{episode_ledger,stats,session_reset,absence_scan,stage}.m/.py`
