<#
.SYNOPSIS
MATLAB MCP 分级探测：安装/许可证 → 配置 → 协议握手 → 只读执行 → 文件读写。

.DESCRIPTION
旧版把 `ready` 定义为“会话文件存在 + PID 存活”，这只证明配置存在，不能证明 MCP 可用。
新版把探测拆成 5 个阶段，各自输出 PASS / FAIL / SKIP：

1. mcp.matlab-install / mcp.matlab-license   MATLAB 安装与许可证
2. mcp.session-config / mcp.client-registration  MCP 配置与会话
3. mcp.protocol-handshake   JSON-RPC initialize
4. mcp.readonly-exec        tools/call 执行 disp(version)
5. mcp.file-io              隔离目录写入 + 回读（宿主机侧二次核对）

阶段 3~5 未通过时，后续阶段输出 SKIP 并写明原因，绝不臆造 PASS。

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabMcpExistingSession.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabMcpExistingSession.ps1 -VerifyLicense -Json
#>
[CmdletBinding()]
param(
    [string]$McpServerName = "matlab-official",
    [string]$SessionFile,
    [string]$MatlabPath = $env:MATLAB_EXE,
    [string]$OutputPath,
    [ValidateSet("static", "matlab-batch", "matlab-mcp-auto", "matlab-mcp-existing", "matlab-mcp-new")]
    [string]$Backend = "matlab-mcp-existing",
    [int]$TimeoutSeconds = 20,
    [switch]$VerifyLicense,
    [switch]$SkipStage5,
    [switch]$SkipTlsValidation,
    [string]$EvalTool = "",
    [switch]$Json,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptDir

Import-Module (Join-Path $scriptDir "MatlabAgentSkills.Acceptance.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $scriptDir "MatlabAgentSkills.Execution.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $scriptDir "MatlabAgentSkills.McpProbe.psm1") -Force -DisableNameChecking

$validationDir = Join-Path $repoRoot "artifacts\validation"
if (-not (Test-Path -LiteralPath $validationDir)) {
    New-Item -ItemType Directory -Force -Path $validationDir | Out-Null
}
if (-not $OutputPath) {
    $OutputPath = Join-Path $validationDir "matlab_mcp_existing_session_probe.json"
}

$probeParams = @{
    ServerName         = $McpServerName
    MatlabPath         = $MatlabPath
    RepositoryRoot     = $repoRoot
    Backend            = $Backend
    TimeoutSeconds     = $TimeoutSeconds
    VerifyLicense      = [bool]$VerifyLicense
    SkipStage5         = [bool]$SkipStage5
    SkipTlsValidation  = [bool]$SkipTlsValidation
    IoProbeDirectory   = (Join-Path $validationDir "mcp_io_probe")
}
if ($SessionFile) { $probeParams["SessionFile"] = $SessionFile }
if ($EvalTool) { $probeParams["EvalTool"] = $EvalTool }

$report = Invoke-McpStagedProbe @probeParams

$acceptanceDir = Join-Path $validationDir "acceptance"
$report = Write-AcceptanceReport -Report $report -Path $OutputPath
$mirrorPath = Join-Path $acceptanceDir "mcp_probe.json"
Write-AcceptanceReport -Report $report -Path $mirrorPath | Out-Null

if ($Json) {
    $report | ConvertTo-Json -Depth 16
}
elseif (-not $Quiet) {
    # 一条检查项一行：Format-Table 会把长 reason 折行，反而不易读。
    foreach ($check in $report.checks) {
        $reasonText = if ($check.status -ne "PASS" -and $check.reason) { ($check.reason -replace "\s+", " ") } else { "" }
        Write-Host ("{0,-24} {1,-4} {2,-5} {3}" -f $check.id, $check.level, $check.status, $reasonText)
    }

    Write-Host ("==> overall={0} achievedLevel={1} pass={2} fail={3} skip={4}" -f `
        $report.overallStatus, $report.achievedLevel, `
        $report.summary.pass, $report.summary.fail, $report.summary.skip) -ForegroundColor Cyan
    Write-Host "MCP_PROBE_REPORT=$OutputPath"
}

exit (Get-AcceptanceExitCode -Report $report)
