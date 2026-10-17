function items = inventory()
%INVENTORY 读取已安装产品清单，附带 license('test') 结果。
%
% 返回 struct 数组：name / version / licensed。
% licensed 只表示该产品能否 checkout，不表示功能已经验证。

persistent cached
if ~isempty(cached)
    items = cached;
    return
end

products = ver;
items = struct("name", {}, "version", {}, "licensed", {});
for idx = 1:numel(products)
    name = string(products(idx).Name);
    licensed = [];
    try
        licensed = logical(license("test", char(name)));
    catch
        licensed = [];
    end
    items(idx).name = name;
    items(idx).version = string(products(idx).Version);
    items(idx).licensed = licensed;
end

cached = items;
end
