<#
.SYNOPSIS
Phase 5.8 sync scenarios for linked roots and first-time adoption.

.DESCRIPTION
The real WorkBuddy root is reached through a directory link, and the Qoder root
has drifting copies but no manifest. These tests pin the two safety properties
the Phase 5.8 plan relies on:

  - a SkillRoot below a link is refused; its physical target is accepted
  - an unmanaged drifting copy is only replaced with -Force, after a backup,
    and unrelated skills in the same root are left alone

All fixtures are temporary; no real user root is read or written.
#>
. (Join-Path $PSScriptRoot 'helpers/Assertions.ps1')

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:SyncScript = Join-Path $script:RepoRoot 'scripts/Sync-Skills.ps1'
Import-Module (Join-Path $script:RepoRoot 'scripts/MatlabAgentSkills.Core.psm1') -Force -DisableNameChecking

function New-Phase58Fixture {
    param([string[]]$Names = @('matlab-alpha', 'matlab-beta'))
    $root = Join-Path ([IO.Path]::GetTempPath()) ('mas-phase58-sync-' + [guid]::NewGuid().ToString('N'))
    $repo = Join-Path $root 'repo'
    foreach ($name in $Names) {
        $dir = Join-Path $repo "skills/$name"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'SKILL.md'), "version-one $name")
    }
    [pscustomobject]@{
        Root = $root
        Repo = $repo
        Skills = (Join-Path $root 'skills')
        Backup = (Join-Path $root 'backups')
        Physical = (Join-Path $root 'physical')
        LinkParent = (Join-Path $root 'linked')
    }
}

function Get-LatestBackupSession {
    param([string]$BackupRoot)
    $dir = Get-ChildItem -LiteralPath $BackupRoot -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $dir) { throw "no backup session under $BackupRoot" }
    $manifestPath = Join-Path $dir.FullName 'manifest.json'
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    $records = @($manifest.records | ForEach-Object {
            [pscustomobject]@{
                Kind = $_.kind; TargetPath = $_.target; BackupPath = $_.backup
                Existed = $_.existed; Data = $_.data
            }
        })
    [pscustomobject]@{
        Id = $manifest.id; Directory = $dir.FullName; Reason = $manifest.reason
        CreatedAt = $manifest.createdAt; Records = $records; ManifestPath = $manifestPath
    }
}

function Remove-Phase58Fixture {
    param($Fixture)
    $target = [IO.Path]::GetFullPath($Fixture.Root)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    if (-not $target.StartsWith($tempPrefix) -or (Split-Path -Leaf $target) -notlike 'mas-phase58-sync-*') {
        throw "refusing to clean outside the temp sandbox: $target"
    }
    # Remove the link itself, never recurse through it into the physical target.
    if (Test-Path -LiteralPath $Fixture.LinkParent) {
        & cmd.exe /c rmdir "$($Fixture.LinkParent)" | Out-Null
    }
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
}

