# Phase 5.5 — MATLAB Agent Skills 自主能力与真实增益验证

仓库：https://github.com/wzyn20051216/matlab-agent-skills
工作分支：`phase5.1-audit`　本轮基线 HEAD：`4f4ceb5`（Phase 5.4 提交，未改动 tag）
上一阶段报告：`docs/PHASE5_4_REAL_EXECUTION_ZH.md`
本轮状态：**部分完成，已按约束停止，等待人工审查。**

---

## 0. 结论摘要（先说不能被证明的部分）

本轮真正回答了一个问题、也真正没有回答另一个问题。

**已证实**：在没有路由提示的 Prompt 下，把九个 Skill 完整暴露给 Agent 的工作区里，Agent 能自主发现并使用它们——12 个 R3 episode 中 9 个自行进入正确领域的 skill 目录，9 个自行执行了 `mas_*` 验证契约工具；12 个 episode 全部真实执行，独立评分 10/12 PASS，0 false accept、0 false reject，UNDETERMINED 正确识别 4/5。同一批 episode 还真实遇到了 23 次错误（16 次 MATLAB 异常 + 7 次工具/传输层失败），9 个受影响 episode **全部自行恢复到最终交付**，其中 8 个最终评分通过。

**尚未证实**：Skills 相对无 Skills 的任何增益百分比。三组唯一真正可比的格子只有 `H-SIG-F` 一个任务（R1/R2/R3 各 n=1，同一模型、同一 Prompt sha、同一预算），三组都判定正确，R3 反而最慢。R1/R2 的其余 11 个任务从未 staged、从未运行，因此是 **BLOCKED/UNKNOWN**，不是负结果。

**明确未通过核验**：客户端级 Skill 自动触发。20 个被审计 episode（含试点）**没有任何一次客户端 `Skill` 工具调用**，所以 `AUTO_SELECTED` = 0/14（正式批次）。我们只能声称"工作区级自主发现"，不能声称"Skill 自动触发"。

**顺带纠正了一条历史记录**：Phase 5.4 把 codegen 失败归因于 MCP 长驻会话状态。本轮 E7 证明刚重启的全新 MCP 会话以同一形式失败、而 `matlab -batch` 真实进程通过——判别变量是 **MCP 动态求值通道**，不是会话年龄。Phase 5.4 原文未改动，勘误放在 `artifacts/phase55/coder_session/coder_diagnosis.json`。

---

## 1. Phase 5.4 冻结与 Git 状态（Task 0）

| 项 | 结果 |
|---|---|
| 起始分支 / HEAD | `phase5.1-audit` / `4f4ceb55970df24fbf6a2afa9652293539c8f581` |
| 起始工作树 | `git status --porcelain` 为空（干净） |
| tag | HEAD 上无 tag；本轮未创建、未修改任何 tag |
| 回归复现 | 全新 `matlab -batch` 进程 803/803、24 suites、0 errored、refs 15/15、cross-domain 15/15、pipeline 15/15，`artifacts/phase55/regression/gate_console.log`（13:13:41，268.6 s） |
| 冻结参考 | Phase 5.3 `tasks.json` `79b328f9…` / `answers.json` `f4134974…`、Phase 5.4 `tasks.json` `f48cccc3…` / `answers.json` `a3e279f7…` 全部与 manifest SHA-256 逐字节一致，未被覆盖 |
| Agent 轨迹 | Phase 5.4 的 3 个 episode 轨迹、MCP 记录与评分文件仍在原位 |

`artifacts/phase55/freeze/freeze_report.json`（schema `mas-phase55-freeze/1`）记录了上述全部字段。

**关于"3 个 normal 任务"的口径修正**：`H-SIG-N`、`H-DATA-N`、`H-ROB-N` 已在 Phase 5.4 被 Agent 执行过，本轮**不**把它们算作盲测，也未重复运行；在能力矩阵与本报告中一律标记 ALREADY_USED。

## 2. 真实 Agent 自动发现与加载证据（Task 2）

Prompt 由 `stage_phase55.m` 生成，只含：任务陈述、`input.mat` 变量名、执行要求（走 MATLAB MCP、25 次调用、15 分钟）、判定口径、`result.json` 输出格式。**不含**任何 Skill 名、`mas_*` 工具名或路线提示。三个臂的同一任务 `prompt.md` 字节一致（H-SIG-F sha256 `ab458fe7319d94bd…`，569 字节）。

