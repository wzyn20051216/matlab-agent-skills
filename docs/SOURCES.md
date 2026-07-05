# 资料来源与使用原则

本仓库的技能设计优先参考官方资料和本机可验证结果。

## 主要来源

- MathWorks MATLAB R2026a Release Notes: https://www.mathworks.com/help/releases/R2026a/matlab/release-notes.html
- MathWorks R2026a product updates: https://www.mathworks.com/products/new_products/latest_features.html
- MATLAB Agentic Toolkit: https://github.com/matlab/matlab-agentic-toolkit
- Simulink Agentic Toolkit: https://github.com/matlab/simulink-agentic-toolkit
- MATLAB Actions setup-matlab: https://github.com/matlab-actions/setup-matlab
- MATLAB Actions run-tests: https://github.com/matlab-actions/run-tests
- MATLAB CI documentation: https://www.mathworks.com/help/matlab/matlab_prog/continuous-integration-with-matlab-on-ci-platforms.html

## 论坛与社区资料

Zhihu、MathWorks Answers、GitHub Issues、博客和论坛只作为问题定位线索。写入技能前必须经过至少一种验证：

- 本机 `help`、`doc`、`which`、`exist`、`ver`、`license` 检查。
- 最小 MATLAB 复现脚本。
- 官方文档或官方仓库交叉确认。

## 本机基线

本机基线应通过脚本自动发现 MATLAB 路径，而不是写死某台机器的安装目录。推荐使用：

```powershell
Get-Command matlab
```

完整工具箱清单由 `matlab/validation/matlab_toolbox_inventory.m` 生成。
