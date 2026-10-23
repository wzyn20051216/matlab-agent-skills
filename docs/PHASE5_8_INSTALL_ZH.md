# Phase 5.8 · 安装一致性、只读变更计划与隔离验证

日期：2026-10-23
分支：`phase5.1-audit`
状态：**只读审计与隔离验证完成；真实用户级 Skills 目录未修改，等待批准。**

## 0. 结论先行

| 问题 | 结论 |
| --- | --- |
| 用户安装副本与仓库是否一致 | **不一致（DRIFTED）**：4 个已观测/已知客户端全部存在漂移，20 条更新建议 |
| 是否已修改真实安装根 | **否**：本文件所述操作只读；`-DryRun` 未写任何文件 |
| 变更是否可逐文件复核 | **是**：`artifacts/phase58/install/file_level_plan.{json,csv}` 列出每个 add/overwrite/identical/keep |
| 同步能力是否在隔离环境验证 | **是**：首次安装、升级、重复同步零写入、用户文件保留、冲突、中断回滚、备份恢复、再发现 |
| 客户端是否能发现同步后的版本 | **Codex CLI / Codex Desktop 隔离项目 9/9 PASS**；Qoder、WorkBuddy **NOT TESTED**（无隔离探针，不用其它客户端代替） |
| 是否已证明客户端重启后加载新版本 | **否**：磁盘一致 ≠ 客户端已加载；必须在批准同步后由客户端自身列表/日志确认 |

本轮同时修复了同步引擎的两个真实缺陷（见第 1 节），并新增 4 个 Phase 5.8 回归用例。

**本文档的根路径别名**：仓库卫生门禁不允许随仓库分发的文件里出现本机绝对路径，
所以下文只用别名指代本机安装根；逐字路径（含 WorkBuddy 链接的物理目标与备份会话目录）
以机器产物为准——`artifacts/phase58/install/install_audit*.json` 的 `roots[].path`
与 `artifacts/phase58/install/file_level_plan.json` 的 `roots[].physicalPath`。

| 别名 | 指代 |
| --- | --- |
| `REPO` | 本仓库的工作副本根目录 |
| `QODER-CN` | 用户配置目录下的 `.qoder-cn\skills`（Qoder 观测到的优先根） |
| `AGENTS` | 用户配置目录下的 `.agents\skills`（两个 Codex 客户端实际解析的根） |
| `WB-LINK` | 用户配置目录下的 `.workbuddy`（目录符号链接，客户端可见路径） |
| `WB-PHYS` | `WB-LINK` 指向的、位于仓库所在盘的数据目录；其 `skills` 才是同步物理根 |

## 1. 本轮修复的同步引擎缺陷

### 1.1 manifest 没有随目录一起备份（回滚不完整）

`Sync-Skills.ps1` 在替换技能目录前会整目录备份，但 manifest 是随后整体重写的，旧实现没有把
manifest 记入备份会话。结果是：目录可以从备份还原，manifest 却停留在新版本，回滚后它记录的
所有权与哈希与磁盘不一致，后续审计会把“旧内容”误报为“已安装新版本”。

现在在重写前登记 `file`（或首次安装时的 `file-absent`）记录，回滚会同时还原 manifest。
`tests/SkillSync.Phase58.Tests.ps1` 用“整文件字节相等”验证了这一点。

### 1.2 上述修复引入的幂等回归（已修复）

无条件备份 manifest 会让“全部 unchanged 的重复同步”也创建备份会话，违反“重复执行零写入”，
并使 `Installer.Scenarios.Tests.ps1` 的备份目录计数失败（22/23）。

修复方式：只有发生 `install` / `update`、首次接管未管理目录、或 `-Prune` 真的清理时，才备份并
重写 manifest；全部 unchanged 时既不刷新 `installedAt`，也不创建备份目录。Phase 5.8 新增
“repeat sync is zero-write”用例，断言 manifest 字节与备份会话数都不变。

### 1.3 回归结果

| 套件 | 结果 |
| --- | --- |
| `SkillSync.Phase58.Tests.ps1` | **4/4**（链接根拒绝、`-Force` 接管与回滚、manifest 回滚、重复同步零写入） |
| `SkillSync.Phase57.Tests.ps1` | **4/4** |
| `Installer.Scenarios.Tests.ps1` | **23/23** |

证据：`artifacts/phase58/install/pester_*.json`。

## 2. 只读安装审计（2026-10-23 13:07:58）

