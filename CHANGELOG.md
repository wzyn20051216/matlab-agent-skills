# Changelog

All notable changes to this project will be documented here.

## Unreleased

### 电力电子领域示例：Buck 稳定性与优化专项（第三阶段 3A.1）

- Added: `matlab/buck/` Buck 电压环完整实现（48V→12V/50kHz）：符号+数值模型推导、平均/开关双模型、参数化闭环构建函数（PI + 抗饱和 back-calculation + 占空比限幅 + 可选陷波器 + 负载阶跃）。
- Added: `matlab/buck/local_margins.m` —— 自实现裕度计算（稠密网格 + 对数二分 + 全交越最坏值口径），避开 `margin()` 只返回单个交越点的行为；与 `margin()` 在单交越系统上验证一致（GM/PM/交越频率吻合到 0.001%）。
- Fixed（本轮自查发现，均重跑验证）：`margin()` 返回顺序 `[Gm,Pm,Wcg,Wcp]` 曾被读反（误报"PM=1.997°"，真实 89.45°）；`Wcg`（相位穿越频率）曾被误当幅值计算 GM（GM 列出现 -70dB 量级垃圾值，且污染了任务三的搜索过滤器）；临界 Ki 从错误的 114.7 纠正为闭式值 **1/(R·Vin·C)=15.78**（闭式与数值二分误差 2.5e-5）。
- Fixed（收尾复查发现，影响全部时域数据）：负载阶跃方向写反 —— 构建函数 `After=1/(R·ratio)` 实际是 6Ω→18Ω **减载**，把纯积分回路推过轻载失稳边界 R_crit=11.98Ω，阶跃后振荡逐段翻倍，一度被误读为"恢复慢 29.64ms"。已改为 `After=ratio/R`（6Ω→3Ω 重载）并重跑全部时域脚本；旧稿时域数字（-58.2% 跌落 / 29.64ms 恢复 / 1.005ms）全部作废。
- Added: 负相位裕度区间完整刻画（`verify/buck_task2c_negative_pm_regime.m`）：纯积分回路 PM=0 的闭式条件 `Ki=1/(R·Vin·C)`；Ki 越界后 GM<0 且闭环出现 RHP 极点；Kp 单独加大只使 PM→0⁺（最低 2.55°）而 GM 保持 Inf。
- Added: 轻载失稳边界（`verify/buck_task2d_load_stability_boundary.m`）：纯积分回路 **R_crit=1/(Ki·Vin·C)=11.98Ω（额定半载即失稳）**，闭式与数值二分误差 3e-5，任务五 C4 失败由此精确解释；陷波器回路**无有限 R_crit**（R 扫到 10MΩ 仍稳定，R→∞ 极限特征多项式与 R 无关且极点全 LHP）。同时记录一个指标失效区：R≥3×10⁵Ω 时 GM 报 -57dB 但闭环稳定——总相位在 ωn 上方**成对穿越** -180°（陷波器相位超前托回），临界点 -1 不在 Nyquist sliver 内，此时判定必须以 maxRe/环绕数为准。
- Added: 陷波器 + PI 结构化设计（`verify/buck_task3_controller_design.m`）：324 组合搜索、标准先声明（PM≥50°/GM≥6dB/闭环稳定），选定 zn=0.02/zd=0.5/Kp=0.04/Ki=5 —— f_c 提升 21.4 倍（60.7→1295.2Hz）、最坏 PM=57.28°、GM=Inf。
- Fixed: tunings 扫描三缺陷（`numel(cell)` 得 12 而非 4、序号命名丢失 label 关联、失败无隔离）—— 移入 `buck_pi_tuning_sweep.m`，遍历数=配置数、id 唯一（同名去重）、失败条目指标全 NaN 不沿用，三条不变量由回归测试逐条断言。
- Added: 防回归护栏 `verify/selfcheck_notch_equivalence.m`（Simulink 时域 vs tf 线性预测差 5.6e-9V）—— 陷波器同阶分子拆并联会丢 s² 项导致时域发散（曾发散到 472V），必须完整二阶实现。
- Added: 工程验收 `verify/buck_task5_acceptance.m`：7 工况（输入电压 ±12.5%、负载 3~12Ω、电感 +30% 容差）× 2 控制器 × 3 次重复，标准 S1-S9 先声明。**实测 BASE 2/7 PASS、OPT 4/7 PASS，每个失败都有公式级解释**：C4×BASE 是 R>R_crit 的真不稳（慢渐近，必须靠频域判据识别）；C5/C6 的跌落超限被判定为物理下限（**该判定在 3A.2 被推翻，见下节**）；C7×OPT 失稳确认了窄陷波器对 f_n 漂移（-12%）敏感的鲁棒性边界。可复现性：3 次重复偏差精确为 0。
- Docs: 新增 `docs/PHASE3A_BUCK_STABILITY_ZH.md`（问题 A/B/C 的公式+仿真双重证据、错误读数纠正记录、能力边界、验收全表）。

