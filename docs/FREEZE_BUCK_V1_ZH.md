# Buck v1 仿真基线冻结记录

- 冻结日期：2026-10-19
- 冻结对象：**仿真**基线（不是硬件设计，不是可发布 Demo）
- 冻结提交：`37fabff`（`docs(buck): 记录干净 checkout 复现结果`）
- 冻结标签：`buck-v1-sim-baseline`（annotated tag，指向 `37fabff`）
- 分支：`feat/phase3a-power-electronics`（PR #2，base `main`，OPEN，未合并）

---

## 1. 冻结时的 Git 拓扑

```
main                              f76681d   ← 未动
└── PR #2 (OPEN, MERGEABLE)
    └── feat/phase3a-power-electronics   37fabff   ← 冻结在此
        └── feat/phase3b1-boost          (Phase 3B.1 从这里拉出，stacked)

fix/p0-installer-safety           10d38bf
└── PR #1 (OPEN, MERGEABLE)
    └── fix/p1-execution-validation  292eb8f
```

- 两个 PR 均保持 OPEN，**未合并、未关闭**；
- 未改写任何历史，未删除任何失败记录；
- Boost 分支从冻结提交拉出，**stacked 在 PR #2 之上**，因此 Boost 的 PR 会以
  `feat/phase3a-power-electronics` 为 base，PR #2 的依赖关系被显式保留。

## 2. 冻结范围内的产物与校验和（SHA-256 前 16 位）

| 文件 | 摘要 | 内容 |
|---|---|---|
| `a6_stability.json` | `fbaa90eaff101fc5` | Floquet 稳定性，14 轨道 |
| `a6_dplus.json` | `7eb5f7b6115cc153` | D+ 联合非理想，35 次 |
| `a6_task4_phase.json` | `b547c928faa10a14` | 采样相位/延迟/补偿/抖动矩阵 |
| `a6_task5_margin.json` | `89ac0533a334ff9d` | 统一裕度与容差 |
| `a6_task6_accept.json` | `fbf12914124832f0` | 七工况最终验收，140 次 |

产物位于 `artifacts/validation/buck/`。**注意：`artifacts/` 被 `.gitignore` 排除，不入库。**
冻结依赖的是"可从冻结提交重新生成"，而不是"文件在仓库里"。复现验证见 §4。

## 3. 冻结时必须携带的六条事实（不得在引用时省略）

| # | 事实 | 证据位置 |
|---|---|---|
| 1 | **严格 12 A 峰值电流约束下仍有工况失败**：C6 峰值 12.041 A，超 0.041 A。"7/7"只在 S1–S9 原文口径（不含峰值电流）下成立，含严格 12 A 时为 **6/7** | `PHASE3A6B_TASKS4_7_ZH.md` §3.5 / §4.3 / §4.7 |
| 2 | **S6 启动超调未得到有效验证**：模型从 12 V 工作点起步，参考从 0 V 斜坡上升；启动段电感电流 −0.87~−1.83 A，二极管不可能反向导通（真实电路进 DCM，模型无 DCM）。判 **UNDETERMINED** | 同上 §3.6 |
| 3 | **150 µH 的电感负偏差裕度很小**：实测稳定下限 ≈145 µH（−3.3%）；140 µH 临界（max\|λ\|=0.9978 且 1500 周期不收敛）；135 µH 失稳。成品电感 ±10%/±20% 不满足 | 同上 §3.9 |
| 4 | **220 µH 只是仿真候选**：在该模型下 21/21 通过与更好裕度，但**没有任何硬件验证** | 同上 §4.3 / §3.9 |
| 5 | **S2/S3 在开关模型上没有同意义的独立频域实测**：51.25°/13.0 dB 是平均模型设计值，标注 INHERITED；开关级替代量为延迟裕度 1 拍、`Kpe` 裕度 ×1.156、`Kci` 裕度 ×1.016 | 同上 §3.10 |
| 6 | **E 级真实硬件验证为 SKIP**：无板、无仪器、无实测 | 同上 §5.4 |

## 4. 冻结前最后一次复现验证

```
git clone -q -b feat/phase3a-power-electronics <repo> /e/desktop/_buck_clean
cd /e/desktop/_buck_clean
matlab -batch "run('matlab/buck/verify/buck_smoke.m')"
  → 9 / 9 checks passed，退出码 0
  → max|λ|=0.965301，dip=−2.18051%，S5=0.1831 ms（与开发机一致）
```

克隆体积 4.8 MB，**不含 `artifacts/`**，因此该次运行证明自检不依赖任何本机产物。

## 5. 冻结的准确含义

**包含**：

- 这套参数（`Vin 48 V, Vref 12 V, L 150 µH, C 220 µF, fs 50 kHz, Kci 6 Ω, Kp_e 1.8, Ki_e 4000,
  ff=1, Imax 12 A, Dmin 0.05, Dmax 0.85, Tt 0.3 ms, Tclamp 1.5 V, Tss 5 ms`）；
- 这套判据（S1–S9 原文阈值）；
- 这批数值（A/B/C/D/D+ 五级 + Task 4–7）；
- 这些工具（`sw_period_map` / `sw_floquet` / `sw_dual_sim` / `s1_verdict` / `step_metrics`），
  以及"重构前后数值一致"这一跨版本证据（ΔS5=0、Δdip=4e-14、ΔssErr=1e-14）。

**不包含**：

- 可以直接照此画板子的结论（电感裕度 −3.3%、峰值越限、启动与 DCM 无定义）；
- 任何对外发布的承诺。

## 6. 解冻条件

出现下列任一情况，必须重新开一条 Task 记录，而不是在冻结基线上直接改数字：

1. 更换 L / 器件参数 / 传感器规格 → 需重跑 Task 4–6；
2. 引入 DCM 模型或器件级（Simscape）模型 → 需重跑全部等级；
3. 修正 S6 的启动初值 → 需重跑 Task 5b/6 并更新 S6 判定；
4. 修改 `sw_period_map` / `sw_dual_sim` / `step_metrics` 的语义 → 需重跑回归 + 跨版本对比。
