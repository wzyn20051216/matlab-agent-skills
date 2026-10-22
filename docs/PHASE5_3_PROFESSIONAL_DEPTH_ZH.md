# Phase 5.3 — MATLAB Agent Skills 跨领域专业能力增强

日期：2026-10-22 · 分支 `phase5.1-audit` · 基线/冻结提交 `31a152a` · MATLAB `26.1.0.3276743 (R2026a) Update 3`
证据根目录：`artifacts/phase53/`（留出集与逐任务结果在仓库外，见 §6）

## 0. 结论

Phase 5.3 给三个专业域补的不是更多示例，而是**可复用的判定契约**：每个域新增一组
`mas_*` 工具，输入是"声称 + 数据 + 容差"，输出是 `PASS | FAIL | UNDETERMINED`
及逐项证据。三域全部接入统一的
`任务识别 → 能力选择 → 环境检查 → MATLAB 执行 → 独立验收 → 错误恢复 → 结果交付`
流程；验收值来自闭式解、手算代数、第二条数值路线或 MathWorks 独立实现，不来自被测代码。

- 新增 **15 个工具**（signal 4、data 7、robotics 4），累计工具矩阵 **49 个 VERIFIED**。
- 新增 **333 个测试**（42 + 118 + 162 + 11）。
- 全量回归：**644/644** skill tests / **22 suites** / **0 errored**，参考 **15/15**、
  跨域 **15/15**、流水线 **15/15**、自判分歧 **0**，耗时约 **240 s**（5.2 基线为 311/311）。
- 隔离 Benchmark：审计 **7/7**；正式 v2 留出集 **9/9**（route/tool/verdict/fields）、
  false accepts **0**；dev **3/3**；harness 自测 **11/11**。
- **Agent 级能力仍是 `NOT TESTED`（agentRuns=0）**。本轮只报告工具级基线，不把脚本回归
  冒充 Agent Benchmark。
- 未修改 main、未 push、未 merge、未发布 Release、未调用付费模型、未新增大型工程案例。

## 1. 冻结评审与基线

| 项目 | 结果 |
|---|---|
| Phase 5.2 冻结提交 | `31a152a`（本轮未改写） |
| 5.2 回归基线 | 311/311，18 suites，15/15 refs，15/15 cross-domain，15/15 pipeline |
| 冻结区域改动 | `git diff 31a152a -- skills/matlab-control-optimization skills/matlab-testing-ci matlab/validation/crossdomain skills/matlab-simulink-modeling skills/matlab-codegen-deploy skills/matlab-runner` 为空 |
| 冻结参考阈值 | 未修改 `mas_ref_spec.m`、`reference_manifest.json` 或任何 `*.mat` 参考 |
| 失败测试 | 未删除、未跳过；`UNDETERMINED`/`SKIP` 语义保持不变 |
| 环境 | R2026a Update 3；Signal/Statistics/Robotics/Control/Simulink/Navigation/ROS 均可用 |

许可探测按函数而非仅按产品名执行（`mas_dep_probe`，深度模式），"未安装"与"已安装未许可"
保持区分：

| 域 | 代表函数可用 | 缺失 |
|---|---|---|
| signal | 7/7 | — |
| data | 8/8 | — |
| robotics | 8/8 | — |
| control | 4/4 | — |
| simulink | 4/4 | — |

证据：`artifacts/phase53/evidence/task6_license_probe.json`、`task6_license.log`。

## 2. 三个域各自增强了什么

### 2.1 信号处理与数字通信 — 测量契约

工具：`mas_measure_contract`、`mas_filter_check`、`mas_sample_check`、`mas_ber_check`。

覆盖四种此前只会"画图"的声明：

- **频率/功率**：Hz 与 rad/s 双向换算、Nyquist 占比、峰值与 RMS 的
  `rms <= peak` 约束、窗加权功率恒等式。`20*log10` 误用会把 0.5 写成 0.25，
  工具判 **FAIL**；缺容差判 **UNDETERMINED**。
