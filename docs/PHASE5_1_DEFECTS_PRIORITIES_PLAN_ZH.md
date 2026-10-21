# Phase 5.1 — 缺陷、优先级、Benchmark 设计与 Phase 5.2 计划

日期：2026-10-21 · 基线 `v0.6.0-preview.2`（`0c5fa84`）· 分支 `phase5.1-audit`
证据：`artifacts/phase51/defect_archaeology.md`（123 条缺陷）、`skill_survey.md`、`skill_suite_results.tsv`、
`skill_probe.json`、`route_probe.txt`、`matlab_env.json`

---

## 1. Task 2 — 真实工程错误的分类与可泛化性

### 1.1 分类计数（来自证据，非估计）

| # | 类别 | 条数 |
|---|---|---|
| 1 | MATLAB API 用错（参数序、语义、选项名） | 21 |
| 2 | 参数/数据结构传递错误（形状、字段、单位） | 14 |
| 3 | Simulink 端口/模块配置错误 | 9 |
| 4 | 扰动没有真正进入模型 | 7 |
| 5 | 数值正确但工程判据错误 | 18 |
| 6 | 参考答案本身错误 | 10 |
| 7 | MATLAB 版本/工具箱/宿主差异 | 12 |
| 8 | 非物理或发散结果被当成正确 | 4 |
| 9 | 技能路由错误/不必要加载 | 10 |
| 10 | 错误恢复没有重新验证结果 | 18 |
| | **合计** | **123** |

**状态（来自逐条证据）**：FIXED **110** / OPEN **10** / PARTIAL 1 / UNSUPPORTED 1 / DEFERRED 1。
这说明仓库**很会记录修复、但不擅长把修复提升成可复用检查**——这正是 Phase 5.2 要改的。

### 1.2 三个主导家族（决定优先级）

1. **测量/判据错误（C5+C6=28）**：数字对，问题错。例：`margin()` 返回值顺序被读错
   （`CHANGELOG.md:111`，PM 报 1.997° 而真值 89.45°）；把 `Wcg` 当成交越幅值算出 −70 dB。
2. **静默成功与不复核（C10=18）**：产物没生成却报"已生成"；恢复后不重跑验证。
   例：`boost_b1_task6_agent.m` 把"首次成功率 0"**手打**成字段当测量值。
3. **静默形状/掩码/API 语义误用（C1+C2=35）**：MATLAB 不报错，返回一个"看起来合理"的错误子集。
   例：`exist(name,'file')==2` 把内置函数当不存在（C1-10/C1-21）；逐周期掩码套到细网格上
   只索引前 N 个点（C2-01，实测 0.647 V 误差）。

### 1.3 最值得转成通用能力的缺陷（Top 8）

| # | 缺陷（证据） | 通用检查（可复用、非硬编码） |
|---|---|---|
| G1 | `margin()` 返回序读错（`CHANGELOG.md:111`） | **返回值契约检查**：对已知系统断言 `[Gm,Pm]` 数值范围与符号；测 PM 时同时用 `allmargin` 交叉核对 |
| G2 | 把 `Wcg` 当幅值、`angle()` 折叠致 PM 假 +83°（C1-02/C1-16） | **交叉点一致性**：同一穿越点的 (频率, 幅值, 相位) 必须满足 |L|=1；PM 用 unwrap 后相位 |
| G3 | 离散系统在 `s` 而非 `z` 上求值（C1-18） | **域检查**：`Ts>0` 系统必须用 `z=e^{jωTs}`；与 `bode` 结果对照 |
| G4 | 扰动/负载阶跃没进入被控对象（C4，3 次跨 Buck/Boost） | **激励可达性检查**：注入已知幅值的阶跃，量测点必须看到对应稳态增量（`Δy/Δu` 与解析增益一致） |
| G5 | 逐周期掩码套细网格（C2-01） | **形状/时间基检查**：掩码长度必须等于该周期采样数；否则报错而不是静默截断 |
| G6 | 参考值本身错（C6=10） | **参考独立推导**：每个基准值至少两种互不依赖的方法（闭式/数值/量纲），差异超容差即拒绝 |
| G7 | 非物理结果被接受（C8-04：慢发散只掉 −2.28%） | **物理性边界**：能量/幅值/时间常数落在可解释区间；趋势检查（连续 N 步单调发散即失败） |
| G8 | 恢复后不复核（C10=18） | **恢复后重测**：任何 retry/回退后必须重跑同一判据并保留前后哈希 |

