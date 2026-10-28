# Phase 5.6 任务 1：Benchmark 强制隔离设计与对抗验证

分支 `phase5.1-audit`，HEAD `572641c`（Phase 5.5 冻结点）。探针数据：
[artifacts/phase56/isolation/probe_report.json](artifacts/phase56/isolation/probe_report.json)。
本文只回答一个问题：**三臂对照里"某臂看不到某类信息"这句话，现在是靠什么保证的，以及它到底成不成立。**

## 1. 目标访问矩阵（本轮永久冻结）

| 可读资源 | R1 无 Skill | R2 仅文档 | R3 文档+工具 |
|---|---|---|---|
| 任务提示 + 暂存输入（`input.mat`、`task.txt`） | ✔ | ✔ | ✔ |
| 工程运行时（MATLAB / Simulink / 工具箱 / MCP 执行通道） | ✔ | ✔ | ✔ |
| 九个 Skill 的 `SKILL.md` + `references/` | ✘ | ✔ | ✔ |
| `skills/*/scripts/mas_*` 契约工具 | ✘ | ✘ | ✔ |
| 隐藏评分答案 `answers.json` | ✘ | ✘ | ✘ |
| 评分器私有判据实现（`benchmark/reference_p56.m`） | ✘ | ✘ | ✘ |
| 其他臂的输出与轨迹 | ✘ | ✘ | ✘ |
| 历史成功轨迹（旧留出集运行产物） | ✘ | ✘ | ✘ |
| 编排会话记录（父 transcript） | ✘ | ✘ | ✘ |
| 未发布任务的参考实现 | ✘ | ✘ | ✘ |

统一约束（三臂相同）：同一模型 ID、同一最大 MATLAB MCP 调用数、同一运行时长上限、
同一工具箱与许可、同一交付格式、同一评分标准。

## 2. 对抗探针：11 个向量，11 个达到，0 个被拦住

方法：一个 `general-purpose` 子代理，正常工具权限（Read/Grep/Glob/Bash），按绝对路径逐个
尝试，只有真正取回字节才算"达到"；策略性拒绝不算。结果按向量记录在
`probe_report.json`，探针原始输出在 `<repo-parent>\p56-probes\probe_results\v1_probes.json`。

| 向量 | 目标 | 结果 | 为什么这条重要 |
|---|---|---|---|
| V1/V2 | 新旧两份隐藏答案 | 达到 | 直接读到 `H54-ODE-N` 的判定与字段名 |
| V3 | 兄弟臂 `result.json` | 达到 | 臂间隔离不存在 |
| V5 | NTFS DENY ACE | 达到 | `cp`/`cat`/`python open()` 被拒，但 `icacls /reset` 与 `takeown /f` 都 rc=0 —— **ACL 拦不住拥有该文件的账户** |
| V6 | AES-256-GCM 密文 + 找密钥 | 达到 | 密钥派生行与密文在同一账户可读，解密成功 —— **静态加密在有密钥同盘时等于没有** |
| V7 | 父会话 transcript（22,520,880 字节） | 达到 | 植入的针脚 `P56PROBE-TX-MARKER-fd2401c41b38` 被 grep 到。**编排器说过的任何话对后续 episode 都不是秘密** |
| V8 | 用户级 Skill 安装目录 | 达到 | 7 个 `matlab-*` 目录可读 —— R1 并非 Skill 盲 |
| V9 | 仓库 Skill 文档 + 9 个 `mas_*.m` 源码 | 达到 | 从 R1 风格工作区用绝对路径直读 |
| V10 | 评分器源码 + 历史评分产物 | 达到 | 支持 `exact/abs/rel/maxabsdiff/min/max`；`manifest` 哈希只能查**篡改**，查不到**读取** |
| V11 | MATLAB MCP 主机执行通道逃逸 | 达到 | `system('whoami')` = `liuliye\23201`；`fileread` 读到 phase54 答案 2621 字节（sha256 前缀 `a3e279f77955082b`，与冻结清单一致）、父 transcript 21,749,205 字节、用户级 SKILL.md、`mas_ode_check.m` |

V11 是决定性的：**只要手臂还需要主机侧的 MATLAB 执行通道，任何 confine 了文件工具但
没 confine 执行工具的沙箱都不是边界。**

探针副作用披露：V5 升级测试把它自己的诱饵文件的 DENY ACE 清掉了（`p56-probes/decoys/`
内，故意保留以便复核）。未改动用户文件、未改动 `~/.qoder-cn/skills`、未改动 C 盘系统 ACL、
未创建账户、未启动或配置沙箱功能。V11 只回传字节数与哈希前缀，刻意不把明文答案送进
编排器 transcript。

