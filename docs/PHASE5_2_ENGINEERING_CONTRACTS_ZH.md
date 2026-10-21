# Phase 5.2 — MATLAB Agent Skills 通用工程能力强化（第一批）

日期：2026-10-21
分支：`phase5.1-audit`（HEAD `741cc2b`）
基线：`v0.6.0-preview.2`
环境：Windows 10.0.26100；MATLAB `26.1.0.3276743 (R2026a) Update 3`；
Control System Toolbox、Simulink、MATLAB Coder、Signal Processing Toolbox 均为真实许可。
本轮未修改 `main`、未覆盖基线、未 push/merge/rebase、未发布 Release、未新增第十个 Skill。

## 0. 结论摘要

Phase 5.1 记录的缺陷里，有一类反复出现：**数值算对了，工程结论错了**。
本轮只做三件事，并用可重放的证据把它们钉住：

| 方向 | 交付 | 修复前 | 修复后 |
|---|---|---|---|
| P0-A 稳定性与验收契约 | `mas_stability_verdict` + `mas_ctrl_analyze` 重构 | 8 / 29 | **32 / 32** |
| P0-B 扰动传播验证 | `mas_dist_enter` | 0 / 19（函数不存在） | **19 / 19** |
| P0-C 路由输出契约 | `mas_route` schema 1.1 + `BLOCKED` | 2 / 16 | **16 / 16** |

完整回归：**311 / 311** 个 Skill 测试、18 个套件、0 个套件错误；
**15 / 15** 冻结参考、**15 / 15** 跨域任务、**15 / 15** 路由流水线；
总耗时 169.7 s。留出集 H1–H7：**7 / 7**。

核心验收标准不是新增了多少工具，而是 Agent 能否更可靠地做出正确工程判断，
并且这个判断能被独立验证。本轮新增的每个结论都必须带三个东西：**值、证据来源、
缺失证据时的明确状态**。

---

## 1. 根因与最小修复

### 1.1 P0-A：把“算出一个数”当成“工程结论”

**已知根因**（Phase 5.1 缺陷档案）：

- C5-18：环路没有 0 dB 穿越时，`mas_ctrl_analyze` 仍返回 `verdict='STABLE'`，
  `pmWorst=NaN`、`nDown=0`。没有相位裕度被静默升级成“稳定”。
- C5-11：`margin(L)` 只返回一个穿越点。有谐振的环路会两次穿越 0 dB，
  第一次 +83°、第二次 −95°；取第一次会报“健康”，闭环却振荡。
- C1-01：`margin()` 的返回顺序是 `[Gm, Pm, Wcg, Wcp]`，曾被读反。
- C1-02：`Wcg` 是相位穿越频率，不是穿越处的幅值；用它算 GM 会产生 −70 dB 量级的垃圾值。
- C1-16：`angle()` 的主值折叠会把 −95° 报成 +83°。
- C1-17：离散模型的 Nyquist 上限若只作用于输入网格，会生成 26 GHz 的虚假穿越。
- 其他：DC 处 `|L(0)|=1` 的 PM、负增益环在 DC 的 −180°、`π/Ts` 处的 GM、
  Hz 与 rad/s 混用、NaN/Inf/空值被当成 PASS。

**修复**：

1. `skills/matlab-control-optimization/scripts/mas_ctrl_analyze.m`
   - 枚举每一个 0 dB 向下/向上穿越和每一个 −180° 穿越，报告全部交点；最差者绑定。
   - 闭环极点来自 `feedback(L,1)`；`closedLoopStatus`、`closedLoopPoles`、`closedLoopMaxPole`。
   - 单独处理 DC 边界（`DC_AT_0_DB`、`DC_PHASE_180`）和离散 Nyquist 边界（`NYQUIST_BOUNDARY`）。
   - 相位先 unwrap，PM 再折回 `(-180,180]`；每个交点同时给 `f`（Hz）和 `wRadPerSec`。
   - `gmWorst` 统一为 dB，并新增 `gmKnown`，避免把“没有穿越”与“GM = Inf”混为一谈。
   - 当闭环极点与频率证据冲突时，`verdict='UNDETERMINED'` 并写 `EVIDENCE_CONFLICT` 注记。
