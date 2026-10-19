# Phase 4.2 —— Skills 专业能力强化（第一批：Task 0 / 1 / 2）

分支 `feat/phase3b1-boost`，基线 `2871544`。main 未动（`f76681d`），PR #1/#2 仍 OPEN，
Buck 冻结标签 `buck-v1-sim-baseline` 未触碰。

本文件记录**已完成并实际跑过**的部分。未完成的 Task 3–8 见 §7，不在此报告里计入成绩。

---

## 1. Task 0：第一批 Skills 的质量复审

### 1.1 复审发现的四个问题（都是上一轮自己引入或漏掉的）

| # | 问题 | 证据 | 处理 |
|---|---|---|---|
| R1 | 产品/feature 映射表存在**两份**：`mas_precheck` 内一份、`mas_product_map` 一份 | 两处都硬编码 15 行 | 删除 `mas_precheck` 内的副本，`toolbox` 检查委托给 `mas_dep_probe` |
| R2 | `mas_precheck('toolbox')` 只有布尔结果 | "不work"分不清是没装、没授权、还是名字写错 | 改成五级探测 + 8 个具名状态 |
| R3 | 参考答案**写在任务代码里**，任务自己判 PASS | D3 的参考公式错时，任务与自己一致 | 参考值移出任务，冻结为带哈希的 manifest，由独立验证器评分 |
| R4 | 旧产品名（`Neural Network Toolbox`）无法解析 | 只有当前名在表里 | 别名字段 + 三条跨版本兼容测试 |

### 1.2 统一依赖发现：五级、八状态

`skills/matlab-runner/scripts/mas_dep_probe.m` + `mas_product_map.m`

```
level 1  函数名可解析        FN_NOT_FOUND / IS_A_DIRECTORY / NOT_ON_PATH
level 3  产品在 ver() 中      NOT_INSTALLED
level 4  license(feature)     NOT_LICENSED / UNKNOWN_PRODUCT
level 5  代表表达式能跑        EXEC_FAILED
```

设计要点：

- **`IS_A_DIRECTORY` 单独成一类**。`robotics` 是工具箱目录，`exist('robotics','file')`
  返回 7；用 `exist(...)==2` 判"缺失"会把一个存在的目录报成不存在。
- **产品名 ≠ feature 名**。`license('test','Deep_Learning_Toolbox')` 在 R2026a 上返回 0，
  而同一产品的 `Neural_Network_Toolbox` 返回 1。写错名字得到的是**假阴性**——
  环境有能力却被判成没有，这是最坏的一种错。
- **只到第 1 级就停**（`function` 探测），除非显式 `deep`。license 检出有真实开销，
  执行探针可能有副作用，不该在每次函数存在性检查时都跑。
- **未知产品给出候选**，不猜。

验证：`skills/matlab-runner/tests/test_dep_probe.m`，**17 / 17**，其中 11 条是必须失败的负例
（目录当函数、假函数名、未知产品、把 feature 名当产品名、执行失败）。

### 1.3 跨版本兼容

| 旧名 | 现行名 | 同一行 |
|---|---|---|
| `Neural Network Toolbox` | `Deep Learning Toolbox` | ✓ |
| `Statistics Toolbox` | `Statistics and Machine Learning Toolbox` | ✓ |
| `Simscape Power Systems` | `Simscape Electrical` | ✓ |

测试断言三对别名解析到**同一行**（同 name 同 feature），而不是各自一条。大小写不敏感亦覆盖。

### 1.4 参考答案可信度机制

这是本轮改动最大的一块。

**问题**：Phase 4 的 D3 参考用模拟 Butterworth 公式 `1/(1+(f/fc)^{2N})` 去评价**数字**滤波器。
在 `fc` 处两者都给 −3.01 dB，错误被掩盖；在 `2fc` 处模拟式给 −24.10 dB，而真实值是 −27.97 dB。
更糟的是判据和参考用同一个错公式，因此"自洽地通过"。