工具：`skills/matlab-testing-ci/scripts/mas_skill_install_audit.m`
输出：`artifacts/phase58/install/install_audit.json`

| 客户端 / 解析级别 | 有效根 | CURRENT | DRIFTED | MISSING | 加载证据 |
| --- | --- | ---: | ---: | ---: | --- |
| Qoder · observed-precedence | `.qoder-cn\skills` 优先，缺失项回退 `.agents\skills` | 2 | 7 | 0 | Qoder override 日志（原始行 + 日志 SHA-256） |
| Codex CLI 0.147.0 · observed-single-root | `.agents\skills` | 5 | 4 | 0 | app-server `skills/list` 9/9 |
| Codex Desktop 0.163.0-alpha.11.1 · observed-single-root | `.agents\skills` | 5 | 4 | 0 | app-server `skills/list` 9/9 |
| WorkBuddy · known-root | `.workbuddy\skills`（链接） | 0 | 9 | 0 | **无列表探针，加载未观测** |

关键事实：

- 总体 `DRIFTED`，9 个 Skill 在至少两个根中哈希不同，生成 20 条 `SYNC` 建议；
- Qoder 的“2 CURRENT”不是本地有 2 个最新副本，而是 `matlab-orchestrator` 与
  `matlab-simulink-modeling` 在 `.qoder-cn` **缺失**、回退到 `.agents` 后命中；其本地 7 个副本全部漂移；
- 项目级根 `REPO\.qoder\skills` 不存在，“项目级覆盖用户级”在本机 **UNEXERCISED**；
- 旧 Codex 根 `C:\Users\23201\.codex\skills` 存在但不含 `matlab-*`，两个 Codex 客户端实际从
  `.agents\skills` 解析，因此**不纳入**本次同步目标；
- 每个根都有与本仓库无关的其它 Skill，同步只能触碰 9 个 `matlab-*` 目录。

## 3. 文件级变更计划（只读）

生成器：`matlab/validation/phase58/p58_install_plan.py`（不写任何安装根）
输出：`file_level_plan.json` / `file_level_plan.csv`（逐文件 SHA-256、动作、大小）

### 3.1 目标根汇总

| 根 | add | overwrite | identical | 冲突 | 更新 | 安装 | 保留根条目 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `C:\Users\23201\.qoder-cn\skills` | 58 | 21 | 27 | 7 | 0 | 2 | 9 |
| `C:\Users\23201\.agents\skills` | 8 | 11 | 87 | 0 | 4 | 0 | 334 |
| `WB-PHYS\skills`（物理根） | 47 | 27 | 32 | 0 | 9 | 0 | 15 |
| **合计（3 个目标根）** | **113** | **59** | **146** | **7** | **13** | **2** | — |

非目标根（只读记录，不纳入计划）：

- `REPO\.qoder\skills`：不存在；
- `C:\Users\23201\.codex\skills`：9 个安装、106 个 add，但未观测为有效根，**不同步**。

`keepUserFiles=0`：9 个 `matlab-*` 目录内没有仓库之外的用户文件。根目录下无关 Skill 全部登记为
`keepRootEntries`，同步不会删除或改写它们（`Sync-Skills` 只枚举源目录中的 `matlab-*`）。

逐 Skill 明细（add / overwrite / identical / keepUserFiles；逐文件哈希见 CSV）：

**Qoder 用户根**

| Skill | 判定 | add | overwrite | identical | keepUser |
| --- | --- | ---: | ---: | ---: | ---: |
| `matlab-codegen-deploy` | conflict | 0 | 4 | 1 | 0 |
| `matlab-control-optimization` | conflict | 3 | 2 | 3 | 0 |
| `matlab-data-analysis` | conflict | 12 | 1 | 2 | 0 |
| `matlab-orchestrator` | install | 10 | 0 | 0 | 0 |
| `matlab-robotics-autonomy` | conflict | 6 | 1 | 5 | 0 |
| `matlab-runner` | conflict | 0 | 5 | 6 | 0 |
| `matlab-signal-vision-ai` | conflict | 13 | 2 | 4 | 0 |
| `matlab-simulink-modeling` | install | 6 | 0 | 0 | 0 |
| `matlab-testing-ci` | conflict | 8 | 6 | 6 | 0 |

**.agents 共享根**

