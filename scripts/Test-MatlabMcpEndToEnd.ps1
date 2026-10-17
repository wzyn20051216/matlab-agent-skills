#Requires -Version 5.1
<#
.SYNOPSIS
真实 MATLAB MCP 端到端验收（L1 启动 / L2 握手 / L3 只读执行 / L4 文件操作 / L5 Simulink）。

.DESCRIPTION
链路：
  本脚本（Agent 侧 MCP Client）
    -> 官方 matlab-mcp-server.exe（stdio，--matlab-session-mode）
      -> MATLAB（共享会话或新会话）
        -> 真实执行结果
  -> 数值/文件断言
  -> artifacts/validation/mcp_e2e_report.json

为什么不用 HTTP 直连共享会话：
实测 R2026a 的 connector 在 POST /mcp 上稳定 403（x-api-key / Bearer / apiKey 全部无效），
官方 server 走 stdio 则正常。所以这里复用官方 server，不自己实现 MATLAB API。

existing 模式前置条件（2026-10-17 实测修复）：
- 必须先有一个共享会话：.\scripts\Start-MatlabSharedSession.ps1 -HoldMinutes 30
- **持有会话绝不能用 pause()**。shareMATLABSession() 的 HTTP 监听在 MATLAB 后台线程，
  端口探活会返回 200，看起来是活的；但执行 MATLAB 代码必须回主线程，pause() 会把主线程
  永久阻塞，表现为 initialize / tools/list 正常、tools/call 永远挂起（实测 300s 无响应，
  且服务端 stderr 干净无错误）。正确做法是用一个空转 timer 保持事件循环，见
  Start-MatlabSharedSession.ps1 的说明。
- 持有会话期间不要在机器上再启动任何 MATLAB（含 matlab -batch）：
  每次 MATLAB 启动都会重写 sessionDetails.json，把 existing 模式指向已失效的会话。
- 本脚本只做"消费方"校验：会预检会话文件存在、PID 存活，不会替你启动或持有会话。

判定原则：
- 每一层都要求真实证据：L3 要求输出里出现可验证的数值（SUM=55），
  L4 要求宿主机文件系统的二次核对，L5 要求仿真数值与解析预期一致且 .slx 真实落盘；
