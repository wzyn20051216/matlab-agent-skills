function info = availability(productName, options)
%AVAILABILITY 汇总"是否安装 / 是否授权 / 能否真实执行"三项互相独立的事实。
%
%   info = masacc.availability("MATLAB Coder");
%
%   info.installed       产品是否出现在 ver 列表里
%   info.licenseFeature  实际用于检测的 license feature 名
%   info.licenseExists   license('test', feature)：true / false / []（无法判定）
%   info.executionProven 轻量真实调用是否成功：true / false / []（无探针，未探测）
%   info.available       只有"已安装 + 确有授权 + 执行探针未失败"才为 true
%   info.provenBy        "license+execution" / "license-only" / "none"
%   info.reason          不可用时为什么不可用（可直接写进验收报告的 reason）
%
%   为什么必须拆开：
%   旧实现用 license('test', 产品显示名) 判断"是否授权"，对 MATLAB Coder /
%   Simulink Coder / Embedded Coder 一律返回 0，于是这些产品被误判成"无许可证"，
%   整条 Coder 验收全部 SKIP。真机实测（R2026a）：MATLAB_Coder / Real-Time_Workshop /
%   RTW_Embedded_Coder 均返回 1。产品名与 feature 名是两套命名，不能混用。
%
%   另外，"有许可证" 也不等于 "能执行"：许可证可能被并发占满，安装也可能损坏。
%   所以这里额外做一次真实调用探针；没有合适探针时记为 []（未探测），不冒充已验证。

arguments
    productName (1,1) string
    % 显式指定 feature 名：测试与排障用，正常调用留空。
    options.LicenseFeature (1,1) string = ""
    % 跳过执行探针：只关心授权、不想付探针代价时用（例如批量清点）。
    options.SkipExecutionProbe (1,1) logical = false
end

info = struct( ...
    "installed", false, ...
    "licenseFeature", "", ...
    "licenseFeatureSource", "unknown", ...
    "licenseExists", [], ...
    "executionProven", [], ...
    "probe", "none", ...
    "available", false, ...
    "provenBy", "none", ...
    "reason", "", ...
    "licenseNote", "", ...
    "probeError", "");

% ---------------- 1. 安装层事实 ----------------
info.installed = masacc.hasProduct(productName);

% ---------------- 2. 授权层事实 ----------------
licenseInfo = masacc.licenseState(productName, LicenseFeature=options.LicenseFeature);
info.licenseFeature = licenseInfo.feature;
info.licenseFeatureSource = licenseInfo.featureSource;
info.licenseExists = licenseInfo.exists;
info.licenseNote = licenseInfo.note;
if strlength(licenseInfo.error) > 0
    info.licenseNote = licenseInfo.error;
end

% ---------------- 3. 执行层事实 ----------------
if options.SkipExecutionProbe
    info.probe = "skipped";
    info.executionProven = [];
else
    probe = masacc.executionProbe(productName);
    info.probe = probe.probe;
    info.executionProven = probe.ok;
    info.probeError = probe.error;
end

% ---------------- 4. 结论 ----------------
if ~info.installed
    info.reason = "未安装 " + productName + "（ver 列表中没有该产品）";
    return
end

if isempty(info.licenseExists)
    info.reason = sprintf( ...
        "%s 已安装，但授权状态无法判定：feature=%s；%s", ...
        productName, localDisplayFeature(info.licenseFeature), info.licenseNote);
    return
end

if ~info.licenseExists
    info.reason = sprintf( ...
        "%s 已安装但未授权：license('test','%s') 返回 false", ...
        productName, localDisplayFeature(info.licenseFeature));
    return
end

if isequal(info.executionProven, false)
    info.reason = sprintf( ...
        "%s 已安装且有授权，但执行探针 %s 失败：%s；有许可证不等于能执行", ...
        productName, info.probe, info.probeError);
    return
end

info.available = true;
if isequal(info.executionProven, true)
    info.provenBy = "license+execution";
else
    % 没有探针的产品只能证明到授权层，调用方若需要硬证据应自行执行真实命令。
    info.provenBy = "license-only";
end
end

function text = localDisplayFeature(feature)
%LOCALDISPLAYFEATURE 报告里展示 feature 名，空值给出可读占位。
if strlength(feature) == 0
    text = "（未收录）";
else
    text = feature;
end
end
