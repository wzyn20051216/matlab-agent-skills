# Phase 4.2 —— Skills 专业能力强化（Task 0–6）

分支 `feat/phase3b1-boost`，基线 `2871544`。main 未动（`f76681d`），PR #1/#2 仍 OPEN，
Buck 冻结标签 `buck-v1-sim-baseline` 未触碰。

本文件记录**已完成并实际跑过**的部分。Task 7–8 见 §9。

---

## 0. 一次运行的完整结果（最新）

`matlab -batch "addpath('matlab/validation/phase4'); run_all(...)"`

```
routing           9 /   9      signal / vision / AI  34 /  34
precheck         16 /  16      robotics              31 /  31
depProbe         17 /  17      codegen               11 /  11
grading           6 /   6      ------------------------------------------
refcheck         11 /  11      skill tests          177 / 177
bench              9 /   9      references            15 /  15
modelCheck        2 /   2      cross-domain          15 /  15
ctrlAnalyze      14 /  14        dev 12/12  held-out 3/3
tableAudit       11 /  11      pipeline              15 /  15  (skillMatch 15/15)
                 166 → 177
```

Benchmark 台账：**R1 DONE / R2 SKIP / R3 SKIP → overall PARTIAL**（见 §9）。

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
| B11 | `mas_dep_probe` 用 `exist(...,'file')` 判可调用性 | Task 4 探测机器人工具箱 | `chol`/`eig`/`inv` 误报 FN_NOT_FOUND、`svd` 误报 IS_A_DIRECTORY |
| B12 | `mas_spectrum_check` 的 Parseval 比 `mean(x²)` | 探针：普通多频+噪声信号 | **任何含随机分量的信号都误报失败**（Hann 实测 7.3e−3） |
| B13 | `mas_image_metrics` 文档承诺 `r.perObject` 但代码没有 | 读文档核对字段 | 目标级指标全错，正是文档强调的风险场景 |
| B14 | `mas_codegen_verify` 的 relative-error 用矩阵右除 `d / den` | 首次真实 codegen | 外积矩阵 → `max()` 返回行向量 → compare 阶段必崩 |
| B15 | `exist('codegen','file')==2` 判 Coder 可用性 | 首次运行 | `codegen` 是 P 文件（exist=6）→ **完好的机器被判不可用** |
| B16 | `codegen -d` 遗留 MEX 二进制在 cwd | 跑完看目录 | stale 二进制会掩盖之后的失败重建 |
| B17 | 产品映射表缺 6 个真实产品 | 保留集 S1 被 SKIP | `Communications Toolbox` → UNKNOWN_PRODUCT **假阴性** |
| B18 | OFDM BER 用固定 15% 容差 | 保留集自评 vs 验证器分歧 | 8 dB 只 58 个错误比特、噪声 13%，容差低于噪声地板 |
| B19 | `run_all` 崩溃的套件不进分母 | 总分 168/168 但 bench 是 0/NaN | **整个验证体系的结论失效，且失效方式让人放心** |
| B20 | 错误处理代码调用不存在的 `tern` | 修 B19 后仍失败 | 它想报告的错误被它自己的错误替换 |
| B21 | `struct(...,'cases',{T.name})` 嵌套 cell | bench 在 run_all 里失败 | `struct` 构造 1×9 结构体数组，**表现像 flaky** |

其中 B1/B3/B8/B10/B12/B14 都是"看起来对、结果自洽"的类型，只有靠**第二条独立方法**或
**边界输入**才会露出来。这正是本轮把参考值剥离出去的理由。

B18 有个特别之处：它不是"实现错了"，而是**判据本身没有依据**——一个固定百分比不可能
同时适配噪声差 19 倍的两个工作点。发现它的不是测试失败，而是**任务自评与独立验证器的
分歧**：两套判据用不同的固定值，恰好都"自洽"。

---

## 7. Task 3–5：三个新 Skill 的工具与测试

### 7.1 Task 3 `matlab-signal-vision-ai`（32 → 34 例）

四个工具，每个都配独立方法交叉验证 + 负对照。