2. `skills/matlab-control-optimization/scripts/mas_stability_verdict.m`
   （schema 1.0）把结论拆成三个独立维度：

   | 维度 | 字段 | 取值 |
   |---|---|---|
   | 数学稳定性 | `math.stability` | `STABLE` / `UNSTABLE` / `UNDETERMINED` |
   | 工程目标 | `target.status` | `PASS` / `FAIL` / `UNDETERMINED` |
   | 证据质量 | `evidence.quality` | `VERIFIED` / `PARTIAL` / `NOT VERIFIED` |

   - 边缘稳定映射为 `UNSTABLE`（不是渐近稳定），同时 `math.marginal=true`。
   - 没有有限 PM 时，`target.status='UNDETERMINED'`，绝不默认 PASS 或 FAIL。
   - 相位永不达 −180° 时 GM 为 Inf，这是 PASS，不是缺失值。
   - 没有可用来源时证据质量降为 `NOT VERIFIED`；只有单一来源时降为 `PARTIAL`。
   - 空模型、非 LTI、非结果 struct 都有明确的 `INVALID_INPUT` 路径。
3. `skills/matlab-testing-ci/scripts/mas_grade.m`：数值/域检查遇到空值、
   非标量、NaN、Inf、非法 reference 或非法 tolerance 时明确失败；
   域测量无效时 `meets` 为 `UNDETERMINED`。**缺失证据不再能保持“未失败”状态。**
4. `skills/matlab-control-optimization/references/stability-contracts.md` 与
   `SKILL.md`：把上述边界规则写成可查阅的契约，并要求“报告任何稳定性结论前先调用
   `mas_stability_verdict`”。

**修复前后证据**：

- `artifacts/phase52/evidence/P0A_before_fail.log`：**8 / 29**。A1–A7、
  B1/B4、C1–C9、D1–D3 失败；失败类型包括 `closedLoopPoles field missing`、
  `mas_stability_verdict` 未定义、`wRadPerSec` 字段缺失、PM 符号错误。
- `artifacts/phase52/evidence/P0A_after_32.log`：**32 / 32**。
- 历史 `test_ctrl_analyze`：**14 / 14**，无回归。
- 最终 32 例是修复前 29 例的超集：原有 29 个 case ID 全部保留并通过；
  新增 C10–C12 覆盖 NaN、Inf、非法 struct，A7 从“接近 20 dB”收紧为
  “与 `|L(π/Ts)|` 解析值一致”。**没有删除失败测试，也没有放宽阈值。**

### 1.2 P0-B：输出曲线变化不等于扰动进入了对象

**已知根因**：

- C4-02：Boost 的负载电阻 `R` 留在参数结构 `p` 里，只有 `Vin` 被传进 Plant，
  负载阶跃根本没有进入对象；所有跌落读 0.00%，“指标好得不合理”。
- C4-04：负载前馈用了被调量 `iL`，不是负载电流，前馈实际无效。
- C4-07：D6 模型把 `dx=−2x+2u` 接成 `dx=−2x+u`，输入增益少一半。
- 只观察输出曲线无法区分三种情况：控制器读到了新值而对象没读到；对象读到了但输出
  理论上不敏感；注入时间错误。

**修复**：新增 `skills/matlab-simulink-modeling/scripts/mas_dist_enter.m`，
把链路拆成五个各自带证据的检查：

```
请求的变化 -> 参数/输入/初始状态 -> 对象接收 -> 输出或内部状态变化
           -> 生效时间 + 独立预测
```

- 参数变化用 `plantParams` / `paramLog` 核对；输入变化用 `disturbanceLog` 核对；
  初始状态变化用 `x0` / `initialState` 核对。
- `plantParams` 明确声明了对象消费哪些字段：变化字段不在其中 -> FAIL
  `PARAM_NOT_ENTERED_PLANT`；完全没有 `plantParams` -> UNDETERMINED，不是 PASS。
