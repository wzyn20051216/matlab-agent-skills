# Changelog

All notable changes to this project will be documented here.

## Unreleased

### Phase 4.7：最终安全修复与合并门禁

- **MCP Server 供应链改为固定清单 + fail closed**：新增 `config/mcp-server-manifest.json`，
  固定上游 **v0.15.0** 的 release tag、下载 URL、SHA-256 与字节数（摘要取自 GitHub Release API
  的 `asset.digest`，并与本机已验证二进制交叉一致）。安装器不再使用 `releases/latest`；
  清单缺失/条目缺失/哈希不符/字节数不符一律拒绝；已存在的 `bin/` 二进制同样校验；
  `Verified=false` 只有在显式 `-AllowUnverifiedServer` 下才放行，且状态记为
  `UNVERIFIED_ACCEPTED_BY_OPERATOR`，绝不当成安装成功。安装摘要新增
  `serverReleaseTag` / `serverIntegrity` / `serverDownloadSrc`。
- **共享会话清理改为归属校验**：`Start-MatlabSharedSession.ps1` 不再按 `sessionDetails.json`
  的 PID 强制结束。启动时写本次运行的所有者文件（PID + StartTime + 可执行路径 + Windows
  会话 id + runId），清理前逐项复核；PID 回收、exe 路径不符、会话不符、进程已退出、
  旧运行遗留的所有者文件都只报告不终止；默认温和关闭，`-AllowForceStop` 才强制。
  就绪文件、日志与报告不含 `apiKey` / `certificate`。
- **清除构建产物里的账号名**：`matlab/boost/models/*.slx` 的 OPC 元数据
  (`metadata/coreProperties.xml`) 里嵌入了 Windows 账号名，纯文本扫描看不到（zip 压缩）。
  已把 `dc:creator` / `cp:lastModifiedBy` 改为 `matlab-agent-skills`，并验证两个模型仍能
  正常加载（59 / 62 个块）。
- **修正 CI 门禁自身**：仓库卫生检查原来的正则同时有误报（把 MATLAB 字符串里的换行转义、
  以及测试夹具里的假用户目录判成机器路径）和漏报（不匹配正斜杠写法）。现在与 Pester 测试
  共用同一判据，并允许占位符与固定夹具；两处真实路径注释已改为占位符。
- **ACL 测试可在任意宿主通过**：CI runner 的当前用户可能就是 `S-1-5-18`，与用例标的 SID
  撞车导致 3 例失败；测试改为动态选取一个"外来 SID"并先清理同名 ACE，断言不再依赖宿主默认 ACE。
- 免费层升至 **306/306**（增加供应链 12 例、进程清理 24 例），Windows PowerShell 5.1 与
  PowerShell 7 各一遍、exit 0。**未合并 main、未创建 GitHub Release**（等待人工批准）。

### Phase 4.6：发布工程化与陌生用户安装验收

- **版本入口与 main 解耦**：新增不可变标签 `v0.6.0-preview.1` 与分支 `release/windows-preview`
  （同一提交）；README/WINDOWS_BETA 的安装步骤改为固定入口 + `rev-parse` 比对，
  明确写出"main 仍是早期快照、默认 clone 装到的是旧技能"，并删除指向移动 `main` 的
  `irm … | iex` 一行命令（它执行旧代码且属于本次要消除的供应链模式）。
- **安全修复（来自独立审查，均有复现）**：MCP server 自动解析不再把当前工作目录当隐式候选
  （原实现会接受任意目录里放的同名非 PE 文件）；回归 PS 5.1/7 各 270/270。
- **干净环境安装验收**：隔离 fake home 下默认安装 9 目录/62 文件、逐技能哈希等于仓库；
  幂等、旧版升级、锁定文件回滚、卸载全部通过；真实用户目录哈希前后不变。
- **发布门禁 A–F 分离**：Installation / Discovery / Execution / Workflow / Quality 有实测证据，
  **Comparison（R1/R2/R3）显式 BLOCKED**，不因前五项通过而标 PASS。
- **Agent 复核（隔离目录、预注册参考）**：三题重跑并按冻结规则评分；
  v2 规则 23/23；v1 的 3 项失败定位为规则自身的测量定义缺陷（t=5τ 理论值 0.993262、
  t=τ 点受变步长网格影响、模型文件名写死），v1 规则未回改、结果原样保留。
