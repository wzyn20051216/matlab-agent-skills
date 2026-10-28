# Phase 5.4 — MATLAB Agent Skills 真实能力验证与跨领域补强

日期：2026-10-22 · 分支 `phase5.1-audit` · 基线/冻结提交 `ce81d72` · MATLAB `26.1.0.3276743 (R2026a) Update 3`
证据根目录：`artifacts/phase54/` · 仓库外留出集：`<repo>-bench-holdout-phase54`、`<repo>-bench-agent-phase54`

## 0. 结论

本轮把"脚本回归通过"和"Agent 真的会做"分开验证：先修复并发夹具缺陷，再用自然语言
prompt + Skill 加载 + 官方 MATLAB MCP 跑真实 Agent episode；同时为 ODE 与视觉两个域
补上可复用的验证契约，并把新域接入隔离 Benchmark。所有评分仍在评测侧完成。

| 项目 | 结果 |
|---|---|
| Phase 5.3 冻结 | 分支 `phase5.1-audit`、HEAD `ce81d72`、9 Skills、49 tools、644/644 / 22 suites、15/15 refs；冻结目录本轮无改动 |
| 并发隔离 | 修复前同轮出现 12/12 与 10/12（共享夹具被另一进程清理）；修复后 **3 轮 × 2 进程全部 12/12**，residue `shared=0 mex=0 tempDirs=0` |
| 真实 Agent episode | 3 个 Phase 5.3 normal 留出任务 **3/3 PASS**；21 次 MATLAB MCP 调用；首次工具运行即 PASS 3/3；1 次 Agent 自身参考选错并修正；评分在评测侧 |
| R1/R2/R3 | **未做三臂对照**；只执行了"技能 + 脚本工具"这一臂，没有 R1（不加载技能）/R2（仅加载技能）对照，**不计算任何相对增益** |
| ODE 验证契约 | `mas_ode_check` 五级判定；**56/56** 测试；`ode45` 退出状态不能单独 PASS |
| 视觉验证契约 | `mas_seg_check` / `mas_detect_check` / `mas_image_contract`；**103/103** 测试；像素/对象、空掩码、阈值来源、坐标与划分泄漏均有明确语义 |
| 新域 Benchmark | 6 个工具级任务（ODE/VIS × normal/boundary/fault）**6/6**；false accepts **0**、false rejects **0**；2 个 boundary 正确判为 UNDETERMINED |
| 全量回归 | **803/803** skill tests / **24 suites** / 0 errored；refs **15/15**、cross-domain **15/15**、pipeline **15/15**、selfDisagreement **0** |
| 能力矩阵 | `mas_capability_check` **CONSISTENT 5/5**；56 VERIFIED capabilities、53 tools；17/17 参考指针可解析 |
| 九 Skills | 仍为 9 个；新增能力全部并入既有 Skill，未新增 Skill、未新增大型工程案例 |

**必须保留的边界声明：**

- 新域 Benchmark 的 **6/6 只是工具级**结果，不是 Agent 级结果，也不是全领域成功率；
  新域的 Agent episode（ODE/vision 的 boundary/fault）本轮 **NOT TESTED**。
- Agent episode 只跑了 Phase 5.3 的 3 个 **normal** 任务，另外 6 个任务未执行；
  不把 3/3 外推为 9/9 或全留出集成功率。
- R1/R2/R3 没有受控三臂数据，**不声明技能带来的增益**。
- 未合并 main、未 push、未发布 Release、未调用未经授权的付费模型、未覆盖任何冻结参考。

## 1. 冻结与 Git 状态（Task 0）

