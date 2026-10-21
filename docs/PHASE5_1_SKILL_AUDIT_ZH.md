# Phase 5.1 — 九个 Skills 深度审计

日期：2026-10-21
基线：`v0.6.0-preview.2` = `main` = `0c5fa84424706074ed661aabd7ced80536e795b0`
分支：`phase5.1-audit`（未合并 main、未发布 Release、未改安装器）
证据目录：`artifacts/phase51/`（gitignored）

---

## 1. Task 0：基线、环境与结构

### 1.1 基线保护

| 项 | 状态 |
|---|---|
| main | `0c5fa84`（未修改） |
| tag `v0.6.0-preview.2` | 未移动；Release 存在且为 Pre-release |
| Phase 5 分支 | `phase5.1-audit`（从 main 切出） |
| 历史验证产物 | 全部保留（`artifacts/validation/**`） |

### 1.2 真实测试环境（`artifacts/phase51/matlab_env.json`）

| 项 | 值 |
|---|---|
| MATLAB | **R2026a Update 3**（`26.1.0.3276743`） |
| 平台 | `PCWIN64` |
| 已安装工具箱 | **117**（`ver` 结果） |
| Java | 由 `version('-java')` 记录 |

**许可探测的关键教训**：`license('test', ...)` 的参数是 **feature 名**，不是产品名。用产品名探测会得到假阴性
（与 CHANGELOG 记录的历史缺陷同类）。用 `ver` 列表 + 正确 feature 名双重核对后的结果：

| 工具箱 | 正确 feature | 许可 |
|---|---|---|
| Deep Learning | `Neural_Network_Toolbox` | ✅ |
| Computer Vision | `Video_and_Image_Blockset` | ✅ |
| System Identification | `Identification_Toolbox` | ✅ |
| Embedded Coder | `RTW_Embedded_Coder` | ✅ |
| HDL Coder | `Simulink_HDL_Coder` | ✅ |
| Symbolic Math | `Symbolic_Toolbox` | ✅ |
| DSP System | `Signal_Blocks` | ✅ |
| Mapping | `MAP_Toolbox` | ✅ |
| Signal / Control / Optimization / Statistics / Image / Robotics / Navigation / ROS / MATLAB Coder | 同名 | ✅ |
| **Simulink Coder** | `RTW` 报 0 | ⚠️ 需用一次真实 build 复核（`ver` 显示已安装） |

> 结论：本机不是"只有基础 MATLAB"。除 Simulink Coder 的 feature 归属待复核外，13 个域所需的商业工具箱基本齐备。
> 因此 **NOT TESTED 不能用"没许可证"解释**，只能解释为"没有可执行实现或没有验收证据"。

### 1.3 九个 Skills 的文件结构（实测）

| Skill | SKILL.md | references/ | scripts/ | 技能内 tests/ | 总文件 |
|---|---|---|---|---|---|
| matlab-runner | 9320 B | **4** | 4 | 2 | 11 |
| matlab-orchestrator | 8950 B | 0 | 3（+2 assets） | 2 | 8 |
| matlab-simulink-modeling | 7247 B | 0 | 1 | 1 | 3 |
| matlab-robotics-autonomy | 6620 B | 0 | 4 | 1 | 6 |
| matlab-signal-vision-ai | 5846 B | 0 | 4 | 1 | 6 |
| matlab-codegen-deploy | 6102 B | 0 | 3 | 1 | 5 |
| matlab-testing-ci | 4634 B | 0 | 9 | 5 | 15 |
| matlab-control-optimization | 3481 B | 0 | 3 | 1 | 5 |
| matlab-data-analysis | 3076 B | 0 | 1 | 1 | 3 |

**结构性事实 1**：**8/9 技能没有 `references/`**。这与"主 SKILL.md 精简 + references 渐进式加载"的设计目标不符；
runner 是唯一做了渐进式加载的技能。

**结构性事实 2**：15 个技能自测真实存在，且**不是"能跑就行"**：全部用例对照独立来源（手算夹具、闭式解、
已知系统、故意错误的负例），设计质量高。

**结构性事实 3**：这 15 个自测**没有被任何 runner 或 CI 调用**（顶层 `tests/Invoke-Tests.ps1` 只跑 Pester；
技能自测需手动 `matlab -batch "test_xxx(true)"`）。因此它们只能算"设计上有验证"，不算"持续受门禁保护"。

---

## 2. 九个 Skills 逐个审计

> 状态口径：**VERIFIED** = 有可执行脚本 + 有对照独立来源的测试并通过；**PARTIAL** = 有实现但缺测试或只在
> 仓库案例里被验证；**NOT TESTED** = 只有散文/API 列表；**UNSUPPORTED** = 明确不具备。