证据只取自客户端原生日志：`subagents/agent-ageneral-purpose-<id>.jsonl` + `.meta.json` + `task-<id>.json`，由 `artifacts/phase55/audit_subagent.py` 解析出 tool_use 列表、读路径、Bash 命令、模型标识与耗时。

| 观测面 | 定义 | 正式批次（v3, 14 episodes） |
|---|---|---|
| 客户端 `Skill` 工具调用 | 轨迹里出现 `Skill` tool_use | **0 / 14** |
| 工作区自主发现 | episode 自行 `Read`/`find` 自身工作区内 `skills/` | 9 / 12（R3），R1/R2 各 0 / 1 |
| 选对领域 | 打开的 skill 目录与冻结答案 `skill` 字段一致 | 9 / 9 全部选对（data-analysis / signal-vision-ai / robotics-autonomy 各自对应） |
| 自主执行 `mas_*` | MCP 代码里调用 `mas_*` 契约工具 | 9 / 12（R3） |
| 仅在回答里提到 Skill 名 | 文本提及 | 1 例（R3 H-SIG-F 提到 `matlab-signal-vision-ai`）→ **按约束不计入触发** |

分类结论：`AUTO_SELECTED`（客户端可核验自主选择）= **0，仍未证实**；本轮可主张的是"工作区级自主选择 + 正确加载 + 契约执行"，属 `UNKNOWN → 部分 EXPLICITLY_SELECTED`（框架把 Skill 放进了工作区，但没有指定用哪个）。

一个必须写下来的负面观察：**在唯一可比的 H-SIG-F 格子里，R3 只是 `find` 列出了 skills 目录，没有打开任何 `SKILL.md`，没有调用任何 `mas_*`**，行为与 R1/R2 无异。多给 101 个文件（R3）对 2 个文件（R1）在简单任务上没有产生可观测差异。

## 3. R1/R2/R3 公平对照报告（Task 1）

三组定义按约束固定为**工作区暴露度**操作化（因九个 Skill 已按 2026-10-20 快照安装在用户级目录，无法构造"物理未安装"条件；此限制已在隔离审计中记录）：

| 臂 | 工作区 | 文件数 | `.m` / `mas_*` | 本轮真实运行 |
|---|---|---|---|---|
| R1 | 仅 `prompt.md` + `input.mat` | 2 | 0 | 1 episode |
| R2 | R1 + 九个 `SKILL.md` + references + capability-matrix | 23 | **0** | 1 episode |
| R3 | R2 + 九个完整 skill 目录 | 101 | 76 `.m` / 53 `mas_*` | 12 episodes |

公平性控制：同一 MATLAB（R2026a Update 3）与工具箱、同一官方 MATLAB MCP 服务（serverId `a68c155e…`）、同一 Prompt sha、同一预算（25 次 MCP / 15 min）、同一评分器与冻结容差、每臂每任务独立目录（全部在仓库外 `E:\desktop\MATLAB-bench-phase55-v3`）、episode 串行执行且每次会话卫生校验。

模型控制是本轮最脆弱的一环，如实记录：
- v1/v2 试点批（各 3 episodes）中，v2 三臂分别是 `dfmodel`/`dfmodel`/`qmodel_38max`，**违反同模型条件**，因此 v1、v2 只作为试点保留，不进入任何对照结论。
- v3 最小三臂（seq 1–3）全部 `qmodel_38max`，满足条件。
- v3 的 11 个 R3 扩展 episode 跨越 `qmodel_38max` 与 `qfmodel`（客户端在配额中断后切换了模型），因此 **R3 臂内部是异质样本**，不能与任何单模型基线比较。

实际执行顺序（`episodes_v3.json` 的 `seq`，非计划顺序）：R1→R2→R3(H-SIG-F) 之后按 R3 扩展顺序 H-DATA-B、H54-ODE-N、H-SIG-B、H54-VIS-F、H-DATA-F、H54-ODE-B、H-ROB-B、H54-VIS-N、H54-ODE-F、H-ROB-F、H54-VIS-B。三臂顺序采用"先 R1 后 R2 最后 R3"的固定顺序而非逐任务随机，因为 episode 必须串行共享同一 MATLAB 会话；这一取舍已在 `executionOrderNote` 中记录，属于本轮协议的一处已知弱点。

**最小对照结果（唯一可比的格子）**

| 臂 | 耗时 | MCP 调用 | verdict | fPeak | 结果 |
|---|---|---|---|---|---|
| R1 | 77.4 s | 3 | FAIL（正确） | 50.0 Hz | PASS |
| R2 | 59.7 s | 2 | FAIL（正确） | 50.0 Hz | PASS |
| R3 | 83.3 s | 2 | FAIL（正确） | 50.0 Hz | PASS |