- 服务端起不来 / 会话过期 / 握手失败时，后续层输出 SKIP 并写明原因，不伪造 PASS；
- 所有层都有超时，避免服务端挂起拖死验收。

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabMcpEndToEnd.ps1 -SessionMode auto
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabMcpEndToEnd.ps1 -SessionMode existing -TimeoutSeconds 600
#>
[CmdletBinding()]
param(
    [string]$ServerExe = "",
    [string]$MatlabRoot = "",
    [ValidateSet("auto", "existing", "new")]
    [string]$SessionMode = "auto",
    # existing 模式下会话已存在，传 --matlab-display-mode 会被官方 server 判为非法组合，
    # 所以只在 auto/new 时下发。nodesktop 更适合无人值守与 CI。
    [ValidateSet("nodesktop", "desktop")]
    [string]$MatlabDisplayMode = "nodesktop",
    [int]$TimeoutSeconds = 300,
    [string]$WorkingDirectory = "",
    [string]$OutputPath = "",
    [string]$TaskId = "",
    [string]$ServerSessionFile = "",
    [switch]$SkipSimulink,
    [switch]$NoDownload,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir

Import-Module (Join-Path $scriptDir "MatlabAgentSkills.Acceptance.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $scriptDir "MatlabAgentSkills.Core.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $scriptDir "MatlabAgentSkills.Execution.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $scriptDir "MatlabAgentSkills.McpProbe.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $scriptDir "MatlabAgentSkills.McpStdio.psm1") -Force -DisableNameChecking

if (-not $TaskId) { $TaskId = New-AcceptanceTaskId -Prefix "mcp-e2e" }
if (-not $WorkingDirectory) { $WorkingDirectory = Join-Path $repoRoot "artifacts\validation\mcp_e2e" }
if (-not $OutputPath) { $OutputPath = Join-Path $repoRoot "artifacts\validation\mcp_e2e_report.json" }
if (-not (Test-Path -LiteralPath $WorkingDirectory)) {
    New-Item -ItemType Directory -Force -Path $WorkingDirectory | Out-Null
}

$backend = "matlab-mcp-$SessionMode"
if (-not $MatlabRoot) {
    $resolvedMatlab = Resolve-MatlabExecutable -ExplicitPath $env:MATLAB_EXE
    if ($resolvedMatlab) { $MatlabRoot = Split-Path -Parent (Split-Path -Parent $resolvedMatlab) }
}
if (-not $ServerSessionFile) { $ServerSessionFile = Join-Path $env:APPDATA "MathWorks\MATLAB MCP Server\v1\sessionDetails.json" }

$matlabExe = Resolve-MatlabExecutable -ExplicitPath $env:MATLAB_EXE
$installInfo = $null
if ($matlabExe) { $installInfo = Get-MatlabInstallInfo -ExecutablePath $matlabExe }

$report = New-AcceptanceReport -TaskId $TaskId -Backend $backend `
    -MatlabVersion $(if ($installInfo -and $installInfo.Readable) { "$($installInfo.Version) $($installInfo.Description)" } else { "" }) `
    -MatlabRelease $(if ($installInfo -and $installInfo.Readable) { "$($installInfo.Release)" } else { "" }) `
    -MatlabExecutable $matlabExe -MatlabInstalled ([bool]$matlabExe)

# ==================== L1：服务端启动 ====================
$serverInfo = $null
$serverVersion = ""
$serverStartOk = $false
$serverStartReason = $null
$startedAt = Get-AcceptanceTimestamp
$l1Timer = [System.Diagnostics.Stopwatch]::StartNew()

try {
    $resolveParams = @{ ScriptRoot = $scriptDir }
    if ($ServerExe) { $resolveParams["Hint"] = $ServerExe }
    if ($NoDownload) { $resolveParams["NoDownload"] = $true }
    $serverInfo = Resolve-McpServerExecutable @resolveParams
}
catch {
    $serverStartReason = "无法获得 matlab-mcp-server.exe：$($_.Exception.Message)"
}

if (-not $serverStartReason) {
    try {
        $versionText = (& $serverInfo.Path --version 2>&1 | Out-String).Trim()
        $versionExit = $LASTEXITCODE
        if ($versionText -match 'v?\d+\.\d+\.\d+') { $serverVersion = $Matches[0] }
        if ($versionExit -ne 0 -and -not $serverVersion) {
            $serverStartReason = "matlab-mcp-server --version 退出码 $versionExit，输出：$versionText"
        }
    }
    catch {
        $serverStartReason = "执行 --version 失败：$($_.Exception.Message)"
    }
}

$session = $null
$proxyState = $null
$proxySnapshotBefore = Get-McpProxyEnvironmentSnapshot
if (-not $serverStartReason) {
    try {
        $arguments = "--matlab-session-mode=$SessionMode"
        # existing 模式下会话已由 MATLAB 共享，官方 server 明确拒绝 --matlab-root / --matlab-display-mode：
        #   Error with supplied arguments: option "matlab-root" is not compatible with
        #   MATLAB session mode set to "existing".
        # 这与安装器 Test-McpServerArgsCompatible 的裁剪规则一致，这里必须同样遵守。
        if ($SessionMode -ne "existing") {
            if ($MatlabRoot) { $arguments += " --matlab-root=`"$MatlabRoot`"" }
            $arguments += " --matlab-display-mode=$MatlabDisplayMode"
        }
        $arguments += " --disable-telemetry=true"

        # 必须在启动子进程之前设置：官方 server 是 Go 程序，会读 HTTPS_PROXY/NO_PROXY。
        # 没有 NO_PROXY 时它会把 localhost 也发给代理，导致 403 / context deadline exceeded。
        $proxyState = Enable-McpLocalhostProxyBypass

        $session = Start-McpStdioServer -ServerExe $serverInfo.Path -ServerArgumentLine $arguments `
            -WorkingDirectory $WorkingDirectory -Label "matlab-mcp-server-$SessionMode"
        Start-Sleep -Milliseconds 800
        if ($session.Process.HasExited) {
            $serverStartReason = "服务端进程启动后立即退出（exit=$($session.Process.ExitCode)）。stderr：$(Get-McpStdioStderrTail -Session $session)"
        }
        else {
            $serverStartOk = $true
        }
    }
    catch {
        $serverStartReason = "启动服务端进程失败：$($_.Exception.Message)"
    }
}
$l1Timer.Stop()

$report = Add-AcceptanceCheck -Report $report -Id "mcp.server-start" -Title "官方 MCP server 启动成功" -Level "L1" `
    -Status $(if ($serverStartOk) { "PASS" } else { "FAIL" }) `
    -Reason $serverStartReason `
    -ErrorClass $(if ($serverStartOk) { $null } else { "MCP_CONNECTION_ERROR" }) `
    -Command $(if ($serverInfo) { "$($serverInfo.Path) --matlab-session-mode=$SessionMode" } else { "Resolve-McpServerExecutable" }) `
    -Metrics ([ordered]@{
        serverExe         = $(if ($serverInfo) { $serverInfo.Path } else { $null })
        serverSource      = $(if ($serverInfo) { $serverInfo.Source } else { $null })
        serverSha256      = $(if ($serverInfo) { $serverInfo.Sha256 } else { $null })
        provenanceVerified = $(if ($serverInfo) { $serverInfo.Verified } else { $false })
        serverVersion     = $(if ($serverVersion) { $serverVersion } else { $null })
        requestedSessionMode = $SessionMode
        matlabRoot        = $MatlabRoot
        processId         = $(if ($session) { $session.Process.Id } else { $null })
    }) `
    -StartedAt $startedAt -FinishedAt (Get-AcceptanceTimestamp) -DurationSeconds ([Math]::Round($l1Timer.Elapsed.TotalSeconds, 3))

# 会话过期预检：existing 模式下会话文件必须指向活着的 MATLAB，否则不调用工具、直接说明原因。
$sessionPrecheck = $null
if ($serverStartOk -and $SessionMode -eq "existing") {
    $sessionPrecheck = Get-McpSessionInfo -SessionFile $ServerSessionFile -ErrorAction SilentlyContinue
    if ($null -eq $sessionPrecheck) {
        # McpProbe 未导入时用 Core 的解析结果兜底（只判断文件存在）。
        $sessionPrecheck = [pscustomobject]@{ Exists = (Test-Path -LiteralPath $ServerSessionFile); Parsed = $false; Pid = $null; ProcessAlive = $false; Port = $null; CertificateExists = $false; Error = "" }
    }
    if (-not $sessionPrecheck.Exists) { $serverStartReason = "existing 模式需要已共享的 MATLAB 会话，但未找到 $ServerSessionFile" }
    elseif ($sessionPrecheck.Pid -and -not $sessionPrecheck.ProcessAlive) { $serverStartReason = "existing 模式要求会话 PID 存活，但 PID $($sessionPrecheck.Pid) 已不存在（每次启动 MATLAB 都会重写会话文件，先共享会话再运行本脚本）" }
}

# ==================== L2：协议握手 ====================
$handshakeOk = $false
$handshakeReason = $null
$protocolVersion = $null
$serverName = $null
$serverSelfVersion = $null
$handshakeMs = 0
$startedAt = Get-AcceptanceTimestamp
$l2Timer = [System.Diagnostics.Stopwatch]::StartNew()

if (-not $serverStartOk) {
    $handshakeReason = "L1 未通过：$serverStartReason"
}
elseif ($serverStartReason) {
    $handshakeReason = "会话预检未通过：$serverStartReason"
}
else {
    $init = Send-McpStdioRequest -Session $session -Method "initialize" -TimeoutSeconds ([Math]::Min(60, $TimeoutSeconds)) -Params ([ordered]@{
            protocolVersion = "2025-06-18"
            capabilities    = [ordered]@{}
            clientInfo      = [ordered]@{ name = "matlab-agent-skills-e2e"; version = "1.0.0" }
        })
    $handshakeMs = $init.DurationMs
    if ($init.Ok -and $null -ne $init.Result) {
        $protocolVersion = "$($init.Result.protocolVersion)"
        if ($init.Result.PSObject.Properties.Name -contains "serverInfo") {
            $serverName = "$($init.Result.serverInfo.name)"
            $serverSelfVersion = "$($init.Result.serverInfo.version)"
        }
        $handshakeOk = $true
        $null = Send-McpStdioRequest -Session $session -Method "notifications/initialized" -Notification
    }
    else {
        $handshakeReason = if ($init.Error) { $init.Error } else { "initialize 未返回 result" }
        if ($init.StdErrTail) { $handshakeReason += "；stderr：" + $init.StdErrTail }
    }
}
$l2Timer.Stop()

$report = Add-AcceptanceCheck -Report $report -Id "mcp.protocol-handshake" -Title "MCP 协议握手（initialize）" -Level "L2" `
    -Status $(if ($handshakeOk) { "PASS" } else { "FAIL" }) -Reason $handshakeReason `
    -ErrorClass $(if ($handshakeOk) { $null } else { "MCP_CONNECTION_ERROR" }) `
    -Command "stdio: initialize" `
    -Metrics ([ordered]@{
        transport       = "stdio"
        protocolVersion = $protocolVersion
        serverName      = $serverName
        serverVersion   = $serverSelfVersion
        durationMs      = $handshakeMs
    }) `
    -StartedAt $startedAt -FinishedAt (Get-AcceptanceTimestamp) -DurationSeconds ([Math]::Round($l2Timer.Elapsed.TotalSeconds, 3))

