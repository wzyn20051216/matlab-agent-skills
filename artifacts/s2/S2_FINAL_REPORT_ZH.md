# MATLAB Agent Skills — S2 最终交付报告

- 主题：Skill 资源可移植性与独立安装验收
- 日期：2026-10-26
- 报告状态：S2 完成，等待人工审查；未进入 S3，未进入 Phase 5.9
- 历史证据：未删除、未重写、未覆盖

## 1. 当前分支、HEAD 与工作区

| 项目 | 值 |
| --- | --- |
| 分支 | `phase5.1-audit` |
| HEAD | `876a2b0c67dae275c199415752226ed71c9c344f` |
| 工作区 | 32 个变更路径：23 个已跟踪修改、9 个未跟踪新文件 |
| 提交/推送/合并/变基/重置/清理 | 均未执行 |
| 真实用户级 Skills 目录、C 盘配置、main、Release | 均未修改 |

S1 基线（`artifacts/s2/baseline/s1_manifest.json`，14 个文件）当前核验结果：

- 11 个文件与基线 SHA-256 完全一致；
- 3 个文件是 S2 有意继续修改：`scripts/MatlabAgentSkills.Core.psm1`、`scripts/MatlabAgentSkills.McpProbe.psm1`、`skills/matlab-runner/SKILL.md`；
- 没有发现无法解释的工作区变化；S1 的历史修改未被覆盖或回退。

## 2. S2 实际改动

S2 仅新增/修改资源发布、路径锚定、测试与文档，共 21 个文件（17 修改 + 4 新增，+1974/−59）：

1. **安装期资源发布（payload）**
   - 新增 `config/skill-payloads.json`：声明 `matlab-runner` 7 个文件、`matlab-orchestrator` 6 个文件，从仓库 `scripts/` 与 `schemas/` 的规范源复制到安装副本。
   - `scripts/MatlabAgentSkills.SkillInstallation.psm1`：校验 payload 清单、相对路径、仓库边界与符号链接。
   - `scripts/Sync-Skills.ps1`：写入前加载并校验 payload 清单，记录清单 SHA-256。
   - `scripts/MatlabAgentSkills.Core.psm1`：`Get-DirectoryTreeHash -AdditionalFiles` 与 `Sync-SkillDirectory -PayloadFiles`，用“源目录 + payload”的虚拟指纹做暂存/提交一致性校验，避免重复同步误判为变更。
2. **探针路径锚定**
   - `scripts/Test-MatlabMcpExistingSession.ps1`：模块导入基于 `$PSScriptRoot`；新增 `-ProjectRoot`、`-ArtifactsRoot`、`-SkipCodexCli`、`-SkipUserConfigs`；产物写到调用者项目，不写安装目录。
   - 官方 MATLAB MCP Server、Agent、Router 未重构。
3. **兼容性修复**
   - `scripts/MatlabAgentSkills.McpProbe.psm1`：PowerShell 7 无 `System.Web.Extensions` 时，用 `System.Text.Json.JsonDocument` 保持大小写敏感 JSON 语义，兼容大小写变体键。
4. **测试**
   - 新增 `tests/SkillPayloadContract.Tests.ps1`（12 条）、`tests/SkillPayloadInstall.Tests.ps1`（10 条）、`tests/Invoke-S2Acceptance.ps1`（A–J 独立验收）。
   - `tests/McpProbe.Tests.ps1` 增加 JSON 大小写键回归测试。
5. **文档**
   - 11 个 Skill 文档/引用（9 个 `SKILL.md` + 2 个 runner references）改为显式 Skill 根解析，命令在任意 cwd 可运行；清除仅仓库可用/不存在的脚本引用；保留触发与渐进加载语义。
6. **明确未做**
   - 未新增第十个 Skill；未提交 payload 副本到 `skills/`（安装副本是构建产物）；未修改官方 MCP Server；未打包 `sessionDetails.json`、API Key、证书私钥或运行凭据。

## 3. 修复前失败证据

证据目录：`artifacts/s2/pre-fix/evidence/`

- 按原文档从“仅安装 Skills”的 `matlab-runner` 目录执行：
  `.\scripts\Test-MatlabMcpExistingSession.ps1` → `-File` 参数指向的文件不存在，退出码 `-196608`。
- 从项目 cwd 用绝对路径执行安装副本 → 同样失败。
- 依赖闭包阶梯（`closure_ladder.json`）逐级补文件：
  1. 仅探针 → 缺 `Acceptance.psm1`；
  2. +Acceptance → 缺 `Execution.psm1`；
  3. +Execution → 缺 `McpProbe.psm1`；
  4. +McpProbe → 缺 `Core.psm1`（`Get-FileSha256` 未识别）；
  5. +Core → 探针可运行并写报告；
  6. +schema → 结果不变。
- 这证明真实闭包是 5 个脚本/模块 + schema，而不是只发布入口脚本。

## 4. 修改文件与精确 Diff

