function classification = classifyError(exception)
%CLASSIFYERROR 把 MATLAB 异常映射到统一的错误类别。
%
% 类别与 PowerShell 侧 Get-MatlabErrorClassification 保持一致：
% ENVIRONMENT_ERROR / LICENSE_ERROR / MCP_CONNECTION_ERROR / MATLAB_RUNTIME_ERROR /
% SIMULATION_ERROR / CODEGEN_ERROR / VALIDATION_ERROR / TIMEOUT

text = string(exception.message) + " " + string(exception.identifier);
classification = "MATLAB_RUNTIME_ERROR";

patterns = {
    "LICENSE_ERROR", ["license", "licens", "checkout"]
    "ENVIRONMENT_ERROR", ["未安装", "not installed", "No supported compiler", "Undefined function", "Unrecognized function"]
    "SIMULATION_ERROR", ["Simulink.SimulationError", "SimulationInput", "Derivative of state", "Cannot simulate"]
    "CODEGEN_ERROR", ["codegen", "Coder", "slbuild", "rtw", "Build"]
    "VALIDATION_ERROR", ["Assertion failed", "assert", "tolerance", "deviat", "验收"]
};

lowered = lower(text);
for idx = 1:size(patterns, 1)
    candidates = lower(string(patterns{idx, 2}));
    if any(contains(lowered, candidates))
        classification = string(patterns{idx, 1});
        return
    end
end
end