Describe 'Phase 5.8 sync: linked root boundary' {
    It 'refuses a SkillRoot below a link and accepts the physical target' {
        $f = New-Phase58Fixture -Names @('matlab-alpha')
        try {
            New-Item -ItemType Directory -Force -Path $f.Physical | Out-Null
            New-Item -ItemType Junction -Path $f.LinkParent -Target $f.Physical | Out-Null

            $linkedSkills = Join-Path $f.LinkParent 'skills'
            $threw = Test-Throws {
                & $script:SyncScript -RepositoryRoot $f.Repo -SkillRoot $linkedSkills -BackupRoot $f.Backup | Out-Null
            }
            $threw | Should Be $true
            (Test-Path -LiteralPath (Join-Path $f.Physical 'skills/matlab-alpha')) | Should Be $false

            $physicalSkills = Join-Path $f.Physical 'skills'
            $json = & $script:SyncScript -RepositoryRoot $f.Repo -SkillRoot $physicalSkills `
                -BackupRoot $f.Backup | Out-String | ConvertFrom-Json
            $json.installed | Should Be 1
            (Test-Path -LiteralPath (Join-Path $physicalSkills 'matlab-alpha/SKILL.md')) | Should Be $true
        }
        finally { Remove-Phase58Fixture $f }
    }
}

Describe 'Phase 5.8 sync: first-time adoption of an unmanaged copy' {
    It 'conflicts without -Force, then backs up and adopts with -Force while keeping other skills' {
        $f = New-Phase58Fixture
        try {
            $alpha = Join-Path $f.Skills 'matlab-alpha'
            New-Item -ItemType Directory -Force -Path $alpha | Out-Null
            [IO.File]::WriteAllText((Join-Path $alpha 'SKILL.md'), 'USER OLD CONTENT')
            $other = Join-Path $f.Skills 'other-skill'
            New-Item -ItemType Directory -Force -Path $other | Out-Null
            [IO.File]::WriteAllText((Join-Path $other 'SKILL.md'), 'other content')

            $dry = & $script:SyncScript -RepositoryRoot $f.Repo -SkillRoot $f.Skills `
                -BackupRoot $f.Backup -DryRun | Out-String | ConvertFrom-Json
            (@($dry.conflicts) -contains 'matlab-alpha') | Should Be $true
            (Get-Content -Raw -LiteralPath (Join-Path $alpha 'SKILL.md')) | Should Match 'USER OLD CONTENT'

            $json = & $script:SyncScript -RepositoryRoot $f.Repo -SkillRoot $f.Skills `
                -BackupRoot $f.Backup -Force | Out-String | ConvertFrom-Json
            $json.updated | Should Be 1
            (Get-Content -Raw -LiteralPath (Join-Path $alpha 'SKILL.md')) | Should Match 'version-one matlab-alpha'
            (Get-Content -Raw -LiteralPath (Join-Path $other 'SKILL.md')) | Should Match 'other content'

            $backups = Get-ChildItem -LiteralPath $f.Backup -Recurse -File -Filter 'SKILL.md' -ErrorAction SilentlyContinue
            (@($backups | Where-Object { (Get-Content -Raw -LiteralPath $_.FullName) -match 'USER OLD CONTENT' })).Count | Should Be 1

            $manifest = Get-Content -Raw -LiteralPath (Join-Path $f.Skills '.matlab-agent-skills-manifest.json') | ConvertFrom-Json
            (($manifest.skills.PSObject.Properties.Name) -contains 'other-skill') | Should Be $false

            $session = Get-LatestBackupSession $f.Backup
            Invoke-BackupRollback -Session $session | Out-Null
            (Test-Path -LiteralPath (Join-Path $f.Skills '.matlab-agent-skills-manifest.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $f.Skills 'matlab-beta')) | Should Be $false
            (Get-Content -Raw -LiteralPath (Join-Path $alpha 'SKILL.md')) | Should Match 'USER OLD CONTENT'
            (Get-Content -Raw -LiteralPath (Join-Path $other 'SKILL.md')) | Should Match 'other content'
        }
        finally { Remove-Phase58Fixture $f }
    }
}

Describe 'Phase 5.8 sync: repeat sync is zero-write' {
    It 'does not rewrite the manifest or create a backup session when nothing changed' {
        $f = New-Phase58Fixture
        try {
            & $script:SyncScript -RepositoryRoot $f.Repo -SkillRoot $f.Skills `
                -BackupRoot $f.Backup | Out-Null
            $manifestPath = Join-Path $f.Skills '.matlab-agent-skills-manifest.json'
            $before = [IO.File]::ReadAllBytes($manifestPath)
            $sessionsBefore = @(Get-ChildItem -LiteralPath $f.Backup -Directory).Count

            $json = & $script:SyncScript -RepositoryRoot $f.Repo -SkillRoot $f.Skills `
                -BackupRoot $f.Backup | Out-String | ConvertFrom-Json

            $json.unchanged | Should Be 2
            ([Convert]::ToBase64String([IO.File]::ReadAllBytes($manifestPath))) | Should Be ([Convert]::ToBase64String($before))
            @(Get-ChildItem -LiteralPath $f.Backup -Directory).Count | Should Be $sessionsBefore
        }
        finally { Remove-Phase58Fixture $f }
    }
}

Describe 'Phase 5.8 sync: managed update rollback restores the manifest' {
    It 'backs up the manifest before rewriting it and restores both on rollback' {
        $f = New-Phase58Fixture
        try {
            & $script:SyncScript -RepositoryRoot $f.Repo -SkillRoot $f.Skills `
                -BackupRoot $f.Backup | Out-Null
            $manifestPath = Join-Path $f.Skills '.matlab-agent-skills-manifest.json'
            $oldBytes = [IO.File]::ReadAllBytes($manifestPath)
            [IO.File]::WriteAllText((Join-Path $f.Repo 'skills/matlab-alpha/SKILL.md'), 'version-two matlab-alpha')

            & $script:SyncScript -RepositoryRoot $f.Repo -SkillRoot $f.Skills `
                -BackupRoot $f.Backup | Out-Null
            $newBytes = [IO.File]::ReadAllBytes($manifestPath)
            ([Convert]::ToBase64String($newBytes) -ne [Convert]::ToBase64String($oldBytes)) | Should Be $true
            (Get-Content -Raw -LiteralPath (Join-Path $f.Skills 'matlab-alpha/SKILL.md')) | Should Match 'version-two'

            $session = Get-LatestBackupSession $f.Backup
            $record = @($session.Records | Where-Object { $_.Kind -eq 'file' -and $_.TargetPath -eq $manifestPath })
            $record.Count | Should Be 1

            Invoke-BackupRollback -Session $session | Out-Null
            ([Convert]::ToBase64String([IO.File]::ReadAllBytes($manifestPath))) | Should Be ([Convert]::ToBase64String($oldBytes))
            (Get-Content -Raw -LiteralPath (Join-Path $f.Skills 'matlab-alpha/SKILL.md')) | Should Match 'version-one'
        }
        finally { Remove-Phase58Fixture $f }
    }
}
