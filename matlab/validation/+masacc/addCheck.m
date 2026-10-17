function report = addCheck(report, id, title, level, status, options)
%ADDCHECK 追加一条检查项；SKIP / FAIL 缺少 reason 时直接报错。
%
% 用法：
%   report = masacc.addCheck(report, "codegen.generate", "生成 C 源码", "L1", "PASS");
%   report = masacc.addCheck(report, "simulink.sim", "仿真输出", "L3", "SKIP", ...
%       Reason = "Simulink 未授权", Metrics = struct("sampleCount", 0));

arguments
    report (1,1) struct
    id (1,1) string
    title (1,1) string
    level (1,1) string {mustBeMember(level, ["L1","L2","L3","L4","L5"])}
    status (1,1) string {mustBeMember(status, ["PASS","FAIL","SKIP"])}
    options.Reason (1,1) string = ""
    options.Command (1,1) string = ""
    options.ExitCode = []
    options.Metrics = struct()
    options.ErrorClass (1,1) string = ""
    options.ArtifactPaths = strings(0, 1)
    options.StartedAt (1,1) string = ""
    options.FinishedAt (1,1) string = ""
    options.DurationSeconds = []
    options.SourceReport (1,1) string = ""
end

if status ~= "PASS" && strlength(options.Reason) == 0
    error("masacc:reasonRequired", ...
        "检查项 %s 的状态为 %s，必须提供 Reason；跳过与失败都必须可审计。", id, status);
end

check = masacc.checkTemplate();
check.id = id;
check.title = title;
check.level = level;
check.status = status;
check.command = options.Command;
check.exitCode = options.ExitCode;
check.startedAt = options.StartedAt;
check.finishedAt = options.FinishedAt;
check.durationSeconds = options.DurationSeconds;
check.metrics = options.Metrics;
check.reason = options.Reason;
check.errorClass = options.ErrorClass;
check.artifactPaths = cellstr(options.ArtifactPaths(:)');
check.sourceReport = options.SourceReport;

report.checks(end + 1) = check;
end
