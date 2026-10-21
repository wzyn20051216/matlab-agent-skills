# 支持环境矩阵

只列**实测过**的组合；未实测的一律写"未实测"，不做兼容性推断。

## 已验证

| 组件 | 版本 / 环境 | 状态 | 证据 |
|---|---|---|---|
| Windows | Windows 10.0.26100（本机） | 实测 | Phase 4.4–4.6 全部验收 |
| Windows PowerShell | 5.1.26100.7462（Desktop） | 免费层 306/306、exit 0 | `phase49/free_ps51.json` |
| PowerShell | 7.6.7（Core） | 免费层 306/306、exit 0 | `phase49/free_ps7.json` |
| Pester | 3.4.0（锁定版本） | 通过 | 测试框架要求 |
| Codex CLI | 0.147.0 | 发现 9/9（引擎级） | `install/discovery/cli/verification.json` |
| Codex Desktop（内置引擎） | 0.163.0-alpha.10.2 | 发现 9/9（引擎级） | `install/discovery/desktop-engine/verification.json` |
| MATLAB | R2026a (26.1.0.3276743) Update 3 | 冷启动 + MCP 数值执行通过 | `phase44/desktop/…startup_report.json` |
| 官方 MATLAB MCP Server | v0.15.0 | tools/list + evaluate 通过 | Phase 4.3/4.4 证据 |
| Simulink | 26.1 | 建模 + 仿真 + 验收通过（小模型 1–3 个块图） | Phase 4.5 Task C、Phase 4.6 run2/C |

## 未实测（不得声称兼容）

| 组件 | 说明 |
|---|---|
| WSL | 只有路径解析逻辑（`$HOME/.agents/skills`），无实机 |
| Linux | 同上；Bootstrap 下载的是 Windows 二进制，Linux 需另行处理 |
| macOS | 代码走 Linux 分支，未实测 |
| 旧版 MATLAB（R2025b 及更早） | 未实测；部分 API 可能不同 |
| 只装 CLI 或只装 Desktop 的独立物理机 | 未实测 |
| 完整 Desktop UI 重启 | 未实测 |
| 全新 Windows 用户账户 / 非 C: 盘用户目录 | 未实测（干净环境测试用 fake home 模拟，但客户端对 `.agents` 的用户级解析绑定 OS 用户） |
| ComDesktop 启动模式 | 本机 **UNSUPPORTED**（Windows Job 禁止 breakaway，Win32 5） |
| B7：holder `HOLDING` 未证明 bootstrap 执行 | DEFERRED，需要允许 breakaway 的环境 |

## 能力层级（不要混为一谈）

| 层级 | 含义 | 当前状态 |
|---|---|---|
| 1. 安装 | 9 个技能落到 `%USERPROFILE%\.agents\skills` 且内容正确 | 已验证 |
| 2. 发现 | 客户端引擎能列出这 9 个技能 | 已验证（引擎级） |
| 3. 加载 | 模型实际读取 `SKILL.md` 正文 | 观测性证据，无原生事件 |
| 4. 执行 | 官方 MATLAB MCP 在真实 MATLAB 上跑出结果 | 已验证 |
| 5. 工作流 | Agent 自主选技能并完成工程任务 | 本会话 Agent 已验证；Codex CLI/Desktop **BLOCKED** |
| 6. 增益 | 有/无技能的可测量差异 | **未测**，不作任何宣称 |
