<#
.SYNOPSIS
备份并卸载本项目安装且未被修改的受管 MATLAB 技能。
.DESCRIPTION
只处理与当前仓库匹配的安装清单。保留外来技能、本地修改、链接及无法核对
指纹的目录；不支持强制删除。-DryRun 不写文件。
#>
[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$SkillRoot,
    [string]$BackupRoot,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MatlabAgentSkills.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'MatlabAgentSkills.SkillInstallation.psm1') -Force -DisableNameChecking
if (-not $RepositoryRoot) { $RepositoryRoot = Split-Path -Parent $PSScriptRoot }
$RepositoryRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RepositoryRoot)
$installation = Resolve-MasSkillInstallation -SkillRoot $SkillRoot
$SkillRoot = Assert-MasSkillRootPath -SkillRoot $installation.skillRoot
if (-not $BackupRoot) { $BackupRoot = Join-Path $SkillRoot '.matlab-agent-skills/backups' }
$BackupRoot = [IO.Path]::GetFullPath($BackupRoot)
$manifest = Read-SkillManifest -SkillRoot $SkillRoot
$removed = New-Object 'System.Collections.Generic.List[string]'
$preserved = New-Object 'System.Collections.Generic.List[object]'
$session = $null
if ($manifest.Exists) {
    $raw = Read-JsonConfig -Path $manifest.Path
    $owner = if ($raw.Contains('repository')) { [string]$raw['repository'] } else { '' }
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [StringComparison]::OrdinalIgnoreCase
    } else { [StringComparison]::Ordinal }
    if (-not $owner -or -not [string]::Equals([IO.Path]::GetFullPath($owner).TrimEnd([char[]]'\/'),
            $RepositoryRoot.TrimEnd([char[]]'\/'), $comparison)) {
        throw '安装清单未指向当前仓库，拒绝卸载；请使用原安装仓库的 -RepositoryRoot。'
    }
    $session = New-BackupSession -Root $BackupRoot -Reason 'remove-skills'
    $eligible = New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in @($manifest.Skills.Keys)) {
        try {
            $target = Assert-MasManagedSkillPath -SkillRoot $SkillRoot -Name $name
            $targetPrefix = $target.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
            if ([string]::Equals($BackupRoot, $target, $comparison) -or $BackupRoot.StartsWith($targetPrefix, $comparison)) {
                throw '备份目录不能位于待卸载技能内。'
            }
            if (-not (Test-Path -LiteralPath $target)) {
                $preserved.Add([pscustomobject]@{ name = $name; reason = '目录已不存在' })
                continue
            }
            $expected = [string]$manifest.Skills[$name].hash
            $actual = Get-DirectoryTreeHash -Path $target
            if (-not $expected -or $actual -ne $expected) { throw '目录已修改或缺少可信安装指纹' }
            $eligible.Add([pscustomobject]@{ name = $name; path = $target; hash = $expected })
        } catch {
            $preserved.Add([pscustomobject]@{ name = $name; reason = $_.Exception.Message })
        }
    }
    try {
        if (-not $DryRun -and $eligible.Count -gt 0) {
            Save-FileBackupToSession -Session $session -Path $manifest.Path -Label 'skill-manifest' | Out-Null
        }
        foreach ($entry in $eligible) {
            if (-not $DryRun) {
                $target = Assert-MasManagedSkillPath -SkillRoot $SkillRoot -Name $entry.name
                if ((Get-DirectoryTreeHash -Path $target) -ne $entry.hash) { throw "卸载前目录内容改变: $target" }
                Save-DirectoryBackupToSession -Session $session -Path $target -Label $entry.name | Out-Null
                # target 已验证为 SkillRoot 内直接子目录且无链接；删除前备份已完成。
                Remove-Item -LiteralPath $target -Recurse -Force
                $manifest.Skills.Remove($entry.name)
            }
            $removed.Add($entry.name)
        }
        if (-not $DryRun -and $removed.Count -gt 0) {
            Write-SkillManifest -SkillRoot $SkillRoot -Skills $manifest.Skills -RepositoryRoot $RepositoryRoot | Out-Null
            Save-BackupManifest -Session $session
        }
    } catch {
        if (-not $DryRun -and $session) {
            Invoke-BackupRollback -Session $session | Out-Null
            Save-BackupManifest -Session $session
        }
        throw
    }
}
[pscustomobject]@{
    dryRun = [bool]$DryRun
    skillRoot = $SkillRoot
    skillEnvironment = $installation
    manifestExists = [bool]$manifest.Exists
    removed = $removed.ToArray()
    preserved = $preserved.ToArray()
    backupRoot = if ($session -and $session.Records.Count -gt 0) { $session.Directory } else { $null }
} | ConvertTo-Json -Depth 8