| 工具 | 做什么 | 关键验证 |
|---|---|---|
| `mas_spectrum_check` | 频谱泄漏 / 集中度 / Parseval | 抛物线插值测半 bin 偏移 |
| `mas_ofdm_ber` | OFDM+QPSK 全链 BER vs 闭式理论 | 教科书 BER、计数噪声自适应容差 |
| `mas_image_metrics` | IoU / Dice / P / R / F1 / **逐目标** | 手数混淆矩阵、组合恒等式 |
| `mas_split_seed` | 可复现分层切分 + 泄漏检查 | 分层在不平衡数据上必须真的有效 |

**修掉三个真缺陷：**

1. `mas_spectrum_check` 的 Parseval 检查**拿错了比对对象**。加窗周期图的单边 PSD
   积分恒等于**窗加权功率** `sum(x²w²)/sum(w²)`，不是 `mean(x²)`；两者只在矩形窗下重合。
   原实现比 `mean(x²)`、阈值 1e−6，结果任何含随机分量的信号都判失败：实测 Hann 7.3e−3、
   Hamming 6.7e−3、Blackman 9.0e−3，而同一信号换矩形窗一致到 5.3e−16。
   **一个总在响的警告等于没人看的警告。** 改为对恒等式取 1e−8 容差，窗自身影响另立
   `taperBias` 字段——它是关于窗的信息，不是错误。

2. `mas_image_metrics` 文档承诺 `r.perObject` 但代码没有（**幻影引用**）。补齐按目标
   匹配的实现：匹配用 `argmax` 遍历全部 truth 标签而非按索引——`bwlabel` 按列序光栅
   扫描编号，掩膜一旦不一致 `Lp==k` 与 `Lt==k` 就无对应关系，而这正是需要它的场合。

3. `mas_ofdm_ber` 只报数字不自判定，与其他工具不一致。补 `ok/verdict/tol`，且判定是
   **双侧的**：BER 显著低于理论值同样是噪声方差算小的缺陷，不是成功。

### 7.2 Task 4 `matlab-robotics-autonomy`（31 例）

先探测真实可用性：Robotics / Navigation / ROS / Sensor Fusion 均可用，**UAV 未安装**。

| 工具 | 做什么 | 实测要点 |
|---|---|---|
| `mas_kin_check` | 平面 n-R 正运动学 + 解析/差分 Jacobian 逐元素比对 | Jacobian 错了不会抛错、画出来也看不出来，只会让控制器往反方向走 |
| `mas_kin_ik` | DLS + 步长限幅 + 关节限位 | 近奇异（q₂=1e−4）下 DLS 原始步长 **0.12 rad 有界**，正规方程 **6.4e3 rad 发散** |
| `mas_ekf_check` | NEES/NIS 一致性，双侧判定带 `N·ANEES ~ χ²(N·n)` | 一致 1.92 PASS；R 缩 100× → 107 FAIL；R 放大 100× → 0.81 FAIL |
| `mas_frame_check` | SE(3)/SO(3) 卫生检查 | 与 MathWorks `eul2rotm`/`quat2rotm` 交叉核对，偏差 0 与 1.1e−16 |

**同时修掉 `mas_dep_probe` 的一处真缺陷（上一轮我自己引入）：**
`exist(name,'file')` 按文档**只搜索文件与文件夹、明确排除 built-in**。于是把核心内置
函数误报成缺失：`exist('chol','file') → 0`、`exist('svd','file') → 7`（被判成"是目录"）。
后果是探测结果把调用者指向根本不存在的修复动作（改名 / addpath / 安装）。
改为以 `which()` 判定"可调用"，`exist` 只用于说明"为什么不可调用"。

`mas_ekf_check` 的真值用 `Qtrue/Rtrue`、滤波器用 `Q/R`——否则改 `R` 会同时改掉滤波器
与真值，对照实验本身失效。双侧判定是有意的：**把 R 调大只是变保守，不是变正确。**

### 7.3 Task 5 `matlab-codegen-deploy`（11 例）

环境探测：MATLAB/Simulink/Embedded/GPU Coder 全部可用，MSVC 2022 在位，
**仅 HDL Coder 未授权**。因此可以构建**真实编译**的代码生成工具。

