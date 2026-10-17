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
- 未执行的检查项记为 SKIP 并写明原因，不折算成通过。

## 执行与验收模块

| 模块 | 职责 |
| --- | --- |
| `schemas/acceptance-report.schema.json` | 验收报告结构的唯一定义源 |
| `scripts/MatlabAgentSkills.Acceptance.psm1` | 报告构造、UTF-8 读写、schema 校验、合并、退出码 |
| `scripts/MatlabAgentSkills.Execution.psm1` | 错误分类、有限重试、进程超时与进程树终止、阶段日志 |
| `scripts/MatlabAgentSkills.McpProbe.psm1` | MCP 五阶段探测 |
| `matlab/validation/+masacc/` | MATLAB 侧同形状报告生成 |
| `matlab/validation/+masacc/featureName.m` | 产品名 → license feature 名映射（`license('test')` 的第二个参数是 feature 名） |
| `matlab/validation/+masacc/licenseState.m` | 三态授权判定（`true` / `false` / 无法判定） |
| `matlab/validation/+masacc/executionProbe.m` | 真实执行探针，区分"有许可证"与"能执行" |

数据流：

```text
Test-MatlabSkills.ps1  -Scope core|simulink|coder|full
  └─ Invoke-MatlabBatch.ps1 / Invoke-MatlabBatchProcess（超时 + 阶段日志）
       └─ matlab -batch <stage>.m
            └─ masacc.new / availability / addCheck / write  →  artifacts/validation/acceptance/<stage>.json
  └─ Merge-AcceptanceReport  →  artifacts/validation/acceptance_report.json
  └─ Get-AcceptanceScopeEvaluations → report.scope / report.scopes  →  退出码 0/1/3（按所选范围）
```

`overallStatus` 与 `scope.status` 是两件事：前者是整份报告的真实状态（有 SKIP 就是 SKIP），
后者只回答"本次声明的那一档能力是否全部有证据"。两者都不允许把 SKIP 折算成 PASS。

`Test-MatlabEmbeddedStack.ps1` 与 `Test-MatlabMcpExistingSession.ps1` 复用同一套报告与退出码语义，因此三者可以在 CI 里用同一条规则判定。
