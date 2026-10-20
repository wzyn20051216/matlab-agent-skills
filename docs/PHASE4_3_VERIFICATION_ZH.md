# Phase 4.3 — MATLAB Agent Skills 真实调用与跨领域泛化验证

分支 `feat/phase3b1-boost`。本文件只记录**实际执行并留下证据**的结论。
没跑的一律写明缺什么证据，不用"应该"补位。

---

## 0. 基线审查（Task 0）

| 项 | 事实 |
|---|---|
| 本地工作区 | clean（`git status --porcelain` 0 行） |
| 当前分支 | `feat/phase3b1-boost` |
| Phase 4.2 提交 | 全部已提交，最新 `44b86f0` |
| `44b86f0` 推送状态 | **未推送**。远端停在 `bcc0d07`，本地领先 **7 个提交** |
| 用户提到的 `4b86f0` | **该哈希不存在**（`git cat-file -t 4b86f0` → fatal）。实际提交是 `44b86f0`（44 开头） |
| main | 未动（`f76681d`），未合并 PR |
| Buck / Boost 冻结基线 | 未触碰；历史失败记录全部保留 |

推送未自作主张：`git push` 改变远端状态，属对外动作。

---

## 1. Skills 从未真正安装过（本轮最意外的发现）

Phase 4.2 说"9 个 Skills 就位"，指的是**仓库源码**。实际安装状态：

```
~/.codex/skills/matlab-*     9 个空目录（0 字节内容）
~/.agents/skills/matlab-*    9 个旧版，只有 SKILL.md（7月5日，3942 字节）
                             缺 scripts/ tests/ references/
```

**Codex 真实的技能发现路径是 `~/.agents/skills/`**（340 个技能在那里），
不是 `~/.codex/skills/`。仓库的 `Sync-Skills.ps1` 默认目标恰恰是后者——
所以那脚本此前即便跑过，也装不到能被发现的位置。

本轮修正：

```powershell
.\scripts\Sync-Skills.ps1 -SkillRoot "$HOME\.agents\skills"   -Force   # Codex
.\scripts\Sync-Skills.ps1 -SkillRoot "$HOME\.workbuddy\skills" -Force   # WorkBuddy
```

安装后核对：**9 个 SKILL.md + 30 个脚本 + 13 个测试 + 4 份 references**，
与仓库 `diff -rq` 完全一致。旧版备份经确认无用后已删除。

> 这条推翻了 Phase 4.2 的一个隐含前提。"197/197 测试通过"是真的，
> 但那些测试跑的是仓库代码；"目标平台能否加载这些 Skills"是另一件事，
> 此前没有任何证据回答它。

---

## 2. 真实 Skills 加载证据（Task 1）

用 WorkBuddy 的 `Skill` 工具逐个加载 9 个技能，平台返回
`Base directory for this skill: %USERPROFILE%\.workbuddy\skills\<name>`
与完整 SKILL.md 正文。这就是**内容被加载**的硬证据。

新增 `mas_skill_audit.m` 把五级事件固化成台账：

```
DISCOVERED  9    平台列出该技能
LOADED      9    平台返回了正文
SELECTED    0    无证据
WORKFLOW    0    无证据
ACCEPTED    0    本台账未接验收器
```

**诚实的部分**：后三级在本 harness 里没有证据。本轮 benchmark 用**固定任务
脚本**，不涉及 Agent 的选路与规划。所以台账报 `INCOMPLETE_CHAIN`，不报全绿。

设计上不让缺证据的级别静默变 OK：`discoveredNotLoaded` 精确列出"已发现但未
加载"者。修名前 9 个全列，因为 jsondecode 把键里的连字符变成下划线——
和 `routing.json` 同一个坑。

---

## 3. 真实 MATLAB MCP 链路（Task 2）

Phase 4.2 报 R2/R3 SKIP，理由是"本会话未绑定 `mcp__matlab*`"。
本轮不绕过限制，而是**直接把官方 server 跑起来**：

```
server  bin\matlab-mcp-server-windows-x64.exe   v0.15.0
args    --matlab-session-mode=auto --matlab-display-mode=nodesktop
        --initialize-matlab-on-startup=true
```

参数用仓库自己的 `Install-MatlabMcpClients.ps1 -DryRun` **生成**，没有手写。
握手 757 ms，`tools/list` 返回 **5 个真实工具**：