- 输出敏感时比较输出增量；输出理论上不敏感时（`expect.insensitive=true`）
  必须比较内部状态 `x`，状态没变 -> FAIL `INTERNAL_EVIDENCE`，没有状态记录 ->
  UNDETERMINED。
- 时间：有日志按日志核对 `tInject`；只有响应时允许 `maxResponseDelay` 的滞后，
  并明确标注 `effectiveTimeSource='response'`；早于 `tInject` 的变化一律失败。
- 独立预测 `expect.delta` 必须来自解析解、独立实现或另一个工具，不能从被检查的
  同一次仿真读回；没有预测时最高证据质量为 `PARTIAL`。
- `verdict` 只有 `PASS` / `FAIL` / `UNDETERMINED`；`reasons` 与逐项 `checks`
  同时返回；`schemaVersion='1.0'`。

**修复前后证据**：

- `artifacts/phase52/evidence/P0B_before_fail_replay.log`：把 `mas_dist_enter.m`
  移走后重跑，**0 passed / 15 failed / 4 skipped**；这是“函数不存在”的回放，
  不是“旧实现有 bug”的回放，报告中明确区分。
- `artifacts/phase52/evidence/P0B_after_19.log`：**19 / 19**，含 4 个真实 `.slx`
  变体（正确、零幅值、仅控制器更新、错误阶跃时间）。
- 历史 `test_model_check`：**2 / 2**，无回归。
- `SKILL.md` 新增“先验证扰动是否到达对象”的入口；
  `references/excitation-checks.md` 记录完整链路、配置字段和 Simulink 记录配方。

### 1.3 P0-C：路由输出没有契约，消费者只能猜

**已知根因**：

- C9-10：`mas_route` 的输出字段没有文档；一个全新消费者按 `r.skills`、
  `r.matched`、`r.missing` 绑定，12 / 12 条 prompt 全部打印 `<unexpected>`。
- 旧实现没有 `missing` / `matched`，没有 `BLOCKED`；即使依赖缺失或 Skill 损坏，
  仍可能返回一个非空 `loadOrder`，调用方会启动一个注定失败的部分流程。
- 否定词和短 ASCII 词（如 `AI`、`ROS`）按子串匹配会产生误路由。
- 缺失工具箱、未安装 Skill、损坏 `SKILL.md`、依赖缺失、依赖环没有统一表示。

**修复**：`skills/matlab-orchestrator/scripts/mas_route.m` 重写为 schema **1.1**：

| 字段 | 含义 |
|---|---|
| `schemaVersion` | `'1.1'` |
| `decision` | `ROUTE` / `CLARIFY` / `AMBIGUOUS` / `BLOCKED` |
| `primary` / `secondary` | 主/次 Skill，`secondary` 可为空 |
| `loadOrder` | 已按依赖拓扑排序；`BLOCKED` 时为空 |
| `alwaysLoaded` | 恒加载的 `matlab-runner` |
| `ranked` | 全部候选及分数 |
| `matched` | `skill` / `term` / `weight`，分数可审计 |
| `missing` | `kind` / `name` / `detail` / `hard`；kind 含 `skill`、`content`、`toolbox`、`dependency`、`cycle` |
| `available` | 每个 Skill 的 `installed` / `loadable` / `problem` |
| `nextAction` | `load` / `ask` / `stop` |
| `reason` | 人类可读理由 |
| `notes` / `prompt` / `tableSource` / `tableVersion` | 可追溯信息 |

- 依赖闭包 + 拓扑排序；依赖缺失或成环 -> `BLOCKED`，`loadOrder` 为空。
- 硬工具箱许可失败 -> `BLOCKED`；软需求失败只写入 `notes`，不阻塞。
- 否定处理按子句切分（中英文标点、`而是`、`只做` 等），避免把
  “不要用 Simulink，做 PID”误判为 Simulink 任务。
- 长度 ≤3 的 ASCII 触发词使用词边界正则，避免 `AI` 命中 `SAIL` 之类的子串。
- `matlab_pipeline.m` 增加 `BLOCKED` 守卫：不执行、记录 `SKIP` 与原因、继续下一个任务。

**修复前后证据**：