- **PR 整理**：补齐缺失的 P0 基础 PR（#3），更新 #1 的 head，把 #2 的 base 改到 p1，
  新建 #4（phase3b1 → phase3a）；合并顺序 #3 → #1 → #2 → #4，审计已用 scratch 合并验证
  最终树与 `8a9da2f` 完全一致。
- 新增 `docs/TROUBLESHOOTING_ZH.md` 与 `docs/SUPPORT_MATRIX_ZH.md`；
  未创建 GitHub Release、未合并 main（等待人工批准）。

### Phase 4.5：真实自主执行验证与 Windows 测试版准备

- **修掉一个真实传输缺陷**：`MatlabAgentSkills.McpStdio.psm1` 未设置标准流编码，.NET 用进程默认
  OEM 代码页写 stdin，导致**经 MCP 提交的含中文 MATLAB 代码被转成 U+FFFD**（实测 346 个替换字符
  写进了产物）。现在 StandardInput/Output/Error 三个流都显式钉 UTF-8，并有回归证据。
- 三个自然语言任务（数据拟合+误差分析 / 数字滤波器设计+采样条件 / Simulink 动态模型+阶跃验收）
  由 Agent 自主完成并被**独立验证器**复核：20/20、22/22、21/21。过程中 Agent 自己发现并修复了
  5 个错误（含一次正反馈符号错误导致响应发散），失败尝试保留在记录里。
- 安装侧：`Sync-Skills` 的 JSON 摘要现在投影 `preservedUserFiles` / `restoredFromBackup` /
  `recreatedFiles`，脚本化消费者不必解析中文 message；`unchanged` 路径也会如实报告用户新增文件。
- 新增 Windows 测试版材料：[WINDOWS_BETA_ZH](docs/WINDOWS_BETA_ZH.md)（快速开始、九个技能用途、
  许可与依赖、诊断、已验证/未验证、卸载回滚、演示任务、发布前 checklist）；README 增加
  "Windows beta status" 段落，明确不写"全平台兼容/全面自主执行/成功率提升"。
- 发布安全：去掉 `docs/PHASE4_3_VERIFICATION_ZH.md` 中的本机用户名绝对路径（首次推送前必须清除，
  否则会永久进入公开历史）。
- **未完成（明确 BLOCKED）**：本轮 CLI / Desktop 的自主执行因 `chatgpt.com` / `api.openai.com`
  在本机不可达而无法进行；R1/R2/R3 增益对照同样无法执行，故**不作任何增益声明**。
  R1/R2/R3 的任务、参考答案与验收规则已在任何运行之前冻结（含 SHA-256 清单），
  runner 对 9 个 arm×task 一律输出 BLOCKED 并附 `github.com` 对照探针，
  评分器用合成夹具自检通过（T1 18/18、T2 17/17、T3 51/51）。

### Phase 4.4：CLI / Desktop 共享技能与独立验收

- 共享安装默认使用当前系统用户的 `.agents/skills`，补充归属校验、内容指纹、备份和保守卸载；Windows 与 WSL 的默认用户目录分开解析。
- 两端发现引擎分别冷启动，真实共享目录升级、卸载、重装的技能数量为 9 / 0 / 9；CLI 和 Desktop 的控制任务分别通过官方 MCP 执行，再由独立解析评分器核对。
- Phase 4.3 grader 修复 logical、缺失结果和损坏证据的统计；保留 53 份历史任务记录，真实 MATLAB 回归 43/43。
- 可见桌面自动启动补上最终证据：零 MATLAB 进程、且 `sessionDetails.json` 仍指向已退出 PID 的条件下，默认 `StartupCommand` 得到 `status=READY`、`beforeProcesses=[]`、`coldStartVerified=true`（9724/25692，23.3 s）；随后官方 stdio `auto` 在该实例执行控制任务，`matlabPid` 与启动报告 `runtimePid` 一致，故 `startupSessionBinding=PASS`。
- 明确区分"另开"与"冷启动"：已有实例时 `-NewSession` 得到 `newSessionVerified=true` / `coldStartVerified=false`，默认模式仍复用或拒绝重复启动；`-LaunchMode ComDesktop` 在被 Job 禁止 breakaway 的宿主中明确失败（Win32 错误 5），本机自动打开使用默认 `StartupCommand`（经 Windows Shell，不继承工具 Job）。
- 新增可见桌面启动、官方 stdio 连接重建和分层证据工具；已测范围、历史失败及未测部署环境见 [双端验收记录](docs/PHASE4_4_DUAL_CLIENT_ZH.md)。

