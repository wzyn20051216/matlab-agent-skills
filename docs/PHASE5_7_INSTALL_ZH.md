# Phase 5.7 · Skills 安装一致性审计（Task 1）

日期：2026-10-23　分支：`phase5.1-audit`　基线：`9543f36`（Phase 5.6）

## 1. 这一轮回答什么

只回答一个问题：**仓库里的 9 个 Skill，和用户实际会被加载的副本，是不是同一份？**

不回答：Skill 是否提升任务成功率（那是 Task 3/4 的评分与隔离问题）。

## 2. 发现（只读审计，未改动任何安装目录）

审计工具：`skills/matlab-testing-ci/scripts/mas_skill_install_audit.m`
输入：`skills/matlab-testing-ci/assets/install-roots.json`
报告：`artifacts/phase57/install/install_audit.json`（schema `mas-skill-install-audit/1`，`readOnly=true`）

| 客户端 | 解析级别 | 当前 | 漂移 | 缺失 | 未决 |
| --- | --- | ---: | ---: | ---: | ---: |
| Qoder 主会话 | observed-precedence | 2 | 7 | 0 | 0 |
| Codex CLI 0.147.0 | observed-single-root | 5 | 4 | 0 | 0 |
| Codex Desktop 0.163.0-alpha.11.1 | observed-single-root | 5 | 4 | 0 | 0 |
| WorkBuddy | known-root | 0 | 9 | 0 | 0 |

总体判定：`DRIFTED`。

关键事实：

1. **Qoder 的有效根是"按 Skill 混合"的，不是单一目录。**
   `<home>\.qoder-cn\skills` 只有 7 个 MATLAB Skill，且全部落后于仓库；
   `matlab-orchestrator` 与 `matlab-simulink-modeling` 在该根不存在，Qoder 回退到
   `<home>\.agents\skills`，因此这两个是当前版本。客户端的override 日志只列出
   7 条，恰好对应这 7 个重复项。
2. **`.agents` 共享根被两个 Codex 客户端实际列出 9/9**（app-server `skills/list`，
   见 `artifacts/phase57/native/codex-*/verification.json`），但其中 4 个内容落后。
3. **WorkBuddy 根存在但不是有效加载证据**：`.workbuddy` 是 `<workbuddy-data>` 的符号
   链接，本仓库没有 WorkBuddy 的 skill-list 探针，状态只能是 `assumed`。
4. **项目级根 `<repo>\.qoder\skills` 不存在**，所以"项目级覆盖用户级"这条
   规则在本机 **未被触发**，不能写成已观察。

## 3. 优先级证据

`artifacts/phase57/install/qoder_precedence.json` 保存了 `qodercli.log` 的原始行、
行号与日志 SHA-256。原文形如：

```
Skill "matlab-testing-ci" from "<home>\.qoder-cn\skills\matlab-testing-ci\SKILL.md"
overrides same-source skill at "<home>\.agents\skills\matlab-testing-ci\SKILL.md" (source: user)
```

这是客户端自己的加载日志，不是从目录顺序推断。它证明"当两处都存在时从 `.qoder-cn`
加载"，**不证明**该副本等于仓库（那正是第 2 节的漂移）。

## 4. 同步行为（隔离沙箱）

新增回归：`tests/SkillSync.Phase57.Tests.ps1`，4/4 通过（Pester 3.4.0，全部在临时目录）：

| 场景 | 结果 |
| --- | --- |
| 受管目录升级 + 用户自建文件 | 升级成功，`custom.md` 保留并在 `preservedUserFiles` 中报告 |
| 升级后重复同步 | `unchanged=2`，自定义文件仍在 |
| 替换被占用文件失败 | `Decision=error`、`RestoredFromBackup=true`，旧版本完整 |
| 清单属于其他仓库 | 拒绝接管，内容不变 |

复现：

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Layer free -Filter Phase57
```

另有 `matlab/validation/phase57/p57_sync_redisovery.m`：把真实仓库同步到临时根，再让
审计工具重新发现，结果 `CONSISTENT`、9/9 `CURRENT`
（`artifacts/phase57/install/sync_redisovery.json`）。这验证"同步 → 再发现"闭环，
但仍不等于"客户端下次启动一定加载"，后者只有客户端自身的列表/日志能证明。

## 5. 真实安装目录的变更计划（未执行，需要人工批准）

`artifacts/phase57/install/real_roots_change_plan.json` 由审计报告生成，**`executed=false`**：

| 根 | 待同步 Skill | 新增文件 | 覆盖文件 |
| --- | ---: | ---: | ---: |
| `<home>\.qoder-cn\skills` | 7 | 39 | 15 |
| `<home>\.agents\skills` | 4 | 5 | 8 |
| `<home>\.workbuddy\skills` | 9 | 44 | 19 |

执行方式（批准后）：

```powershell
# 1) 先看计划，不写盘
powershell -ExecutionPolicy Bypass -File .\scripts\Sync-Skills.ps1 -SkillRoot "<home>\.qoder-cn\skills" -DryRun
# 2) 再执行；脚本会先整目录备份，失败自动补齐
powershell -ExecutionPolicy Bypass -File .\scripts\Sync-Skills.ps1 -SkillRoot "<home>\.qoder-cn\skills"
```

安全边界：不使用 `-Force`；外来同名目录会保持冲突不覆盖；用户新增文件会被保留；
备份位于 `<root>\.matlab-agent-skills\backups`。本轮**没有**运行第 2 条命令。

## 6. 结论与限制

- **已证实**：安装副本与仓库不一致，且不一致可按客户端、按 Skill 量化。
- **已证实**：同步脚本在隔离环境中满足升级、幂等、保留用户文件、失败恢复。
- **未证实**：执行同步后 Qoder/Codex 会立即重新加载；需要客户端重启后的列表/日志。
- **未做**：修改任何真实用户目录、系统 ACL、全局配置。

因此本轮对"用户真正加载最新 Skills"的回答是：**尚未达成，但已有可审计的差距清单和
可回滚的修复路径**。在人工批准并执行同步、再观察客户端列表之前，不得声称一致。