| Skill | 判定 | add | overwrite | identical | keepUser |
| --- | --- | ---: | ---: | ---: | ---: |
| `matlab-codegen-deploy` | update | 0 | 2 | 3 | 0 |
| `matlab-control-optimization` | unchanged | 0 | 0 | 8 | 0 |
| `matlab-data-analysis` | update | 1 | 3 | 11 | 0 |
| `matlab-orchestrator` | unchanged | 0 | 0 | 10 | 0 |
| `matlab-robotics-autonomy` | unchanged | 0 | 0 | 12 | 0 |
| `matlab-runner` | unchanged | 0 | 0 | 11 | 0 |
| `matlab-signal-vision-ai` | update | 2 | 4 | 13 | 0 |
| `matlab-simulink-modeling` | unchanged | 0 | 0 | 6 | 0 |
| `matlab-testing-ci` | update | 5 | 2 | 13 | 0 |

**WorkBuddy 物理根**

| Skill | 判定 | add | overwrite | identical | keepUser |
| --- | --- | ---: | ---: | ---: | ---: |
| `matlab-codegen-deploy` | update | 0 | 4 | 1 | 0 |
| `matlab-control-optimization` | update | 3 | 2 | 3 | 0 |
| `matlab-data-analysis` | update | 12 | 1 | 2 | 0 |
| `matlab-orchestrator` | update | 2 | 5 | 3 | 0 |
| `matlab-robotics-autonomy` | update | 6 | 1 | 5 | 0 |
| `matlab-runner` | update | 0 | 5 | 6 | 0 |
| `matlab-signal-vision-ai` | update | 13 | 2 | 4 | 0 |
| `matlab-simulink-modeling` | update | 3 | 1 | 2 | 0 |
| `matlab-testing-ci` | update | 8 | 6 | 6 | 0 |

### 3.2 Qoder 根需要 `-Force` 的原因

`.qoder-cn\skills` 没有 `.matlab-agent-skills-manifest.json`，7 个已有副本因此被视为“外来目录”；
内容不同 → `conflict`，默认不覆盖。另外 2 个 Skill 缺失 → `install`。所以：

- 不带 `-Force`：安装 2 个、报告 7 个冲突，退出码 0（非 `-Strict`）；
- 带 `-Force`：7 个冲突目录先备份再接管，2 个安装，manifest 首次建立；
- `-Force` 只作用于源目录中存在的 9 个 `matlab-*` 名称，不触碰根下另外 9 个 Skill。

`.agents` 与 WorkBuddy 物理根都已有本仓库 manifest 且归属为 `REPO`，属于受管更新，
**不需要** `-Force`。

## 4. WorkBuddy 链接拓扑与真实备份位置

只读核实（2026-10-23）：

```
<用户配置目录>\.workbuddy          ->  WB-PHYS            （目录符号链接）
<用户配置目录>\.workbuddy\skills   ->  WB-PHYS\skills    （skills 本身是普通目录，不是二次链接）
```

因此：

- 客户端可见路径：`C:\Users\23201\.workbuddy\skills`；
- **真正要写入的物理根：`WB-PHYS\skills`**；
- `Sync-Skills.ps1` 会拒绝含链接祖先前缀的根（`Assert-MasSkillRootPath`），
  `-DryRun` 实测退出 1，提示“技能路径包含链接，拒绝自动修改: C:\Users\23201\.workbuddy”；
- 现有真实备份位于 `WB-PHYS\skills\.matlab-agent-skills\backups\20261020-102624-sync-skills`，
  其中 `manifest.json` 记录 9 个 Skill 的整目录备份；这就是回滚依据；
- **任何清理都不得递归删除 `WB-PHYS` 或用户配置目录下的 `.workbuddy`**；只允许在
  `WB-PHYS\skills` 内按 9 个 `matlab-*` 名称操作。

Qoder 根没有既有备份；首次同步会在
`C:\Users\23201\.qoder-cn\skills\.matlab-agent-skills\backups\<时间戳>-sync-skills` 下创建备份会话。
`.agents` / WorkBuddy 的后续备份会话会追加在各自的 `.matlab-agent-skills\backups`，旧会话不删除。

## 5. 隔离验证

### 5.1 同步闭环（临时根）

`matlab/validation/phase58/p58_sync_rediscovery.m` → `sync_rediscovery.json`

- 第一次：`installed=9`；
- 第二次：`installed=0, updated=0, unchanged=9`（零写入）；
- 重新审计：`CONSISTENT`，9/9 `CURRENT`，无缺失；
- 全程只使用系统临时目录，结束后删除。

### 5.2 客户端再发现（隔离项目）

