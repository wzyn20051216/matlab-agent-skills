# Phase 5.7 · 并发隔离与 MATLAB Coder 入口契约（Task 7）

日期：2026-10-23
代码：`skills/matlab-codegen-deploy/scripts/mas_codegen_verify.m`、
`skills/matlab-codegen-deploy/tests/test_codegen.m`、
`matlab/validation/phase54/test_concurrency.m`、
`matlab/validation/phase57/{p57_concurrency_evidence,p57_coder_contract}.m`
证据：`artifacts/phase57/task7/`

## 1. 先区分两个问题

Task 7 明确要求区分**已验证的并发隔离**与**高负载下的稳定性**。本轮的结论是：

| 问题 | 结论 | 依据 |
| --- | --- | --- |
| 两个并发进程是否互相污染日志、夹具或构建目录 | **已验证：不污染** | 3 轮 × 2 进程，15/15；跨会话字符串 0；夹具归属 6/6；残留 0 |
| 四个进程同时运行时是否仍然稳定 | **不主张** | 只做了 1 轮探索性观测，记为 `EXPLORATORY`，不当作稳定性结论 |
| Phase 5.6 的 11/13 重叠日志是否由资源竞争导致 | **NOT ESTABLISHED** | 日志无会话/进程身份，无法归因；只作为观测保留 |

高负载下的退化可以来自 CPU、内存、编译器临时文件或客户端通道，不能仅凭“同时跑就变慢/失败”断言资源竞争。本轮没有做受控对比，因此不写这种因果句。

## 2. Phase 5.6 重叠日志：原样保留，只读复核

`p57_concurrency_evidence.m` 读取
`artifacts/phase54/evidence/concurrency_regression/20261022_230327/*.log`，只计算哈希与行级统计，不复制、不改写、不删除：

- 6 个日志，全部 **11/13**，内容逐字节相同
  （sha256 `8fcee464dc095ded17fce565a4db1ac3206d21d0df7bb1f9898e5e1bed0fb79d`）；
- 失败的两项都是依赖真实构建的用例：`verify: PASS on a real function` 与
  `verify: FAIL via goldenFcn mismatch`；
- 日志不含 session id 或 pid，**无法把某份日志归给某个进程**；
- 归因：`NOT POSSIBLE`；因果：`NOT ESTABLISHED`。

这条记录回答的是“历史上确实看到过一次并发退化”，不是“已经证明并发会导致退化”。

## 3. 冲突面与修复

旧的 codegen 路径有三个共享点：

1. `codegen -d <buildDir>` 同时会在**当前目录**放一份 MEX；
2. 构建目录由调用方传入时，另一个进程可能正在使用；
3. 清理阶段会删除构建目录，可能删掉别人的产物。

现在的约束：

- 每个测试进程写入自己的 `MAS_RUN_SESSION`；临时根由 `MAS_CODEGEN_RUN_ROOT` 指定，
  默认落到 `%TEMP%/mas_codegen_tests/<session>`。
- 夹具目录、构建目录、工作目录都在该会话根下；`codegen` 在一个私有的临时 cwd 中运行，
  结束后恢复调用方目录。
- 夹具目录写 `.mas_run_owner`；会话根写 `.mas_run_session.json`。清理时先核对
  owner 与 manifest，只删除自己的目录，且**只对会话根做非递归删除**——根里若还有
  别人的东西，删除会失败而不是递归清除。
- 清理不会删除调用方的当前目录或工作目录；若 `outDir` 与它们相同，则保留不删。
- `keep=true` 时保留构建树供取证；默认仍然清理。

这不是“给 Prompt 加一句不要互相干扰”，而是把共享路径变成按会话隔离的路径。

## 4. 隔离验证

`test_concurrency(3, 2, true)` 的结果：

| 检查 | 结果 |
| --- | --- |
| 每轮两个进程的用例 | 6/6 个进程均 **15/15** |
| 自己的 session 出现在自己的日志 | 6/6 |
| 日志中出现另一个 session 的字符串 | 0 |
| 夹具目录位于自己的会话根下 | 6/6 |
| 共享夹具目录 | 不存在 |
| 仓库内新增 `.mexw64` | 0 |
| 新增临时会话目录 / 根文件 | 0 / 0 |
| `isolation.verified` | `true` |

