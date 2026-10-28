# Phase 5.7 · 原生 Skills 调用证据（Task 2）

日期：2026-10-23　客户端：Qoder 主会话、Qoder 子会话、Codex CLI 0.147.0、
Codex Desktop engine 0.163.0-alpha.11.1

## 1. 四级证据的定义

| 级别 | 含义 | 需要的证据 |
| --- | --- | --- |
| L1 | 源码存在 | 仓库中有 `SKILL.md` 与可执行脚本 |
| L2 | 客户端发现/装载 | 客户端自己的列表、日志或工具解析到该 Skill |
| L3 | 原生调用事件 | 客户端实际发出 Skill 调用（自动或显式），有 transcript 事件 |
| L4 | 对工作产出的影响 | 在允许执行的对照中，加载 Skill 改变了工作流或结果 |

**L2 不等于 L3，L3 不等于 L4。** 目录存在、配置写了路径、系统提示里列出了 Skill，
都不能单独升级为 L3。

## 2. 本轮观察

证据文件：`artifacts/phase57/native/qoder_trigger_evidence.json`（含三个会话 transcript
的 SHA-256、工具事件计数）。

| 级别 | 状态 | 证据 |
| --- | --- | --- |
| L1 | EVIDENCED | 9 个 Skill，`skills/*/SKILL.md` 齐全（`artifacts/phase57/task0/baseline_audit.json`） |
| L2（Qoder） | EVIDENCED | `qodercli.log` 的 override 行 + `Skill` 工具成功解析 `matlab-orchestrator` |
| L2（Codex CLI/Desktop） | EVIDENCED | app-server `skills/list` 返回 9/9，`discoveryErrors=[]` |
| L3（Qoder 自动触发） | **NOT EVIDENCED** | MATLAB BER 任务会话只有 `mcp_list/mcp_get/mcp_call`，Skill 事件 0 |
| L3（Qoder 显式调用） | EVIDENCED | 显式请求会话出现 `Skill` 事件，加载 `matlab-orchestrator` |
| L3（Codex 调用） | NOT TESTED | 本轮只做了发现探针；没有用 Codex 跑一次 Skill 任务 |
| L4 | NOT TESTED | 显式验证任务禁止运行 MATLAB，无法把产出归因于 Skill |

### 会话

| 角色 | 会话 | Skill 事件 | 其他工具 | 结果 |
| --- | --- | ---: | --- | --- |
| 自动触发（MATLAB 任务） | `c0b3bbc4-4482-455e-a4b3-85db4dcd3f07` | 0 | MCP 5 次 | 直接计算并给出正确 JSON，**未加载 Skill** |
| 负对照（非 MATLAB） | `f4bb0f35-b1bc-43f1-bcea-b04017d12ab6` | 0 | 无 | 纯文本改写，**未加载 Skill** |
| 显式调用 | `d8e01567-3b8a-48bc-8bad-61c7e6b1e292` | 1 | Grep 3、Read 1 | `Skill` 加载成功，读取 `.agents/skills/matlab-orchestrator/assets/routing.json` |

显式会话的结论是：**客户端机制是通的**。`Skill` 工具返回
`Launching skill: matlab-orchestrator`，随后 Skill 内容进入上下文，模型据此读取路由表。

自动会话的结论是：**没有自动触发**。这是一条否定证据，不是失败执行：任务本身完成且
正确，但没有任何 Skill 调用事件。不能把"模型会做 MATLAB 题"写成"Skill 被调用"。

## 3. 为什么自动触发没有出现

本轮只记录观察，不把原因断言为单一因素。至少以下解释都与证据相容：

1. 客户端把 Skill 视为**可选上下文**，由模型自行决定是否调用；
2. 当前 Skill 的 `description` 是路由型描述，未在首轮立即吸引模型；
3. 任务被模型判断为"可直接用 MCP 完成"，因而不进入 Skill 流程。

无论哪一种，**都不能用强制提示词让 Agent 对所有请求加载 MATLAB Skills** 来提高数字；
那会污染触发率，也会破坏负对照。

## 4. Codex 的边界

- 两个 Codex 客户端都从 `<home>\.agents\skills` 列出 9/9；
- 它们的版本分别是 `0.147.0` 与 `0.163.0-alpha.11.1`；
- 这只证明**发现**。本轮没有用 Codex 执行 MATLAB 任务，因此不能用 Qoder 的 L3 结果
  代替 Codex 的调用结论；
- Codex 的 `skills/list` 响应保存在 `artifacts/phase57/native/codex-cli/skills_list_response.json`
  与 `.../codex-desktop-engine/skills_list_response.json`。

## 5. 对交付的含义

- 可以声称：Skill 已安装、客户端能发现、Qoder 的显式调用机制可用。
- 不可以声称：Agent 会在自然语言 MATLAB 请求中自动加载 Skill。
- 不可以声称：加载 Skill 带来了更好的结果（L4 未测，且当前安装副本 7/9 落后）。
- 后续若要回答 L4，必须先完成任务 1 的同步（经批准），再做**同任务、同模型、同工具**
  的加载/不加载对照，并把结果与历史禁用的评分协议分开记录。

## 6. 复现

```powershell
# 发现探针（两个 Codex 客户端）
python .\scripts\Test-CodexSkillDiscovery.py
```

Qoder 的会话证据只能通过会话 ID 读取；原始 transcript 位于
`<home>\.qoder-cn\projects\E--desktop-MATLAB\<session-id>.jsonl`，
哈希已固化在 `qoder_trigger_evidence.json`。它们是**证据**，不是可重放的实验。
