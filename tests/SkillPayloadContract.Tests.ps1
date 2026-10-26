# S2 static contract: the installed Skills must ship their runtime resources.
# All assertions are read-only; no user-level Skill directory is touched.
. (Join-Path $PSScriptRoot 'helpers/Assertions.ps1')

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:PayloadConfig = Join-Path $script:RepoRoot 'config/skill-payloads.json'
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

function Read-JsonUtf8 {
    param([Parameter(Mandatory)][string]$Path)
    $text = [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false)))
    return ($text | ConvertFrom-Json)
}

function Get-PayloadEntries {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SkillName
    )
    $property = $Config.payloads.PSObject.Properties | Where-Object { $_.Name -eq $SkillName }
    if (-not $property) { return @() }
    return @($property.Value.files)
}

function Get-NormalizedTargets {
    param([object[]]$Entries)
    return @($Entries | ForEach-Object { ([string]$_.target -replace '\\', '/').ToLowerInvariant() } | Sort-Object)
}

function Test-SafeRelativePath {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ([IO.Path]::IsPathRooted($Value)) { return $false }
    if ($Value -match '^[A-Za-z]:') { return $false }
    if ($Value -match '(^|[\\/])\.\.([\\/]|$)') { return $false }
    if ($Value -match '[<>:"|?*]') { return $false }
    return $true
}

Describe 'S2 payload manifest contract' {

    It 'declares a schema-versioned payload manifest' {
        (Test-Path -LiteralPath $script:PayloadConfig) | Should Be $true
        if (-not (Test-Path -LiteralPath $script:PayloadConfig)) { return }
        $config = Read-JsonUtf8 -Path $script:PayloadConfig
        ([int]$config.schemaVersion) | Should Be 1
        $names = @($config.payloads.PSObject.Properties.Name)
        ($names -contains 'matlab-runner') | Should Be $true
        ($names -contains 'matlab-orchestrator') | Should Be $true
    }

    It 'ships the complete runner probe and batch closure' {
        (Test-Path -LiteralPath $script:PayloadConfig) | Should Be $true
        if (-not (Test-Path -LiteralPath $script:PayloadConfig)) { return }
        $config = Read-JsonUtf8 -Path $script:PayloadConfig
        $entries = @(Get-PayloadEntries -Config $config -SkillName 'matlab-runner')
        $actual = @(Get-NormalizedTargets -Entries $entries)
        $expected = @($script:RunnerTargets | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object)
        ($actual -join '|') | Should Be ($expected -join '|')
    }

    It 'ships the complete orchestrator probe closure' {
        (Test-Path -LiteralPath $script:PayloadConfig) | Should Be $true
        if (-not (Test-Path -LiteralPath $script:PayloadConfig)) { return }
        $config = Read-JsonUtf8 -Path $script:PayloadConfig
        $entries = @(Get-PayloadEntries -Config $config -SkillName 'matlab-orchestrator')
        $actual = @(Get-NormalizedTargets -Entries $entries)
        $expected = @($script:OrchestratorTargets | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object)
        ($actual -join '|') | Should Be ($expected -join '|')
    }

    It 'keeps every payload source inside the repository runtime roots' {
        (Test-Path -LiteralPath $script:PayloadConfig) | Should Be $true
        if (-not (Test-Path -LiteralPath $script:PayloadConfig)) { return }
        $config = Read-JsonUtf8 -Path $script:PayloadConfig
        $failures = New-Object System.Collections.Generic.List[string]
        foreach ($skillName in @('matlab-runner', 'matlab-orchestrator')) {
            foreach ($entry in @(Get-PayloadEntries -Config $config -SkillName $skillName)) {
                $source = [string]$entry.source
                $target = [string]$entry.target
                if (-not (Test-SafeRelativePath $source)) { $failures.Add("unsafe source: $skillName -> $source") }
                if (-not (Test-SafeRelativePath $target)) { $failures.Add("unsafe target: $skillName -> $target") }
                $normalizedSource = ($source -replace '\\', '/').TrimStart('/')
                if ($normalizedSource -notmatch '^(scripts|schemas|config)/') {
                    $failures.Add("source outside runtime roots: $source")
                }
                $normalizedTarget = ($target -replace '\\', '/').TrimStart('/')
                if ($normalizedTarget -notmatch '^(scripts|schemas|config)/') {
                    $failures.Add("target outside runtime roots: $skillName -> $target")
                }
                if ($normalizedSource -match '(^|/)(artifacts|tests|docs|skills)/') {
                    $failures.Add("source outside installable runtime: $source")
                }
                if ($normalizedSource -match '(?i)(sessiondetails\.json|\.pem$|\.key$|\.pfx$|\.cer$|(^|/)\.env$)') {
                    $failures.Add("secret-like source: $source")
                }
                if (-not (Test-Path -LiteralPath (Join-Path $script:RepoRoot $source))) {
                    $failures.Add("missing source: $source")
                }
                $sourceSkill = Join-Path $script:RepoRoot ("skills/" + $skillName)
                if (Test-Path -LiteralPath (Join-Path $sourceSkill $target)) {
                    $failures.Add("target collides with skill source: $skillName/$target")
                }
            }
        }
        ($failures -join '; ') | Should Be ''
    }

    It 'does not commit a duplicate probe implementation inside skills/' {
        $duplicates = @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'skills') -Recurse -File -Force |
                Where-Object { $_.Name -in @('Test-MatlabMcpExistingSession.ps1', 'MatlabAgentSkills.Core.psm1', 'MatlabAgentSkills.McpProbe.psm1') })
        @($duplicates).Count | Should Be 0
    }

    It 'keeps all nine skills present with SKILL.md' {
        foreach ($skill in $script:Skills) {
            $skillFile = Join-Path $script:RepoRoot ("skills/$skill/SKILL.md")
            (Test-Path -LiteralPath $skillFile) | Should Be $true
        }
    }
}