- `P0C_before_fail_replay.log`：恢复 HEAD 版 `mas_route.m` 后 **2 / 16**；
  失败集中在 `missing` 字段缺失、依赖环、`BLOCKED` 仍返回 `loadOrder`、`matched` 缺失。
- `P0C_after.log`：**16 / 16**。
- 历史 `test_routing`：**9 / 9**；`test_grading`：**6 / 6**。
- 路由流水线：**15 / 15 PASS，skillMatch 15 / 15**。
- `references/routing-contract.md` 给出字段表、决策表、消费者伪代码和已知边界；
  `SKILL.md` 明确“先消费 `decision`，不要覆盖它”。

---

## 2. 九个 Skills 的更新后指令

本轮**没有新增第十个 Skill**。结构保持 `SKILL.md` + `references/` + `scripts/` +
`tests/` + `evals/`；只有三个 `SKILL.md` 增加契约入口，一个脚本被加固，
其余 Skills 的指令未改但全部进入回归。

| # | Skill | 本轮变化 | 指令入口 |
|---|---|---|---|
| 1 | `matlab-orchestrator` | 路由契约 1.1；`BLOCKED`；先 decision 后 loadOrder | `skills/matlab-orchestrator/SKILL.md` |
| 2 | `matlab-runner` | 无指令变化；仍是恒加载、依赖顺序第一 | 原 `SKILL.md` |
| 3 | `matlab-testing-ci` | `mas_grade` 拒绝空/非标量/NaN/Inf/非法容差 | 原 `SKILL.md`；`scripts/mas_grade.m` |
| 4 | `matlab-simulink-modeling` | 新增扰动传播验证入口 | `skills/matlab-simulink-modeling/SKILL.md` |
| 5 | `matlab-control-optimization` | 稳定性三答案契约 | `skills/matlab-control-optimization/SKILL.md` |
| 6 | `matlab-data-analysis` | 无指令变化；跨域 T1 回归 | 原 `SKILL.md` |
| 7 | `matlab-signal-vision-ai` | 无指令变化；OFDM 留出点 H6 | 原 `SKILL.md` |
| 8 | `matlab-robotics-autonomy` | 无指令变化；R1/D8 回归 | 原 `SKILL.md` |
| 9 | `matlab-codegen-deploy` | 无指令变化；G1 回归 | 原 `SKILL.md` |

三处新指令都遵守“先给结论维度、再给证据、缺失即 UNDETERMINED”的统一风格，
没有把 Buck/Boost 具体案例写进主文件；案例只出现在文档的边界说明中。

---

## 3. 跨域回归与独立参考

### 3.1 完整回归

`matlab/validation/phase4/run_all.m` 新增三个套件：
`stabilityContract`、`distEnter`、`routingContract`。

最终结果（`artifacts/phase52/evidence/full_suite_after.log`）：

| 套件 | 通过 | 套件 | 通过 |
|---|---:|---|---:|
| routing | 9 / 9 | stabilityContract | 32 / 32 |
| precheck | 16 / 16 | distEnter | 19 / 19 |
| depProbe | 26 / 26 | routingContract | 16 / 16 |
| grading | 6 / 6 | tableAudit | 11 / 11 |
| phase43Grade | 43 / 43 | signalVision | 34 / 34 |
| refcheck | 11 / 11 | robotics | 31 / 31 |
| bench | 9 / 9 | codegen | 12 / 12 |
| capability | 7 / 7 | modelCheck | 2 / 2 |
| skillGraph | 13 / 13 | ctrlAnalyze | 14 / 14 |

合计 **311 / 311**；`suitesErrored=0`、`suitesRun=18`、`allSuitesOk=true`。
`run_all` 不按退出码判定；套件抛错会单独计数并打印 ERROR，不会混进绿色总数。

### 3.2 冻结参考

- `mas_refcheck` 对 15 个冻结参考：**15 / 15**，SHA-256 全部一致。
- 日志中前两张 14 / 15 的表是**故意的篡改攻击控制组**：第一张只改 D3 的值、
  第二张同时改值和 hash；它们必须失败，且分别触发 VALUE 与 HASH 守卫。
  第三张才是已提交的 manifest。
