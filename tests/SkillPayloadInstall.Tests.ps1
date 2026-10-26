# S2 install-time acceptance: the installed Skills must carry their runtime payload.
# Every fixture lives under the system temp directory; the real user Skill root is never touched.
. (Join-Path $PSScriptRoot 'helpers/Assertions.ps1')

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:SyncScript = Join-Path $script:RepoRoot 'scripts/Sync-Skills.ps1'
$script:RemoveScript = Join-Path $script:RepoRoot 'scripts/Remove-Skills.ps1'
$script:PayloadConfig = Join-Path $script:RepoRoot 'config/skill-payloads.json'
$script:Skills = @(
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
$script:RunnerTargets = @(
    'scripts/Test-MatlabMcpExistingSession.ps1',
    'scripts/Invoke-MatlabBatch.ps1',
    'scripts/MatlabAgentSkills.Core.psm1',
    'scripts/MatlabAgentSkills.Acceptance.psm1',
    'scripts/MatlabAgentSkills.Execution.psm1',
    'scripts/MatlabAgentSkills.McpProbe.psm1',
    'scripts/MatlabAgentSkills.McpStdio.psm1',
    'config/mcp-server-manifest.json',
    'schemas/acceptance-report.schema.json'
)
$script:OrchestratorTargets = @(
    'scripts/Test-MatlabMcpExistingSession.ps1',
    'scripts/MatlabAgentSkills.Core.psm1',
    'scripts/MatlabAgentSkills.Acceptance.psm1',
    'scripts/MatlabAgentSkills.Execution.psm1',
    'scripts/MatlabAgentSkills.McpProbe.psm1',
    'scripts/MatlabAgentSkills.McpStdio.psm1',
    'config/mcp-server-manifest.json',
    'schemas/acceptance-report.schema.json'
)
$script:FakeApiKey = 'synthetic-s2-install-probe-not-a-real-credential'

function Read-S2Json {
    param([Parameter(Mandatory)][string]$Path)
    $text = [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false)))
    return ($text | ConvertFrom-Json)
}