`p58_codex_isolated_discovery.py` 在临时项目内同步 9 个 Skill 到 `project/.agents/skills`，
校验 `SKILL.md` 哈希与仓库一致，再冷启动 Codex app-server 请求 `skills/list`：

| 客户端 | 结果 | 证据 |
| --- | --- | --- |
| Codex CLI 0.147.0 | **PASS 9/9** | `artifacts/phase58/native/codex-cli-isolated/` |
| Codex Desktop engine 0.163.0-alpha.11.1 | **PASS 9/9** | `artifacts/phase58/native/codex-desktop-isolated/` |

限制：这证明“同步后的隔离根能被客户端发现”，不证明模型会调用，也不证明真实用户根在重启后加载。

### 5.3 Qoder / WorkBuddy

- Qoder：仓库内没有可用的 headless `skills/list` 探针；其发现证据仍来自 Phase 5.7 的 override 日志。
  隔离“同步 → 再发现”本轮 **NOT TESTED**，不用 Codex 结果替代。
- WorkBuddy：无列表探针，只能标为 `known-root`；本轮 **NOT TESTED**。

### 5.4 场景覆盖对照

| 场景 | 覆盖 | 位置 |
| --- | --- | --- |
| 首次安装 | 是 | Phase 5.8 / `Installer.Scenarios` |
| 受管升级 | 是 | Phase 5.7 / Phase 5.8 |
| 重复同步零写入 | 是 | 本轮新增用例 + 隔离根 |
| 用户文件保留 | 是 | Phase 5.7 |
| 外来目录冲突 | 是 | Phase 5.8 |
| 中断/替换失败恢复 | 是 | Phase 5.7（文件占用模拟） |
| manifest 一并回滚 | 是 | 本轮新增 |
| 同步后客户端再发现 | Codex 是；Qoder/WorkBuddy 否 | 见 5.2/5.3 |

## 6. 四个 `-DryRun` 的实际结果

| 目标 | 结果 | 日志 |
| --- | --- | --- |
| Qoder 用户根 | installed 2，conflicts 7 | `dryrun_qoder-user.log` |
| `.agents` 共享根 | updated 4，unchanged 5 | `dryrun_agents-shared.log` |
| WorkBuddy 物理根 | updated 9 | `dryrun_workbuddy-physical.log` |
| WorkBuddy 链接路径 | 拒绝（退出 1） | `dryrun_workbuddy-linked.log` |

所有 `-DryRun` 的 `backupRoot` 均为 `null`，未创建备份目录，未写入安装根。

## 7. 批准后的执行与回滚方案（本轮未执行）

### 7.1 执行顺序

一次只处理一个根，先预览再写入；每一步之后重新审计，不并行。

```powershell
# 安装根按本机取值，示例不写死路径
$QoderRoot  = Join-Path $env:USERPROFILE '.qoder-cn\skills'
$AgentsRoot = Join-Path $env:USERPROFILE '.agents\skills'
$WbPhysRoot = 'WB-PHYS\skills'   # 从 install_audit.json 的 physicalPath 取，勿用 .workbuddy 链接

# 1) Qoder 用户根（首次接管，需要 -Force）
powershell -ExecutionPolicy Bypass -File .\scripts\Sync-Skills.ps1 `
  -SkillRoot $QoderRoot -DryRun -Force
powershell -ExecutionPolicy Bypass -File .\scripts\Sync-Skills.ps1 `
  -SkillRoot $QoderRoot -Force

# 2) .agents 共享根（受管更新，不需要 -Force）
powershell -ExecutionPolicy Bypass -File .\scripts\Sync-Skills.ps1 `
  -SkillRoot $AgentsRoot -DryRun
powershell -ExecutionPolicy Bypass -File .\scripts\Sync-Skills.ps1 `
  -SkillRoot $AgentsRoot

# 3) WorkBuddy 物理根（必须用物理路径，不能用 .workbuddy 链接）
powershell -ExecutionPolicy Bypass -File .\scripts\Sync-Skills.ps1 `
  -SkillRoot $WbPhysRoot -DryRun
powershell -ExecutionPolicy Bypass -File .\scripts\Sync-Skills.ps1 `
  -SkillRoot $WbPhysRoot
```

每次写入后：

