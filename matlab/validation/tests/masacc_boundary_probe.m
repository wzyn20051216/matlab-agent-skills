%{
@file masacc_boundary_probe.m
@brief 验收协议的 MATLAB 侧边界探针：把各种"难看但合法/不合法"的报告写到磁盘，
       由 PowerShell 侧用同一份 schema 与语义规则校验，验证两端产出一致。

@details
  为什么要双端：
  PowerShell 侧用 hashtable 序列化，MATLAB 侧用 struct + jsonencode。两者对
  "单元素数组""空值""空集合"的编码规则完全不同：
    - MATLAB jsonencode 会把只有 1 个元素的结构体数组编码成对象而不是数组；
    - 空 double 编码成 []，空 string 编码成 ""，而 schema 要的是 null。
  只测一端，另一端就会在 CI 里以"schema 不合法"炸掉。

  本脚本不判断 pass/fail，只如实产出报告 + 一份 manifest（说明每个文件预期长什么样），
  由 tests/Acceptance.Boundary.Matlab.Tests.ps1 断言。
%}

scriptPath = mfilename("fullpath");
% 本文件在 matlab/validation/tests/ 下，所以要退 4 层才到仓库根。
repoRoot = fileparts(fileparts(fileparts(fileparts(scriptPath))));
addpath(fullfile(repoRoot, "matlab", "validation"));

evidenceRoot = getenv('MAS_TEST_EVIDENCE_ROOT');
if isempty(evidenceRoot), evidenceRoot = repoRoot; end
outDir = fullfile(evidenceRoot, "artifacts", "validation", "tests", "masacc_boundary");
if ~isfolder(outDir)
    mkdir(outDir);
end

manifest = struct("case", {}, "file", {}, "expectedCheckCount", {}, ...
    "expectedStatuses", {}, "expectsEmptyInventory", {}, "note", {});
addEntry = @(name, file, count, statuses, emptyInv, note) struct( ...
    "case", string(name), "file", string(file), "expectedCheckCount", count, ...
    "expectedStatuses", string(statuses), "expectsEmptyInventory", emptyInv, "note", string(note));

% ---------------- 1. 单条检查：checks 必须仍是数组 ----------------
report = masacc.new("boundary-single", "matlab-batch");
report = masacc.addCheck(report, "single.only", "唯一的检查项", "L1", "PASS", ...
    Command="noop", Metrics=struct("value", 1), ExitCode=0, DurationSeconds=0.5);
path = fullfile(outDir, "single_check.json");
masacc.write(report, path);
manifest(end + 1) = addEntry("single-check", path, 1, "PASS", false, ...
    "单元素 checks 必须编码成数组，不能退化成对象");

% ---------------- 2. 多条检查：PASS / FAIL / SKIP 混合 ----------------
report = masacc.new("boundary-multi", "matlab-batch");
report = masacc.addCheck(report, "multi.pass", "通过项", "L1", "PASS");
report = masacc.addCheck(report, "multi.fail", "失败项", "L2", "FAIL", ...
    Reason="故意失败，用于验证 FAIL 的 reason 必填", ErrorClass="VALIDATION_ERROR", ExitCode=1);
report = masacc.addCheck(report, "multi.skip", "跳过项", "L3", "SKIP", ...
    Reason="故意跳过，用于验证 SKIP 不计入 PASS", ErrorClass="ENVIRONMENT_ERROR");
path = fullfile(outDir, "multi_check.json");
masacc.write(report, path);
manifest(end + 1) = addEntry("multi-check", path, 3, ["PASS", "FAIL", "SKIP"], false, ...
    "三种状态共存时整体必须是 FAIL，且 SKIP 不得被算作 PASS");

% ---------------- 3. 全部可空字段留空 ----------------
report = masacc.new("boundary-nulls", "matlab-batch");
report = masacc.addCheck(report, "nulls.only", "可空字段留空", "L1", "PASS");
path = fullfile(outDir, "null_fields.json");
masacc.write(report, path);
manifest(end + 1) = addEntry("null-fields", path, 1, "PASS", false, ...
    "command/startedAt/finishedAt/errorClass/reason/exitCode/durationSeconds 必须写成 null");

% ---------------- 4. 中文原因与产物路径 ----------------
report = masacc.new("boundary-unicode", "matlab-batch");
report = masacc.addCheck(report, "unicode.skip", "中文原因与空产物", "L1", "SKIP", ...
    Reason="缺少许可证：feature 名超过 27 字符上限，无法用 license('test') 判定（中文原因必须可读）", ...
    ErrorClass="LICENSE_ERROR", ArtifactPaths=strings(0, 1));
path = fullfile(outDir, "unicode_reason.json");
masacc.write(report, path);
manifest(end + 1) = addEntry("unicode-reason", path, 1, "SKIP", false, ...
    "UTF-8 中文原因往返后不得变成乱码；空 artifactPaths 必须是数组");