**建议落成的脚本名（Phase 5.2 命名）**：
`mas_broadcast_guard`（隐式扩展/形状子集）、`mas_dist_enter`（扰动可达 + "过于理想"哨兵）、
`mas_stability_verdict`（把 buck 里仅限本案例的 Floquet/有界判据提升为通用三级判定）、
`mas_absence_verdict`（"缺证据"不得等于 PASS）、`mas_settle` / `mas_fft_verify` / `mas_window_covers_signal`
（测量定义）、`mas_atomic_publish`（写入后逐文件复核，防"静默成功"）。
其中 `mas_precheck('index')`、`mas_refcheck` 已存在且质量高，应**复用而不是重写**。

### 1.4 硬编码修复反模式（必须避免重犯）

| 反模式 | 证据 | 正确做法 |
|---|---|---|
| 把测量值手打进报告 | `boost_b1_task6_agent.m` 硬编码"首次成功率 0"（C10-15） | 由脚本写 JSON，报告只读 |
| SKILL.md 写死 MATLAB 版本 | `matlab-orchestrator` / `matlab-runner` 硬编码 `R2026a`（C7-09） | 运行时探测 `version('-release')` |
| 为单一案例加特例分支 | 多处（如 `mas_precheck` 的 `exist==2` 与 `mas_dep_probe` 的修法不一致，C1-21） | 抽成一个共用依赖探测函数，全仓库单一实现 |
| 用"能跑"当验收 | `mas_model_check` L3 = 信号有限；`test_codegen` 无 codegen 时 `return true` | 判据必须对照独立值；缺依赖时标 SKIP 而不是 PASS |
| A1 特例守卫只重演一次历史设计 | `selfcheck_notch_equivalence.m:9-10,40-43` 钉死 `fn=5504.8/zn/zd/Kp/Ki` | 守卫应参数化到"任意陷波设计"，而非复刻单一案例 |
| A2 枚举式正则 | 盘符正则只列 `[ED]:`（`PHASE4_4_1:42`），C:/F: 未覆盖 | 用谓词/白名单而不是枚举 |
| A3 证据门禁绑定单一构建 | Desktop 门禁硬编码 `source=='vscode'` 与某引擎版本 | 按语义字段判定，版本作为参数 |
| A4 手打测量值 | `boost_b1_task6_agent.m` 硬编码"首次成功率 0" | 由脚本写 JSON，报告只读 |
| A5 字面 true | `matlabValidation.passed=$true` | 由实际检查结果生成 |
| A6 参考规则绑死文件名 | v1 benchmark 规则写死模型文件名 | 用结构/内容识别，不绑名字 |
| A7 文档写死 commit SHA | 已由 `c406cc0`/`22b4cd2` 修 | 引用 tag 而非 SHA |
| A8（可接受）| Pester 固定 3.4.0 | 有理由且有测试，记录为"有意的约束" |

### 1.5 仍未关闭（保持可见）

| ID | 问题 | 状态 |
|---|---|---|
| C1-21 | `mas_precheck` 仍用 `exist(name,'file')==2`，与已修的 `mas_dep_probe` 不一致 | **OPEN** |
| C5-18 | `mas_ctrl_analyze` 对"无 0 dB 穿越"的环返回 `STABLE` 且 `pmWorst=NaN` 无解释（本轮实测） | **OPEN** |
| C6-09 | `evals/` 把 held-out 参考答案以字面量公开，被测 Agent 可读 | **OPEN** |
| C7-11 | Simscape Electrical `Switch` 端口语义在 `-batch` 下无法可靠判定 | **DEFERRED** |
| C7-12 | CLI 0.147.0 与 Desktop 引擎 0.163.0-alpha 证据不可互相替代 | **OPEN（流程约束）** |
| C8-04 | 慢发散（每 120 ms 增长 1.03）只掉 −2.28%，看起来"正常" | **OPEN** |
| C9-03 | 中文语序导致子串匹配失败（"代码生成" vs "生成 C 代码"） | 部分修复，路由仍 6/15 CLARIFY |
| C9-04 | `matlab-runner` 对所有 prompt 强制加载，属设计选择但放大了 token 成本 | 设计如此，记录 |
| C9-10 | `mas_route` **没有文档化的输出契约**：本轮我用 `r.skills/matched/missing` 绑定，12/12 全部 `<unexpected>`，改用 `decision/primary/loadOrder` 才正确 | **OPEN（文档缺陷）** |
| B7 / ComDesktop / R1R2R3 | holder bootstrap 未证 / COM 模式 UNSUPPORTED / 增益未测 | 延续 4.6 结论 |

---