# 工具发现：必须在调用前确认工具名，不能假设。
$toolsOk = $false
$toolNames = @()
$toolsReason = $null
$requiredTools = @("evaluate_matlab_code", "run_matlab_file", "check_matlab_code", "detect_matlab_toolboxes")
$startedAt = Get-AcceptanceTimestamp
$toolTimer = [System.Diagnostics.Stopwatch]::StartNew()

if (-not $handshakeOk) {
    $toolsReason = "L2 握手未通过，无法列出工具"
}
else {
    $list = Send-McpStdioRequest -Session $session -Method "tools/list" -TimeoutSeconds 30
    if ($list.Ok -and $null -ne $list.Result -and $list.Result.PSObject.Properties.Name -contains "tools") {
        $toolNames = @($list.Result.tools | ForEach-Object { "$($_.name)" })
        $missing = @($requiredTools | Where-Object { $toolNames -notcontains $_ })
        if ($missing.Count -eq 0) { $toolsOk = $true }
        else { $toolsReason = "缺少预期工具：$($missing -join ', ')；实际：$($toolNames -join ', ')" }
    }
    else {
        $toolsReason = if ($list.Error) { $list.Error } else { "tools/list 未返回 tools" }
    }
}
$toolTimer.Stop()

$report = Add-AcceptanceCheck -Report $report -Id "mcp.tools-list" -Title "工具发现（tools/list）" -Level "L2" `
    -Status $(if ($toolsOk) { "PASS" } else { "FAIL" }) -Reason $toolsReason `
    -ErrorClass $(if ($toolsOk) { $null } else { "MCP_CONNECTION_ERROR" }) `
    -Command "stdio: tools/list" `
    -Metrics ([ordered]@{ toolCount = $toolNames.Count; tools = $toolNames; required = $requiredTools }) `
    -StartedAt $startedAt -FinishedAt (Get-AcceptanceTimestamp) -DurationSeconds ([Math]::Round($toolTimer.Elapsed.TotalSeconds, 3))

# ==================== L3：只读执行 ====================
$readOk = $false
$readReason = $null
$readOutput = ""
$sumValue = $null
$readMs = 0
$startedAt = Get-AcceptanceTimestamp
$l3Timer = [System.Diagnostics.Stopwatch]::StartNew()

if (-not $toolsOk) {
    $readReason = "L2 工具发现未通过"
}
else {
    $code = "disp(version); fprintf('SUM=%d\n', sum(1:10)); fprintf('PWD=%s\n', pwd);"
    $call = Send-McpStdioRequest -Session $session -Method "tools/call" -TimeoutSeconds $TimeoutSeconds -Params ([ordered]@{
            name      = "evaluate_matlab_code"
            arguments = [ordered]@{ code = $code; project_path = $WorkingDirectory }
        })
    $readMs = $call.DurationMs
    if ($call.Ok -and $null -ne $call.Result) {
        $readOutput = Get-McpStdioToolText -ResultNode $call.Result
        $isError = ($call.Result.PSObject.Properties.Name -contains "isError") -and [bool]$call.Result.isError
        if ($isError) {
            $readReason = "工具返回 isError=true：$($readOutput.Substring(0, [Math]::Min(400, $readOutput.Length)))"
        }
        elseif ($readOutput -match 'SUM=(\d+)') {
            $sumValue = [int]$Matches[1]
            if ($sumValue -eq 55 -and $readOutput -match '\d+\.\d+') { $readOk = $true }
            else { $readReason = "数值不符：期望 SUM=55，实际 SUM=$sumValue；输出：$($readOutput.Substring(0, [Math]::Min(300, $readOutput.Length)))" }
        }
        else {
            $readReason = "输出中未找到可验证的数值标记；输出：$($readOutput.Substring(0, [Math]::Min(400, $readOutput.Length)))"
        }
    }
    else {
        $reasonParts = @()
        if ($call.Error) { $reasonParts += $call.Error }
        if ($call.TimedOut) { $reasonParts += "请求超时（${TimeoutSeconds}s）" }
        if ($call.StdErrTail) { $reasonParts += "stderr：" + $call.StdErrTail }
        $readReason = ($reasonParts -join "；")
        if (-not $readReason) { $readReason = "tools/call 未返回结果" }
    }
}
$l3Timer.Stop()

$report = Add-AcceptanceCheck -Report $report -Id "mcp.readonly-exec" -Title "MATLAB 只读执行（version + 数值）" -Level "L3" `
    -Status $(if ($readOk) { "PASS" } elseif ($readReason -match "未通过") { "SKIP" } else { "FAIL" }) -Reason $readReason `
    -ErrorClass $(if ($readOk -or $readReason -match "未通过") { $null } else { "MATLAB_RUNTIME_ERROR" }) `
    -Command "stdio: tools/call evaluate_matlab_code (disp version + sum(1:10))" `
    -Metrics ([ordered]@{
        tool           = "evaluate_matlab_code"
        expectedSum    = 55
        actualSum      = $sumValue
        durationMs     = $readMs
        outputExcerpt  = (Protect-McpSensitiveText -Text $(if ($readOutput) { $readOutput.Substring(0, [Math]::Min(600, $readOutput.Length)) } else { "" }))
    }) `
    -StartedAt $startedAt -FinishedAt (Get-AcceptanceTimestamp) -DurationSeconds ([Math]::Round($l3Timer.Elapsed.TotalSeconds, 3))

