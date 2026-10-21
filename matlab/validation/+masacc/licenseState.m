function info = licenseState(productName, options)
%LICENSESTATE 判定某个产品对应的 license feature 是否存在授权（不等于可执行）。
%
%   info = masacc.licenseState("MATLAB Coder")
%   info.exists  -> true / false / []（[] 表示无法判定）
%
%   三个刻意的设计决定：
%
%   1) 只用 feature 名去调 license('test')。
%      传产品显示名会得到 0（例如 "MATLAB Coder"），那是查错了键，不是没授权。
%
%   2) license('test', feature) 有 27 字符上限。
%      实测 R2026a：长度 >= 28 时抛 MATLAB:license:toomanychars，
%      例如 Satellite_Communications_Toolbox。这里不预判长度，直接捕获该异常并把
%      结论记为"无法判定"，避免把"测不了"说成"没授权"。
%
%   3) 猜出来的 feature 返回 0 时，不允许据此判"未授权"。
%      归一化猜测（空格换下划线）只能用来确认授权；返回 0 时记为未知。
%      同理，表内映射返回 0 但归一化名返回 1 时，说明表内映射可疑，也记为未知。

arguments
    productName (1,1) string
    options.LicenseFeature (1,1) string = ""   % 显式覆盖，用于测试与排障
end

info = struct( ...
    "exists", [], ...
    "feature", "", ...
    "featureSource", "unknown", ...
    "featureLength", 0, ...
    "tested", false, ...
    "error", "", ...
    "note", "");

if strlength(options.LicenseFeature) > 0
    info.feature = options.LicenseFeature;
    info.featureSource = "override";
else
    mapping = masacc.featureName(productName);
    info.feature = mapping.feature;
    info.featureSource = mapping.source;
    info.note = mapping.note;
end

if strlength(info.feature) == 0
    info.note = "未收录该产品的 license feature 名，无法判定授权状态";
    return
end

info.featureLength = strlength(info.feature);

try
    info.exists = logical(license("test", char(info.feature)));
    info.tested = true;
catch exception
    info.exists = [];
    if string(exception.identifier) == "MATLAB:license:toomanychars"
        info.note = sprintf( ...
            "feature 名 %s 长度 %d 超过 license('test') 的 27 字符上限，MATLAB 直接拒绝检测；" + ...
            "这不是未授权，而是无法用该 API 判定", info.feature, info.featureLength);
    else
        info.error = string(exception.message);
        info.note = "license('test') 调用失败，无法判定授权状态：" + info.error;
    end
    return
end

if info.exists
    return
end

% ---- 走到这里说明 exists == false，需要防止"查错键"造成的假阴性 ----
if info.featureSource == "normalized-guess"
    info.exists = [];
    info.note = sprintf( ...
        "按产品名归一化猜测 feature（%s）返回 false。猜测不能用来否定授权，" + ...
        "因此记作未知；如需确定请把该产品补进 masacc.featureName 的映射表", info.feature);
    return
end

if info.featureSource ~= "table"
    return
end

% 表内映射返回 false，但归一化名返回 true：多半是表内映射名字不对。
normalized = replace(strtrim(productName), " ", "_");
if normalized == info.feature || strlength(normalized) == 0
    return
end
normalizedExists = localSafeTest(normalized);
if isequal(normalizedExists, true)
    info.exists = [];
    info.note = sprintf( ...
        "表内映射 %s 返回 false，但产品名归一化 %s 返回 true，两者矛盾；" + ...
        "说明表内映射可能不正确，记作未知而不是未授权", info.feature, normalized);
end
end

function value = localSafeTest(feature)
%LOCALSAFETEST license('test') 的安全包装：任何异常都返回 []。
value = [];
try
    value = logical(license("test", char(feature)));
catch
    value = [];
end
end