### 电力电子领域示例：Buck 鲁棒性与验收可信度复审（第三阶段 3A.2）

本节**推翻了 3A.1 的一条核心结论**，并修复两个验收算法。标准 S1-S9 的文本一字未改。

- **Fixed（推翻 3A.1 的结论）**：3A.1 称 C5/C6 的 -18.3% 跌落是"物理下限，任何线性电压环都达不到 12% 标准"——**错误**。该结论把"控制器不动作时的二阶振铃轨迹"当成了下界，忽略了 `diL/dt=(Vin·d−vC)/L` 给出的电流爬升能力（d 取上限 0.85 时 192 kA/s，补足 6A 仅需 **31 µs**，而二阶公式隐含 244 µs）。新增 `verify/buck_task5c_physical_bounds.m` 用 ODE 数值积分最优占空比轨迹，得真实下界：R1=3Ω 时 **-0.39%**、R1=1.5Ω 时 **-3.32%**，均远优于 12% 标准。缺口归因实测为**控制器动态受限**（阶跃后占空比峰值仅 0.314、贴上限占比 0%、Ki 提高 20 倍只改善 0.74pp）。硬件重设计非必需（固定 L/C 在最优控制下已达标，C=470µF 时更优但无必要）；固定硬件与允许重设计两类结果分别报告。
- **Fixed（F-16 调节时间口径）**：旧口径只报"首次进入 ±1% 频带"，无法排除之后再次越界。新增 `matlab/buck/step_metrics.m` 同时输出 `firstEntryMs`（对照）与 `settleMs`（门禁），附加 `nExits`/`converged`/`tailInBandMs`/`growth`/`hasNaN` 诊断；锚点取**最大偏差**而非最小值（否则起步型单调衰减会退化成"报出记录时长"）。合成回归 `verify/buck_task5b_settling_regression.m` 6/6 通过，量化出旧口径高估 **12.5ms**。**修正后 S5 由"几乎全过"变为全不过**——测量变严，不是标准变松。
- **Fixed（工具缺陷）**：`local_margins.m` 的相位穿越二分**从未真正执行**——相位目标用主值相位减 lvl（≤-180），差值恒正，区间无法满足符号条件，代码一直落入注释里写着"理论上不会到这里"的几何中点兜底（偏差 1.3e-5 rad/s）。重写为：全局 unwrap 相位 + 分支一致二分 + 内部扩展频带（带外穿越也计入最坏值，从根上杜绝虚假 Inf GM）+ 精确零命中按穿越处理 + 离散系统奈奎斯特频率封顶。另修 `eval_H` 的多项式捷径对离散系统错误（离散应在 z=e^{jωTs} 求值）。新增 `verify/local_margins_synthetic_tests.m` 8/8 通过（含独立的 Nyquist 绕数算法与 `pole()` 在 7 个用例上逐一对照），并与 `allmargin`/`margin()` 交叉验证。
- **Added**：`verify/buck_task3b_notch_robustness.m` —— 参数扫描、失谐**双向**边界（3A.1 只扫了负向；实测正向 +0.082 即失稳而负向 -0.30 全域稳定）、深度/宽度权衡、离散化与传输延迟，以及 **Routh-Hurwitz 闭式证明**（取代 3A.1 对"任意有限 R 稳定"的有限扫描：设 x=1/(RC)，首列 b1=1、b2=da+x>0、b3=N(x)/b4，其中 N(x)=1.668e11+6.061e7·x+x² 对 x>0 恒正）。同时补出 3A.1 未报告的细节：最右极点对 R 按 ~1/R 趋近虚轴——**稳定不等于鲁棒**。
- **Added（否定性结论，如实记录）**：`verify/buck_task4_strategy_compare.m` 评估 5 个控制策略候选，只实现最有价值的双环（电压外环+电流内环），结论是**在本硬件下不优于单环 OPT**：纯积分外环 ζ=1/(2R√(C·Ki_e)) 与 Ki_e 成反比，跌落随 Ki_e 单调改善但 PM 断崖恶化，要在跌落上超越单环需 Ki_e>1e⁵ 而该区间闭环发散。交付仍用单环陷波器+PI——不为了"有新算法"而采用更差的方案。
- **Added**：工程验收矩阵扩到 7 工况 × **3 控制器**（新增 OPT30：陷波器+PI 但 Ki=30，PM=52.60° 仍达标；跌落仅从 -13.25% 改善到 -20.10%，量化了"提高增益不是解法"）。标准 S1-S9 未改，3A.1 的历史 FAIL 全部保留在报告 §4.2.1。
- Docs: `docs/PHASE3A_BUCK_STABILITY_ZH.md` 就地修订，新增 §0.1（三条重大修订表）、§4.5（物理边界纠正）、§4.6（策略评估否定性结论）、§6.1（3A.2 结论汇总）。

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