### 2.1 matlab-runner（执行与依赖发现）— 最强的一个

- 脚本：`mas_dep_probe`（291 行，五级依赖发现）、`mas_precheck`（187 行）、`mas_product_map`（119 行）、`mas_toolbox_map`。
- 测试：`test_dep_probe` **26/26**、`test_precheck` **16/16**（本轮实跑，8.0 s / 5.2 s）。
- references/：4 个（渐进式加载唯一实现者）。
- 过度声明：**Paper Reproduction Mode 只有 5 步散文**，无脚本、无测试、无复现产物。
- 判据：执行/依赖/预检 **VERIFIED**；论文复现 **NOT TESTED**。

### 2.2 matlab-orchestrator（路由与流水线）

- 脚本：`mas_route`（加权词表，可审计）、`mas_pipeline`、`mas_skill_graph`（387 行，检查环/悬挂引用/重复）。
- 测试：`test_routing` **9/9**、`test_skill_graph` **13/13**。
- 实测路由（15 条跨领域请求，`artifacts/phase51/route_probe.txt`）：**9 ROUTE / 6 CLARIFY**。
  CLARIFY 的 6 条：FFT+混叠、CNN 训练、Buck 论文复现、约束优化、两连杆动力学、论文图表。
- 过度声明：`mas_pipeline` 只在**固定任务函数**上跑过 15/15，矩阵自报 `skill_runtime_invocation = NOT TESTED`。
- 判据：路由/图检查 **VERIFIED**；端到端自治 **PARTIAL**；6 个领域存在**路由缺口**。

### 2.3 matlab-simulink-modeling（Simulink 系统级）

- 脚本：`mas_model_check`（90 行，L0–L3 分级）。
- 测试：`test_model_check` **2/2**（真实模型 L3 / 缺失文件 L0）。
- 仓库内另有独立证据：`matlab/validation/simulink_coder_smoke.m` 做过 `simulation=PASS/L3` 与参数扫描 `L4`。
- 过度声明：Stateflow、Simscape、requirements、sweeps 均无技能内实现/测试（O6）。
- 判据：建模+仿真+lint **VERIFIED**；Stateflow/Simscape/codegen-build **NOT TESTED**。

### 2.4 matlab-robotics-autonomy

- 脚本：`mas_kin_check`（FK + 差分 Jacobian 交叉验证，120 行）、`mas_kin_ik`（DLS + 限幅）、`mas_ekf_check`（NEES/NIS）、`mas_frame_check`（SE(3)/SO(3) 卫生）。
- 测试：`test_robotics` **31/31**。
- 实测：`jacErr=5.5e-11`、`maxReach=1.2` 精确；SE(3) 正交性检查能区分好/坏矩阵（`orthErr 1.1e-16` vs `4.75e-02`）。
- 过度声明：ROS/ROS2 bag、SLAM、路径规划、UAV 均无调用点（O3）。
- 判据：运动学/IK/EKF/坐标系 **VERIFIED**；ROS/SLAM/导航 **NOT TESTED**。

### 2.5 matlab-signal-vision-ai

- 脚本：`mas_spectrum_check`（Parseval + taper 双检）、`mas_ofdm_ber`（闭式 BER 对照）、`mas_image_metrics`（IoU/Dice 约定）、`mas_split_seed`（分层+泄漏检查）。
- 测试：`test_signal_vision` **34/34**。
- 实测：Parseval 误差 `6.7e-16`、OFDM 最大相对误差 `4.48%`（容差 15%）、IoU `0.25` 精确匹配手算。
- 过度声明：deep learning（O1）、CV/lidar/medical（O2）无实现。
- 判据：频谱/通信/分割指标/切分 **VERIFIED**；ML/DL/CV **NOT TESTED**。

### 2.6 matlab-codegen-deploy

- 脚本：`mas_codegen_ready`（静态就绪审计）、`mas_codegen_verify`（生成+编译+对照 MATLAB golden）、`mas_fixpt_range`（范围+量化代价）。
- 测试：`test_codegen` **12/12**（65.8 s，含真实生成/编译链路）。
- 过度声明：HDL / STM32 全链路 / `slbuild` **NOT TESTED**。
- 判据：MEX golden 对照、静态就绪、定点范围 **VERIFIED**；嵌入式目标链 **NOT TESTED**。

### 2.7 matlab-control-optimization

- 脚本：`mas_ctrl_analyze`（**多穿越**裕度，223 行）、`mas_ctrl_pid_design`（带宽最大化受裕度约束）、`mas_ctrl_aw_sim`（饱和+抗饱和）。
- 测试：`test_ctrl_analyze` **14/14**。
- 实测：已知稳定环 `STABLE`、右半平面极点 `UNSTABLE`；但**稳定环 `pmWorst=NaN`**（DC 处即 0 dB，无向下穿越）——
  数值上正确，但对使用者是"没有解释的 NaN"，属于可改进的可用性缺陷。
