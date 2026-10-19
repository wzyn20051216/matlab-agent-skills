# Phase 4：核心能力审计与第一批升级

分支 `feat/phase3b1-boost`（stacked 在 PR #2 的 Buck 分支之上），main 未动。
本文件只写**实际运行得到**的结果；没有运行的项一律标 NOT TESTED / SKIP。

---

## 0. 结论摘要

1. **审计前，9 个 Skill 一共 788 行文档，0 个可运行脚本、0 个测试、0 个 references。**
   所有"能力"都只是文字，没有任何一条被测试固定住。
2. **发现一个幻影工具**：`matlab-runner` 明确要求 Agent 用 `masacc.availability(...)`
   代替 `license`，而仓库里、MATLAB 路径上都不存在 `masacc`（`exist` 返回 0）。
   照文档执行必然第一步就失败。
3. **第一批四个 Skill 已升级为"可运行 + 可测试"**：
   - orchestrator：加权路由表 + 匹配器，**9/9** 用例（含任务书里的三个例子与两个"不许猜"用例）；
   - runner：通用预检查，**16/16** 用例（一半是必须失败的）；
   - testing-ci：三级判定 `ran / correct / meets`，**6/6** 用例；
   - simulink-modeling：模型 L0–L3 分级，**2/2** 用例。
4. **跨领域 8 个任务全部通过（8/8）**，每个都有独立参考答案。过程中 Agent 自己
   发现并修掉了 **6 个真实错误**（3 个是参考值/判据错，2 个是 API/约定错，1 个是模型错）。
5. **R2/R3 仍是 SKIP**：本会话没有绑定 `mcp__matlab*` 工具，技能也没有作为可调用
   技能被自动触发。任何"Skills 提效"的说法目前都没有证据。

---

## 1. Task 1：9 个 Skill 审计

### 1.1 结构事实（审计前的真实状态）

| Skill | 行数 | references/ | scripts/ | tests/ | evals/ |
|---|---|---|---|---|---|
| matlab-orchestrator | 160 | – | – | – | – |
| matlab-runner | 181 | – | – | – | – |
| matlab-simulink-modeling | 107 | – | – | – | – |
| matlab-codegen-deploy | 94 | – | – | – | – |
| matlab-testing-ci | 71 | – | – | – | – |
| matlab-data-analysis | 47 | – | – | – | – |
| matlab-robotics-autonomy | 46 | – | – | – | – |
| matlab-control-optimization | 45 | – | – | – | – |
| matlab-signal-vision-ai | 37 | – | – | – | – |

`scripts/` 目录存在于**仓库根**（PowerShell 工具链），但**没有一个属于 Skill 本身**。
也就是说：Skill 描述的工作流没有任何自带实现。

### 1.2 十个问题的逐项回答（合并为表）

| # | 问题 | 审计结论 |
|---|---|---|
| 1 | 当前覆盖的能力 | 每个 Skill 覆盖的是**一段流程描述**，不是能力。唯一有可执行载体的是根目录 PowerShell 脚本（MCP 探测、批处理包装） |
| 2 | 缺失的核心能力 | 全部缺：没有路由实现、没有预检查、没有验收判定、没有领域测试 |
| 3 | 自动触发条件是否准确 | 只有 `description` 一句话。orchestrator 的触发词覆盖过宽（"MATLAB" 即触发），无权重、无冲突处理 |
| 4 | 与其他 Skill 的职责重叠 | orchestrator 与 runner 都写了"执行优先级"（MCP > batch），两处规则不一致时无仲裁 |
| 5 | 可调用工具与依赖 | runner 指向 `.\scripts\*.ps1`（存在）与 `masacc.*`（**不存在**）；其余 Skill 只列 API 名 |
| 6 | 执行流程是否完整 | 从"选技能"到"验收"之间缺三段：环境预检、失败分类的自动执行、结果三级判定 |
| 7 | 错误恢复策略 | runner 有分类表与重试上限，但没有实现；其余 Skill 无 |
| 8 | 结果验收能力 | orchestrator 指向 `schemas/acceptance-report.schema.json`（存在），但没有任何 Skill 会去写/校验它 |
| 9 | 硬编码机器环境 | orchestrator/runner 写死 `.\scripts\Test-MatlabMcpExistingSession.ps1` 相对路径与 "on this machine"；换目录即失效 |
| 10 | 是否经 Agent 调用验证 | **否**。本会话无 Skill 运行时，SKILL.md 只是被读取，不构成触发证据 |