**机制**（`mas_ref_derive.m` / `mas_ref_spec.m` / `mas_refcheck.m` / `mas_verify_task.m`）：

```
任务        只返回数字（values 结构体）
mas_verify_task   拿数字和冻结 manifest 比较 → PASS / FAIL / UNDETERMINED
mas_refcheck      重新独立推导 + 比哈希
```

三道闸门，全部通过才叫"参考"：

1. **≥2 条互不共享代码的方法必须一致**，且一致性要好于判定公差的 1/10
   （`spreadFactor`，蒙特卡洛类任务放宽到 1/2 并单独标注）。
2. **手写常量与推导值在冻结时必须一致**。这一条当场抓到两个我自己的错：
   T1 的 `nRowsOut` 我写成 25（40−3−2−2=33），D4 的质心修正写法一开始留了残余代码。
3. **哈希比对**。manifest 用 SHA-256，`freeze` 会重写文件因此**不在常规测试里跑**——
   改参考必须体现在 diff 上。

D3 的三条方法分别是：闭式（预畸变 `tan` 比值）、手写差分手写递推 + 直接 DFT、
正弦稳态幅度最小二乘。三条在 1.5e-14 内一致。
D6 的三条：闭式 `1−exp(−2t)`、RK4、矩阵指数 `expm`。三条在 2.3e-15 内一致。

验证：`skills/matlab-testing-ci/tests/test_refcheck.m`，**11 / 11**。其中包含
两条篡改攻击：只改数值（VALUE 闸门捕获）与数值哈希一起改（HASH 闸门捕获），
以及"缺字段 → UNDETERMINED 而不是 PASS"。

### 1.5 Skill 与执行工具的集成

`skills/matlab-orchestrator/scripts/mas_pipeline.m` + `assets/tasks.json`。
一条命令走完 自然语言 → 路由 → 依赖探测 → 执行 → 独立验收：

```
id   skill      match  verdict        detail
D3   matlab-sig 1      PASS           4/4 checks matched the frozen reference (fc49eafd9423)
...
12 tasks: PASS 12 / FAIL 0 / UNDETERMINED 0 / SKIP 0
router agreed with the task's intended skill on 12/12
```

每条记录都带 `steps`（route/products/execute/verify，各自的耗时与状态）与 `selfVerdict`
（任务自评，仅记录**不采用**）。

---

## 2. Task 1：matlab-control-optimization

新增三个可执行工具。

### 2.1 `mas_ctrl_analyze` —— 裕度属于"交越点"，不属于"回路"

`margin(L)` 只返回一个数。带谐振的回路会两次穿越 0 dB，第一次可能 +83°，第二次 −95°。
取第一个就是"回路很健康"，而实际闭环振荡。Boost 单环 PI 在 Phase 3B.2 就是这样：
第一次 +38°，第二次 −18°。

工具行为：

- 列出**全部** 0 dB 交越（向下/向上）与全部 −180° 交越；
- `pmWorst` 取所有向下交越的最小值，`binding` 指出是哪一次；
- 相位先 `unwrap` 再插值——带积分器的回路相位会跑过 −180°，`angle()` 折回来
  会把最差裕度变成最好看的那个；
- 判定同时看极点与裕度：极点在 LHP 但某次交越裕度为负 → `UNSTABLE`。
- 积分器（极点正好在轴上）单独报 `hasIntegrator`，不再让整条回路变成 "MARGINAL"。

### 2.2 `mas_ctrl_pid_design` —— 目标是"满足裕度的最大带宽"

裕度是约束不是目标：过阻尼回路满足一切裕度且毫无用处。所以网格扫 `Kp × (Ki/Kp)`，
每条候选都用 `mas_ctrl_analyze` 的**最差**裕度判定，取可行解里带宽最大的一个。
无可行解时返回 `feasible=false` 并给出实际达到的最好裕度与原因，**不返回"最不差的"冒充成功**。