三臂全部正确识别"测得的 100 Hz 单频峰不是 50 Hz"。n=1/臂 ⇒ **不构造任何增益或损耗百分比**；R3 是三臂中最慢的。

**CLI vs MCP 执行通道实验**：未运行。本轮所有 Agent episode 都被 Prompt 要求走 MATLAB MCP；本地 `matlab -batch` 通道只出现在我本人的诊断脚本与回归门禁里（已作为违规信号写入审计规则，episode 中出现即 INVALID）。该项保留为 Phase 5.6 的独立实验。

## 4. Phase 5.3 剩余留出任务的真实 Agent 结果（Task 3）

9 个 Phase 5.3 留出任务中，3 个 normal 已用于 Phase 5.4；本轮把 **剩余 6 个 boundary/fault 任务全部在 R3 下真实执行**：

| 任务 | 期望 | Agent 实际 | 评分 | 关键依据（取自 result.json notes） |
|---|---|---|---|---|
| H-SIG-F | FAIL | FAIL | PASS | 100 Hz 处出现峰，不是 50 Hz 信号 |
| H-SIG-B | UNDETERMINED | **FAIL** | **MISS** | 0/128 的 95% 单侧置信上界 0.02313 ≈ 9.7× 理论 Pb；预期错误数仅 0.31，P(0 错)=0.74；需 ~41871 bit |
| H-DATA-B | UNDETERMINED | UNDETERMINED | PASS | 缺条件数与验收判据，拒判 |
| H-DATA-F | FAIL | FAIL | PASS | LU 与 QR 两路解相差 2.2e-4，超过声明容差 1e-9 约 2.2e4 倍 |
| H-ROB-B | UNDETERMINED | UNDETERMINED | PASS | 判据缺失（`mas_quat_check`） |
| H-ROB-F | FAIL | FAIL | PASS | 反对称残差 0.206、元素上界 0.103，且同一稳态下正确 C 的残差 4.16e-13 → 指标不可逆 |

即 **6 个 boundary/fault 任务中 5 个完全正确**，唯一失误是 H-SIG-B 把"样本不足以结论"表达成"声明被否定"。注意它没有犯更严重的错误——它坚决拒绝了 PASS，也没有为了成功率改写工程目标。冻结任务、冻结答案与评分器全程未改。

## 5. ODE / 视觉真实 Agent 验收（Task 4）

Phase 5.4 的 ODE/vision 只有工具级 6/6；本轮 6 个任务全部改由真实 Agent episode 执行（未复用任何工具级轨迹）：

| 任务 | 期望 | 实际 | 评分字段 | 评分 |
|---|---|---|---|---|
| H54-ODE-N | PASS | PASS | 2/3 | **MISS**（verdict 对，字段定义不符） |
| H54-ODE-B | UNDETERMINED | UNDETERMINED | 无字段 | PASS |
| H54-ODE-F | FAIL | FAIL | 1/1 | PASS（超预算，见 §6） |
| H54-VIS-N | PASS | PASS | 2/2 | PASS |
| H54-VIS-B | UNDETERMINED | UNDETERMINED | 无字段 | PASS |
| H54-VIS-F | FAIL | FAIL | 3/3 | PASS（首个 episode 因配额中断，重试成功） |

**特别检查 A–F 逐条取证**：

