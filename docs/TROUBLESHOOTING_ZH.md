# 故障排查（Windows 技术预览）

本文只写**已实测**的失败模式与处理办法；没验证过的不写"应该能行"。

## 安装类

**装到了旧版技能 / 9 个技能内容很旧**
`main` 目前仍是早期快照，默认 `git clone` 装到的是旧技能。请用固定版本入口：

```powershell
git clone --branch v0.6.0-preview.1 --depth 1 https://github.com/wzyn20051216/matlab-agent-skills.git
cd matlab-agent-skills
git rev-parse HEAD
git rev-parse 'v0.6.0-preview.1^{commit}'   # 两个必须一致
```

**装到了别的目录**
不带 `-SkillRoot` 时应为 `%USERPROFILE%\.agents\skills`。先 `-DryRun` 看解析结果：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Sync-Skills.ps1 -DryRun
```

**同步报错并以非零退出**
任一技能 `decision=error` 都会非零退出。看 JSON 的 `failed` 与 `skills[].message`；
被占用文件导致的失败会"只补缺失文件"恢复，原文件保持不动。关掉占用程序（编辑器、杀软、OneDrive
同步）后重跑即可。

**两个看似成功其实是冲突**
外来同名目录默认**不覆盖**、退出码 0；需要严格模式加 `-Strict`（冲突退出 2）。
`conflicts` 数组非空就说明有冲突，不要只看退出码。

**重复安装会不会多备份**
不会。第二次及以后 `updated=0`、不新建备份目录；manifest 的 `generatedAt` 会重写（已知）。

## 发现类

**客户端看不到技能**
1. 确认已装到 `%USERPROFILE%\.agents\skills` 且 9 个目录都在；
2. 关掉重开客户端会话（技能目录在会话启动时扫描）；
3. 离线确认（不花模型额度）：

```powershell
python -B .\scripts\Test-CodexSkillDiscovery.py --help
```

注意：引擎级"发现 9/9"不等于 UI 里一定可见；UI 可见性需要人工确认。

**客户端提示技能太多 / 描述被截断**
本机技能总量接近上下文预算时会看到
`Skill descriptions were shortened`/`Exceeded skills context budget`。这是客户端的预算问题，
不是安装失败；可禁用无关插件或技能。

## MCP / 执行类

**MCP 连不上 / 超时**
先看 `sessionDetails.json` 里的 PID 是否还活着（自动模式会复用已共享的会话）。确认可行后：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabMcpEndToEnd.ps1
```

**MATLAB 没开，任务直接失败**
先让 Agent 自动拉起可见桌面：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Start-MatlabDesktop.ps1 -TimeoutSeconds 180
```

失败时报告里会写 `status`/`reasonCode`。`UNSUPPORTED` + `COM_HOLDER_BREAKAWAY_DENIED` 表示
当前宿主 Job 不允许 breakaway（本机就是这种情况），请改用默认 `StartupCommand`（不加
`-LaunchMode ComDesktop`）。

**含中文的 MATLAB 代码执行后变成 `?` 或空**
Phase 4.5 已修：MCP stdio 客户端现在把 stdin/stdout/stderr 都钉成 UTF-8。若仍出现，
确认用的是本仓库 `scripts\Invoke-MatlabMcpCode.ps1`（旧版会按 OEM 代码页转码）。

**Simulink 任务卡住不返回**
实测过两种：`new_system` 后未 `load_system` 就 `add_block`、以及把模型另存为与已打开模型
不同名的文件，都会报"模型不存在/同名模型已打开"。处理：`new_system` 后立刻 `load_system`，
并让 `.slx` 文件名与模型名一致。另：卡住的实例会占住 MATLAB，后续 MCP 调用全部超时——
结束该实例再重开即可。

## 许可证与平台

**提示某个工具箱未授权**
本项目**不提供** MATLAB 许可。用 `mas_precheck('toolbox','<产品名>')` 查实际状态，
不要用 `license('test','<显示名>')`（显示名会误报 0）。

**在 WSL / Linux / macOS 上能用吗**
未实测。只有路径解析逻辑（`$HOME/.agents/skills`），不能声称兼容。Windows 之外请自行评估。

## 卸载与回滚

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Remove-Skills.ps1
```

只删 manifest 登记且未被本地修改的目录；改过的技能会保留并给出原因。备份在
`<SkillRoot>\.matlab-agent-skills\backups\` 下，可手工回滚。
