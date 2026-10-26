# S3-T5: verify the INSTALLED copy of the Skills over the official stdio path.
# Installs into an isolated root under %TEMP% (never the real user Skill root), then runs
# the installed probe with NO -SkipTlsValidation. ASCII-only source so Windows PowerShell 5.1
# can parse it regardless of the active code page.
param(
    [ValidateSet("5.1", "7")]
    [string]$PsHost = "5.1",
    [ValidateSet("auto", "stdio", "https")]
    [string]$Transport = "auto",
    [ValidateSet("existing", "auto", "new")]
    [string]$SessionMode = "existing",
    [string]$RepositoryRoot = "E:\desktop\MATLAB",
    [string]$ServerExe = "",
    [string]$ProbeProjectRoot = "",
    [int]$TimeoutSeconds = 60,
    [string]$EvidenceDir = ""
)

$ErrorActionPreference = "Stop"

$tag = "$PsHost-$Transport-$SessionMode"
if (-not $EvidenceDir) { $EvidenceDir = Join-Path $RepositoryRoot "artifacts\s3\evidence" }
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$isoRoot = Join-Path ([IO.Path]::GetTempPath()) ("mas-s3-" + $tag + "-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $isoRoot | Out-Null
$skillRoot = Join-Path $isoRoot "installed-skills"
$backupRoot = Join-Path $isoRoot "backups"
$project = Join-Path $isoRoot "project"
New-Item -ItemType Directory -Force -Path $project | Out-Null

function Get-Sha256File {
    param([Parameter(Mandatory)][string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace "-", "")
    }
    finally { $sha.Dispose() }
}

function Get-HostExe {
    param([string]$Which)
    if ($Which -eq "7") {
        $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
        if (-not $cmd) { throw "pwsh (PowerShell 7) not found on PATH" }
        return [string]$cmd.Source
    }
    return (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe")
}

$report = [ordered]@{
    tag             = $tag
    startedAt       = (Get-Date -Format "yyyy-MM-ddTHH:mm:sszzz")
    repositoryRoot  = $RepositoryRoot
    isolatedRoot    = $isoRoot
    transport       = $Transport
    serverExe       = $ServerExe
    sessionMode     = $SessionMode
    skipTlsValidation = $false
    host            = $PsHost
    payload         = [ordered]@{}
    install         = @{}
    probe           = @{}
}

try {
    # ---------- 1. isolated install of the nine Skills ----------
    $syncLog = Join-Path $EvidenceDir ("installed-$tag.sync.log")
    $sync = & (Join-Path $RepositoryRoot "scripts\Sync-Skills.ps1") -RepositoryRoot $RepositoryRoot `
        -SkillRoot $skillRoot -BackupRoot $backupRoot 2>&1 | Out-String
    [IO.File]::WriteAllText($syncLog, $sync, (New-Object System.Text.UTF8Encoding($true)))
    $syncJson = $null
    $brace = $sync.IndexOf("{")
    if ($brace -ge 0) { $syncJson = $sync.Substring($brace) | ConvertFrom-Json }

    $runnerRoot = Join-Path $skillRoot "matlab-runner"
    $payloadTargets = @(
        "scripts\Test-MatlabMcpExistingSession.ps1",
        "scripts\MatlabAgentSkills.McpProbe.psm1",
        "scripts\MatlabAgentSkills.McpStdio.psm1",
        "config\mcp-server-manifest.json",
        "schemas\acceptance-report.schema.json"
    )
    foreach ($target in $payloadTargets) {
        $path = Join-Path $runnerRoot $target
        $entry = [ordered]@{ exists = (Test-Path -LiteralPath $path -PathType Leaf) }
        if ($entry.exists) {
            $sha = Get-Sha256File -Path $path
            $sourcePath = Join-Path $RepositoryRoot $target
            $sourceSha = Get-Sha256File -Path $sourcePath
            $entry.sha256 = $sha
            $entry.matchesSource = ($sha -eq $sourceSha)
        }
        $report.payload[$target.Replace("\", "/")] = $entry
    }
    $report.install = [ordered]@{
        installed = $(if ($syncJson) { [int]$syncJson.installed } else { $null })
        skillRoot = $skillRoot
        logPath   = $syncLog
    }

    # ---------- 2. run the installed probe with the requested host ----------
    $exe = Get-HostExe -Which $PsHost
    $probePath = Join-Path $runnerRoot "scripts\Test-MatlabMcpExistingSession.ps1"
    $stdout = Join-Path $EvidenceDir ("installed-$tag.stdout.txt")
    $stderr = Join-Path $EvidenceDir ("installed-$tag.stderr.txt")
    $probeProject = if ($ProbeProjectRoot) { $ProbeProjectRoot } else { $project }
    $probeArtifacts = Join-Path $isoRoot "artifacts"
    $argLine = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$probePath`"",
        "-ProjectRoot", "`"$probeProject`"",
        "-ArtifactsRoot", "`"$probeArtifacts`"",
        "-Transport", $Transport,
        "-SessionMode", $SessionMode,
        "-TimeoutSeconds", "$TimeoutSeconds",
        "-Json"
    )
    if ($ServerExe) { $argLine += @("-ServerExe", "`"$ServerExe`"") }
    $proc = Start-Process -FilePath $exe -ArgumentList $argLine -WorkingDirectory $probeProject `
        -PassThru -Wait -NoNewWindow `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $outText = if (Test-Path -LiteralPath $stdout) { [IO.File]::ReadAllText($stdout) } else { "" }
    $errText = if (Test-Path -LiteralPath $stderr) { [IO.File]::ReadAllText($stderr) } else { "" }
    $report.probe = [ordered]@{
        exe        = $exe
        exitCode   = $proc.ExitCode
        stdoutPath = $stdout
        stderrPath = $stderr
    }

    # ---------- 3. parse the probe report ----------
    $installedReport = Join-Path $probeArtifacts "validation\acceptance\mcp_probe.json"
    if (Test-Path -LiteralPath $installedReport) {
        Copy-Item -LiteralPath $installedReport -Destination (Join-Path $EvidenceDir ("installed-$tag.report.json")) -Force
        $json = [IO.File]::ReadAllText($installedReport, (New-Object System.Text.UTF8Encoding($false))) | ConvertFrom-Json
        $checks = @($json.checks | ForEach-Object {
                [ordered]@{ id = $_.id; status = $_.status; reason = $_.reason; level = $_.level;
                    evidencePath = $_.evidencePath; metrics = $_.metrics }
            })
        $report.probe.overallStatus = [string]$json.overallStatus
        $report.probe.achievedLevel = [string]$json.achievedLevel
        $report.probe.matlabVersion = [string]$json.matlabVersion
        $report.probe.checks = $checks
        $report.probe.limitations = @($json.limitations)
    }
    else {
        $report.probe.reportMissing = $true
        $report.probe.stdoutTail = ($outText -split "`n" | Select-Object -Last 25) -join "`n"
    }
    $report.probe.stderrTail = (($errText -split "`n" | Select-Object -Last 15) -join "`n")
    $report.finishedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:sszzz")

    $outFile = Join-Path $EvidenceDir ("installed-$tag.json")
    [IO.File]::WriteAllText($outFile, ($report | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "EVIDENCE: $outFile"
    Write-Host ("overall=" + $report.probe.overallStatus + " achieved=" + $report.probe.achievedLevel + " exit=" + $proc.ExitCode)
    foreach ($c in @($report.probe.checks)) { Write-Host ("  " + $c.id + " " + $c.status) }
}
finally {
    if (Test-Path -LiteralPath $isoRoot) {
        try { Remove-Item -LiteralPath $isoRoot -Recurse -Force } catch { Write-Warning "left behind: $isoRoot" }
    }
}
