#Requires -Version 5.1
<#
.SYNOPSIS
S2 independent acceptance A-J for installed Skill portability.

.DESCRIPTION
Runs against an isolated copy of the runtime in the temp directory. It never reads
or writes a real user-level Skill root, never modifies the repository, and never
prints a session credential.

Phases:
  A first install of all nine Skills
  B installed resource and SHA-256 parity
  C execution from a cwd outside the repository and Skill root
  D MCP session check produces a staged verdict
  E no source-repository fallback
  F repeat install is zero-write
  G failed upgrade restores the pre-upgrade tree
  H S1 credential protection still holds in the installed layout
  I uninstall leaves no payload residue
  J report and sandbox cleanup

.PARAMETER EvidenceRoot
Where the acceptance report and raw evidence are written.

.PARAMETER SkipRealProbe
Skip the real MCP session probe (phase D still records SKIP, never PASS).
#>
[CmdletBinding()]
param(
    [string]$RepositoryRoot = "",
    [string]$EvidenceRoot = "",
    [switch]$SkipRealProbe
)

$ErrorActionPreference = 'Stop'

if (-not $RepositoryRoot) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}
$repo = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $EvidenceRoot) {
    $EvidenceRoot = Join-Path (Join-Path $repo 'artifacts\s2\acceptance') $timestamp
}
$EvidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot)
if (-not (Test-Path -LiteralPath $EvidenceRoot)) {
    New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
}

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('mas-s2-acceptance-' + [guid]::NewGuid().ToString('N'))
$installerRepo = Join-Path $sandbox 'installer-repo'
$installSkillRoot = Join-Path $sandbox 'installed-skills'
$installBackup = Join-Path $sandbox 'backups'
$cleanRoot = Join-Path $sandbox 'clean-install'
$cleanSkillRoot = Join-Path $cleanRoot 'installed-skills'
$cleanProject = Join-Path $cleanRoot 'project'
$skillNames = @(
    'matlab-codegen-deploy',
    'matlab-control-optimization',
    'matlab-data-analysis',
    'matlab-orchestrator',
    'matlab-robotics-autonomy',
    'matlab-runner',
    'matlab-signal-vision-ai',
    'matlab-simulink-modeling',
    'matlab-testing-ci'
)
$checks = New-Object System.Collections.Generic.List[object]
$syntheticSecret = 'synthetic-s2-acceptance-not-a-real-credential-7f31'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Add-Check {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Status,
        [string]$Detail = "",
        [string]$Evidence = ""
    )
    $checks.Add([pscustomobject][ordered]@{
            id       = $Id
            name     = $Name
            status   = $Status
            detail   = $Detail
            evidence = $Evidence
        })
}

function Write-EvidenceText {
    param([string]$Name, [string]$Text)
    $path = Join-Path $EvidenceRoot $Name
    [IO.File]::WriteAllText($path, $Text, $utf8NoBom)
    return $path
}

function Write-EvidenceJson {
    param([string]$Name, $Object)
    $path = Join-Path $EvidenceRoot $Name
    [IO.File]::WriteAllText($path, ($Object | ConvertTo-Json -Depth 20), $utf8NoBom)
    return $path
}

function ConvertFrom-MixedJson {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $start = $Text.IndexOf('{')
    while ($start -ge 0) {
        try {
            $candidate = $Text.Substring($start)
            $value = $candidate | ConvertFrom-Json
            if ($null -ne $value) { return $value }
        }
        catch { }
        $start = $Text.IndexOf('{', $start + 1)
    }
    return $null
}

function Invoke-ChildPowerShell {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 600,
        [string]$WorkingDirectory = $sandbox
    )
    $stdout = Join-Path $sandbox (([IO.Path]::GetFileNameWithoutExtension($ScriptPath)) + '-' + [guid]::NewGuid().ToString('N') + '.out.txt')
    $stderr = [IO.Path]::ChangeExtension($stdout, '.err.txt')
    $exe = (Get-Process -Id $PID).Path
    $argumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $Arguments
    $quoted = @($argumentList | ForEach-Object { '"' + ([string]$_ -replace '"', '\"') + '"' }) -join ' '
    # Start-Process -PassThru leaves ExitCode empty after WaitForExit(ms) on this
    # host, so drive the child through System.Diagnostics.Process directly.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $quoted
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $null = $process.Start()
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) {
        try { $process.Kill() } catch { }
        $process.WaitForExit(5000) | Out-Null
    }
    $outText = if ($outTask.Wait(10000)) { [string]$outTask.Result } else { '' }
    $errText = if ($errTask.Wait(10000)) { [string]$errTask.Result } else { '' }
    $exitCode = if ($timedOut) { -1 } else { $process.ExitCode }
    [IO.File]::WriteAllText($stdout, $outText, $utf8NoBom)
    [IO.File]::WriteAllText($stderr, $errText, $utf8NoBom)
    $process.Dispose()
    [pscustomobject]@{
        ExitCode = $exitCode
        TimedOut = $timedOut
        Stdout   = $outText
        Stderr   = $errText
        OutPath  = $stdout
        ErrPath  = $stderr
        Json     = ConvertFrom-MixedJson -Text $outText
    }
}