## 3. 候选隔离原语实测评估

| 原语 | 状态 | 依据 |
|---|---|---|
| Prompt 里写"禁止访问" | 规格直接否决 | V1–V11 |
| NTFS DACL / DENY ACE | 不可强制 | V5 |
| 静态加密 | 不可强制（密钥同盘） | V6 |
| 工作区里不放某路径 | 不可强制 | V9/V11 |
| Windows Sandbox | 本机不可用 | 可选功能查询需提权，DISM COM 失败；启用它属于我无权做的系统改动 |
| Docker Desktop（守护进程在线，v29.8.2） | 对"不受信主体"不适用 | 容器能关住 CLI 代理，但 Qoder 子代理在主机运行；容器化的臂仍需主机 MATLAB，V11 已证明该通道可达主机文件系统 |
| 受限次级账户 | 不由我创建 | 本机已存在 Codex CLI 建的 `CodexSandboxOffline/Online`；创建或改账户属于系统级改动，未获授权 |

## 4. 结论

**强隔离 = BLOCKED。** 在这台机器、这个客户端里，不改动用户系统的的前提下，没有任何
我可用的访问控制能阻止一个 episode 读到隐藏答案、其他臂结果、历史轨迹、评分器内部、
用户级 Skill 或编排器 transcript。11/11 达到。

按规格要求明确三点：这不是"程序性隔离"被美化成强隔离；不声称隔离成功；
**因此任何"R1/R2/R3 因为 Skill 暴露不同而表现不同"的因果增益结论都被阻塞** ——
因为现有留出集的期望答案全都预先存在于本卷。

### 仍然真实有效的四类控制（不是边界，是可信度控制）

1. **两阶段封存 = ENFORCED-BY-ABSENCE**：任务与输入先冻结并公布哈希，期望答案在全部
   episode 结束、transcript 落盘之后才生成。episode 读不到一个当时还不存在的文件。
   可用全盘搜索验证其"不存在"。→ **已实现并测试，见 §6**（43/43，含 canary 正反两向）。
2. **承诺（commitment）**：产出答案的参考实现、它的单元测试、任务集在 episode 之前就已
   提交，评分标准无法事后挑选。
3. **泄漏检测而非泄漏阻止**：transcript 逐条记录真实工具调用，读评估侧路径当场可查，
   命中即标 `INVALID_FOR_COMPARISON` 并丢弃，不混入统计。
4. **编排器卫生**：臂盲内容不得进入编排器会话（V7 证明 transcript 本身是泄漏面）。

### 真隔离的充分条件（需用户批准，我未执行）

手臂主体与其工具层以**非属主、非管理员的独立身份**运行，或 MATLAB 也一起搬进 VM/容器，
使 V5/V6/V11 的升级路径不适用；同时封存答案与其他臂结果放在 episode 无法寻址的主机上。

## 5. 探索性运行的强制披露格式

每个隔离不足的 episode 必须同时交付：臂、模型 ID、是否读过评估侧路径（逐条调用）、
是否读过其他臂产物、是否读过 Skill/`mas_*`（R1/R2 读了即失效）、判定与字段、预算事实。
报告里凡引用这类数据，一律写 `EXPLORATORY（隔离未强制）`，不得写成因果结论。

## 6. 补偿控制的实现与证据（本轮完成）

规格要求"不能只靠 Prompt 写禁止访问"。既然真边界拿不到，就把能强制的那部分**实现成代码并测它**。

### 6.1 两阶段封存（absence by design）

| 文件 | 作用 |
|---|---|
| [benchmark/tasks_p56.json](benchmark/tasks_p56.json) | 三个永久冻结任务（normal/boundary/fault），**不含** skill/tool/verdict 字段 |
| [benchmark/benchmark_publish.m](benchmark/benchmark_publish.m) | 阶段一：公布任务 + 物化 `inputs_*.mat`，剥离期望值，公布哈希，拒绝二次发布 |
| [benchmark/reference_p56.m](benchmark/reference_p56.m) | 答案生成器：只以 **SHA-256 承诺**出现在 bundle 里，内容不落地 |
| [benchmark/benchmark_seal.m](benchmark/benchmark_seal.m) | 阶段二：校验承诺、episode 完成时刻、单次使用，然后才生成 `answers.json` |
| [benchmark/benchmark_expectation_shape.m](benchmark/benchmark_expectation_shape.m) | 判据：**形状**而非词汇 —— `"verdict":"PASS"`、`"ref":`、`"answersSha256":"` |
| [benchmark/benchmark_scan_for_answers.m](benchmark/benchmark_scan_for_answers.m) | 泄漏扫描器，`bundle` 严格模式与 `workspace` 臂模式两套规则 |
| [matlab/validation/phase56/p56_stage.m](matlab/validation/phase56/p56_stage.m) | 三臂工作区搭建 + 臂不变式断言 |
| [matlab/validation/phase56/p56_absence_scan.m](matlab/validation/phase56/p56_absence_scan.m) | 全盘"不存在"验证 + episode 前承诺复核 |

