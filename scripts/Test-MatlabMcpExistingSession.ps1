<#
.SYNOPSIS
验证 MATLAB 官方 MCP 配置与会话状态。
#>
[CmdletBinding()]
param(
    [string]$McpServerName = "matlab-official"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$validationDir = Join-Path $repoRoot "artifacts\validation"
if (-not (Test-Path -LiteralPath $validationDir)) {
    New-Item -ItemType Directory -Force -Path $validationDir | Out-Null
}

$sessionPath = Join-Path $env:APPDATA "MathWorks\MATLAB MCP Server\v1\sessionDetails.json"
$sessionExists = Test-Path -LiteralPath $sessionPath
$session = $null
if ($sessionExists) {
    $session = Get-Content -Raw -LiteralPath $sessionPath | ConvertFrom-Json
}

$matlabProc = $null
if ($session -and $session.pid) {
    $matlabProc = Get-Process -Id ([int]$session.pid) -ErrorAction SilentlyContinue
}

$visibleMatlab = @(Get-Process -Name MATLAB -ErrorAction SilentlyContinue | Select-Object Id, ProcessName, MainWindowTitle, StartTime)
$staleSessionHint = $null
if ($sessionExists -and -not $matlabProc -and $visibleMatlab.Count -gt 0) {
    $staleSessionHint = "Session file points to a stale pid. Re-run shareMATLABSession() in the visible MATLAB desktop if you want MCP to reuse that exact session."
}

$codexGet = $null
try {
    $codexGet = & codex mcp get $McpServerName 2>&1
}
catch {
    $codexGet = $_.Exception.Message
}

$codexText = $codexGet -join [Environment]::NewLine
$codexMode = $null
if ($codexText -match '--matlab-session-mode=([a-z]+)') {
    $codexMode = $Matches[1]
}
$autoConfigured = [bool]($codexText -match '--matlab-session-mode=auto')
$startupInitConfigured = [bool]($codexText -match '--initialize-matlab-on-startup=true')

$report = [pscustomobject]@{
    probeTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    mcpServerName = $McpServerName
    codexSessionMode = $codexMode
    autoConfigured = $autoConfigured
    initializeMatlabOnStartup = $startupInitConfigured
    sessionFile = $sessionPath
    sessionFileExists = $sessionExists
    session = $session
    matlabProcessAlive = [bool]$matlabProc
    matlabProcessName = if ($matlabProc) { $matlabProc.ProcessName } else { $null }
    visibleMatlabProcesses = $visibleMatlab
    staleSessionHint = $staleSessionHint
    codexMcpGet = $codexText
    ready = [bool]($sessionExists -and $session -and $matlabProc)
    autoModeReady = [bool]($autoConfigured -and $startupInitConfigured)
}

$reportPath = Join-Path $validationDir "matlab_mcp_existing_session_probe.json"
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding UTF8
$report | ConvertTo-Json -Depth 6