### 2.3 `mas_ctrl_aw_sim` —— 饱和与抗积分饱和

三种模式 `none | clamp | backcalc`。实测（`P=1/(s+1)`，`Kp=6, Ki=12`，`u∈[0,1.2]`）：

| 模式 | 超调 | 积分器超出执行器能力的程度 |
|---|---|---|
| none | 3.23 % | 5.86 |
| clamp | 0.00 % | 4.00 |
| backcalc | 0.00 % | 2.10 |

这里踩到一个真坑：**back-calculation 必须除以 Ki**。积分器存的是 `I=∫e`，
命令是 `u=Kp·e+Ki·I`，所以 `dI/dt = e + (u_sat−u)/(Tt·Ki)`。漏掉 1/Ki 时修正增益
正比于 Ki，第一次跑直接把状态推到 1e300。

### 2.4 三个验收系统（要求的稳定/不稳定/多重交越）

| id | 系统 | 期望 | 实测 |
|---|---|---|---|
| C1 | `L=10/(s+1)` | PM 95.74°，单次交越，稳定 | ✓ |
| C2 | `G=1/(s²+s−2)` | 1 个 RHP 极点（+1），不稳定 | ✓ |
| C3 | `L=0.02(s+2)/(s(s+0.5)(s²+0.02s+1))` | 两次向下交越，最差 PM −95.4°，不稳定 | ✓ |

C3 是本轮最有价值的一个案例：第一次交越 +83.1°，如果只报那一个，结论完全相反。

测试：`tests/test_ctrl_analyze.m`，**14 / 14**（含离散回路、延迟回路、PID 可达/不可达、
抗饱和对比）。

---

## 3. Task 2：matlab-data-analysis

`mas_table_audit.m`：带**逐行账本**的清洗流水线。

关键不是"能清洗"，而是**算术必须对得上**：

```
nRowsIn == nRowsOut + nDropped     且每一行被删的行都有且只有一个理由
```

三条规则各自删行时，一行同时命中两条会被数两次，"40 进 30 出，删除 3+4+4"读起来
没问题，但少算/多算一行。所以每一行只拿**一个**判定，由第一条命中的规则认领，
顺序（missing → duplicates → outliers）写进契约并打印出来，因为换顺序会换数字。

`balanced=false` 时调用方不得报 PASS。

其他要求：

- **不允许静默丢列**：非数值列进 `typeWarnings` 并保留，不转换不丢弃；
- `audit` 逐规则给 before/after/dropped/filled；
- `dropped` 表带 `audit_reason` 列。

验证：`tests/test_table_audit.m`，**11 / 11**。含"一行同时是重复值和异常值"
（必须计 1 次、总数 2 而不是 3）、fill 不删行、混合类型、空表、非表格输入。

对应评测任务 T1：40 行、3 NaN、2 重复、2 异常 → 33 行，计数 3/2/2，`balanced=1`。

---

## 4. 路由词表的两处补强

用 12 条真实评测 prompt 跑路由，5 条落到 `CLARIFY`：

```
数值积分 / Butterworth 低通 / 阶跃响应 / Boost 占空比 / 右半平面稳定
```

这些不是歧义句，是词表缺词。补词后 12/12 全部 ROUTE，且原有 9 条路由测试（含两条
"必须说不知道"）仍然 9/9。

一处必须写清楚的取舍：**没有独立的电力电子 Skill**。变换器/占空比/纹波被映射到
`matlab-control-optimization`，因为稳态与稳定性方法归它；这一点写进了 `routing.json`
的 `notes`，能力矩阵里电力电子也只能记 PARTIAL，不能因为路由能命中就说支持。

---

## 5. 一次运行的完整结果

`matlab -batch "addpath('matlab/validation/phase4'); run_all(...)"`

```
routing          9 /   9
precheck        16 /  16
depProbe        17 /  17
grading          6 /   6
refcheck        11 /  11
modelCheck       2 /   2
ctrlAnalyze     14 /  14
tableAudit      11 /  11
references      15 /  15
cross-domain    12 /  12
pipeline        12 /  12   (skillMatch 12/12, self-disagreement 0)
```