### Phase 4.4.1：安装与执行基础设施可靠性收尾

不新增专业 Skill，只修可靠性。逐项结论与证据见 [Phase 4.4.1 记录](docs/PHASE4_4_1_RELIABILITY_ZH.md)。

- 七个启动缺陷：B1/B2/B3/B4/B5/B6 已修，B7（`HOLDING` 未证明 bootstrap）明确 DEFERRED 并写明验收条件。B2 由"1 秒后一句无法归因的创建失败"改为**启动前预检**：`status=UNSUPPORTED`、`reasonCode=COM_HOLDER_BREAKAWAY_DENIED`、`breakawayState=IN_JOB=1;LIMIT_FLAGS=0x2000`，且不创建/不关闭任何 MATLAB（实测启动前后 PID 不变）。
- 进程身份从"裸 PID"改为 `(PID, 创建时间)`：PID 回收不再把新运行时误判成 `PREEXISTING_RUNTIME`/`NOT_NEW`；holder 存活绑定自身 `holderStartedAt` + `ProcessName=powershell`。状态文件发布改为 `File.Replace`/`Move` + 有界重试，读侧允许 `ReadWrite|Delete` 共享，避免发布状态时把 holder（连同它持有的 MATLAB）弄死。
- 免费层 `263/265` → **`270/270`**（Windows PowerShell 5.1 与 PowerShell 7 各 270/270，exit 0）。两项历史失败的真实结论：盘符检查**同时**存在判据误报（大小写不敏感把正则里的 `name:` + 空白序列当成盘符）与真实硬编码；BOM 是真实约定缺陷。判据改为 `(?<![A-Za-z0-9_])[ED]:[\\/](?![A-Za-z]:)`，附灵敏度/特异度自检，并且只扫 **git 跟踪文件**（无 git 时退回文件系统遍历并报告扫描模式）。
- 安装侧：升级时**保留用户新增文件**并报告（`PreservedUserFiles`），且用户文件不再让每次同步都判成 update；单技能失败改为"补齐缺失文件"恢复（`RestoredFromBackup`/`RecreatedFiles`）并让退出码非零。修复过程中发现 `Remove-Item -Recurse -Force` 对占用文件只报非终止错误，会把缺文件的目录报成"已更新"——现已在交换路径显式 `-ErrorAction Stop`，并在交换后逐个核对源文件是否齐全。
- Desktop 证据门修复：`originator=='Codex Desktop'` 不足以区分客户端（CLI 0.147.0 exec 会话也这么写），改为同时要求 `source='vscode'` 与会话含 `<app-context>`，并把这两项写进证据；新增 2 条负向回归。
- 双端独立报告：CLI 与 Desktop 各自留证，未用一端结果替代另一端；Desktop UI 层与 CLI 本轮重跑均按 `NOT VERIFIED` 记录（原因：无 UI 驱动通道、账户额度耗尽）。

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

### 电力电子领域示例：Buck 综合非理想验证与冻结审查（第三阶段 3A.6）

- **Fixed（S1 语义，最重要）**：3A.5 的 D 级 S1 是 `isfinite(settleMs) && |ssErr|<0.1%`，
  即「60 ms 内收敛」——这不是稳定性。两个反例：时间常数 20 ms 的弱不稳定在窗口内只涨 3 倍；
  极限环波形完全重复、稳态误差为 0。3A.5 撞上后者（2 拍延迟）只是被 `isfinite` 拦住，**是运气**。
  改为**闭环周期映射的 Floquet 乘子**（`sw_period_map.m` + `sw_floquet.m` + `s1_verdict.m`）。