- **滤波器**：`freqz` 与直接 z 展开双路线（一致到 1e-9）；阻带取**全带最差**，
  梳状零点的"指标点读数" 61.79 dB，而真实最差 11.30 dB——只测端点会误判 PASS。
  对称 FIR 才评线性相位；未要求相位的 IIR 记 `na`，不记 FAIL。
- **采样链**：Nyquist 折叠位置显式打印；重建必须有解析真值，记录不匹配真值时
  不给 PASS。
- **BER**：按错误计数构造 z 检验与 Wilson 区间；零错误只给上界，128 bit 零错误
  判 **UNDETERMINED**；Eb/N0 与 Es/N0 的 3.01 dB 约定差被显式检查。

证据：`test_signal_contract.m` **42/42**，旧套件 `test_signal_vision.m` **34/34**。
边界与负例逐条记录在 `references/signal-measurement-contract.md`。

### 2.2 科学计算与数据分析 — 数值可认证性

工具：`mas_quad_check`、`mas_linsolve_check`、`mas_converge_check`、`mas_fit_check`、
`mas_stat_check`、`mas_uncert_check`、`mas_repro_check`。数据清洗复用既有
`mas_table_audit`（11/11），没有另造一套。

- **积分/微分**：两条独立参考路线必须先互相一致，才允许作为参考；声称容差低于
  双精度地板判 **UNDETERMINED**。Simpson 的光滑被积函数实测阶可高于名义阶，
  检查是单边的；带折点函数实测阶 0，判 **FAIL**。
- **线性系统**：后向误差 `||b-Ax||/(||A|| ||x||+||b||)` 与向前界 `kappa*eta` 分开；
  `hilb(12)` 的 `kappa = 1.6344e16`，残差在舍入地板但无可认证有效位，判
  **UNDETERMINED**；秩亏设计矩阵同样不给 PASS。
- **迭代**：阶从 `n/2n/4n` 实测，不从方法名推断；达到
  `100*eps*max(1,e1)` 后阶估计视为噪声，少于三个干净估计判 **UNDETERMINED**。
- **拟合/统计**：t 分位数由 `betaincinv` 得到并与 2.30600413520417 对照；
  Welch 自由度 13.8367；p 值与精确符号翻转/标签置换路线一致才允许声称显著性，
  不一致判 **UNDETERMINED**；`n <= p` 时标准误与 CI 为 **UNDETERMINED**，不是 0。
- **不确定度**：复步微分与中心差分对照；线性传播与 Monte Carlo 超出
  `sigmaTolRel` 判 **FAIL**；MC 噪声过大判 **UNDETERMINED**。
- **可复现**：同种子逐位相等、换种子差异、SHA-256 摘要、RNG 流恢复；声称可复现
  但同种子不一致判 **FAIL**。

证据：`test_data_contract.m` **118/118**；边界逐条记录在
`references/data-verification-contract.md`。

### 2.3 机器人与机械工程 — 从"跑通"到"身份成立"

新工具：`mas_quat_check`、`mas_traj_check`、`mas_dyn_check`、`mas_estimate_check`。
与既有 `mas_frame_check`、`mas_kin_check`、`mas_kin_ik`、`mas_ekf_check` 组成
运动学—动力学—估计的闭环。

- **四元数**：单位范数、双覆盖 `q ≡ -q`、最短弧 SLERP 对闭式解；非单位四元数
  与"单位阵轴角"分别处理，后者轴不唯一，判 **UNDETERMINED**；有 Robotics 工具箱时
  与 `quat2rotm`/`rotm2quat` 交叉对照，没有则 `crossCheck.checked=false`，不伪造。
- **轨迹**：0.1 的航点漏检、采样极值与认证极值分开；解析导数对五点内点差分；
  非均匀/过短记录判 **UNDETERMINED**。
- **动力学**：`M` 由动能构造，`C` 由 Lagrange 恒等式与斜对称性双查，`g` 由势能梯度；
  RK4 能量漂移 **6.5e-12**。翻转 Coriolis 符号的模型泄漏 **0.32**，判 **FAIL**。