### 执行引擎与工程验收体系重构（第二阶段 P1）

- Added: `schemas/acceptance-report.schema.json` —— 统一验收协议的唯一定义源（JSON Schema draft-07 子集）。
- Added: `scripts/MatlabAgentSkills.Acceptance.psm1` —— 报告构造、UTF-8 读写、纯 PowerShell schema 校验器、语义校验、子报告合并、退出码映射。
- Added: `matlab/validation/+masacc/` —— MATLAB 侧同形状报告生成（`new` / `addCheck` / `classifyError` / `write`），与 PowerShell 侧字段完全一致。
- Added: `scripts/MatlabAgentSkills.Execution.psm1` —— 8 类错误分类、有限重试、进程超时与进程树终止、阶段日志、MATLAB 安装解析。
- Added: `scripts/MatlabAgentSkills.McpProbe.psm1` —— MCP 五阶段探测（安装 / 会话配置 / 客户端注册 / 协议握手 / 只读执行 / 文件回读）。
- Added: `tests/` 三个新套件（`Acceptance.Protocol.Tests.ps1` 21 例、`Execution.Reliability.Tests.ps1` 26 例、`McpProbe.Tests.ps1` 13 例）与 `tests/helpers/FakeMcpServer.ps1` 故障注入服务端。
- Added: `tests/RealExecution.Matlab.Tests.ps1`（matlab 层），验证真实 MATLAB 解析、真实 `-batch` 执行与真实超时终止。
- Added: 测试分层执行 —— `tests/Invoke-Tests.ps1 -Layer free|matlab|all`，并落盘 `artifacts/validation/tests/layer_report.json` 记录哪一层真的执行过。
- Fixed: MCP 可用性不再由 `pid` 或配置文件是否存在推断；`ready` / `autoModeReady` 改为五阶段独立判定，任一段失败后续段 SKIP。
- Fixed: `codegen` 的"生成源码"与"真实编译"拆成 L1 / L2 两个检查项，不再用代码生成冒充编译成功。
- Fixed: `simulink_coder_smoke.m` 增加模型重载、`update`、仿真数值比对、增益扫描，不再只判断 `.c` 文件存在。
- Fixed: 编译链路增加 5 组 golden 数值比对与 NaN / 非法尺寸 / 大数鲁棒性检查，此前 golden 结果未被使用。
- Fixed: 缺少许可证或工具箱时输出带原因的 SKIP，不再伪造成功状态；`Test-MatlabEmbeddedStack.ps1` 移除硬编码 `matlabValidation.passed = $true`。
- Fixed: 所有长任务增加可配置超时（`-TimeoutSeconds`）、阶段日志与超时进程树终止，超时返回 `124`。
- Fixed: `Invoke-MatlabBatch.ps1` 用 `run()` 执行脚本，但 MATLAB 的 `run` 只接受合法标识符：脚本名含连字符、以数字或下划线开头时直接抛 `MATLAB:m_illegal_character`。现在遇到非法标识符会在同目录建一个合法标识符的别名副本，跑完即删（必须同目录，否则 `mfilename('fullpath')` 解析出的仓库根会错）；`-Code` 生成的临时脚本名也改成合法标识符。
- Fixed: `Merge-AcceptanceReport` 在父报告 `toolboxInventory` 为空时继承子报告清单，否则主报告里这个字段只是空数组（空数组同样满足 schema，等于"有字段没内容"）。
- Fixed: `RealExecution.Matlab.Tests.ps1` 的别名用例改为从 summary 的 `stdout=` 读 MATLAB 真实输出日志，而不是匹配封装脚本的控制台输出。
- Fixed: `+masacc/new.m` 用 `computer("os")` 取 OS 触发 `MATLAB:badopt`，六个验收脚本在真机上全部在第 26 行挂掉；改为 `string(computer)`。
- Fixed: `+masacc/write.m` 直接 `jsonencode(report)` 时，只有一条检查项的结构体数组会被编码成 JSON 对象，导致 PowerShell 侧 schema 校验报 `$.checks 类型应为 array，实际为 object`；改为 `num2cell` 强制数组。
- Fixed: `simulink_coder_smoke.m` 用 `"StepTime"` 设置阶跃时刻，真机报 `Step block 没有名为 'StepTime' 的参数`；按实测 `DialogParameters` 改为 `"Time"`。
- Fixed: `matlab_skill_smoke.m` 的 Sine 仿真只跑到 1 秒、2 秒，峰值/谷值永远到不了 ±2（实测 1.6829 = 2·sin(1)、谷值 0.0000）；改为 5 秒覆盖 3π/2 并设 `MaxStep=0.01`，采样点 51 → 501。
- Fixed: PowerShell 5.1 下 `ConvertFrom-Json` 对 UTF-8 BOM-less 文件按 ANSI 解码导致 schema 解析失败；新增 `Read-AcceptanceJsonFile` 显式 UTF-8 读取。
- Fixed: PowerShell 5.1 下 `Start-Process` 在环境变量存在大小写重复键（`HTTPS_PROXY` / `https_proxy`）时抛"字典中的关键字重复"；改用 `ProcessStartInfo`。
- Fixed: PowerShell 5.1 下 `@($list)` 对 `List[object]` 抛"参数类型不匹配"；统一改用 `$list.ToArray()`。
- Changed: `Test-MatlabSkills.ps1` 改为 6 阶段编排，逐阶段产出并合并验收报告，退出码区分 PASS/FAIL/SKIP。
- Changed: CI 分为层 A（免费环境，仅 free 层）与层 B（带许可证的 MATLAB 环境），层 C（Pro 许可证 / 硬件）明确标注为不在默认 workflow 执行。
- Docs: 重写 `docs/VALIDATION.md`；新增 `docs/P1_ACCEPTANCE_ZH.md`（缺陷清单、设计、证据、未验证项）。
- Tested: `-Layer free` 122 例全通过、退出码 `0`；`-Layer matlab` 5 例全通过、退出码 `0`（含真实 `-batch` 执行 18.8 s、真实超时终止 45.7 s、非法脚本名别名 19.7 s）。
- Tested: `Test-MatlabSkills.ps1` 在本机 MATLAB R2026a 上真实跑完六个阶段：19 项检查中 12 项 PASS、7 项 SKIP（均为 MATLAB Coder / Simulink Coder 未授权，或目标 API 未检测到）、0 项 FAIL；整体按"存在 SKIP 即 SKIP"判为 `SKIP`（退出码 3），因 L1 存在 SKIP，按连续达成规则 `achievedLevel=L0`。
- Note: 排查中发现 Windows PowerShell 5.1 下读取 `ProcessStartInfo.EnvironmentVariables` 会得到空集合，子进程因此拿不到 `SystemRoot`/`TEMP`/`PATH`，MATLAB 直接 abort（0x00000003）。执行模块已加注释禁止该用法；据此否决了曾考虑过的 `-ClearProxyEnvironment` 方案（代理不是根因，带代理同样 16 秒启动成功）。

