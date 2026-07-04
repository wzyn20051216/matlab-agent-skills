# 技能架构

本仓库采用“总入口 + 专项技能 + 公共执行脚本”的结构。

## 技能族

- `matlab-orchestrator`: 路由和闭环策略。
- `matlab-runner`: 命令行执行、日志、工具箱清单、smoke test。
- `matlab-data-analysis`: 数据分析、统计、拟合、论文图复现。
- `matlab-simulink-modeling`: Simulink 建模、仿真、信号验收。
- `matlab-codegen-deploy`: MEX、C/C++、嵌入式、GPU、HDL 代码生成。
- `matlab-control-optimization`: 控制、辨识、MPC、优化。
- `matlab-robotics-autonomy`: ROS、机器人、导航、传感融合。
- `matlab-signal-vision-ai`: 信号、视觉、图像、AI 实验。
- `matlab-testing-ci`: 单元测试、Simulink Test、GitHub Actions、验收报告。

## 设计原则

- 任务优先，不按工具箱机械拆分。
- 每个技能都必须导向可执行命令和验收结果。
- 优先本机验证，其次官方资料，再参考社区经验。
- 不把论坛经验直接写成结论。
- 默认生成可开源的目录、日志和复现实验材料。