# ==================== L4：文件操作（双向） ====================
$ioOk = $false
$ioReason = $null
$ioMetrics = [ordered]@{
    hostScript       = $null
    runToken         = $null
    runOutput        = $null
    matlabWrittenFile = $null
    hostReadToken     = $null
    hostVerified      = $false
}
$startedAt = Get-AcceptanceTimestamp
$l4Timer = [System.Diagnostics.Stopwatch]::StartNew()

if (-not $readOk) {
    $ioReason = "L3 只读执行未通过"
}
else {
    $ioDir = Join-Path $WorkingDirectory "io"
    if (-not (Test-Path -LiteralPath $ioDir)) { New-Item -ItemType Directory -Force -Path $ioDir | Out-Null }

    # 方向 1：宿主机写脚本 -> MCP 执行 -> 脚本再写一个结果文件 -> 宿主机核对
    $runToken = [guid]::NewGuid().ToString("N").Substring(0, 12)
    $resultFile = Join-Path $ioDir "run_result_$runToken.txt"
    $scriptPath = Join-Path $ioDir "e2e_run_$runToken.m"
    $scriptBody = @"
fid = fopen('$resultFile', 'w');
fprintf(fid, '%s', '$runToken');
fclose(fid);
disp('RUN_TOKEN=$runToken');
"@
    [System.IO.File]::WriteAllText($scriptPath, $scriptBody, (New-Object System.Text.UTF8Encoding($false)))
    $ioMetrics.hostScript = $scriptPath
    $ioMetrics.runToken = $runToken

    $runCall = Send-McpStdioRequest -Session $session -Method "tools/call" -TimeoutSeconds $TimeoutSeconds -Params ([ordered]@{
            name      = "run_matlab_file"
            arguments = [ordered]@{ script_path = $scriptPath }
        })
    $runText = ""
    if ($runCall.Ok -and $null -ne $runCall.Result) { $runText = Get-McpStdioToolText -ResultNode $runCall.Result }
    $ioMetrics.runOutput = (Protect-McpSensitiveText -Text $(if ($runText) { $runText.Substring(0, [Math]::Min(600, $runText.Length)) } else { "" }))

    $runEchoOk = ($runText -match [regex]::Escape("RUN_TOKEN=$runToken"))
    $runFileOk = (Test-Path -LiteralPath $resultFile) -and ((Get-Content -Raw -LiteralPath $resultFile).Trim() -eq $runToken)

    # 方向 2：MCP 侧写文件并回读 -> 宿主机独立核对内容
    $writeToken = [guid]::NewGuid().ToString("N").Substring(0, 12)
    $matlabFile = Join-Path $ioDir "matlab_written_$writeToken.txt"
    $ioMetrics.matlabWrittenFile = $matlabFile
    $code = "p = '$matlabFile'; fid = fopen(p, 'w'); fprintf(fid, '%s', '$writeToken'); fclose(fid); s = fileread(p); disp(['ECHO=' s]);"
    $writeCall = Send-McpStdioRequest -Session $session -Method "tools/call" -TimeoutSeconds $TimeoutSeconds -Params ([ordered]@{
            name      = "evaluate_matlab_code"
            arguments = [ordered]@{ code = $code; project_path = $WorkingDirectory }
        })
    $writeText = ""
    if ($writeCall.Ok -and $null -ne $writeCall.Result) { $writeText = Get-McpStdioToolText -ResultNode $writeCall.Result }

    $echoOk = ($writeText -match [regex]::Escape("ECHO=$writeToken"))
    $hostContent = ""
    if (Test-Path -LiteralPath $matlabFile) { $hostContent = (Get-Content -Raw -LiteralPath $matlabFile).Trim() }
    $ioMetrics.hostReadToken = $hostContent
    $ioMetrics.hostVerified = ($hostContent -eq $writeToken)
    $ioMetrics["writeEcho"] = (Protect-McpSensitiveText -Text $(if ($writeText) { $writeText.Substring(0, [Math]::Min(300, $writeText.Length)) } else { "" }))

    if (-not $runEchoOk) {
        $ioReason = "run_matlab_file 输出里没有脚本写入的标记（期望 RUN_TOKEN=$runToken）"
    }
    elseif (-not $runFileOk) {
        $ioReason = "脚本声称写入但宿主机未看到一致结果：$resultFile"
    }
    elseif (-not $echoOk) {
        $ioReason = "MATLAB 写文件后回读内容不含 ECHO=$writeToken"
    }
    elseif (-not $ioMetrics.hostVerified) {
        $ioReason = "宿主机读到的内容与 MATLAB 写入令牌不一致：'$hostContent'"
    }
    else {
        $ioOk = $true
    }
}
$l4Timer.Stop()

