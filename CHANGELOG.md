# Changelog

All notable changes to this project will be documented here.

## Unreleased

### 安装器安全重构（第一阶段 P0）

- Fixed: `existing` 会话模式不再输出 `--matlab-display-mode` / `--matlab-root` / `--initialize-matlab-on-startup`，此前会被官方 MCP server 直接拒绝。
- Fixed: `.mcp.json` 与 `.vscode/mcp.json` 改为安全合并，保留用户已有的其它 server 与其它顶层键；JSON 非法时中止而不是覆盖。
- Fixed: Codex / Claude 注册改为幂等 + 快照 + 失败还原，不再“先删后加”导致注册丢失。
- Fixed: 基础 MCP 配置与客户端注册解耦，未安装 Codex 时也能单独配置 Claude Code。
- Fixed: `Sync-Skills` 增加目录指纹与 manifest，冲突默认不覆盖，更新前整目录备份。
- Fixed: `startup.m` 使用托管标记块，重复执行逐字节幂等，写前备份，用户自建钩子不覆盖。
- Fixed: ACL 改为追加式授权（默认不剥离继承），改动前快照 SDDL 并可回滚。
- Fixed: 二进制下载强制 HTTPS，支持 SHA256 校验、临时文件与原子替换，已存在文件默认复用。
- Fixed: 移除 MATLAB 验证脚本中的机器专属绝对路径（外部技能目录改由环境变量注入，Keil 改为可移植探测）。
- Fixed: PowerShell 脚本统一为 UTF-8 with BOM，修复 Windows PowerShell 5.1 下无法解析的问题。
- Added: `scripts/MatlabAgentSkills.Core.psm1` 共享核心模块（参数裁剪、JSON 合并、备份回滚、目录指纹、ACL、下载校验）。
- Added: 安装器统一支持 `-DryRun`、`-BackupRoot`、`-Force`，失败自动逆序回滚。
- Added: Pester 测试套件（`tests/`），覆盖首次安装、重复安装、冲突配置、无 Codex、existing 模式与故障回滚。
- Added: CI 增加安装器测试任务、全仓库机器路径检查与 BOM 检查。
- Docs: 新增 `docs/P0_HARDENING_ZH.md`（缺陷清单、修复设计、测试证据、未验证项）。

- Added MCP-first MATLAB workflow documentation.
- Added one-command MCP client installer for Codex, Claude Code, VS Code, and generic MCP clients.
- Added bootstrap installer for downloading skills, syncing local skills, and configuring MATLAB MCP.
- Added Chinese project introduction and short-video script drafts.
- Added STM32 / Raspberry Pi embedded toolchain acceptance checks.