### 1.3 三个确定性缺陷（本轮已修）

| 缺陷 | 证据 | 修法 |
|---|---|---|
| `masacc.availability` 不存在 | `exist('masacc','file')+exist('masacc','dir') = 0`；调用报 "无法解析名称" | 改为 `mas_precheck('toolbox', ...)` + 自动生成的 feature 映射表 |
| orchestrator 有**重复章节** | "Closed-loop Definition" 出现两次（第 62 与 105 行），内容一字不差 | 删除后者 |
| 产品名当 license feature | `license('test','Deep_Learning_Toolbox') = 0`，而同一产品的 `Neural_Network_Toolbox` = 1 | 映射表由 `mas_toolbox_map.m` 现场生成，15 个产品逐条实测 |

### 1.4 能力矩阵（完整版见 `skills/capability-matrix.json`）

| Skill | VERIFIED | PARTIAL | NOT TESTED |
|---|---|---|---|
| orchestrator | 路由、多技能协同、低置信度澄清 | 验收报告链接 | MCP 执行 |
| runner | 预检查、工具箱判定、批处理执行 | 错误恢复自动化 | MCP 执行 |
| simulink-modeling | 模型 L0–L3、开关级建模 | 参数扫描（在 MATLAB 里做的） | Stateflow / Simscape |
| testing-ci | 三级判定、33 条断言可运行 | — | GitHub Actions、覆盖率 |
| control-optimization | 状态空间稳定性与阶跃指标 | 频域裕度（多交越未写入技能） | 辨识、鲁棒、MPC |
| signal-vision-ai | 数字滤波器、图像分割 | — | 深度学习、视频、点云 |
| data-analysis | 缺失值+回归 | — | 论文图复现、timetable |
| codegen-deploy | — | — | 全部（本轮未跑任何代码生成） |
| robotics-autonomy | 正运动学（纯 base MATLAB） | — | 轨迹规划、ROS |

统计：**VERIFIED 12 项 / PARTIAL 4 项 / NOT TESTED 14 项 / UNSUPPORTED 0 项**。
"NOT TESTED" 不是"不能用"，是"没有任何证据"，两者不能混。

---

## 2. Task 2：Buck / Boost 经验 → 可复用规则

12 类问题，按 A（通用 MATLAB）/ B（Simulink）/ C（领域知识）/ D（能否预检查）/ E（能否沉淀）判断。

| # | 问题 | A | B | C | D | E | 沉淀位置 |
|---|---|---|---|---|---|---|---|
| 1 | 负载阶跃没进入 Plant | ✔ | | | ✔ | ✔ | `mas_precheck('struct')` + 参考 D7 的端到端检查 |
| 2 | 结构体参数没同步（`p.R` vs `Rcur`） | ✔ | | | ✔ | ✔ | `mas_precheck('struct')`；runner 技能"改参数要重建结构体" |
| 3 | Cell 维度与遍历错误 | ✔ | | | ✔ | ✔ | `mas_precheck('cell')` |
| 4 | Simulink 模块参数名错误 | | ✔ | | ✔ | ✔ | `mas_precheck('model')`（update 会报） |
| 5 | 首次执行失败 | ✔ | ✔ | | ✔ | ✔ | 预检查四件套（函数/字段/数值/索引） |
| 6 | 稳定性被误判 | | | ✔ | | ✔ | `mas_grade` 的 `CORRECT_NOT_ACCEPTED` + control 技能的裕度规则（**待补**） |
| 7 | 多重交越 / 相位裕度算错 | | | ✔ | 部分 | ✔ | 本轮未进技能，列在 control 的升级计划 |
| 8 | 有限时间收敛当成稳定 | | | ✔ | | ✔ | 同上（Floquet 属于领域知识，不进通用层） |
| 9 | 平均模型结论推广到开关模型 | | | ✔ | | ✔ | 领域 references（Boost/Buck 各自），不进 SKILL.md |
| 10 | 跨领域套用验收阈值 | | | ✔ | | ✔ | `mas_grade` 只消费阈值，不内建阈值 |
| 11 | 电流限幅与硬件保护混淆 | | | ✔ | | ✔ | 领域 references |
| 12 | 结果错却报 PASS | | | | ✔ | ✔ | 三级判定（ran / correct / meets） |