function Get-S2FileHash {
    param([Parameter(Mandatory)][string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        return ([System.BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '')
    }
    finally {
        if ($stream) { $stream.Dispose() }
        $sha.Dispose()
    }
}

function New-S2Fixture {
    param([switch]$CopyRepository)
    $root = Join-Path ([IO.Path]::GetTempPath()) ('mas-s2-install-' + [guid]::NewGuid().ToString('N'))
    $repo = $script:RepoRoot
    if ($CopyRepository) {
        $repo = Join-Path $root 'repo'
        New-Item -ItemType Directory -Force -Path $repo | Out-Null
        foreach ($name in @('scripts', 'schemas', 'config', 'skills')) {
            $source = Join-Path $script:RepoRoot $name
            if (Test-Path -LiteralPath $source) {
                Copy-Item -LiteralPath $source -Destination (Join-Path $repo $name) -Recurse -Force
            }
        }
    }
    $project = Join-Path $root 'project'
    New-Item -ItemType Directory -Force -Path $project | Out-Null
    $fakeHome = Join-Path $root 'fake-home'
    New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
    [pscustomobject]@{
        Root       = $root
        Repo       = $repo
        SkillRoot  = (Join-Path $root 'installed-skills')
        Backup     = (Join-Path $root 'backups')
        Project    = $project
        FakeHome   = $fakeHome
        Session    = (Join-Path $project 'sessionDetails.test.json')
        FakeCert   = (Join-Path $project 'fake-cert.pem')
    }
}

function Remove-S2Fixture {
    param($Fixture)
    $target = [IO.Path]::GetFullPath($Fixture.Root)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    if (-not $target.StartsWith($tempPrefix) -or (Split-Path -Leaf $target) -notlike 'mas-s2-install-*') {
        throw "refusing to clean outside the temp sandbox: $target"
    }
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
}

function Get-S2Snapshot {
    param([Parameter(Mandatory)][string]$Root)
    $map = @{}
    if (-not (Test-Path -LiteralPath $Root)) { return $map }
    $resolved = (Resolve-Path -LiteralPath $Root).Path
    foreach ($file in @(Get-ChildItem -LiteralPath $resolved -Recurse -File -Force)) {
        $relative = $file.FullName.Substring($resolved.Length).TrimStart([char[]]'\/').ToLowerInvariant()
        $map[$relative] = Get-S2FileHash -Path $file.FullName
    }
    return $map
}

function Compare-S2Snapshot {
    param([hashtable]$Before, [hashtable]$After)
    $differences = New-Object System.Collections.Generic.List[string]
    foreach ($key in @($Before.Keys | Sort-Object)) {
        if (-not $After.ContainsKey($key)) { $differences.Add("missing: $key"); continue }
        if ($Before[$key] -ne $After[$key]) { $differences.Add("changed: $key") }
    }
    foreach ($key in @($After.Keys | Sort-Object)) {
        if (-not $Before.ContainsKey($key)) { $differences.Add("added: $key") }
    }
    return , $differences.ToArray()
}

function Get-S2PayloadTargets {
    param([Parameter(Mandatory)][string]$SkillName)
    if (-not (Test-Path -LiteralPath $script:PayloadConfig)) { return @() }
    $config = Read-S2Json -Path $script:PayloadConfig
    $property = $config.payloads.PSObject.Properties | Where-Object { $_.Name -eq $SkillName }
    if (-not $property) { return @() }
    return @($property.Value.files | ForEach-Object { ([string]$_.target -replace '\\', '/') })
}

function Invoke-S2Sync {
    param($Fixture, [switch]$DryRun)
    $output = & $script:SyncScript -RepositoryRoot $Fixture.Repo -SkillRoot $Fixture.SkillRoot `
        -BackupRoot $Fixture.Backup -DryRun:$DryRun 2>&1 | Out-String
    $start = $output.IndexOf('{')
    if ($start -lt 0) { throw "sync produced no JSON: $output" }
    return ($output.Substring($start) | ConvertFrom-Json)
}

function Write-S2ProbeSession {
    param($Fixture)
    [IO.File]::WriteAllText($Fixture.FakeCert, 'synthetic certificate placeholder')
    $payload = [ordered]@{
        port        = 1
        certificate = $Fixture.FakeCert
        apiKey      = $script:FakeApiKey
        pid         = $PID
    }
    [IO.File]::WriteAllText($Fixture.Session, ($payload | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-S2ChildScript {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Content
    )
    $scriptPath = Join-Path $Root ($Name + '.ps1')
    [IO.File]::WriteAllText($scriptPath, $Content, (New-Object System.Text.UTF8Encoding($true)))
    $stdout = Join-Path $Root ($Name + '.stdout.txt')
    $stderr = Join-Path $Root ($Name + '.stderr.txt')
    $exe = (Get-Process -Id $PID).Path
    $process = Start-Process -FilePath $exe `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) `
        -WorkingDirectory $Root -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout   = if (Test-Path -LiteralPath $stdout) { [IO.File]::ReadAllText($stdout) } else { '' }
        Stderr   = if (Test-Path -LiteralPath $stderr) { [IO.File]::ReadAllText($stderr) } else { '' }
        Report   = (Join-Path $Root ('artifacts/validation/matlab_mcp_existing_session_probe.json'))
    }
}

function ConvertTo-S2Literal {
    param([string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

Describe 'S2 installed Skill resource payload' {

    It 'installs every declared payload file byte-for-byte into runner and orchestrator' {
        $f = New-S2Fixture
        try {
            (Test-Path -LiteralPath $script:PayloadConfig) | Should Be $true
            if (-not (Test-Path -LiteralPath $script:PayloadConfig)) { return }
            Invoke-S2Sync -Fixture $f | Out-Null

            foreach ($pair in @(
                    @{ Skill = 'matlab-runner'; Targets = $script:RunnerTargets },
                    @{ Skill = 'matlab-orchestrator'; Targets = $script:OrchestratorTargets })) {
                $installed = Join-Path $f.SkillRoot $pair.Skill
                $declared = @(Get-S2PayloadTargets -SkillName $pair.Skill)
                (@($declared | Sort-Object) -join '|') | Should Be (@($pair.Targets | Sort-Object) -join '|')
                foreach ($target in $pair.Targets) {
                    $installedPath = Join-Path $installed $target
                    (Test-Path -LiteralPath $installedPath) | Should Be $true
                    if (-not (Test-Path -LiteralPath $installedPath)) { continue }
                    (Get-S2FileHash -Path $installedPath) | Should Be (Get-S2FileHash -Path (Join-Path $script:RepoRoot $target))
                }
            }
        }
        finally { Remove-S2Fixture $f }
    }

    It 'does not ship artifacts, session files, certificates, keys, or repository paths inside a Skill' {
        $f = New-S2Fixture
        try {
            Invoke-S2Sync -Fixture $f | Out-Null
            $violations = New-Object System.Collections.Generic.List[string]
            foreach ($skill in $script:Skills) {
                $skillPath = Join-Path $f.SkillRoot $skill
                foreach ($file in @(Get-ChildItem -LiteralPath $skillPath -Recurse -File -Force)) {
                    $relative = $file.FullName.Substring($skillPath.Length)
                    if ($relative -match '(?i)[\\/]artifacts[\\/]') { $violations.Add("artifacts: $relative") }
                    if ($relative -match '(?i)(sessiondetails\.json|\.pem$|\.key$|\.pfx$|\.cer$|(^|[\\/])\.env$)') {
                        $violations.Add("secret-like: $relative")
                    }
                }
            }
            ($violations -join '; ') | Should Be ''

            foreach ($skill in @('matlab-runner', 'matlab-orchestrator')) {
                foreach ($target in @(Get-S2PayloadTargets -SkillName $skill)) {
                    $path = Join-Path (Join-Path $f.SkillRoot $skill) $target
                    if (-not (Test-Path -LiteralPath $path)) { continue }
                    $text = [IO.File]::ReadAllText($path)
                    ($text.IndexOf($script:RepoRoot, [StringComparison]::OrdinalIgnoreCase)) | Should Be -1
                }
            }
        }
        finally { Remove-S2Fixture $f }
    }

    It 'keeps a repeat sync byte-identical, including payload and manifest' {
        $f = New-S2Fixture
        try {
            Invoke-S2Sync -Fixture $f | Out-Null
            $before = Get-S2Snapshot -Root $f.SkillRoot
            $backupSessionsBefore = @(Get-ChildItem -LiteralPath $f.Backup -Directory -ErrorAction SilentlyContinue).Count
            $summary = Invoke-S2Sync -Fixture $f
            $summary.unchanged | Should Be 9
            $differences = Compare-S2Snapshot -Before $before -After (Get-S2Snapshot -Root $f.SkillRoot)
            ($differences -join '; ') | Should Be ''
            @(Get-ChildItem -LiteralPath $f.Backup -Directory -ErrorAction SilentlyContinue).Count | Should Be $backupSessionsBefore
        }
        finally { Remove-S2Fixture $f }
    }

    It 'writes nothing for -DryRun' {
        $f = New-S2Fixture
        try {
            $summary = Invoke-S2Sync -Fixture $f -DryRun
            (Test-Path -LiteralPath $f.SkillRoot) | Should Be $false
            (Test-Path -LiteralPath $f.Backup) | Should Be $false
            @($summary.skills).Count | Should Be 9
        }
        finally { Remove-S2Fixture $f }
    }

    It 'repairs a tampered installed payload and backs up the previous copy' {
        $f = New-S2Fixture
        try {
            Invoke-S2Sync -Fixture $f | Out-Null
            $payloadPath = Join-Path $f.SkillRoot 'matlab-runner/scripts/MatlabAgentSkills.Core.psm1'
            (Test-Path -LiteralPath $payloadPath) | Should Be $true
            if (-not (Test-Path -LiteralPath $payloadPath)) { return }
            [IO.File]::AppendAllText($payloadPath, "`n# tampered-by-s2-test`n")

            $summary = Invoke-S2Sync -Fixture $f
            ($summary.updated -ge 1) | Should Be $true
            (Get-S2FileHash -Path $payloadPath) | Should Be (Get-S2FileHash -Path (Join-Path $script:RepoRoot 'scripts/MatlabAgentSkills.Core.psm1'))
            $backups = @(Get-ChildItem -LiteralPath $f.Backup -Recurse -File -Force |
                    Where-Object { (Get-Content -Raw -LiteralPath $_.FullName) -match 'tampered-by-s2-test' })
            @($backups).Count | Should Be 1
        }
        finally { Remove-S2Fixture $f }
    }

    It 'restores the pre-upgrade payload when the destination is locked' {
        $f = New-S2Fixture -CopyRepository
        try {
            Invoke-S2Sync -Fixture $f | Out-Null
            $skillPath = Join-Path $f.SkillRoot 'matlab-runner'
            $payloadPath = Join-Path $skillPath 'scripts/MatlabAgentSkills.Core.psm1'
            (Test-Path -LiteralPath $payloadPath) | Should Be $true
            if (-not (Test-Path -LiteralPath $payloadPath)) { return }

            $before = Get-S2Snapshot -Root $f.SkillRoot
            $sourceFile = Join-Path $f.Repo 'skills/matlab-runner/SKILL.md'
            [IO.File]::AppendAllText($sourceFile, "`nversion-two`n")

            $syncPath = Join-Path $f.Repo 'scripts/Sync-Skills.ps1'
            $scriptText = @(
                '$ErrorActionPreference = ''Continue'''
                '& ' + (ConvertTo-S2Literal $syncPath) + ' -RepositoryRoot ' + (ConvertTo-S2Literal $f.Repo) +
                    ' -SkillRoot ' + (ConvertTo-S2Literal $f.SkillRoot) + ' -BackupRoot ' + (ConvertTo-S2Literal $f.Backup)
                'exit $LASTEXITCODE'
            ) -join "`n"

            # Read access with share Read: hashing can still open it, while any
            # delete request (which shares none of it) fails and triggers rollback.
            $lock = [IO.File]::Open($payloadPath, 'Open', 'Read', 'Read')
            try {
                $child = Invoke-S2ChildScript -Root $f.Root -Name 'locked-upgrade' -Content $scriptText
            }
            finally { $lock.Dispose() }

            ($child.ExitCode -ne 0) | Should Be $true
            ($child.Stdout -match '"restoredFromBackup"\s*:\s*true') | Should Be $true
            ($child.Stdout -match '"decision"\s*:\s*"error"') | Should Be $true
            $differences = Compare-S2Snapshot -Before $before -After (Get-S2Snapshot -Root $f.SkillRoot)
            ($differences -join '; ') | Should Be ''
            @(Get-ChildItem -LiteralPath $f.SkillRoot -Directory -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like '*.__incoming__*' }).Count | Should Be 0
        }
        finally { Remove-S2Fixture $f }
    }

    It 'uninstalls all nine managed Skills without leaving payload residue' {
        $f = New-S2Fixture
        try {
            Invoke-S2Sync -Fixture $f | Out-Null
            $result = & $script:RemoveScript -RepositoryRoot $f.Repo -SkillRoot $f.SkillRoot `
                -BackupRoot $f.Backup | Out-String | ConvertFrom-Json
            @($result.removed).Count | Should Be 9
            @($result.preserved).Count | Should Be 0
            @(Get-ChildItem -LiteralPath $f.SkillRoot -Directory -Filter 'matlab-*' -ErrorAction SilentlyContinue).Count | Should Be 0
            $manifestPath = Join-Path $f.SkillRoot '.matlab-agent-skills-manifest.json'
            $remainingPayload = @()
            if (Test-Path -LiteralPath $manifestPath) {
                $manifest = Read-S2Json -Path $manifestPath
                @($manifest.skills.PSObject.Properties.Name | Where-Object { -not [string]::IsNullOrEmpty($_) }).Count | Should Be 0
            }
            foreach ($skill in $script:Skills) {
                foreach ($target in @(Get-S2PayloadTargets -SkillName $skill)) {
                    if (Test-Path -LiteralPath (Join-Path $f.SkillRoot (Join-Path $skill $target))) {
                        $remainingPayload += "$skill/$target"
                    }
                }
            }
            ($remainingPayload -join '; ') | Should Be ''
        }
        finally { Remove-S2Fixture $f }
    }
}

Describe 'S2 installed Skill execution without the source repository' {

    It 'keeps sanitizer behavior in the installed Core module' {
        $f = New-S2Fixture
        try {
            Invoke-S2Sync -Fixture $f | Out-Null
            $corePath = Join-Path $f.SkillRoot 'matlab-runner/scripts/MatlabAgentSkills.Core.psm1'
            (Test-Path -LiteralPath $corePath) | Should Be $true
            if (-not (Test-Path -LiteralPath $corePath)) { return }
            $scriptText = @(
                'Import-Module ' + (ConvertTo-S2Literal $corePath) + ' -Force -DisableNameChecking'
                '$text = ''{"apiKey":"' + $script:FakeApiKey + '"}'''
                'Protect-MasText -Text $text'
            ) -join "`n"
            $child = Invoke-S2ChildScript -Root $f.Root -Name 'installed-sanitizer' -Content $scriptText
            $child.ExitCode | Should Be 0
            ($child.Stdout.IndexOf($script:FakeApiKey, [StringComparison]::Ordinal)) | Should Be -1
            ($child.Stdout -match 'REDACTED') | Should Be $true
        }
        finally { Remove-S2Fixture $f }
    }

    It 'resolves every installed module from inside the Skill root' {
        $f = New-S2Fixture
        try {
            Invoke-S2Sync -Fixture $f | Out-Null
            $scriptsDir = Join-Path $f.SkillRoot 'matlab-runner/scripts'
            $scriptText = @(
                '$paths = @()'
                'foreach ($name in @(''Acceptance'', ''Execution'', ''McpProbe'', ''McpStdio'')) {'
                '    Import-Module (Join-Path ' + (ConvertTo-S2Literal $scriptsDir) + ' ("MatlabAgentSkills." + $name + ".psm1")) -Force -DisableNameChecking'
                '}'
                'foreach ($module in @(Get-Module -All | Where-Object { $_.Name -like ''MatlabAgentSkills.*'' })) { if ($module.Path) { $paths += $module.Path } }'
                '[pscustomobject]@{ count = $paths.Count; paths = $paths } | ConvertTo-Json'
            ) -join "`n"
            $child = Invoke-S2ChildScript -Root $f.Root -Name 'module-resolution' -Content $scriptText
            $child.ExitCode | Should Be 0
            $moduleReport = ($child.Stdout.TrimStart([char]0xFEFF)) | ConvertFrom-Json
            ([int]$moduleReport.count -ge 4) | Should Be $true
            $paths = @($moduleReport.paths)
            $outside = @($paths | Where-Object { -not $_.StartsWith($scriptsDir, [StringComparison]::OrdinalIgnoreCase) })
            ($outside -join '; ') | Should Be ''
        }
        finally { Remove-S2Fixture $f }
    }

    It 'runs the installed probe from a project cwd and writes artifacts outside the Skill' {
        $f = New-S2Fixture
        try {
            Invoke-S2Sync -Fixture $f | Out-Null
            Write-S2ProbeSession -Fixture $f
            $probePath = Join-Path $f.SkillRoot 'matlab-runner/scripts/Test-MatlabMcpExistingSession.ps1'
            (Test-Path -LiteralPath $probePath) | Should Be $true
            if (-not (Test-Path -LiteralPath $probePath)) { return }

            $before = Get-S2Snapshot -Root (Join-Path $f.SkillRoot 'matlab-runner')
            $scriptText = @(
                '$env:USERPROFILE = ' + (ConvertTo-S2Literal $f.FakeHome)
                '$env:HOME = ' + (ConvertTo-S2Literal $f.FakeHome)
                '$env:APPDATA = ' + (ConvertTo-S2Literal (Join-Path $f.FakeHome 'AppData/Roaming'))
                '$env:LOCALAPPDATA = ' + (ConvertTo-S2Literal (Join-Path $f.FakeHome 'AppData/Local'))
                '$env:MATLAB_EXE = ' + (ConvertTo-S2Literal (Join-Path $f.FakeHome 'no-matlab.exe'))
                '$env:PATH = (Join-Path $env:SystemRoot ''System32'')'
                '& ' + (ConvertTo-S2Literal $probePath) + ' -SessionFile ' + (ConvertTo-S2Literal $f.Session) +
                    ' -ProjectRoot ' + (ConvertTo-S2Literal $f.Project) + ' -SkipStage5 -TimeoutSeconds 2 -Json'
                'exit $LASTEXITCODE'
            ) -join "`n"
            $child = Invoke-S2ChildScript -Root $f.Project -Name 'installed-probe' -Content $scriptText

            $child.Stdout | Should Match 'mcp\.session-config'
            ($child.Stdout -match '"mcp\.session-config"[\s\S]{0,400}?"status"\s*:\s*"PASS"') | Should Be $true
            (Test-Path -LiteralPath $child.Report) | Should Be $true
            if (Test-Path -LiteralPath $child.Report) {
                $report = Read-S2Json -Path $child.Report
                $sessionCheck = @($report.checks | Where-Object { $_.id -eq 'mcp.session-config' })
                @($sessionCheck).Count | Should Be 1
                $sessionCheck[0].status | Should Be 'PASS'
                $report.overallStatus | Should Be 'FAIL'
            }
            ($child.Stdout.IndexOf($script:FakeApiKey, [StringComparison]::Ordinal)) | Should Be -1
            ($child.Stderr.IndexOf($script:FakeApiKey, [StringComparison]::Ordinal)) | Should Be -1

            $after = Get-S2Snapshot -Root (Join-Path $f.SkillRoot 'matlab-runner')
            $differences = Compare-S2Snapshot -Before $before -After $after
            ($differences -join '; ') | Should Be ''
            (Test-Path -LiteralPath (Join-Path $f.SkillRoot 'matlab-runner/artifacts')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $f.Project 'artifacts/validation')) | Should Be $true
        }
        finally { Remove-S2Fixture $f }
    }
}