- 所有参考阈值与容差未修改；`phase52_hash.m` 对 held-out 的 values + checks
  做规范化 SHA-256，改一个容差就会改变 hash。
- 跨域任务由 `mas_verify_task` 按 manifest 评分，不由任务自己的 `out.status`
  自评；15 / 15，其中 dev 12 / 12、held-out 3 / 3。

跨域覆盖：

| 任务 | 领域 | 结果 | 任务 | 领域 | 结果 |
|---|---|---|---|---|---|
| D1 | 科学计算 | PASS | C1 | 控制（稳定） | PASS |
| D2 | 数据分析 | PASS | C2 | 控制（不稳定） | PASS |
| D3 | 信号处理 | PASS | C3 | 控制（多穿越） | PASS |
| D4 | 图像处理 | PASS | T1 | 数据清洗 | PASS |
| D5 | 控制 | PASS | S1 | 信号（留出） | PASS |
| D6 | Simulink | PASS | R1 | 机器人（留出） | PASS |
| D7 | 电力电子 | PASS | G1 | 代码生成（留出） | PASS |
| D8 | 机器人 | PASS | | | |

---

## 4. 独立数值验收与留出集

留出集位于 `matlab/validation/phase52/`：先冻结 `heldout_reference.json`
（SHA-256），再由 `phase52_heldout_run.m` 读取并独立测量。参考值只来自解析公式
或问题构造，不读取被测工具的输出。

| ID | 领域 | 独立方法 | 测量值 | 结果 |
|---|---|---|---|---|
| H1 | 数学/数值 | Vandermonde 构造 + `A\b`；64 点 Gauss–Legendre（不用 `erf`/`integral`） | x 精确；I=0.746824132812 | 2/2 |
| H2 | 动态系统 | RK4 手写积分（不用 `ode45`） | 0.950212931632 / 0.997521247823 | 2/2 |
| H3 | 控制（负增益） | 解析闭环分母 `s²+4s−1`；工具判三维结论 | maxRealPole=0.2360679775；UNSTABLE/FAIL/VERIFIED | 4/4 |
| H4 | 控制（离散/无穿越） | 解析 `z=0.4`、`|L(−1)|=0.4/1.8`；`allmargin` 交叉核对 | GM=13.0643 dB；STABLE/PASS/VERIFIED；无穿越环 STABLE/UNDETERMINED/PARTIAL | 8/8 |
| H5 | Simulink | 真实 `sim` + 解析 `3(1−e⁻²)` | Δ=2.593994；t_eff=0.01 s；PASS/VERIFIED | 4/4 |
| H6 | 信号 | QPSK-OFDM 6 dB 留出点；闭式 `0.5·erfc(√SNR)` | BER=0.002242（相对误差 6.1%，限 15%） | 1/1 |
| H7 | 多 Skill 路由 | 真实 `mas_route`，复合 prompt | ROUTE；Simulink 主、信号次；loadOrder 正确 | 4/4 |

**首次通过：7 / 7**（在冻结参考修正之后，见下）。

需要如实披露的两处：

1. **H4 的参考值在冻结前被独立探针纠正过一次。** 最初把离散对象写成
   `0.4z/(z−0.8)`，并预期一个有限 GM；探针发现它在 `z=−1` 处为 `+0.222`
   （相位 0°），根本没有 −180° 穿越，GM=Inf。改为 `0.4/(z−0.8)` 后，
   `allmargin` 给出 `GainMargin=4.5`（13.0643 dB），闭环极点 0.4。
   这是**参考错误**，不是工具误接受；冻结发生在修正之后，因此“首次通过”
   不是盲测首跑，报告不把它包装成盲测。
2. **H5 的生效时间容差在冻结前按求解器步长设定。** 实测第一个变化出现在
   0.01 s（ode4 固定步长），工程要求是“不晚于第一个求解步”，于是检查写为
   `effectiveTime ≤ 0.011`，而不是要求精确等于 0。该容差在冻结前写入并哈希，
   不是看到结果后放宽。

