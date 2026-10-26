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

传输方式（-Transport，默认 auto）：
- stdio：启动官方 matlab-mcp-server 子进程。这是实测唯一可用路径；
  二进制只能使用本机已有且通过 config/mcp-server-manifest.json 校验的那一个，本脚本绝不下载。
- https：直连 MATLAB connector 的 POST /mcp。仅作观测——R2026a 实测恒 403，
  且必须能解析出会话证书指纹才发起（-SkipTlsValidation 会把整进程的证书校验关掉，不默认使用）。
- auto：优先 stdio，找不到可用二进制时退回 https，并把退回原因写进报告。

.DESCRIPTION
脚本自身只依赖同目录模块与 Skill 根下的 schemas/；产物默认写到调用者项目目录，
不写回 Skill 安装目录。安装后的推荐调用方式见 matlab-runner / matlab-orchestrator
的 SKILL.md（先解析 skill root，再用 Join-Path 定位本脚本）。

.EXAMPLE
powershell -ExecutionPolicy Bypass -File $skillRoot\scripts\Test-MatlabMcpExistingSession.ps1
powershell -ExecutionPolicy Bypass -File $skillRoot\scripts\Test-MatlabMcpExistingSession.ps1 -VerifyLicense -Json
powershell -ExecutionPolicy Bypass -File $skillRoot\scripts\Test-MatlabMcpExistingSession.ps1 -ProjectRoot (Get-Location).Path -Json
#>
[CmdletBinding()]
param(
    [string]$McpServerName = "matlab-official",
    [string]$SessionFile,
    [string]$MatlabPath = $env:MATLAB_EXE,
    [string]$OutputPath,
    # 项目根只影响客户端注册扫描与产物位置；资源解析始终相对本脚本/Skill 根。
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$ArtifactsRoot,
    [ValidateSet("static", "matlab-batch", "matlab-mcp-auto", "matlab-mcp-existing", "matlab-mcp-new")]
    [string]$Backend = "matlab-mcp-existing",
    [ValidateSet("auto", "stdio", "https")]
    [string]$Transport = "auto",
    # 只在显式指定时使用；未给出时按 env:MATLAB_MCP_SERVER -> 客户端注册 -> 固定候选顺序查找。
    [string]$ServerExe = "",
    [ValidateSet("auto", "existing", "new")]
    [string]$SessionMode = "auto",
    [int]$TimeoutSeconds = 20,
    [switch]$VerifyLicense,
    [switch]$SkipStage5,
    [switch]$SkipTlsValidation,
    [switch]$SkipCodexCli,
    [switch]$SkipUserConfigs,
    [string]$EvalTool = "",
    [switch]$Json,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Import-Module (Join-Path $scriptDir "MatlabAgentSkills.Acceptance.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $scriptDir "MatlabAgentSkills.Execution.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $scriptDir "MatlabAgentSkills.McpProbe.psm1") -Force -DisableNameChecking

$ProjectRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProjectRoot)
if (-not $ArtifactsRoot) {
    $ArtifactsRoot = Join-Path $ProjectRoot "artifacts"
}
else {
    $ArtifactsRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ArtifactsRoot)
}
$validationDir = Join-Path $ArtifactsRoot "validation"
if (-not (Test-Path -LiteralPath $validationDir)) {
    New-Item -ItemType Directory -Force -Path $validationDir | Out-Null
}
if (-not $OutputPath) {
    $OutputPath = Join-Path $validationDir "matlab_mcp_existing_session_probe.json"
}

$probeParams = @{
    ServerName         = $McpServerName
    MatlabPath         = $MatlabPath
    RepositoryRoot     = $ProjectRoot
    Backend            = $Backend
    Transport          = $Transport
    SessionMode        = $SessionMode
    TimeoutSeconds     = $TimeoutSeconds
    VerifyLicense      = [bool]$VerifyLicense
    SkipStage5         = [bool]$SkipStage5
    SkipTlsValidation  = [bool]$SkipTlsValidation
    IoProbeDirectory   = (Join-Path $validationDir "mcp_io_probe")
}
if ($ServerExe) { $probeParams["ServerExe"] = $ServerExe }
if ($SessionFile) { $probeParams["SessionFile"] = $SessionFile }
if ($EvalTool) { $probeParams["EvalTool"] = $EvalTool }
if ($SkipCodexCli) { $probeParams["SkipCodexCli"] = $true }
if ($SkipUserConfigs) { $probeParams["SkipUserConfigs"] = $true }

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