- **Added（开关级独立稳定性证据）**：14 个轨道（7 工况 × 阶跃前后）**全部存在周期-1 轨道且
  `max|λ| < 1`**，最坏 0.96906（C4 轻载），距单位圆 0.031。
  与平均模型离散极点吻合到 **−0.96% ~ +2.79%**（两条完全独立的路径给出同一衰减率）；
  50 mV 扰动的实测衰减率与线性化预测差 **0.57%**（验证 Jacobian 没错）。
- **Added（S2/S3 等级声明）**：开关级**没有**单一线性回路可测相位裕度，PM/GM 只有平均模型设计值
  （54.15~54.69°/13.00~13.54 dB），本轮正式标为「未独立验证」。替代给出两个真正在开关动力学上
  测出的标量裕度：**延迟裕度 1 个开关周期**（0 拍 0.9339 → 1 拍 0.9653 → 2 拍无周期-1 轨道）、
  **Kp_e 增益裕度 ×1.253（1.96 dB）**。JSON 字段 `s2s3Source` 记录该声明。
- **Added（D+ 联合等级，本轮新增）**：`sw_dual_sim.m` 逐周期精确仿真器（矩阵指数传播、开关时刻
  精确、含完整传感器链），比 Simulink 快约 20 倍，**只用于扫描**。与 Simulink 交叉验证：
  dip 最大差 0.026 pp、S5 0.0020 ms、iL 峰值 0.028 A。
  D+ = 开关行为 + 传感器非理想性，**7 工况 × 5 个噪声种子 = 35 次，7/7 通过**。
  最坏 S5 0.6745 ms、跌落 −4.930%、**ssErr 0.0977%**（限 0.1，余量 2.3%）、
  duty [0.050, 0.790]（下限零余量）、iL 峰值 12.04 A（超 Imax 0.3%）。
- **Added（统计鲁棒性）**：噪声种子固定为 [11 23 37 41 59]，S5 标准差最大 **0.117 ms**（C1），
  而确定性仿真永远是「3 次重复偏差 0」。**把 0 分散当鲁棒性证据没有意义**，本轮已落实。
  C1 的分布是**双峰**（0.25 或 0.51 ms），因为包络穿带时刻只能落在离散周期上。
- **Added（传感器代价的隔离）**：同一引擎只切传感器，**轻载/中载（C1–C3）S5 被拖慢约 3 倍**
  （0.183 → 0.514 ms），重载只拖慢 25%。S5 = 0.155 ms 只相当于 7.75 个开关周期，
  一个周期的传感器延迟就吃满预算。
- **Corrected（纹波率的真实最坏点）**：标称 62% 不是最坏。纹波率 ∝ 1/iL，
  **C4 轻载（1 A）达 125.4%**，电流在 0.375~1.63 A 摆动，距 DCM 仅 0.375 A。
- **Added（电感权衡，4 候选 × 7 工况 × 3 种子 = 84 次）**：
  | L | 纹波 | 跌落 | S5 | ssErr | iL峰值 | DCR/储能 |
  |---|---|---|---|---|---|---|
  | 150 µH | 125.6% | −4.93% | 0.675 ms | 0.0977% | 12.04 A | 1.00× |
  | **220 µH** | 84.4% | −5.62% | **0.575 ms** | 0.0679% | 10.61 A | 1.21×/1.47× |
  | 330 µH | 56.2% | −6.67% | 0.718 ms | 0.0465% | 9.69 A | 1.48×/2.20× |
  | 470 µH | 39.4% | −7.83% | 0.816 ms | 0.0343% | 9.44 A | 1.77×/3.13× |
  **四条曲线方向不一致**：纹波/S4/iL 峰值单调变好，跌落单调变差（电流斜率 192→61 kA/s），
  S5 非单调（220 µH 最优）。**没有候选全面更好**。建议 220 µH（唯一同时改善 S4/S5/iL 峰值）。
- **Added（回归）**：`verify/buck_a6_regression.m` 7 项断言全过，其中 **R4 专门守 3A.5 的 bug**
  （`s1_verdict(converged=false, max|λ|=0.5)` 必须不是 PASS）。
- **Fixed（仿真器自身的两个缺陷）**：占空比被子步网格量化（1/200）导致控制器抖动、纹波虚高 14%、
  输出纹波虚高 2.2 倍；周期平均电流用右端点求和在锯齿波上偏差 0.37%。
  另有一个 MATLAB 陷阱：把 per-period 逻辑掩码用在细网格数组上**不报错**而是静默返回错误子集
  （实测 0.647 V vs 真实的 0.058 V）。