| 检查项 | 结果 |
|---|---|
| 分支 / HEAD | `phase5.1-audit` / `ce81d72`（Phase 5.3 提交） |
| Skills 数量 | 9 个，依赖图 `skillGraph` 13/13、`depProbe` 26/26 |
| Phase 5.3 基线 | 644/644 skill tests、22 suites、49 tools、15/15 frozen refs |
| 冻结目录 | `matlab-control-optimization`、`matlab-testing-ci`、`matlab-simulink-modeling`、`matlab-runner`、`matlab/validation/crossdomain` 相对 `ce81d72` 无 diff |
| 冻结参考 | 未修改 `mas_ref_spec.m`、`reference_manifest.json` 或任何 `*.mat` 参考；`mas_refcheck('verify')` 15/15 |
| Benchmark 边界 | dev 集在仓库内；正式留出集在仓库外；answers/grade 只在评测侧 |
| Git 卫生 | 本阶段改动集中在 `phase5.1-audit` 的一个独立提交；未推送到远端 |

Phase 5.3 的留出集、冻结哈希和证据原位保留，本轮只读引用。唯一被跟踪的既有结果是
`artifacts/phase52/heldout_results.json` 的**重跑时间戳**变化；7/7 判定与全部 measured
值不变，属于回归复跑，不是参考改写。

## 2. 并发隔离修复（Task 1）

### 2.1 缺陷与根因

两个 MATLAB 进程同时运行 `test_codegen` 时，都把夹具写进
`skills/matlab-codegen-deploy/tests/fixtures_codegen`。一个进程的 `onCleanup`
在另一个进程执行期间删除了该目录，导致后者在 `verify` 用例上找不到刚生成的函数，
出现 **10/12**；同时 `mas_codegen_verify` 把 MEX 落到共享 cwd，存在互相覆盖的风险。

修复前证据（原始日志保留）：

- `artifacts/phase54/evidence/concurrency_before/round1_A.log`：12/12，但清理阶段报
  "无法删除 fixtures_codegen"；
- `artifacts/phase54/evidence/concurrency_before/round1_B.log`：10/12，
  `verify: PASS on a real function` 与 `verify: FAIL via goldenFcn mismatch` 失败，
  日志明确出现夹具目录被另一会话移除的警告。

### 2.2 修复内容

- `tests/test_codegen.m`：每次运行在 `tempdir/mas_codegen_tests/<unique>` 下创建
  独立夹具目录，写入 `.mas_run_owner` 所有权标记；清理前核对标记，**只删除本次运行
  拥有的目录**，不删除共享目录，也不删除别人的运行目录。
- `scripts/mas_codegen_verify.m`：`codegen -d` 在私有 `workDir` 中执行，返回前恢复
  调用者 cwd；build/work 目录都唯一；清理只针对本次创建的目录，且拒绝删除调用者目录。
- **没有禁止并发**，没有降低 12 项断言的标准，没有改变任何期望值。

### 2.3 修复后证据

- `artifacts/phase54/evidence/concurrency_after/round1_A.log`、`round1_B.log`：均 12/12。
- `matlab/validation/phase54/test_concurrency.m`：3 轮 × 2 进程，随机顺序与 0–4 s
  错峰启动；每轮都要求两边 12/12。
- `artifacts/phase54/evidence/concurrency_regression/phase54_final_console.log`：

```text
round 1: [12 12] ([12 12])
round 2: [12 12] ([12 12])
round 3: [12 12] ([12 12])
test_concurrency: 3/3 rounds clean; residue shared=0 mex=0 tempDirs=0
```

全量回归中的 `codegen` 也是 12/12（见 §7）。并发修复没有改变 `codegen` 的验收标准。

## 3. 真实 Agent Episode（Task 2）

### 3.1 隔离工作区

工作区 `<repo>-bench-agent-phase54` 在仓库外，只包含：

- `README.md`（任务说明与禁止事项）；
- `task1..3/prompt.md`（自然语言 prompt）与 `task1..3/input.mat`（原始输入）；
- 仓库内 `skills/` 的只读访问（SKILL.md、references、scripts、tests）。