合计 **85 / 86 → 86 / 86**（precheck 的一条期望分类随探测改造更新后）。

---

## 6. 本轮修掉的真 Bug（按发现方式分类）

| # | 缺陷 | 怎么发现的 | 影响 |
|---|---|---|---|
| B1 | `mas_ctrl_analyze` 中 `squeeze` 返回**列**向量，`Lw .* delay` 广播成 200000×200000 | 延迟测试 | 申请 596 GB，直接 OOM |
| B2 | 抗饱和 back-calc 漏 `1/Ki` | 抗饱和对比测试 | 状态发散到 1e300 |
| B3 | 交叉校验公差用 `100×agreement` | 冻结输出 | D5 的公差被放大到 0.94，比判定公差还宽，"独立"失效 |
| B4 | `fread(fid,inf,'char')` 返回 **double** | 篡改测试 | `strrep` 容忍、`jsondecode` 拒绝，形成半失败 |
| B5 | `fileparts` 层数数错（4 层 vs 3 层） | 两处 | 所有 addpath 变空操作，报错信息完全误导 |
| B6 | `dflt` 只填顶层字段，`outliers.columns` 缺失 | T1 首跑 | 首行即崩 |
| B7 | 参考值里 `nRowsOut` 写成 25 | 冻结闸门 | 手算错误被自动拦住 |
| B8 | `mas_ref_derive` 的 D5 RK4 漏了输入项 | 双方法不一致 | 超调 −71%（应为 +16.3%） |
| B9 | 手写差分递推未保护历史索引 | D3 首跑 | `y(0)` 索引越界 |
| B10 | C3 相位未 `unwrap` | 双方法不一致 | 最差 PM −95° 被报成 +83° |

其中 B1/B3/B8/B10 都是"看起来对、结果自洽"的类型，只有靠**第二条独立方法**或
**边界输入**才会露出来。这正是本轮把参考值剥离出去的理由。

---

## 7. 尚未完成（不计入本报告成绩）

| Task | 状态 | 说明 |
|---|---|---|
| Task 3 signal-vision-ai | NOT STARTED | 需要频谱泄漏/OFDM BER/图像指标三个工具组 |
| Task 4 robotics | NOT STARTED | `mas_kinematics_check` 等 |
| Task 5 codegen | NOT STARTED | L1–L5 分级探测，无 Coder 许可时 SKIP |
| Task 6 12+ 评测集 | PARTIAL | 12 条任务**已存在并全部通过**，但开发集/保留集**尚未切分** |
| Task 7 Benchmark | PARTIAL | R1 有机器可读 trace；R2/R3 仍 SKIP（本会话无 `mcp__matlab*`） |
| Task 8 架构 | PARTIAL | 四个技能已按 SKILL.md + scripts + tests 组织；其余五个未动 |

---

## 8. 诚实边界

1. **12/12 的 skillMatch 是路由器的成绩，不是 Agent 的行为。** `mas_pipeline` 直接调用
   `mas_route` 与入口函数，Skill 在本会话中**从未被自动触发**（没有技能运行时）。
2. **R2/R3 仍是 SKIP。** 本会话工具列表中没有 `mcp__matlab*`；`matlab -batch` 不是 MCP。
3. **`mas_ref_derive` 的方法仍然是我写的代码。** 两条方法互不共享代码路径，能挡住
   "公式用错"和"代码写错"，挡不住"两条方法对同一个物理问题有同一个错误理解"。
   这一层只能靠外部权威（教科书、器件手册、实测）补，报告里逐项标注了哪些参考
   属于解析解（可信度高）与哪些属于约定（如 ESR 采样沿定义）。
4. **D6 耗时 69 s**（Simulink 编译），是 12 条里唯一的重量级任务；其余 11 条合计 5 s。