- **估计**：记录型数据上的 NEES 同时给"全样本均值"和"逐步跨运行均值"两个分母；
  协方差先做对称/正定卫生检查，再算 NEES；5 次运行或 4 步记录判 **UNDETERMINED**。
  新息白化按 family-wise 阈值（`alpha=0.05` 时约 **0.0444**），偏差单独报告。
- **IK**：DLS 步长有界；近奇异 `q2=1e-4` 时 DLS 原始步长 0.12，而正规方程
  `(J'J)\J'e` 达 **6.4e3**。`stepRawMax` 仍如实返回，因为隐藏它就隐藏了"构型很差"。

证据：`test_robotics_contract.m` **162/162**，旧套件 `test_robotics.m` **31/31**。
契约细节在 `references/robotics-verification-contract.md`。

## 3. 统一工作流（Task 4）

三个 SKILL.md 都按同一七步组织，且复用编排层工具，不各自实现路由/预检/评分：

| 步骤 | 三域共同做法 |
|---|---|
| 1 任务识别 | 明确量、单位、容差、可选独立真值；没有容差就没有 PASS |
| 2 能力选择 | `mas_route(prompt)`；只读被路由到的工具契约 |
| 3 环境检查 | `mas_precheck`；缺工具箱显式降级，不偷换方法 |
| 4 MATLAB 执行 | 先小记录/小子集，保存中间量 |
| 5 独立验收 | 工具判定 + 第二条路线；`mas_grade`/`mas_refcheck` 用于冻结参考 |
| 6 错误恢复 | 按 `fail`/`UNDETERMINED` 的具体原因补证据后重跑，不跳过 |
| 7 结果交付 | 数值、容差、条件数/不确定度、判定；SKIP/BLOCKED 不改写 |

复用清单：`mas_route`、`mas_precheck`、`mas_grade`、`mas_refcheck`、
`mas_stability_verdict`、`mas_dist_enter`。

路由只增加**领域词汇**（如 `主频`、`功率谱`、`采样定理`、`数值精度`、`条件数`、
`四元数`、`动力学`、`状态估计`、`fmincon`），没有把任何测试任务名写进路由器。
Task 3 的 9 条机器人提示全部路由正确；Task 2 的 6 条数据提示全部路由正确，
控制提示仍归 control；统一 sweep **247/247**，15 任务流水线 skill match **15/15**。

## 4. 独立数值验收（不是"图对了"）

| 域 | 被验收的声明 | 独立来源 | 结果 |
|---|---|---|---|
| signal | 50 Hz 主频与 0.5 线性功率 | 窗加权功率恒等式、块 t 区间 | PASS；20log10 陷阱 FAIL |
| signal | 128 bit 零误码 | Poisson 零事件上界 | UNDETERMINED，不是 PASS |
| data | `∫₀¹ 4/(1+x²) = π` | 两条求积路线 + 闭式 π | PASS；折点 Simpson 阶 0 FAIL |
| data | `hilb(12)` 解的精度 | 后向误差 + `kappa*eta` | UNDETERMINED（`kappa=1.63e16`） |
| data | 两样本显著性 | t 分布 + 精确置换 | 一致才 PASS；不一致 UNDETERMINED |
| robotics | 四元数组合/插值 | 矩阵乘积、闭式 SLERP | PASS；非单位 q 被纠正/标注 |
| robotics | 平面二连杆 `M,C,g` | 动能、斜对称、Lagrange、势能梯度 | PASS；C 符号错 FAIL（泄漏 0.32） |
| robotics | 滤波器一致性 | NEES 双侧卡方带 + 白化 | 正确 1.92 PASS；R/100→107、R×100→0.81 FAIL |

全量冻结参考：**15/15** 通过 `mas_refcheck('verify')`；跨域 **15/15** 由
`mas_verify_task` 对照冻结参考评分，未使用任务自报的 `out.status`。

## 5. 失败与恢复记录

1. **隔离 Benchmark v1 pilot：7/9**。两处失败均为**基准规格错误**，不是工具错误：
   - `mas_measure_contract.freqHz` 回显的是"声称频率"，测量值在 `measured.fPeak`；
   - 一个边界任务的容差被误写得比"手算参考 vs 实测"的差异更紧（具体数值见
     评测侧 v1 证据，不进入仓库）。
   未改任何工具；v1 任务/答案/清单/结果保留，正式 v2 重新冻结后 9/9。
