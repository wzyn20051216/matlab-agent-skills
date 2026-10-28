# Phase 5.7 任务 4：泄漏面复测与强隔离评估

分支 `phase5.1-audit`，HEAD `9543f36`（Phase 5.6 冻结点，本轮未提交）。
探针：[p57_leak_surface_probe.py](matlab/validation/phase57/p57_leak_surface_probe.py)
与 [p57_isolation_probe.m](matlab/validation/phase57/p57_isolation_probe.m)；
证据：[leak_surface_probe.json](artifacts/phase57/isolation/leak_surface_probe.json)、
[matlab_state.json](artifacts/phase57/isolation/matlab_state.json)。

## 0. 结论

**强隔离 = BLOCKED。本轮不开展 Task 5 的正式三臂增益实验，也不产出任何因果结论。**

2026-10-23 复测了 9 类 26 个泄漏面，**26/26 达到**（只有真正读到字节才算达到）。
六个客户端/账户控制项没有一项拦住了访问。Phase 5.6 的 11 个对抗向量同样仍全部达到，
本轮的新增事实是：**即使删掉 `answers.json`，答案仍可由仓库内的生成器 + 任务集精确重算；
父会话 transcript 本身就是一份包含 2031 处 P56 任务 id 的可读历史轨迹。**

这不是"程序性隔离"被写成强隔离。26 个面全部是普通读权限下达到的，没有利用漏洞、
没有提权、没有改 ACL、没有用管理员令牌。

## 1. 方法与边界

1. 所有探针**只读**：读取文件后记录字节数、SHA-256 与元数据，**不把答案值写入报告或对话**。
2. 文件面用普通 Python 进程探测；MATLAB 面用**手臂实际使用的 MCP evaluate 通道**探测。
3. "达到"的定义：成功取回字节。策略性拒绝、路径不存在、仅目录存在都不算。
4. 本轮未修改账户、ACL、Skills 安装根、MATLAB 全局配置或系统功能。唯一的会话内写入是
   一个临时变量 `P57PROBE_CANARY_7f31`（设值→下一次调用读回→清除），用于验证共享工作区。
5. 当前的 MATLAB 会话在探测时是干净的：0 个仓库/评估侧路径项，`mas_ber_check` 等 4 个工具
   均不可解析，`pwd` 已回到 `C:\Users\23201\Documents`。**"干净"是上一次清理的结果，不是边界。**

## 2. 九类泄漏面实测

| 类别 | 数量 | 达到 | 代表性证据 |
|---|---:|---:|---|
| 参考答案生成器 | 4 | 4 | `reference_p56.m` 可读，SHA-256 `8c85a00c8fa6…` 与冻结承诺**逐字节一致** |
| 历史答案 | 5 | 5 | Phase 5.6 `answers.json` `5397be4b…` 3 个任务；Phase 5.4 6 个任务；Phase 5.3 两版各 9 个任务；`benchmark/dev` 3 个任务 |
| 评分器源码 | 5 | 5 | `benchmark_grade.m`（230 行）、`benchmark_grade_v2.m`（414 行）、`benchmark_expectation_shape.m`、`mas_grade.m`、`mas_refcheck.m` |
| 其他臂输出 | 3 组 | 3 组 | 9 份 `arm_R*/result_*.json` + 3 份 `grade_R*.json` + 9 份 episode 产物 |
| Skills 安装根 | 5 | 5 | `.qoder-cn` 7 个（陈旧）、`.agents` 9 个、`.workbuddy` 9 个（陈旧）、仓库 9 个；Task 2 的显式会话已证明**代理**能读 `.agents`，不只是 OS 能读 |
| MATLAB 共享状态/路径 | 1 | 1 | 两次独立 evaluate 调用共享一个工作区（canary 读回）；探测时 base 工作区 47 个变量 |
| 命令执行 | 1 | 1 | 从 MCP 通道执行 `system('whoami')`，rc=0，输出 `liuliye\23201` |
| 可推导答案 | 1 | 1 | 用仓库内生成器 + 任务集重算，3/3 任务与封存答案**逐字段相等** |
| 历史轨迹 | 1 | 1 | 12 份 episode transcript 共 1,564,191 字节且哈希未变；父会话 transcript 34,075,136 字节，含 2031 处 P56 任务 id |