独立数值验收的核心规则：**不与被测工具共用代码路径**。H1 不调用 `erf`，
H2 不调用 `ode45`，H3/H4 的解析值来自特征方程和 `z=−1` 的直接代入，
H5 的预测来自一阶系统闭式解，H6 来自 QPSK 误码率闭式解，H7 来自真实路由。
历史 `test_ctrl_analyze` / `test_stability_contract` 还使用 `margin` / `allmargin`
作为第二来源，并显式验证 `margin` 的返回顺序和 dB/绝对比值单位。

---

## 5. 哪些能力真实跑过 MATLAB，哪些只是静态/单元测试

### 5.1 真实 MATLAB（本轮实际执行）

- `mas_ctrl_analyze` / `mas_stability_verdict`：真实 `tf`、`feedback`、`pole`、
  `margin`、`allmargin`，连续与离散（`Ts=0.1`）、DC、`π/Ts`、负增益、NaN/Inf/空输入。
- `mas_dist_enter`：4 个真实 `.slx` 模型经 `new_system` / `sim` 运行；H5 再一次
  真实 Simulink 运行（Constant → Gain → Transfer Fcn → To Workspace）。
- `mas_route`：真实路由脚本 + `mas_pipeline` 15 个跨域任务，真实依赖顺序与
  `BLOCKED` 守卫。
- OFDM BER、图像、机器人、代码生成：历史套件在真实 MATLAB 中执行并通过
  （34/34、31/31、12/12）。
- 冻结参考、SHA-256、篡改攻击、`mas_verify_task`：真实运行。

### 5.2 仅静态/单元测试或通过测试接缝

- 路由的“缺失工具箱 / 未安装 Skill / 损坏 SKILL.md / 依赖环”通过
  `opts.toolboxStatus`、`opts.skillStatus`、临时 `skillsRoot` 构造；
  没有真的卸载工具箱或破坏本机 Skill 安装。
- 软工具箱需求只验证“写入 notes、不阻塞”的代码路径。
- 安装器只做了真实仓库的 `Sync-Skills.ps1 -DryRun`：9 个 Skill 均可安装、
  0 冲突、0 失败；**没有运行 Pester 安装器套件**。
- `mas_grade` 的 NaN/Inf/空值守卫是单元测试，不是真实评分任务。

### 5.3 未测试（NOT TESTED）

- **Agent 运行时自动触发/加载**：Phase 4.3 的客户端回执证明 Skill 能被发现和加载，
  但本轮没有让一个 LLM Agent 在真实对话中自动选择并执行这些 Skill。
- Pester 安装器场景套件、WSL/Linux/macOS、MATLAB ≤ R2025b。
- 付费模型 Benchmark（明确禁止）。
- 能力矩阵仍有 14 项 `NOT TESTED`、3 项 `PARTIAL`（Stateflow、Simulink Coder、
  Simulink Test、CI 生成、H∞、深度学习、大规模 DataFrame、HDL、STM32、
  ROS bag、SLAM、UAV、运行时调用、R1/R2/R3）。

---

## 6. Git Diff、提交与残余缺陷

### 6.1 工作区变化（未提交）

基线 `741cc2b`，分支 `phase5.1-audit`。**本轮没有创建 commit、没有 push、
没有 merge/rebase、没有发布 Release。**

已跟踪文件修改 **10 个，+988 / −170**：

| 文件 | 变化 |
|---|---|
| `skills/matlab-control-optimization/scripts/mas_ctrl_analyze.m` | +286 / −60，全穿越/DC/Nyquist/三维证据 |
| `skills/matlab-orchestrator/scripts/mas_route.m` | +450 / −63，schema 1.1 |
| `skills/matlab-orchestrator/assets/routing.json` | +84 / −2，版本 1.1，依赖与工具箱需求 |
| `skills/matlab-orchestrator/scripts/mas_pipeline.m` | +10，BLOCKED 守卫 |
| `skills/matlab-testing-ci/scripts/mas_grade.m` | +28 / −1，非有限值/非法容差守卫 |
| `skills/matlab-control-optimization/SKILL.md` | +39 / −26，三维契约入口 |
| `skills/matlab-orchestrator/SKILL.md` | +30 / −12，路由契约入口 |
| `skills/matlab-simulink-modeling/SKILL.md` | +28，扰动传播入口 |
| `skills/capability-matrix.json` | +30 / −6，新能力与测试计数 |
| `matlab/validation/phase4/run_all.m` | +3，三个新套件 |

