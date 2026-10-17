function report = write(report, path)
%WRITE 收尾并写出验收 JSON。
%
% 收尾动作：
% - 填充 finishedAt；
% - 统计 summary；
% - 由 checks 推导 overallStatus（任一 FAIL 即 FAIL，有 SKIP 即 SKIP，全 PASS 才是 PASS）；
% - 逐级计算 levelStatus 与连续达成的 achievedLevel；
% - 把空值翻译成 JSON null，写 UTF-8 JSON。

arguments
    report (1,1) struct
    path (1,1) string
end

checks = report.checks;
total = numel(checks);
if total == 0
    % schema 要求 checks 至少一条。空报告无法证明任何事，宁可直接报错。
    error("masacc:emptyReport", "验收报告至少需要一条检查项；空报告不能作为验收结论。");
end

report.finishedAt = masacc.timestamp();
statuses = strings(0, 1);
if total > 0
    statuses = string({checks.status})';
end

passCount = sum(statuses == "PASS");
failCount = sum(statuses == "FAIL");
skipCount = sum(statuses == "SKIP");
report.summary = struct("total", total, "pass", passCount, "fail", failCount, "skip", skipCount);

if failCount > 0
    report.overallStatus = "FAIL";
elseif skipCount > 0
    % 只要存在 SKIP，就不允许把整体标成 PASS：未验证 ≠ 通过。
    report.overallStatus = "SKIP";
elseif total > 0
    report.overallStatus = "PASS";
else
    report.overallStatus = "SKIP";
end

levels = ["L1", "L2", "L3", "L4", "L5"];
levelStatus = struct();
achieved = "L0";
blocked = false;
for idx = 1:numel(levels)
    level = levels(idx);
    if total == 0
        levelStatus.(level) = "SKIP";
        blocked = true;
        continue
    end
    mask = string({checks.level})' == level;
    if ~any(mask)
        levelStatus.(level) = "SKIP";
        blocked = true;
        continue
    end
    levelChecks = statuses(mask);
    if any(levelChecks == "FAIL")
        levelStatus.(level) = "FAIL";
        blocked = true;
    elseif any(levelChecks == "SKIP")
        levelStatus.(level) = "SKIP";
        blocked = true;
    else
        levelStatus.(level) = "PASS";
        if ~blocked
            achieved = level;
        end
    end
end
report.levelStatus = levelStatus;
report.achievedLevel = achieved;

directory = fileparts(path);
if strlength(directory) > 0 && ~isfolder(directory)
    mkdir(directory);
end

json = jsonencode(report, "PrettyPrint", true);
% 空值统一翻译成 null，保证与 PowerShell 侧的报告落在同一个 schema 下。
json = masacc.jsonNulls(json);
fid = fopen(path, "w");
if fid < 0
    error("masacc:writeFailed", "无法写入验收报告：%s", path);
end
cleanup = onCleanup(@() fclose(fid));
fprintf(fid, "%s", json);
clear cleanup
end