`stability.status` 在 2 进程配置下是 `NOT CLAIMED`：隔离成立不代表数值或性能在压力下稳定。

另做了一轮 4 进程探索性观测（`stressObservation.status = EXPLORATORY`）：4 个进程均为 15/15，
隔离结构仍成立。它只说明“这一次没有看到污染”，不构成稳定性或竞争结论，也不进入正式判据。

## 5. MATLAB Coder 入口契约

`p57_coder_contract.m` 固定三个入口，全部保留原始返回值：

| 入口 | verdict | stage | 关键证据 |
| --- | --- | --- | --- |
| 字符串函数名 `'p57_cg_ok'` | PASS | compare | 真实 `codegen` → MSVC 2022 构建 → MATLAB 与 MEX 均执行；`maxAbs 0`；保留的 buildLog 4432 字节 |
| 函数句柄入口 | FAIL | codegen | `emlc:compilationError`，消息明确指出“传函数名，不要传句柄/anonymous function” |
| 真实链接失败 | FAIL | build | `LNK2019` + `LNK1120`；编译器日志 5561 字节，落盘后逐字节一致 |

链接失败用的夹具调用了 `coder.ceval('mas_undefined_symbol_xyz', ...)`：它能通过代码生成，
只在链接期失败。这样 `stage` 的区分是被真实故障验证过的，而不是靠构造一个必然在前端失败的错误。

**阶段区分是关键**：“构建失败”和“生成的代码算错”是两种问题、两种修法。只有 compare
阶段失败才是数值不一致；build 阶段失败会被明确报告为构建问题。

## 6. 空消息缺陷与修正

`emlc:compilationError` 在本机至少覆盖两种完全不同的情况，且 `ME.message` 都为空：

1. 入口不是文件名（函数句柄、anonymous function）；
2. 编译/链接本身失败（此时磁盘上有 `build/win64/buildLog.log`）。

早期实现把所有空消息都解释成“传了函数句柄”。当一个字符串入口因语法错误在前端被拒时，
这条诊断会把用户引向错误的修复方向。现在的判定顺序是：

```
catch ME
  logs = collect_logs(buildDir)
  if 有日志        → stage = build，消息引用日志中的 LNK/fatal error
  else if isa(fcn,'function_handle')
                   → stage = codegen，明确要求传函数名
  else             → stage = codegen，说明在前端被拒、没有编译器日志
```

`test_codegen.m` 的 `verify_string_entry_detail` 专门钉住第三种情况：入口是字符串、
在构建前失败、消息必须提到 `syntax_bad` 和 `before the build`，且**不得**出现
`function handle`。

编译器日志按原始字节保存：读取用 `fread(...,'*uint8')`，写盘用 `uint8`。早期的
`fread(...,'*char')`/`fwrite(...,'char')` 会按编码解码再编码，把 5561 字节变成 5512
左右的字符再写回 5610 字节；现在 `byteExact = true`，sha256
`1a158f7dbb841b98a02b9382151b474d833d913a1b95b114ac5b9b2c29da847e`。

## 7. 复现

```matlab
% 真实并发隔离（3 轮 × 2 进程）
cd('<repo>/matlab/validation/phase57')
p57_concurrency_evidence

% Coder 三入口契约 + 原始编译器日志
p57_coder_contract

% 用例级回归（15 例）
cd('<repo>/skills/matlab-codegen-deploy/tests')
test_codegen
```

输出：

- `artifacts/phase57/task7/concurrency_evidence_<stamp>.json`
- `artifacts/phase57/task7/coder_contract.json`
- `artifacts/phase57/task7/build_failure_compiler.log`

## 8. 未主张

- 没有修改官方 MCP Server；
- 没有把工具级并发隔离升级为 Agent 级隔离；
- 没有把一次 4 进程观测写成稳定性或资源竞争结论；
- 没有扩展到新的大型代码生成案例；范围仍是同一个 `mas_codegen_verify` 契约。
