param(
    [Parameter(Mandatory)][string]$TaskId,
    [Parameter(Mandatory)][string]$TaskScript,
    [string]$WithSkills = "0",
    [string]$OutputPath = "",
    [int]$TimeoutSeconds = 300
)

# Run ONE benchmark task through the official MATLAB MCP server.
#
# The difference between R2 and R3 is exactly one thing, and it is applied
# here: with -WithSkills 1 the task script is executed with this project's
# skill scripts on the MATLAB path, so the task can use mas_codegen_ready and
# friends. With 0 it cannot. Everything else -- server binary, session mode,
# MATLAB install, the task script itself -- is identical.
#
# The result is written as the raw MCP tool output, which the MATLAB grader
# parses. No summary is produced here: a grader that reads a summary sentence
# is the thing this whole project exists to prevent.

$ErrorActionPreference = "Stop"
# Repo root from the script location: the checkout must not carry a machine-specific path.
$repo = Split-Path -Parent $PSScriptRoot
Import-Module -Name (Join-Path $repo "scripts\MatlabAgentSkills.McpStdio.psm1") -Force -DisableNameChecking

$null = Enable-McpLocalhostProxyBypass
$serverExe = Join-Path $repo "bin\matlab-mcp-server-windows-x64.exe"
$argLine = "--matlab-session-mode=auto --matlab-display-mode=nodesktop --initialize-matlab-on-startup=true"

$skillsPath = @()
if ($WithSkills -eq "1") {
    foreach ($s in @("matlab-codegen-deploy","matlab-control-optimization","matlab-data-analysis",
                     "matlab-orchestrator","matlab-robotics-autonomy","matlab-runner",
                     "matlab-signal-vision-ai","matlab-simulink-modeling","matlab-testing-ci")) {
        $p = Join-Path $repo "skills\$s\scripts"
        if (Test-Path -LiteralPath $p) { $skillsPath += $p }
    }
}

# The task script is written into a scratch dir with the skill path added only
# when R3 is running. R2 gets the same script in a directory that has no way to
# reach the skills.
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("p43_" + $TaskId + "_" + [Guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
# Explicit destination NAME: Copy-Item with a bare directory keeps the source
# name, and the MATLAB code below references the script by its task name.
$scriptPath = Join-Path $scratch ("task_" + $TaskId + ".m")
Copy-Item -LiteralPath $TaskScript -Destination $scriptPath -Force

$pathPrefix = ($skillsPath -join [System.IO.Path]::PathSeparator)
$code = ""
if ($WithSkills -eq "1" -and $pathPrefix -ne "") {
    # forward slashes: a backslash inside a MATLAB single-quoted string is an
    # escape character, so 'C:\Users\<user>\...' arrives with \U and \t mangled.
    $code += "addpath('$($pathPrefix.Replace('\','/'))'); "
}
# run() with a BARE NAME searches the MATLAB path; run() with a full path does
# not. The scratch directory is not on the path, so the bare name fails with
# "未找到 task_B1" even though the file is right there.
#
# The path is converted to forward slashes and the quotes are doubled: a
# backslash inside a MATLAB single-quoted string is an ESCAPE character, so
# 'C:\Users\<user>\...' would arrive with \U and \t mangled.
$matlabPath = $scriptPath.Replace("\", "/")
$code += "run('$matlabPath');"

$session = $null
try {
    $session = Start-McpStdioServer -ServerExe $serverExe -ServerArgumentLine $argLine `
        -WorkingDirectory $scratch -Label "p43-$TaskId"

    $null = Send-McpStdioRequest -Session $session -Method "initialize" -Params @{
        protocolVersion = "2024-11-05"
        capabilities    = @{}
        clientInfo      = @{ name = "phase43-$TaskId"; version = "1.0" }
    } -TimeoutSeconds $TimeoutSeconds
    $null = Send-McpStdioRequest -Session $session -Method "notifications/initialized" -Params @{} -Notification -TimeoutSeconds 30

    $resp = Send-McpStdioRequest -Session $session -Method "tools/call" -Params @{
        name = "evaluate_matlab_code"
        arguments = @{ code = $code }
    } -TimeoutSeconds $TimeoutSeconds

    $text = Get-McpStdioToolText -ResultNode $resp.Result
    if ($OutputPath) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
        $text | Set-Content -Path $OutputPath -Encoding utf8
    }
    Write-Host $text
    # Exit 0 on success AND on a graded failure. A non-zero exit code makes
    # MATLAB's system() throw "output argument not assigned" and abort the
    # caller, hiding a result line that was already written to -OutputPath.
    # The verdict belongs to the grader, not to the exit code.
    exit 0
}
finally {
    # | Out-Null on purpose: Stop-McpStdioServer returns a session object, and
    # letting PowerShell format it appends "Exited ExitCode Forced StdErrTail"
    # AFTER the MAS_RESULT line -- which the grader then fails to parse as JSON.
    if ($session) { Stop-McpStdioServer -Session $session | Out-Null }
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}