$report = Add-AcceptanceCheck -Report $report -Id "mcp.file-io" -Title "文件操作（写脚本执行 + 双向回读）" -Level "L4" `
    -Status $(if ($ioOk) { "PASS" } elseif ($ioReason -match "未通过") { "SKIP" } else { "FAIL" }) -Reason $ioReason `
    -ErrorClass $(if ($ioOk -or $ioReason -match "未通过") { $null } else { "VALIDATION_ERROR" }) `
    -Command "stdio: tools/call run_matlab_file + evaluate_matlab_code (write/read)" `
    -Metrics $ioMetrics -ArtifactPaths @($WorkingDirectory) `
    -StartedAt $startedAt -FinishedAt (Get-AcceptanceTimestamp) -DurationSeconds ([Math]::Round($l4Timer.Elapsed.TotalSeconds, 3))

# ==================== L5：Simulink 模型操作 ====================
$simOk = $false
$simReason = $null
$simMetrics = [ordered]@{
    modelPath   = $null
    finalValue  = $null
    expected    = 3.0
    samples     = $null
    modelExists = $false
    modelBytes  = $null
    output      = $null
}
$startedAt = Get-AcceptanceTimestamp
$l5Timer = [System.Diagnostics.Stopwatch]::StartNew()

if ($SkipSimulink) {
    $simReason = "调用方要求跳过 L5"
}
elseif (-not $ioOk) {
    $simReason = "L4 文件操作未通过"
}
else {
    $slxPath = Join-Path $WorkingDirectory "mcp_e2e_step_gain.slx"
    if (Test-Path -LiteralPath $slxPath) { Remove-Item -LiteralPath $slxPath -Force }
    $simMetrics.modelPath = $slxPath

    # 与 matlab/validation/simulink_coder_smoke.m 相同的已验证范式：
    # Step 的阶跃时刻参数名是 Time；SaveFormat=Array 才能用 yout(:) 取值。
    $code = @"
mdl = 'mcp_e2e_step_gain';
if bdIsLoaded(mdl); close_system(mdl, 0); end
new_system(mdl);
add_block('simulink/Sources/Step', [mdl '/Step'], 'Position', [80 80 120 120], 'SampleTime', '0.01', 'Time', '1');
add_block('simulink/Math Operations/Gain', [mdl '/Gain'], 'Gain', '3', 'Position', [170 80 230 120]);
add_block('simulink/Sinks/Out1', [mdl '/Out1'], 'Position', [290 80 330 120]);
add_line(mdl, 'Step/1', 'Gain/1');
add_line(mdl, 'Gain/1', 'Out1/1');
set_param(mdl, 'StopTime', '2', 'Solver', 'FixedStepDiscrete', 'FixedStep', '0.01', 'SaveOutput', 'on', 'SaveFormat', 'Array', 'ReturnWorkspaceOutputs', 'on');
save_system(mdl, '$slxPath');
close_system(mdl, 0);
load_system('$slxPath');
simOut = sim(mdl);
yout = simOut.get('yout');
y = yout(:);
fprintf('FINAL=%.9f\n', y(end));
fprintf('SAMPLES=%d\n', numel(y));
fprintf('MODEL_EXISTS=%d\n', isfile('$slxPath'));
fprintf('MODEL_BYTES=%d\n', dir('$slxPath').bytes);
close_system(mdl, 0);
"@
    $call = Send-McpStdioRequest -Session $session -Method "tools/call" -TimeoutSeconds $TimeoutSeconds -Params ([ordered]@{
            name      = "evaluate_matlab_code"
            arguments = [ordered]@{ code = $code; project_path = $WorkingDirectory }
        })
    $text = ""
    if ($call.Ok -and $null -ne $call.Result) { $text = Get-McpStdioToolText -ResultNode $call.Result }
    $simMetrics.output = (Protect-McpSensitiveText -Text $(if ($text) { $text.Substring(0, [Math]::Min(800, $text.Length)) } else { "" }))

    $isError = ($call.Ok -and $null -ne $call.Result -and ($call.Result.PSObject.Properties.Name -contains "isError") -and [bool]$call.Result.isError)
    if (-not $call.Ok -or $isError) {
        $simReason = if ($call.Error) { $call.Error } else { "Simulink 建模调用失败：$($text.Substring(0, [Math]::Min(500, $text.Length)))" }
    }
    elseif ($text -match 'FINAL=(-?\d+(?:\.\d+)?)') {
        $final = [double]$Matches[1]
        $simMetrics.finalValue = $final
        if ($text -match 'SAMPLES=(\d+)') { $simMetrics.samples = [int]$Matches[1] }
        $hostExists = Test-Path -LiteralPath $slxPath
        $simMetrics.modelExists = $hostExists
        if ($hostExists) { $simMetrics.modelBytes = (Get-Item -LiteralPath $slxPath).Length }

        if (-not $hostExists) {
            $simReason = "MATLAB 报告建模成功，但宿主机上找不到 .slx：$slxPath"
        }
        elseif ([Math]::Abs($final - 3.0) -gt 1e-6) {
            $simReason = "仿真终值与解析预期不符：期望 3.0（阶跃 1 × 增益 3），实际 $final"
        }
        elseif ($simMetrics.samples -lt 1) {
            $simReason = "仿真未产生采样点"
        }
        else {
            $simOk = $true
        }
    }
    else {
        $simReason = "输出中未找到 FINAL= 标记；输出：$($text.Substring(0, [Math]::Min(500, $text.Length)))"
    }
}
$l5Timer.Stop()

$report = Add-AcceptanceCheck -Report $report -Id "mcp.simulink-model" -Title "Simulink 建模 + 仿真数值（Step→Gain×3）" -Level "L5" `
    -Status $(if ($simOk) { "PASS" } elseif ($simReason -match "跳过|未通过") { "SKIP" } else { "FAIL" }) -Reason $simReason `
    -ErrorClass $(if ($simOk -or $simReason -match "跳过|未通过") { $null } else { "SIMULATION_ERROR" }) `
    -Command "stdio: tools/call evaluate_matlab_code (new_system/add_block/add_line/sim)" `
    -Metrics $simMetrics -ArtifactPaths @($(if ($simMetrics.modelPath) { $simMetrics.modelPath } else { $WorkingDirectory })) `
    -StartedAt $startedAt -FinishedAt (Get-AcceptanceTimestamp) -DurationSeconds ([Math]::Round($l5Timer.Elapsed.TotalSeconds, 3))

