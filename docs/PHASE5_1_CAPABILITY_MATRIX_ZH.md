# Phase 5.1 — 十三类专业领域能力矩阵

日期：2026-10-21 · 基线 `v0.6.0-preview.2`（`0c5fa84`）· 分支 `phase5.1-audit`
证据：`artifacts/phase51/`（自测结果、脚本探测、路由探测、环境与许可清单）

## 判据（不看关键词，只看证据）

| 状态 | 含义 |
|---|---|
| **VERIFIED** | 有可执行脚本 **且** 有对照独立来源的测试（或真实运行证据）证明数学/工程正确性 |
| **PARTIAL** | 有可执行实现，但只覆盖该领域的一个子集，或只在仓库案例中被验证、未纳入技能自测 |
| **NOT TESTED** | 只有散文、API 名列表或描述，无实现、无验证 |
| **UNSUPPORTED** | 明确不具备，或依赖本机没有的许可证/硬件（本轮无此情况，所有探测到的商业工具箱均有许可） |

版本与环境：MATLAB **R2026a Update 3**（`26.1.0.3276743`）、117 个工具箱、`PCWIN64`。
**其他 MATLAB 版本未测试**；本矩阵中的"支持版本"一律只能写 R2026a。

---

## 矩阵总表

| # | 领域 | 状态 | 主要承担者 | 依赖工具箱 | 关键证据 | 缺口 |
|---|---|---|---|---|---|---|
| 1 | 数学与科学计算 | **PARTIAL** | data-analysis（数值积分）、robotics（SE(3)/旋转） | MATLAB 基础、Symbolic（有许可未用） | `test_table_audit 11/11` 含 `numerical_integration=VERIFIED`；`test_robotics 31/31` 覆盖刚体变换 | 线性代数/ODE/符号计算无通用能力；路由对"方程求解"CLARIFY |
| 2 | 数值优化与方程求解 | **PARTIAL** | control（PID 网格搜索 + 裕度约束） | Optimization（有许可） | `test_ctrl_analyze 14/14`；`mas_ctrl_pid_design` 带宽最大化 | `fmincon`/`optimproblem`/`fsolve`/约束优化 **NOT TESTED**；路由对"约束优化"CLARIFY |
| 3 | 统计分析与数据可视化 | **PARTIAL** | data-analysis | Statistics | `test_table_audit 11/11`：逐行审计、回归+缺失数据 **VERIFIED** | 假设检验、绘图产物无脚本无验证（O9）；路由"论文图"CLARIFY |
| 4 | 信号处理与数字通信 | **VERIFIED** | signal-vision-ai | Signal, Communications 基础函数 | `test_signal_vision 34/34`；实跑 Parseval 误 `6.7e-16`、OFDM 相对误 `4.48%`（容差 15%）、泄漏/集中度负例 | 滤波器**设计**（FIR/IIR 指标验收）无工具、路由 CLARIFY |
| 5 | 图像处理与计算机视觉 | **PARTIAL** | signal-vision-ai（仅二值掩码指标） | Image, Computer Vision（有许可） | IoU 手算 `0.25` 精确匹配；`test_signal_vision 34/34` | 检测/分割算法、特征、lidar、医学影像 **NOT TESTED**（O2） |
| 6 | 机器学习与深度学习 | **NOT TESTED** | signal-vision-ai（仅切分） | Deep Learning（有许可） | 只有 `reproducible_stratified_split=VERIFIED` | `trainnet`/`dlnetwork`/训练与推理 **NOT TESTED**（O1）；路由"CNN"CLARIFY |
| 7 | 自动控制与系统辨识 | **PARTIAL** | control-optimization | Control, Simulink Control Design | `test_ctrl_analyze 14/14`：多穿越裕度、稳定/不稳定判定实跑正确；PID、抗饱和、状态空间 **VERIFIED** | 系统辨识、Hinf、MPC **NOT TESTED**（O4） |
| 8 | 电力电子与电机控制 | **PARTIAL** | 无专属技能（仓库 Buck/Boost 案例 + control 的频域方法） | Simulink, Simscape（有许可） | `matlab/buck/**`、`matlab/boost/**` 的 7 工况验收；跨域 D7 PASS | 技能内无电力电子能力（矩阵 `power_electronics_dedicated=PARTIAL`）；电机控制 **NOT TESTED** |
| 9 | 机械动力学与多体系统 | **NOT TESTED** | 无 | Simscape Multibody | 无脚本、无测试、无 .slx | 描述里出现 Simscape（O6），实现为零；路由"两连杆动力学"CLARIFY |
| 10 | 机器人、ROS 与自主导航 | **PARTIAL** | robotics-autonomy | Robotics, Navigation, ROS（有许可） | `test_robotics 31/31`：FK/Jacobian 差分对照 `5.5e-11`、IK 限幅、NEES/NIS、SE(3) 卫生 **VERIFIED** | ROS bag、SLAM、路径规划、UAV **NOT TESTED**（O3） |
| 11 | Simulink 系统级仿真 | **VERIFIED**（核心） | simulink-modeling | Simulink | `test_model_check 2/2`（L3/L0）；仓库另有 `simulation=PASS/L3`、参数扫描 `L4` 证据。**限定**：L3 判据是"信号有限非空"，不是"对齐 golden" | Stateflow、Simscape、需求追踪、覆盖率 **NOT TESTED**（O6） |
| 12 | 嵌入式代码生成与部署 | **PARTIAL** | codegen-deploy | MATLAB Coder, Embedded Coder（有许可） | `test_codegen 12/12`（65.8 s，含真实生成/编译/golden 对照）；静态就绪、定点范围 **VERIFIED** | HDL、STM32 全链路、`slbuild` **NOT TESTED**；Simulink Coder feature `RTW` 报 0 待核实 |
| 13 | 科学实验与论文复现 | **PARTIAL** | testing-ci（冻结参考/独立校验/ledger） | MATLAB 基础 | `test_refcheck 11/11`、`test_phase43_grade 43/43`、`test_bench 9/9`；冻结参考与篡改负例 **VERIFIED** | 论文复现流程只是 5 步散文（O8）；图件复现无实现；路由"论文图表"CLARIFY |

