# Phase 5.6 · MATLAB Coder 与 MCP 通道独立诊断（Task 5）

日期：2026-10-22 · 机器：Windows 11 x64 · MATLAB：26.1.0.3276743 (R2026a) Update 3，`matlabroot = E:\matlab`
产物：`artifacts/phase56/coder_channel/`（15 个 JSON）· 汇总：`coder_diagnosis.json`（schema `mas-phase56-coder-diagnosis/3`，sha256 前缀 `4d0f50e18c1294aa`）

---

## 1. 一句话结论

在入口形态固定之后，**batch 真实进程、`evaluate_matlab_code`、`run_matlab_file` 三条通道对 `codegen` 的行为完全一致**。决定成败的是**传给 `codegen` 的入口参数形态**，不是执行通道。因此 Phase 5.5 的"判别变量是 MCP 动态求值通道"这一归因**被本轮证据推翻**。本轮**没有**主张 MathWorks 内部根因。

## 2. 为什么要重做这个判断

Phase 5.5 的实验同时改了两个量：

| | 通道 | 入口形态 | 结果 |
|---|---|---|---|
| Phase 5.5 通过例 | `matlab -batch` | 磁盘上的独立函数文件 | PASS |
| Phase 5.5 失败例 | MCP 动态求值 | 只在求值帧里存在的入口（句柄） | FAIL，空消息 `emlc:compilationError` |

通道与形态同时变化，无法判别哪个是因。本轮把两者拆开：**同一入口形态在每条通道各跑一次，同一通道把每种形态各跑一次**。

另外，Phase 5.5 明确列了未测项：`run_matlab_file` 作为替代通道、脚本局部函数入口。本轮补齐。

## 3. 被探测的量

**通道（由调用栈判定，不由标签判定）**

每条记录都存了 `dbstack('-completenames')` 的前 6 帧。汇总脚本据此独立标注 `channelIdentity`：出现 `LiveEditorEvaluationHelperEmatlab_mcp_server.m` 或 `matlab_mcp/mcpEval.m` 即记为 `mcp-helper-frame-present`，否则 `no-mcp-frame`。

- `batch-process`：`E:/matlab/bin/matlab.exe -batch ...`，独立新进程；
- `mcp-dynamic-eval`：`evaluate_matlab_code` 提交的代码；
- `mcp-run_matlab_file`：`run_matlab_file` 提交的脚本文件。

**实测：`run_matlab_file` 不是另一个进程。** 它的栈与 `evaluate_matlab_code` 同构（tag D）：

```
p56_coder_channel_probe.m:39 in p56_coder_channel_probe
p56_coder_drive_d.m:17 in p56_coder_drive_d
D:/Temp/Editor_tfqyu/LiveEditorEvaluationHelperEmatlab_mcp_server.m:1
D:/Temp/matlab-mcp-server-2594176706/matlab-session-1084747922-2657702379/+matlab_mcp/mcpEval.m:48 in mcpEval
E:/matlab/toolbox/matlab/connector2/interpreter/+connector/+internal/fevalMatlab.p:0
E:/matlab/toolbox/matlab/connector2/interpreter/+connector/+internal/fevalJSON.p:0
```

所以"文件 vs 内联"是**代码如何递交**的差别，不是**谁执行**的差别。这一点在诊断增益时很关键：官方 MCP Server 的每个工具最终都落到同一个常驻求值帧。

**入口形态**

| 形态 | 写法 | `which()` 解析 |
|---|---|---|
| `file` | `codegen('p56coder_entry','-args',{0.5})`，入口是磁盘上的独立 `.m` | `.../coder_channel/src/p56coder_entry.m` |
| `inline` | `f = @(x) x*2+sin(x); codegen(f,'-args',{0.5})` | 无文件 |
| `anon-handle-args` | 同上但匿名句柄 + `'-args'` 选项串 | 无文件 |
| `anon-handle-naive` | `codegen(f,{0.5})`（文档里的句柄写法） | 无文件 |
| `file-handle` | `codegen(@p56coder_entry,{0.5})`，入口文件存在且可解析 | 有文件，但以句柄传入 |
| `scriptlocal-top-level` | 脚本本身是顶层脚本，入口是该脚本的局部函数，`codegen(@local,...)` | 解析到脚本文件自身 |
| `scriptlocal`（已作废） | 在**函数内部**用 `run(script)` 执行同样的脚本 | — |