时间顺序是定义性的：`publish → 承诺哈希 → 全部 episode 结束 → seal → grade`。
`benchmark_seal` 拒绝任何 `finishedAt` 晚于封存时刻的 episode，也拒绝二次封存。

### 6.2 三臂实际暂存内容（不是口头承诺，是目录清单）

```
task         arm   files  .mat    .m   .md     mas_*.m
P56-SIG-B    R1        3     1     0     1           0
P56-SIG-B    R2       23     1     0    21           0
P56-SIG-B    R3       79     1    54    21          54
```

R1 = 输入 + prompt + 环境说明，3 个文件，0 个可执行、0 份 SKILL.md；
R2 = 21 份文档，0 个 `.m`；R3 = 54 个 `mas_*.m`。三臂 `prompt.txt` **字节相同**（按 SHA-256 比较），
prompt 里不出现 `mas_`、不出现 skill 名、不出现 routing 词汇。每次暂存先 `rmdir(d,'s')` 重建目录，
避免上一轮更宽臂的残留文件静默变成更窄臂的输入。

### 6.3 测试：43/43，其中 12 条是"必须失败"的负例

日志 [artifacts/phase56/isolation/seal_and_staging.log](artifacts/phase56/isolation/seal_and_staging.log)：
`test_two_phase_seal` 22/22 + `test_p56_stage` 21/21，已注册进质量门禁（`run_all.m` 第 28 个套件）。

负例覆盖：二次发布、脏 bundle 里发布、episode 未跑完就封存、封存后改 prompt、
换答案生成器、重复封存、R1/R2 混入可执行工具、把 episode 自己的 `result.json` 误判成泄漏。
正例里最有分量的是 canary：往 R1 工作区种一个 `answer_key.json`（含 `"verdict":"PASS"` 与任务 id），
扫描必须拒绝运行并在报告里点出该路径 —— 种下前它报 clean，"clean" 因此才有含义。

冻结值（本轮之后不得改动）：tasks `9ffb788f81378fdf…6793cbdb`，public bundle `acb276afe0f9f144…5357a4f8`，
答案生成器承诺 `8c85a00c8fa67f09a0fcf200…edc83fc9`。

### 6.4 不存在性验证结果

`p56_absence_scan` 扫描 315 个暂存文件 + bundle + 全部臂目录树：**Phase 5.6 期望值 0 命中**，
phase56 评估根下封存产物 0 个，生成器哈希与承诺一致。

同一份报告必须说的坏消息：扫描范围内另有 **3 份历史封存产物**，其中一份就在本仓库里
（`benchmark/dev/answers.json`），其余在 `MATLAB-bench-holdout-phase53/54`。也就是说
"本卷存在旧答案、且按 §2 的 V1/V11 绝对路径可达"这句话没有被任何新代码改变。
P56 之所以还站得住，只是因为 P56 的答案此刻**还不存在**，不是因为读者被挡住了。

### 6.5 这套检测器的能力边界（写清楚，免得被当成边界）

1. 它能抓**答案文件的副本**；抓不到有人把数字手抄进一个 Innocent 名字的文件。
2. 它按**形状**匹配，因此 `"verdict"` 作为字段名出现在剥离清单里不算命中。
3. 臂目录整体扫描只豁免一个文件名：episode 自己被要求写的 `result.json`。
4. 扫描发生在封存前/运行前，属于**事后取证**，不是访问控制。
5. 检测器自己的注释里引用了它要找的形状，所以不要把它指向 `benchmark/` 本身。

### 6.6 本轮实现过程中修掉的三个自找错误

- `dir('<root>/**')` 的 `.name` **不含子路径**：九份 SKILL.md 塌成九个同名条目，
  暂存清单和扫描都失去定位能力 → 改为用 `.folder` 重建相对路径。
- `for q = 1:numel(h)` 遍历的是**单元元素**而不是行：一条命中（1×2）会跑两圈并在第二圈越界；
  clean 扫描时该 bug 完全隐身，正是 canary 测试把它逼出来的 → 改为 `size(h,1)`。
- `struct('a',[])` 是 **1×1**（字段为空），`struct('a',{})` 才是 0×0：
  空命中列表被 `numel` 数成 1，"clean" 打印成 "1 hit(s)" → 改用 `{}` 构造。

