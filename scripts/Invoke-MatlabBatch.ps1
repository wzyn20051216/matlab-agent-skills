<#
.SYNOPSIS
用 MATLAB -batch 执行脚本或代码片段，带超时、日志与错误分类。

.DESCRIPTION
与旧版差异（向后兼容原有参数）：
- 新增 `-TimeoutSeconds`（默认 1800）：MATLAB 启动挂起时会终止进程树，而不是无限等待；
- 新增 `-NoRetry`：默认对 TIMEOUT 额外重试一次，可用此开关关闭；
- 失败时给出统一 errorClass（LICENSE_ERROR / TIMEOUT / CODEGEN_ERROR ...）；
- 退出码：MATLAB 原始退出码；超时为 124。

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\scripts\Invoke-MatlabBatch.ps1 -Script .\matlab\validation\pi_control_step.m -TimeoutSeconds 600
#>
[CmdletBinding()]
param(
    [string]$MatlabPath = $env:MATLAB_EXE,
    [string]$Code,
    [string]$Script,
    [string]$WorkingDirectory = (Get-Location).Path,
    [string]$LogDirectory,
    [string]$Label = "matlab_batch",
    [int]$TimeoutSeconds = 1800,
    [switch]$NoRetry,
    [string]$AcceptancePath
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptDir "MatlabAgentSkills.Execution.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $scriptDir "MatlabAgentSkills.Acceptance.psm1") -Force -DisableNameChecking

if (-not $Code -and -not $Script) {
    throw "Provide -Code or -Script."
}
if (-not (Test-Path -LiteralPath $WorkingDirectory)) {
    throw "WorkingDirectory does not exist: $WorkingDirectory"
}

$resolvedMatlab = Resolve-MatlabExecutable -ExplicitPath $MatlabPath
if (-not $resolvedMatlab) {
    $message = "MATLAB executable not found. Set MATLAB_EXE or ensure matlab is on PATH."
    [Console]::Error.WriteLine($message)
    if ($AcceptancePath) {
        $report = New-AcceptanceReport -TaskId (New-AcceptanceTaskId -Prefix "batch") -Backend "matlab-batch"
        $report = Add-AcceptanceCheck -Report $report -Id "batch.matlab" -Title "MATLAB 可执行文件可解析" -Level "L1" `
            -Status "FAIL" -Reason $message -ErrorClass "ENVIRONMENT_ERROR"
        Write-AcceptanceReport -Report $report -Path $AcceptancePath | Out-Null
    }
    exit 2
}

if (-not $LogDirectory) {
    $LogDirectory = Join-Path $WorkingDirectory "artifacts\logs"
}
New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$safeLabel = $Label -replace '[^\w.-]', '_'
$stdoutPath = Join-Path $LogDirectory "$safeLabel`_$timestamp.stdout.log"
$stderrPath = Join-Path $LogDirectory "$safeLabel`_$timestamp.stderr.log"
$stageLogPath = Join-Path $LogDirectory "$safeLabel`_$timestamp.stages.log"
$summaryPath = Join-Path $LogDirectory "$safeLabel`_$timestamp.summary.txt"

if ($Script) {
    $resolvedScript = (Resolve-Path -LiteralPath $Script).Path
    $escapedScript = $resolvedScript.Replace("'", "''")
    $batchCommand = "run('$escapedScript')"
}
else {
    $tempScript = Join-Path $LogDirectory "$safeLabel`_$timestamp`_batch.m"
    Set-Content -Path $tempScript -Value $Code -Encoding UTF8
    $escapedScript = $tempScript.Replace("'", "''")
    $batchCommand = "run('$escapedScript')"
}

$argumentList = @("-batch", $batchCommand)

$action = {
    Invoke-MatlabBatchProcess -MatlabPath $resolvedMatlab `
        -ArgumentList $argumentList `
        -WorkingDirectory $WorkingDirectory `
        -TimeoutSeconds $TimeoutSeconds `
        -StdoutPath $stdoutPath `
        -StderrPath $stderrPath `
        -StageLogPath $stageLogPath `
        -Label $safeLabel
}

$maxAttempts = 1
if (-not $NoRetry) {
    # 只对超时做一次重试：验证类脚本只写 artifacts，属于幂等操作。
    $maxAttempts = 2
}

$result = Invoke-WithRetry -Operation "matlab-batch:$safeLabel" -Action $action `
    -MaxAttempts $maxAttempts -DelaySeconds 2 -Idempotent $true
$run = $result.Value
if ($null -eq $run) {
    throw "MATLAB 进程未返回结果：$($result.Reason)"
}

$summary = @(
    "matlab_path=$resolvedMatlab",
    "working_directory=$WorkingDirectory",
    "started=$($run.StartedAt)",
    "finished=$($run.FinishedAt)",
    "duration_seconds=$($run.DurationSeconds)",
    "timeout_seconds=$TimeoutSeconds",
    "attempts=$($result.AttemptCount)",
    "timed_out=$($run.TimedOut)",
    "exit_code=$($run.ExitCode)",
    "error_class=$($run.ErrorClass)",
    "stdout=$stdoutPath",
    "stderr=$stderrPath",
    "stages=$stageLogPath",
    "command=$batchCommand"
)
$summary | Set-Content -Path $summaryPath -Encoding UTF8
Get-Content -Path $summaryPath

if ($AcceptancePath) {
    $report = New-AcceptanceReport -TaskId (New-AcceptanceTaskId -Prefix "batch") -Backend "matlab-batch" `
        -MatlabExecutable $resolvedMatlab -MatlabInstalled $true
    $status = "PASS"
    $reason = $null
    if ($run.TimedOut -or $run.ExitCode -ne 0) { $status = "FAIL" }
    if ($status -eq "FAIL") {
        if ($run.TimedOut) {
            $reason = "超过 $TimeoutSeconds 秒未结束，已终止进程树"
        }
        else {
            $reason = "MATLAB 退出码 $($run.ExitCode)（$($run.ErrorClass)）"
        }
    }
    $retryInfo = [ordered]@{
        attempts    = $result.AttemptCount
        maxAttempts = $maxAttempts
        approved    = $false
        blockedReason = $result.BlockedReason
    }
    $report = Add-AcceptanceCheck -Report $report -Id "batch.execution" -Title "MATLAB 批处理执行" -Level "L1" `
        -Status $status -Command $run.Command -ExitCode $run.ExitCode -Reason $reason `
        -ErrorClass $run.ErrorClass -StartedAt $run.StartedAt -FinishedAt $run.FinishedAt `
        -DurationSeconds $run.DurationSeconds -Retry $retryInfo `
        -Metrics ([ordered]@{ timedOut = $run.TimedOut; timeoutSeconds = $TimeoutSeconds; attempts = $result.AttemptCount }) `
        -ArtifactPaths @($stdoutPath, $stderrPath, $stageLogPath)
    Write-AcceptanceReport -Report $report -Path $AcceptancePath | Out-Null
}

if ($run.TimedOut) {
    [Console]::Error.WriteLine("MATLAB batch timed out after $TimeoutSeconds seconds. See $stdoutPath and $stageLogPath")
    exit 124
}
if ($run.ExitCode -ne 0) {
    [Console]::Error.WriteLine("MATLAB batch failed (exit=$($run.ExitCode), class=$($run.ErrorClass)). See $stdoutPath and $stderrPath")
}
exit $run.ExitCode