- 过度声明：system ID / Hinf / MPC / Simulink Control Design 无实现（O4）；优化只有 2-D 网格（O5）。
- 判据：裕度/PID/抗饱和/状态空间 **VERIFIED**；系统辨识/Hinf/MPC **NOT TESTED**。

### 2.8 matlab-data-analysis

- 脚本：`mas_table_audit`（逐行会计，269 行）。
- 测试：`test_table_audit` **11/11**；实测 `balanced=1`，行 5→4。
- 过度声明：可视化/报告产物无脚本生成、无测试验证（O9）。
- 判据：表格清洗/回归/数值积分 **VERIFIED**；可视化与论文图 **NOT TESTED**。

### 2.9 matlab-testing-ci

- 脚本：9 个（`mas_grade` 三级判定、`mas_refcheck` 冻结参考、`mas_ref_derive` 571 行独立推导、`mas_verify_task`、`mas_bench_record`、`mas_capability_check`、`mas_phase43_grade`、`mas_skill_audit`、`mas_ref_spec`）。
- 测试：5 个套件 **76/76**（9+7+6+43+11）。
- 实测：`mas_capability_check` → `CAPOK=1 VERDICT=CONSISTENT`（矩阵自报 34 VERIFIED / 14 NOT TESTED / 3 PARTIAL 自洽）。
- 缺陷：`mas_skill_audit.m` **无调用点、无测试**，但矩阵声称有 ledger 证据。
- 判据：三级判定/冻结参考/独立校验 **VERIFIED**；CI 生成/coverage/Simulink Test **NOT TESTED**（O10）。

### 2.10 自测执行汇总（本轮真跑，`artifacts/phase51/skill_suite_results.tsv`）

| 套件 | 结果 | 用时 |
|---|---|---|
| test_codegen | **12/12** | 65.8 s |
| test_ctrl_analyze | **14/14** | 24.1 s |
| test_table_audit | **11/11** | 1.5 s |
| test_routing | **9/9** | 0.4 s |
| test_skill_graph | **13/13** | 5.1 s |
| test_robotics | **31/31** | 1.9 s |
| test_dep_probe | **26/26** | 8.0 s |
| test_precheck | **16/16** | 5.2 s |
| test_signal_vision | **34/34** | 1.1 s |
| test_model_check | **2/2** | 3.0 s |
| test_bench | **9/9** | 23.0 s |
| test_capability | **7/7** | 0.7 s |
| test_grade | **6/6** | 0.2 s |
| test_phase43_grade | **43/43** | 1.0 s |
| test_refcheck | **11/11** | 1.3 s |

**合计 244/244 通过**（其中 `test_refcheck` 的 14/15 是故意的篡改负例，15/15 是恢复后的正例，均符合预期）。

**必须带上的限定**：`test_codegen.m:156` 在 `exist('codegen','file')==0` 时直接返回 `true`，
即**在没装 MATLAB Coder 的机器上会"12/12 通过"却一条都没测**。本机 `codegen`/`fi` 均存在
（`CODEGEN_EXISTS=1`、`FI_EXISTS=1`），且该套件耗时 65.8 s，说明真实生成/编译链路跑了；
但这条"环境缺失即空转"的写法是真实的可移植性缺陷（见 §4.7）。同理
`test_model_check.m:17` 只断言 `level=='L3'`，而 `mas_model_check.m:10` 把 L3 定义为
"仿真到 tStop 且信号有限非空"——这是"能跑就行"的判据，与仓库自己"L3 = 对齐 golden"的说法冲突（§4.8）。

## 3. 过度声明清单（描述暗示但无可执行实现）

来自 `artifacts/phase51/skill_survey.md`（O1–O11），按领域归并：

