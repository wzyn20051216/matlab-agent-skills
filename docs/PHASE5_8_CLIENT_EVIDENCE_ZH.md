# Phase 5.8 · 客户端加载证据与真实闭环验收

日期：2026-10-23
分支：`phase5.1-audit`
范围：Task 2（各客户端 L1–L4 原生调用证据）与 Task 3（最小真实工程闭环）
机器可读证据：`artifacts/phase58/native/client_evidence.json`、
`artifacts/phase58/closed-loop/codex_desktop_pid_acceptance.json`

## 0. 结论先行

| 问题 | 结论 |
| --- | --- |
| 客户端能否发现仓库里的 9 个 Skill | **能**：Codex CLI 0.147.0 与 Codex Desktop 引擎 0.163.0-alpha.11.1 在隔离项目里 `skills/list` 均返回 9/9，且 `hashesMatchRepo=true` |
| 客户端是否真的读了安装副本 | **是（Codex Desktop）**：A/B/C 三个 episode 的 `SKILL.md` 读取全部落在隔离副本内，`projectScoped=true`，用户级根读取 0 次 |
| 是否证明了"原生 Skill 触发" | **没有**：Codex 事件流没有 Skill 类型的 item，只有 error / agent_message / command_execution / mcp_tool_call / file_change。原生触发对 Codex 记为 **NOT APPLICABLE (mechanism)**；能给出的最强等效证据是"客户端在提示词未点名的情况下自主读取了安装副本里的 `SKILL.md`" |
| 有没有把读文件冒充原生调用 | **没有**：等效证据单独一列 `l3ReadInstalledCopy`，不改名、不合并进 L3 |
| 非 MATLAB 负控是否误触发 | **没有**：任务 D 两次尝试均 0 次 Skill 读取、0 次 MATLAB MCP 调用、0 产物 |
| 真实工程闭环 | **1 例 PASS**：Codex Desktop 的 PID 任务，独立复算与交付一致（4.9748% / 1.5049 s），v3 七个维度全 PASS |
| 是否改过真实用户级 Skills | **没有**：45 份安装副本在探针前（13:07:58）与探针后（18:00:38）逐文件哈希一致 |
| 是否改过 SKILL.md 元数据 | **没有**：本轮 0 次元数据修改，因此没有 before/after 对照需要出示 |
| 其余客户端 | Codex CLI 任务运行 **BLOCKED**（模型缓存拒绝 + 上下文预算）；Codex Desktop 后续 **BLOCKED**（账户额度）；Qoder **DEFERRED**（等批准同步）；WorkBuddy **NOT TESTED**（仓库内没有它的探针接口） |

## 1. 执行模式与为什么必须这样跑

```
codex.exe exec --json --ephemeral --skip-git-repo-check --approve-for-me -C <隔离项目> <自然语言任务>
```

- `--approve-for-me` 与 `-s/--sandbox` **互斥**（同用直接 exit 2）。
- 默认 `approval_policy=never` 会拒绝 MCP 工具调用，MATLAB 一步都跑不起来；
  `--approve-for-me` 隐含 workspace-write，才让 `matlab_official` 的调用通过。
  所有 episode 的 `approvalMode` 字段都记录了这一点，闭环验收还把它作为通过条件之一。
- 提示词四个，均不含 Skill 名、也不含 `mas_` 工具名；`client_evidence.json` 的
  `promptHasSkillName` 对 11 个 episode 全部为 false（断言项）。

| 任务 | 提示词（原文，无点名） |
| --- | --- |
| A 纯 MATLAB 数值 | Use MATLAB to build the 4x4 matrix M = [2 -1 0 0; -1 2 -1 0; 0 -1 2 -1; 0 0 -1 2], compute its determinant and the largest magnitude of its eigenvalues, and write them rounded to 6 decimal places as {"determinant": …, "maxAbsEigenvalue": …} to result.json … |
| B MATLAB+Simulink | Build a small Simulink model: a Constant block with value 3 connected to a Gain block with gain 4, and a Display block … Save the model as phase58_model.slx, simulate it, and write the displayed value to result.json … |
| C 专业域选择 | Design a PID controller for a first-order plant P(s) = 1/(s+1). Target a settling time below 2 seconds and overshoot below 10% … write {"Kp", "Ki", "Kd", "overshootPercent", "settlingTimeSeconds"} to result.json … |
| D 非 MATLAB 负控 | Explain in three bullet points the main differences between TCP and UDP. Do not run any commands and do not create files. |

没有为了让触发率好看而要求客户端"必须加载 Skill"，也没有对同一个任务改提示词重试到成功——
失败的 attempt 全部原样保留（下表）。

## 2. Episode 逐条结果（Codex Desktop，10 条 + Codex CLI，1 条）