**结论**：12 条里 6 条是通用 MATLAB/Simulink 错误，可以用**代码**检查（已进 `mas_precheck`）；
另外 6 条是领域知识，只能写进 references。把后者塞进 SKILL.md 会让主文件膨胀且误导
——这正是本轮只把"通用检查"写成脚本、把"领域阈值"留给领域技能的原因。

---

## 3. Task 3：路由设计与测试

### 3.1 设计

- 路由表 `skills/matlab-orchestrator/assets/routing.json`：每个技能一组加权词条（中英混排）。
- 匹配器 `mas_route.m`：score = 命中权重之和；`matlab-runner` 永远加载。
- 三种结果：`ROUTE` / `CLARIFY`（低于阈值）/ `AMBIGUOUS`（两个领域并列第一）。
- 多技能：次技能得分 ≥ `0.6 × 最高分` 时并入 `loadOrder`。

### 3.2 测试（9/9）

| 用例 | 期望 | 实际 |
|---|---|---|
| 分析 OFDM 通信系统的误码率 | signal-vision-ai，control 不得并列 | ROUTE signal(8)，control 0 ✔ |
| 设计三相逆变器并分析 THD | simulink 为主，signal 协同 | ROUTE simulink(5) + signal(3) ✔ |
| 使用 KITTI 进行目标检测实验 | signal-vision-ai | ROUTE signal(5) ✔ |
| 用 pidtune 调电机转速环 | control | ROUTE control(8) ✔ |
| Simulink 模型生成 C 代码部署 STM32 | codegen | ROUTE codegen(8) > simulink(5) ✔ |
| 整理 CSV 数据并画论文图 | data-analysis | ROUTE data(5) ✔ |
| 同时做控制与图像处理（默认阈值） | CLARIFY | CLARIFY ✔ |
| 同一句但阈值降到 2 | AMBIGUOUS | AMBIGUOUS ✔ |
| 帮我看看这个 | CLARIFY | CLARIFY ✔ |

**已知局限**：中文词序会破坏子串匹配——"代码生成"匹配不到"生成 C 代码"。
第一版就是这样漏掉了代码生成，最后靠补充 `代码`/`生成` 两个低权重词条修复。
这是**词表法的固有代价**，已在文件注释里写明；换成语义匹配需要模型，不在本轮范围。

---

## 4. Task 4：Runner 预检查与恢复

`mas_precheck.m` 支持 8 种检查：function / struct / numeric / index / cell / toolbox / path / model。

其中 **index 检查**是本轮最有价值的一条：MATLAB 对"掩码比数组短"**不报错**，
而是静默取前 `numel(mask)` 个元素。Phase 3B.2 里它让所有 `iLref` 读成 0，
差点得出"电流指令钉在零"的错误结论。现在它会明确失败：

```
mask length 3000 != target length 120000; MATLAB would silently select the first 3000 elements
```

测试 16 项，其中 8 项是必须失败的负例（缺函数、缺字段、NaN、越界、掩码长度不符、
cell 形状不一、未知工具箱、路径缺失），全部按预期。

**恢复策略**（有限、安全）：预检查失败 → 不进入长跑；只对"可安全重试"的类别
（路径、工具箱、字段名）给建议；不自动改用户文件，不无限重试。

---

## 5. Task 5：三级验收

`mas_grade.m` 把三件事分开：