README 明确禁止读取 Phase 5.3 留出集或任何答案/评分文件。三个任务对应
`H-SIG-N`（信号测量）、`H-DATA-N`（数值积分）、`H-ROB-N`（四元数/SLERP），
均为 Phase 5.3 的 normal 留出任务。Agent 需要自己完成路由、加载 Skill/reference、
通过 MATLAB MCP 执行、写 evidence 后再给 verdict；不允许使用 benchmark runner 冒充。

### 3.2 执行结果

| 任务 | 路由 Skill | 使用工具 | 首次工具结论 | 最终 | MCP 调用 | 诊断/恢复 |
|---|---|---|---|---|---:|---|
| H-SIG-N | matlab-signal-vision-ai | `mas_measure_contract` | PASS | PASS | 7 | 0 |
| H-DATA-N | matlab-data-analysis | `mas_quad_check` | PASS | PASS | 5 | 0 |
| H-ROB-N | matlab-robotics-autonomy | `mas_quat_check` | PASS | PASS | 8 | 1（Agent 自身参考选错） |
| 最终读回 | — | — | — | — | 1 | — |
| **合计** | 3/3 路由正确 | 3 个领域工具 | **3/3** | **3/3** | **21** | **1** |

- 首次工具运行即 PASS 3/3，最终 PASS 3/3；没有工具/Skill 产品缺陷需要绕过。
- 唯一一次恢复发生在 H-ROB-N：Agent 第一次手算 SLERP 参考时把起点当成单位四元数，
  与 claims 的起点 `q0` 不一致；重新按 `q0 → qEnd` 计算后与工具结果一致（1.11e-16）。
  该错误与修正都保留在 `trajectory_task3.jsonl` 的 `FIXED` 步骤中，没有删除。
- 21 次调用来自子 Agent 的独立会话记录（`mcp_call` 工具记录：任务 7/5/8 次 + 最终
  读回 1 次），并写入评测侧 `episode_meta.json` 后才生成汇总；
  `trajectory_task*.jsonl` 只叙述了其中 13 次 `evaluate_matlab_code`，两者口径不同。