- **A（会不会把 ode45 正常退出当成数值正确）**：未发生，且有正向反例。H54-ODE-B 中 Agent 明确写出：前向 Euler `h=0.5` 同样能"干净退出、12 步无警告"，但 `y(2)=0.0625` 对 `exp(-2)=0.1353352832366127` 的绝对误差 7.28e-02，而 ode45 自洽参考误差 4.32e-08（约 5 个数量级）；`mas_ode_check` 五级输出为 `solverExit=pass, converged=pass, errorTol=na, invariant=na, conclusion=undetermined` → 综合判定 UNDETERMINED。退出状态与正确性被分开处理。
- **B（能否用独立参考识别误差与物理约束）**：H54-ODE-N 用解析参考 `[cos t; -sin t]`、独立路线 `expm(A·t)·y0`（与参考差 1.1e-16）、`ode113(RelTol 1e-12)`（4.4e-13）与 `ode15s`（1.25e-9）四路交叉；不变量（能量）最大相对漂移 6.55e-10 通过。H54-ODE-F 用 `ode15s(RelTol 1e-12, AbsTol 1e-14)` 复算 `y(0.02)`，识破声明值 2.061e-09 恰等于 `exp(-20)` 的"陈旧解析值"，实际 ode45+MaxStep 0.02 得 4.533e-07（相对偏差 218.9），判 FAIL。
- **C（缺参考/缺判据时能否正确 UNDETERMINED）**：3 个 boundary 任务里 2 个正确（ODE-B、VIS-B），ROB-B/DATA-B 亦正确；唯一失败仍是 H-SIG-B。整体 UNDETERMINED 识别 4/5。
- **D（像素级与对象级是否分清）**：VIS-N 报像素级 `F1=dice=30/31=0.967741935483871` 与对象级 `objectIouMean=objectIouWorst=15/16=0.9375`，两套数字分别对齐；VIS-F 报像素 micro-F1 0.750000（声明 0.9，差 0.15）与对象平均 IoU 0.6000，并用 `bwlabel(4-conn)` 独立重算、`pixelRecount` 差 0 px。
- **E（IoU、一对一匹配、阈值来源）**：VIS-N 明确"匹配 IoU 阈值 0.5 来自 `claims.iouThreshold` 的显式声明"，`matchedFraction=1`、`duplicateCandidates=0`；VIS-B 指出声明者未给出对象匹配阈值，0.5 是"评分侧默认而非声明者给出的值"，因此 `iouThreshold=undetermined` → 不能评分，拒绝代填判据。
- **F（会不会在测试集上调阈值）**：本轮任务面没有提供可调阈值的数据集/评分曲线，因此**不构成对该项的设计性检验**。可观测的间接证据是：12 个 episode 无一修改任何阈值，VIS-B 明确拒绝用默认阈值替代缺失判据。该项标为"未设计 / 无违规观测"。

所有结果由仓库外独立评分器 `grade_phase55.m` 判定，Agent 工作目录内不含评分记录或答案。

## 6. 错误与边界任务的恢复轨迹（交付物 6）

本节的初稿曾写"轨迹里没有错误"，那是**错的**：统计脚本里有一行把 `errorSignals` 强制算成 0 的占位表达式。发现后已改为直接读取 14 份 episode 审计 JSON 的 `errorSignals` 并逐条分类，`artifacts/phase55/analysis/statistics_v3.json` 的 `recovery` 块随之重算。错误占位表达式所在的脚本已修正并入库，错误的初稿结论不留存。

**真实恢复观测（v3，14 episodes）**

| 项 | 数值 |
|---|---|
| 含真实错误信号的 episode | **9 / 14**（全部在 R3；R1、R2 各 0） |
| 真实错误信号总数 | **23** = MATLAB 异常 16 + 工具/传输层 7 |
| 命中错误模式但并非失败 | 5 例，已单列 `patternHitsNotErrors` 并从错误计数中剔除（例如契约输出里的 "0 fail"、`SKILL.md` 描述里的 "error propagation"） |
| 报错后仍完成并写出 `result.json` | **9 / 9** |
| 报错后最终评分通过 | **8 / 9** |
| 唯一未通过 | H54-ODE-N：verdict PASS 正确，`error.maxScaled` 字段定义与冻结契约不一致（见 §5） |

被观测到的 MATLAB 异常都是真实的工程性障碍而不是答案泄漏：`错误使用 symengine`、`无法解析名称 'jupyter.Idler'`、`类型为 double 的变量不支持使用点进行索引`、`错误使用 *`、`错误使用 datestr`、`意外的 'fprintf'（缺失乘法运算符/该用方括号）`、`错误使用 struct2table`、`意外的 'M'`、`错误使用 vertcat`、`错误使用 jsonencode`、`错误使用 table`、`错误使用 run`、`错误使用 mat2str`、`错误使用 fopen`、`错误使用 benchmark_fixtures>@(t,y)[y(2);-y(1)]`。工具层障碍是 4 次 `JSON_PARSE / MCP 参数校验` 与 1 次 `ECONNRESET`。

最典型的两个恢复轨迹：
- **H-DATA-F**：5 次 MATLAB 异常（含符号工具箱路径 `symengine`、点索引误用）后仍完成 LU/QR 双路复算，识破 2.2e-4 的解差，最终 verdict FAIL（正确）。
- **H-ROB-B**：4 次自身工具调用格式错误（参数不是合法 JSON / 多余属性）后仍然正确判 UNDETERMINED。