function Invoke-SyncChild {
    param(
        [Parameter(Mandatory)][string]$InstallerRoot,
        [Parameter(Mandatory)][string]$SkillRoot,
        [Parameter(Mandatory)][string]$BackupRoot,
        [switch]$Force
    )
    $sync = Join-Path $InstallerRoot 'scripts\Sync-Skills.ps1'
    $args = @(
        '-RepositoryRoot', $InstallerRoot,
        '-SkillRoot', $SkillRoot,
        '-BackupRoot', $BackupRoot
    )
    if ($Force) { $args += '-Force' }
    return Invoke-ChildPowerShell -ScriptPath $sync -Arguments $args -WorkingDirectory $sandbox
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-TreeSnapshot {
    param([Parameter(Mandatory)][string]$Root)
    $files = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath $Root) {
        $resolved = (Resolve-Path -LiteralPath $Root).Path
        foreach ($file in @(Get-ChildItem -LiteralPath $resolved -Recurse -File -Force | Sort-Object FullName)) {
            $relative = $file.FullName.Substring($resolved.Length).TrimStart([char[]]'\/')
            $files.Add([pscustomobject][ordered]@{
                    relative = ($relative -replace '\\', '/')
                    sha256   = Get-FileSha256 -Path $file.FullName
                    length   = $file.Length
                })
        }
    }
    $canonical = (@($files | ForEach-Object { "$($_.relative)|$($_.sha256)" }) -join "`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $aggregate = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))) -replace '-', '')
    }
    finally { $sha.Dispose() }
    [pscustomobject][ordered]@{
        root            = $Root
        fileCount       = $files.Count
        aggregateSha256 = $aggregate
        files           = $files.ToArray()
    }
}

function Compare-TreeSnapshot {
    param($Before, $After)
    $differences = New-Object System.Collections.Generic.List[string]
    $beforeMap = @{}
    foreach ($entry in @($Before.files)) { $beforeMap[$entry.relative] = $entry.sha256 }
    $afterMap = @{}
    foreach ($entry in @($After.files)) { $afterMap[$entry.relative] = $entry.sha256 }
    foreach ($key in @($beforeMap.Keys | Sort-Object)) {
        if (-not $afterMap.ContainsKey($key)) { $differences.Add("missing: $key"); continue }
        if ($beforeMap[$key] -ne $afterMap[$key]) { $differences.Add("changed: $key") }
    }
    foreach ($key in @($afterMap.Keys | Sort-Object)) {
        if (-not $beforeMap.ContainsKey($key)) { $differences.Add("added: $key") }
    }
    return , $differences.ToArray()
}

function Read-PayloadConfig {
    param([Parameter(Mandatory)][string]$InstallerRoot)
    $path = Join-Path $InstallerRoot 'config\skill-payloads.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $text = [IO.File]::ReadAllText($path, $utf8NoBom)
    return ($text | ConvertFrom-Json)
}

function Get-PayloadEntries {
    param($Config, [Parameter(Mandatory)][string]$SkillName)
    if ($null -eq $Config) { return @() }
    $property = $Config.payloads.PSObject.Properties | Where-Object { $_.Name -eq $SkillName }
    if (-not $property) { return @() }
    return @($property.Value.files)
}

$startedAt = Get-Date
$sandboxCreated = $false
$cleanupSucceeded = $false
$report = $null