| 工具 | 用途 |
|---|---|
| `check_matlab_code` | 静态检查 .m |
| `detect_matlab_toolboxes` | 列出已安装工具箱 |
| `evaluate_matlab_code` | 在真实 MATLAB 执行内联代码 |
| `run_matlab_file` | 执行脚本文件 |
| `run_matlab_test_file` | 跑测试脚本 |

`evaluate_matlab_code` 实测：真实 R2026a（26.1.0.3276743）执行，返回 **117 个工具箱**。

已注册进 `~/.workbuddy/mcp.json`（合并，保留 solidworks，原文件备份 `.bak-phase43`）。
**新 MCP 需重启会话才加载工具**，故本轮的 MCP 调用全部经由 stdio 传输。

---

## 4. R1/R2/R3 对照评测（Task 3）

### 4.1 参考值是算出来的，不是写出来的

**第一版 6 条参考值里 5 条是错的**，独立双路推导后全部纠正：

| 任务 | 凭记忆写的 | 真实值 | 差在哪 |
|---|---|---|---|
| B1 | x=[1;-3;2] | [0.318182;-3.090909;3.318182] | 手写解残差 4.12，根本不对 |
| B2 | pm=51.83° | pm=55.862240° | 且原传递函数**没有 0 dB 交越**，margin 返回 Inf |
| B3 | 峰值 bin 10 | bin 11 | 1-based 索引，bin k ↔ (k-1)·fs/N |
| B4 | slope 2.02, int 0.02 | slope 2.01, int 0.03 | 手算错 |
| B5 | x=1.1294 | x=0.995434926336 | 用了错的 cos(75°) 项 |

每条最终由**两条独立路径**在 MATLAB 算出并互证（`A\b` vs `pinv`；`margin` vs
解析式；`abs(fft)` vs 直接 DFT 投影；`polyfit` vs `fitlm` vs 手公式；几何式 vs
齐次变换）。推导脚本留在 `evals/derive_phase43_refs.m`。

### 4.2 结果（`artifacts/validation/phase43/grade.json`）

三组各 3 次重复，同一套固定任务脚本、同一个 MATLAB、同一个独立 grader：

| 组 | 通道 | Skills | B1 | B2 | B3 | B4 | B5 | B6 | 合计 |
|---|---|---|---|---|---|---|---|---|---|
| R1 | `matlab -batch` | 无 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 0/3 | **15/18** |
| R2 | 官方 MCP | 无 | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 0/2 | **15/17** |
| R3 | 官方 MCP | **有** | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | **3/3** | **18/18** |

（R2 少一次 B6 是运行被外部中断，不是失败；该组实际完成 17 次。）

**唯一区分三组的是 B6**：它调用 `mas_codegen_ready`，该函数只存在于本仓库。
R1/R2 的沙箱**故意不含** skills 目录，所以不可能读到现成解法；B6 因此无法执行，
grader 记为 **ERROR（没测到）而非 FAIL（数值错）**——这个区分是刻意的。

R3 的 B6 三次全部返回 `READY`，与冻结参考一致。

### 4.3 这个结果证明什么、不证明什么

**证明**：Skill 提供的可执行工具确实触达了真实 MATLAB，并完成了一个
没有它就无法完成的任务。

**不证明**：Skills 让 Agent 更聪明。任务脚本是固定的，本轮不测 Agent 的
自主规划、选路与错误恢复。把 18/18 读成"Agent 能力提升"是过度解读。

---

## 5. 顺带查出并修掉的缺陷

| 编号 | 缺陷 | 发现方式 | 后果 |
|---|---|---|---|
| P1 | UAV Toolbox 不在产品映射表 | MCP 报 117 个工具箱 vs 矩阵写 NOT INSTALLED | 能力矩阵撒谎；UAV 已装已授权却被判不可用 |
| P2 | Communications feature 名错，误报 NOT_LICENSED | 授权返回 0 但产品探针能跑 | 假阴性，可用产品被判不可用 |
| P3 | `mas_codegen_ready` 无法解析**完整路径** | R3 跑 B6 时报 `cannot open `（空参数） | `which()` 对完整路径返回空；文档明写接受路径却解析失败 |

P3 的回归测试特意用**不在 path 上**的临时文件——原有 5 条用例都把 fixture
目录 `addpath` 了，所以这个缺陷一直测不出来。
**"测试用例把 bug 藏起来了"这件事本身值得记。**