| Episode | 任务 | 状态 | 读 SKILL.md | 读 references | MCP 完成 | 工程检查 | 修复 | 用户根读取 | 产物 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `A_numeric_matlab` | A | FAIL | 是 | 否 | 0 | 0 | — | **2** | 0 |
| `A_numeric_matlab_E` | A | FAIL | 是 | 是 | 0（2 次失败） | 0 | — | 0 | 1 |
| `A_numeric_matlab_E2` | A | PASS | 是 | 否 | 1 | 0 | — | 0 | 1 |
| `B_simulink_model_E` | B | PASS | 是 | 否 | 3 | 0 | — | 0 | 2 |
| `C_control_design_E` | C | FAIL | 否 | 否 | 0 | 0 | — | 0 | 0 |
| `C_control_design_E2` | C | FAIL | 否 | 否 | 0 | 0 | — | 0 | 0 |
| **`C_control_design_E3`** | C | **PASS** | **是（3 个 Skill）** | **是（8 项）** | **8 次调用 / 7 完成** | **是（3× check_matlab_code）** | **1 次失败后修复** | 0 | **10** |
| `D_nonmatlab_control` | D | PASS | 否 | 否 | 0 | 0 | — | 0 | 0 |
| `D_nonmatlab_control_E` | D | PASS | 否 | 否 | 0 | 0 | — | 0 | 0 |
| `iso_A` | A（仓库外夹具） | FAIL | 是 | 是 | 0 | 0 | — | 0 | 0 |
| Codex CLI `D_nonmatlab_control` | D | FAIL | 否 | 否 | 0 | 0 | — | 0 | 0 |

`C_control_design_E3` 读到的 Skill：`matlab-orchestrator`、`matlab-control-optimization`、
`matlab-runner`（均相对隔离项目 `.agents/skills/`）；读到的 references/scripts：
`mas_ctrl_analyze.m`、`mas_stability_verdict.m`、`mas_route.m`、`routing.json`、
`acceptance-levels.md`、`failure-classes.md`、`mcp-readiness-ladder.md`。

**证据出处（relocated）**：11 个 episode 都跑在一次性探针目录里
（仓库内 `artifacts/phase58/native/fixtures/task_*`、系统临时目录下的
`p58_codex_task_*`、以及仓库旁的一棵 `p58-iso` 隔离树），事后证据被归档到
`artifacts/phase58/native/{codex-desktop,codex-cli}-tasks/<episode>/`。
因此 `verification.json` 里记录的 `cwd` / `skillRoot` 指向的目录**现在已不存在**。
路径分类是按当时记录的根做的（也就是客户端命令串里实际出现的那个路径），
这一点由 `client_evidence.json` 的 `provenanceNotes`（11 条，逐根标注 RELOCATED）
机器记录，而不是靠本文档的一句话带过。含义要说清：
**探针目录本身无法再复检，能复检的是留在 `events.jsonl` 里的原始命令串与产物哈希。**
本文档只写目录属于哪一类（仓库内 / 系统临时目录 / 仓库旁隔离树），
逐字路径以各 episode `verification.json` 与 `events.jsonl` 里的原文为准——
把本机绝对路径抄进随仓库分发的文档，正是仓库卫生门禁要拦的东西。

## 3. 各客户端证据等级（不相互替代）

等级沿用 Phase 5.7 的四级（**不是** `matlab-runner` 的工程 L1–L5 阶梯）：
L1 源码存在 → L2 客户端列表可见 → L3 客户端发出原生 Skill 加载事件 → L4 按该 Skill 完成并经独立验收。

| 客户端 | L1 | L2 发现 | L3 原生 | L3 等效（自主读安装副本） | L4 | 状态 |
| --- | --- | --- | --- | --- | --- | --- |
| Codex Desktop 0.163.0-alpha.11.1 | EVIDENCED | EVIDENCED（9/9，哈希匹配） | NOT APPLICABLE (mechanism) | EVIDENCED | **EVIDENCED** | 达独立验收 L4 后 BLOCKED（账户额度） |
| Codex CLI 0.147.0 | EVIDENCED | EVIDENCED（9/9，哈希匹配） | NOT APPLICABLE (mechanism) | NOT EVIDENCED | NOT EVIDENCED | 仅 L2；任务运行 BLOCKED |
| Qoder Desktop | EVIDENCED | PARTIAL（Phase 5.7 的 override 日志 + 一次显式 `Skill` 事件；5.8 未复跑） | **DEFERRED**（用户根 2/9 CURRENT、7/9 DRIFTED，同步需批准） | NOT TESTED | NOT TESTED | BLOCKED 等批准 |
| WorkBuddy | EVIDENCED（磁盘存在 47 个目录） | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | 仓库内没有该客户端的探针接口 |

Codex CLI 的 BLOCKED 依据（其 `stderrTail` 原文）：
`failed to load models cache: missing field supports_parallel_tool_calls`；
另外该账户共 365 个 Skill，反复出现 `Exceeded skills context budget. All skill
descriptions were removed`。Codex Desktop 在 06:57Z 之后触发账户额度限制
（"try again at 4:10 PM"），此后没有再跑任何 episode，也没有用别的客户端补数。

