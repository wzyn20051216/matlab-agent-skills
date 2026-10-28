# Phase 5.8 · 任务 5：隔离方案评估（仅设计，未实施）

日期：2026-10-23
分支：`phase5.1-audit`
范围：Task 5（A 非管理员账户 / B Windows Sandbox·Hyper-V / C 远程执行 的可行性设计）
本文档状态：**DESIGN-ONLY**。`artifacts/phase58/isolation/` 为空目录，本轮没有产生任何强隔离证据。

## 0. 结论先行

| 问题 | 结论 |
| --- | --- |
| 本轮是否创建了系统账户 | **没有**（0 次 `New-LocalUser`，未查询过账户列表） |
| 是否修改了 ACL | **没有**（0 次 `icacls` / `takeown` 写入；未对任何真实目录收紧或放开权限） |
| 是否启用了虚拟化 / Windows Sandbox | **没有**（未启用可选功能，未新建虚拟机或快照） |
| 是否改了 MATLAB 全局配置或许可 | **没有**（未改 `matlabroot` 设置、未新增激活、未改启动项） |
| 是否跑了正式三臂因果增益实验 | **没有**。前置条件 V1–V13 在 Phase 5.7 的实测是 **13/13 达到**（即隔离完全失效），门槛远未满足 |
| 本轮实际依赖的隔离 | **程序性隔离**：仓库内一次性 fixture 项目 + 其 `.agents/skills` 副本 + `codex exec --ephemeral`；它对"安装同步"够用，对"泄漏阻断"不够用 |
| 三个方案里当前最可行的 | **B（Sandbox/VM）** 是真边界，但需管理员与重启；**A（非管理员账户）** 成本最低但需 MATLAB 许可试运行；**C（远程执行）** 在本机条件下 `BLOCKED-ENVIRONMENT` |

与 Phase 5.7 的分工：[PHASE5_7_ISOLATION_ZH.md](PHASE5_7_ISOLATION_ZH.md)
已把 26 个泄漏面和 13 个对抗向量测到底，本轮不重复测量，只做两件事——
（1）把方案按 **Phase 5.8 的目标**（普通用户装的版本＝客户端实际加载的 Skill＝MATLAB 执行流程＝最终交付）
重新对齐；（2）给出批准后可以直接执行的最小步骤与回滚点。

## 1. 本轮真正用过的隔离（可复现、已验证、但不算强隔离）

| 机制 | 位置 | 验到了什么 | 验不到什么 |
| --- | --- | --- | --- |
| 一次性 fixture 项目 | `artifacts/phase58/native/fixtures/task_*`，各自带 `.agents/skills` 副本 | 客户端能在只含仓库 Skill 副本的目录里发现并读取安装副本；`projectScoped=true`、用户级根读取 0 次 | 同一 OS 身份下，进程仍**有权**读用户级根与仓库源（探针只是没去读） |
| `codex exec --ephemeral` | `matlab/validation/phase58/p58_codex_task_probe.py` | episode 之间不落会话历史，减少跨臂串扰 | 不阻断文件系统读取 |
| 前后快照哈希对比 | `p58_native_evidence.m` 的 `root_compare()` | 45 份安装副本在探针前后逐文件一致 → **探针确实没写用户根** | 不能证明别人（别的工具、别的会话）没写 |
| 链接根边界 | `Sync-Skills.ps1` + `SkillSync.Phase58.Tests.ps1:73` | 拒绝把同步目标落到符号链接之下，WorkBuddy 只能同步到 `.workbuddy` 链接指向的物理数据目录，避免误操作整个数据目录 | 不涉及权限模型 |
| 首次安装 / 升级 / 重复同步零写入 / 接管 / 回滚 / 备份恢复 | `SkillSync.Phase58.Tests.ps1`、`Installer.Scenarios.Tests.ps1`、`p58_sync_rediscovery.m` | 8 类用户安装场景在隔离目录里全部通过（详见 [PHASE5_8_INSTALL_ZH.md](PHASE5_8_INSTALL_ZH.md) §1） | 这些是**同身份**目录隔离，不是账户/主机边界 |

诚实表述：**"隔离目录"能证明同步引擎不出错，不能证明手臂拿不到答案。**
Phase 5.7 已经把后者测死（26/26 达到，含 `system('whoami')` 与可读的 34 MB 父 transcript），
本轮没有任何新证据削弱那个结论。

## 2. 三个方案按 Phase 5.8 目标重排