**口径限制**：客户端不记录逐次尝试的 verdict，只记录最终 `result.json`，所以"首次 verdict / 最终 verdict"无法分列，恢复只能以 **completed-after-error 代理指标**给出（9/9 完成、8/9 通过），**不写成精确恢复率**。

唯一一次硬性中断发生在 episode 之外：**R3 H54-VIS-F 首次运行被客户端配额限制中止**（`You've reached your credit usage limit`，status `failed`，空轨迹、无 `result.json`）。处理方式：未绕过限制、未改用其他通道，登记 `ERROR_CREDIT_LIMIT`，保留失败证据文件 `artifacts/phase55/audit/v3_R3_H54-VIS-F_FAILED.json`，在成功探针之后于 `qfmodel` 上重跑（retrySeq=7），重跑结果 3/3 字段通过（重跑中仍含 1 次 `mat2str` 异常并自行恢复）。

预算越界 1 例：**H54-ODE-F 耗时 1001.4 s > 15 分钟**（MCP 调用 22 次未超 25 次上限），且该 episode 内含 3 次 MATLAB 异常与 1 次传输错误。其 verdict 与字段仍正确，评分器不因超时改判，因此记为 **PASS + BUDGET_VIOLATION_TIME** 并同时保留两个标签——既不隐藏超支，也不因超支否决正确结果。这是 R3 在最难数值任务上付出的真实成本证据。

## 7. Benchmark 隔离审计（Task 6）

`artifacts/phase55/audit/isolation_audit.json`：20 episodes 审计（v1 3 + v2 3 + v3 14），审计项为禁用目录访问、答案泄漏、复用旧产物、读取历史轨迹、提前获得正确工具/verdict、评分器与 Agent 共用可写目录、本地 CLI MATLAB 执行。**violations = 0，INVALID = 0。**

但"尝试真实强制隔离"的结果是负面的，如实报告：用只读对抗探针 subagent 做 5 项检查，**0 项被阻止、5 项全部允许**——

1. 直接读出 `E:/desktop/MATLAB-bench-holdout-phase53/answers.json`（3039 字节，无需 Prompt）；
2. 读取仓库内 `SKILL.md`；
3. 列出用户级 skill 目录 `C:/Users/23201/.qoder-cn/skills/`，可见全部 `matlab-*`；
4. 执行本地 `matlab -batch`，退出码 0；
5. 在仓库内写文件成功（探针随即自行删除并验证不存在）。

结论：**该客户端对 subagent 不存在 OS/工具级沙箱。隔离只能是"程序性（Prompt 指令）+ 事后轨迹审计"，污染是可能的，本轮 20 个 episode 里未发生。** 未修改任何用户系统配置、未破坏 MATLAB 安装、未清理用户数据。

残余限制四条已入档：九个 Skill 用户级已安装（R1 ≠ 未安装）；所有 episode 共享同一长驻 MATLAB MCP 会话（串行 + 编排侧 `rmpath`/`clear`/`close all force`/`rng('default')` 清理，不是进程隔离）；`answers.json` 在所有 episode 工作区之外但评分器目录对 Agent 可写；配额中断那一条 episode。

## 8. MATLAB Coder 长驻会话问题分析（Task 7，仅设计报告）

Phase 5.4 记录（`docs/PHASE5_4_REAL_EXECUTION_ZH.md:316`）：长驻 MCP 会话内 codegen 10/12，某函数 `emlc:compilationError` 且消息为空，只产出 `html/interface`。

本轮 8 个实验（探针脚本已归档到 `artifacts/phase55/probes/`）：

| 实验 | 内容 | 结果 |
|---|---|---|
| E1 | 长驻 MCP 会话内跑 codegen 套件 | 10/12，精确复现 Phase 5.4 数字 |
| E2 | 失败项单独复现 | `FAIL at codegen: `（空消息），而日志显示编译器**已被识别**：Microsoft Visual C++ 2022 (C) |
| E3 | 取错误标识 | `emlc:compilationError`，message 为空 |
| E4 | 清 workspace / `clear all` / `close all force` / `rng default` / 重命名入口后重试 | 四项**全部仍失败**，无恢复 |
| E5 | 会话中新建函数后 codegen | 同样失败 → "会话中新建"不是触发条件 |
| E6 | **真实新进程** `matlab -batch` 跑同一 `mas_codegen_verify` | **PASS**：verdict=PASS stage=compare，maxAbs 0.000e+00，产出 `codegen_target_mex.mexw64` 等 26 个产物 |
| E7 | **重启后的全新 MCP 会话** | 同样 `emlc:compilationError`，诊断与产物（html/interface）完全一致 |
| E8 | 全套门禁 | 803/803，codegen 12/12，0 errored suites |

