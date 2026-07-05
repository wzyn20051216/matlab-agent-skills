# 闭环验收

## 本机验收

在仓库根目录运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabSkills.ps1
```

脚本会执行：

1. `matlab_toolbox_inventory.m` 生成工具箱清单。
2. `matlab_skill_smoke.m` 执行数值拟合、图像导出、数据保存。
3. 如果 Simulink 可用，自动创建并仿真一个最小 `.slx` 模型。
4. `matlab_feature_probe.m` 探测直接导入模型、硬件块集和本地 agent skill 状态。
5. `matlab_codegen_smoke.m` 验证 MATLAB Coder 生成通用 C 源码。
6. `simulink_coder_smoke.m` 验证 Simulink Coder 生成通用 C 源码。

## 合格标准

- MATLAB 退出码为 `0`。
- `artifacts/validation/toolbox_inventory.json` 存在。
- `artifacts/validation/feature_probe.json` 存在。
- `artifacts/validation/smoke_*/summary.json` 存在。
- `artifacts/validation/codegen_smoke/summary.json` 存在。
- `artifacts/validation/simulink_coder_smoke/summary.json` 存在。
- 数值拟合 RMSE 小于脚本阈值。
- 图像和 `.mat` 数据文件非空。
- 如果 Simulink 可用，`.slx` 模型存在且输出信号非空。
- 如果 MATLAB Coder 可用，C 源码和头文件存在。
- 如果 Simulink Coder 可用，模型对应的 `.c` 文件存在。

## 论文复现验收

论文复现任务至少需要：

- `manifest.json` 记录论文、代码、数据、MATLAB 版本和工具箱。
- 先复现一个最小图或表。
- 给出与论文结果的数值差异或可解释偏差。
- 保存原始日志、处理脚本、结果数据、图像。
