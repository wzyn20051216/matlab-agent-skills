# Codex CLI / Desktop 共享技能安装

本仓库将九个 MATLAB Skills 安装到当前操作系统用户的共享目录。
CLI 与 Desktop 读取同一份文件，升级只同步一次；安装脚本不依赖 `codex` 是否在 PATH。
客户端实际发现、加载、执行分别验收，目录存在不等于客户端已经加载。

| 当前执行环境 | 默认目录 | 与其他环境的关系 |
|---|---|---|
| Windows PowerShell / PowerShell 7 | `%USERPROFILE%\.agents\skills` | Windows CLI 与 Desktop 共用 |
| WSL 内 PowerShell 7 | `$HOME/.agents/skills` | 使用 Linux 用户目录，不自动写入 Windows 用户目录 |
| 原生 Linux PowerShell 7 | `$HOME/.agents/skills` | 使用当前 Linux 用户目录 |

`CODEX_HOME` 仍可用于客户端自身配置；它不改变本仓库默认共享技能目录。
旧版客户端可能支持 `.codex/skills`，本仓库不声称该目录永远无效。
需要兼容已确认的客户端发现目录时，显式传入 `-SkillRoot`；脚本不会自动复制到两个目录。
共享同一目录的不同客户端还需分别启动新会话，检查其技能列表及加载结果。

## 安装、升级与检查

在仓库根目录运行：

```powershell
# 预览默认目录及冲突；不写文件
./scripts/Sync-Skills.ps1 -DryRun

# 安装；受管技能升级前备份，外来同名目录保留并报告冲突
./scripts/Sync-Skills.ps1

# 显式目标，适合 WorkBuddy、旧版客户端或隔离验收沙箱
./scripts/Sync-Skills.ps1 -SkillRoot 'C:\path\to\skills' -DryRun

# Bootstrap 将相同目录传递给同步器，同步出错或有冲突时停止后续注册
./scripts/Bootstrap-MatlabAgentSkills.ps1 -InstallDir 'C:\path\to\repo' -SkillRoot 'C:\path\to\skills' -DryRun
```

不传 `-SkillRoot` 时，返回的 `skillEnvironment` 记录实际运行系统、用户目录、
最终目标及旧目录诊断。Windows 与 WSL 应分别在各自环境执行安装，不自动转换
`C:\...`、`/home/...` 和 `/mnt/c/...`。显式指定 WSL 的挂载目录属于操作者选择，
不属于默认共享策略。Windows 的 MCP 二进制安装链不等同于 Linux MCP 安装器。

安装后 `.matlab-agent-skills-manifest.json` 记录本仓库管理的技能及指纹。
非空清单必须归属当前仓库；仓库 B 不会接管仓库 A 的条目，`-Force` 也不绕过归属检查。
迁移仓库时，先用原仓库审查并卸载未修改受管技能，再由新仓库安装；
存在本地修改或无法确认归属时选择新 `-SkillRoot`，或备份后人工复核迁移清单。
`-Prune` 也只清理指纹仍一致的已退役技能，缺少指纹的条目会保留并告警。
技能升级保留完整目录备份，默认位于目标根下 `.matlab-agent-skills/backups`。
新会话应自行确认 SKILL.md 的发现、读取及随附 scripts/references 可访问；
模块的路径解析测试不替代真实 CLI / Desktop 启动测试。

## 卸载

```powershell
# 先审查将移除的受管技能和将保留的目录
./scripts/Remove-Skills.ps1 -DryRun

# 备份后移除；自定义安装目录必须再次显式传入
./scripts/Remove-Skills.ps1 -SkillRoot 'C:\path\to\skills'
```

卸载只处理清单归属于当前 `-RepositoryRoot`、名称合法且内容指纹未改变的直接子目录。
本地修改、其他技能、无可信指纹和链接目录均保留，并在 `preserved` 中说明原因。
删除前保存目录和清单备份；失败时回滚。本命令没有强制删除参数。
备份不会放入待删除技能内。清单和备份保留用于复核；再次安装会重新生成技能目录。
卸载后分别重启客户端会话，核对技能不再发现，不能把旧会话缓存当成卸载结果。

