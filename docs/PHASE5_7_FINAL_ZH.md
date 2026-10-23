# Phase 5.7 最终报告 · 安装一致性、原生调用与可信评测闭环

日期：2026-10-23
分支：`phase5.1-audit`
基线：`9543f36`（Phase 5.6 冻结点）
范围：Task 0–8；不新增 Skill、不扩建专业案例、不改动 `main`/Release/历史标签。

## 0. 结论先行

| 问题 | 结论 |
| --- | --- |
| 用户安装的副本与仓库是否一致 | **不一致（DRIFTED）**：四个客户端全部存在漂移；已给出只读审计、Diff、备份与回滚方案，**未执行同步** |
| Agent 是否通过客户端原生机制自动加载 Skill | **NOT EVIDENCED**：自动任务 0 个 Skill 事件；Qoder 显式调用成功；Codex 只验证了发现 |
| 是否具备强隔离 | **BLOCKED**：26/26 泄漏面达到，A–D 方案均需人工批准或外部环境 |
| 是否开展正式三臂增益实验 | **未开展**：Task 5 保持 BLOCKED；Phase 5.6 的 9 个 episode 只做 v2 回顾重放 |
| 新旧评分差异 | v1 全部 0/3（判据不适配）；v2 为 R1 0/3、R2 2/3、R3 3/3；输入与 v1 文件逐字节未变 |
| 工程数值与交付 Schema 是否分开 | **是**：9/9 格式合法、5/9 数学达标；4 例“格式合规但数值错误”；0 次 verdict 改写 |
| 并发隔离是否验证 | **是（2 进程 × 3 轮）**；4 进程仅记为 `EXPLORATORY`，不主张稳定性 |
| 全量 MATLAB 回归 | **1075/1075**，32 个套件，0 个 ERROR |

一句话：本轮把“安装了什么、客户端发现了什么、评测器算了什么”从传闻变成了可复核的证据，但没有把任何未证实的环节写成已证实。

## 1. Git 与 Phase 5.6 状态（对应交付 1）

`artifacts/phase57/task0/baseline_audit.json`：

- 分支 `phase5.1-audit`，HEAD `9543f36`，提交时间 2026-10-23 11:23:36；
- `headIsPhase56Commit=true`，`trackedDriftEmpty=true`，冻结树的
  `diffSinceHeadForFrozenTrees` 为空；
- 9 个 Skill 均有 `SKILL.md`；
- 本轮开始时 Phase 5.7 的新增文件均为 untracked，未覆盖任何历史文件。

没有修改 `main`、Release 或历史标签。Phase 5.6 的失败记录（0/3 的 v1 结果、
R3 的 2 个 miss、11/13 的并发日志）全部保留，未被改写。

## 2. 四客户端安装/发现审计（交付 2、3）

工具：`skills/matlab-testing-ci/scripts/mas_skill_install_audit.m`（只读）
报告：`artifacts/phase57/install/install_audit.json`

| 客户端 | 解析级别 | 当前 | 漂移 | 缺失 | 有效根 |
| --- | --- | ---: | ---: | ---: | --- |
| Qoder | observed-precedence | 2 | 7 | 0 | `.qoder-cn\skills` 优先，缺失项回退 `.agents\skills` |
| Codex CLI 0.147.0 | observed-single-root | 5 | 4 | 0 | `.agents\skills` |
| Codex Desktop 0.163.0-alpha.11.1 | observed-single-root | 5 | 4 | 0 | `.agents\skills` |
| WorkBuddy | known-root | 0 | 9 | 0 | `.workbuddy\skills`（符号链接，加载未观测） |

关键事实：

- 总体 `DRIFTED`，9 个 Skill 存在版本冲突，生成 20 条更新建议；
- Qoder 的 override 日志（`qoder_precedence.json`，含原始行号与日志 SHA-256）证明它
  优先读 `.qoder-cn`，但该根只有 7 个 MATLAB Skill 且全部落后；另外 2 个来自 `.agents`；
- 两个 Codex 客户端通过 app-server `skills/list` 各自列出 9/9，`discoveryErrors=[]`；
  这证明**发现**，不证明自动调用；
- 项目级根 `E:\desktop\MATLAB\.qoder\skills` 不存在，“项目级覆盖用户级”在本机未被触发，
  报告为 `UNEXERCISED`，没有写成已观察；
