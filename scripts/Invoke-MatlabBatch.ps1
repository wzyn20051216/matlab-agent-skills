param(
    [string]$MatlabPath = $env:MATLAB_EXE,
    [string]$Code,
    [string]$Script,
    [string]$WorkingDirectory = (Get-Location).Path,
    [string]$LogDirectory,
    [string]$Label = "matlab_batch"
)

$ErrorActionPreference = "Stop"

if (-not $MatlabPath) {
    $matlabCommand = Get-Command matlab -ErrorAction SilentlyContinue
    if ($matlabCommand) {
        $MatlabPath = $matlabCommand.Source
    }
}

if (-not $MatlabPath -or -not (Test-Path -LiteralPath $MatlabPath)) {
    throw "MATLAB executable not found. Set MATLAB_EXE or ensure matlab is on PATH."
}

if (-not $Code -and -not $Script) {
    throw "Provide -Code or -Script."
}

if (-not (Test-Path -LiteralPath $WorkingDirectory)) {
    throw "WorkingDirectory does not exist: $WorkingDirectory"
}

if (-not $LogDirectory) {
    $LogDirectory = Join-Path $WorkingDirectory "artifacts\logs"
}

New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$safeLabel = $Label -replace '[^\w.-]', '_'
$stdoutPath = Join-Path $LogDirectory "$safeLabel`_$timestamp.stdout.log"
$stderrPath = Join-Path $LogDirectory "$safeLabel`_$timestamp.stderr.log"
$summaryPath = Join-Path $LogDirectory "$safeLabel`_$timestamp.summary.txt"

if ($Script) {
    $resolvedScript = Resolve-Path -LiteralPath $Script
    $escapedScript = $resolvedScript.Path.Replace("'", "''")
    $batchCommand = "run('$escapedScript')"
}
else {
    $tempScript = Join-Path $LogDirectory "$safeLabel`_$timestamp`_batch.m"
    Set-Content -Path $tempScript -Value $Code -Encoding UTF8
    $escapedScript = $tempScript.Replace("'", "''")
    $batchCommand = "run('$escapedScript')"
}

$started = Get-Date
$process = Start-Process -FilePath $MatlabPath `
    -ArgumentList @("-batch", $batchCommand) `
    -WorkingDirectory $WorkingDirectory `
    -Wait `
    -PassThru `
    -NoNewWindow `
    -RedirectStandardOutput $stdoutPath `
    -RedirectStandardError $stderrPath
$finished = Get-Date

$summary = @(
    "matlab_path=$MatlabPath",
    "working_directory=$WorkingDirectory",
    "started=$($started.ToString('o'))",
    "finished=$($finished.ToString('o'))",
    "duration_seconds=$([math]::Round(($finished - $started).TotalSeconds, 3))",
    "exit_code=$($process.ExitCode)",
    "stdout=$stdoutPath",
    "stderr=$stderrPath",
    "command=$batchCommand"
)

$summary | Set-Content -Path $summaryPath -Encoding UTF8
Get-Content -Path $summaryPath

if ($process.ExitCode -ne 0) {
    Write-Error "MATLAB batch failed. See $stdoutPath and $stderrPath"
}

exit $process.ExitCode