2. **并发全量回归出现 641/643**：`codegen 10/12`，且 G1 自判 FAIL/验证器 PASS，
   `selfDisagreement=1`。根因是两个 MATLAB 进程同时运行 `run_all`，共用
   `skills/matlab-codegen-deploy/tests/fixtures_codegen`，其中一个的 `onCleanup`
   在另一个执行中删除了夹具目录（日志有明确警告）。
   单进程重跑 `test_codegen 12/12`、全量 **643/643**、`selfDisagreement=0`。
   这是测试夹具的并发缺陷，不是产品回归；本轮不修改该冻结测试，列为残余风险。

## 6. 隔离式 Benchmark（Task 5）

### 6.1 隔离约定

1. Agent 可见仓库只含 **dev** 集；正式留出集在仓库外
   `E:\desktop\MATLAB-bench-holdout-phase53`。留出集的 id、fixture、prompt 与
   参考值只存在于评测侧，仓库文档不枚举。
2. 参考答案与评分器只在评测侧；runner 只收到 `tasks.json`。
3. 评测前 `benchmark_freeze` 写 SHA-256 清单；评分器发现 tasks/answers 变更即拒绝。
4. dev 与 holdout 的 id 不相交；审计检查路径包含、冻结哈希、逐字节答案副本、集合完整性。
5. 完整证据：`input_<id>.mat`、`output_<id>.mat`、`trajectory_<id>.jsonl`、
   `result_<id>.json`（含输入/结果 SHA-256）。
6. 无真实 Agent episode 时，`baseline` 明确写
   `tool-level scripted policy (NOT an Agent benchmark)`，`agentRuns=0`、
   `agentLevel='NOT TESTED'`。

留出集的逐任务结果默认写到 `<holdout root>/runs/latest`，**不进入仓库**：评分结果
带有期望 verdict，放进工作区会削弱隔离。仓库仅保留聚合
`artifacts/phase53/benchmark/task5_summary.json` 与 `isolation_audit.json`。

### 6.2 结果

| 项目 | 结果 |
|---|---|
| 隔离审计 | **7/7**：holdoutOutsideRepo、filesExist、answersHash、tasksHash、noAnswerCopy、devHoldoutDisjoint、holdoutComplete |
| 正式 v2 留出集 | **9/9** tasks；route 9/9、tool 9/9、verdict 9/9；false accepts **0** |
| 覆盖 | signal/data/robotics × normal/boundary/fault |
| dev 自测 | **3/3**（公开答案，仅用于开发 harness） |
| harness 独立测试 | **11/11**：冻结哈希、答案副本告警（含隐藏目录）、干净审计、3/3 评分、tool-level 标签、篡改拒绝、缺失结果计失败、错误 verdict/字段超差均不能通过 |
| Agent 级 | **NOT TESTED**（未运行独立 agent episode） |

v2 冻结哈希：

- tasks `79b328f998e19e107651a32e650501ef8bcaad4443289c6cac525c61d5719cdd`
- answers `f4134974ff1549d9315b5ea08bbabfba4e22ae7ca488219ecf519eb8d0b61517`

