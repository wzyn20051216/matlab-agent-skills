# Windows 技术预览 — Release Notes 草案（v0.6.0-preview.2）

状态：**待批准**。本文件是发布材料草稿；尚未创建 GitHub Release，也尚未创建新 tag。

- 目标提交：`44052fd9db887a3cd9650b2c5fd7a05697fa3b3f`（`main`）
- 对标内容：与 tag `v0.6.0-preview.1`（`100e6d4`）**同一棵树**（`a0f6540…`）
- 建议 tag：`v0.6.0-preview.2`，打在 `44052fd`（新增合并提交后不可变入口）
- 不建议：移动或覆盖 `v0.6.0-preview.1` / `v0.1.0`；不建议现在创建正式 Release

## 1. 这个版本包含什么

四个已审查的 stacked PR 合并进 `main`（共 73 提交、312 个文件，删除 0）：

| 层 | 内容 |
|---|---|
| #3 | P0 安装器安全重构（原子替换、用户文件保留、失败恢复） |
| #1 | P1 执行引擎与工程验收体系 |
| #2 | Phase 3A Buck 工程案例（7 工况验收） |
| #4 | Phase 3B/4：9 个 Skills 工具链、可见桌面启动、MCP 代码执行器、卸载器、发布文档 |

## 2. Windows 快速开始

```powershell
git clone https://github.com/wzyn20051216/matlab-agent-skills.git
cd matlab-agent-skills
git rev-parse HEAD                      # 44052fd9db887a3cd9650b2c5fd7a05697fa3b3f
powershell -ExecutionPolicy Bypass -File .\scripts\Sync-Skills.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\Install-MatlabMcpClients.ps1 -McpServerName matlab-official
```

重启 Codex 会话后自检：`列出你能看到的 matlab-* 技能名称`（应得 9 个）。

**许可证**：本仓库开源不等于 MATLAB 免费。需要你自己的 MathWorks 有效许可证；
部分技能依赖 Signal Processing / Control System / Simulink / Coder 等工具箱，可能需单独授权。

## 3. 九个 Skills

| Skill | 用途 |
|---|---|
| `matlab-orchestrator` | 任务分流与多技能编排 |
| `matlab-runner` | MCP 执行、日志、artifact、工具箱盘点、冒烟验证 |
| `matlab-data-analysis` | 表格/时序/统计/拟合/可复现图表 |
| `matlab-signal-vision-ai` | 信号处理、DSP、图像/视觉、深度学习实验 |
| `matlab-control-optimization` | 控制、系统辨识、鲁棒控制、MPC、参数整定 |
| `matlab-simulink-modeling` | Simulink 建模、仿真、验收 |
| `matlab-codegen-deploy` | MATLAB Coder / Embedded Coder 风格生成与部署 |
| `matlab-testing-ci` | matlab.unittest、覆盖率、CI、验收标准 |
| `matlab-robotics-autonomy` | ROS、导航、感知融合、轨迹规划 |

## 4. 已验证（本机参考环境）

| 项 | 结果 |
|---|---|
| 默认安装（9 skills / 62 文件） | PASS，逐技能树哈希等于仓库（干净克隆实测） |
| 重复安装幂等 | PASS（`unchanged=9`，不新建多余备份） |
| 升级 / 锁定文件回滚 | PASS（失败返回非零、树哈希恢复、0 缺失） |
| 安全卸载 | PASS（只删未修改的受管目录，保留用户改动与无关目录） |
| 免费层测试 | **306/306**，Windows PowerShell 5.1 与 PowerShell 7 各一遍 |
| Codex CLI 发现 | PASS 9/9（`codex-cli 0.147.0`，`scope=user`，`errors=[]`） |
| Codex Desktop 引擎发现 | PASS 9/9（引擎 `0.163.0-alpha.10.2`） |
| MATLAB MCP 冷启动 + 真实数值执行 | PASS |
| MCP 二进制供应链 | 固定 `v0.15.0` + SHA-256 校验，不符即拒绝执行 |

## 5. 未验证 / 实验性（不得当作已验证能力）

| 项 | 状态 |
|---|---|
| Desktop **UI** 是否显示/可选中这 9 个技能 | NOT VERIFIED（只有引擎级证据） |
| 模型是否真实读取 `SKILL.md` 正文 | 无原生事件，仅有观测性证据 |
| 客户端自主完成工程任务 | 受限（本会话 Agent 已验证；Codex 客户端后端曾阻断） |
| R1/R2/R3「技能带来增益」 | **未测（BLOCKED）**，不作任何性能宣称 |
| `-LaunchMode ComDesktop` | 本机 UNSUPPORTED（Job 禁止 breakaway） |
| B7（holder `HOLDING` 后 bootstrap 执行） | DEFERRED |
| WSL / Linux / macOS | 未实测 |
| 旧版 MATLAB（R2025b 及更早） | 未实测 |
| 专业工具箱全组合（Coder/Robotics 等） | 仅覆盖已记录的具体用例，未做全矩阵 |
| 真实硬件（STM32 / ROS 设备等） | 未实测 |

## 6. 已知问题与故障排查

见 [TROUBLESHOOTING_ZH](TROUBLESHOOTING_ZH.md)。最常见三类：

1. 装到别的目录 → 先 `-DryRun` 看 `skillRoot`；
2. 技能根已被**其它仓库路径**安装过 → 会拒绝同步（防止跨仓库接管），用原仓库或清理后重装；
3. MATLAB 未启动 → `Start-MatlabDesktop.ps1` 自动拉起可见桌面。

## 7. 安全说明

- MCP server 固定版本 `v0.15.0`，下载与本地二进制都对照
  `config/mcp-server-manifest.json` 的 SHA-256 校验；不匹配直接拒绝，`-AllowUnverifiedServer`
  才会放行并记录为未验证。
- 自动解析不再把当前工作目录当候选（防同名文件劫持）。
- 安装走"暂存 + 原子替换 + 失败恢复"，不会留下半个技能目录。
- 共享会话清理改为归属校验（PID + 启动时间 + 可执行路径 + 会话 id），不会误杀用户 MATLAB。
- 就绪文件与日志不记录 `apiKey` / `certificate`。

## 8. 升级与回滚

- 升级：`git pull` 后重跑 `Sync-Skills.ps1`；旧版本备份在
  `<SkillRoot>\.matlab-agent-skills\backups\<时间戳>-sync-skills\`。
- 回滚：把备份目录内容覆盖回技能目录；或 `Remove-Skills.ps1` 后重装旧版本。
- 卸载：`Remove-Skills.ps1`（只删 manifest 登记且未被本地修改的目录）。

## 9. 建议的发布动作（等待批准）

```bash
# 1) 新 tag（不改动任何历史 tag）
git tag -a v0.6.0-preview.2 44052fd9db887a3cd9650b2c5fd7a05697fa3b3f \
  -m "Windows technical preview 0.6.0-preview.2"
git push origin v0.6.0-preview.2

# 2) 再创建 GitHub Release（需要单独批准）
gh release create v0.6.0-preview.2 --prerelease --title "Windows technical preview 0.6.0-preview.2" \
  --notes-file docs/RELEASE_NOTES_WINDOWS_BETA_ZH.md
```