- 证据：`artifacts/phase54/evidence/agent_episode_grade_summary.json`；
  完整逐任务结果与包含期望值的 `grade.json` 位于留出集
  `<repo>-bench-holdout-phase53\runs\agent_phase54\`，**不进入仓库**。

### 3.3 评分与隔离

`artifacts/phase54/grade_agent_episode.m` 只把三个 `result_taskN.json` 复制到评测侧
暂存目录并改名为正式任务 id，再调用 `benchmark_grade(..., 'agentRuns', 1)` 对照封印
答案评分。结果：

```text
executed 3/9 | pass 3 | fail 0 | missing 6 | false accepts 0
agent level: TESTED (partial holdout)
```

`falseAccepts=0`、`falseRejects=0`；缺失的 6 个任务计为 `MISSING`，不计为失败，也
不进入成功率分母之外的外推。评分记录含期望 verdict，只存在于仓库外。

### 3.4 R1/R2/R3 与执行客户端

R1 = 不加载技能，R2 = 加载技能，R3 = 技能 + 脚本工具。本轮只执行了 R3 形态的一臂：
没有 R1/R2 对照，也没有控制模型、toolbox、预算或环境的三臂运行，因此：

- **不计算相对增益**；`capability-matrix.json` 的 `r1r2r3Gain` 保持 `UNKNOWN`；
- 执行客户端是本会话的 Agent 运行时（Qoder）+ 官方 MATLAB MCP，不是 Codex CLI/Desktop；
  未调用外部付费接口，也未绕过任何后端限制。该客户端差异本身也限制了外推。
- Phase 4.5 的 `executionClient=PARTIAL` 结论不变。

### 3.5 本轮没有做的 Agent 验证

- 新域（ODE/vision）的 Agent episode：**NOT TESTED**；
- Phase 5.3 的 boundary/fault 任务：**NOT TESTED**；
- 多 Agent、多模型、跨版本对比：**NOT TESTED**。

## 4. ODE 验证契约（Task 3）

工具：`skills/matlab-data-analysis/scripts/mas_ode_check.m`（704 行）。

### 4.1 五级判定

| level | 回答的问题 | 不能说明什么 |
|---|---|---|
| `solverExit` | 候选解是否运行并返回有限值 | 精度 |
| `converged` | 独立细化是否趋于稳定极限 | 极限就是正确解 |
| `errorTol` | 是否与独立真值在声明容差内一致 | 物理约束 |
| `physicalInvariant` | 声明的守恒量是否守恒 | 未声明的量也正确 |
| `conclusion` | 所有适用层是否一致且无缺失判据 | 退出标志干净就自动 PASS |

`PASS` 要求所有适用层通过；缺 reference/finalValue/invariant/event/stiffness 判据时
`conclusion=undetermined`，整体 **UNDETERMINED**；任一层失败即 **FAIL**。
**仅凭 `ode45` 的退出状态永远不会产生 PASS。**

### 4.2 参考与数值可靠性

- 解析 reference 会与 tight `ode15s`（RelTol 1e-11 / AbsTol 1e-13）端点交叉校验；
  公式写错（如把 `exp(-t)` 写成 `exp(t)`）会被拒绝评分，判 UNDETERMINED，而不是
  把候选解判 FAIL。
- 无解析 reference 时，用 tight `ode15s` 与 `ode45` 互相校验；两者不一致则不选边，
  精度声明判 UNDETERMINED。
- 误差按 `max|y_ref|` 归一化，避免零交叉处逐元素相对误差发散；逐元素最大值仍报告。
- 固定步长 Euler（h=0.5，[0,2]）得到 0.0625，而 `exp(-2)=0.1353`，相对误差约 0.538：
  数值有限、`solverExit` 通过，但 `errorTol` 必须 FAIL。
- `RelTol=1e-3, AbsTol=1e-3` 对 1e-6 精度声明 FAIL，而退出与收敛仍通过：收敛是
  数值族自身的性质，不是精度证据。
- 守恒量逐行计算；把整矩阵交给向量化 invariant 会伪造零漂移，测试覆盖了两种写法。
- 刚性分类以 Jacobian 特征值比 `max|Re λ| / min|Re λ| >= 100` 为主，ode45/ode15s
  步数比为辅；谐振子比值约 1，不能因"步数多"判刚性。`expectedStiff` 可显式断言。
- 事件用 RelTol 1e-9 检测；声称的事件未发生则 FAIL。

### 4.3 覆盖与环境

56 个测试覆盖：解析真值、错误 finalValue、守恒能量（两种 invariant 写法）、非线性
单摆、粗 Euler、错误 RelTol、刚性与非刚性、ode45 跑刚性问题、事件、不稳定解
（`e^2`）、短候选、坏 reference、无判据等。证据
`skills/matlab-data-analysis/tests/test_ode_contract.m`，**56/56**。

Symbolic Math Toolbox 探测结果为可用，但契约不依赖它：reference 仍使用解析函数与
tight 数值交叉解；即使 Symbolic 不可用，检查逻辑不变。没有因为 SMT 产生 SKIP。

## 5. 视觉验证契约（Task 4）

### 5.1 三个工具

| 工具 | 作用 | 关键拒绝项 |
|---|---|---|
| `mas_seg_check` | 分割掩码：像素与对象分开评分 | 像素精度冒充分割质量；没有显式 IoU 阈值的对象指标；在测试集上调阈值；无容差的指标 |
| `mas_detect_check` | 检测框：显式 IoU 的一对一匹配、AP/mAP | 重复检测当 TP；类别未对齐；全点插值 AP 以外的近似；测试集阈值 |
| `mas_image_contract` | 图像数据/坐标/预处理/划分 | 尺寸/dtype/范围不符；不可逆归一化；不可逆或病态仿射；边界/特征与独立真值不符；索引或内容哈希/分组泄漏 |

### 5.2 语义要点

- 分割同时报告像素级 TP/FP/FN、逐类 P/R/F1/IoU 与对象级匹配；4 连通对象按面积
  降序访问，重复候选计 FP，不做多对一匹配。
- 空预测/空真值有明确约定：两者都空按 IoU=1；真值为空但有预测按 IoU=0；
  0/0 从不静默当作好分数。
- 检测框使用 `[x y w h]`、1-based 左上角、半开区间 `[x, x+w)`；按分数降序、
  逐类贪心一对一匹配；mAP 只对含 GT 的类平均。
- 阈值来源是声明的一部分：`test` 直接 FAIL；未声明则 UNDETERMINED；阈值扫描与
  类别不平衡会显式报告。
- 图像坐标约定为 row=y、column=x；仿射作用于齐次 `[x;y;1]`；归一化通过运行逆变换
  （以及正向变换）与原图比较，而不是假设可逆。
- 边缘/特征与独立 truth 在声明像素容差内匹配；全 1 边缘图会因 precision 极低被拒。
- 划分同时检查索引重叠、内容哈希重叠和 group 重叠；仅在训练集调阈值、在测试集报告
  会 FAIL。

### 5.3 覆盖

`skills/matlab-signal-vision-ai/tests/test_vision_contract.m`，**103/103**。全部使用
小型确定性数组（如 8×8 掩码），没有训练、没有大数据集、没有付费云服务。参考文档：
`skills/matlab-signal-vision-ai/references/vision-verification-contract.md`。
测试中的期望值由手算/独立公式重算，不取工具自身输出。

## 6. 隔离 Benchmark 扩展（Task 5）

### 6.1 新任务与冻结

| 任务 | 域 | 类型 | 期望 verdict | 实测 |
|---|---|---|---|---|
| H54-ODE-N | ode | normal | PASS | PASS |
| H54-ODE-B | ode | boundary | UNDETERMINED | UNDETERMINED |
| H54-ODE-F | ode | fault | FAIL | FAIL |
| H54-VIS-N | vision | normal | PASS | PASS |
| H54-VIS-B | vision | boundary | UNDETERMINED | UNDETERMINED |
| H54-VIS-F | vision | fault | FAIL | FAIL |

冻结哈希（评测侧 manifest）：

- tasks `f48cccc389bb3341942f0f85e5f845f98886bf3efe5755356999c2eeb9c92d88`
- answers `a3e279f77955082b9234275764e53a4b1141042378abbd0c29ce02fc1ff941e1`
- manifest `105650cdfd599bba7099d188f859801e6df3012b45df2e439b665132db3e73f1`

隔离审计 **7/7**：holdout 在仓库外、tasks/answers 存在、answers/tasks 哈希匹配、
0 个逐字节答案副本、dev/holdout id 不相交、任务集完整。

### 6.2 结果

```text
6/6 tasks | executed 6/6 (pass 6) | route 6/6 | tool 6/6 | verdict 6/6
false accepts 0 | false rejects 0 | missing 0 | environment SKIP/BLOCKED 0
```

两个 boundary 任务被判 UNDETERMINED 是**正确评分**，不是失败：它们故意只给求解器
配置/不带 IoU 阈值的指标，工具拒绝在缺少判据时给 PASS。两个 fault 任务被判 FAIL，
说明契约能拒绝"有限但错误"的 ODE 轨迹和"像素精度高但 F1 低"的错位掩码。

**边界声明：** 这是工具级基线，不是 Agent 级；6 个任务不代表 ODE/vision 全领域，
不能把 6/6 外推为全领域或 Agent 成功率。新域的 Agent 级为 **NOT TESTED**。
逐任务结果、轨迹、输入/输出 `.mat` 与包含答案的 `grade.json` 全部在仓库外
`<repo>-bench-holdout-phase54\runs\tool_level_20261022\`；仓库仅保留聚合
`artifacts/phase54/benchmark/task5_summary.json` 与 `isolation_audit.json`。

## 7. 全量回归与失败分类（Task 6）

### 7.1 门禁结果

新进程、单实例、串行执行（`matlab -batch`），日志
`artifacts/phase54/regression/run_all_fresh.log`：

```text
FRESH GATE tests=803/803 suites=24 errored=0 allOk=1
refs=15/15 cross=15/15 pipeline=15/15 elapsed=176.2
```

| suite | 通过/总数 | suite | 通过/总数 |
|---|---:|---|---:|
| routing | 9/9 | dataContract | 118/118 |
| precheck | 16/16 | signalVision | 34/34 |
| depProbe | 26/26 | signalContract | 42/42 |
| grading | 6/6 | robotics | 31/31 |
| phase43Grade | 43/43 | roboticsContract | 162/162 |
| refcheck | 11/11 | **odeContract** | **56/56** |
| bench | 9/9 | **visionContract** | **103/103** |
| capability | 7/7 | benchmarkHarness | 11/11 |
| skillGraph | 13/13 | codegen | 12/12 |
| modelCheck | 2/2 | tableAudit | 11/11 |
| ctrlAnalyze | 14/14 | stabilityContract | 32/32 |
| distEnter | 19/19 | routingContract | 16/16 |

其他门禁：

- Phase 5.2 留出回归：**7/7**（H1–H7，`artifacts/phase52/heldout_results.json`）。
- 冻结参考：`mas_refcheck('verify')` **15/15**；git diff 冻结目录为空。
- 路由/依赖：routing 9/9、depProbe 26/26、skillGraph 13/13、routingContract 16/16。
- 安装完整性：`Sync-Skills.ps1 -DryRun` **9/9 unchanged**；本阶段同步时曾 8 updated /
  1 unchanged，备份在 `<home>\.agents\skills\.matlab-agent-skills\backups\20261022-122823-sync-skills`。
- 能力矩阵：**CONSISTENT 5/5**（53 tools on disk = 53 listed；owner 一致；派生计数一致；
  VERIFIED 证据存在；17/17 reference 指针可解析）。

### 7.2 失败分类

| 现象 | 分类 | 处理与结论 |
|---|---|---|
| 长驻 MCP 会话内 `codegen 10/12`，任意函数报 `emlc:compilationError`（空消息），只产出 html/interface | **环境/测试会话状态**，不是产品缺陷 | 新进程 `matlab -batch` 12/12；同一新会话内连续 3 次均 12/12；全量门禁在新进程 803/803。未删测试、未降容差、未改参考 |
| 并发下 10/12、夹具目录被另一进程删除 | **测试基础设施缺陷** | Task 1 修复：每次运行独立夹具 + 所有权标记 + 私有 cwd；3×2 回归 3/3 轮干净 |
| `agent_episode_grade_summary.json` 曾把 MCP 调用数写死为 21 | **证据脚本缺陷（非产品）** | 改为读取评测侧 `episode_meta.json`，该文件由子 Agent 会话记录统计生成（21 次，任务 7/5/8 + 读回 1）；重新评分并保留日志 |
| capability matrix 注记曾写 "3 normal, 2 boundary, 1 fault" | **文档计数错误（非产品）** | 按实际 2/2/2 修正；`mas_capability_check` 重新 CONSISTENT |
| 新域 2 个 boundary 任务 UNDETERMINED | **正确判定** | 缺少判据时拒绝 PASS；期望值即 UNDETERMINED，评分通过 |

没有发现需要修改产品工具的失败；没有参考答案错误；没有缺失环境导致的 SKIP/BLOCKED；
没有把无法判定的结果强行判 PASS。全程**未静默删除测试、未降低容差、未修改历史任务的
参考答案**。长驻会话污染作为残余风险保留，门禁统一使用新进程（见 §10）。

## 8. 九 Skills 集成（Task 7）

仍为 9 个 Skill，没有新增 Skill、没有新增 Buck/Boost/三相逆变器或大型机器人仿真案例，
没有重构安装器或 MATLAB MCP 服务。

| 集成点 | 变更 |
|---|---|
| `skills/matlab-data-analysis/SKILL.md` | 描述加入 ODE 求解/验证；新增 `mas_ode_check` 示例与边界说明；测试行加入 56/56 |
| `skills/matlab-data-analysis/references/data-verification-contract.md` | 新增 §9 ODE 五级契约、参考策略、步长/刚性/事件示例 |
| `skills/matlab-signal-vision-ai/SKILL.md` | 描述加入视觉验证；新增分割/检测/图像契约示例与七条边界；测试行加入 103/103 |
| `skills/matlab-signal-vision-ai/references/vision-verification-contract.md` | 新增完整视觉验证契约文档 |
| `skills/capability-matrix.json` | 新增 4 个工具与 4 项能力；VERIFIED 56、tools 53；注记与 Agent 级状态更新 |
| `matlab/validation/phase4/run_all.m` | 注册 `odeContract`、`visionContract`，suite 22 → 24 |
| `benchmark/benchmark_fixtures.m` / `benchmark_grade.m` | 新增 6 个 ODE/vision 夹具；评分器支持 `agentRuns` 与 `MISSING`，不把缺失计为 false reject |

新增文件：

- `skills/matlab-data-analysis/scripts/mas_ode_check.m`
- `skills/matlab-data-analysis/tests/test_ode_contract.m`
- `skills/matlab-signal-vision-ai/scripts/mas_seg_check.m`
- `skills/matlab-signal-vision-ai/scripts/mas_detect_check.m`
- `skills/matlab-signal-vision-ai/scripts/mas_image_contract.m`
- `skills/matlab-signal-vision-ai/tests/test_vision_contract.m`
- `skills/matlab-signal-vision-ai/references/vision-verification-contract.md`
- `matlab/validation/phase54/test_concurrency.m`

## 9. Git Diff 摘要

相对 `ce81d72`，源码与文档改动（证据目录按仓库惯例单独加入）：

- 修改 10 个已跟踪文件：`benchmark/benchmark_fixtures.m`、`benchmark/benchmark_grade.m`、
  `matlab/validation/phase4/run_all.m`、`skills/capability-matrix.json`、
  `skills/matlab-codegen-deploy/scripts/mas_codegen_verify.m`、
  `skills/matlab-codegen-deploy/tests/test_codegen.m`、两个 `SKILL.md`、
  `data-verification-contract.md`、`artifacts/phase52/heldout_results.json`（仅重跑时间戳）。
- 新增 8 个源码/文档文件（§8）+ 本报告 + Phase 5.4 证据。
- 冻结参考、冻结目录、安装器和 MCP 服务无 diff。

## 10. 未验证域与残余风险

1. **新域 Agent 级**：ODE/vision 只跑了工具级 6/6；新域的 Agent episode（尤其
   boundary/fault）未运行。
2. **R1/R2/R3**：没有三臂对照，不能声称技能增益；执行客户端不是 Codex CLI/Desktop。
3. **Phase 5.3 留出集的另外 6 个任务**：未执行，3/3 不能外推为 9/9。
4. **平台单一**：只在 Windows 10 / R2026a Update 3 验证；Linux/macOS、旧版本未测。
5. **工具箱边界**：Symbolic 可用但未依赖；Stateflow、Simulink Coder/Test、HDL、
   PLC/STM32 目标未验证。
6. **深度学习**：没有训练/迁移学习/GPU；视觉工具只验证确定性推理与指标。
7. **大数据**：没有 tall array、数据库、超大规模表格或流式数据验证。
8. **控制/机器人高级域**：H-infinity/MPC、ROS bag、SLAM、路径规划、UAV scenario
   未验证；已有控制/机器人契约只覆盖已列出的任务。
9. **真实硬件**：没有传感器、执行器、实时目标或硬件在环。
10. **运行时自动触发**：没有验证 Agent 在无显式提示时自动选择 Skill 的能力。
11. **并发范围**：只回归了 `test_codegen` 3×2；全量门禁的多进程并发未验证。
12. **隔离强度**：程序性隔离，不是操作系统沙箱；知道绝对路径的进程仍可能读答案。
13. **长驻会话**：MATLAB Coder 在长驻 MCP 会话中可能进入不可用状态；已用新进程规避，
    但根因未定位到 MATLAB 内部。
14. **样本量**：新域 6 个任务、Agent 3 个任务，样本很小；不提供统计置信区间。

## 11. Phase 5.5 优先级

1. **P0 — 新域 Agent episode**：在同等隔离下跑 ODE/vision 的 normal/boundary/fault，
   保留首轮失败与恢复；这是当前最大的证据缺口。
2. **P0 — R1/R2/R3 受控三臂**：固定模型、toolbox、预算、环境与任务集；若后端仍不可用，
   继续记录 BLOCKED/UNKNOWN，不计算增益。
3. **P1 — 工业域扩展**：Stateflow、Simulink Coder/Test、HDL、PLC/STM32 目标；
   先确认许可证，再建立可复现的最小案例与独立参考。
4. **P1 — 深度学习验证契约**：不训练大模型的前提下，补数据泄漏、校准、逐类指标、
   分布偏移与推理确定性；禁止用测试集调阈值。
5. **P1 — 真实硬件/ROS**：ROS bag、SLAM、路径规划、UAV scenario 或硬件在环；
   需要真实环境时明确记录 SKIP/BLOCKED，不用仿真冒充硬件。
6. **P2 — 运行时与跨版本**：Agent 自动触发、Codex/Desktop 客户端、Linux/macOS、
   多个 MATLAB 版本；同时验证安装器与 Skill 发现。
7. **P2 — 长驻会话卫生**：把"全量门禁必须新进程"写入运行约定；调查 MATLAB Coder
   会话污染的可检测信号，避免把环境状态误判为算法失败。
8. **P2 — 统计与并发**：扩大留出集并给出置信区间；把并发回归扩展到更多 suite，
   保持"每次运行只清理自己的文件"。

## 12. 交付物对照

| # | 交付物 | 位置 |
|---|---|---|
| 1 | Phase 5.3 冻结/Git 状态 | §1；`git log` / `git diff ce81d72` |
| 2 | 并发修复前后证据 | §2；`artifacts/phase54/evidence/concurrency_before|after|regression/` |
| 3 | 真实 Agent episode 结果 | §3；`artifacts/phase54/evidence/agent_episode_grade_summary.json`；仓库外 `runs/agent_phase54/` |
| 4 | R1/R2/R3 未执行说明 | §3.4；`capability-matrix.json` `r1r2r3Gain=UNKNOWN` |
| 5 | ODE/数值可靠性能力 | §4；`mas_ode_check.m` + 56/56 |
| 6 | 图像/视觉验证能力 | §5；三个工具 + 103/103 |
| 7 | 新工具/测试 | §8；8 个新增源码/文档文件 |
| 8 | 独立 Benchmark 结果 | §6；`artifacts/phase54/benchmark/task5_summary.json` |
| 9 | 全量回归 + Git Diff | §7、§9；`run_all_fresh.log` / `phase4_all.json` |
| 10 | 能力矩阵更新 | §7；`mas_capability_check` CONSISTENT 5/5 |
| 11 | 未验证域清单 | §10 |
| 12 | Phase 5.5 优先级 | §11 |

## 13. 停止点

本阶段按约束停止：**未合并 main、未 push、未发布 Release、未调用未经授权的付费模型、
未覆盖冻结参考**。等待审查后再决定 Phase 5.5 的范围。
