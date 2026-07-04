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

当前首轮基线来自本机 `MATLAB R2026a`，可执行文件路径为：

```text
E:\Program Files\MATLAB\R2026a\bin\matlab.exe
```

完整工具箱清单由 `matlab/validation/matlab_toolbox_inventory.m` 生成。