| 判定 | 含义 | 反例 |
|---|---|---|
| `ran` | 每个检查都真的执行了 | 跳过一项就不能算 PASS |
| `correct` | 数值与**独立参考**一致（无参考 → UNDETERMINED） | 47.884 V 与参考一致 ✓ |
| `meets` | 满足领域指标 | 恢复 2.252 ms > 2 ms ✗ |

`overall` 因此多出一个 `CORRECT_NOT_ACCEPTED`：数值对、指标不对。
这正是 Boost C2 的真实处境——如果没有这一档，它会被写成 PASS。

6/6 用例通过，包括"没有数值检查时 correct = UNDETERMINED（不是 true）"。

---

## 6. Task 6：跨领域验证（8/8）

| ID | 领域 | 独立参考 | 结果 |
|---|---|---|---|
| D1 | 科学计算 | 构造的整数解 x=[1;-2;3]；∫4/(1+x²)=π | max\|x−x*\|=0，\|I−π\|<1e-9 |
| D2 | 数据分析 | 真值 a=2.5, b=−0.7 | a 2.504、b −0.7000、R² 0.9995、剔除 3 个 NaN |
| D3 | 信号处理 | Butterworth 预畸变解析式 | −3.0103 dB @fc、−27.966 dB @2fc |
| D4 | 图像处理 | 人为绘制的矩形面积 592 / 100 | 完全一致 |
| D5 | 自动控制 | 二阶系统闭式解 OS 16.30%、Ts 4.0 s | 16.29%、4.04 s |
| D6 | Simulink | x(t)=1−e^{−2t} | x(1)=0.864665 与参考一致 |
| D7 | 电力电子 | 48 V 指标 + 解析纹波（复用冻结 Boost） | 47.9288 V（−0.148%）、纹波 1.0625 vs 1.0627 A |
| D8 | 机器人 | 几何法 (√3/2, 1.3) | 12 位小数一致 |

### 6.1 过程中发现并修掉的 6 个真实错误

| # | 任务 | 错误 | 类别 |
|---|---|---|---|
| 1 | D6 | 模型接成 dx=−2x+u（输入增益漏了 2），轨迹只有参考的一半 | **模型错误**，被独立参考抓到 |
| 2 | D4 | 假设 `regionprops` 的 `Centroid` 是 [行 列]，实际是 [列 行] | API 约定 |
| 3 | D4 | 假设 `st(1)` 是大对象，实际 bwlabel 按列序编号 | 逻辑假设 |
| 4 | D3 | 用**模拟** Butterworth 公式当数字滤波器的参考（2fc 处 −24.10 vs 真实 −27.97） | **参考值本身错** |
| 5 | D3 | `freqz(b,a,0,fs)` 被当成"0 个点"返回空；标量 1e-6 当点数报错 | API 用法 |
| 6 | D3 | 用 `|H(fc)|`（0.707）校验直流增益，正确滤波器被判失败 | 判据写错 |

第 4 条最值得记住：**"独立参考"也可能错**。它不是从被测代码来的，但如果用错了
公式（模拟 vs 数字），它会理直气壮地把正确答案判成错误。判据错和代码错同样严重。

首次执行 **5/8 通过**，3 个失败全部定位并修复，最终 8/8。

---

## 7. Task 7：Agent Benchmark

| 指标 | R1（Agent + CLI） | R2（+ MATLAB MCP） | R3（+ Skills + MCP） |
|---|---|---|---|
| 路由准确率 | 9/9（路由表用例） | — | — |
| 技能触发记录 | 无（无 Skill 运行时） | — | 无 |
| 首次执行成功率 | 5/8（跨领域任务） | SKIP | SKIP |
| 最终任务成功率 | 8/8 | SKIP | SKIP |
| 数值正确率 | 8/8 与独立参考一致 | SKIP | SKIP |
| 错误发现/恢复 | 6/6 全部修复 | SKIP | SKIP |
| 工具调用（MCP） | 0 | SKIP | SKIP |
| 批处理调用 | 1 次/整套 | — | — |
| 总耗时 | 47 s（含 Simulink 建模） | — | — |
| 不必要工具调用 | 0 | — | — |

**必须说清的三点**：