### 2.1 可推导性是最关键的新发现

`reference_p56.m` 是闭式公式（QPSK BER、Wilson 区间、二项 z、解析 ODE），不调用任何
`mas_*` 工具；`tasks_p56.json` 发布时已公开。探针把生成器指向临时文件，重算后与
`<repo>-bench-phase56\eval\answers.json` 比较：**3/3 个任务的 skill、tool、
verdict 与全部 fields 的 name/op/ref/tol 完全一致**。临时文件已删除。

含义：即使把 `answers.json` 从磁盘移除，只要手臂能读仓库并执行 MATLAB，答案仍然可得。
"把答案藏起来"不是控制；**答案的可推导性必须和答案文件一起评估**。

### 2.2 共享 MATLAB 状态：当前干净，但通道存在

- 探测时路径干净：0 个 `MATLAB\skills`/`benchmark`/`MATLAB-bench` 项，4 个 `mas_*` 均不可解析。
- 但两次独立调用共享同一个工作区：第一次 `SET=1; NVARS=30`，第二次 `READ=731945`，随后清除。
- 因此 `p56_session_reset.m` 是**清理**，不是**隔离**。一个手臂只要 `addpath` 或留下变量，
  下一次调用就能看见；没有任何东西阻止它这么做。跨客户端/跨账户的共享未在本轮测试。

### 2.3 历史轨迹与父会话

12 份 Phase 5.6 episode transcript 全部可读，哈希与 Task 0 基线一致（未被篡改）。
当前父会话 transcript 34,075,136 字节，含 2031 处 `P56-*` 任务 id。Phase 5.6 的 V7 已经
证明：编排器说过的任何话，对后续 episode 都不是秘密。本轮没有改变这一点。

### 2.4 Skills 安装根

| 根 | MATLAB Skills | 状态（Task 1 审计） |
|---|---:|---|
| `C:\Users\23201\.qoder-cn\skills` | 7 | 7 个陈旧；Qoder 对其中 7 个优先使用此根 |
| `C:\Users\23201\.agents\skills` | 9 | 5 current / 4 drifted（Codex 全部从此根发现） |
| `C:\Users\23201\.workbuddy\skills` → `<workbuddy-data>\skills` | 9 | 9 个陈旧；加载未观测 |
| `<repo>\skills` | 9 | 仓库源 |

即使把 `.qoder-cn` 同步到最新，**"安装正确"也不等于"隔离"**：R1 仍能按绝对路径读仓库
`skills/`，Task 2 的显式会话已经用普通 Read 工具读到了 `.agents/skills/matlab-orchestrator/...`。

## 3. 为什么"在 Prompt 里禁止"不成立

Phase 5.6 的 V5 已证明：拥有文件的账户可以用 `icacls /reset`、`takeown /f` 清掉 DENY ACE，
rc=0。V11 已证明：只要手臂还需要主机侧 MATLAB 执行通道，`system()` 就能读父 transcript、
历史答案和用户 Skills。本轮的 26 个面是同一权限模型下的再次确认。

**任何仅靠提示词、工作区目录布局、文件改名或静态加密的方案，都不构成本轮定义的强隔离。**

## 4. 候选隔离方案 A–D

评估标准：能否阻止"手臂主体"（模型 + 其文件/执行工具）读到评估侧资产；而不是能否让
编排器"不展示"这些资产。

### A. 非属主本地账户 + 最小 ACL（同机）

- **做法**：新建标准用户（非管理员），让 Qoder/Codex 客户端与 MATLAB 都在该身份下运行；
  评估侧资产（`MATLAB-bench-phase56\eval`、历史答案、仓库 `reference_p56.m`、父 transcript）
  对属主与 SYSTEM 可见、对该账户拒绝；每个手臂的工作区单独授权；网络禁用。
