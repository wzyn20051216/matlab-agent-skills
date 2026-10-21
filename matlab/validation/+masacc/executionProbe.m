function info = executionProbe(productName)
%EXECUTIONPROBE 对产品做一次轻量但真实的调用，证明"能执行"而不只是"有许可证"。
%
%   info = masacc.executionProbe("MATLAB Coder")
%   info.ok     -> true / false / []（[] 表示没有合适的探针，未探测）
%   info.probe  -> 探针名，"none" 表示未探测
%
%   设计约束：
%   - 必须便宜：这个函数会在验收脚本开头被调用，不能启动编译或仿真；
%   - 必须无副作用：不写文件、不改模型、不签出额外许可证；
%   - 不猜：没有合适探针就如实返回 []，让调用方知道"执行可用性未验证"，
%     而不是用 isfile / exist 这种"文件存在"的弱证据冒充执行。
%
%   只有真正会失败在许可证上的调用才算有效探针：
%   coder.typeof / coder.config / new_system 在缺少对应授权时会直接报许可证错误。

arguments
    productName (1,1) string
end

info = struct("probe", "none", "ok", [], "detail", struct(), "error", "");

switch productName
    case "MATLAB Coder"
        info.probe = "coder.typeof+coder.config";
        try
            typeInfo = coder.typeof(0);
            cfg = coder.config("lib");
            info.detail = struct( ...
                "typeofClass", string(class(typeInfo)), ...
                "configClass", string(class(cfg)), ...
                "targetLang", string(cfg.TargetLang));
            info.ok = true;
        catch exception
            info.ok = false;
            info.error = string(exception.message);
            info.detail = struct("identifier", string(exception.identifier));
        end

    case "Embedded Coder"
        info.probe = "coder.config(ecoder)";
        try
            cfg = coder.config("lib", "ecoder", true);
            info.detail = struct( ...
                "isERTTarget", logical(cfg.IsERTTarget), ...
                "targetLang", string(cfg.TargetLang));
            info.ok = logical(cfg.IsERTTarget);
            if ~info.ok
                info.error = "coder.config('lib','ecoder',true) 未返回 ERT 目标配置";
            end
        catch exception
            info.ok = false;
            info.error = string(exception.message);
            info.detail = struct("identifier", string(exception.identifier));
        end

    case "Simulink"
        info.probe = "new_system/close_system";
        % 模型名必须是合法标识符，且不能与用户已有模型撞名。
        probeName = "masacc_probe_" + string(mod(round(posixtime(datetime("now")) * 1000), 1000000000));
        try
            new_system(probeName);
            info.detail = struct("modelName", probeName, "blockDiagramType", ...
                string(get_param(probeName, "BlockDiagramType")));
            info.ok = true;
        catch exception
            info.ok = false;
            info.error = string(exception.message);
            info.detail = struct("identifier", string(exception.identifier));
        end
        % 无论成功失败都要清掉临时模型，避免污染工作区。
        try
            if bdIsLoaded(probeName)
                close_system(probeName, 0);
            end
        catch
        end

    otherwise
        % 没有便宜、真实、无副作用的探针，就明确说"未探测"。
        info.probe = "none";
        info.ok = [];
end
end