最后一行是探针自身的缺陷：在函数里调 `run()` 会先抛 `MATLAB:err_static_workspace_violation`，根本没走到 Coder。这测的是脚手架，不是 Coder，所以 `form_F.json` / `form_L.json` 保留在表里但标记 `superseded: true`，并由 `p56_coder_scripttop.m`（真·顶层脚本）重新测量。

## 4. 结果表（18 行）

| tag | 通道 | 入口形态 | ok | errorIdentifier | 产物 | 秒 |
|---|---|---|---|---|---|---|
| A | batch-process | file | ✔ | — | 25 | 39.7 |
| B | mcp-dynamic-eval | file | ✔ | — | 25 | 14.68 |
| D | mcp-run_matlab_file | file | ✔ | — | 25 | 8.58 |
| J | plain-caller（batch） | file | ✔ | — | 25 | 13.97 |
| DIRECT | mcp-dynamic-eval | 在 payload 里直接写 file 形态 | ✔ | — | — | — |
| I | plain-caller（batch） | inline | ✘ | `emlc:compilationError`（空消息） | 0 | 6.46 |
| K | mcp-dynamic-eval | inline | ✘ | `emlc:compilationError`（空消息） | 0 | 1.71 |
| O | batch / mcp-dynamic-eval | anon-handle-args | ✘ ×2 | `emlc:compilationError`（空消息） | 0 | — |
| Q | batch / mcp-dynamic-eval | anon-handle-naive | ✘ ×2 | `emlc:compilationError`（空消息） | 0 | — |
| P | batch / mcp-dynamic-eval | file-handle | ✘ ×2 | `emlc:compilationError`（空消息） | 0 | — |
| **E** | **batch-process** | **scriptlocal-top-level** | ✘ | **`emlc:compilationError`（空消息）** | **0** | **7.75** |
| **E** | **mcp-run_matlab_file** | **scriptlocal-top-level** | ✘ | **`emlc:compilationError`（空消息）** | **0** | **5.49** |
| E | batch-process（未设标签，重复一次） | scriptlocal-top-level | ✘ | `emlc:compilationError`（空消息） | 0 | 7.35 |
| F / L | batch / mcp | scriptlocal（函数内 `run()`，作废） | ✘ | `MATLAB:err_static_workspace_violation` | 1 | 0.43 / 0.32 |

**判定矩阵**（`entryFormByChannelMatrix`，行=入口形态，列=调用栈判定的通道身份，值=ok）：

| 形态 | no-mcp-frame（真实进程） | mcp-helper-frame（MCP 常驻求值） |
|---|---|---|
| file | ✔ true | ✔ true |
| inline | ✘ false | ✘ false |
| scriptlocal-top-level | ✘ false | ✘ false |
| anon-handle-args | ✘ false | ✘ false |
| anon-handle-naive | ✘ false | ✘ false |
| file-handle | ✘ false | ✘ false |

每一行两列同值。**没有任何一种形态在一条通道过、在另一条通道挂。**

三点值得单独记：

1. `file-handle`（P）的入口文件确实存在且能被 `which()` 解析，仍然失败——所以问题不是"Coder 找不到函数"，而是**参数不是字符向量时代码生成命令的选项串无法被处理**。控制台在这之前只输出一行"无法处理选项"，然后就是空消息的 `emlc:compilationError`。
2. `anon-handle-naive`（Q，文档里句柄的写法 `codegen(f,{0.5})`）也失败，说明在本机这个更新版本上，句柄入口这条路**整体不通**，不是选项串写法能救的。
3. **E 行是本任务的关键反证**：Phase 5.5 归因给 MCP 通道的失败形态（入口只存在于被提交的代码里），在真实 batch 进程里以**同一标识符、同样空消息、同样 0 产物**复现。也就是说，即使完全绕开 MCP，那种写法一样失败。

## 5. 对 Phase 5.5 的勘误

- Phase 5.5 的说法：`artifacts/phase55/coder_session/coder_diagnosis.json` 与 `docs/PHASE5_5_AUTONOMY_AND_GAIN_ZH.md` 第 8 节判定"判别变量是 MCP 的动态求值通道"。
- 当时实际变化的量：通道 + 入口形态两个一起变；失败例是以句柄形式在被求值的帧里定义入口。
- 本轮结论：**入口形态才是判别变量，通道不是**。
- 处理：**没有修改 Phase 5.5 的任何文件或产物**（历史数据只读）。勘误只写在本文件与 `coder_diagnosis.json.correction`，并由本轮产物提供可复现证据。

## 6. 未主张的内容

明确划界，避免把相关性说成根因：