- Docs: 新增 `docs/PHASE3A6_JOINT_AND_FREEZE_ZH.md`（S1 语义修复、14 轨道 Floquet 表、
  S2/S3 等级声明、D+ 35 次矩阵与统计、电感权衡、**冻结建议：可冻结为 v1 仿真基线，
  不可冻结为可发布 Demo**）。未做：硬件（E 级）、器件级模型、DCM、磁设计、增益调度。

### 电力电子领域示例：Buck 数字控制与非理想工程验证（第三阶段 3A.5）

- **Fixed（模型缺陷 A1）**：`buck_dual_sim.m` 在 `ff=1` 时仍用 `xe0 = iL0/Kie`，而稳态关系是
  `iLref = Kie*xe + iLoad`，等于把负载电流**算了两遍**。实测 `t=0` 处产生 **0.9315 V** 虚假偏差
  （`iLref/iL0 = 2.000`），改为 `ff=1 -> xe0=0` 后偏差 **0.0000 V**。
- **Fixed（模型缺陷 A2）**：`build_buck_dual_loop.m` 的电流指令限幅放在负载前馈**之前**，
  限幅形同虚设。实测 `Imax=6 A` 时 `iLref` 峰值达 **8.418 A**（超 40%）；修复后 **6.000 A**。
- **Fixed（等级误标 A4，对 3A.4 的更正）**：3A.4 的 84 次验收用的是**连续平均模型**
  （审计检索离散块数量 = 0），只能算 **A 级**，不能代表数字实现。本轮补 B/C/D 三级。
- **Fixed（结论错误 A5，对 3A.3/3A.4 的更正）**：跌落「物理下界」用错了阶跃前的初始电流。
  3Ω→1.5Ω 阶跃的错误下界 −3.320% 正确值是 **−1.510%**，因此 3A.4 的
  「DUAL-B 已达下界 82%、S7 无优化空间」**作废**——实际是下界的 **1.78 倍**，仍有约 1.8 倍余量。
  新增 `buck_dip_floor.m`（可指定阶跃前后负载的下界计算）。
- **Added（真实离散闭环，B 级）**：`verify/buck_a5_task1_digital.m`。**0 拍 7/7、1 拍 7/7、2 拍 0/7**。
  每拍延迟代价 PM −9.2°/GM −4.2 dB；2 拍是**极限环**（S5=NaN、启动超调 15~18%、~4 kHz），
  不是指标退化——印证了「不能只靠频域裕度判定」。
- **Added（传感器非理想性）**：`buck_dual_sim.m` 增参数化测量链（带宽/传输延迟/增益/偏置/
  高斯噪声/ADC 量化/冻结/超范围）与监督器（解析冗余 `iLoad = iL − C·dvC/dt`、范围立即跳闸、
  3 拍去抖、无扰切换 `xe ← xe ∓ iLoad/Kie`）。
  实测门槛：**带宽 ≥5 kHz、延迟 ≤1 拍、噪声 σ≤0.1 A**；零点偏置 0~1 A **完全无影响**
  （外环积分器吸收）；噪声从 0.1 A 到 0.2 A 时 S5 从 0.14 ms 崩到 **39 ms**（陡崖）。
- **Added（故障与降级）**：`verify/buck_a5_task3_faults.m`，12 种场景 × 监督器开/关。
  监督器**唯一不可替代的作用是「读数打满」**（无监督器时传感器偏差 7.02 A、安全包络被突破）。
  降级模式（无前馈双环）实测 **跌落 −6.28%、S5 1.12 ms**：稳定、安全、S7 通过、**S5 不通过**。
  另发现监督器会把「延迟 5 拍但仍可用」的传感器误判为故障（容差 3.0 A 偏保守）。
- **Added（开关级模型，D 级）**：`build_buck_switching.m`（基础模块，真实开关状态、二极管压降、
  Ron、ESR、LC 动态、PWM 载波、ZOH 调制）。Simscape Electrical 有授权但理想 Switch 端口语义在
  `-batch` 下无法稳定确定，属排期决定（报告已注明），非授权限制。