## 2. Task 3 — 能力优先级（P0/P1/P2）

评分维度：A 通用性、B 当前支持度、C 工程风险、D 跨域复用、E 额外许可证、F 实现成本、G 可独立验证（1–5，5 最优；C 越高风险越大）。

| 优先级 | 能力 | A | B | C | D | E | F | G | 结论 |
|---|---|---|---|---|---|---|---|---|---|
| **P0** | 测量/判据契约检查（G1–G3、G6） | 5 | 3 | 5 | 5 | 5 | 4 | 5 | 缺陷最大来源（28），纯基础 MATLAB，可独立验证 |
| **P0** | Simulink 激励可达性 + 物理性检查（G4、G5、G7） | 5 | 2 | 5 | 4 | 5（Simulink 已有） | 3 | 5 | 工程风险最高、目前无任何通用检查 |
| **P0** | 自测入门禁 + 可移植性修复（G8、空转测试、`exist==2`、版本硬编码） | 5 | 4 | 4 | 5 | 5 | 5 | 5 | 让 244 条断言真正受保护；成本最低 |
| **P1** | 路由缺口补齐（FFT/混叠、约束优化、论文图表、电力电子） | 5 | 4 | 2 | 4 | 5 | 5 | 4 | 6/15 CLARIFY 里 4 条本可接住 |
| **P1** | references 渐进式加载（8 个技能） | 4 | 2 | 1 | 4 | 5 | 2 | 3 | 结构债；SKILL.md 最长 9.3 KB |
| **P1** | 深度学习最小工作流（训练/推理/混淆矩阵） | 4 | 1 | 2 | 3 | 4（DL 已许可） | 2 | 3 | 描述已承诺（O1），需实现否则降级表述 |
| **P1** | 系统辨识 / 状态空间辨识（`iddata`/`tfest`） | 4 | 1 | 3 | 3 | 4（SID 已许可） | 3 | 4 | 控制域自然延伸 |
| **P2** | ROS bag / 导航 / SLAM | 3 | 1 | 3 | 2 | 3 | 1 | 2 | 需 ROS 环境，验证成本高 |
| **P2** | Stateflow / Simscape / 覆盖率 | 3 | 1 | 2 | 2 | 3 | 2 | 3 | 描述已承诺（O6） |
| **P2** | HDL / STM32 目标链 | 2 | 1 | 3 | 1 | 2（HDL 已许可，硬件无） | 1 | 2 | 需硬件/目标链；标 SKIP 优先 |
| **P2** | 电力电子技能化（把仓库案例升为技能能力） | 3 | 2 | 4 | 2 | 4 | 2 | 4 | 已有案例，迁移成本中等；避免挤占通用能力 |

**排序原则落实**：P0 全部是"跨领域 + 基础 MATLAB/Simulink + 可独立验证"的能力；
电力电子虽有大量案例，但只排 P2，避免挤占其他领域（符合本轮要求）。

---

## 3. Task 4 — 可复用工作流的统一骨架（供 5.2 实现）

每个能力必须能走完这条链，且每一步有"可检查的产物"：

```
自然语言触发
 → Skill 路由（mas_route；低于阈值 CLARIFY，不猜）
 → 环境探测（mas_precheck/mas_dep_probe：版本、工具箱 feature、依赖）
 → 建模/算法设计（技能脚本）
 → MATLAB 执行（MCP，带超时与日志）
 → 结果验证（独立参考：闭式/数值/量纲/物理边界；禁止用被测代码自证）
 → 失败诊断（错误分类：API/形状/端口/激励/判据/参考）
 → 安全恢复（重试前记录哈希；恢复后重跑同一判据）
 → 工程交付（JSON + 图 + 复现命令 + 已知限制）
```

规则：主 SKILL.md 只留触发、路由、验收与"何时加载哪个 reference"；专业知识进 `references/`；
**能自动检查的规则必须落成脚本 + 测试**，不允许只写在 SKILL.md 里。

---

## 4. Task 5 — 独立 Benchmark 设计（本轮只设计，不虚报结果）

### 4.1 任务集（15 题：10 dev + 5 held-out）

覆盖 10 个不同领域，每题带三类输入：**正常 / 边界 / 故意错误**。