- **能覆盖**：V1–V10 类文件读取；V11 的 `system()` 也只能以非属主身份运行，读不到属主
  评估资产（前提是 ACL 与配置文件权限都设置正确）。
- **需要改动**：创建本地账户（管理员）、MATLAB 在该账户下的许可/激活、Qoder/Codex 的
  独立登录与配置、评估目录 ACL、每臂工作区 ACL、可能的客户端重启。
- **残留风险**：同机内核与 MATLAB 进程仍共享硬件；手臂可写自己的 profile，必须在臂间
  清理；MATLAB 许可证是否允许第二身份需先做一次试运行；ACL 配置错误会静默放行。
- **结论**：`VIABLE-WITH-APPROVAL`，且必须先做一次"账户 + MATLAB + 单臂读取"试运行。

### B. Windows Sandbox / Hyper-V 虚拟机

- **做法**：VM/沙箱内安装 MATLAB 与客户端，快照按臂回滚；宿主只以只读方式映射任务包，
  不映射评估侧、Skills 安装根或父 transcript；关闭剪贴板/共享文件夹/网络（或许可服务器
  单独放行）。结果通过单向导出目录取回。
- **能覆盖**：文件读取、主机命令执行、跨臂状态；比 A 更接近真正的边界。
- **需要改动**：管理员启用 Windows Sandbox 或 Hyper-V（可能需重启）；MATLAB 许可证；
  约 20–40 GB 磁盘；VM 内客户端登录。
- **残留风险**：虚拟化逃逸不在本轮可测范围；许可证与 GPU/工具箱可用性需验证；启动成本高。
- **结论**：`VIABLE-WITH-ADMIN-APPROVAL`，是这台机器上最现实的真边界。

### C. 远程一次性执行器（CI/容器）

- **做法**：每个臂在一次性容器/CI job 中运行，只挂载任务包，结果单向导出；评估侧不在
  容器可达范围内。
- **阻塞点**：容器内必须同时有 MATLAB 与可用的模型客户端。MATLAB 容器需要 MathWorks
  容器许可与镜像访问；本机没有该授权，也没有可用的远程执行服务。没有 MATLAB 的执行器
  会改变任务本身，不能用于本 Benchmark。
- **结论**：`BLOCKED-ENVIRONMENT`（配额/网络/许可），不是本轮可实施项。

### D. 物理隔离 / 人工单向传递

- **做法**：第二台机器（有 MATLAB 许可、无到本机的网络路径）运行手臂；任务包经移动介质
  单向传入，结果人工带回。
- **能覆盖**：所有主机侧读取与执行通道；是本清单里最强的边界。
- **代价**：需要第二台机器与许可；每臂人工操作，无法自动统计；Skills 版本也需人工同步。
- **结论**：`VIABLE-MANUAL`，不需要改本机系统，但不适合本轮自动化闭环。

| 方案 | 文件读取 | 主机命令 | 共享状态 | 父 transcript | 改动级别 | 结论 |
|---|---|---|---|---|---|---|
| A 非属主账户 + ACL | 可覆盖 | 可覆盖 | 可覆盖（需臂间清理） | 可覆盖（profile ACL） | 系统账户/ACL | 待批准试运行 |
| B Sandbox/VM | 可覆盖 | 可覆盖 | 可覆盖（快照） | 可覆盖（不映射） | 管理员 + 重启 | 待批准 |
| C 远程容器 | 可覆盖 | 可覆盖 | 可覆盖 | 可覆盖 | 外部服务/许可 | BLOCKED |
| D 物理隔离 | 可覆盖 | 可覆盖 | 可覆盖 | 可覆盖 | 第二台机器 | 可人工实施 |

## 5. 权限申请（未执行）

以下动作**均未执行**，仅作为批准后的实施方案。批准前不会创建账户、不会修改 ACL、
不会启用 Windows 功能、不会改动 MATLAB 许可或全局配置。

### 5.1 申请项