- **Fixed（开关级建模缺陷，本轮最重要的发现）**：连续控制器输出直接与载波比较会形成**模拟调制**，
  一个周期内 `d` 从 0.411 滑到 0.351，记录均值 0.3326 而实际施加 0.2590，内环被迫维持
  **0.66 A 虚假稳态误差**。加 **ZOH（每周期锁存一次占空比）** 后 `duty=0.2554`、与含损耗理论值 0.2563 吻合。
- **Added（采样相位与半纹波补偿）**：`sampPhase` + `rippleComp`。62% 电流纹波率下，
  边界采样采到**谷值**（1.44 A vs 平均 2.00 A，偏差 0.56 A）；移到中点可消除偏差但**额外 0.125·Ts
  延迟，在 1 拍计算延迟下失稳**（S5=30 ms、启动超调 17.3%）。正确解是**边界采样 + 解析半纹波补偿
  `dIL/2=(Vin−Vout)dT/(2L)`**，实测偏差降到 0.037 A 且 1 拍延迟稳定。
- **Added（分级验收）**：A/B/C/D 四级，全部 C1–C7 × 3 次，S1–S8 原文标准。
  **A 7/7、B 7/7、C 7/7、D 7/7**，但**最紧的判据从 A 级的 S5（余量 84%）换成 D 级的 S4（余量 3%）**：
  D 级 `ssErr = +0.0683%~+0.0969%`，实测为**恒定偏置**（12.0106 V 在 65/70/75 ms 不变），
  机理是 ADC 采纹波谷值 + `vOut` 含 `ESR·iL`，在 62% 纹波率下约 0.09%，**调参无法消除**。
  D 级另两处零余量：`duty` 下界恰好 0.050（S8 下限）、`iL` 峰值 12.41 A > Imax 12 A（限幅作用在采样值上）。
- **Added（回归）**：`verify/buck_a5_task0_audit.m`（5 项缺陷复现 + 修复验证）、
  `verify/buck_a5_task5_levelC.m`（21 组）、`verify/buck_a5_task5_levelD.m`（28 组）、
  `verify/buck_a5_figure.m`（从 JSON 直接绘图，不重跑仿真）。
- Docs: 新增 `docs/PHASE3A5_NONIDEAL_ZH.md`（等级定义、五处自我更正、四级验收矩阵、
  「7/7 成立在什么条件下」的 10 条假设清单、发布条件结论）。
  未做：真实硬件（E 级 SKIP）、Simscape 器件级、传感器实测数据、增益调度、DCM。

### 电力电子领域示例：Buck 双环控制实现与验收（第三阶段 3A.4）

- **Fixed（口径，影响全部历史 S5 数字）**：`matlab/buck/step_metrics.m` 的 `settleMs` 取
  `tv(lastOut)`（最后一个**越界**样本）而非 `tv(lastOut+1)`（其后第一个在带内样本），
  系统性低估 **恰好一个采样间隔**。在 3A.2 的 21 组真实波形上验证：19 个有限案例的
  delta **全部恰为 +0.001000 ms**（采样间隔中位数 1.000 µs），**PASS/FAIL 变化 0/21**。
  回归新增 S7a–S7d 四条定点断言（`settle` 精确等于 `t(lastOut+1)`、与旧口径差恰为一个采样间隔、
  单点越界、全程在带内），回归 6→**10 项全通过**；顺带修掉回归脚本"只累加 nPass、
  从不累加 nFail"的计数缺陷（曾打出"9 通过 / 0 失败 / 共 9 项"）。
- **Added（新架构）**：级联双环 —— 电压外环 PI → 电感电流指令 → 比例电流内环 → 占空比。
  新文件 `build_buck_dual_loop.m`（Simulink，与被 BASE/OPT 共用同一功率级/限幅/抗饱和结构）、
  `dual_A.m`（精确 3 状态 A 矩阵）、`dual_loop_gain.m`（外环看到的被控对象）、
  `dual_step_eval.m`（负载阶跃的精确模态和）、`buck_dual_sim.m`（数字控制器平均模型仿真）。
  精确特征方程 `s³+(Kci/L+1/RC)s²+(Kci/(LRC)+(1+Kci·Kp_e)/(LC))s+Kci·Ki_e/(LC)`
  与 `pole()` 吻合到 **4.2e-16**；`Vref/Vin` 前馈下稳态/功率平衡误差 **0.000e+00**。