修复后：`test_dep_probe` 17 → **26/26**，`test_codegen` 11 → **12/12**。
P2 配了负对照（`skipExec` 时必须回到 NOT_LICENSED），防止"救援"变成"永远 OK"。

---

## 6. 驱动器自身的坑（都已修，留档）

| 现象 | 根因 |
|---|---|
| MATLAB `system()` 报"输出参数未赋值"，栈只指调用行 | MATLAB 的 `unassignedOutputs` 不显示局部函数栈帧；真实错误被它盖住 |
| `task_B1` 无法识别 | MATLAB 不把当前目录放上 path，`cd` 之后仍找不到脚本 |
| `RUN 无法执行文件 ... 需要有效的 MATLAB 脚本` | `Copy-Item -Destination <目录>` 保留**源文件名**，与 runner 引用的名字不符 |
| 53 个 result.json 全部 `jsondecode` 失败 | PowerShell 5.1 的 `-Encoding utf8` 实际写 UTF-16LE + BOM。改用 `-Encoding ascii` |
| 第一个任务失败就中断整轮 | `$ErrorActionPreference = "Stop"` 把子进程的 stderr banner 当终止错误 |

最终方案：**PowerShell 驱动执行，MATLAB 只当 grader**。在 `matlab -batch`
里驱动 MCP server 的尝试已放弃并删除——那不是评测该有的复杂度。

---

## 7. 环境兼容性（Task 5，部分）

查出并记录，尚未全面改造：

- SKILL.md 硬编码 `MATLAB R2026a`：`matlab-orchestrator`、`matlab-runner` 的
  description 与正文写死版本。本机确实是 R2026a，但换版本会误导。
- `Sync-Skills.ps1` 的**默认 `-SkillRoot` 仍是错的**（指向 `.codex/skills`）。
  本轮靠显式传参才对。默认值应改为 `.agents/skills`，否则下一个人照样装错。
- SKILL.md 里手写测试用例数（"32 cases"/"17 cases"）已与实际（34 / 26）不符。
  这类数字不该手写。

---

## 8. Task 7 的诚实回答

**问题：能否证明"本项目 Skills 对 MATLAB Agent 有实际增益"？**

**答：不能。证据链缺一环。**

已有的证据：
1. 9 个 Skills 能被平台真实发现并加载（§2）
2. 官方 MATLAB MCP 链路真实可用，5 个工具实返（§3）
3. Skill 的工具（`mas_codegen_ready`）解决了一个没有它就无法完成的任务，
   且在 3 次重复中稳定成立（§4.2）

缺的证据：
- **没有一次真实 Agent 会话**，其中 Agent 自己读任务描述、自己选 Skill、
  自己决定调哪个工具、自己从错误里恢复。本轮代码全是写死的。
- 因此 SELECTED / WORKFLOW / ACCEPTED 三级无证据（§2）。
- 没有首次成功率、自动恢复成功率这类需要 Agent 自主行为的指标。

**当前能说的最强结论**：
Skills 已被证明**可安装、可加载、可执行**，且其工具解决了一个没有它就
无法完成的任务；Skills 对 **Agent 自主能力**的增益**尚未测量**。

**最小下一步**（不需要新工具）：把 `evals/phase43_benchmark.json` 里的
**自然语言 prompt**（不是脚本）分别交给 R1/R2/R3 三个真实 Agent 会话，
让它们自己写代码、自己跑，再用同一个 grader 打分，各 3 次。
这一步才能回答"增益"问题。

---

## 9. 复现命令

```powershell
# 安装到两个平台
.\scripts\Sync-Skills.ps1 -SkillRoot "$HOME\.agents\skills"   -Force
.\scripts\Sync-Skills.ps1 -SkillRoot "$HOME\.workbuddy\skills" -Force

# 真实 MCP 握手与 tools/list
.\scripts\Test-Phase43McpHandshake.ps1

# 参考值独立推导（双路径互证）
matlab -batch "cd('evals'); derive_phase43_refs"

# 完整 R1/R2/R3 评测（三组各三次）
.\scripts\Invoke-Phase43Benchmark.ps1 -Group ALL -Repeats 3

# 独立评分（不执行任何 MATLAB 任务，只比对数字）
matlab -batch "addpath('skills/matlab-testing-ci/scripts'); mas_phase43_grade"

# 全部回归测试
matlab -batch "addpath('matlab/validation/phase4'); run_all('artifacts/validation/phase4')"
```