Qoder 侧只记录真实接口能看到的东西：`skill-usage.json` 有 1 次
`matlab-orchestrator` 使用记录；它自己的 `qodercli.log` 证明
`.qoder-cn\skills` 覆盖 `.agents\skills`（用户根优先）。**没有**用 Qoder 的结论
去代替 Codex，也没有用 Codex 的结论去代替 Qoder。

## 4. 两条只能记为"限制"的观察

1. **沙箱进程创建被拒**：三次 attempt 报
   `CreateProcessAsUserW failed: 5 (拒绝访问)`——两次工作目录在仓库外
   （系统临时目录、仓库旁的 `p58-iso` 隔离树），一次在仓库内（`fixtures/task_A`）。
   仓库外两次始终没有暴露 MATLAB MCP，也没有重试成功；仓库内那次下一轮就恢复了。
   因此"仓库外夹具"被放弃，但**不能**把该拒绝归因于目录位置本身。
2. **用户根读取回退**：第一条 A attempt（夹具在系统临时目录）除了读项目内副本，
   还读取了 `C:/Users/23201/.agents/skills/matlab-runner/SKILL.md` **2 次**（只读）。
   这只说明"项目根不可用时客户端会去看用户根"，没有说明加载的是哪一个版本，
   因此该 episode 的 `projectScoped=false`，不计入 L3 等效证据。

## 5. 发现的真实缺陷（本轮只记录，不修改）

`matlab-runner` / `matlab-orchestrator` 的 `SKILL.md` 让 Agent 运行
`.\scripts\Test-MatlabMcpExistingSession.ps1`。安装副本里没有这个相对路径：
`C_control_design_E3` 里客户端先按相对路径找不到，随后去读了**源码仓库**的
5 个文件（源码仓库的 `scripts/Test-MatlabMcpExistingSession.ps1`、
`MatlabAgentSkills.{McpProbe,Acceptance,Execution}.psm1`、`schemas/acceptance-report.schema.json`）。
episode 仍然成功——这正是隐患所在：它只在"恰好有一个仓库副本可达"的环境里成立。

没有在本轮修改 SKILL.md：改元数据会移动全部安装哈希，而安装审计尚未收口；
且元数据修改必须自带 before/after 证据。建议：把该检查随 Skill 一起交付，
并按 `SKILL.md` 所在目录引用。

`client_evidence.json` 的 `knownDefects` 与闭环报告的
`clientReadsOutsideSkillCopy` 是这条结论的机器可读记录。

## 6. 真实闭环验收（Task 3）

链路：自然语言 → 客户端选 Skill → 读 references → 官方 MATLAB MCP 执行 →
工程检查 → 失败修复 → 规范化结果 → 独立验收。

`p58_closed_loop_acceptance()` 不接受客户端叙述，只做四件事：

1. **从事件流重建阶段证据**：`skillSelected/referencesLoaded/mcpExecuted/checksRun/repaired`
   全部来自 `command_execution` 与 `mcp_tool_call` 结构化事件；
   `toolCalls=8` 按 call id 去重（started/completed 成对不重复计数）。
2. **独立复算**：用交付的 Kp=5.6 / Ki=9.9 / Kd=0.1 重新搭建
   `P(s)=1/(s+1)` 的单位负反馈回路自行仿真。
   独立值 **4.974846% / 1.504924 s**，交付值 **4.9748484% / 1.5049240 s**，
   极点实部 −3（稳定，DC 增益 1）→ `independentAgreement=true`。
3. **规范化交付**（写临时文件，客户端产物逐字节不变：`clientInputsUnchanged=true`），
   再按 `mas-result/2` 契约评 v3 七维。
4. **七维评分**：
   `numericalCorrectness / enumContractValid / engineeringVerdictCorrect /
   structuralSchemaValid / workflowCompleted / withinBudget / deliveryValid` **全部 PASS**；
   workflow 5 个阶段（skillSelected、referencesLoaded、mcpExecuted、checksRun、repaired）
   由轨迹而非客户端自述提供；budget 取真实用量 8 次调用 / 730 s。

诚实记录：**第一次验收尝试是 FAIL 的**，原因在我方验收工具的引用计算里——
`step()` 的返回是 `[yout, tout]`，我按 `[t, y]` 写，把时间向量当成响应喂给
`stepinfo`，得到 Overshoot 900 / Settling NaN。修正后独立值与交付值一致；
失败那次的数字没有写进任何"通过"结论。

## 7. 未做的事

- 没有把 4 个任务包装成 benchmark，也没有构造 Skills 增益百分比；
  这 11 个 episode 是**单机、单账户、逐客户端**的观察。
- 没有创建系统账户、没有改 ACL、没有启用虚拟化、没有改 MATLAB 全局配置。
- 没有同步任何真实用户级 Skills 根；`mas_skill_install_audit` 只读复查显示
  45 份安装副本与探针前快照一致。
- Qoder 的原生验证停在"等待批准同步"，磁盘文件比对没有被说成客户端已加载。