v1 pilot 与逐任务轨迹保存在
`E:\desktop\MATLAB-bench-holdout-phase53\runs\v1_pilot\`、`runs\latest\`；
复跑命令 `run_holdout` 在 2026-10-22 再次得到 9/9。

**边界声明**：这是程序性隔离，不是操作系统沙箱；知道绝对路径的进程仍可读答案。
本轮能证明的是"交给 agent 的工作区不含答案，且评分器校验冻结"，不能证明
"任何进程都无法访问"。

## 7. 全量回归（Task 6）

命令：`matlab -batch "run_full_regression"`，新进程、单实例、串行。
日志：`artifacts/phase53/evidence/full_suite_after.log`；
结构化结果：`full_suite_after_summary.json`。

| suite | 通过/总数 | suite | 通过/总数 |
|---|---:|---|---:|
| routing | 9/9 | dataContract | 118/118 |
| precheck | 16/16 | signalVision | 34/34 |
| depProbe | 26/26 | signalContract | 42/42 |
| grading | 6/6 | robotics | 31/31 |
| phase43Grade | 43/43 | roboticsContract | 162/162 |
| refcheck | 11/11 | benchmarkHarness | 11/11 |
| bench | 9/9 | codegen | 12/12 |
| capability | 7/7 | tableAudit | 11/11 |
| skillGraph | 13/13 | modelCheck | 2/2 |
| ctrlAnalyze | 14/14 | stabilityContract | 32/32 |
| distEnter | 19/19 | routingContract | 16/16 |

合计 **644/644**，22 suites，0 errored；参考 **15/15**、跨域 **15/15**、
流水线 **15/15**、`selfDisagreement=0`；耗时约 **240 s**。
相对 5.2 的 311/311：新增 4 个 suite、333 个测试，旧 suite 与冻结阈值全部保持。

## 8. 能力矩阵更新

机器可读矩阵 `skills/capability-matrix.json`（由 `mas_capability_check.m` 计算，
`capability` suite 7/7 校验计数不漂移）：

- 能力：**52 VERIFIED / 14 NOT TESTED / 3 PARTIAL**（5.1 时为 37/14/3）。
- 工具：**49 VERIFIED**（5.1 时为 34）。
- `autonomousExecution` 新增 `isolatedBenchmark`：状态 **VERIFIED**，但 scope 明确
  为 **tool-level only**，`agentLevel=NOT TESTED`。

领域级（13 域）只按证据升级，不过度声称：

| 领域 | 5.1 | 5.3 | 依据/仍缺 |
|---|---|---|---|
| 数学与科学计算 | PARTIAL | PARTIAL | 积分/微分/线性系统/迭代/统计已 VERIFIED；ODE、符号计算仍无契约 |
| 统计分析与数据可视化 | PARTIAL | PARTIAL | 检验/拟合/不确定度/复现已 VERIFIED；图件本身仍无验收 |
| 信号处理与数字通信 | VERIFIED | VERIFIED（加强） | 测量/滤波/采样/BER 契约补齐 |
| 图像处理与 CV | PARTIAL | PARTIAL | 仍只有二值掩码指标 |
| 机器学习与深度学习 | NOT TESTED | NOT TESTED | 无训练/推理验证 |
| 机器人、ROS 与自主导航 | PARTIAL | PARTIAL（加强） | 机械臂运动学/动力学/估计已 VERIFIED；ROS bag、SLAM、规划、UAV 未测 |
| 机械动力学与多体系统 | NOT TESTED | **PARTIAL** | 平面刚体动力学 `mas_dyn_check` 已验证；多体/Simscape 仍未测 |
| 自动控制与系统辨识 | PARTIAL | PARTIAL | 频域/PID 已验证；系统辨识、MPC 未测 |
| 电力电子与电机控制 | PARTIAL | PARTIAL | 仓库案例仍承担主要证据 |
| Simulink | VERIFIED（核心） | VERIFIED（核心） | 未改 |
| 代码生成与部署 | PARTIAL | PARTIAL | 未改 |
| 科学实验与论文复现 | PARTIAL | PARTIAL | 数值复现增强，图件复现仍缺 |
| 数值优化与方程求解 | PARTIAL | PARTIAL | `fsolve` 可路由；约束优化无独立验收契约 |

## 9. 精确 Git Diff

基线 `31a152a` → 本轮提交（分支 `phase5.1-audit`，不 push / 不 merge / 不改 main）：

**修改**

- `matlab/validation/phase4/run_all.m`：注册 `dataContract`、`signalContract`、
  `roboticsContract`、`benchmarkHarness`，并加入 `benchmark`/`benchmark/tests` 路径。
- `skills/capability-matrix.json`：三域能力/工具条目、`isolatedBenchmark`、计数与说明。
- `skills/matlab-orchestrator/assets/routing.json`：三域词汇；无任务名硬编码。
- `skills/matlab-signal-vision-ai/SKILL.md`、`skills/matlab-data-analysis/SKILL.md`、
  `skills/matlab-robotics-autonomy/SKILL.md`：七步流程、工具契约、边界规则。
- `docs/PHASE5_1_CAPABILITY_MATRIX_ZH.md`：加历史快照指针，不改旧结论。

**新增**

- 15 个工具脚本：signal 4、data 7、robotics 4。
- 4 个测试：`test_signal_contract.m`（42）、`test_data_contract.m`（118）、
  `test_robotics_contract.m`（162）、`benchmark/tests/test_benchmark_harness.m`（10）。
- 3 份 reference：signal/data/robotics verification contract。
- `benchmark/`：`benchmark_freeze.m`、`benchmark_run.m`、`benchmark_grade.m`、
  `benchmark_audit.m`、`benchmark_fixtures.m`、`run_holdout.m`、`README.md`、
  `dev/tasks.json`、`dev/answers.json`、`dev/manifest.json`、harness 测试。
- `matlab/validation/phase53/`：许可探测与模型探测。
- `artifacts/phase53/`：各任务探测/证据脚本、日志、benchmark 聚合结果；
  逐任务留出结果在仓库外。

## 10. 残余缺陷与未验证项

1. **Agent 级 Benchmark 未运行**：`agentRuns=0`，不能据此声称自主选技能/纠错能力。
2. **平台单一**：只在 R2026a Update 3 / Windows 上验证；其他 MATLAB 版本未测。
3. **留出集规模小**：9 个任务、单机，统计意义有限；不能外推为通用能力分数。
4. **`run_all` 非并发安全**：共享 `fixtures_codegen` 会导致假失败（见 §5.2）；
   必须单实例串行运行。
5. **领域缺口**：ROS bag/SLAM/路径规划/UAV、深度学习训练、图像检测分割、
   ODE/符号计算、系统辨识/MPC、图件复现均仍为 NOT TESTED。
6. **隔离是程序性的**：无 OS 级沙箱；绝对路径仍可被有权限的进程读取。
7. `hilb(12)` 运行中的"矩阵接近奇异"警告是预期输入性质，工具正确返回
   UNDETERMINED；未屏蔽。
8. dev 集答案公开是设计选择；正式评分只使用仓库外冻结的 holdout。

## 11. 下一批建议（不新增大型案例）

1. **真实 Agent episode**：只给 9 条 prompt，不给 `report`/答案，用同一冻结清单评分；
   报告 `agentRuns`、false accepts、失败恢复轨迹，才可称 Agent Benchmark。
2. **让 `run_all` 并发安全**：把 `fixtures_codegen` 移到 `tempname`，加一个
   "fixture 不在仓库内"的测试；这是纯测试基础设施修改，不动产品阈值。
3. **ROS bag/状态估计契约**：用一段可复现的小 rosbag 验证 frame/时间戳/协方差，
   没有数据则 SKIP，不伪造。
4. **ODE/符号计算契约**：`ode45` 收敛阶/能量守恒 + `syms` 闭式对照，补数学域的
   最后一个大缺口。
5. **控制域系统辨识/MPC**：先做可辨识性检查与闭环约束可行性，再谈性能。

## 12. 复现

```matlab
% 全量回归（单实例！）
cd('E:/desktop/MATLAB/artifacts/phase53');
run_full_regression

% 三域契约（各自独立）
addpath('E:/desktop/MATLAB/skills/matlab-signal-vision-ai/tests');   test_signal_contract
addpath('E:/desktop/MATLAB/skills/matlab-data-analysis/tests');      test_data_contract
addpath('E:/desktop/MATLAB/skills/matlab-robotics-autonomy/tests');  test_robotics_contract

% 隔离 Benchmark（结果写到评测侧 <root>/runs/latest）
addpath('E:/desktop/MATLAB/benchmark');
run_holdout
```

所有 PASS 都对应一个可失败的检查；所有 UNDETERMINED/SKIP 都保留原因，
没有被改写成 PASS。