- WorkBuddy 根存在但没有可用的 skill-list 探针，只能标为 `assumed`，不能当作加载证据。

真实安装根的变更计划：`artifacts/phase57/install/real_roots_change_plan.json`，
`executed=false`、`requiresApproval=true`。计划涉及 `.qoder-cn`（7 个 Skill、新增 39、
覆盖 15）、`.agents`（4、5、8）、`.workbuddy`（9、44、19）。本轮**没有**执行。

## 3. 漂移/冲突与安全同步（交付 3、4）

- 9 个 Skill 在至少两个根中存在不同哈希；审计按客户端给出 `CURRENT`/`DRIFTED`/
  `MISSING`/`CONFLICT`，不把一个客户端的规则套到另一个客户端。
- 同步能力已在**隔离临时目录**验证：`tests/SkillSync.Phase57.Tests.ps1` 4/4
  （Pester 3.4.0）——受管升级保留用户自建文件、升级后重复同步为 no-op、替换失败从备份
  恢复旧版本、拒绝接管属于其他仓库的清单。
- `p57_sync_redisovery.m` 把仓库同步到临时根后重新审计：`CONSISTENT`、9/9 `CURRENT`
  （`artifacts/phase57/install/sync_redisovery.json`）。
- 这只证明“同步 → 再发现”的闭环；**不证明**客户端重启后会立即加载，仍需客户端的列表/日志。

## 4. 原生调用 L1–L4（交付 5）

证据：`artifacts/phase57/native/qoder_trigger_evidence.json`、
`artifacts/phase57/native/codex-*/verification.json`

| 级别 | 状态 | 依据 |
| --- | --- | --- |
| L1 源码 | EVIDENCED | 9 个 `SKILL.md` |
| L2 发现 | EVIDENCED（Qoder/Codex CLI/Codex Desktop） | Qoder override 日志 + Skill 工具解析；Codex `skills/list` 9/9 |
| L3 自动调用 | **NOT EVIDENCED** | MATLAB BER 任务会话只有 `mcp_list/mcp_get/mcp_call`，Skill 事件 0 |
| L3 显式调用 | EVIDENCED（Qoder） | 显式请求产生 `Skill` 事件并加载 `matlab-orchestrator` |
| L3 Codex 调用 | NOT TESTED | 只用 Codex 做了发现探针 |
| L4 工作产出影响 | NOT TESTED | 显式验证禁止运行 MATLAB，无法归因 |

没有用 Qoder 的结果代替 Codex，没有把文件发现写成原生触发，也没有为了提高触发率
让 Agent 对所有请求强行加载 Skills。

## 5. 版本化评分 v2 与新旧差异（交付 6）

协议：`mas-benchmark-scoring/2`；Schema：`mas-benchmark-grade/2`；
回顾声明：`benchmark/scoring_p56_retro.json`。

| 臂 | v1 pass | v2 pass | 失败 |
| --- | ---: | ---: | --- |
| R1 | 0/3 | **0/3** | 字段词表 `neither`/`REFUTE`/`non-stiff` |
| R2 | 0/3 | **2/3** | ODE `stiffnessClassified` 词表不一致 |
| R3 | 0/3 | **3/3** | — |

- v1 要求 `routeOk && toolOk`；Phase 5.6 的 prompt 既没要求路由也没要求工具，R1 更没有
  Skill，所以三臂都被判 0。这是**判据不适配**，不是三臂都失败。
- v2 只在任务确实要求时评分：route/tool 在本次重放中均为 `NOT_REQUIRED`；R1 的
  `NOT_APPLICABLE_ARM` 不会被暗中要求调用不存在的 Skill；budget 未声明 → `NOT_REQUIRED`。
- 六个维度分别报告：三臂的 `engineeringVerdictCorrect`、`outputSchemaValid`、
  `workflowCompliance`、`deliveryValid` 都是 3/3；差异只在
  `mathematicalCorrectness`（0/3、2/3、3/3）。
- `inputsAndV1Unchanged=true`：v1 评分器与三个 v1 评分文件的哈希在重放前后相同；
  没有修改 Phase 5.6 报告，也没有把历史的 0/3 偷改成 PASS。
- 这只是 3 个任务、每格 1 个主结果的**回顾性重放**，不是新实验，也不是因果增益。

## 6. 泄漏面与强隔离（交付 7）

报告：`artifacts/phase57/isolation/leak_surface_probe.json`

