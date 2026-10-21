# Boost Simulink 模型

本目录的两个 `.slx` 是 Phase 3B.2 的交付物，由下面两条命令**程序化生成**并当场验证，
不是手工搭建后另存的副本：

```bash
matlab -batch "run('matlab/boost/verify/boost_b2_task3_simulink.m')"
```

| 文件 | 内容 |
|---|---|
| `boost_avg.slx` | 两状态 CCM 平均模型 + 双环离散控制器 + 负载阶跃 |
| `boost_sw.slx` | 50 kHz PWM、开关、二极管单向导通、DCM、ESR/DCR/导通损耗、ZOH 控制 |

## 说明

- 两个模型只用库模块和数值常量，**不引用基础工作区变量**（`Simulink.findVars` 过滤
  `base workspace` 后为 0）。因此不存在"必须先跑某个脚本准备好数据"的隐藏步骤。
- `boost_sw.slx` 的 DCM 由 `Integrator Limited` 强制：电流想变负时状态停在 0，
  这正是二极管的行为，不是事后检测出来的标志位。
- 模型在周期边界采样，该点正是 ESR 阶跃点（二极管电流从 iL 跳到 0）。因此与
  MATLAB 引擎存在约 0.064 % 的稳态偏移——**这是采样沿定义不同，不是误差**，
  详见 `docs/PHASE3B2_ZH.md` §4.2。
- 重新生成会覆盖本目录的文件；这是有意的，模型是构建产物，不是需要手工维护的资产。