| 工具 | 做什么 | 关键设计 |
|---|---|---|
| `mas_codegen_ready` | 静态就绪审计 | blocker（eval/input/clear/load/containers、**循环内**数组增长）vs warning（table/datetime/graphics/异构 cell） |
| `mas_codegen_verify` | **真实** codegen → 编译 → 双跑 → 比较 | 五阶段 probe/codegen/build/run/compare 逐阶段报告；无编译器返回 **SKIP 不是 PASS** |
| `mas_fixpt_range` | 观测输出范围 + 量化代价 | 范围是**观测不是证明**，stimuli 属于结果的一部分；无 Fixed-Point Designer 返回 SKIP 而不用 double 拙劣模拟 |

**修掉三个真缺陷：**

1. `mas_codegen_verify` 的 relative-error 用了**矩阵右除**：`d ./ den` 才是逐元素相对
   误差；写成 `d / den` 对两个列向量得到完整**外积矩阵**，再 `max()` 按列返回行向量，
   下游 `sprintf('%.3e', 向量)` 直接崩。后果是"比较"这一步对任何非标量输出都崩溃，
   **工具从未真正完成过一次 compare**。

2. `exist('codegen','file')==2` 是**假阴性**：`codegen` 是 P 编码文件，`exist` 返回 **6**
   而非 2，于是"没装 Coder"的 SKIP 分支把一台完好、装了 MSVC 的机器判成不可用。
   改为接受任意非零 file/builtin/pcode。`mas_fixpt_range` 的 `fi` 判据同样加固。

3. `codegen -d buildDir` **仍把 MEX 二进制丢进当前目录**。遗留的 stale 二进制会掩盖之后
   的失败重建。cleanup 显式删除 cwd 下的 `fcn_mex.mexw64`。

`mas_codegen_verify` 的 `goldenFcn` 选项存在的意义是：**只能和自己一致的 harness 等于
没测**。默认路径（函数 vs 它自己的 MEX）永远一致，所以必须能构造"真的不一致"的负对照。

---

## 8. Task 6：开发集 / 保留集切分

评测集从 12 条扩到 **15 条**，显式切分：

```
dev       12 条  D1–D8, C1–C3, T1
held-out   3 条  S1, R1, G1   ← 正是 Task 3/4/5 建的工具
```

S1/R1/G1 的**参考推导、grading spec、SHA-256 冻结参考在 Phase 4.2 Task 0 就已就位**
（`mas_ref_derive` / `mas_ref_spec` / manifest 都有这三项），本任务补的是**任务入口
函数**与**注册**，让它们真正跑起来。保留集单独统计，不并入总分——否则一个强开发集
成绩可以掩盖保留集失败，而那正是保留集存在的意义。

### 8.1 保留集暴露的两个真问题

**问题一：`Communications Toolbox` 不在产品映射表里 → `UNKNOWN_PRODUCT` 假阴性。**
S1 被无理由 SKIP。这正是 Task 0 要消除的那类错（环境有能力却被判成没有），
只不过这次发生在**映射表缺条目**而不是 feature 名写错。补入 6 个真实存在的 MathWorks
产品（Communications / RF / Audio / Curve Fitting / Fuzzy Logic / Data Acquisition /
Instrument Control / Econometrics / Symbolic Math），表从 30 行增至 **36 行**，无重复。
实测 Communications Toolbox 现在正确返回 `NOT_LICENSED`（**真实状态**）而非
`UNKNOWN_PRODUCT`（**假阴性**）。

顺带查清：`mas_ofdm_ber` 只用基础 MATLAB 函数（ifft/fft/randn），**根本不需要**
Communications Toolbox——原先的依赖声明本身也是错的，已改为 `[]`。

**问题二：S1 出现"自评 FAIL vs 验证器 PASS"的分歧。**
这是保留集最有价值的产出。查清根因：

```
8 dB 实测 BER 0.000227，理论 0.000191 → 相对偏差 +19%
```