- 9 类 26 个泄漏面，**26/26 达到**（只有取回字节才算达到）；
- 新增的最关键事实：即使删除 `answers.json`，仓库内的生成器 + 任务集仍可**精确重算**
  3/3 个答案；父会话 transcript 本身含 2031 处任务 id；
- MATLAB MCP 的两次独立调用共享同一工作区（canary 读回），`p56_session_reset` 是清理，
  不是隔离；
- 没有任何账户、ACL、Skills 根或系统配置被修改；探针只读，只记录哈希/大小/元数据，
  不把答案值写进报告。

A（非属主账户 + ACL）、B（Sandbox/VM）、C（远程容器）、D（物理隔离）四方案已评估；
C 受许可/网络阻塞，A/B 需人工批准并先做单臂试运行，D 可人工实施。**强隔离 = BLOCKED，
Task 5 不启动。** 批准前的 V1–V13 对抗验收必须包含正控，0/13 达到才允许讨论正式实验。

## 7. 实际完成的三臂任务与独立评分（交付 8）

- Phase 5.7 **没有新增三臂 episode**；没有把重复跑同一任务当作不同工程问题。
- 实际可报告的三臂数据只有 Phase 5.6 已执行的 9/27 个正式 episode；本轮在
  **输入与 v1 文件不变**的前提下用 v2 重放，得到 0/3、2/3、3/3。
- 独立评分：`benchmark_grade_v2` 与 `mas_delivery_check` 两条独立代码路径对同一批
  存储结果给出 9/9 一致的逐题判断。
- 增益：`UNDETERMINED`。没有构造 Skills-gain 百分比，也没有把 3 个配对单元写成效应量。

## 8. 工程数学与 Schema 的独立结果（交付 9）

报告：`artifacts/phase57/delivery/delivery_audit.json`

| 指标 | 结果 |
| --- | --- |
| 结果数 / 已执行 | 9 / 9 |
| 格式合法 | 9/9 |
| 工程数值达标 | 5/9（R1 0/3、R2 2/3、R3 3/3） |
| 数值正确但格式错误 | 0 |
| 格式合法但数值错误 | 4（全部是枚举词表不一致） |
| verdict 被改写 | 0（`verdictCoerced=false`） |
| 与 v2 评分逐题一致 | 9/9 |
| 审计前后输入哈希 | 不变 |

`mas_delivery_check` 不重复实现数值比较：`math` 委托 `mas_grade`，`reference` 委托
`mas_refcheck`。`UNKNOWN`/`UNDETERMINED` 是合法状态，不是 Schema 错误，也不会被当成 PASS。
回归 `test_delivery_check.m` 93/93；版本化 Schema 为 `schemas/mas-result-2.schema.json`。

## 9. 并发与 Coder（交付 10）

详见 `docs/PHASE5_7_CONCURRENCY_ZH.md`。

- **并发隔离已验证**：3 轮 × 2 进程，6/6 个进程均 15/15；自己的 session 出现在自己的
  日志 6/6；跨会话字符串 0；夹具归属 6/6；残留 0；`isolation.verified=true`。
- **4 进程**：1 轮探索性观测，4/4 进程 15/15，但 `status=EXPLORATORY`，
  `stability=NOT CLAIMED`；没有把一次观测写成资源竞争结论。
- **Phase 5.6 重叠日志**：6 份、全部 11/13、逐字节相同、无 session/pid；
  `causation=NOT ESTABLISHED`，原样保留、只读复核。
- **Coder 入口契约**：字符串函数名 PASS；函数句柄 FAIL 在 codegen 并给出可操作诊断；
  真实链接失败 FAIL 在 build，保留 5561 字节、逐字节一致的编译器日志
  （LNK2019/LNK1120，sha256 `1a158f7d…`）。
- 修正了“空消息一律归因于函数句柄”的误诊：只有无构建日志且入口确实是句柄时才那样说；
  字符串语法错误现在明确报告“在构建前被拒”。回归 `test_codegen.m` 15/15。

## 10. 全量 MATLAB 回归（交付 11）

命令：

```matlab
cd('E:/desktop/MATLAB'); addpath('matlab/validation/phase4');
r = run_all('artifacts/phase57/regression');
```

结果（`artifacts/phase57/regression/phase4_all.json`）：