新增文件：

| 文件 | 行数 | 作用 |
|---|---:|---|
| `skills/matlab-control-optimization/scripts/mas_stability_verdict.m` | 238 | 三维稳定性契约 |
| `skills/matlab-control-optimization/tests/test_stability_contract.m` | 228 | 32 例边界测试 |
| `skills/matlab-control-optimization/references/stability-contracts.md` | 88 | 边界表与字段说明 |
| `skills/matlab-simulink-modeling/scripts/mas_dist_enter.m` | 626 | 扰动传播验证 |
| `skills/matlab-simulink-modeling/tests/test_dist_enter.m` | 326 | 19 例（含 4 个真实 `.slx`） |
| `skills/matlab-simulink-modeling/references/excitation-checks.md` | 128 | 链路、配置、记录配方 |
| `skills/matlab-orchestrator/tests/test_routing_contract.m` | 259 | 16 例契约测试 |
| `skills/matlab-orchestrator/references/routing-contract.md` | 139 | schema 1.1 与消费者规则 |
| `matlab/validation/phase52/*.m` | 432 | 哈希、冻结、测量、评分 |
| `matlab/validation/phase52/heldout_reference.json` | — | 7 条留出参考（含 hash） |

证据与结果在 `artifacts/phase52/`（被 `.gitignore` 忽略，不进入提交）：
`evidence/README.md` 是索引，`heldout_results.json` 与
`artifacts/validation/phase52/phase4_all.json` 是机器可读结果。

### 6.2 残余缺陷与风险

| 严重度 | 残余问题 | 说明 / 下一步 |
|---|---|---|
| 中 | 旧字段 `mas_ctrl_analyze.verdict` 在“无 0 dB 穿越”时仍为 `STABLE` | 为兼容保留；新契约要求消费 `mas_stability_verdict`。未迁移的旧调用方仍可能把“数学稳定”当“验收通过”。 |
| 中 | 留出参考 `heldout_reference.json` 在仓库内可读 | C6-09 未解决：Agent 若被允许读取仓库，就能看到答案。真正盲测需把参考移出可读树或只保留 hash。 |
| 中 | 路由仍是词表匹配 | 中文语序、同义词、语义歧义未覆盖（C9-03 仍 OPEN）；`CLARIFY` 可能因缺词而非真歧义。 |
| 中 | Agent 运行时自动触发未测 | Phase 4.3 只证明客户端能发现/加载；本轮没有真实 Agent 对话跑通“自动选 Skill 并执行”。 |
| 低 | `mas_dist_enter` 需要用户提供 `plantParams` / `paramLog` / `disturbanceLog` / `x0` | 无仪器化时只能 UNDETERMINED；没有自动为任意 Simulink 模型插桩。 |
| 低 | Simulink 时间分辨率受求解步长限制 | H5 的 0.01 s 是第一个求解步，不能分辨更细的注入时刻。 |
| 低 | 软工具箱需求不阻塞 | Signal Processing 未许可时只写 notes；这是设计选择，但调用方需阅读 notes。 |
| 低 | 安装器 Pester 套件未跑 | 只做了真实仓库 dry-run；无文件写入，9/9 计划安装。 |
| 低 | 代码生成测试清理时出现路径移除警告 | 非失败，12/12 通过；属于测试清理的噪声。 |
| 信息 | 能力矩阵 14 项 NOT TESTED / 3 项 PARTIAL | 与本轮三个 P0 无关，保留原有状态，未虚报为 VERIFIED。 |

---

## 7. A–E 回答

### A. 是否消除了“数值正确但工程判断错误”的已知缺陷？

**在本轮三个 P0 范围内，是。** 不是全部 18 条 Phase 5.1 缺陷都关闭，而是把其中
最影响工程结论的三类钉住：