结论：判别变量是 **MCP 的动态求值通道**（`connector.internal.fevalJSON → matlab_mcp.mcpEval → LiveEditorEvaluationHelperE*`）——Coder 在该上下文里把入口函数判为"不支持代码生成"，抛空消息 `emlc:compilationError`。**不是产品缺陷、不是本机 Coder 缺陷、不是 Agent 算法状态污染。** 因此 Phase 5.4 的"长驻会话状态"归因被本证据推翻（原文未改，此为勘误）。

处理规则（本轮实施）：所有 codegen 断言只在真实 MATLAB 进程里跑，并写明数字来自哪个通道；Agent episode 里由 MCP 报出的 codegen PASS 一律视为未验证，除非真实进程复现；不在本轮做 MCP/Coder 执行器重构（设计报告 only）。未测项也一并列出：Simulink Coder / `coder.compileC` / mexCinterface 走 MCP、`run_matlab_file` 作为替代通道、MathWorks 工单跟进。

同日另一事件必须记录：`restoredefaultpath` 摧毁了 MCP 服务自带的 `+matlab_mcp` 包（`mcpEval` 无法自修复），只能通过 `manage_mcp retry` 恢复，代价是 Phase 5.4 那个长驻会话消失——这也是本轮无法直接解剖原始故障会话的原因。教训：宿主 MCP 的会话里禁止 `restoredefaultpath`，只对项目路径做定向 `rmpath`。

## 9. 完整回归与精确 Git Diff（Task 8）

矩阵更新之后在**全新进程**重跑门禁，最终一次为 `artifacts/phase55/regression/final_gate3_console.log`（18:09:27，298.1 s，R2026a Update 3）：

```
==== 803/803 skill tests | 15/15 references | 15/15 cross-domain | 15/15 pipeline | 298.1 s ====
HEADLINE 803/803 suitesRun 24 suitesErrored 0 refs 15/15 cross 15/15 pipe 15/15 allOk=1
SUITE capability 7/7 ok=1
SUITE codegen 12/12 ok=1
dataContract 118/118  roboticsContract 162/162  visionContract 103/103  odeContract 56/56
signalContract 42/42   stabilityContract 32/32  routingContract 16/16  routing 9/9
benchmarkHarness 11/11 ... 24 suites, 0 errored
```

本轮门禁一共跑了三次，三次日志都保留、不覆盖，过程缺陷如实记录：
1. `gate_console.log`（13:13:41，Task 0 冻结复现）与 `final_gate_console.log`（17:2x）：结果均为 **803/803**，但我的 wrapper 打印用了不存在的字段 `r.testsPass`，MATLAB 在汇总行之后抛错、命令以非零退出——数字有效而退出码不干净。
2. `final_gate2_console.log`（17:48:04，146.4 s）：字段名修正后取数正确，但它在能力矩阵的 recovery 修订**之前**运行。
3. `final_gate3_console.log`（18:09:27，298.1 s）：矩阵定稿后的最终门禁，`allOk=1`。

Codegen 并发回归（本轮重跑，`artifacts/phase55/regression/concurrency_runs/20261022_174913`）：3 轮 × 2 进程，6 个独立 `matlab -batch` 进程全部 `test_codegen: 12/12 passed`、exit 0；每个进程的唯一夹具子目录用后自删，`D:/Temp/mas_codegen_tests` 留空目录；未删除任何非本轮拥有的文件（10-17 遗留的 `mas-test-*` 等目录原样保留）。

Git Diff（本轮相对 `4f4ceb5` 的仓库内改动，提交 `c052ecd`，77 files changed / 7042 insertions / 2 deletions）：**九个 Skill 的任何 `.m` 工具、测试与 references 零改动**。产品侧唯一改动是 `skills/capability-matrix.json`（+41 / −2）：`phase` 更新为 5.5 部分完成、新增 `autonomousExecution.phase55AgentBenchmark` 块、`summary.note` 追加一句。其余为本报告与 `artifacts/phase55/**` 证据（评分器、stager、审计脚本、统计脚本、episode 台账、审计 JSON、门禁与并发日志、探针脚本）。格式上刻意用 `indent=1` + ASCII 转义重生矩阵，使 diff 保持单块新增而非整文件重写。

## 10. Capability Matrix 更新（交付物 10）