| 项目 | 结果 |
| --- | --- |
| 32 个 Skill 测试套件 | **1075/1075**（209.5 s） |
| 套件 ERROR | 0 |
| 参考实现 | 15/15 |
| 跨域任务 | 15/15 |
| 路由流水线 | 15/15 |

新增回归：`test_skill_install_audit` 25/25、`test_grade_v2` 60/60、
`test_delivery_check` 93/93；`test_capability` 增至 8/8（新增 tool_counts 负控）；
`test_codegen` 增至 15/15（新增链接失败与字符串入口两个用例）。
Pester Phase 5.7 同步套件 4/4。

## 11. Git Diff 与新测试（交付 12）

已跟踪文件（`git diff --stat`）：

```
matlab/validation/phase4/run_all.m                 |   3 +
matlab/validation/phase54/test_concurrency.m       | 178 +++++++++++++----
skills/capability-matrix.json                      |  75 +++++++-
skills/matlab-codegen-deploy/scripts/mas_codegen_verify.m  | 142 +++++++++++--
skills/matlab-codegen-deploy/tests/test_codegen.m  | 176 +++++++++++++++--
skills/matlab-testing-ci/scripts/mas_capability_check.m    |  28 ++++
skills/matlab-testing-ci/tests/test_capability.m   |  10 ++
7 files changed, 543 insertions(+), 69 deletions(-)
```

新增文件：

- 工具：`mas_skill_install_audit.m`（386 行）、`mas_delivery_check.m`（631 行）；
- 测试：`test_skill_install_audit.m`（193）、`test_delivery_check.m`（323）、
  `test_grade_v2.m`（332）、`tests/SkillSync.Phase57.Tests.ps1`（143）；
- 评分：`benchmark/benchmark_grade_v2.m`（589）、`scoring_p56_retro.json`；
- Schema：`schemas/mas-result-2.schema.json`（49）；
- 验证脚本：`matlab/validation/phase57/` 8 个文件（1433 行）；
- 文档：7 份 Phase 5.7 报告（本文件 + 安装/原生/评分/隔离/交付/并发）；
- 证据：`artifacts/phase57/` 下的审计、重放、泄漏面、交付、Coder 与并发 JSON/日志，
  以及被引用的 Phase 5.4 并发日志。

能力矩阵：56 个工具、58 条 VERIFIED 能力；新增
`mas_skill_install_audit`、`mas_delivery_check` 与对应两条能力。`mas_capability_check`
增加 `tool_counts` 校验（此前 54 个工具全为 VERIFIED，汇总却写 53），并新增负控；
检查结果 `CONSISTENT`。

## 12. Phase 5.8 建议（交付 13）

1. **先批准再同步**：对 `.qoder-cn`、`.agents`、`.workbuddy` 三个根执行
   `Sync-Skills.ps1 -DryRun`，审阅 20 条建议与 Diff 后再同步；先整目录备份，不使用
   `-Force`；同步后重启客户端并用 `skills/list`/日志重新确认，再重跑安装审计。
2. **隔离选型**：优先做 A（非属主账户 + ACL）的单臂试运行；若需要更强边界，选 B
   （Sandbox/VM）。在 V1–V13 含正控全部通过前，不开展正式三臂实验。
3. **Task 5 预注册**：先定样本量、模型别名、预算、六维评分与统计方法；禁止事后加
   `routeRequired`；把探索性观测与正式结果分目录记录。
4. **原生触发**：继续以客户端事件流为唯一 L3 证据；自动触发保持 NOT EVIDENCED；
   不用强制提示词污染负对照。
5. **评分**：新任务一律用 v2 并声明适用性；v1 文件只读保留；报告六维而不是单一布尔。
6. **Coder/并发**：把 `MAS_RUN_SESSION`/`MAS_CODEGEN_RUN_ROOT` 写进运行器契约；
   CI 中先探测编译器；保留 `r.compilerLog` 原始字节；不要在共享 cwd 中直接跑 `codegen`。
7. **矩阵与门禁**：把 `mas_capability_check` 接入 CI；工具/能力计数由条目推导；
   新工具没有矩阵条目时让门禁失败。

## 13. 停止点

本轮已完成 Task 0–4、6–8 中不依赖强隔离的部分；Task 5 保持 BLOCKED。未 push、未 merge、
未 rebase、未 reset/clean，未修改 `main`、Release 或历史标签。等待人工审查后再决定是否
批准真实安装根同步与隔离环境。