### 最终验收修复（第二阶段 2.2）

#### 许可证检测纠正（上一轮 7 个 SKIP 的根因）

- Fixed: `license('test', <产品名>)` 是错误用法 —— 第二个参数要的是 **license feature 名**。
  实测 R2026a：`MATLAB Coder` → `0`，而 `MATLAB_Coder` → `1`；`Simulink Coder` → `0`，而 `Real-Time_Workshop` → `1`；
  `Embedded Coder` → `0`，而 `RTW_Embedded_Coder` → `1`。此前据此判定"Coder 未授权"，导致整条 Coder 验收 SKIP。
- Added: `+masacc/featureName.m` —— 产品名 → feature 名映射表（101 条，逐条在本机实测确认）。
- Added: `+masacc/licenseState.m` —— 三态授权判定（`true` / `false` / `[]` 无法判定），记录 `featureSource`
  与 `note`，不再把"测不了"写成"没授权"。
- Added: `+masacc/executionProbe.m` —— 真实执行探针（`coder.typeof` + `coder.config`、`new_system`），
  区分"有许可证"与"能执行"。
- Fixed: `license('test')` 的 feature 字符串 **上限 27 字符**，超长抛 `MATLAB:license:toomanychars`。
  旧代码用 `catch` 吞成 `[]` 且不留原因；现在明确记为"无法判定"并说明是该 API 限制。