| ID | 领域 | 任务 | 依赖 | 参考来源（独立） |
|---|---|---|---|---|
| D1 | 信号处理 | 单音频谱泄漏与集中度 | 基础 | Parseval + 解析泄漏 |
| D2 | 数字通信 | QPSK-OFDM BER vs 闭式 | 基础 | `0.5*erfc(sqrt(Eb/N0))` |
| D3 | 图像 | 二值分割 IoU/Dice | 基础（`bwlabel`） | 手算混淆矩阵 |
| D4 | 控制 | 多穿越裕度与稳定判定 | Control | 解析传递函数 + `allmargin` |
| D5 | 控制 | PID 带宽最大化受裕度约束 | Control/Optimization | 参数扫描 + 解析边界 |
| D6 | 机器人 | 平面 n-R FK/Jacobian | 基础 | 解析 FK + 中央差分 |
| D7 | 电力电子 | Buck 纹波与穿越频率 | Simulink | 解析小信号模型 |
| D8 | Simulink | 一阶热系统阶跃 | Simulink | `1-exp(-t/tau)` |
| D9 | 数据 | 表格清洗行会计 | 基础 | 行数守恒恒等式 |
| D10 | 统计 | 回归 + 缺失数据 | Statistics | 闭式 OLS |
| H1 | 信号 | FIR 指标验收（通带/阻带） | Signal | 设计规格解析界 |
| H2 | 优化 | 约束参数估计 | Optimization | KKT 解析解 |
| H3 | 多体 | 两连杆动力学能量守恒 | 基础 | 能量守恒 + 解析力矩 |
| H4 | 代码生成 | MEX golden 对照 | MATLAB Coder | 双实现交叉 |
| H5 | 实验复现 | 图表/数值/文本三对齐 | 基础 | 冻结 manifest |

### 4.2 每题的"错误输入"（故障注入，必须有）

单位错（ms vs s）、形状错（行/列向量）、掩码/时间基错、端口符号错、Step Time 错、
空信号、参考值被篡改（哈希变化）、发散参数、超容差但"看起来平滑"的结果。
每题至少 2 个故障变体，且**必须能被判据拒绝**（否则该判据无效）。

### 4.3 评分协议（离线、可独立复核）

| 指标 | 定义 |
|---|---|
| `firstPass` | 无人工干预首次是否通过 |
| `finalPass` | 允许自修复后的最终结果 |
| `selfRepairs` | 诊断→修复循环次数 |
| `falseAccept` | 结果错误但被判据接受（**最关键，越低越好**） |
| `skipHonesty` | 无法执行时是否标 SKIP 而非 PASS |
| `reproducible` | 同命令重跑结果一致（含随机种子） |

冻结方式：任务 + 参考答案 + 容差 + 故障变体全部 SHA-256 冻结（`freeze_manifest.json`）；
参考答案放独立目录，**不进入被测 Agent 可见路径**；评分器只读冻结文件，拒绝即时报错。

### 4.4 R1/R2/R3 对照

- R1 = 不加载技能；R2 = 加载技能；R3 = 技能 + 脚本工具。
- **约束**：客户端未暴露"技能被自动加载"的事件，因此**不允许**把推断写成事实。
- 本轮结论：**Agent 端 R1/R2/R3 = BLOCKED**（无可用客户端会话）；离线评分器与冻结参考可以先跑通并
  自检（合成用例），这部分不依赖 Agent。

### 4.5 SKIP 规则

无法执行的条件（缺工具箱 feature、缺硬件、客户端不可用）→ 标 `SKIP` 并写明原因，
**不得**把 SKIP 计为 PASS；汇总时 SKIP 单独成列。

---

## 5. Task 6 — Phase 5.2 第一批（三个模块）

### P0-A：测量/判据契约（Measurement & Criterion Contract）

- **当前真实缺陷**：C1-01/C1-02/C1-16/C5-18 等 28 条；`mas_ctrl_analyze` 的 NaN 无解释；
  判据与测量混为一谈（数值对、问题错）。
- **用户会遇到的问题**：Agent 报"相位裕度 1.997°，稳定"，实际 89.45°；或把"没有穿越"报成"稳定"。
- **计划增强的技能**：`matlab-control-optimization`（主）、`matlab-testing-ci`（判定协议）。
- **新增 references/scripts/tests**：
  - `references/measurement-contracts.md`（每个量的定义、单位、返回序、无效情形）
  - `scripts/mas_measure_check.m`（对一组已知系统断言 Gm/Pm/crossover 的一致性与符号）
  - `tests/test_measure_check.m`（含"无穿越""多穿越""离散系统"三类负例）
- **最小可执行任务**：给定 5 个已知传递函数，输出每个的 PM/GM/穿越点，并与 `allmargin` + 解析值对齐。
- **修复前后对照**：同一批系统，改前只报 verdict；改后报"测量值 + 判据 + 无效原因(notes)"。
- **成功标准**：`test_measure_check` ≥ 15 条断言全过；对无穿越系统返回 `verdict='UNDETERMINED'` 而非 `STABLE`；
  并把"缺证据"统一走 `mas_absence_verdict` 的三值逻辑（PASS/FAIL/UNDETERMINED）。