Phase 5.8 想验的东西其实分两层，方案适配度不同：

- **U 层（用户交付一致性）**：普通用户装完之后，客户端是否发现新版本、是否加载、
  MATLAB 是否按 Skill 跑通、交付是否被独立验收。这层需要的是"干净的用户环境"，
  不一定需要强隔离。
- **B 层（泄漏阻断）**：手臂读不到评估侧资产，才能谈因果增益。这层需要账户/主机边界。

| 维度 | A 非管理员账户 | B Windows Sandbox / Hyper-V | C 远程一次性执行 |
| --- | --- | --- | --- |
| U 层：模拟"全新用户首次安装" | **优**：新 profile 天然没有历史 Skills，能真验 `.agents`/`.qoder-cn` 首次落盘 | **最优**：快照回滚 = 每次都是全新机器，最适合版本漂移实验 | 可行，但要先把客户端与 MATLAB 塞进镜像 |
| U 层：客户端能否运行 | 取决于 Qoder/Codex 在该账户下的登录与配置目录 | 需在沙箱内重新登录，Qoder 是否有该账户许可未知 | **未知**，很可能不允许在容器内登录客户端 |
| U 层：MATLAB 可达 | 需先做许可试运行（同机第二身份） | 沙箱/VM 内需再装一次 MATLAB（约 20–40 GB） | 需要 MathWorks 容器许可，本机没有 |
| B 层：文件读取（V1–V10） | 可覆盖（前提：评估资产 ACL 收紧正确） | 可覆盖（宿主资产不映射进去） | 可覆盖 |
| B 层：主机命令（V11） | 可覆盖，非属主身份 | 可覆盖 | 可覆盖 |
| B 层：可推导答案（V12） | **需要额外动作**：`benchmark/reference_p56.m` 与 `tasks_p56.json` 同在仓库内，仓库一旦对臂可读，V12 仍可推导 → 必须把生成器移出可读范围 | 同上，靠"不映射仓库源"解决 | 同上，靠镜像里不放生成器解决 |
| B 层：共享 MATLAB 状态（V13） | 需每臂独立 MATLAB 进程 + profile 清理 | **最优**：按臂快照回滚，进程与磁盘状态一起归零 | 每臂一个容器，天然独立 |
| 改动级别 | 系统账户 + ACL | 管理员启用功能、可能重启 | 外部服务 / 许可 / 网络 |
| 结论 | `VIABLE-WITH-APPROVAL`，先做一次单臂试运行 | `VIABLE-WITH-ADMIN-APPROVAL`，本机最现实的真边界 | `BLOCKED-ENVIRONMENT`，本轮不可实施 |

补充一个本轮已在用、**无需任何批准**的选项：

| 维度 | D 临时 profile 重定向（现有做法的形式化） |
| --- | --- |
| 做法 | `HOME`/`USERPROFILE` 指到 `artifacts/phase58/native/fixtures/` 下的假根，Skill 根用相对项目路径 |
| U 层 | 足够验同步引擎、首次安装、零写入回滚 |
| B 层 | **完全不够**：同一账户、同一内核、同一 MATLAB 会话 |
| 批准 | 不需要 |
| 结论 | `PROCEDURAL-ONLY`，不得用它替代 A/B 的结论 |

## 3. 批准后的最小实施步骤（本轮未执行）

### 3.1 A：非管理员账户

1. 先做**只读前提检查**（无需批准）：确认 MATLAB 许可类型是否允许第二身份、
   Qoder/Codex 是否能在该账户下登录；
2. 创建 `masarm`（非管理员）→ 在该账户下启动一次 MATLAB → 记录能否执行；
3. 备份 ACL（`icacls /save`）后再收紧评估目录与父 transcript；
4. 只跑**一个**单臂 episode + 13 个对抗向量，不跑正式实验；
5. 验收：V1–V13 **0/13 达到**，且**正控必须能读**（在 `masarm` 自己的任务包里必须取回字节），
   否则视为探针失效而不是隔离成功；
6. 回滚：删除账户及其 profile，`icacls /restore` 备份。

```powershell
# 以下为批准后示例，本轮未执行。路径按本机实际位置取值，不写死盘符。
$repoRoot = (Get-Location).Path          # 仓库根
$evalDir  = Join-Path (Split-Path $repoRoot -Parent) 'MATLAB-bench-phase56\eval'
$me       = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
New-LocalUser -Name masarm -NoPassword
Add-LocalGroupMember -Group Users -Member masarm
icacls $evalDir /save (Join-Path $repoRoot 'artifacts\phase58\isolation\acl_backup_eval.txt') /t
icacls $evalDir /inheritance:r /grant:r "${me}:(OI)(CI)F" "SYSTEM:(OI)(CI)F"
```