try {
    # ---------- setup: isolated installer source copy ----------
    New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
    $sandboxCreated = $true
    New-Item -ItemType Directory -Force -Path $installerRepo | Out-Null
    foreach ($name in @('scripts', 'schemas', 'config', 'skills')) {
        Copy-Item -LiteralPath (Join-Path $repo $name) -Destination (Join-Path $installerRepo $name) -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $cleanProject | Out-Null

    # ---------- A: first install ----------
    $install = Invoke-SyncChild -InstallerRoot $installerRepo -SkillRoot $installSkillRoot -BackupRoot $installBackup
    Write-EvidenceText -Name 'A-install.stdout.txt' -Text $install.Stdout | Out-Null
    Write-EvidenceText -Name 'A-install.stderr.txt' -Text $install.Stderr | Out-Null
    if ($null -ne $install.Json) { Write-EvidenceJson -Name 'A-install.summary.json' -Object $install.Json | Out-Null }

    $missingSkills = @($skillNames | Where-Object {
            -not (Test-Path -LiteralPath (Join-Path (Join-Path $installSkillRoot $_) 'SKILL.md') -PathType Leaf)
        })
    $installCount = if ($null -ne $install.Json) { [int]$install.Json.installed } else { -1 }
    $installOk = ($install.ExitCode -eq 0 -and $installCount -eq 9 -and $missingSkills.Count -eq 0)
    Add-Check -Id 'A' -Name 'first install of nine Skills' `
        -Status $(if ($installOk) { 'PASS' } else { 'FAIL' }) `
        -Detail ("exit={0}; installed={1}; missing={2}" -f $install.ExitCode, $installCount, ($missingSkills -join ',')) `
        -Evidence 'A-install.stdout.txt; A-install.stderr.txt; A-install.summary.json'

    # ---------- B: resource + SHA-256 parity ----------
    $payloadConfig = Read-PayloadConfig -InstallerRoot $installerRepo
    $payloadConfigSource = Join-Path $repo 'config\skill-payloads.json'
    $payloadConfigSha = if (Test-Path -LiteralPath $payloadConfigSource) { Get-FileSha256 -Path $payloadConfigSource } else { '' }
    $hashEntries = New-Object System.Collections.Generic.List[object]
    $hashFailures = New-Object System.Collections.Generic.List[string]
    $payloadTargets = @{}
    foreach ($skill in @('matlab-runner', 'matlab-orchestrator')) {
        $payloadTargets[$skill] = @{}
        foreach ($entry in @(Get-PayloadEntries -Config $payloadConfig -SkillName $skill)) {
            $target = ([string]$entry.target -replace '\\', '/')
            $source = ([string]$entry.source -replace '\\', '/')
            $payloadTargets[$skill][$target] = $source
            $installedPath = Join-Path (Join-Path $installSkillRoot $skill) $target
            $sourcePath = Join-Path $installerRepo $source
            if (-not (Test-Path -LiteralPath $installedPath -PathType Leaf)) {
                $hashFailures.Add("missing payload: $skill/$target")
                continue
            }
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                $hashFailures.Add("missing source: $source")
                continue
            }
            $installedHash = Get-FileSha256 -Path $installedPath
            $sourceHash = Get-FileSha256 -Path $sourcePath
            if ($installedHash -ne $sourceHash) { $hashFailures.Add("payload mismatch: $skill/$target") }
            $hashEntries.Add([pscustomobject][ordered]@{
                    skill = $skill; relativePath = $target; origin = $source
                    sha256 = $installedHash; sourceSha256 = $sourceHash; match = ($installedHash -eq $sourceHash)
                })
        }
    }
    foreach ($skill in $skillNames) {
        $skillRoot = Join-Path $installSkillRoot $skill
        if (-not (Test-Path -LiteralPath $skillRoot)) { $hashFailures.Add("missing skill: $skill"); continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $skillRoot -Recurse -File -Force)) {
            $relative = ($file.FullName.Substring($skillRoot.Length).TrimStart([char[]]'\/') -replace '\\', '/')
            if ($payloadTargets.ContainsKey($skill) -and $payloadTargets[$skill].ContainsKey($relative)) { continue }
            $sourcePath = Join-Path (Join-Path $installerRepo 'skills') (Join-Path $skill $relative)
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                $hashFailures.Add("unexpected file: $skill/$relative")
                continue
            }
            $installedHash = Get-FileSha256 -Path $file.FullName
            $sourceHash = Get-FileSha256 -Path $sourcePath
            if ($installedHash -ne $sourceHash) { $hashFailures.Add("skill mismatch: $skill/$relative") }
            $hashEntries.Add([pscustomobject][ordered]@{
                    skill = $skill; relativePath = $relative; origin = "skills/$skill/$relative"
                    sha256 = $installedHash; sourceSha256 = $sourceHash; match = ($installedHash -eq $sourceHash)
                })
        }
    }
    $forbidden = New-Object System.Collections.Generic.List[string]
    foreach ($skill in $skillNames) {
        $skillRoot = Join-Path $installSkillRoot $skill
        foreach ($file in @(Get-ChildItem -LiteralPath $skillRoot -Recurse -File -Force)) {
            $relative = $file.FullName.Substring($skillRoot.Length)
            if ($relative -match '(?i)[\\/]artifacts[\\/]') { $forbidden.Add("artifacts: $skill$relative") }
            if ($relative -match '(?i)(sessiondetails\.json|\.pem$|\.key$|\.pfx$|\.p12$|\.cer$|\.crt$|(^|[\\/])\.env$)') {
                $forbidden.Add("secret-like: $skill$relative")
            }
        }
    }
    $shaEvidence = [pscustomobject][ordered]@{
        schemaVersion = 1
        payloadConfig = 'config/skill-payloads.json'
        payloadConfigSha256 = $payloadConfigSha
        entries = $hashEntries.ToArray()
        failures = $hashFailures.ToArray()
        forbidden = $forbidden.ToArray()
    }
    Write-EvidenceJson -Name 'B-installed-sha256.json' -Object $shaEvidence | Out-Null
    $parityOk = ($hashFailures.Count -eq 0 -and $forbidden.Count -eq 0)
    Add-Check -Id 'B' -Name 'installed resource and SHA-256 parity' `
        -Status $(if ($parityOk) { 'PASS' } else { 'FAIL' }) `
        -Detail ("files={0}; failures={1}; forbidden={2}; payloadConfigSha256={3}" -f `
            $hashEntries.Count, $hashFailures.Count, $forbidden.Count, $payloadConfigSha) `
        -Evidence 'B-installed-sha256.json'

    # ---------- F: repeat install zero writes ----------
    $beforeRepeat = Get-TreeSnapshot -Root $installSkillRoot
    $manifestPath = Join-Path $installSkillRoot '.matlab-agent-skills-manifest.json'
    $manifestBefore = if (Test-Path -LiteralPath $manifestPath) { Get-FileSha256 -Path $manifestPath } else { '' }
    $backupSessionsBefore = @(Get-ChildItem -LiteralPath $installBackup -Directory -ErrorAction SilentlyContinue).Count
    $repeat = Invoke-SyncChild -InstallerRoot $installerRepo -SkillRoot $installSkillRoot -BackupRoot $installBackup
    Write-EvidenceText -Name 'F-repeat.stdout.txt' -Text $repeat.Stdout | Out-Null
    Write-EvidenceText -Name 'F-repeat.stderr.txt' -Text $repeat.Stderr | Out-Null
    if ($null -ne $repeat.Json) { Write-EvidenceJson -Name 'F-repeat.summary.json' -Object $repeat.Json | Out-Null }
    $afterRepeat = Get-TreeSnapshot -Root $installSkillRoot
    $repeatDiff = Compare-TreeSnapshot -Before $beforeRepeat -After $afterRepeat
    $manifestAfter = if (Test-Path -LiteralPath $manifestPath) { Get-FileSha256 -Path $manifestPath } else { '' }
    $backupSessionsAfter = @(Get-ChildItem -LiteralPath $installBackup -Directory -ErrorAction SilentlyContinue).Count
    $repeatUnchanged = if ($null -ne $repeat.Json) { [int]$repeat.Json.unchanged } else { -1 }
    $repeatOk = ($repeat.ExitCode -eq 0 -and $repeatUnchanged -eq 9 -and $repeatDiff.Count -eq 0 -and
        $manifestBefore -eq $manifestAfter -and $backupSessionsBefore -eq $backupSessionsAfter)
    Add-Check -Id 'F' -Name 'repeat install is zero-write' `
        -Status $(if ($repeatOk) { 'PASS' } else { 'FAIL' }) `
        -Detail ("exit={0}; unchanged={1}; diff={2}; manifestEqual={3}; backupSessions={4}->{5}" -f `
            $repeat.ExitCode, $repeatUnchanged, $repeatDiff.Count, ($manifestBefore -eq $manifestAfter), `
            $backupSessionsBefore, $backupSessionsAfter) `
        -Evidence 'F-repeat.stdout.txt; F-repeat.stderr.txt; F-repeat.summary.json'

    # ---------- G: failed upgrade rollback ----------
    $beforeUpgrade = Get-TreeSnapshot -Root $installSkillRoot
    $lockedPayload = Join-Path $installSkillRoot 'matlab-runner\scripts\MatlabAgentSkills.Core.psm1'
    $sandboxSourceSkill = Join-Path $installerRepo 'skills\matlab-runner\SKILL.md'
    Add-Content -LiteralPath $sandboxSourceSkill -Value "`nacceptance-upgrade-marker`n"
    $lock = [IO.File]::Open($lockedPayload, 'Open', 'Read', 'Read')
    try {
        $upgrade = Invoke-SyncChild -InstallerRoot $installerRepo -SkillRoot $installSkillRoot -BackupRoot $installBackup
    }
    finally { $lock.Dispose() }
    Write-EvidenceText -Name 'G-upgrade.stdout.txt' -Text $upgrade.Stdout | Out-Null
    Write-EvidenceText -Name 'G-upgrade.stderr.txt' -Text $upgrade.Stderr | Out-Null
    if ($null -ne $upgrade.Json) { Write-EvidenceJson -Name 'G-upgrade.summary.json' -Object $upgrade.Json | Out-Null }
    $afterUpgrade = Get-TreeSnapshot -Root $installSkillRoot
    $upgradeDiff = Compare-TreeSnapshot -Before $beforeUpgrade -After $afterUpgrade
    $runnerResult = $null
    if ($null -ne $upgrade.Json) {
        $runnerResult = @($upgrade.Json.skills | Where-Object { $_.name -eq 'matlab-runner' } | Select-Object -First 1)
        if ($runnerResult.Count -gt 0) { $runnerResult = $runnerResult[0] }
    }
    $stagingResidue = @(Get-ChildItem -LiteralPath $installSkillRoot -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '*.__incoming__*' }).Count
    $rollbackOk = ($upgrade.ExitCode -ne 0 -and $null -ne $runnerResult -and
        [string]$runnerResult.decision -eq 'error' -and [bool]$runnerResult.restoredFromBackup -eq $true -and
        $upgradeDiff.Count -eq 0 -and $stagingResidue -eq 0)
    Add-Check -Id 'G' -Name 'failed upgrade restores the pre-upgrade tree' `
        -Status $(if ($rollbackOk) { 'PASS' } else { 'FAIL' }) `
        -Detail ("exit={0}; decision={1}; restored={2}; diff={3}; staging={4}" -f `
            $upgrade.ExitCode, $(if ($runnerResult) { $runnerResult.decision } else { 'n/a' }), `
            $(if ($runnerResult) { $runnerResult.restoredFromBackup } else { 'n/a' }), $upgradeDiff.Count, $stagingResidue) `
        -Evidence 'G-upgrade.stdout.txt; G-upgrade.stderr.txt; G-upgrade.summary.json'

    # ---------- clean install copy with no source repository ----------
    New-Item -ItemType Directory -Force -Path $cleanRoot | Out-Null
    Copy-Item -LiteralPath $installSkillRoot -Destination $cleanSkillRoot -Recurse -Force
    New-Item -ItemType Directory -Force -Path $cleanProject | Out-Null

    # ---------- E: no source-repository fallback (module resolution) ----------
    $scriptsDir = Join-Path $cleanSkillRoot 'matlab-runner\scripts'
    $moduleScript = Join-Path $sandbox 'module-resolution.ps1'
    $moduleContent = @"
`$paths = @()
foreach (`$name in @('Acceptance', 'Execution', 'McpProbe')) {
    Import-Module (Join-Path '$scriptsDir' ("MatlabAgentSkills." + `$name + ".psm1")) -Force -DisableNameChecking
}
foreach (`$module in @(Get-Module -All | Where-Object { `$_.Name -like 'MatlabAgentSkills.*' })) { if (`$module.Path) { `$paths += `$module.Path } }
[pscustomobject]@{ count = `$paths.Count; paths = `$paths } | ConvertTo-Json
"@
    [IO.File]::WriteAllText($moduleScript, $moduleContent, (New-Object System.Text.UTF8Encoding($true)))
    $moduleRun = Invoke-ChildPowerShell -ScriptPath $moduleScript -WorkingDirectory $cleanProject
    Write-EvidenceText -Name 'E-module-resolution.stdout.txt' -Text $moduleRun.Stdout | Out-Null
    Write-EvidenceText -Name 'E-module-resolution.stderr.txt' -Text $moduleRun.Stderr | Out-Null
    $modulePaths = @()
    if ($null -ne $moduleRun.Json) { $modulePaths = @($moduleRun.Json.paths) }
    $outsideModulePaths = @($modulePaths | Where-Object {
            -not $_.StartsWith($scriptsDir, [StringComparison]::OrdinalIgnoreCase)
        })
    $moduleOk = ($moduleRun.ExitCode -eq 0 -and $null -ne $moduleRun.Json -and
        [int]$moduleRun.Json.count -ge 4 -and $outsideModulePaths.Count -eq 0)

    # ---------- D: MCP session check runs ----------
    $probeResult = $null
    $probeJson = $null
    $probeStatus = 'SKIP'
    $probeDetail = 'skipped by request'
    if (-not $SkipRealProbe) {
        $probePath = Join-Path $cleanSkillRoot 'matlab-runner\scripts\Test-MatlabMcpExistingSession.ps1'
        $probe = Invoke-ChildPowerShell -ScriptPath $probePath -Arguments @(
            '-ProjectRoot', $cleanProject, '-TimeoutSeconds', '20', '-Json'
        ) -WorkingDirectory $cleanProject -TimeoutSeconds 600
        Write-EvidenceText -Name 'D-probe.stdout.txt' -Text $probe.Stdout | Out-Null
        Write-EvidenceText -Name 'D-probe.stderr.txt' -Text $probe.Stderr | Out-Null
        $probeJson = ConvertFrom-MixedJson -Text $probe.Stdout
        if ($null -ne $probeJson) { Write-EvidenceJson -Name 'D-probe.report.json' -Object $probeJson | Out-Null }
        $probeReportPath = Join-Path $cleanProject 'artifacts\validation\acceptance\mcp_probe.json'
        if (Test-Path -LiteralPath $probeReportPath) {
            Copy-Item -LiteralPath $probeReportPath -Destination (Join-Path $EvidenceRoot 'D-probe.artifacts.json') -Force
        }
        $probeChecks = @()
        if ($null -ne $probeJson) {
            $probeChecks = @($probeJson.checks | ForEach-Object {
                    [pscustomobject][ordered]@{ id = $_.id; status = $_.status }
                })
        }
        $probeResult = [pscustomobject][ordered]@{
            exitCode      = $probe.ExitCode
            timedOut      = [bool]$probe.TimedOut
            overallStatus = $(if ($probeJson) { [string]$probeJson.overallStatus } else { $null })
            achievedLevel = $(if ($probeJson) { [string]$probeJson.achievedLevel } else { $null })
            checkCount    = $probeChecks.Count
            checks        = $probeChecks
        }
        Write-EvidenceJson -Name 'D-probe.verdict.json' -Object $probeResult | Out-Null
        if ($null -ne $probeJson -and @($probeJson.checks).Count -ge 7) {
            $probeStatus = 'PASS'
            $probeDetail = "probe produced a staged verdict: overall=$($probeJson.overallStatus), achieved=$($probeJson.achievedLevel), exit=$($probe.ExitCode)"
        }
        else {
            $probeStatus = 'FAIL'
            $probeDetail = "probe did not produce a parseable staged report (exit=$($probe.ExitCode))"
        }
    }
    Add-Check -Id 'D' -Name 'MCP session check runs from the installed Skill' `
        -Status $probeStatus -Detail $probeDetail `
        -Evidence 'D-probe.stdout.txt; D-probe.stderr.txt; D-probe.report.json; D-probe.verdict.json'

    # ---------- E: no source-repository fallback (probe output + payload text) ----------
    $fallbackHits = New-Object System.Collections.Generic.List[string]
    $repoVariants = @($repo, $installerRepo, $cleanSkillRoot, $installSkillRoot) | Where-Object { $_ }
    if ($probeResult) {
        $probeText = ''
        foreach ($name in @('D-probe.stdout.txt', 'D-probe.stderr.txt', 'D-probe.report.json', 'D-probe.artifacts.json')) {
            $path = Join-Path $EvidenceRoot $name
            if (Test-Path -LiteralPath $path) { $probeText += [IO.File]::ReadAllText($path) + "`n" }
        }
        foreach ($variant in @($repo, $installerRepo)) {
            if ($probeText.IndexOf($variant, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $fallbackHits.Add("probe output mentions source repo: $variant")
            }
        }
    }
    foreach ($skill in @('matlab-runner', 'matlab-orchestrator')) {
        foreach ($target in @($payloadTargets[$skill].Keys)) {
            $path = Join-Path (Join-Path $cleanSkillRoot $skill) $target
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $text = [IO.File]::ReadAllText($path)
            if ($text.IndexOf($repo, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $fallbackHits.Add("payload embeds source repo path: $skill/$target")
            }
        }
    }
    $noRepoInClean = -not (Test-Path -LiteralPath (Join-Path $cleanRoot 'repo'))
    $fallbackOk = ($moduleOk -and $noRepoInClean -and $fallbackHits.Count -eq 0)
    Add-Check -Id 'C' -Name 'commands run outside the repository and Skill root' `
        -Status $(if ($moduleRun.ExitCode -eq 0 -and $moduleOk) { 'PASS' } else { 'FAIL' }) `
        -Detail ("module modules={0}; outside={1}; cwd={2}" -f $modulePaths.Count, $outsideModulePaths.Count, $cleanProject) `
        -Evidence 'E-module-resolution.stdout.txt; E-module-resolution.stderr.txt; D-probe.stdout.txt'
    Add-Check -Id 'E' -Name 'no source-repository fallback' `
        -Status $(if ($fallbackOk) { 'PASS' } else { 'FAIL' }) `
        -Detail ("cleanRootHasRepo={0}; moduleOutside={1}; fallbackHits={2}" -f (-not $noRepoInClean), $outsideModulePaths.Count, $fallbackHits.Count) `
        -Evidence 'E-module-resolution.stdout.txt; D-probe.stdout.txt'

    # ---------- H: credential protection in the installed layout ----------
    $corePath = Join-Path $cleanSkillRoot 'matlab-runner\scripts\MatlabAgentSkills.Core.psm1'
    $sanitizerScript = Join-Path $sandbox 'sanitizer.ps1'
    $sanitizerContent = @"
Import-Module '$corePath' -Force -DisableNameChecking
`$text = '{"apiKey":"$syntheticSecret"}'
Protect-MasText -Text `$text
"@
    [IO.File]::WriteAllText($sanitizerScript, $sanitizerContent, (New-Object System.Text.UTF8Encoding($true)))
    $sanitizerRun = Invoke-ChildPowerShell -ScriptPath $sanitizerScript -WorkingDirectory $cleanProject
    Write-EvidenceText -Name 'H-sanitizer.stdout.txt' -Text $sanitizerRun.Stdout | Out-Null
    Write-EvidenceText -Name 'H-sanitizer.stderr.txt' -Text $sanitizerRun.Stderr | Out-Null
    $sanitizerOk = ($sanitizerRun.ExitCode -eq 0 -and
        $sanitizerRun.Stdout.IndexOf($syntheticSecret, [StringComparison]::Ordinal) -lt 0 -and
        $sanitizerRun.Stdout -match 'REDACTED')

    $realKey = $null
    $sessionFile = Join-Path $env:APPDATA 'MathWorks\MATLAB MCP Server\v1\sessionDetails.json'
    if (Test-Path -LiteralPath $sessionFile -PathType Leaf) {
        try {
            $sessionText = [IO.File]::ReadAllText($sessionFile, $utf8NoBom)
            $sessionJson = $sessionText | ConvertFrom-Json
            if ($sessionJson.PSObject.Properties.Name -contains 'apiKey') {
                $candidate = [string]$sessionJson.apiKey
                if (-not [string]::IsNullOrEmpty($candidate) -and $candidate.Length -ge 4) { $realKey = $candidate }
            }
        }
        catch { $realKey = $null }
    }
    $secretScan = [pscustomobject][ordered]@{
        sessionFilePresent = (Test-Path -LiteralPath $sessionFile -PathType Leaf)
        keyAvailable       = ($null -ne $realKey)
        filesScanned       = 0
        leaksFound         = 0
        leakFiles          = @()
    }
    if ($null -ne $realKey) {
        $leakFiles = New-Object System.Collections.Generic.List[string]
        $filesToScan = @(Get-ChildItem -LiteralPath $EvidenceRoot -Recurse -File -Force -ErrorAction SilentlyContinue)
        $probeArtifacts = Join-Path $cleanProject 'artifacts'
        if (Test-Path -LiteralPath $probeArtifacts) {
            $filesToScan += @(Get-ChildItem -LiteralPath $probeArtifacts -Recurse -File -Force -ErrorAction SilentlyContinue)
        }
        foreach ($file in $filesToScan) {
            $secretScan.filesScanned++
            try {
                $text = [IO.File]::ReadAllText($file.FullName)
                if ($text.IndexOf($realKey, [StringComparison]::Ordinal) -ge 0) {
                    $leakFiles.Add($file.FullName)
                }
            }
            catch { }
        }
        $secretScan.leaksFound = $leakFiles.Count
        $secretScan.leakFiles = $leakFiles.ToArray()
    }
    Write-EvidenceJson -Name 'H-credential-scan.json' -Object $secretScan | Out-Null
    $credentialOk = ($sanitizerOk -and $secretScan.leaksFound -eq 0)
    $credentialStatus = if ($credentialOk) { $(if ($secretScan.keyAvailable) { 'PASS' } else { 'SKIP' }) } else { 'FAIL' }
    Add-Check -Id 'H' -Name 'S1 credential protection in the installed layout' `
        -Status $credentialStatus `
        -Detail ("sanitizerRedacted={0}; sessionPresent={1}; keyAvailable={2}; scanned={3}; leaks={4}" -f `
            $sanitizerOk, $secretScan.sessionFilePresent, $secretScan.keyAvailable, $secretScan.filesScanned, $secretScan.leaksFound) `
        -Evidence 'H-sanitizer.stdout.txt; H-sanitizer.stderr.txt; H-credential-scan.json'

    # ---------- I: uninstall no residue ----------
    $removeScript = Join-Path $installerRepo 'scripts\Remove-Skills.ps1'
    $remove = Invoke-ChildPowerShell -ScriptPath $removeScript -Arguments @(
        '-RepositoryRoot', $installerRepo,
        '-SkillRoot', $installSkillRoot,
        '-BackupRoot', $installBackup
    ) -WorkingDirectory $sandbox
    Write-EvidenceText -Name 'I-uninstall.stdout.txt' -Text $remove.Stdout | Out-Null
    Write-EvidenceText -Name 'I-uninstall.stderr.txt' -Text $remove.Stderr | Out-Null
    if ($null -ne $remove.Json) { Write-EvidenceJson -Name 'I-uninstall.summary.json' -Object $remove.Json | Out-Null }
    $residualSkills = @(Get-ChildItem -LiteralPath $installSkillRoot -Directory -Filter 'matlab-*' -ErrorAction SilentlyContinue)
    $remainingPayload = New-Object System.Collections.Generic.List[string]
    foreach ($skill in $skillNames) {
        foreach ($target in @($payloadTargets[$skill].Keys)) {
            if (Test-Path -LiteralPath (Join-Path (Join-Path $installSkillRoot $skill) $target)) {
                $remainingPayload.Add("$skill/$target")
            }
        }
    }
    $removedCount = if ($remove.Json) { @($remove.Json.removed).Count } else { -1 }
    $preservedCount = if ($remove.Json) { @($remove.Json.preserved).Count } else { -1 }
    $uninstallOk = ($remove.ExitCode -eq 0 -and $removedCount -eq 9 -and $preservedCount -eq 0 -and
        $residualSkills.Count -eq 0 -and $remainingPayload.Count -eq 0)
    Add-Check -Id 'I' -Name 'uninstall leaves no payload residue' `
        -Status $(if ($uninstallOk) { 'PASS' } else { 'FAIL' }) `
        -Detail ("exit={0}; removed={1}; preserved={2}; residualSkills={3}; residualPayload={4}" -f `
            $remove.ExitCode, $removedCount, $preservedCount, $residualSkills.Count, $remainingPayload.Count) `
        -Evidence 'I-uninstall.stdout.txt; I-uninstall.stderr.txt; I-uninstall.summary.json'

    # ---------- J: cleanup ----------
    if (Test-Path -LiteralPath $sandbox) {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction Stop
    }
    $cleanupSucceeded = -not (Test-Path -LiteralPath $sandbox)
    Add-Check -Id 'J' -Name 'sandbox cleanup' `
        -Status $(if ($cleanupSucceeded) { 'PASS' } else { 'FAIL' }) `
        -Detail ("sandboxRemoved={0}" -f $cleanupSucceeded) `
        -Evidence ''
}
catch {
    Add-Check -Id 'X' -Name 'acceptance harness exception' -Status 'FAIL' `
        -Detail $_.Exception.Message -Evidence ''
}
finally {
    if ($sandboxCreated -and (Test-Path -LiteralPath $sandbox) -and -not $cleanupSucceeded) {
        try { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

$finishedAt = Get-Date
$pass = @($checks | Where-Object { $_.status -eq 'PASS' }).Count
$fail = @($checks | Where-Object { $_.status -eq 'FAIL' }).Count
$skip = @($checks | Where-Object { $_.status -eq 'SKIP' }).Count
$overall = if ($fail -gt 0) { 'FAIL' } elseif ($skip -gt 0) { 'SKIP' } else { 'PASS' }

$gitHead = ''
$gitBranch = ''
try {
    $gitHead = (git -C $repo rev-parse HEAD 2>$null)
    $gitBranch = (git -C $repo rev-parse --abbrev-ref HEAD 2>$null)
}
catch { }

$report = [pscustomobject][ordered]@{
    schemaVersion = 1
    task = 'S2 independent acceptance A-J'
    startedAt = $startedAt.ToString('o')
    finishedAt = $finishedAt.ToString('o')
    repository = $repo
    gitHead = $gitHead
    gitBranch = $gitBranch
    evidenceRoot = $EvidenceRoot
    sandboxRoot = $sandbox
    sandboxRemoved = $cleanupSucceeded
    scope = 'isolated simulated installation; not a real user-level Skills directory'
    realUserRootTouched = $false
    overallStatus = $overall
    summary = [pscustomobject][ordered]@{ pass = $pass; fail = $fail; skip = $skip; total = $checks.Count }
    checks = $checks.ToArray()
    limitations = @(
        'A passing probe means the staged check produced a verdict; the per-stage PASS/FAIL/SKIP is recorded verbatim.',
        'No session credential value is written to any evidence file or printed.',
        'The sandbox is a simulated installation on the temp drive, not a real user machine installation.'
    )
}
$reportPath = Write-EvidenceJson -Name 'acceptance-report.json' -Object $report

$summaryLines = New-Object System.Collections.Generic.List[string]
$summaryLines.Add('# S2 independent acceptance A-J')
$summaryLines.Add('')
$summaryLines.Add("- overall: **$overall**")
$summaryLines.Add("- checks: $pass PASS / $fail FAIL / $skip SKIP")
$summaryLines.Add("- repository: $repo")
$summaryLines.Add("- git: $gitBranch @ $gitHead")
$summaryLines.Add("- scope: isolated simulated installation; no real user-level Skill directory was read or written")
$summaryLines.Add('')
$summaryLines.Add('| id | check | status | detail |')
$summaryLines.Add('|---|---|---|---|')
foreach ($check in $checks) {
    $summaryLines.Add("| $($check.id) | $($check.name) | $($check.status) | $($check.detail) |")
}
$summaryLines.Add('')
$summaryLines.Add('Raw evidence: A-install.*, B-installed-sha256.json, D-probe.*, E-module-resolution.*, F-repeat.*, G-upgrade.*, H-*, I-uninstall.*, acceptance-report.json')
Write-EvidenceText -Name 'summary.md' -Text ($summaryLines -join "`n") | Out-Null

Write-Host ("OVERALL={0} PASS={1} FAIL={2} SKIP={3}" -f $overall, $pass, $fail, $skip)
Write-Host ("REPORT={0}" -f $reportPath)
if ($fail -gt 0) { exit 1 }
if ($skip -gt 0) { exit 2 }
exit 0
