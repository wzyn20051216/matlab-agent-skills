#Requires -Version 5.1
<#
.SYNOPSIS
    Agent Benchmark 最小原型：三个真实 MATLAB 任务的端到端跑分。

.DESCRIPTION
链路（全部真实，无 Fake）：
    自然语言 Prompt
      -> 规则路由到 Skill（记录命中理由）
        -> Agent 循环：选 MCP 工具 -> 官方 matlab-mcp-server -> MATLAB R2026a
          -> 产物落盘 -> 数值验收 -> Benchmark 报告

三个任务：
    BM1  数值分析脚本生成（最小二乘拟合 + 图像 + 统计数据）
    BM2  Simulink 阶跃响应建模（传递函数 + 仿真数值 vs 解析解）
    BM3  PID 调参对比（同一对象、两组参数、响应指标对比）

诚实边界（写进报告，不允许含糊）：
    - 规划层是**规则路由 + 固定步骤序列**，不是 LLM 自主规划。
      它证明的是：给定一条自然语言 Prompt，Agent 侧能正确选 Skill、选工具、
      填对参数、把结果验回来；它**不**证明 LLM 的自主推理能力。
    - 执行层完全真实：每一次 evaluate_matlab_code / run_matlab_file /
      check_matlab_code 都经官方 server 打到真实 MATLAB，返回数值原样入报告。
    - 无预置结果脚本冒充 Agent 产物：
        BM1 的 .m 由 Agent 侧生成 -> check_matlab_code 静态检查 -> run_matlab_file 真实执行；
        BM2/BM3 的模型由 evaluate_matlab_code 现场 new_system/add_block 搭建。
    - 预期值由**独立解析推导**得出，不用 MATLAB 输出反推。

用法：
    powershell -ExecutionPolicy Bypass -File .\scripts\Invoke-MatlabAgentBenchmark.ps1
#>
[CmdletBinding()]
param(
    [string]$ServerExe = "",
    [ValidateSet("auto", "existing", "new")]
    [string]$SessionMode = "auto",
    [string]$OutputPath = "",
    [string]$TaskId = "",
    [int]$TimeoutSeconds = 300,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$stdioModule = Join-Path $PSScriptRoot "MatlabAgentSkills.McpStdio.psm1"
Import-Module -Name $stdioModule -Force -DisableNameChecking

# 本地回环代理旁路：Go server 未设 NO_PROXY 时会把 localhost 也发给代理
$null = Enable-McpLocalhostProxyBypass

$benchDir = Join-Path $repoRoot "artifacts\validation\benchmark"
if (-not (Test-Path -LiteralPath $benchDir)) {
    New-Item -ItemType Directory -Force -Path $benchDir | Out-Null
}
if (-not $TaskId) { $TaskId = "agent-bench-" + (Get-Date -Format "yyyyMMdd-HHmmss") }
if (-not $OutputPath) { $OutputPath = Join-Path $benchDir ("benchmark_report_" + (Get-Date -Format "HHmmss") + ".json") }

# ==================== Skill 路由（规则层） ====================
$script:SkillRoutes = @(
    [pscustomobject]@{
        Skill     = "matlab-data-analysis"
        Reason    = "命中数据分析关键词（拟合/残差/统计/图像）"
        MatchAny  = @("拟合", "残差", "统计", "图像", "数据分析")
        ForbidAny = @("simulink", "pid", "调参", "阶跃响应")
    },
    [pscustomobject]@{
        Skill     = "matlab-control-optimization"
        Reason    = "命中控制关键词（PID/调参/阶跃响应/控制器）"
        MatchAny  = @("pid", "调参", "阶跃响应", "控制器", "控制")
        ForbidAny = @()
    },
    [pscustomobject]@{
        Skill     = "matlab-simulink-modeling"
        Reason    = "命中建模关键词（simulink/建模/仿真）"
        MatchAny  = @("simulink", "建模", "仿真")
        ForbidAny = @()
    }
)

function Resolve-BenchmarkSkill {
    param([string]$Prompt)
    $p = $Prompt.ToLowerInvariant()
    foreach ($route in $script:SkillRoutes) {
        $matched = @($route.MatchAny | Where-Object { $p.Contains($_.ToLowerInvariant()) })
        if ($matched.Count -eq 0) { continue }
        $forbidden = @($route.ForbidAny | Where-Object { $p.Contains($_.ToLowerInvariant()) })
        if ($forbidden.Count -gt 0) { continue }
        return [pscustomobject]@{
            Skill        = $route.Skill
            RouteReason  = $route.Reason
            MatchedTerms = $matched
        }
    }
    return [pscustomobject]@{ Skill = "(none)"; RouteReason = "无路由命中"; MatchedTerms = @() }
}

# ==================== MCP 调用封装（逐次记录真实调用） ====================
$script:ToolCallLog = New-Object System.Collections.ArrayList

function Invoke-BenchmarkTool {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Benchmark,
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][hashtable]$Arguments,
        [Parameter(Mandatory)][string]$Purpose,
        [int]$Timeout = $TimeoutSeconds
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = Send-McpStdioRequest -Session $Session -Method "tools/call" -TimeoutSeconds $Timeout -Params @{
        name      = $Tool
        arguments = $Arguments
    }
    $sw.Stop()

    $text = ""
    $isError = $false
    if ($resp.Result) {
        $isError = [bool]($resp.Result.PSObject.Properties.Name -contains "isError" -and $resp.Result.isError)
        $text = Get-McpStdioToolText -ResultNode $resp.Result
    }

    $record = [pscustomobject][ordered]@{
        benchmark    = $Benchmark
        tool         = $Tool
        purpose      = $Purpose
        ok           = [bool]($resp.Ok -and -not $isError)
        isError      = $isError
        timedOut     = [bool]$resp.TimedOut
        durationMs   = $sw.ElapsedMilliseconds
        requestId    = $resp.Id
        skippedLines = $resp.SkippedLines
        error        = $resp.Error
        arguments    = ($Arguments | ConvertTo-Json -Depth 12 -Compress)
        outputChars  = if ($text) { $text.Length } else { 0 }
        output       = $text
    }
    [void]$script:ToolCallLog.Add($record)
    if (-not $Quiet) {
        $color = if ($record.ok) { "Gray" } else { "Red" }
        Write-Host ("    {0,-22} {1,7} ms  ok={2}  ({3})" -f $Tool, $record.durationMs, $record.ok, $Purpose) -ForegroundColor $color
    }
    return $record
}