- 稳定性：不再用单个 `margin` 值或“MATLAB 跑通”代替闭环结论；无穿越时工程目标为
  `UNDETERMINED`，负增益/DC/离散 Nyquist/多穿越都有专门测试。证据从 8/29 到 32/32。
- 验收：空值、NaN、Inf、非法 reference/tolerance 不再可能“未失败即通过”。
- 扰动：不再从输出曲线推断“扰动进入了对象”；参数、输入、初始状态分别有证据链。
- 路由：不再把“有候选”当成“可执行”；缺依赖/缺工具/坏 Skill 明确 `BLOCKED`。

没有声称“所有缺陷已消除”：旧 `verdict` 字段、词表路由、参考可读性等仍在残余表中。

### B. 是否能够通用地检测扰动未进入实际模型的问题？

**是，前提是模型提供可核对的对象证据。** `mas_dist_enter` 不依赖 Buck/Boost
案例名，也不依赖特定模型文件名；它检查的是角色和数值：对象实际消费了哪些参数、
对象输入信号是什么、内部状态是否变化、变化是否在声明的时间发生、是否与独立预测
一致。19 个测试覆盖 A–E 五类场景和 4 个真实 `.slx` 变体；缺少仪器化时返回
`UNDETERMINED`，不会误报 PASS。它不能自动为任意模型插桩，这是明确的边界。

### C. 是否建立了稳定可复用的 Skills 路由契约？

**是。** schema 1.1 有版本号、`decision`、`primary`、`loadOrder`、`matched`、
`missing`、`reason`、`nextAction` 等字段；`BLOCKED` 时 `loadOrder` 为空；
依赖闭包按拓扑排序；16 个契约测试 + 9 个历史测试 + 15 个流水线任务全部通过。
契约写入 `references/routing-contract.md`，并有消费者伪代码。
它不是语义路由器；词表匹配的局限仍在残余表中，但“输出结构不稳定、消费者靠猜”
这一问题已经关闭。

### D. 哪些能力真实使用 MATLAB 验证，哪些仅完成静态或单元测试？

真实 MATLAB：稳定性分析、扰动传播（含真实 Simulink 模型）、路由与流水线、
冻结参考与篡改攻击、OFDM/图像/机器人/代码生成历史套件、7 条留出案例。
静态/单元/接缝：路由的缺工具箱/未安装/损坏/依赖环、软需求不阻塞、
`mas_grade` 的非有限值守卫。
未测试：Agent 运行时自动触发、Pester 安装器套件、WSL/Linux/macOS、
MATLAB ≤ R2025b、付费模型 Benchmark。详见第 5 节。

### E. 下一轮 Phase 5.3 应优先增强哪些专业领域？

按“能力矩阵中未验证项 × 工程风险”排序，建议：

1. **Simulink 部署链**：Stateflow、Simulink Coder、Simulink Test/覆盖率的真实验证
   （当前均为 NOT TESTED），并复用本轮的 `mas_dist_enter` 证据链。
2. **代码生成正确性**：HDL、STM32、`slbuild` 的固定点/资源/黄金对比，
   把“能生成”与“生成结果正确”分开验收。
3. **信号与视觉的测量契约**：深度学习训练、频谱/窗函数/置信区间，
   避免又一次“FFT bin 读数”式的测量错误。
4. **机器人自主性**：ROS bag、SLAM、UAV 场景，优先建立坐标系与状态估计的
   独立参考，而不是堆案例。
5. **运行时与路由**：真实 Agent 自动触发、R1/R2/R3 基准（需可用后端）、
   语义路由与中文语序；同时把留出参考移出可读树，解决 C6-09。

---

## 8. 停止声明

本轮已完成 P0-A → P0-B → P0-C 的实现、测试、回归、留出验收与报告。
**未修改 `main`，未覆盖 `v0.6.0-preview.2`，未 push/merge/rebase，未发布 Release，
未新增第十个 Skill，未继续开发 Buck/Boost 大型仿真，未调用付费模型。**
工作区保留全部修改与证据，等待审查；没有创建 commit。
