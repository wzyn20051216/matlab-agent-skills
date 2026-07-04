# GitHub 开源发布清单

## 发布前确认

- 仓库名：建议 `matlab-r2026a-agent-skills`。
- 许可证：当前使用 MIT。
- 不提交 `artifacts/`、本机日志、私有数据、论文受限数据集或商业模型。
- 如需跑完整 MATLAB/Simulink 验收，优先使用 self-hosted runner 绑定本机许可证。
- GitHub hosted runner 可用于基础 MATLAB smoke test，但专业工具箱和许可证可用性要单独确认。

## 本地初始化

```powershell
git init
git add .
git status --short
```

确认没有误加入 `artifacts/` 后再提交：

```powershell
git commit -m "初始化 MATLAB R2026a agent skills"
```

## 创建远程仓库

如果已经登录 GitHub CLI：

```powershell
gh repo create matlab-r2026a-agent-skills --public --source . --remote origin --push
```

如果不用 GitHub CLI：

```powershell
git remote add origin https://github.com/<your-name>/matlab-r2026a-agent-skills.git
git branch -M main
git push -u origin main
```

## 发布后验收

- GitHub 页面能看到 `skills/`、`scripts/`、`docs/`、`.github/workflows/`。
- README 的本地部署命令能复制运行。
- GitHub Actions 至少能启动；如果许可证不足，应在 README 说明需要 self-hosted runner。
- 新开一个 Codex 会话后能在 skill 列表看到 `matlab-*` 技能。
