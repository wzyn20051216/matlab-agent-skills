param(
    [ValidateSet("R1", "R2", "R3", "ALL")]
    [string]$Group = "ALL",
    [int]$Repeats = 3,
    [int]$TimeoutSeconds = 420
)

# Phase 4.3 benchmark driver.
#
# Runs the six tasks in evals/phase43_benchmark.json through three channels:
#   R1  matlab -batch, sandbox without the skills directory
#   R2  the official MATLAB MCP server, same sandbox
#   R3  the official MATLAB MCP server, with this project's skills on the path
#
# Results land in artifacts/validation/phase43/<group>_run<N>/<task>_result.json
# and are graded by MATLAB (mas_phase43_grade.m) against the frozen references.
#
# The driver is PowerShell rather than MATLAB on purpose: driving the MCP
# server over stdio from inside a matlab -batch process hit a wall of quoting
# and exit-code problems, and the whole point of this benchmark is to measure
# the channels, not to debug the driver.

$ErrorActionPreference = "Stop"
$repo = "E:\desktop\MATLAB"
# The MATLAB and MCP helpers write their banner to STDERR, and with
# ErrorActionPreference = "Stop" PowerShell turns any NativeCommandError into a
# terminating one -- so the very first task aborted the whole run before R2 or
# R3 ever started. Keep Stop for our own logic, drop it around the child
# processes, and treat a non-zero exit as data rather than as a crash.
$ErrorActionPreference = "Continue"
$outRoot = Join-Path $repo "artifacts\validation\phase43"
if (-not (Test-Path -LiteralPath $outRoot)) { New-Item -ItemType Directory -Force -Path $outRoot | Out-Null }

$cfg = Get-Content -LiteralPath (Join-Path $repo "evals\phase43_benchmark.json") -Raw | ConvertFrom-Json
$tasks = $cfg.tasks

$groups = if ($Group -eq "ALL") { @("R1","R2","R3") } else { @($Group) }

foreach ($g in $groups) {
    for ($rep = 1; $rep -le $Repeats; $rep++) {
        $dir = Join-Path $outRoot ("{0}_run{1}" -f $g, $rep)
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        foreach ($t in $tasks) {
            $taskFile = Join-Path $dir ("{0}_task.m" -f $t.id)
            $resultFile = Join-Path $dir ("{0}_result.json" -f $t.id)
            $logFile = Join-Path $dir ("{0}_mcp.log" -f $t.id)

            # write the task script (same content for every group -- see
            # scripts/Get-Phase43TaskScript.ps1 for the source of truth)
            & powershell -ExecutionPolicy Bypass -File (Join-Path $repo "scripts\Write-Phase43Task.ps1") `
                -TaskId $t.id -OutputPath $taskFile | Out-Null

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $resultText = ""
            if ($g -eq "R1") {
                $sandbox = Join-Path $dir "sandbox"
                New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
                # Copy to an EXPLICIT destination name. Copy-Item with a bare
                # directory as -Destination keeps the SOURCE name (B1_task.m),
                # while the runner script below references task_B1.m -- so the
                # file was there and run() still could not find it.
                $sandboxTask = Join-Path $sandbox ("task_$($t.id).m")
                Copy-Item -LiteralPath $taskFile -Destination $sandboxTask -Force
                # cd alone is NOT enough: MATLAB does not put the current
                # directory on its path, so `task_B1` is "unrecognised" even
                # though the file is right there.
                #
                # The path is passed through a temporary runner script rather
                # than through -batch's inline command: a quoted path inside
                # another quoted command loses its slashes when it crosses the
                # cmd.exe boundary, and `run` then reports a bogus file name.
                $runner = Join-Path $dir "run_$($t.id).m"
                $mpath = (Join-Path $sandbox ("task_$($t.id).m")).Replace("\", "/")
                Set-Content -LiteralPath $runner -Value "run('$mpath');" -Encoding ascii
                $resultText = & (Join-Path "E:" "matlab\bin\matlab.exe") -batch ("run('" + (Join-Path $dir ("run_$($t.id).m")).Replace("\", "/") + "')") 2>&1 | Out-String
            } else {
                $withSkills = if ($g -eq "R3") { "1" } else { "0" }
                $resultText = & powershell -ExecutionPolicy Bypass -File (Join-Path $repo "scripts\Invoke-Phase43McpTask.ps1") `
                    -TaskId $t.id -TaskScript $taskFile -WithSkills $withSkills `
                    -OutputPath $logFile -TimeoutSeconds $TimeoutSeconds 2>&1 | Out-String
            }
            $sw.Stop()

            # keep the raw output for audit, and extract the MAS_RESULT line
            $rawFile = Join-Path $dir ("{0}_raw.txt" -f $t.id)
            $resultText | Set-Content -LiteralPath $rawFile -Encoding utf8

            $masLine = ""
            foreach ($line in ($resultText -split "`r?`n")) {
                if ($line -match "MAS_RESULT") { $masLine = $line.Trim(); break }
            }
            @{
                taskId    = $t.id
                group     = $g
                repeat    = $rep
                ms        = $sw.ElapsedMilliseconds
                masLine   = $masLine
                channel   = $g
                timestamp = (Get-Date).ToString("o")
            } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $resultFile -Encoding ascii

            Write-Host ("{0} {1} r{2} {3}  {4} ms  {5}" -f $g, $t.id, $rep, $(if ($masLine) { "OK" } else { "NO-RESULT" }), $sw.ElapsedMilliseconds, $masLine.Substring(0, [Math]::Min(70, $masLine.Length)))
        }
    }
}
Write-Host "driver done"