`skills/capability-matrix.json` 的 `phase55AgentBenchmark` 块记录：三臂工作区暴露度与 n、公平性六项（含模型异质这一不利事实）、R3 结果 10/12 与两项失误、自动触发 0/14 与 9/12 自主发现、隔离"PROVEN NOT ENFORCED"、`gainClaim: UNKNOWN`、R1/R2 其余任务 `BLOCKED`、Coder 通道诊断。矩阵一致性由 `capability 7/7` 在同一次门禁里验证。未新增第十个 Skill，未新增工具（53 个 VERIFIED 不变）。

## 11. 可证实与尚无法证实的增益（Task 5 / 交付物 11）

按臂统计（`artifacts/phase55/analysis/statistics_v3.json`，样本量已标注）：

| 指标 | R1 (n=1) | R2 (n=1) | R3 (n=12) |
|---|---|---|---|
| 首次/最终任务成功率 | 1/1 | 1/1 | 10/12 = 83.3%（样本量 12，不做显著性断言） |
| false accept / false reject | 0 / 0 | 0 / 0 | 0 / 0 |
| UNDETERMINED 正确识别 | 0/0 | 0/0 | 4/5 |
| 可观测字段通过 | 1/1 | 1/1 | 11/12 |
| Skill 自动选择准确率 | — | — | 9/9 发现即选对；客户端级 0/14 |
| MCP 调用（均值/最大） | 3 / 3 | 2 / 2 | 8.8 / 22 |
| Agent 总耗时（均值/中位） | 77.4 / 77.4 s | 59.7 / 59.7 s | 268.2 / 203.0 s |
| 预算违规 | 0 | 0 | 1（时间） |
| Token | **NOT_OBSERVABLE**：该客户端版本每条消息 `usage` 都是 0，无法比较 | 同左 | 同左 |
| 含真实错误信号的 episode | 0 / 1 | 0 / 1 | **9 / 12**（MATLAB 异常 16、工具/传输 7） |
| 错误恢复 | 无机会 | 无机会 | 9/9 完成、8/9 最终评分通过（**代理指标**，非精确恢复率） |

**可证实**：无路由提示下，Skill+工具工作区能被自主发现、正确选择并执行契约（9/12）；专业 verdict 在无提示下成立；R3 在最难任务上给出了真实进程级参考交叉（ODE 四路、视觉独立 `bwlabel` 重算）。

**尚无法证实**：Skills 带来的准确率/速度/成本增益（正负皆不能）——R1/R2 覆盖 1/12；客户端级自动触发；精确的错误恢复率（只有"报错后仍完成"的代理指标，客户端不记录逐次尝试 verdict）；Token 成本；R3 的 10/12 与"Skills 的贡献"之间的因果（R3 样本跨两个模型，且没有任何同任务基线）。

## 12. Phase 5.6 建议（交付物 12）

1. **补 R1/R2 覆盖，这是唯一能让"增益"这个词成立的前提**：先在**单一模型**（当前可用 `qfmodel`）下补齐 12×2 episode，串行运行预算约 2–3 小时/批；只有 R1/R2/R3 同任务 n≥3 才允许报告差值，且需先做二项/置换检验而不是直接报百分比。
2. **把"自动触发"做成可测目标**：本轮证据表明客户端 `Skill` 工具从未被自主调用。Phase 5.6 应设计一个能区分"客户端 Skill 机制触发"与"工作区文件发现"的判据，并考虑在项目级 `QODER.md`/hook 里暴露 skill 索引（属于评测装置，不是新 Skill）。
3. **补最小对照的统计量**：在 H-SIG-F 这一格把 n 从 1 提到 ≥5/臂（成本最低：单任务、耗时 ~80 s），先拿到一个有方差的对照点，再谈扩展。
4. **执行通道实验独立成项**：CLI(`matlab -batch`) vs MCP 通道对比（含 Coder 在两条通道的可用性，验证 §8 结论），不与 R1/R2/R3 混算；`mas_codegen_verify` 增加 `channel` 字段并在空消息 `emlc:compilationError` 时输出"入口无法从动态求值上下文解析"而非空白。
5. **隔离要做真强制**：申请或实现进程级沙箱/受限令牌；短期至少把 `answers.json` 移出 Agent 可读文件系统（例如交给独立评分进程/容器）。在此之前所有对照报告必须保留"污染可能、事后审计未见"的措辞。
6. **把预算违规变成可判据**：为 R3 长任务（ODE-F 类）区分"任务难度"与"预算设置"，在冻结答案里加 `budgetClass`，避免超时任务只能靠报告脚注解释。
7. **专业领域扩展优先级（不加第十个 Skill，在九个内部加深）**：优先补 (a) 通信链路预算/调制识别的可核验判据（本轮 BER 判据类别错误暴露了统计功效类判据的缺口）；(b) 数值契约中"字段定义"的规范化——`error.maxScaled` 这类名字必须写清分子分母，否则 Agent 正确也拿不到分（H54-ODE-N 的失误是定义歧义，不是能力缺陷）；(c) 机器人/机构动力学里"指标可逆性"检查（H-ROB-F 的成功说明该类判据有价值，值得扩到更多判据）。
8. **不建议做的**：新 Skill、Buck/Boost 专项续做、为凑成功率调低阈值或改历史答案、把工具级轨迹再次冒充 Agent 轨迹。

