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
7. `stm32_codegen_stack_probe.m` 探测 STM32 Embedded Coder 链路：CubeMX 注册路径、STM32 目标硬件、推荐 CubeMX 版本、Cube firmware package。
8. `Test-EmbeddedToolchains.ps1` 进一步探测外部工具：STM32CubeMX、GNU Tools for STM32、CMSIS、CMSIS-DSP、STM32Cube Repository、Keil、VS Code 扩展。

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
- STM32 代码生成验收不能只看桌面快捷方式或 `arm-none-eabi-gcc.exe` 是否存在；还要确认 MATLAB 已注册 CubeMX、目标硬件可见、`.ioc` 已绑定、Cube firmware package 存在。
- 如果 CubeMX 版本较新但 MATLAB 推荐旧版本，应记录推荐版本和实际版本；若 `java -jar STM32CubeMX.exe -q script` 卡住，优先按推荐版本修复，再考虑本地 wrapper。

## 论文复现验收

论文复现任务至少需要：

- `manifest.json` 记录论文、代码、数据、MATLAB 版本和工具箱。
- 先复现一个最小图或表。
- 给出与论文结果的数值差异或可解释偏差。
- 保存原始日志、处理脚本、结果数据、图像。