- Fixed: 归一化猜测（空格→下划线）只用于**确认**授权，返回 `0` 时记"未知"。
  实测反例：`Simulink_Coder` 为 `0`，而真实 feature `Real-Time_Workshop` 为 `1`。
- Fixed: `+masacc/availability.m` 重写为 `installed` / `licenseFeature` / `licenseExists` /
  `executionProven` / `available` / `provenBy` / `reason`；`available` 不再等同于"已安装"。
- Fixed: `+masacc/inventory.m` 与 `matlab_toolbox_inventory.m` 去掉重复的 `license('test', 产品名)`，
  改为三态并附 `licenseFeature` / `licenseSource`。
- Added: `inventory.gated-license` 检查 —— 核心产品（MATLAB / Simulink / 三个 Coder）的授权结论必须是
  确定的布尔值，不允许停留在"无法判定"。
- Fixed: `matlab_feature_probe.m` 此前用"已安装"给 Coder / 块集放行，改为按 `available` 判定，
  并把"未安装"与"已安装但不可用"区分成两种 SKIP 原因。
- Tested: 117 个产品清点结果 **95 授权 / 5 未授权 / 17 无法判定**（修复前是 4 / 113，其中 17 个无原因）。

#### 依赖检查顺序

- Fixed: `matlab_codegen_smoke.m` 在依赖检测**之前**就调用 `coder.typeof` 构造参数，
  缺少 MATLAB Coder 时会抛出未捕获异常，根本走不到 SKIP 分支。参数构造已移入受保护的 try 块。
- Added: `tests/DependencyOrder.Tests.ps1` —— 静态扫描全部验证脚本，断言首次 `coder.typeof` /
  `coder.config` / `codegen` / `slbuild` 调用必须晚于首次 `masacc.availability`，且 `coder.typeof`
  必须位于 try 块内（8 个用例）。

#### CI 门禁按能力范围判定

- Added: `Test-MatlabSkills.ps1 -Scope core|simulink|coder|full`，范围只决定门禁与退出码，
  **不修改** `overallStatus`，也不删除任何检查项；范围外的 SKIP 原样保留在报告里。
- Added: `Get-AcceptanceScopeDefinition` / `Get-AcceptanceScopeStatus` / `Get-AcceptanceScopeEvaluations` /
  `Get-AcceptanceScopeExitCode`。必选 FAIL → `FAIL`；必选 SKIP 或未产出 → `SKIP`；全部必选 PASS → `PASS`。