```powershell
# 重新审计（只读），并重算文件级计划确认 0 add / 0 overwrite / 0 conflict
# $matlab = MATLAB 可执行文件路径；$repo = 本仓库根（都按本机取值）
& $matlab -batch "addpath(fullfile('$repo','skills','matlab-testing-ci','scripts')); mas_skill_install_audit('repoRoot','$repo','outFile',fullfile('$repo','artifacts','phase58','install','install_audit_after.json'));"
python .\matlab\validation\phase58\p58_install_plan.py
```

然后重启/刷新客户端，并要求客户端**用自己的列表或日志**确认版本：

- Qoder：查看 `qodercli.log` 的 Skill override 记录，确认生效路径是 `.qoder-cn`，再逐个核对目录哈希与仓库一致；
  日志只能证明优先级，不能单独证明版本；
- Codex CLI / Desktop：重新运行真实根的 `skills/list` 只读探针（当前隔离脚本只覆盖临时项目），确认 9/9 且路径正确；
- WorkBuddy：没有列表探针，**不得**仅凭磁盘哈希声称已加载，保持 `NOT TESTED`。

### 7.2 回滚

每个写入会话都有 `manifest.json`。回滚前先 `-DryRun` 查看动作：

```powershell
Import-Module .\scripts\MatlabAgentSkills.Core.psm1 -Force -DisableNameChecking
$backupRoot = "C:\Users\23201\.qoder-cn\skills\.matlab-agent-skills\backups"   # 按根替换
$dir = Get-ChildItem -LiteralPath $backupRoot -Directory | Sort-Object Name -Descending | Select-Object -First 1
$raw = Get-Content -Raw -LiteralPath (Join-Path $dir.FullName 'manifest.json') | ConvertFrom-Json
$session = [pscustomobject]@{
  Id = $raw.id; Directory = $dir.FullName; Reason = $raw.reason; CreatedAt = $raw.createdAt
  Records = @($raw.records | ForEach-Object {
    [pscustomobject]@{ Kind = $_.kind; TargetPath = $_.target; BackupPath = $_.backup; Existed = $_.existed; Data = $_.data }
  })
  ManifestPath = (Join-Path $dir.FullName 'manifest.json')
}
Invoke-BackupRollback -Session $session -DryRun
Invoke-BackupRollback -Session $session
```

WorkBuddy 的 `$backupRoot` 为 `WB-PHYS\skills\.matlab-agent-skills\backups`；旧的
`20261020-102624-sync-skills` 会话也可用同样方式回滚（它早于本轮，仅作兜底）。

### 7.3 批准边界

批准后允许修改的只有：3 个目标根内的 9 个 `matlab-*` 目录、各根的
`.matlab-agent-skills-manifest.json`、各根 `.matlab-agent-skills\backups` 下的新会话。
**不修改**：其它 Skill、项目级 `.qoder\skills`、旧 Codex 根、ACL/账户、MATLAB 全局配置、
`main` 或任何历史标签。

## 8. 与 Phase 5.7 报告的差异

Phase 5.7 报告写 Qoder 计划为“新增 39、覆盖 15”，本轮实测为“新增 58、覆盖 21”。原因是 Phase 5.7
报告生成后，后续提交又改动了多个 Skill 的文件（新增 references/scripts/tests），而报告没有重算。
这是**文档陈旧**，不是工作区与冻结基线不一致：Task 0 的只读审计已确认 HEAD、冻结树与门禁哈希一致。
本文件的数字以 Phase 5.8 的只读计划为准。

## 9. 证据索引

| 证据 | 路径 |
| --- | --- |
| 安装审计 | `artifacts/phase58/install/install_audit.json` |
| 文件级计划 | `artifacts/phase58/install/file_level_plan.json` / `.csv` |
| 四个 DryRun | `artifacts/phase58/install/dryrun_*.log` |
| 同步闭环 | `artifacts/phase58/install/sync_rediscovery.json` / `sync_rediscovery_audit.json` |
| Pester | `artifacts/phase58/install/pester_phase58.json` / `pester_phase57_rerun.json` / `pester_installer_scenarios.json` |
| Codex 隔离发现 | `artifacts/phase58/native/codex-cli-isolated/`、`codex-desktop-isolated/` |
| 本文件的生成器 | `matlab/validation/phase58/p58_install_plan.py`、`p58_sync_rediscovery.m`、`p58_codex_isolated_discovery.py` |

## 10. 停止点

真实安装根、ACL、账户与客户端配置均未改动。等待对第 7 节计划的明确批准后，才执行真实根同步；
同步完成后必须由客户端自身证据确认加载版本，再进入 Task 2/3。未 push、未 merge、未 rebase。