% ---------------- 5. 空工具箱清单 ----------------
report = masacc.new("boundary-empty-inventory", "matlab-batch");
report.toolboxInventory = struct("name", {}, "version", {}, "licenseFeature", {}, "licensed", {});
report = masacc.addCheck(report, "empty.inventory", "空清单", "L1", "PASS");
path = fullfile(outDir, "empty_inventory.json");
masacc.write(report, path);
manifest(end + 1) = addEntry("empty-inventory", path, 1, "PASS", true, ...
    "空工具箱清单必须是 [] 而不是 null，否则违反 type: array");

% ---------------- 6. 许可证缺失（真实走 availability 的失败分支） ----------------
faultLicense = masacc.availability("MATLAB Coder", LicenseFeature="__no_such_feature__");
report = masacc.new("boundary-fault-license", "matlab-batch");
if faultLicense.available
    report = masacc.addCheck(report, "fault.license", "许可证缺失", "L1", "PASS", ...
        Reason="", Metrics=faultLicense);
else
    report = masacc.addCheck(report, "fault.license", "许可证缺失时必须 SKIP 并说明原因", "L1", "SKIP", ...
        Reason=faultLicense.reason, ErrorClass="LICENSE_ERROR", Metrics=faultLicense);
end
path = fullfile(outDir, "fault_license_missing.json");
masacc.write(report, path);
manifest(end + 1) = addEntry("fault-license", path, 1, "SKIP", false, ...
    "用不存在的 feature 名触发真实的未授权分支，reason 必须非空");

% ---------------- 7. 许可证无法判定（feature 名超长） ----------------
% 40 个字符的单个 feature 名：char 行向量转 string 才是 1x1，
% 直接 repmat("x",1,40) 会得到 1x40 的字符串数组，参数校验会拒绝。
longFeature = string(repmat('x', 1, 40));
unknownLicense = masacc.availability("MATLAB Coder", LicenseFeature=longFeature);
report = masacc.new("boundary-fault-unknown", "matlab-batch");
report = masacc.addCheck(report, "fault.unknown", "授权无法判定时必须 SKIP 而不是 FAIL", "L1", "SKIP", ...
    Reason=unknownLicense.reason, ErrorClass="LICENSE_ERROR", Metrics=unknownLicense);
path = fullfile(outDir, "fault_license_unknown.json");
masacc.write(report, path);
manifest(end + 1) = addEntry("fault-license-unknown", path, 1, "SKIP", false, ...
    "feature 名超过 27 字符时 MATLAB 抛 toomanychars，必须记未知而不是未授权");

% ---------------- 8. 运行异常 -> 错误分类 ----------------
report = masacc.new("boundary-fault-runtime", "matlab-batch");
try
    error("masacc:testFault", "故意抛出的运行时异常，用于验证错误分类");
catch ME
    report = masacc.addCheck(report, "fault.runtime", "运行异常必须被分类并保留信息", "L1", "FAIL", ...
        Reason=string(ME.message), ErrorClass=masacc.classifyError(ME), ExitCode=1, ...
        Metrics=struct("identifier", string(ME.identifier)));
end
path = fullfile(outDir, "fault_runtime.json");
masacc.write(report, path);
manifest(end + 1) = addEntry("fault-runtime", path, 1, "FAIL", false, ...
    "异常必须落到 8 类 errorClass 之一，并保留原始 message");

% ---------------- 9. 空报告必须被拒绝 ----------------
emptyReport = masacc.new("boundary-empty-report", "matlab-batch");
emptyPath = fullfile(outDir, "empty_report_rejected.json");
rejected = false;
detail = "";
try
    masacc.write(emptyReport, emptyPath);
    rejected = false;
    detail = "写盘没有报错，但空报告不应该被接受";
catch ME
    rejected = string(ME.identifier) == "masacc:emptyReport";
    detail = string(ME.message);
end
report = masacc.new("boundary-empty-report-guard", "matlab-batch");
if rejected
    report = masacc.addCheck(report, "guard.empty-report", "空报告被拒绝", "L1", "PASS", ...
        Metrics=struct("identifier", "masacc:emptyReport"));
else
    report = masacc.addCheck(report, "guard.empty-report", "空报告被拒绝", "L1", "FAIL", ...
        Reason=detail, ErrorClass="VALIDATION_ERROR");
end
path = fullfile(outDir, "guard_empty_report.json");
masacc.write(report, path);
manifest(end + 1) = addEntry("guard-empty-report", path, 1, "PASS", false, ...
    "不允许写出零检查项的报告：空报告无法证明任何事");

% ---------------- manifest ----------------
manifestPath = fullfile(outDir, "manifest.json");
fid = fopen(manifestPath, "w");
cleanup = onCleanup(@() fclose(fid));
fprintf(fid, "%s", jsonencode(manifest, "PrettyPrint", true));
clear cleanup

fprintf("BOUNDARY_DIR=%s\n", outDir);
fprintf("BOUNDARY_MANIFEST=%s\n", manifestPath);
fprintf("BOUNDARY_CASE_COUNT=%d\n", numel(manifest));