- **不主张 MathWorks 内部原因。** 无法从外部区分这是不被支持的语法、该更新版本的行为，还是 Coder 选项处理里的某个分支。本轮只主张"哪个变量翻转了结果"。
- 未改动官方 MCP Server 任何代码，未重装任何产品，未持久化用户 MATLAB 路径：每个探针内部 `addpath`/`rmpath` 成对出现，全程没有 `savepath`、没有 `restoredefaultpath`（遵守约束）。
- 未探测 Simulink Coder、GPU Coder、`coder.compileC`、mexCinterface。
- batch 与 MCP-file 各为单次运行，本轮不从它们做任何时间结论，只用其通过/失败与标识符。
- 许可证与环境事实：`license('test','Matlab_Coder') = 1`，`which('codegen')` 存在，已安装 Coder 家族产品为 Embedded Coder / GPU Coder / HDL Coder / MATLAB Coder / Simulink Coder / Simulink PLC Coder（均 26.1）。成功构建在磁盘上实际产生 **39 个文件**（探针每条只记录前 25 个，`artifacts` 字段是截断列表）；chA/chB/chD 三个输出目录各自 39 个文件、`codegen/mex/p56coder_entry/p56coder_entry_mex.mexw64` 均存在，包含 `.c/.h`、interface、`build.ninja`、`buildInfo.mat`。**三通道产物数量与 mex 落地情况逐字节一致。**

## 7. 因此改了哪一行产品代码

失败路径原本会把"空消息"原样交给 Agent：`FAIL at codegen: `（后面什么都没有），没有可操作的诊断。最小修复在
[skills/matlab-codegen-deploy/scripts/mas_codegen_verify.m](file:///E:/desktop/MATLAB/skills/matlab-codegen-deploy/scripts/mas_codegen_verify.m)：
codegen 阶段捕获到空消息时，改写为携带 `ME.identifier` 与"入口必须用函数名而不是函数句柄"的可执行建议。回归用例
[skills/matlab-codegen-deploy/tests/test_codegen.m](file:///E:/desktop/MATLAB/skills/matlab-codegen-deploy/tests/test_codegen.m) 新增 `verify: empty-message codegen error still yields a usable detail`，先构造失败输入（句柄入口）再断言 `detail` 里必须出现 `emlc` / identifier / "file name" / "function handle" 之一且长度显著超过前缀。

这是本轮唯一的 Skill 产品代码改动，属于"通用判断缺陷"，不新增工具、不新增 Skill。

## 8. 后续规则

1. **codegen 断言只在真实 MATLAB 进程里跑，并且使用文件名入口形态**；MCP 报出的 codegen PASS 在被真实进程复现前一律视为未验证。
2. **Skill 不得以函数句柄作为 `codegen` 入口**。本机上那条路径只给一个空消息的 `emlc:compilationError`，没有任何可操作的诊断。`mas_codegen_verify` 的入参是函数名字符串。
3. **做通道对比的脚手架必须先固定入口形态**。同时改变通道和形态，就会像 Phase 5.5 那样得到错误的归因。
4. **不要相信工具的通道名称，要看调用栈**。`run_matlab_file` 与 `evaluate_matlab_code` 是同一个常驻求值帧。

## 9. 证据索引

| 文件 | 作用 |
|---|---|
| `matlab/validation/phase56/p56_coder_channel_probe.m` | 固定 file 入口形态，变通道；记录版本/许可证/入口解析/工作目录/标识符/消息/调用栈/产物 |
| `matlab/validation/phase56/p56_coder_drive_d.m` | `run_matlab_file` 通道驱动（`run()` 需要脚本而非函数文件） |
| `matlab/validation/phase56/p56_coder_entry_form_probe.m` | 固定通道，变入口形态 |
| `matlab/validation/phase56/p56_coder_scripttop.m` | 真·顶层脚本 + 脚本局部入口，用 `P56_LAUNCHER` 环境变量自报启动方，同时记录调用栈供核对 |
| `matlab/validation/phase56/p56_coder_syntax_probe.m` | `codegen` 三种语法形状（O/Q/P）在两通道下的对照 |
| `matlab/validation/phase56/p56_coder_diagnosis.py` | 汇总为 `coder_diagnosis.json`，含 `entryFormByChannelMatrix`、`supersededRows`、`correction`、`notClaimed` |
| `artifacts/phase56/coder_channel/*.json` | 15 个逐次运行产物；`chA/ chB/ chD/ top_batch/ top_mcpfile/` 为各次构建的输出目录 |