Describe 'S2 skill documentation reference contract' {

    It 'uses a skill-root resolution rule instead of caller-cwd scripts for runner and orchestrator' {
        $runner = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'skills/matlab-runner/SKILL.md')
        $orchestrator = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'skills/matlab-orchestrator/SKILL.md')
        ($runner -match '(?i)skill root') | Should Be $true
        ($runner -match '\$skillRoot') | Should Be $true
        ($orchestrator -match '(?i)skill root') | Should Be $true
        ($orchestrator -match '\$skillRoot') | Should Be $true
        ($runner -match 'Join-Path \$skillRoot ''scripts\\Test-MatlabMcpExistingSession\.ps1''') | Should Be $true
        ($orchestrator -match 'Join-Path \$skillRoot ''scripts\\Test-MatlabMcpExistingSession\.ps1''') | Should Be $true
    }

    It 'does not present repository-relative PowerShell scripts as installed commands' {
        $failures = New-Object System.Collections.Generic.List[string]
        foreach ($skill in $script:Skills) {
            $root = Join-Path $script:RepoRoot ("skills/$skill")
            foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.md' -Force)) {
                $lines = @(Get-Content -LiteralPath $file.FullName)
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    $line = $lines[$i]
                    if ($line -match '(?:-File|&)\s+\.\\scripts\\') {
                        $failures.Add("$($file.FullName):$($i + 1): $line")
                    }
                    if ($line -match '^(?:\s*)powershell\b.*-File\s+(?!\$skillRoot|<skill-root>)') {
                        $failures.Add("$($file.FullName):$($i + 1): unanchored -File: $line")
                    }
                }
            }
        }
        ($failures -join "`n") | Should Be ''
    }

    It 'does not reference the removed STM32 deployment document or repository-only docs' {
        $failures = New-Object System.Collections.Generic.List[string]
        foreach ($skill in $script:Skills) {
            $root = Join-Path $script:RepoRoot ("skills/$skill")
            foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.md' -Force)) {
                $text = Get-Content -Raw -LiteralPath $file.FullName
                if ($text -match 'stm32-deployment-chain\.md') { $failures.Add("$($file.FullName): missing STM32 reference") }
                if ($text -match 'docs/MATLAB_DESKTOP_STARTUP_ZH\.md') { $failures.Add("$($file.FullName): repository docs reference") }
            }
        }
        ($failures -join '; ') | Should Be ''
    }

    It 'marks repository-only setup and smoke-test scripts as developer operations' {
        $runner = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'skills/matlab-runner/SKILL.md')
        $ladder = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'skills/matlab-runner/references/mcp-readiness-ladder.md')
        (($runner + "`n" + $ladder) -match '(?i)developer') | Should Be $true
        ($runner -match 'Test-MatlabSkills\.ps1') | Should Be $true
        ($runner -match '(?i)(not shipped|repository-only|developer)') | Should Be $true
    }

    It 'resolves every references/, tests/ and scripts/ link inside the skill or its siblings' {
        $failures = New-Object System.Collections.Generic.List[string]
        $pattern = '(?<prefix>(?:references|tests|scripts)/[A-Za-z0-9._-]+\.(?:md|m|ps1))'
        foreach ($skill in $script:Skills) {
            $root = Join-Path $script:RepoRoot ("skills/$skill")
            foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.md' -Force)) {
                $lines = @(Get-Content -LiteralPath $file.FullName)
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    foreach ($match in [regex]::Matches($lines[$i], $pattern)) {
                        $relative = $match.Groups['prefix'].Value
                        $candidates = @(
                            (Join-Path $root $relative),
                            (Join-Path $script:RepoRoot $relative)
                        )
                        foreach ($sibling in $script:Skills) {
                            $candidates += (Join-Path $script:RepoRoot ("skills/$sibling/$relative"))
                        }
                        $exists = $false
                        foreach ($candidate in $candidates) {
                            if (Test-Path -LiteralPath $candidate) { $exists = $true; break }
                        }
                        if (-not $exists) {
                            $failures.Add("$($file.FullName):$($i + 1): $relative")
                        }
                    }
                }
            }
        }
        ($failures -join "`n") | Should Be ''
    }

    It 'keeps repository-only build examples out of installed skill instructions' {
        $failures = New-Object System.Collections.Generic.List[string]
        foreach ($skill in $script:Skills) {
            $root = Join-Path $script:RepoRoot ("skills/$skill")
            foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.md' -Force)) {
                $lines = @(Get-Content -LiteralPath $file.FullName)
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match 'matlab/boost/models') { $failures.Add("$($file.FullName):$($i + 1): repo model example") }
                    if ($lines[$i] -match 'C:\\Users\\|C:\\codex_build') { $failures.Add("$($file.FullName):$($i + 1): machine-specific path") }
                }
            }
        }
        ($failures -join "`n") | Should Be ''
    }
}