function Get-NumberFromOutput {
    param([string]$Text, [string]$Key)
    if ($Text -match ("(?m)^" + [regex]::Escape($Key) + "=([-0-9.eE+]+)")) { return [double]$Matches[1] }
    return $null
}

# ==================== 启动 MCP Server ====================
if (-not $ServerExe) {
    $candidate = Join-Path $repoRoot "bin\matlab-mcp-server-windows-x64.exe"
    if (Test-Path -LiteralPath $candidate) { $ServerExe = $candidate }
}
if (-not $ServerExe -or -not (Test-Path -LiteralPath $ServerExe)) {
    throw "未找到 MCP server 可执行文件：$ServerExe"
}

$serverArgs = "--matlab-session-mode=$SessionMode --disable-telemetry=true"
$session = Start-McpStdioServer -ServerExe $ServerExe -ServerArgumentLine $serverArgs -Label "agent-benchmark" -WorkingDirectory $benchDir
$serverStartOk = -not $session.Process.HasExited
$serverStartReason = if ($serverStartOk) { $null } else { "MCP server 启动后立即退出" }

$benchmarks = New-Object System.Collections.ArrayList

try {
    $init = Send-McpStdioRequest -Session $session -Method "initialize" -TimeoutSeconds 60 -Params @{
        protocolVersion = "2025-06-18"
        capabilities    = [ordered]@{}
        clientInfo      = [ordered]@{ name = "matlab-agent-benchmark"; version = "1.0.0" }
    }
    $handshakeOk = [bool]($init.Ok -and $init.Result)
    $null = Send-McpStdioRequest -Session $session -Method "notifications/initialized" -Notification
    $toolsList = Send-McpStdioRequest -Session $session -Method "tools/list" -TimeoutSeconds 60
    $toolNames = @()
    if ($toolsList.Result -and $toolsList.Result.tools) {
        $toolNames = @($toolsList.Result.tools | ForEach-Object { "$($_.name)" })
    }
    if (-not $Quiet) {
        Write-Host "==> 握手 ok=$handshakeOk；发现 $($toolNames.Count) 个工具：$($toolNames -join ', ')" -ForegroundColor Cyan
    }
    if (-not $handshakeOk -or $toolNames.Count -eq 0) {
        throw "MCP 握手或工具发现失败：$($init.Error)"
    }

    # ====================================================================
    # BM1：数值分析脚本生成
    # ====================================================================
    $bm1Dir = Join-Path $benchDir "bm1_numeric_analysis"
    if (-not (Test-Path -LiteralPath $bm1Dir)) { New-Item -ItemType Directory -Force -Path $bm1Dir | Out-Null }
    $bm1Prompt = "生成一个 MATLAB 数值分析脚本：构造带高斯噪声的正弦信号 y = 3*sin(2*pi*1.5*t) + 0.4，" +
                 "用最小二乘拟合出幅度、频率、相位和直流偏置，输出拟合参数与残差 RMS，" +
                 "并把图像和数据文件保存到磁盘。"
    $bm1Route = Resolve-BenchmarkSkill -Prompt $bm1Prompt
    if (-not $Quiet) { Write-Host "==> BM1 数值分析脚本生成  [skill: $($bm1Route.Skill)]" -ForegroundColor Cyan }

    $bm1Script = @'
function analyze_noisy_sine()
% 带噪正弦信号的最小二乘拟合 + 图像/数据落盘
% 真值：幅度 3，频率 1.5 Hz，相位 pi/2，直流偏置 0.4
rng(20261017, 'twister');

fs = 200;
T  = 4;
t  = (0:1/fs:T)';
truth = [3.0, 1.5, pi/2, 0.4];
noiseSigma = 0.05;
y = truth(1)*sin(2*pi*truth(2)*t + truth(3)) + truth(4) + noiseSigma*randn(size(t));

fGrid = linspace(0.1, 5, 4000);
bestErr = inf; bestF = NaN;
for f = fGrid
    % 注意：这里是**纵向**拼接三根等长列向量，得到 801x3 设计矩阵。
    % 早期写法用了 [sin(...)' cos(...)' ones(...)']，横向拼接成 1x2403，
    % 于是 A\y 解的是欠定方程，返回 2403x801 的最小范数解，
    % c(1:3) 取到的是垃圾值，表现为所有拟合参数输出 0。
    A = [sin(2*pi*f*t), cos(2*pi*f*t), ones(size(t))];
    c = A \ y;
    r = y - A*c;
    e = r' * r;
    if e < bestErr
        bestErr = e; bestF = f;
    end
end
A = [sin(2*pi*bestF*t), cos(2*pi*bestF*t), ones(size(t))];
c = A \ y;
amplitude = hypot(c(1), c(2));
phase = atan2(c(2), c(1));
offset = c(3);
residual = y - A*c;
rms = sqrt(mean(residual.^2));

fprintf('FIT_AMPLITUDE=%.6f\n', amplitude);
fprintf('FIT_FREQUENCY=%.6f\n', bestF);
fprintf('FIT_PHASE=%.6f\n', phase);
fprintf('FIT_OFFSET=%.6f\n', offset);
fprintf('FIT_RMS=%.6f\n', rms);
fprintf('SAMPLES=%d\n', numel(t));

outDir = fileparts(mfilename('fullpath'));
csvPath = fullfile(outDir, 'fit_data.csv');
% t / y / residual 已经是等长列向量，直接建三列表。
% 早期写成 table(t', y', residual)，t' 变成 1x801 行向量，
% writetable 把它展开成 801 个变量，CSV 表头变成 t_1,t_2,... 完全不可用。
writetable(table(t, y, residual, 'VariableNames', {'t','y','residual'}), csvPath);

figPath = fullfile(outDir, 'fit_figure.png');
fh = figure('Visible', 'off');
plot(t, y, '.', 'DisplayName', 'noisy samples'); hold on;
plot(t, amplitude*sin(2*pi*bestF*t + phase) + offset, 'r-', 'LineWidth', 1.5, 'DisplayName', 'LS fit');
xlabel('t (s)'); ylabel('y'); legend('show'); grid on;
title(sprintf('LS fit: A=%.3f f=%.3f phi=%.3f b=%.3f', amplitude, bestF, phase, offset));
saveas(fh, figPath);
close(fh);

jsonPath = fullfile(outDir, 'fit_summary.json');
s = struct('amplitude', amplitude, 'frequency', bestF, 'phase', phase, ...
           'offset', offset, 'residualRms', rms, 'samples', numel(t), ...
           'truthAmplitude', truth(1), 'truthFrequency', truth(2), ...
           'truthPhase', truth(3), 'truthOffset', truth(4));
fid = fopen(jsonPath, 'w'); fwrite(fid, jsonencode(s)); fclose(fid);

fprintf('WROTE_CSV=%s\n', csvPath);
fprintf('WROTE_PNG=%s\n', figPath);
fprintf('WROTE_JSON=%s\n', jsonPath);
end
'@
    $bm1ScriptPath = Join-Path $bm1Dir "analyze_noisy_sine.m"
    [System.IO.File]::WriteAllText($bm1ScriptPath, $bm1Script, (New-Object System.Text.UTF8Encoding($false)))

    # 注意：官方 schema 的参数名是 script_path（不是 file_path），
    # 且 additionalProperties=false，传错名字会直接 -32602 invalid params。
    $bm1Check = Invoke-BenchmarkTool -Session $session -Benchmark "BM1" -Tool "check_matlab_code" -Purpose "对 Agent 生成的脚本做静态检查" -Arguments @{ script_path = $bm1ScriptPath }
    $bm1Run = Invoke-BenchmarkTool -Session $session -Benchmark "BM1" -Tool "run_matlab_file" -Purpose "在真实 MATLAB 中执行拟合脚本" -Arguments @{ script_path = $bm1ScriptPath }

    $bm1Out = "$($bm1Run.output)"
    $bm1Csv = Join-Path $bm1Dir "fit_data.csv"
    $bm1Png = Join-Path $bm1Dir "fit_figure.png"
    $bm1Json = Join-Path $bm1Dir "fit_summary.json"
    $bm1Amp = Get-NumberFromOutput -Text $bm1Out -Key "FIT_AMPLITUDE"
    $bm1Freq = Get-NumberFromOutput -Text $bm1Out -Key "FIT_FREQUENCY"
    $bm1Phase = Get-NumberFromOutput -Text $bm1Out -Key "FIT_PHASE"
    $bm1Offset = Get-NumberFromOutput -Text $bm1Out -Key "FIT_OFFSET"
    $bm1Rms = Get-NumberFromOutput -Text $bm1Out -Key "FIT_RMS"

    $bm1Checks = @(
        @{ name = "脚本静态检查通过"; pass = [bool]$bm1Check.ok }
        @{ name = "拟合幅度 ≈ 3.0（容差 0.15）"; pass = ($null -ne $bm1Amp -and [math]::Abs($bm1Amp - 3.0) -le 0.15) }
        @{ name = "拟合频率 ≈ 1.5 Hz（容差 0.02）"; pass = ($null -ne $bm1Freq -and [math]::Abs($bm1Freq - 1.5) -le 0.02) }
        @{ name = "拟合相位 ≈ pi/2（容差 0.15）"; pass = ($null -ne $bm1Phase -and [math]::Abs($bm1Phase - [math]::PI / 2) -le 0.15) }
        @{ name = "直流偏置 ≈ 0.4（容差 0.05）"; pass = ($null -ne $bm1Offset -and [math]::Abs($bm1Offset - 0.4) -le 0.05) }
        @{ name = "残差 RMS 与噪声水平同量级（0.02~0.12）"; pass = ($null -ne $bm1Rms -and $bm1Rms -ge 0.02 -and $bm1Rms -le 0.12) }
        @{ name = "CSV 数据文件真实落盘且非空"; pass = ((Test-Path -LiteralPath $bm1Csv) -and (Get-Item -LiteralPath $bm1Csv).Length -gt 100) }
        @{ name = "PNG 图像真实落盘且非空"; pass = ((Test-Path -LiteralPath $bm1Png) -and (Get-Item -LiteralPath $bm1Png).Length -gt 1000) }
        @{ name = "JSON 统计摘要真实落盘"; pass = ((Test-Path -LiteralPath $bm1Json) -and (Get-Item -LiteralPath $bm1Json).Length -gt 50) }
    )
    $bm1Pass = @($bm1Checks | Where-Object { $_.pass }).Count
    $bm1Status = if ($bm1Pass -eq $bm1Checks.Count) { "PASS" } elseif ($bm1Pass -gt 0) { "PARTIAL" } else { "FAIL" }
    [void]$benchmarks.Add([pscustomobject][ordered]@{
        id            = "BM1"
        title         = "数值分析脚本生成"
        rawPrompt     = $bm1Prompt
        routedSkill   = $bm1Route.Skill
        routeReason   = $bm1Route.RouteReason
        matchedTerms  = $bm1Route.MatchedTerms
        status        = $bm1Status
        checksPassed  = $bm1Pass
        checksTotal   = $bm1Checks.Count
        checks        = @($bm1Checks | ForEach-Object { [pscustomobject]@{ name = $_.name; pass = $_.pass } })
        workDir       = $bm1Dir
        artifacts     = @($bm1ScriptPath, $bm1Csv, $bm1Png, $bm1Json)
        metrics       = [pscustomobject]@{
            fittedAmplitude = $bm1Amp; fittedFrequency = $bm1Freq; fittedPhase = $bm1Phase
            fittedOffset    = $bm1Offset; residualRms = $bm1Rms
            truthAmplitude  = 3.0; truthFrequency = 1.5; truthPhase = [math]::PI / 2; truthOffset = 0.4
        }
    })

    # ====================================================================
    # BM2：Simulink 阶跃响应建模
    # ====================================================================
    $bm2Dir = Join-Path $benchDir "bm2_simulink_step"
    if (-not (Test-Path -LiteralPath $bm2Dir)) { New-Item -ItemType Directory -Force -Path $bm2Dir | Out-Null }
    $bm2Prompt = "创建一个 Simulink 模型：单位阶跃输入经过传递函数 1/(s^2+2s+5)，" +
                 "记录 5 秒仿真输出，报告输出终值、峰值和峰值时刻。"
    $bm2Route = Resolve-BenchmarkSkill -Prompt $bm2Prompt
    if (-not $Quiet) { Write-Host "==> BM2 Simulink 阶跃响应建模  [skill: $($bm2Route.Skill)]" -ForegroundColor Cyan }

    # 解析真值（独立推导）：wn^2=5, 2*zeta*wn=2
    $bm2Wn = [math]::Sqrt(5.0)
    $bm2Zeta = 1.0 / [math]::Sqrt(5.0)
    $bm2Steady = 1.0 / 5.0
    $bm2Peak = $bm2Steady * (1.0 + [math]::Exp(-$bm2Zeta * [math]::PI / [math]::Sqrt(1 - $bm2Zeta * $bm2Zeta)))
    $bm2PeakTime = [math]::PI / ($bm2Wn * [math]::Sqrt(1 - $bm2Zeta * $bm2Zeta))

    $bm2Model = Join-Path $bm2Dir "bm2_step_response.slx"
    $bm2ModelM = $bm2Model -replace '\\', '/'
    $bm2Code = @"
mdl = 'bm2_step_response';
if bdIsLoaded(mdl); close_system(mdl, 0); end
new_system(mdl);
load_system(mdl);
% Step 块默认 StepTime=1，会让整个响应右移 1 秒（峰值时刻从 1.57 变成 2.57）。
% 这里显式置 0，使输出与解析解的零初始时刻对齐。
add_block('simulink/Sources/Step', [mdl '/Step'], 'Time', '0');
add_block('simulink/Continuous/Transfer Fcn', [mdl '/Plant'], 'Numerator', '[1]', 'Denominator', '[1 2 5]');
add_block('simulink/Sinks/To Workspace', [mdl '/Sink'], 'VariableName', 'y', 'SaveFormat', 'Timeseries');
add_line(mdl, 'Step/1', 'Plant/1');
add_line(mdl, 'Plant/1', 'Sink/1');
set_param(mdl, 'StopTime', '5', 'Solver', 'ode45', 'MaxStep', '0.01', 'SaveOutput', 'on', 'SaveFormat', 'Dataset', 'ReturnWorkspaceOutputs', 'on');
save_system(mdl, '$bm2ModelM');
simout = sim(mdl);
y = simout.y.Data; t = simout.y.Time;
fprintf('BM2_FINAL=%.6f\n', y(end));
fprintf('BM2_PEAK=%.6f\n', max(y));
[~, ip] = max(y);
fprintf('BM2_PEAK_TIME=%.6f\n', t(ip));
fprintf('BM2_SAMPLES=%d\n', numel(y));
fprintf('BM2_MODEL_BYTES=%d\n', getfield(dir('$bm2ModelM'), 'bytes'));
close_system(mdl, 0);
"@
    $bm2Run = Invoke-BenchmarkTool -Session $session -Benchmark "BM2" -Tool "evaluate_matlab_code" -Purpose "现场搭建 Simulink 模型并跑阶跃仿真" -Arguments @{ code = $bm2Code }

    $bm2Out = "$($bm2Run.output)"
    $bm2Final = Get-NumberFromOutput -Text $bm2Out -Key "BM2_FINAL"
    $bm2PeakGot = Get-NumberFromOutput -Text $bm2Out -Key "BM2_PEAK"
    $bm2PeakTimeGot = Get-NumberFromOutput -Text $bm2Out -Key "BM2_PEAK_TIME"

    $bm2Checks = @(
        @{ name = "仿真终值 ≈ 0.2（容差 0.01）"; pass = ($null -ne $bm2Final -and [math]::Abs($bm2Final - $bm2Steady) -le 0.01) }
        @{ name = "峰值 ≈ 解析值 0.2416（容差 0.01）"; pass = ($null -ne $bm2PeakGot -and [math]::Abs($bm2PeakGot - $bm2Peak) -le 0.01) }
        @{ name = "峰值时刻 ≈ pi/2 s（容差 0.15）"; pass = ($null -ne $bm2PeakTimeGot -and [math]::Abs($bm2PeakTimeGot - $bm2PeakTime) -le 0.15) }
        @{ name = ".slx 模型真实落盘且 >10KB"; pass = ((Test-Path -LiteralPath $bm2Model) -and (Get-Item -LiteralPath $bm2Model).Length -gt 10240) }
    )
    $bm2Pass = @($bm2Checks | Where-Object { $_.pass }).Count
    $bm2Status = if ($bm2Pass -eq $bm2Checks.Count) { "PASS" } elseif ($bm2Pass -gt 0) { "PARTIAL" } else { "FAIL" }
    [void]$benchmarks.Add([pscustomobject][ordered]@{
        id           = "BM2"
        title        = "Simulink 阶跃响应建模"
        rawPrompt    = $bm2Prompt
        routedSkill  = $bm2Route.Skill
        routeReason  = $bm2Route.RouteReason
        matchedTerms = $bm2Route.MatchedTerms
        status       = $bm2Status
        checksPassed = $bm2Pass
        checksTotal  = $bm2Checks.Count
        checks       = @($bm2Checks | ForEach-Object { [pscustomobject]@{ name = $_.name; pass = $_.pass } })
        workDir      = $bm2Dir
        artifacts    = @($bm2Model)
        metrics      = [pscustomobject]@{
            finalValue = $bm2Final; peak = $bm2PeakGot; peakTime = $bm2PeakTimeGot
            expectedSteady = $bm2Steady; expectedPeak = $bm2Peak; expectedPeakTime = $bm2PeakTime
            wn = $bm2Wn; zeta = $bm2Zeta
        }
    })

    # ====================================================================
    # BM3：PID 调参对比
    # ====================================================================
    $bm3Dir = Join-Path $benchDir "bm3_pid_tuning"
    if (-not (Test-Path -LiteralPath $bm3Dir)) { New-Item -ItemType Directory -Force -Path $bm3Dir | Out-Null }
    $bm3Prompt = "对受控对象 1/(s(s+1)) 建立 Simulink PID 单位阶跃模型，" +
                 "先用 Kp=1,Ki=0,Kd=0 跑一轮，再调到 Kp=30,Ki=40,Kd=12 跑第二轮，" +
                 "对比两轮的超调量、2% 调节时间和稳态误差。"
    $bm3Route = Resolve-BenchmarkSkill -Prompt $bm3Prompt
    if (-not $Quiet) { Write-Host "==> BM3 PID 调参对比  [skill: $($bm3Route.Skill)]" -ForegroundColor Cyan }

    # 解析真值：round1 纯比例 Kp=1 -> 闭环 1/(s^2+s+1)，zeta=0.5, wn=1
    $bm3Zeta = 0.5
    $bm3ExpectedOv = [math]::Exp(-$bm3Zeta * [math]::PI / [math]::Sqrt(1 - $bm3Zeta * $bm3Zeta)) * 100.0

    $bm3Model = Join-Path $bm3Dir "bm3_pid_compare.slx"
    $bm3ModelM = $bm3Model -replace '\\', '/'

    function Get-Bm3Code {
        param([double]$Kp, [double]$Ki, [double]$Kd, [string]$Label)
        $kp = $Kp.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        $ki = $Ki.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        $kd = $Kd.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        return @"
mdl = 'bm3_pid_compare';
if bdIsLoaded(mdl); close_system(mdl, 0); end
new_system(mdl);
load_system(mdl);
% 闭环单位反馈：Step -> Sum(+-) -> PID -> Plant -> 输出 -> 回 Sum
% 少了 Sum 与反馈线就是开环级联，输出会一直爬（实测 Kp=1 时 t=30 得到 29，
% 正是 1/(s(s+1)) 的阶跃斜坡响应 t-1，这是真实的建模错误，不是数值误差）。
add_block('simulink/Sources/Step', [mdl '/Step'], 'Time', '0');
add_block('simulink/Math Operations/Sum', [mdl '/Sum'], 'Inputs', '+-');
add_block('simulink/Continuous/PID Controller', [mdl '/PID'], 'Controller', 'PID');
add_block('simulink/Continuous/Transfer Fcn', [mdl '/Plant'], 'Numerator', '[1]', 'Denominator', '[1 1 0]');
add_block('simulink/Sinks/To Workspace', [mdl '/Sink'], 'VariableName', 'y', 'SaveFormat', 'Timeseries');
add_line(mdl, 'Step/1', 'Sum/1');
add_line(mdl, 'Sum/1', 'PID/1');
add_line(mdl, 'PID/1', 'Plant/1');
add_line(mdl, 'Plant/1', 'Sink/1');
add_line(mdl, 'Plant/1', 'Sum/2');
set_param(mdl, 'StopTime', '30', 'Solver', 'ode45', 'MaxStep', '0.01', 'SaveOutput', 'on', 'SaveFormat', 'Dataset', 'ReturnWorkspaceOutputs', 'on');
save_system(mdl, '$bm3ModelM');
set_param([mdl '/PID'], 'P', '$kp', 'I', '$ki', 'D', '$kd', 'Controller', 'PID');
simout = sim(mdl);
y = simout.y.Data; t = simout.y.Time;
yss = y(end);
yp = max(y); [~, ip] = max(y); tp = t(ip);
ov = (yp - yss) / yss * 100;
% 2% 调节时间 = 最后一次**离开**误差带之后的时刻。
% 早期用 find(abs(y-yss)<=band, 1, 'last')，对已收敛的响应取到的是仿真终点，
% 于是任何收敛良好的响应都报"调节时间 = 30s"，指标完全失效。
band = 0.02 * abs(yss);
out = find(abs(y - yss) > band, 1, 'last');
if isempty(out); ts = 0; else; ts = t(min(out + 1, numel(t))); end
fprintf('ROUND=$Label\n');
fprintf('KP=$kp KI=$ki KD=$kd\n');
fprintf('STEADY=%.6f\n', yss);
fprintf('PEAK=%.6f\n', yp);
fprintf('PEAK_TIME=%.6f\n', tp);
fprintf('OVERSHOOT_PCT=%.4f\n', ov);
fprintf('SETTLING_TIME=%.6f\n', ts);
fprintf('SAMPLES=%d\n', numel(y));
close_system(mdl, 0);
"@
    }

    $bm3R1 = Invoke-BenchmarkTool -Session $session -Benchmark "BM3" -Tool "evaluate_matlab_code" -Purpose "第一轮：初始参数 Kp=1,Ki=0,Kd=0" -Arguments @{ code = (Get-Bm3Code -Kp 1.0 -Ki 0.0 -Kd 0.0 -Label "round1_Ponly") }
    $bm3R2 = Invoke-BenchmarkTool -Session $session -Benchmark "BM3" -Tool "evaluate_matlab_code" -Purpose "第二轮：调参后 Kp=30,Ki=40,Kd=12" -Arguments @{ code = (Get-Bm3Code -Kp 30.0 -Ki 40.0 -Kd 12.0 -Label "round2_PID") }

    $bm3R1Out = "$($bm3R1.output)"
    $bm3R2Out = "$($bm3R2.output)"
    $r1Ov = Get-NumberFromOutput -Text $bm3R1Out -Key "OVERSHOOT_PCT"
    $r1Ts = Get-NumberFromOutput -Text $bm3R1Out -Key "SETTLING_TIME"
    $r1Steady = Get-NumberFromOutput -Text $bm3R1Out -Key "STEADY"
    $r2Ov = Get-NumberFromOutput -Text $bm3R2Out -Key "OVERSHOOT_PCT"
    $r2Ts = Get-NumberFromOutput -Text $bm3R2Out -Key "SETTLING_TIME"
    $r2Steady = Get-NumberFromOutput -Text $bm3R2Out -Key "STEADY"

    $bm3Checks = @(
        @{ name = "第一轮超调量 ≈ 解析值 16.30%（容差 1.5）"; pass = ($null -ne $r1Ov -and [math]::Abs($r1Ov - $bm3ExpectedOv) -le 1.5) }
        @{ name = "第一轮稳态值 ≈ 1（容差 0.01）"; pass = ($null -ne $r1Steady -and [math]::Abs($r1Steady - 1.0) -le 0.01) }
        @{ name = "第二轮超调量低于第一轮（调参方向正确）"; pass = ($null -ne $r1Ov -and $null -ne $r2Ov -and $r2Ov -lt $r1Ov) }
        @{ name = "第二轮稳态值 ≈ 1（积分项消除静差）"; pass = ($null -ne $r2Steady -and [math]::Abs($r2Steady - 1.0) -le 0.01) }
        @{ name = "第二轮调节时间短于第一轮（收敛更快）"; pass = ($null -ne $r1Ts -and $null -ne $r2Ts -and $r2Ts -gt 0 -and $r2Ts -lt $r1Ts) }
        @{ name = "两轮调节时间均在 30 s 窗内且为正"; pass = ($null -ne $r1Ts -and $null -ne $r2Ts -and $r1Ts -gt 0 -and $r2Ts -gt 0 -and $r1Ts -le 30 -and $r2Ts -le 30) }
        @{ name = ".slx 模型真实落盘且 >10KB"; pass = ((Test-Path -LiteralPath $bm3Model) -and (Get-Item -LiteralPath $bm3Model).Length -gt 10240) }
    )
    $bm3Pass = @($bm3Checks | Where-Object { $_.pass }).Count
    $bm3Status = if ($bm3Pass -eq $bm3Checks.Count) { "PASS" } elseif ($bm3Pass -gt 0) { "PARTIAL" } else { "FAIL" }
    [void]$benchmarks.Add([pscustomobject][ordered]@{
        id           = "BM3"
        title        = "PID 调参对比"
        rawPrompt    = $bm3Prompt
        routedSkill  = $bm3Route.Skill
        routeReason  = $bm3Route.RouteReason
        matchedTerms = $bm3Route.MatchedTerms
        status       = $bm3Status
        checksPassed = $bm3Pass
        checksTotal  = $bm3Checks.Count
        checks       = @($bm3Checks | ForEach-Object { [pscustomobject]@{ name = $_.name; pass = $_.pass } })
        workDir      = $bm3Dir
        artifacts    = @($bm3Model)
        metrics      = [pscustomobject]@{
            round1Kp = 1.0; round1Ki = 0.0; round1Kd = 0.0
            round2Kp = 30.0; round2Ki = 40.0; round2Kd = 12.0
            round1OvershootPct = $r1Ov; round1SettlingTime = $r1Ts; round1Steady = $r1Steady
            round2OvershootPct = $r2Ov; round2SettlingTime = $r2Ts; round2Steady = $r2Steady
            expectedRound1OvershootPct = $bm3ExpectedOv
            overshootImprovementPct = if ($null -ne $r1Ov -and $null -ne $r2Ov) { $r1Ov - $r2Ov } else { $null }
            settlingSpeedup = if ($null -ne $r1Ts -and $null -ne $r2Ts -and $r2Ts -gt 0) { $r1Ts / $r2Ts } else { $null }
        }
    })
}
finally {
    try { Stop-McpStdioServer -Session $session } catch { }
}

# ---- 把工具调用归属到各 benchmark ----
foreach ($bm in $benchmarks) {
    $mine = @($script:ToolCallLog | Where-Object { $_.benchmark -eq $bm.id })
    $bm | Add-Member -NotePropertyName toolCalls -NotePropertyValue $mine -Force
    $bm | Add-Member -NotePropertyName toolCallCount -NotePropertyValue $mine.Count -Force
    $bm | Add-Member -NotePropertyName totalDurationMs -NotePropertyValue (@($mine | Measure-Object -Property durationMs -Sum).Sum) -Force
    $bm | Add-Member -NotePropertyName failedToolCalls -NotePropertyValue @(@($mine | Where-Object { -not $_.ok }).Count) -Force
    $bm | Add-Member -NotePropertyName toolSequence -NotePropertyValue @($mine | ForEach-Object { $_.tool }) -Force
}

$allCalls = @($script:ToolCallLog)
$totalPass = @($benchmarks | Where-Object { $_.status -eq "PASS" }).Count
$report = [pscustomobject][ordered]@{
    schemaVersion    = "1.0.0"
    taskId           = $TaskId
    generatedAt      = (Get-Date).ToString("o")
    backend          = "matlab-mcp-benchmark"
    sessionMode      = $SessionMode
    serverExe        = $ServerExe
    environment      = [pscustomobject]@{
        os                = [System.Environment]::OSVersion.VersionString
        powerShellVersion = $PSVersionTable.PSVersion.ToString()
        matlabRelease     = "R2026a"
    }
    honesty          = [pscustomobject]@{
        planningLayer    = "规则路由 + 固定步骤序列（非 LLM 自主规划）"
        executionLayer   = "全部真实：每次工具调用都经官方 matlab-mcp-server 打到真实 MATLAB"
        noPresetScripts  = "BM1 脚本由 Agent 侧生成后交 check_matlab_code 静态检查再 run_matlab_file 真实执行；BM2/BM3 模型由 evaluate_matlab_code 现场 new_system/add_block 搭建"
        expectationsFrom = "独立解析推导（不用 MATLAB 输出反推预期）"
    }
    serverStartOk    = $serverStartOk
    serverStartReason = $serverStartReason
    handshakeOk      = $handshakeOk
    discoveredTools  = $toolNames
    benchmarks       = $benchmarks
    toolCallLog      = $allCalls
    summary          = [pscustomobject]@{
        benchmarkTotal  = $benchmarks.Count
        benchmarkPassed = $totalPass
        totalToolCalls  = $allCalls.Count
        totalDurationMs = (@($allCalls | Measure-Object -Property durationMs -Sum).Sum)
        failedToolCalls = @(@($allCalls | Where-Object { -not $_.ok }).Count)
        totalChecks     = @($benchmarks | Measure-Object -Property checksTotal -Sum).Sum
        passedChecks    = @($benchmarks | Measure-Object -Property checksPassed -Sum).Sum
    }
    overallStatus    = if ($totalPass -eq $benchmarks.Count -and $benchmarks.Count -gt 0) { "PASS" } elseif ($totalPass -gt 0) { "PARTIAL" } else { "FAIL" }
}

$json = $report | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText($OutputPath, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "===== Agent Benchmark 结果 =====" -ForegroundColor Cyan
foreach ($bm in $benchmarks) {
    $color = if ($bm.status -eq "PASS") { "Green" } elseif ($bm.status -eq "PARTIAL") { "Yellow" } else { "Red" }
    Write-Host ("  {0} {1,-22} {3}  检查 {4}/{5}  工具调用 {6} 次  总耗时 {7} ms" -f $bm.id, $bm.title, "", $bm.status, $bm.checksPassed, $bm.checksTotal, $bm.toolCallCount, $bm.totalDurationMs) -ForegroundColor $color
}
Write-Host ("  overall={0}  toolCalls={1}  checks={2}/{3}" -f $report.overallStatus, $report.summary.totalToolCalls, $report.summary.passedChecks, $report.summary.totalChecks) -ForegroundColor Cyan
Write-Host "  REPORT=$OutputPath"
