# S2 pre-fix evidence: installed skills lack the MCP probe closure.
# Writes only under artifacts/s2/pre-fix. Never reads real session credentials.
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$repo = "E:\desktop\MATLAB"
$root = Join-Path $repo "artifacts\s2\pre-fix"
$installed = Join-Path $root "installed"
$backup = Join-Path $root "backups"
$project = Join-Path $root "project-cwd"
$entryRoot = Join-Path $root "entry-only"
$evidence = Join-Path $root "evidence"
$ladderPath = Join-Path $evidence "closure_ladder.json"
$syncScript = Join-Path $repo "scripts\Sync-Skills.ps1"
$probeRel = "scripts\Test-MatlabMcpExistingSession.ps1"

foreach ($path in @($root, $project, $entryRoot, $evidence)) {
    if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
}

function Reset-Directory {
    param([string]$Path, [string]$MustBeUnder)
    $full = [IO.Path]::GetFullPath($Path)
    $prefix = [IO.Path]::GetFullPath($MustBeUnder).TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "refusing to reset outside sandbox: $full"
    }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $full | Out-Null
}

function Write-TextFile {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-TreeRecord {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    return @(Get-ChildItem -LiteralPath $resolved -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
            [pscustomobject]@{
                relative = $_.FullName.Substring($resolved.Length).TrimStart([char[]]'\/')
                bytes    = $_.Length
                sha256   = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        })
}

function Invoke-Captured {
    param(
        [string]$Label,
        [string]$WorkingDirectory,
        [string[]]$Arguments
    )
    $stdout = Join-Path $evidence "$Label.stdout.txt"
    $stderr = Join-Path $evidence "$Label.stderr.txt"
    $commandLine = "powershell -NoProfile -ExecutionPolicy Bypass " + ($Arguments -join " ")
    Write-TextFile -Path (Join-Path $evidence "$Label.command.txt") -Text $commandLine
    $previous = Get-Location
    $previousEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        Set-Location -LiteralPath $WorkingDirectory
        $all = & powershell -NoProfile -ExecutionPolicy Bypass @Arguments 2>&1
        $code = $LASTEXITCODE
    }
    catch {
        $all = @($_.Exception.Message)
        $code = 1
    }
    finally {
        Set-Location -LiteralPath $previous
        $ErrorActionPreference = $previousEap
    }
    $lines = @($all | ForEach-Object { [string]$_ })
    $stdoutLines = New-Object System.Collections.Generic.List[string]
    $stderrLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -match '^(?:\s*\+ CategoryInfo|\s*\+ FullyQualifiedErrorId|\s*\+ At line)') { $stderrLines.Add($line) }
        else { $stdoutLines.Add($line) }
    }
    Write-TextFile -Path $stdout -Text (($stdoutLines -join "`n") + "`n")
    Write-TextFile -Path $stderr -Text (($stderrLines -join "`n") + "`n")
    return [pscustomobject]@{
        label = $Label
        workingDirectory = $WorkingDirectory
        command = $commandLine
        exitCode = [int]$code
        output = ($lines -join "`n")
    }
}

# 1) Install the current skills into a sandbox Skills root.
Reset-Directory -Path $installed -MustBeUnder $root
Reset-Directory -Path $backup -MustBeUnder $root
$syncJson = & $syncScript -RepositoryRoot $repo -SkillRoot $installed -BackupRoot $backup | Out-String
Write-TextFile -Path (Join-Path $evidence "sync.stdout.txt") -Text $syncJson
$sync = $syncJson | ConvertFrom-Json

$installedRunner = Join-Path $installed "matlab-runner"
$installedOrchestrator = Join-Path $installed "matlab-orchestrator"
$closure = @(
    "scripts\Test-MatlabMcpExistingSession.ps1",
    "scripts\MatlabAgentSkills.Acceptance.psm1",
    "scripts\MatlabAgentSkills.Execution.psm1",
    "scripts\MatlabAgentSkills.McpProbe.psm1",
    "scripts\MatlabAgentSkills.Core.psm1",
    "schemas\acceptance-report.schema.json"
)
$closureChecks = @(foreach ($relative in $closure) {
        [pscustomobject]@{
            relative = $relative
            runnerInstalled = (Test-Path -LiteralPath (Join-Path $installedRunner $relative))
            orchestratorInstalled = (Test-Path -LiteralPath (Join-Path $installedOrchestrator $relative))
            sourceExists = (Test-Path -LiteralPath (Join-Path $repo $relative))
        }
    })

$installRecord = [ordered]@{
    schema = "mas-s2-prefix-install/1"
    syncedAt = (Get-Date).ToString("o")
    syncInstalled = [int]$sync.installed
    syncUpdated = [int]$sync.updated
    syncUnchanged = [int]$sync.unchanged
    syncFailed = [bool]$sync.failed
    runnerTree = @(Get-TreeRecord -Path $installedRunner)
    orchestratorTree = @(Get-TreeRecord -Path $installedOrchestrator)
    closureChecks = $closureChecks
}
Write-TextFile -Path (Join-Path $evidence "installed_manifest.json") -Text ($installRecord | ConvertTo-Json -Depth 8)

