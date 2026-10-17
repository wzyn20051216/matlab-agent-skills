function tf = hasProduct(name)
%HASPRODUCT 判断某个产品是否出现在 ver 列表中（安装层事实，不代表已授权）。
products = masacc.inventory();
tf = any(strcmp(string({products.name}), string(name)));
end