- Added: 报告新增 `scope`（所选范围）与 `scopes`（四个范围全量求值），schema 同步增补定义。
- Changed: `matlab-validation.yml` 重写为 `core` 门禁 job + `coder` 可选 job（仅 `workflow_dispatch`
  且显式申请 Coder 产品时创建，push / PR 上不存在）。CI 只依据声明的必选能力判定成败，
  可选能力的 SKIP 全部保留在报告与 artifact 中。

#### 测试与 CI 的真实性

- Fixed: **CI 三轮全红的根因是 Pester 版本选择。** runner 上同时预装 Pester 3.4.0 与 5.9.0，
  旧实现 `Sort-Object Version -Descending | Select -First 1` 选中 5.9.0，而套件使用 Pester 3 的
  `Should Be` 语法，直接抛 `Legacy Should syntax is not supported in Pester 5`，124 个用例全失败。
  本机只有 3.4.0，所以本地一直全绿——这个 bug 只在 CI 暴露。
- Fixed: `tests/Invoke-Tests.ps1` 改为按 `主.次.构建` 精确匹配 `-PesterVersion`（默认 `3.4.0`），
  绝不降级/升级到别的的主版本；本地缺失时下载到 `artifacts/.pester`，仍缺失则抛错说明原因。
  选择逻辑抽为纯函数 `tests/helpers/PesterSelection.ps1`。
- Added: `tests/PesterSelection.Tests.ps1`（11 例）锁死"必须选 3.4.0、只有 5.x 时必须返回 null"。
- Fixed: **Pester 3.4 的 `Should Throw` 在 PowerShell 7 上不生效**，全部"应当抛错"的用例会失败，
  报 `Expected: the expression to throw an exception`。新增 `tests/helpers/Assertions.ps1` 的
  `Test-Throws`（try/catch 实现），把 11 处断言改为版本无关写法。
- Fixed: **`Get-JsonValueKind` 不认 `[datetime]`**。PowerShell 7 的 `ConvertFrom-Json` 会把 ISO 8601
  字符串自动解析成 `[datetime]`，于是一份完全合法的报告被判成
  `$.startedAt 类型应为 string，实际为 unknown`。现在把 `[datetime]` / `[datetimeoffset]` 按 string 处理，
  `date-time` 格式校验也改用 ISO 文本比对。
- Changed: 层 A 的 `free-tests` 用两个显式 shell 步骤（`powershell` 与 `pwsh`）跑同一套用例；
  `layer_report.json` 新增 `powerShellVersion` / `powerShellEdition`，让"用哪个运行面跑的"可审计。
- Fixed: **ACL 授权校验把成功的授权误判成失败并回滚。** `Get-Acl` 生成的 SDDL 会把知名 SID
  渲染成别名（`S-1-5-21-…-500` → `LA`，`S-1-5-18` → `SY`），旧实现用"SDDL 里搜 SID 字面量"判断，
  于是任何以本地内置管理员（RID 500）身份运行安装器的场景都会失败。新增
  `Test-AclContainsSid`（`GetAccessRules(..., SecurityIdentifier)` 按 SID 语义比较）并替换校验；
  回归用例用 `LocalSystem` 授权，先证明字面量搜索必然落空，再断言语义比较为真。
- Fixed: `-Layer matlab` 增加可执行性预检（`matlab -batch "disp(version)"`）。
  "装了 MATLAB" 与 "MATLAB 能跑" 分开判定：预检失败时本层记为**未执行**（退出码 2，reason 含退出码与
  stderr 尾部），而不是让 5 个与被测代码无关的用例全红。`layer_report.json` 新增
  `matlabAvailable` / `matlabRunnable` / `matlabRunFailure`。
- Fixed: `McpProbe.Tests.ps1` 的"全套正常"用例不再硬断言整体 `PASS`。没有 MATLAB 的运行面上
  `mcp.matlab-install` 必然 FAIL（这是正确行为），用例改为按该项真实结果推导整体状态，
  并要求 FAIL 只能由该项引起。