# ==================== 收尾 ====================
# 收尾失败不能丢弃已经拿到的证据：曾经出现过服务端关闭瞬间异常导致整份报告没写盘，
# 结果 L3~L5 明明已经跑完却只剩上一次的旧报告。这里把关闭与摘要都做成"尽力而为"。
$shutdown = [pscustomobject][ordered]@{ Exited = $null; ExitCode = $null; Forced = $false; StdErrTail = "" }
if ($session) {
    try { $shutdown = Stop-McpStdioServer -Session $session }
    catch {
        $shutdown.StdErrTail = "关闭服务端时异常（已继续写报告）：$($_.Exception.Message)"
    }
}
if ($proxyState) { Restore-McpProxyEnvironment -State $proxyState }

$totalSeconds = 0
foreach ($check in @($report.checks)) {
    if ($null -ne $check.durationSeconds) { $totalSeconds += [double]$check.durationSeconds }
}

$toolCallCount = 0
if ($session -and $session.RequestLog) {
    $toolCallCount = @($session.RequestLog | Where-Object { $_.Method -eq "tools/call" }).Count
}

$report | Add-Member -NotePropertyName mcpSession -NotePropertyValue ([ordered]@{
        transport        = "stdio"
        requestedMode    = $SessionMode
        serverExe        = $(if ($serverInfo) { $serverInfo.Path } else { $null })
        serverVersion    = $(if ($serverVersion) { $serverVersion } else { $null })
        serverSelfName   = $serverName
        serverSelfVersion = $serverSelfVersion
        shutdown         = $shutdown
        totalToolCalls   = $toolCallCount
        totalDurationSeconds = [Math]::Round($totalSeconds, 3)
        proxy            = [ordered]@{
            before           = $proxySnapshotBefore
            localhostBypass  = $(if ($proxyState) { $proxyState.Applied } else { $null })
            note             = "官方 server 是 Go 程序；未设置 NO_PROXY 时会把 localhost 也发给代理，导致 403 / 超时"
        }
    }) -Force