- 精确 S2-only 统一 diff：`artifacts/s2/evidence/task7/s2-only.diff`
  （SHA-256 `369FE9F20902BEA41899CB034C1D8DE194EA9730C019D90E23BADEBA9739CB62`）
- 统计：`artifacts/s2/evidence/task7/s2-only.stat.txt`（21 files, +1974/−59）
- 文件分类（哪些叠加在 S1 上、哪些基于 HEAD、哪些新增）：
  `artifacts/s2/evidence/task7/s2-file-classification.json`
- Diff 以 S1 基线快照为旧侧；S1 快照由 HEAD + 基线补丁重建，并逐文件 SHA-256 与基线清单一致后才用于比较。
- 为便于阅读，diff 忽略行尾 CR（`--ignore-cr-at-eol`）；内容改动均完整保留，未省略任何语义修改。

## 5. 修复后独立安装验收

证据：`artifacts/s2/acceptance/20261026-134858/`（A–J：10 PASS / 0 FAIL / 0 SKIP）

| 检查 | 结果 |
| --- | --- |
| A 首次安装九个 Skill | 退出 0，安装 9 个，无缺失 |
| B 安装资源与 SHA-256 一致性 | 119 个文件，0 失败，0 禁止文件；payload 清单 SHA-256 `2914FF29...2065CA` |
| C 在仓库与 Skill 根之外执行 | 4 个模块全部来自安装根，`outside=0` |
| E 无源仓库回退 | `cleanRootHasRepo=False`，`moduleOutside=0`，`fallbackHits=0` |
| F 重复安装零写入 | `unchanged=9`，`diff=0`，manifest 相等，备份会话数不变 |
| G 升级失败回滚 | 退出 1，`decision=error`，`restored=True`，`diff=0`，暂存目录 0 |
| H 新布局下的 S1 凭据保护 | 脱敏生效，21 个文件扫描，0 泄漏 |
| I 卸载无残留 | 移除 9 个，`residualSkills=0`，`residualPayload=0` |
| J 沙箱清理 | 已删除 |

D 的定义是“安装副本能执行探针并产出分级结论”，不是“真实 MCP 已可用”。本次 D 的真实分级为 `overall=FAIL`、`achieved=L0`，见第 7 节。

## 6. 无源仓库执行证据

- C/E 检查在干净安装根进行，源仓库不可见；模块解析全部落在安装副本内（`outside=0`），无 fallback 读取。
- 安装副本的模块来源为 `<skill>/scripts/`，不依赖调用者 cwd。
- 独立复跑真实 MCP 冒烟时，探针来自临时隔离安装副本（payload SHA 与规范源一致；该临时目录已在交付前清理），项目 cwd 在项目盘临时目录。

## 7. MATLAB MCP 会话证据与真实执行状态

- 会话描述符可解析：PID 7008 存活，端口 31519 可连接，API Key 存在（只记录长度 48，不输出值）。
- 默认安装副本探针：`mcp.matlab-install=PASS`、`mcp.session-config=PASS`、`mcp.protocol-handshake=FAIL`（TLS 信任错误），L3/L4 SKIP，`overall=FAIL`、`achieved=L0`。
  证据：`artifacts/s2/acceptance/20261026-134858/D-probe.report.json`
- 以文档化的 `-SkipTlsValidation` 对回环地址做最小只读冒烟：握手到达 HTTP 403（服务器拒绝当前凭据/认证），L3/L4 仍 SKIP。
  证据：`artifacts/s2/evidence/task6/real-mcp-smoke/probe.json`
- 证据中未出现 Authorization 头或 API Key 值。
- **结论：真实 MCP L3/L4 执行 BLOCKED，S2 不声称已打通。** 解除需要人工重启会话/轮换凭据或处理 TLS 信任；本轮未修改 C 盘、系统信任或真实会话配置。

## 8. S1 安全回归

| 测试 | PowerShell 5.1 | PowerShell 7.6.9 |
| --- | --- | --- |
| `CredentialSanitizer.Tests.ps1` | 11 / 11 | 11 / 11 |
| `McpCredentialOutput.Tests.ps1` | 5 / 5 | 5 / 5 |

安装布局凭据扫描 21 个文件，0 泄漏。S1 的脱敏、凭据短持有、报告仅记录会话文件指纹等逻辑未被重写。

## 9. MATLAB / PowerShell 回归

| 门禁 | 结果 |
| --- | --- |
| MATLAB skill 测试 | 1127 / 1127 |
| MATLAB reference / cross-domain / pipeline | 15/15、15/15、15/15 |
| MATLAB suites | 32 个，0 errored，`allOk=1` |
| Pester free 层（5.1） | 352 / 353 |
| Pester free 层（7.6.9） | 352 / 353 |
| 九 Skill 路由 | 7/7 ROUTE，主 Skill 与 runner 均正确 |
| capability matrix | 5 项检查，`CONSISTENT` |