## 13. 停止点（如实记录）

- 客户端配额在 H54-VIS-F 上中断过一次（未绕过，重跑成功）；此后继续扩展三臂运行存在配额风险，按约束**保留 BLOCKED 并停止**。
- R1/R2 只完成 1/12 任务；其余 11 任务从未 staged/运行 → 增益结论 `UNKNOWN`。
- 客户端级 Skill 自动触发未证实（0/14）。
- Token 成本不可观测。
- 错误恢复只能给代理指标（报错后仍完成 9/9、最终通过 8/9）：客户端不记录逐次尝试的 verdict，精确恢复率无法给出。
- ODE/vision 的 F 项（测试集调阈值）未被本轮任务面设计覆盖。
- 三臂顺序未按任务随机化（受串行共享 MATLAB 会话限制），已记为协议弱点。

## 14. 约束逐条核对

| 约束 | 状态 |
|---|---|
| 不新增第十个 Skill / 不续做 Buck-Boost 专项 | 遵守：Skill 数 9，工具数 53，本轮零新工具 |
| 不修改发布版 tag、不自动合并 main、不创建 Release、不 push | 遵守：仅 `phase5.1-audit` 上一个独立提交 |
| 不调用未经授权的付费模型 | 遵守：全部 episode 为客户端默认分配的模型标识；配额中断时停止而非绕道 |
| Agent 客户端受限则保留 BLOCKED | 遵守：R1/R2 其余 11 任务、F 项检查均记 BLOCKED/未设计 |
| 只有真正运行的组参与统计，不得用历史脚本结果补齐 | 遵守：统计仅计有轨迹 + `result.json` 的 episode；v1/v2 试点隔离标注 |
| Prompt 不得含路线提示 | 遵守：Prompt 模板仅任务+预算+口径，三臂字节一致 |
| 不得因回答提到 Skill 名就推断自动触发 | 遵守：1 例提及明确标注为不计入 |
| 不得复用工具级轨迹冒充 Agent 自主执行 | 遵守：12 个 episode 全部为客户端原生 subagent 轨迹 + 独立评分 |
| 三组未全跑则保留 UNKNOWN，不构造增益百分比 | 遵守：`gainClaim: UNKNOWN`，无任何百分比 |
| 不得为隔离修改用户系统配置、破坏 MATLAB 或清理用户数据 | 遵守：对抗探针只读 + 自删自验证；未动用户环境 |
| 证据污染即标 INVALID | 规则已实现并逐 episode 应用；本轮 0 个 INVALID |
| 不因 Agent 失败降低数学/工程验收标准；禁止删除历史失败记录 | 遵守：冻结答案与容差零改动；H-SIG-B 与 H54-ODE-N 两项失误、首次失败 episode、字段不通过明细与两次门禁日志全部保留入档 |

---

证据索引：`artifacts/phase55/freeze/freeze_report.json`、`stage_v3.log`、`stage_v3_equivalence.log`、`grades/agent_grade_v3.json`、`grades/minimal_v3_H-SIG-F.json`、`grades/r3_v3_extension.json`、`episodes/episodes_v3.json`、`audit/isolation_audit.json`、`audit/v3_*.json`（14 + 1 失败）、`analysis/statistics_v3.json`（含 `recovery` 块）、`coder_session/coder_diagnosis.json`、`probes/*`、`regression/gate_console.log`、`regression/final_gate_console.log`、`regression/final_gate2_console.log`、`regression/final_gate3_console.log`（最终）、`regression/concurrency_runs/20261022_174913/`。工具：`stage_phase55.m`、`grade_phase55.m`、`audit_subagent.py`、`analyze_v3.py`、`score_spec.json`。
