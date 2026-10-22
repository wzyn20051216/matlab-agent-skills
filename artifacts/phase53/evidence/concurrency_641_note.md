# 并发运行导致的 641/643（非产品回归）

- 时间：2026-10-22 约 10:55（本地）
- 现象：`run_all` 报 **641/643**；`codegen 10/12`；G1 跨域任务
  `[self FAIL vs verifier PASS]`；`selfDisagreement=1`。其余 suite 全绿。
- 环境事实：当时有 **两个 MATLAB 进程**同时运行同一 `run_all`：
  1. 交互式会话中的一次 MCP 调用（客户端已超时，但 MATLAB 继续执行）；
  2. 一个 `matlab -batch` 新进程。
- 直接证据：日志出现
  `已将 ...\skills\matlab-codegen-deploy\tests\fixtures_codegen 从此 MATLAB 会话的
  MATLAB 路径中删除`，由 `test_codegen` 的 `onCleanup` 触发。两个进程共用该夹具目录，
  一个进程的清理删除了另一个进程正在使用的夹具。
- 恢复：结束并发后单进程重跑，`test_codegen 12/12`，全量 **643/643**，
  `selfDisagreement=0`；加入新增 harness 用例后为 **644/644**。
- 结论：这是测试夹具的并发缺陷，不是 Phase 5.3 产品代码的回归。
  未修改 `test_codegen` 或任何冻结阈值；`run_all` 必须单实例串行运行，
  此限制已列入交付报告的残余缺陷。
- 说明：641/643 的完整控制台输出被随后的干净重跑覆盖，未能保留为文件；
  上述数字来自当次会话输出，特此标注来源。
