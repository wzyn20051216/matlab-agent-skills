<#
.SYNOPSIS
Phase 5.7 sync scenarios: upgrade, conflict, user-file preservation, rollback.

.DESCRIPTION
The Phase 5 installer tests already cover first install, idempotent repeat,
conflict, -Force, managed update and DryRun. This suite pins the behaviours the
Phase 5.7 review depends on but that were not yet covered:

  - a managed upgrade leaves user-added files in place and reports them
  - a failed replacement restores the previous version from the backup
  - re-running the installer is still a no-op after an upgrade

Everything runs in a temporary fixture repository and a temporary skill root.
No real user configuration is read or written.
#>
. (Join-Path $PSScriptRoot 'helpers/Assertions.ps1')

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:SyncScript = Join-Path $script:RepoRoot 'scripts/Sync-Skills.ps1'
$script:CoreModule = Join-Path $script:RepoRoot 'scripts/MatlabAgentSkills.Core.psm1'
Import-Module $script:CoreModule -Force -DisableNameChecking

function New-SyncFixture {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('mas-phase57-sync-' + [guid]::NewGuid().ToString('N'))
    $repo = Join-Path $root 'repo'
    foreach ($name in @('matlab-alpha', 'matlab-beta')) {
        $dir = Join-Path $repo "skills/$name"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'SKILL.md'), "version-one $name")
    }
    [pscustomobject]@{
        Root = $root
        Repo = $repo
        Skills = (Join-Path $root 'skills')
        Backup = (Join-Path $root 'backups')
    }
}

function Remove-SyncFixture {
    param($Fixture)
    $target = [IO.Path]::GetFullPath($Fixture.Root)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    if (-not $target.StartsWith($tempPrefix) -or (Split-Path -Leaf $target) -notlike 'mas-phase57-sync-*') {
        throw "refusing to clean outside the temp sandbox: $target"
    }
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
}

function Invoke-Sync {
    param($Fixture)
    & $script:SyncScript -RepositoryRoot $Fixture.Repo -SkillRoot $Fixture.Skills `
        -BackupRoot $Fixture.Backup | Out-String | ConvertFrom-Json
}

function Set-SkillVersion {
    param($Fixture, [string]$Name, [string]$Text)
    [IO.File]::WriteAllText((Join-Path $Fixture.Repo "skills/$Name/SKILL.md"), $Text)
}

Describe 'Phase 5.7 sync: managed upgrade keeps user files' {
    It 'upgrades the managed copy and preserves a user-added file' {
        $f = New-SyncFixture
        try {
            Invoke-Sync $f | Out-Null
            $dest = Join-Path $f.Skills 'matlab-alpha'
            [IO.File]::WriteAllText((Join-Path $dest 'custom.md'), 'user notes')
            Set-SkillVersion $f 'matlab-alpha' 'version-two matlab-alpha'

            $json = Invoke-Sync $f

            $json.updated | Should Be 1
            (Get-Content -Raw -LiteralPath (Join-Path $dest 'SKILL.md')) | Should Match 'version-two'
            (Get-Content -Raw -LiteralPath (Join-Path $dest 'custom.md')) | Should Match 'user notes'
            $entry = @($json.skills | Where-Object { $_.name -eq 'matlab-alpha' })[0]
            (@($entry.preservedUserFiles) -contains 'custom.md') | Should Be $true
        }
        finally { Remove-SyncFixture $f }
    }

    It 'still reports unchanged after the upgrade and keeps the custom file' {
        $f = New-SyncFixture
        try {
            Invoke-Sync $f | Out-Null
            $dest = Join-Path $f.Skills 'matlab-alpha'
            [IO.File]::WriteAllText((Join-Path $dest 'custom.md'), 'user notes')
            Set-SkillVersion $f 'matlab-alpha' 'version-two matlab-alpha'
            Invoke-Sync $f | Out-Null

            $json = Invoke-Sync $f

            $json.updated | Should Be 0
            $json.unchanged | Should Be 2
            (Get-Content -Raw -LiteralPath (Join-Path $dest 'custom.md')) | Should Match 'user notes'
        }
        finally { Remove-SyncFixture $f }
    }
}

Describe 'Phase 5.7 sync: failed replacement restores the previous version' {
    It 'reports an error and rebuilds missing files from the backup' {
        $f = New-SyncFixture
        try {
            Invoke-Sync $f | Out-Null
            $dest = Join-Path $f.Skills 'matlab-alpha'
            $destFile = Join-Path $dest 'SKILL.md'
            Set-SkillVersion $f 'matlab-alpha' 'version-two matlab-alpha'

            $session = New-BackupSession -Root $f.Backup -Reason 'phase57-rollback'
            $lock = [IO.File]::Open($destFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try {
                $r = Sync-SkillDirectory -Name 'matlab-alpha' `
                    -Source (Join-Path $f.Repo 'skills/matlab-alpha') -Destination $dest `
                    -IsManaged $true -Session $session
            }
            finally { $lock.Dispose() }

            $r.Decision | Should Be 'error'
            $r.RestoredFromBackup | Should Be $true
            $r.Changed | Should Be $false
            (Get-Content -Raw -LiteralPath $destFile) | Should Match 'version-one'
        }
        finally { Remove-SyncFixture $f }
    }
}

Describe 'Phase 5.7 sync: manifest ownership fence' {
    It 'refuses to take over a manifest owned by another repository' {
        $f = New-SyncFixture
        try {
            Invoke-Sync $f | Out-Null
            $manifestPath = Join-Path $f.Skills '.matlab-agent-skills-manifest.json'
            $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
            $manifest.repository = 'E:\some\other\repo'
            [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6))

            $threw = Test-Throws { Invoke-Sync $f }
            $threw | Should Be $true
            (Get-Content -Raw -LiteralPath (Join-Path $f.Skills 'matlab-alpha/SKILL.md')) | Should Match 'version-one'
        }
        finally { Remove-SyncFixture $f }
    }
}