## 本地测试与已知限制

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ./tests/Invoke-Tests.ps1 -Layer free -Filter SkillInstallation
```

测试使用临时目录覆盖路径解析、环境隔离、显式目标、安装升级、受保护卸载、链接、
路径穿越及 Bootstrap 传参。Windows/WSL 默认目录的纯函数模拟只证明解析策略；
没有实际启动的操作系统或客户端不记为通过。
Windows/WSL 间的 MATLAB、MCP 二进制及许可证配置仍需各自验收。

2026-10-20 本轮安装侧回归：新增安装生命周期测试最初在 Windows PowerShell 5.1 和
PowerShell 7 均为 23/23；加入 SHA-256 标准向量后，完整 free 回归中的安装套件为
24/24。原安装器场景 23/23。机器可读报告位于
`artifacts/validation/phase44/skill_installation_tests.json`、
`skill_installation_ps7_tests.json` 和 `installer_scenarios_tests.json`。
Phase 4.4.1 已把这两项历史失败处理完：盘符检查被证实同时存在**判据误报**
（大小写不敏感匹配把正则里的 `name:` 加空白序列误当成盘符路径）与真实硬编码，判据已改为
`(?<![A-Za-z0-9_])[ED]:[\\/](?![A-Za-z]:)` 并加自检样本、且只扫 git 跟踪文件；
`Invoke-Phase43McpTask.ps1` 补上了 PS 5.1 解码所需的 UTF-8 BOM。
免费层因此由 263/265 变为 **270/270**（含本轮新增用例），
证据见 `artifacts/validation/phase44/free_tests_final_ps51.json` 与
`free_tests_final_ps7.json`（两个宿主均 270/270、exit 0）。
详情见 `artifacts/validation/phase44/installation_core_tests.json`。

### 同步行为与退出码（Phase 4.4.1）

```powershell
# 默认：装到 <用户主目录>\.agents\skills
powershell -ExecutionPolicy Bypass -File .\scripts\Sync-Skills.ps1

# 严格模式：只要存在冲突就以退出码 2 结束
powershell -ExecutionPolicy Bypass -File .\scripts\Sync-Skills.ps1 -Strict
```

- **失败即非零**：任一技能同步失败，脚本会 `throw`（不再以 0 退出），
  并在 JSON 的 `failed`/`skills[].decision=error` 中留下记录。
  被占用等失败会**只补齐缺失文件**恢复原目录（`RestoredFromBackup`、`RecreatedFiles`），
  仍被占用的文件保持原样，不会被删除或改写。
- **冲突 vs 失败**：外来同名目录属"冲突"，默认不覆盖、退出码 0；只有 `-Strict` 时才退出 2。
  修改历史文件属"更新"，会先整目录备份。
- **用户新增文件会被保留**：升级前快照、替换后回填，结果字段 `PreservedUserFiles`
  列出被保留的相对路径；这类文件不参与"受管内容是否一致"的判定，
  因此带用户文件的技能不会每次同步都被判成 update。
- 备份根默认 `<SkillRoot>\.matlab-agent-skills\backups`，可用 `-BackupRoot` 指定。
- 仍存在的限制：manifest 每次运行都会重写 `generatedAt`（"零写入"措辞偏强）；
  卸载只删除 manifest 登记且未被本地修改的目录。

真实共享用户目录也完成了升级、卸载与重装。CLI 0.147.0 与 Desktop 内置
0.163.0-alpha.10.2 发现引擎每阶段均独立冷启动，`skills/list` 实返数量分别为
9、0、9，六次均无发现错误。证据位于
`artifacts/validation/phase44/native_lifecycle_retry/summary.json`。
这是两端发现引擎的实测；不替代 Desktop UI 重启、WSL 或仅安装单一客户端的物理环境验收。

首次真实升级还暴露了嵌套 PowerShell 5.1 的 `Get-FileHash` 无法自动加载问题，
现已改由 .NET 计算同样的 SHA-256，并验证标准向量及升级/卸载/重装链路。
失败的首次升级和项目沙箱发现尝试均保留在本轮 artifacts 中。