| # | 技能 | 领域 | 为什么是过度声明 |
|---|---|---|---|
| O1 | signal-vision-ai | 6 ML/DL | 描述含 "deep learning … training, inference"，SKILL.md 列 `trainnet`/`dlnetwork`，但无脚本无测试 |
| O2 | signal-vision-ai | 5 CV | 描述含 "computer vision, lidar, medical imaging"，只实现二值掩码指标 |
| O3 | robotics-autonomy | 10 ROS/SLAM/导航/UAV | 描述列 ROS/Navigation/UAV Toolbox，实际只有平面 n-R 与 2 状态 KF |
| O4 | control-optimization | 7 系统辨识/Hinf/MPC | 列 `iddata`/`tfest`/`hinfsyn`/`musyn`/`systune`，无调用点 |
| O5 | control-optimization | 2 优化 | 列 `optimproblem`/`fmincon`/`ga`，实际只有 2-D 网格 |
| O6 | simulink-modeling | 9/11 Simscape/Stateflow/需求/扫描 | 无 Simscape/Stateflow 触碰，L4 依赖调用方 |
| O8 | runner | 13 论文复现 | 5 步散文，无脚本/测试/产物 |
| O9 | data-analysis | 3 可视化/论文图 | 无绘图脚本、无图验证；只 `assert(isfile(...))` |
| O10 | testing-ci | CI/coverage/Simulink Test | 只给 `matlab-actions/*@v3` 模板，仓库内无生成物、无 coverage 调用 |
| O11 | orchestrator | 端到端自治 | `mas_pipeline` 只在固定任务函数上通过；矩阵自报 `skill_runtime_invocation = NOT TESTED` |

**处理原则**：不要求 Phase 5.2 立刻实现全部；要求 (a) 把这些能力在矩阵中保持 NOT TESTED/PARTIAL，
(b) 或在 SKILL.md 顶部加一句"该能力未验证"，(c) 优先实现跨领域通用项。

## 4. 结构与依赖问题（可执行清单）

1. **渐进式加载缺失**：8/9 技能无 `references/`；SKILL.md 最大 9.3 KB。建议 P1 拆分（每技能 2–4 个 references）。
2. **自测未入门禁**：244 条断言的技能自测不在 CI/免费层；建议 P0 加一个 MATLAB 层 runner（`-Layer matlab` 已有框架），并在免费层用一个"测试清单存在且与 SKILL.md 声明一致"的静态检查兜底。
3. **无调用点脚本**：`mas_skill_audit.m` 无测试无调用（矩阵却声称有证据）→ 要么补测试，要么降级矩阵条目。
4. **NaN 可读性**：`mas_ctrl_analyze` 在"DC 即 0 dB"时 `pmWorst=NaN` 无解释 → 增加 `r.notes`。
5. **CAPCHECK 的 `detail` 是字符数组**，逐字符打印（`DETAIL 0 / / 0 / c o n s i s t e n t`），调用方容易误读 → 改为字符串/单元数组。
6. **路由缺口**：6 条常见请求落到 CLARIFY（FFT/混叠、CNN、约束优化、多体动力学、论文图表、Buck 复现）。
7. **环境缺失即空转**：`test_codegen.m:156` 的 `if exist('codegen','file')==0, return true` 会把"没测"上报成"通过"。
8. **判据偏弱**：`mas_model_check` 的 L3 = "信号有限非空"，`test_model_check` 只钉 `level=='L3'`；
   仓库另处又把 L3 定义为"对齐 golden"——同一等级两种含义。
9. **仓库自相矛盾（已核实）**：
   - `skills/matlab-runner/SKILL.md:137` 写 "`masacc.availability`…No such package exists"，
     但 `matlab/validation/+masacc/` 实际有 **13 个函数**，且有 7 个验证脚本调用 `masacc.*`；
   - `skills/capability-matrix.json:454` 引用 `test_capability_check.m`，实际文件是 `test_capability.m`；
   - 同一矩阵 `:466` 声称 `mas_skill_audit` 由 `test_bench.m` 覆盖——`test_bench` 测的是 `mas_bench_record`；
   - `:196-203` 把 `simulink_coder_slbuild` 标为 NOT TESTED，但仓库里存在 GRT `.exe` 与
     `simulink.codegen-build=PASS/L4` 证据——这是**低报**，方向与过度声明相反。
10. **唯一完整跑批记录不是绿的**：`artifacts/validation/phase4/phase4_all.json` 记录
    `skillPass 200/201`、`allSuitesOk=false`、`capability 6/7`，且只列了 15 个套件中的 14 个
    （缺 `test_phase43_grade`），而 `suitesErrored` 仍为 0——统计口径本身有问题。
11. **领域级结论**：把上面的证据按 13 域归并后，**只有 2 个领域达到领域级 VERIFIED**
    （4 信号/通信、11 Simulink 核心建模仿真），其余为 PARTIAL 或 NOT TESTED（见能力矩阵）。

## 5. 本轮的验证边界

- 全部 244 条技能自测**真跑通过**（R2026a U3）。
- 7 个核心脚本的**实际输出**已记录（`skill_probe.json`），并由我独立核对（Parseval、手算 IoU、解析 FK、Cramer）。
- **NOT VERIFIED**：Desktop UI 可见性、客户端自主执行、R1/R2/R3 增益、真实硬件、非 Windows 平台。
- **未做**：没有修改任何 Skill 代码；没有新增第十个 Skill；没有改安装器；没有合并 main。