**计数（领域级）**：**VERIFIED 2**（4 信号/通信、11 Simulink 核心）/ **PARTIAL 9** /
**NOT TESTED 2**（6 机器学习、9 多体动力学）。**没有 UNSUPPORTED 领域**——许可证齐备，
缺的是实现与验证，不是环境。子能力缺口另列于 §3（11 项）。

> 领域级 VERIFIED 的门槛比"有脚本"更高：必须同时有独立参考的测试通过；因此即使某技能自报 34 项
> VERIFIED 子能力，落到 13 个领域也只有 2 个领域整体达标。

---

## 2. 路由与实际覆盖的错位（实测）

15 条跨领域自然语言请求（`artifacts/phase51/route_probe.txt`）：

| 结果 | 数量 | 典型请求 |
|---|---|---|
| `ROUTE` 命中 | **9** | 数据拟合/误差棒、FIR 设计、Simulink 热系统、LQR、ROS2+EKF、PID→STM32、医学图像 Dice、统计描述+检验、三相逆变器电流环 |
| `CLARIFY`（拒绝猜测） | **6** | FFT+混叠、CNN 训练、Buck 论文复现、约束优化、两连杆动力学、论文图表 |

**解读**：
- `CLARIFY` 本身是**正确设计**（"低于阈值就问，不猜"），`test_routing 9/9` 就是在钉这个行为。
- 但这 6 条里有 4 条**本应有技能接住**（FFT 属信号、约束优化属优化、论文图表属复现、Buck 属电力电子），
  说明 **routing 词表覆盖不足**，不是"这些领域不该做"。
- 另外 2 条（CNN、多体动力学）属于**真的没有实现**，应保持 CLARIFY 直到 Phase 5.2/5.3 补齐。

---

## 3. 子能力缺口清单（按领域）

| 领域 | 缺的具体能力 | 现状态 |
|---|---|---|
| 1 | 线性方程/特征值/ODE/符号计算的可复用验证器 | 无 |
| 2 | 约束优化与方程求根（`fmincon`/`fsolve`/`optimproblem`） | 无 |
| 3 | 假设检验（t/ANOVA/非参数）与图件复现校验 | 无 |
| 4 | FIR/IIR 设计 + 指标验收（通带/阻带/线性相位） | 路由 CLARIFY |
| 5 | 检测/分割算法、特征、lidar、医学影像读取 | 无 |
| 6 | 训练/推理/混淆矩阵/类别不平衡 | 无 |
| 7 | 系统辨识（`iddata`/`tfest`）、Hinf、MPC | 无 |
| 8 | 电力电子专属能力（开关级/平均模型、纹波、环路） | 仅仓库案例 |
| 9 | 多体动力学（Simscape Multibody / 拉格朗日） | 无 |
| 10 | ROS bag、路径规划、SLAM、UAV | 无 |
| 11 | Stateflow、Simscape、覆盖率、需求 | 无 |
| 12 | HDL、STM32 目标链、`slbuild` | 无 |
| 13 | 论文复现流水线（图/表/数值三对齐） | 散文 |

---

## 4. 与仓库自报矩阵的一致性

`skills/capability-matrix.json` 自报：**34 VERIFIED / 14 NOT TESTED / 3 PARTIAL**；
`mas_capability_check` 返回 `CAPOK=1 VERDICT=CONSISTENT`。
本轮实测把每个 VERIFIED 条目对应的技能自测都真跑了一遍（244/244 通过），**未发现自报矩阵虚高**；
唯一不一致是 `mas_skill_audit.m` 被声称有 ledger 证据但实际无测试/无调用点（见审计报告 §4.3）。

---

## 5. 验证边界（必须随矩阵一起读）

- 仅 **Windows + MATLAB R2026a Update 3** 实测；其他版本/平台 **NOT VERIFIED**。
- 工具箱许可已确认，但**没有对每个工具箱做"深度用例"**：许可 ≠ 该领域的工程正确性。
- 领域 8（电力电子）的 PASS 来自仓库案例，**不是技能能力**；迁到技能仍需 5.2 的实施与测试。
- 本矩阵不改变 `skills/capability-matrix.json`（那是 Skill 内容，按本轮要求不动）。