风险与失效模式：ACL 配错会**静默放行**，因此第 5 步的对抗向量必须在收紧之后、
正式实验之前重跑一次；同身份的历史 MATLAB 会话（长驻 MCP）不受新账户影响，
必须显式重启 MATLAB MCP 服务，否则 V13 仍以旧身份运行。

### 3.2 B：Windows Sandbox / Hyper-V

1. 启用功能（管理员，可能重启）→ 新建专用实例；
2. 沙箱/VM 内安装 MATLAB + 客户端；宿主侧**只映射任务包（只读）**，
   不映射仓库 `skills/`、不映射评估目录、不映射 `<home>\.qoder-cn\projects`；
3. 每臂开始前回滚快照 → 跑臂 → 单向导出结果目录 → 再回滚；
4. 验收同 A（V1–V13 全部 BLOCKED + 正控可读）；
5. 回滚：关闭功能即恢复原状，宿主不留残余。

代价：MATLAB 许可证占用一份、磁盘 20–40 GB、工具箱与 GPU 可用性需先验证；
虚拟化逃逸不在可测范围，不能声称"绝对安全"。

### 3.3 C：远程一次性执行

阻塞点没有变化，本轮未探测任何外部执行服务：容器内必须**同时**具备 MATLAB
与可登录的模型客户端，MathWorks 容器许可与镜像访问本机都没有。
没有 MATLAB 的执行器会改变任务本身，不能用于这个 Benchmark。
→ `BLOCKED-ENVIRONMENT`。若将来获得许可与镜像，方案要重新评估，
且必须先确认"远程执行器是否也让手臂能读到评估侧资产"。

## 4. 正式因果增益实验的前置门（未满足）

按 Phase 5.7 §6 与本轮结论，进入正式三臂实验之前**全部**成立才允许讨论：

- [ ] 隔离环境（A 或 B）已实施，且 MATLAB 在执行身份下可用
- [ ] V1–V13 重测为 **0/13 达到**
- [ ] 正控通过（同一探针在同一身份下能读到自己的任务包字节）
- [ ] `reference_p56.m` / `tasks_p56.json` 的可推导路径被实际切断（V12 单独确认）
- [ ] 每臂 MATLAB 进程独立，跨臂 canary 读不回来（V13 单独确认）
- [ ] 样本量、评分协议（v3 七维）、统计方法在开跑**之前**预注册
- [ ] 用户明确批准创建账户 / 启用虚拟化 / 收紧 ACL

当前状态：**第 1 项就不成立**（本轮未实施任何账户或虚拟化改动），
因此后面 6 项都无从谈起。已有的一切三臂结果只能继续标 `EXPLORATORY（隔离未强制）`，
不得写成 Skill 的因果增益。

## 5. 批准清单（等待用户决定，本轮不推进）

- [ ] 同意创建本地非管理员账户 `masarm`（A 方案）
- [ ] 确认 MATLAB 许可允许第二身份 / 允许在沙箱内安装
- [ ] 同意对评估目录、`benchmark/reference_p56.m`、父 transcript 目录做 ACL 收紧（含备份与回滚）
- [ ] 同意启用 Windows Sandbox 或 Hyper-V（可能重启）
- [ ] 同意手臂运行期间禁用其网络（或仅允许许可服务器）
- [ ] 决定先做 A 还是先做 B（A 成本低但残留共享状态；B 边界真但成本高）
- [ ] 同意在隔离验收通过后，是否允许设计正式三臂实验

任一勾选项未批准 → **Task 5 保持 DESIGN-ONLY，Task 5 相关实验不启动**。

## 6. 本轮明确没有做的事

未创建账户、未改 ACL、未启用虚拟化、未改 MATLAB 全局配置或许可、未改官方 MCP Server；
未在真实用户级 Skills 目录写入（`.qoder-cn` / `.agents` / `.workbuddy` 保持只读，45 份副本哈希一致）；
没有把 fixture 级"目录隔离"写成"强隔离"；没有新增第十个 Skill；
没有把 Phase 5.6/5.7 的历史结果当作新一轮因果实验；没有调用未经授权的付费模型。