$report.limitations = @(
    "L1~L5 只证明本机 R2026a + 官方 server $serverVersion 的链路可用，不证明其它版本。",
    "会话文件会被任何一次 MATLAB 启动重写（含 -batch），所以 existing 模式必须最后共享会话再跑。",
    "官方 server 默认发送匿名遥测；本脚本显式传 --disable-telemetry=true。"
)

$report = Write-AcceptanceReport -Report (Update-AcceptanceSummary -Report $report) -Path $OutputPath

if (-not $Quiet) {
    Write-Host ""
    foreach ($check in @($report.checks)) {
        $reasonText = if ($check.status -ne "PASS" -and $check.reason) { ($check.reason -replace "\s+", " ") } else { "" }
        Write-Host ("{0,-24} {1,-4} {2,-5} {3,7}s  {4}" -f `
                $check.id, $check.level, $check.status, ([math]::Round([double]$check.durationSeconds, 1)), $reasonText)
    }
    Write-Host ("==> overall={0} achievedLevel={1} pass={2} fail={3} skip={4}" -f `
        $report.overallStatus, $report.achievedLevel, $report.summary.pass, $report.summary.fail, $report.summary.skip) -ForegroundColor Cyan
    Write-Host "MCP_E2E_REPORT=$OutputPath"
}

exit (Get-AcceptanceExitCode -Report $report)