# 2) Original command from the installed skill root.
$originalFromSkill = Invoke-Captured -Label "original-from-installed-skill" -WorkingDirectory $installedRunner `
    -Arguments @("-File", ".\$probeRel", "-Json")

# 3) Same installed path from a project cwd outside the repository and outside the skill.
$probeAbsent = Join-Path $installedRunner $probeRel
$originalOutside = Invoke-Captured -Label "original-from-project-cwd" -WorkingDirectory $project `
    -Arguments @("-File", $probeAbsent, "-Json")

# 4) Entry-script-only ladder: add one dependency at a time and record the first failure.
Reset-Directory -Path $entryRoot -MustBeUnder $root
$fakeSession = Join-Path $root "fake-session.json"
$fakeCert = Join-Path $root "fake-cert.pem"
Write-TextFile -Path $fakeCert -Text "-----BEGIN CERTIFICATE-----`nS2-FAKE-NOT-A-REAL-CERTIFICATE`n-----END CERTIFICATE-----`n"
$fakeSessionJson = [ordered]@{
    port        = 1
    certificate = $fakeCert
    apiKey      = "synthetic-s2-fake-not-a-real-credential"
    pid         = $PID
} | ConvertTo-Json
Write-TextFile -Path $fakeSession -Text $fakeSessionJson

$ladderFiles = @(
    "scripts\Test-MatlabMcpExistingSession.ps1",
    "scripts\MatlabAgentSkills.Acceptance.psm1",
    "scripts\MatlabAgentSkills.Execution.psm1",
    "scripts\MatlabAgentSkills.McpProbe.psm1",
    "scripts\MatlabAgentSkills.Core.psm1",
    "schemas\acceptance-report.schema.json"
)
$ladder = New-Object System.Collections.Generic.List[object]
$oldUserProfile = $env:USERPROFILE
$oldAppData = $env:APPDATA
$oldHome = $env:HOME
$oldPath = $env:PATH
$oldMatlabExe = $env:MATLAB_EXE
try {
    # Keep the ladder away from the real user profile and any real codex registration.
    $env:USERPROFILE = Join-Path $root "isolated-user"
    $env:APPDATA = Join-Path $root "isolated-appdata"
    $env:HOME = $env:USERPROFILE
    $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot\System32\WindowsPowerShell\v1.0;$env:SystemRoot"
    $env:MATLAB_EXE = Join-Path $root "no-such-matlab.exe"
    foreach ($path in @($env:USERPROFILE, $env:APPDATA)) {
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
    }

    for ($i = 0; $i -lt $ladderFiles.Count; $i++) {
        $relative = $ladderFiles[$i]
        $source = Join-Path $repo $relative
        $target = Join-Path $entryRoot $relative
        $parent = Split-Path -Parent $target
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        Copy-Item -LiteralPath $source -Destination $target -Force

        $entryProbe = Join-Path $entryRoot $probeRel
        $reportPath = Join-Path $evidence ("ladder-$($i + 1)-report.json")
        $label = "ladder-$($i + 1)-$(($relative -split '\\')[-1] -replace '\.', '-')"
        $run = Invoke-Captured -Label $label -WorkingDirectory $entryRoot `
            -Arguments @(
                "-File", $entryProbe,
                "-SessionFile", $fakeSession,
                "-OutputPath", $reportPath,
                "-SkipStage5", "-TimeoutSeconds", "2", "-Json"
            )
        $firstError = @($run.output -split "`n" | Where-Object {
                $_ -match 'not recognized|Cannot find|does not exist|CommandNotFound|找不到|不存在|无法识别|Missing'
            } | Select-Object -First 1)
        $ladder.Add([pscustomobject]@{
                step = ($i + 1)
                added = $relative
                filesPresent = @($ladderFiles[0..$i])
                exitCode = $run.exitCode
                reportWritten = (Test-Path -LiteralPath $reportPath)
                firstError = if ($firstError.Count -gt 0) { [string]$firstError[0] } else { "" }
                command = $run.command
                outputTail = (($run.output -split "`n") | Select-Object -Last 10) -join "`n"
            })
    }
}
finally {
    $env:USERPROFILE = $oldUserProfile
    $env:APPDATA = $oldAppData
    $env:HOME = $oldHome
    $env:PATH = $oldPath
    $env:MATLAB_EXE = $oldMatlabExe
}
Write-TextFile -Path $ladderPath -Text ($ladder | ConvertTo-Json -Depth 8)

# 5) Summary for the Task 2 report.
$summary = [ordered]@{
    schema = "mas-s2-prefix-evidence/1"
    createdAt = (Get-Date).ToString("o")
    head = (& git -C $repo rev-parse HEAD)
    originalFromSkill = $originalFromSkill
    originalFromProjectCwd = $originalOutside
    closureChecks = $closureChecks
    ladder = $ladder
}
Write-TextFile -Path (Join-Path $evidence "summary.json") -Text ($summary | ConvertTo-Json -Depth 10)
Write-Host ("PRE_FIX_EVIDENCE={0}" -f (Join-Path $evidence "summary.json"))
Write-Host ("originalFromSkill.exitCode={0}" -f $originalFromSkill.exitCode)
Write-Host ("originalFromProjectCwd.exitCode={0}" -f $originalOutside.exitCode)
