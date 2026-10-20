param(
    [string]$ServerExe = "",
    [int]$TimeoutSeconds = 300
)

# Real MATLAB MCP tool invocation. This is the Task 2 end-to-end check:
#   Agent-side request -> MCP server -> real MATLAB -> result -> written back.
# The MATLAB code is evaluated by the REAL MATLAB that the server starts, not
# by a local matlab -batch.
$ErrorActionPreference = "Stop"
# Repo root from the script location: the checkout must not carry a machine-specific path.
$repo = Split-Path -Parent $PSScriptRoot
# Default to the repo's own server binary; -ServerExe still accepts any install.
if (-not $ServerExe) { $ServerExe = Join-Path $repo "bin\matlab-mcp-server-windows-x64.exe" }
Import-Module -Name (Join-Path $repo "scripts\MatlabAgentSkills.McpStdio.psm1") -Force -DisableNameChecking

$null = Enable-McpLocalhostProxyBypass
$argLine = "--matlab-session-mode=auto --matlab-display-mode=nodesktop --initialize-matlab-on-startup=true"

$session = Start-McpStdioServer -ServerExe $ServerExe -ServerArgumentLine $argLine -Label "phase43-e2e"
try {
    $null = Send-McpStdioRequest -Session $session -Method "initialize" -Params @{
        protocolVersion = "2024-11-05"; capabilities = @{}
        clientInfo = @{ name = "phase43-e2e"; version = "1.0" }
    } -TimeoutSeconds $TimeoutSeconds
    $null = Send-McpStdioRequest -Session $session -Method "notifications/initialized" -Params @{} -Notification -TimeoutSeconds 30

    # 1) toolbox detection
    Write-Host "== tools/call detect_matlab_toolboxes =="
    $d = Send-McpStdioRequest -Session $session -Method "tools/call" -Params @{
        name = "detect_matlab_toolboxes"; arguments = @{}
    } -TimeoutSeconds $TimeoutSeconds
    Write-Host ("  Ok=" + $d.Ok + "  ms=" + $d.DurationMs)
    # Dump the RAW response first: Get-McpStdioToolText expects the RESULT node,
    # and passing the whole envelope silently yields "" -- an empty string that
    # looks like "the tool printed nothing" rather than "we read the wrong level".
    Write-Host "  ---- raw result node ----"
    Write-Host ($d.Result | ConvertTo-Json -Depth 8 -Compress)
    $detText = Get-McpStdioToolText -ResultNode $d.Result
    Write-Host ("  text length: " + (($detText -join "`n").Length))
    Write-Host ("  " + (($detText -join " ") -replace "`r?`n", " "))

    # 2) REAL evaluation -- this is the load-bearing call
    Write-Host "== tools/call evaluate_matlab_code =="
    $code = "v = ver; fprintf('MATLAB %s\n', version); fprintf('TOOLBOX_COUNT %d\n', numel(v)); disp({v.Name}');"
    $e = Send-McpStdioRequest -Session $session -Method "tools/call" -Params @{
        name = "evaluate_matlab_code"; arguments = @{ code = $code }
    } -TimeoutSeconds $TimeoutSeconds
    Write-Host ("  Ok=" + $e.Ok + "  ms=" + $e.DurationMs)
    Write-Host "  ---- raw result node ----"
    Write-Host ($e.Result | ConvertTo-Json -Depth 8 -Compress)
    $evalText = Get-McpStdioToolText -ResultNode $e.Result
    Write-Host "  ---- text ----"
    Write-Host $evalText
    if ($e.StdErrTail) { Write-Host ("  STDERR: " + $e.StdErrTail) }

    $outDir = Join-Path $repo "artifacts\validation\phase43"
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $record = [ordered]@{
        timestamp        = (Get-Date).ToString("o")
        detectOk         = [bool]$d.Ok
        detectMs         = $d.DurationMs
        detectText       = ($detText -join "`n")
        evaluateOk       = [bool]$e.Ok
        evaluateMs       = $e.DurationMs
        evaluateCode     = $code
        evaluateText     = ($evalText -join "`n")
        matlabVersionSeen= if ($evalText -match 'MATLAB\s+(\S+)') { $Matches[1] } else { $null }
    }
    $record | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $outDir "mcp_e2e_evaluate.json") -Encoding utf8
    Write-Host "== wrote artifacts/validation/phase43/mcp_e2e_evaluate.json =="
}
finally {
    Stop-McpStdioServer -Session $session
}