1. 这些任务脚本是 Agent 写的，**参考值是事先给定的**。所以这证明的是
   "Agent + CLI 能把 8 个领域的任务做到参考值"，**不证明** Agent 能自主规划一整套
   工程流程。后者需要 R2/R3 与更长的任务链，本轮不具备条件。
2. R2/R3 的 SKIP 不是"失败"，是"未执行"。接入清单见
   `docs/MATLAB_MCP_ACCESS_CHECKLIST.md`（Phase 3B.2 已写，本轮无变化）。
3. "技能触发准确率 9/9" 是**路由表**的准确率，不是 Agent 行为。本会话中 Skill 没有被
   自动加载过，不能把这两件事混为一谈。

---

## 8. Task 8：目录规范与后续计划

### 8.1 本轮采用的布局（四个 Skill 已落地）

```
skills/<name>/
  SKILL.md        任务边界、触发条件、核心流程（保持精简）
  assets/         机器可读的数据（如 routing.json）
  scripts/        可运行的通用脚本
  references/     专业知识与 API 约束（按需加载）
  tests/          能失败的测试
```

已落地：orchestrator（assets+scripts+tests）、runner（scripts+references+tests）、
testing-ci（scripts+tests）、simulink-modeling（scripts+tests）。
其余五个只有 SKILL.md——**不假装它们已经升级**。

### 8.2 剩余五个的升级计划（按价值排序）

| 顺序 | Skill | 第一步 | 验收方式 |
|---|---|---|---|
| 1 | control-optimization | 把"多重交越/最坏裕度"写成 `references/margins.md`，并加一个能复现 Phase 3A 单环 −18° 的测试 | 用 `mas_grade` 判 FAIL |
| 2 | data-analysis | 加 `scripts/mas_table_audit.m`（缺失率、类型、范围、重复） | 用 D2 的数据构造 3 个脏表用例 |
| 3 | signal-vision-ai | 把 D3 的预畸变参考固化为 `references/digital-vs-analog.md` | 加一个"模拟公式会误判"的负例 |
| 4 | robotics-autonomy | 加 `scripts/mas_fk_check.m`（DH 与几何互验） | D8 扩成 3 组关节角 |
| 5 | codegen-deploy | 先做一个 MEX 最小闭环（codegen + 与 MATLAB 结果对比） | 需要编译器；失败就 SKIP |

### 8.3 不做什么

- 不重写其余五个 Skill 的正文（本轮只审计）。
- 不把 Buck S1–S9 / Boost B1–B12 写进任何通用 Skill。
- 不改动已冻结的工程基线（`buck-v1-sim-baseline` 标签未触碰）。

---

## 9. 复现

```bash
export MAS_OUT="$PWD/artifacts/validation/phase4"
matlab -batch "addpath('matlab/validation/phase4'); run_all(getenv('MAS_OUT'))"
```

耗时 47 s，输出 `phase4_all.json` 与 `crossdomain.json`。
单独跑某一套：

```matlab
addpath('skills/matlab-orchestrator/tests'); test_routing
addpath('skills/matlab-runner/tests');       test_precheck
addpath('skills/matlab-testing-ci/tests');   test_grade
addpath('skills/matlab-simulink-modeling/tests'); test_model_check
```

---

## 10. 未解决的问题

| # | 问题 | 影响 | 原因 |
|---|---|---|---|
| U1 | Skill 没有被真正触发过 | "Skills 是否提效"无法回答 | 客户端未把 `skills/*` 暴露为可调用技能 |
| U2 | 路由依赖子串匹配 | 中文语序变化会漏词 | 需要语义匹配或更多同义词，本轮只做加权词表 |
| U3 | 只有 R1 有数据 | Benchmark 不完整 | 无 MATLAB MCP 绑定 |
| U4 | codegen / Stateflow / ROS / DL 全未验证 | 能力矩阵大面积 NOT TESTED | 本轮范围限制；不编造 |
| U5 | 错误恢复仍以"报告 + 中止"为主 | 自动修复能力有限 | 自动改文件风险高，需用户授权机制 |
