param(
    [string]$ServerExe = "E:\desktop\MATLAB\bin\matlab-mcp-server-windows-x64.exe",
    [int]$TimeoutSeconds = 240
)

# Real MATLAB MCP handshake + tools/list over stdio. No mock, no simulation:
# this starts the official server binary and speaks JSON-RPC to it.
$ErrorActionPreference = "Stop"
$repo = "E:\desktop\MATLAB"
Import-Module -Name (Join-Path $repo "scripts\MatlabAgentSkills.McpStdio.psm1") -Force -DisableNameChecking

$null = Enable-McpLocalhostProxyBypass

$argLine = "--matlab-session-mode=auto --matlab-display-mode=nodesktop --initialize-matlab-on-startup=true"

Write-Host "== starting official MATLAB MCP server (stdio) =="
$session = Start-McpStdioServer -ServerExe $ServerExe -ServerArgumentLine $argLine -Label "phase43-probe"
Write-Host "   session started"

try {
    $init = Send-McpStdioRequest -Session $session -Method "initialize" -Params @{
        protocolVersion = "2024-11-05"
        capabilities    = @{}
        clientInfo      = @{ name = "phase43-probe"; version = "1.0" }
    } -TimeoutSeconds $TimeoutSeconds

    Write-Host "== initialize =="
    Write-Host ("  Ok=" + $init.Ok + "  TimedOut=" + $init.TimedOut + "  DurationMs=" + $init.DurationMs)
    if ($init.Error) { Write-Host ("  Error: " + ($init.Error | ConvertTo-Json -Depth 6 -Compress)) }
    if ($init.Result) { Write-Host ("  Result: " + ($init.Result | ConvertTo-Json -Depth 6 -Compress)) }
    if ($init.StdErrTail) { Write-Host ("  STDERR: " + $init.StdErrTail) }

    $null = Send-McpStdioRequest -Session $session -Method "notifications/initialized" -Params @{} -Notification -TimeoutSeconds 30

    $tools = Send-McpStdioRequest -Session $session -Method "tools/list" -Params @{} -TimeoutSeconds 180
    Write-Host "== tools/list =="
    $names = @()
    if ($tools.Result -and $tools.Result.tools) {
        foreach ($t in $tools.Result.tools) { $names += $t.name }
    }
    Write-Host ("  Ok=" + $tools.Ok + "  tool count: " + $names.Count)
    foreach ($n in $names) { Write-Host "   - $n" }
    if ($tools.StdErrTail) { Write-Host ("  STDERR: " + $tools.StdErrTail) }

    $outDir = Join-Path $repo "artifacts\validation\phase43"
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $record = [ordered]@{
        timestamp       = (Get-Date).ToString("o")
        serverExe       = $ServerExe
        serverArgLine   = $argLine
        initializeOk    = [bool]$init.Ok
        initializeMs    = $init.DurationMs
        protocolVersion = if ($init.Result) { $init.Result.protocolVersion } else { $null }
        serverInfo      = if ($init.Result) { $init.Result.serverInfo } else { $null }
        toolsListOk     = [bool]$tools.Ok
        toolCount       = $names.Count
        tools           = $names
        stderrTail      = $init.StdErrTail
    }
    $record | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $outDir "mcp_tools_list.json") -Encoding utf8
    Write-Host "== wrote artifacts/validation/phase43/mcp_tools_list.json =="
}
finally {
    Stop-McpStdioServer -Session $session
    Write-Host "== server stopped =="
}