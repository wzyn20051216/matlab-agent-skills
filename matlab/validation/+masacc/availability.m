function info = availability(productName)
%AVAILABILITY 汇总“是否安装 / 是否授权 / 可否执行”三项事实。
%
% 返回 struct：installed / licensed / available / reason。
% 只有 available 为 true 时才允许把相关检查判为 PASS；
% 否则调用方必须输出 SKIP 并把 reason 写进报告。

info = struct("installed", false, "licensed", false, "available", false, "reason", "");

info.installed = masacc.hasProduct(productName);
if ~info.installed
    info.reason = "未安装 " + string(productName);
    return
end

try
    info.licensed = logical(license("test", char(productName)));
catch exception
    info.licensed = false;
    info.reason = "license('test') 调用失败：" + string(exception.message);
    return
end

if ~info.licensed
    info.reason = string(productName) + " 已安装但未授权（license('test') 返回 false）";
    return
end

info.available = true;
end
