function report = new(taskId, backend)
%NEW 创建验收报告骨架，字段与 schemas/acceptance-report.schema.json 对齐。
%
% 用法：
%   report = masacc.new("codegen-smoke", "matlab-batch");
%   report = masacc.addCheck(report, "codegen.generate", "生成 C 源码", "L1", "PASS");
%   report = masacc.write(report, fullfile(outDir, "summary.json"));

arguments
    taskId (1,1) string
    backend (1,1) string {mustBeMember(backend, ["static","matlab-batch","matlab-mcp-auto","matlab-mcp-existing","matlab-mcp-new"])}
end

template = masacc.checkTemplate();

% 记录真实可执行文件名：Windows 下是 matlab.exe，其它平台是 matlab。
% 写一个不存在的路径会让报告里的环境信息变成假证据。
if ispc
    executableName = "matlab.exe";
else
    executableName = "matlab";
end

report = struct();
report.schemaVersion = "1.0.0";
report.taskId = taskId;
report.backend = backend;
report.matlabVersion = string(version);
report.matlabRelease = "R" + string(version("-release"));
report.startedAt = masacc.timestamp();
report.finishedAt = [];
% computer 不接受 "os" 参数（实测 MATLAB:badopt），直接返回平台标识，如 PCWIN64。
report.environment = struct( ...
    "os", string(computer), ...
    "hostName", string(getenv("COMPUTERNAME")), ...
    "matlabInstalled", true, ...
    "matlabExecutable", string(fullfile(matlabroot, "bin", executableName)), ...
    "powerShellVersion", "");
report.toolboxInventory = masacc.inventory();
report.checks = template(zeros(0, 1));
report.summary = struct("total", 0, "pass", 0, "fail", 0, "skip", 0);
report.overallStatus = "SKIP";
report.achievedLevel = "L0";
report.levelStatus = struct("L1", "SKIP", "L2", "SKIP", "L3", "SKIP", "L4", "SKIP", "L5", "SKIP");
report.limitations = strings(0, 1);
report.unexecuted = struct("capability", {}, "level", {}, "reason", {});
end