| # | 动作 | 目的 | 影响面 | 回滚 |
|---|---|---|---|---|
| P1 | 创建本地标准用户 `masarm`（非管理员） | 让手臂以非属主身份运行 | 新账户、用户目录、客户端配置 | 删除账户与其 profile |
| P2 | 在该账户下验证 MATLAB R2026a 启动与许可 | 确认手臂能执行 MATLAB | 许可占用/激活 | 停用该账户的许可会话 |
| P3 | 对 `<repo>-bench-phase56\eval`、历史 holdout 答案、`benchmark/reference_p56.m` 设置"属主+SYSTEM 可读，masarm 拒绝"的 ACL | 阻断答案与生成器 | 仅这些目录/文件 | `icacls /save` 备份后 `/restore` |
| P4 | 对 `C:\Users\23201\.qoder-cn\projects`（父 transcript）设置同样的 ACL | 阻断历史轨迹 | 仅该目录 | 同上 |
| P5 | 为每臂准备独立工作区与 Skills 根，并在臂间清理 profile 临时目录 | 防止跨臂残留 | 新目录 | 删除新目录 |
| P6 | 在手臂运行期间禁用其网络（或仅允许许可服务器） | 防止外传 | 该账户网络策略 | 恢复策略 |
| P7 | 以 `masarm` 启动客户端并完成一次单臂读取探针 | 先验证边界，不直接跑正式实验 | 客户端进程 | 关闭进程 |

### 5.2 未执行的命令（示例，不是已执行记录）

```powershell
# P1（需要管理员）
New-LocalUser -Name masarm -NoPassword
Add-LocalGroupMember -Group Users -Member masarm
# P3/P4（先备份 ACL，再收紧）
icacls "<repo>-bench-phase56\eval" /save "artifacts\phase57\isolation\acl_backup_eval.txt" /t
icacls "<repo>-bench-phase56\eval" /inheritance:r /grant:r "23201:(OI)(CI)F" "SYSTEM:(OI)(CI)F"
# P7（批准后）
# 以 masarm 运行客户端，重复 13 个对抗向量，要求 0 个达到
```

### 5.3 批准清单

- [ ] 同意创建本地非管理员账户
- [ ] 确认 MATLAB 许可允许第二身份运行
- [ ] 同意对评估目录与父 transcript 做 ACL 收紧（含备份/回滚）
- [ ] 同意手臂运行期间禁用网络
- [ ] 同意以试运行结果决定是否进入 Task 5

未获批准前：**Task 5 不启动。**

## 6. 批准后的对抗验收（先于任何正式增益实验）

在 `masarm` 身份下重复并扩展 Phase 5.6 的 11 个向量，再加本轮新增的 2 个：

| # | 向量 | 通过条件 |
|---|---|---|
| V1–V10 | 历史/当前答案、兄弟臂、评分器、用户 Skills、仓库 Skills、ACL 升级、静态加密、父 transcript | 全部 `BLOCKED` |
| V11 | MATLAB MCP `system()` 读评估侧/父 transcript | `BLOCKED`（非属主身份下拒绝） |
| V12 | 可推导答案：生成器 + 任务集重算 | `BLOCKED`（生成器不可读或执行身份不可达） |
| V13 | 共享 MATLAB 状态：canary、path、base 变量 | `BLOCKED`（每臂独立进程/快照） |

验收必须含**正控**：在 `masarm` 自己的只读任务包上必须能读到字节；否则"全 BLOCKED"
可能只是探针坏了。0/13 达到且正控通过，才允许讨论 Task 5；届时仍需预注册样本量、
评分协议与统计方法，不能把探索性观测当因果结论。

## 7. 当前允许与禁止的事项

**允许**：继续 Task 6/7/8 的工程契约、评分协议、并发诊断、回归与交付；继续把已有结果
标注为 `EXPLORATORY（隔离未强制）`。

**禁止**：声称 R1/R2/R3 的差异由 Skill 暴露造成；把 Phase 5.6 的 0/2/3 重算结果当作
新实验；在未通过 V1–V13 前运行 Task 5；修改用户系统目录、ACL、全局配置或官方 MCP Server。