- Changed: `matlab-validation.yml` 的层 B job 需要仓库变量 `MATLAB_VALIDATION_ENABLED=true`
  与 Secret `MLM_LICENSE_FILE` 才运行；未配置时显示 skipped 而不是 passed
  （公共 runner 没有许可证，`-batch` 1~2 秒即失败，跑出来的红灯与被测代码无关）。
- Tested: `Repository Checks` 在 GitHub 上**真实通过**：`层 A - 免费测试（5.1 + 7 双运行面）`
  两步各 162/162。此前三轮 CI 分别因 Pester 版本选择、PowerShell 7 语义差异、ACL SID 别名而红，
  三个根因都已定位并修复，不是"重跑就好了"。
- Added: `tests/Acceptance.Boundary.Matlab.Tests.ps1` + `matlab/validation/tests/masacc_boundary_probe.m` ——
  MATLAB 侧产出 9 类边界报告（单条/多条检查、全空字段、空清单、中文原因、许可证缺失、
  授权无法判定、运行异常、空报告拒绝），PowerShell 侧用同一份 schema 逐项校验（69 个断言）。
- Added: `Acceptance.Protocol.Tests.ps1` 增补 20 个用例：验收范围语义、`exitCode` / `durationSeconds` /
  `errorClass` / `licensed` 的取值域、单条检查数组编码、原子覆盖写。
- Fixed: 覆盖写报告不是原子操作。旧实现 `Remove-Item` + `Move-Item` 之间存在真空期，
  删除失败（被安全删除钩子拦截、文件被占用）会留下"目标消失、临时文件还在"的破损状态。
  改为 `File.Replace` / `File.Move` 单步替换，并新增回归用例。

#### 真机执行抓到的两个被掩盖的缺陷

- Fixed: `codegen -d <变量名>` 的命令行解析器把变量名当**字面量**，实测在当前目录建出名为 `genDir`
  的文件夹，产物落在那里，而断言去绝对路径找，表现为"codegen 成功但找不到产物"。
  `matlab_codegen_smoke.m` 与 `matlab_compiler_chain_smoke.m` 均改为切到目标目录执行，
  产物查找改回递归（真实产物在 `<dir>/codegen/lib/<fcn>/` 下）。
  这两个脚本此前从未真正跑到这一步，缺陷一直被许可证误判掩盖。
- Docs: `skills/matlab-runner/SKILL.md`、`skills/matlab-simulink-modeling/SKILL.md` 更正
  `license('test', product)` 的错误示例，补充产品名 → feature 名对照表与 27 字符限制。
- Tested: `-Layer free` **162 例全通过**、退出码 `0`，且在 Windows PowerShell 5.1 与 PowerShell 7.6
  两个运行面上各跑一遍都通过——这一条是 GitHub Actions 的真实结果，不是本地推测
  （`Repository Checks` 运行 39028581728 成功，层报告 artifact 记录了两个运行面的版本号）。
- Tested: `-Layer matlab` **74 例全通过**、退出码 `0`，在 PowerShell 5.1 与 7.6 两个运行面各跑一遍均通过
  （含 MATLAB 侧边界往返 69 个断言）。这一层需要真实许可证，公共 runner 上无法执行，见下一条。
- Tested: `Test-MatlabSkills.ps1 -Scope full` 在 R2026a 上真实跑完六个阶段：
  **20 项检查 19 PASS / 1 SKIP / 0 FAIL**；`core` / `simulink` / `coder` 三个范围均 PASS，
  `full` 因 `embedded.hardware-in-loop` 未执行而 SKIP（退出码 3）。唯一 SKIP 是
  `feature.direct-import`（目标 API 未检测到），不是许可证问题。
  与修复前对比：同机同环境从 12 PASS / 7 SKIP 变为 19 PASS / 1 SKIP。

- Added MCP-first MATLAB workflow documentation.
- Added one-command MCP client installer for Codex, Claude Code, VS Code, and generic MCP clients.
- Added bootstrap installer for downloading skills, syncing local skills, and configuring MATLAB MCP.
- Added Chinese project introduction and short-video script drafts.
- Added STM32 / Raspberry Pi embedded toolchain acceptance checks.