看起来像 bug，其实是**统计现象**：8 dB 处 2.56 万比特只产生 **58 个错误比特**，
泊松相对标准差 ≈ 1/√58 ≈ **13%**。工具内部用固定 15% 容差 → 判 FAIL；
spec 用 20% → 判 PASS。**两边都不是"错"，但两边都不对**：一个固定的百分比容差
不可能同时适配 0 dB（2 万错误、噪声 0.7%）和 8 dB（58 错误、噪声 13%）。

修法不是随手放宽，而是**让容差跟随计数噪声**：

```
tolPt = clamp(3 × 1/√nErr, tolMin=0.15, tolMax=0.45)
```

实测：0 dB → 15%（噪声 0.7%）、4 dB → 15%（噪声 1.8%）、8 dB → **39%**（噪声 13%）。
spec 的 8 dB 容差同步改为 45%（约 3σ）并写明理由。

**放宽之后必须证明它仍然是真闸门**，否则"放宽容差"就变成"不再检查"。新增负对照
`of_negScalingHighSnr`：在 8 dB 处注入接收端 CP 惩罚缺陷（σ² 虚高 25%），
断言缺陷必须落在**同一个容差之外**。实测缺陷偏移远超 39%，正确运行 PASS、缺陷 FAIL。

测试从 32 → **34/34**。其中 `of_tolFollowsCountingNoise` 断言的是**关系**而非硬编码值：
容差比必须显著 > 1（确实放宽了）、但不超过噪声比（没有过度放宽）、且不超 `tolMax` 上限。

> 这里我自己犯了一次刚在 Task 0 批评过的错：新测试断言 `r.tolMax`，而
> `mas_ofdm_ber` 的返回结构里**没有这个字段**——幻影引用。补上后才通过。
> **写断言时要先确认被测对象真的暴露了该字段。**

---

## 9. Task 7：Benchmark 台账（R1 DONE / R2·R3 SKIP）

新增 `mas_bench_record`——一个**机器可读的 benchmark 台账**，替代散落在报告里的
"跑过了"三个字。

### 9.1 为什么是台账而不是一句话

散文声明有三种失效模式，台账逐一封堵：

| 失效模式 | 台账的对策 |
|---|---|
| SKIP 悄悄变成 PASS —— "R2/R3: N/A" 旁边一个绿色总分，读起来就是"全跑了" | `overall` 在任何一项 SKIP 时**只能是 PARTIAL**，代码层面强制 |
| SKIP 的**理由**含糊 —— "no MCP" 分不清是机器上没装还是本会话没绑，两者修法不同（装 vs 绑） | `reason` 取自固定集合，`evidence` 明说 server 二进制是否在盘上 |
| 成绩**不可复现** —— 报告里的数字无法追溯 | 每条 R1 记录带来源文件相对路径 + **SHA-256** |

### 9.2 实测结果（2026-10-19）

```
R1 DONE | R2 SKIP | R3 SKIP -> PARTIAL
R1  3/3 任务, 20/20 checks, 5 次真实工具调用, handshake=1
R2/R3  NO_MATLAB_MCP_TOOL_IN_SESSION
```

**R2/R3 的 SKIP 是绑定缺口，不是缺安装**，这个区分是本轮特意查清的：

- `bin/matlab-mcp-server-windows-x64.exe` **存在**（19.9 MB，2026-10-17 落地）
- R1 在 10-17 **真实跑通过**：`serverStartOk=true`、`handshakeOk=true`、
  发现 5 个真实工具（`evaluate_matlab_code` / `run_matlab_file` /
  `check_matlab_code` / `run_matlab_test_file` / `detect_matlab_toolboxes`）
- 本会话工具列表中**没有** `mcp__matlab*`

所以修法是**绑定 MCP 服务器到会话**，不是重装。台账的 `evidence` 字段直接写明这一点，
避免下一个人去重装一遍。

### 9.3 一处刻意的设计：UNKNOWN 不是 SKIP

第一版 `mas_bench_record` 有一个永远返回 0 的 `count_session_tools()` 桩函数——
它实际上是在**没看的情况下报告"没有工具"**。这正是本项目一直在批的假阴性
（和 `mas_dep_probe` 把 `chol` 报成缺失同一类）。

