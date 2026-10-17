function items = inventory(options)
%INVENTORY 读取已安装产品清单，附 license feature 名与实际授权判定。
%
%   items = masacc.inventory();
%   items(idx).name           产品名（ver 的 Name）
%   items(idx).version        产品版本
%   items(idx).licenseFeature 实际用于检测的 license feature 名
%   items(idx).licensed       true / false / []（[] = 无法判定）
%
%   为什么 licensed 是三态而不是布尔：
%   license('test', feature) 有 27 字符上限，超长 feature 会直接抛
%   MATLAB:license:toomanychars；未收录映射的产品也只能给归一化猜测。
%   这两种情况都**不能**记 false —— 把"测不了"写成"没授权"正是上一轮的 bug。
%
%   逐产品调用 license('test') 只查询不签出，不消耗并发名额。

arguments
    % 批量清点时不逐个做执行探针：探针会真的调用产品，清点阶段不需要。
    options.Probe = false
end

persistent cached
if ~isempty(cached)
    items = cached;
    return
end

products = ver;
items = struct("name", {}, "version", {}, "licenseFeature", {}, "licensed", {}, "licenseSource", {});
for idx = 1:numel(products)
    name = string(products(idx).Name);
    state = masacc.licenseState(name);
    items(idx).name = name;
    items(idx).version = string(products(idx).Version);
    items(idx).licenseFeature = state.feature;
    items(idx).licensed = state.exists;
    items(idx).licenseSource = state.featureSource;
    if options.Probe
        % 只有显式要求时才补执行探针，且只补有探针的产品。
        probe = masacc.executionProbe(name);
        items(idx).licensed = localCombine(state.exists, probe.ok);
    end
end

cached = items;
end

function value = localCombine(licenseExists, executionOk)
%LOCALCOMBINE 授权与执行两个事实的与运算，空值不参与强制否定。
if isempty(licenseExists)
    value = [];
    return
end
if ~licenseExists
    value = false;
    return
end
if isequal(executionOk, false)
    value = false;
    return
end
value = true;
end