唯一失败是既存的仓库卫生门禁（盘符硬编码路径）：77 个命中 / 449 个文件，PS 5.1、PS 7 与历史 S2 运行完全一致；21 个 S2 变更/新增文件单独扫描 0 命中。未放宽断言、未删除测试、未改写历史证据。

证据：`artifacts/s2/evidence/task6/GATES.md`、`free-ps51-final`、`free-pwsh7-final`、`matlab-regression-final/`、`matlab-logs/s2_task6_consistency_20261026_133710.*`。

## 10. 资源依赖与版本闭包结论

- 安装副本的探针闭包：入口探针 + `Acceptance.psm1` + `Execution.psm1` + `McpProbe.psm1` + `Core.psm1` + `acceptance-report.schema.json`；runner 另含 `Invoke-MatlabBatch.ps1`。
- payload 清单：runner 7 个文件、orchestrator 6 个文件；唯一源文件 7 个，规范源位于仓库 `scripts/` 与 `schemas/`。
- 安装期从规范源复制，安装副本为构建产物；仓库中未提交重复实现，避免长期双维护。
- 安装资源 119 个文件与源 SHA-256 全量一致（B 检查 0 失败），payload 清单 SHA-256 固定为 `2914FF29...2065CA`。
- 探针产物默认写到调用者项目而非安装目录，安装副本哈希不会因运行而漂移（F 检查零写入）。
- PowerShell 5.1 与 7.6.9 均通过探针、McpProbe 与完整 free 层（除同一既存卫生失败）。

## 11. 未解决的已知问题

1. **真实 MCP L3/L4 仍 BLOCKED**：TLS 信任失败；回环冒烟为 HTTP 403。需要人工重启/授权会话或轮换凭据，不能在 S2 内自行处理。
2. **既存仓库卫生门禁失败**：77 个历史盘符路径命中，S2 未新增；本轮按约束保留失败，不清理历史文件。
3. **部分 Skill 内 `.m` 辅助脚本仍读取仓库数据**：`matlab-testing-ci`、`matlab-orchestrator` 等脚本依赖 `evals/`、`artifacts/`、`capability-matrix.json`、`matlab/boost` 等；审计记录在 `artifacts/s2/audit/dependency_audit.md` 第 5 节。它们不属于安装后的 MCP 探针路径，但仍是 S3 候选。
4. **`matlab-codegen-deploy` 的测试需要 cwd 位于 Skill 的 `tests/`**；文档已如实说明，未伪装成任意 cwd 可用。
5. **`Invoke-MatlabBatch.ps1` 分类瑕疵**：成功运行仍标 `error_class=CODEGEN_ERROR`（退出码 0），属于既有分类问题，未在 S2 修改。
6. **许可证阶段默认 SKIP**：只有传 `-VerifyLicense` 才启动 MATLAB 验证；本轮未声称许可证可用。
7. **S1 历史暴露凭据仍需人工撤销/轮换**：`%APPDATA%\MathWorks\MATLAB MCP Server\v1\sessionDetails.json` 的 `apiKey` 字段；本报告不复制其值，也不推断其已失效。

## 12. 是否具备进入 S3 用户验收的条件

- **资源可移植性与独立安装：具备。** 九个 Skill 可在无源仓库、任意 cwd 下安装、执行已声明命令、重复安装零写入、失败回滚、卸载无残留，S1 保护在新布局有效。
- **真实 MCP 端到端：不具备。** L3/L4 被 TLS 信任/HTTP 403 阻塞，需人工恢复会话或轮换凭据后重跑；S3 不应把“探针分级报告可生成”冒充“真实执行成功”。
- **仓库整体绿色：不具备。** 既存卫生门禁仍有 77 个历史命中；S2 已证明未新增，但全绿需另行清理历史路径。
- 建议 S3 用户验收首先解决会话认证/信任，再以本报告第 5 节验收矩阵复跑；此外把第 11 节第 3 条纳入 S3 范围评估。

---

**S2 到此停止。未执行 S3，未进入 Phase 5.9；未 commit、push、merge、rebase、reset、clean；等待人工审查。**

---

## 13. 日期标注：2026-10-26（S3 追加，不改动上文）

第 7、11 节第 1 条与第 12 节中「真实 MCP L3/L4 BLOCKED」的判定已由 S3 解除并在
`artifacts/s3/S3_FINAL_REPORT_ZH.md`、`artifacts/s3/GATES_S3.md` 留证：安装副本在**未使用
`-SkipTlsValidation`** 的条件下，于 Windows PowerShell 5.1.26100 与 PowerShell 7.6.9 上均取得
`overall=PASS / achieved=L4 / exit=0`，L3 为 `evaluate_matlab_code` 返回真实版本串
`26.1.0.3276743 (R2026a) Update 3`，L4 为 MATLAB 写入 token 后宿主回读一致。
此前暴露的会话凭据已按证据判定失效并被替换（仅记录哈希前缀与长度，值从未输出）。
上文原始判定按历史证据原样保留，未改写、未删除。