问题在于：**MATLAB 进程无法枚举宿主 Agent 的工具绑定**。它根本看不到。所以诚实的答案是
`UNKNOWN`，不是猜一个 0。

```matlab
mas_bench_record('report')      % R2/R3 = UNKNOWN（不猜）
mas_bench_record('report', 0)   % R2/R3 = SKIP（调用方声明确实 0 个）
mas_bench_record('report', 3)   % R2/R3 = NOT_RUN（有工具但本版本不驱动）
```

测试 9/9 钉住这个三态，并断言 `overall` 在所有非全 DONE 情况下都是 PARTIAL。

### 9.4 开发过程中自己犯的四次同类错误

写这个工具时我反复踩同一个坑，值得单独记下来：

| # | 错误 | 怎么暴露的 |
|---|---|---|
| 1 | `isfield(d,'discoveredTools') && iscell(d.tools)` —— 幻影字段 | 首次运行 `无法识别字段名 "tools"` |
| 2 | `cellfun` 用在 struct 数组上（`runs` 不是 cell） | 首次运行类型错误 |
| 3 | `max(cellstr)` —— `max` 对 cell 无效 | 改为 `sort` 取末位 |
| 4 | 测试里局部函数引用父函数变量（MATLAB 需 `nested`） | 9/9 全挂，报"输入参数过多" |

第 1 条与 Task 0 批评的 `masacc.availability` 完全同类：**文档/注释里承诺了一个
不存在的字段**。四次里有三次是"引用了不存在的东西"，说明这不是偶发，
而是写这类"跨模块契约"代码时的稳定失效模式——**引用前先确认字段真的存在**。

### 9.5 接入一键验证时又抓到一个更严重的问题

把 `test_bench` 挂进 `run_all` 后，总分显示 **168/168 全绿**，但逐套件检查发现
`bench` 那一行是 `0 / NaN` —— **它根本没跑，而总分看不出来**。

根因在 `run_all` 的错误处理：

```matlab
catch ME
    S(end+1) = struct('name', ..., 'pass', 0, 'total', NaN, 'ok', false);
    nP 不加, nT 不加          % 崩溃的套件不进分母
end
```

一个崩溃的套件贡献 0/NaN，**从分母里消失**，于是 `168/168` 看起来是"全部通过"。
这比任何单个工具的 bug 都危险：它让整个验证体系的结论失效，而且失效方式恰好是
让人放心的那一种。

修法是让崩溃**无法被忽略**：

- `res.suitesErrored` / `res.suitesRun` / `res.allSuitesOk` 三个字段进入结果文件
- 汇总行在有套件崩溃时额外打印 `!!!! N SUITE(S) ERRORED AND WERE NOT COUNTED`

### 9.6 错误处理代码自己崩溃，掩盖了真正的错误

修好上面这条之后，第一次运行仍然失败——但报的是

```
bench  ERROR at run_all line 71
无法识别函数名 'tern'
```

我加的那两行错误报告调用了 `run_all.m` 里**不存在的局部函数 `tern`**。
错误处理代码自己抛异常，于是它想报告的那个错误被替换成了它自己的错误。

这是本轮最值得记的一条：**诊断代码的失败比被诊断的失败更隐蔽**。
现在改成内联条件判断，不引入任何新依赖，并在注释里写明原因。

### 9.7 bench 真正的失败原因：`{T.name}` 的嵌套 cell

拿到真实栈之后才看清：`test_bench` 的返回结构用了

```matlab
res = struct('nPass', ..., 'cases', {T.name});   % 花括号多包了一层
```

`struct()` 遇到 `{T.name}`（1×9 cell 再套一层）会试图构造 **1×9 结构体数组**，
与其它标量字段冲突。麻烦之处在于它**不是稳定报错**——单独调用能过、在
`run_all` 里失败，读起来像"偶发/ flaky"。改为逐字段赋值后彻底稳定。

三条连起来是一个完整的失效链：**崩溃被吞 → 报错误的代码也崩 → 真正的错误是
一个只在特定上下文出现的构造问题**。如果第二步没修，永远看不到第三条。

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