- **Added（关键工程约束，本轮最重要的发现）**：数字内环的采样约束 `z_inner = 1 − Kci·Ts/L ≥ 0`，
  即 **`Kci ≤ L/Ts = 7.5 Ω`**。连续平均模型在 `Kci ≥ 10` 时**完全失效**：
  仍预测 S5 ≈ 0.72 ms，而数字仿真**不收敛**（S5=NaN，30 ms 内不进带）。
  第一版可行域搜索因此产生 14 个伪可行点（全部 `Kci=10~12`），已作废重做。
  同时纠正 3A.2 的"`Kci ≤ 2πL·fs/3` 且余量 8~15 倍"：`fc=fs/3` 处一拍延迟就是 **120°**、
  含 ZOH 是 **180°**，`fs/3` 根本不是安全带宽。
- **Added（前馈的结构性作用）**：负载电流前馈 `iLref += iLoad` 不是"不影响环路的顺馈"——
  它把内环被控量从 `iL` 换成电容电流 `iC = iL − vC/R`，LC 谐振从外环消失，
  外环对象由 `R/(1+sRC)` 退化为 ≈`1/(Cs)`。用 ff=0 的传函算 PM 是**错的**（曾算出 >90° 的假裕度）。
- **Fixed（抗饱和）**：`1/Tt` 不能跨控制器复用。3A.2 的 `Ki=7.9` 配 `Tt=1 ms`，
  双环 `Ki_e=4000~5500`（前向增益大 700 倍），同样 `1/Tt` 拉不住积分器 → 启动超调 25~36%。
  另发现根因是"启动充电瞬态（0.3 ms）比外环带宽（0.5 ms）还快"，属结构性问题。
  处置：软启动 `Tss=5 ms` + 误差钳位 `Eclamp=1.5 V` + `Tt=0.3 ms` + `Imax=12 A`；
  Simulink 复验启动超调 **1.41%**，负载阶跃指标完全不变（跌落 −2.317%、S5 0.14 ms）。
- **Added（可行域）**：`verify/buck_a4_task34_design.m`，576 点/架构 × 全 7 工况，
  约束含 S2 离散 PM≥50°、GM≥6 dB、S5≤1 ms、|dip|≤12%、线性不饱和、`z_inner≥0`。
  **CAND-A（纯双环）1/576 可行**（S5 下界 **0.992 ms**）；
  **CAND-B（双环+负载电流前馈）11/576 可行**（S5 下界 **0.130 ms**）。
  对照 3A.3：单环 PI+陷波 9600 点 **0 可行**，S5 下界 2.670 ms。
  Pareto 显示 **CAND-A 的 S5 与 PM 单调对撞**（PM 55° → S5 1.336 ms），
  而 **CAND-B 的前沿几乎水平**（PM 50°→55°，S5 仅 0.130→0.078 ms）。
- **Added（验收）**：`verify/buck_a4_acceptance.m`，**7 工况 × 4 控制器 × 3 次 = 84 次真实 Simulink 仿真**，
  S1–S9 原文标准。结果：**BASE 0/7、OPT 0/7、DUAL-A 5/7、DUAL-B 7/7**。
  DUAL-B 的 S5 = 0.000~0.155 ms、跌落 −0.70%~−2.69%、离散 PM 51.25~54.69°、
  启动超调 1.41%、duty 上限 0.75（均为实测）。
- **Fixed（历史结论补正）**：**OPT 的离散 PM 只有 0/7** —— C1 连续 57.28° 但
  ZOH+1 拍延迟下仅 **39.00°**。3A.1 的定稿控制器在 50 kHz 数字实现里**其实不满足 S2**，
  这一条以前从未测过。BASE 因增益极低反而离散 PM 更高（88.58°）。
- Docs: 新增 `docs/PHASE3A4_DUAL_LOOP_ZH.md`（精确模型推导、内环/外环设计、延迟与采样约束、
  可行域与 Pareto、84 次验收矩阵、15 条自查错误清单、PR 拆分建议）。

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