- **改动范围/风险**：2 个技能、~400 行、无安装器改动；风险是与既有 `mas_ctrl_analyze` 契约兼容（保持旧字段，新增字段）。

### P0-B：Simulink 激励可达性 + 物理性（Excitation & Physicality）

- **当前真实缺陷**：C4（扰动没进模型，跨 Buck/Boost 3 次）、C8-04（慢发散被忽略）、C2-01（掩码形状静默截断）。
- **用户会遇到的问题**：仿真"跑完了、曲线平滑"，但被控对象根本没被扰动；或发散被当稳定。
- **计划增强的技能**：`matlab-simulink-modeling`（主）、`matlab-runner`（预检）。
- **新增 references/scripts/tests**：
  - `references/excitation-checks.md`（阶跃/扰动/负载的可达性判据）
  - `scripts/mas_dist_enter.m`（注入已知幅值；检查阶跃**符号/幅度**、量测 Δy/Δu 与解析增益一致、
    "过于理想"哨兵：若扰动后响应与未扰动几乎相同则判失败；同时校验 Step 块参数名 `Time` 而非 `StepTime`）
  - `tests/test_dist_enter.m`（反例：Buck 阶跃反向 6Ω→18Ω、Boost 的 R 根本没传入、StepTime 拼错、信号为空）
- **最小可执行任务**：对一阶系统 `.slx` 注入 10% 负载阶跃，验证量测点稳态增量在容差内。
- **成功标准**：正例通过；三个反例全部被拒（不能只是"不报错"）。
- **改动范围/风险**：1 个技能 + 1 个脚本；仅 Simulink，回归风险局限在 MATLAB 层。

### P0-C：自测入门禁 + 可移植性修复

- **当前真实缺陷**：244 条技能自测无 runner/CI 调用；`test_codegen` 缺 codegen 时空转 12/12；
  `mas_precheck` 仍用 `exist==2`（C1-21）；SKILL.md 硬编码 R2026a（C7-09）。
- **用户会遇到的问题**：装机后"测试全过"但什么都没测；不同 MATLAB 版本上 skill 文本直接错。
- **计划增强的技能**：`matlab-testing-ci`（主）、`matlab-runner`。
- **新增 references/scripts/tests**：
  - `scripts/run_skill_suites.m`（汇总 15 个套件，输出 JSON：pass/fail/skip + 原因）
  - 顶层 `tests/SkillSuites.Matlab.Tests.ps1`（MATLAB 层 Pester 包装，未装 MATLAB 时 SKIP）
  - 修 `test_codegen` 的 `return true` → 标 `SKIP`；`mas_precheck` 统一走依赖探测函数；SKILL.md 去掉硬编码版本
- **成功标准**：MATLAB 层一键跑出 15 套件真实计数；缺依赖时必须出现 SKIP 而非 PASS；免费层保持 306/306。
- **改动范围/风险**：测试基础设施 + 两处小修；风险低，但要保证免费层不引入对 MATLAB 的硬依赖。

**P1（5.3 起）**：路由缺口（FFT/约束优化/论文图表/电力电子）、references 渐进式加载、
深度学习最小工作流、系统辨识。
**P2**：ROS/导航/SLAM、Stateflow/Simscape/覆盖率、HDL/STM32、多体、电力电子技能化。

---

## 6. 本轮 Git 与文件改动

| 项 | 内容 |
|---|---|
| 分支 | `phase5.1-audit`（从 `main` `0c5fa84` 切出，**未合并**） |
| 新增（文档） | `docs/PHASE5_1_SKILL_AUDIT_ZH.md`、`docs/PHASE5_1_CAPABILITY_MATRIX_ZH.md`、本文件 |
| 新增（证据，gitignored） | `artifacts/phase51/*`（环境、许可、套件结果、脚本探测、路由探测、两份并行调查） |
| 未改 | Skills 核心代码、安装器、`skills/capability-matrix.json`、main、tag、Release |
| 未验证 | Desktop UI、客户端自主执行、R1/R2/R3、真实硬件、非 Windows、MATLAB 非 R2026a 版本 |

**下一轮入口**：等你批准 Phase 5.2 后，从本分支的实现计划开始（先 P0-A，再 P0-B、P0-C），
每项都以"独立测试可证收益"为完成标准。
