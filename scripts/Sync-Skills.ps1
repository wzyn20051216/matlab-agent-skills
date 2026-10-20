<#
.SYNOPSIS
把仓库内的 MATLAB skills 同步到本机 skills 目录。

.DESCRIPTION
安全策略（第一阶段 P0 重构后）：
1. 先算目录指纹再决定动作：一致则完全跳过（幂等，重复执行零写入）。
2. 目标目录存在但内容不同时，区分“本项目管理的目录”（记录在
   .matlab-agent-skills-manifest.json）与“外来目录”。外来目录默认不动，
   只在显式 -Force 时才覆盖。
3. 覆盖前先整目录备份，替换通过暂存目录完成；失败可由备份还原。
4. -DryRun 只输出计划，不写任何文件。

.PARAMETER BackupRoot
备份根目录。默认 <SkillRoot>/.matlab-agent-skills/backups。
.PARAMETER SkillRoot
显式指定技能目录；省略时使用当前 Windows/Linux/WSL 用户的 .agents/skills。
#>
[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$SkillRoot,
    [string]$BackupRoot,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$Prune,
    [switch]$Strict
)

$ErrorActionPreference = "Stop"

$corePath = Join-Path $PSScriptRoot "MatlabAgentSkills.Core.psm1"
if (-not (Test-Path -LiteralPath $corePath)) {
    throw "缺少核心模块: $corePath"
}
Import-Module -Name $corePath -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'MatlabAgentSkills.SkillInstallation.psm1') -Force -DisableNameChecking

if (-not $RepositoryRoot) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}
$RepositoryRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RepositoryRoot)

$installation = Resolve-MasSkillInstallation -SkillRoot $SkillRoot
$SkillRoot = Assert-MasSkillRootPath -SkillRoot $installation.skillRoot

if (-not $BackupRoot) {
    $BackupRoot = Join-Path $SkillRoot ".matlab-agent-skills\backups"
}

$sourceRoot = Join-Path $RepositoryRoot "skills"
if (-not (Test-Path -LiteralPath $sourceRoot)) {
    throw "Skills source folder not found: $sourceRoot"
}

Write-Step "同步 skills: $sourceRoot -> $SkillRoot"
if ($DryRun) { Write-Info "[DryRun] 不会写入任何文件" }

$manifest = Read-SkillManifest -SkillRoot $SkillRoot
if ((Test-Path -LiteralPath $manifest.Path) -and -not $manifest.Exists) {
    throw '现有技能清单无法解析，拒绝改写；请先人工复核清单或选择新的 -SkillRoot。'
}
if ($manifest.Exists -and $manifest.Skills.Count -gt 0) {
    # 不把其他仓库的条目带入本次同步，避免重写 owner 后被本仓卸载器误删。
    $rawManifest = Read-JsonConfig -Path $manifest.Path
    $owner = if ($rawManifest.Contains('repository')) { [string]$rawManifest['repository'] } else { '' }
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [StringComparison]::OrdinalIgnoreCase
    } else { [StringComparison]::Ordinal }
    if (-not $owner -or -not [string]::Equals(
            [IO.Path]::GetFullPath($owner).TrimEnd([char[]]'\/'),
            $RepositoryRoot.TrimEnd([char[]]'\/'), $comparison)) {
        throw '非空技能清单归属其他仓库或缺少归属，拒绝同步；-Force 不接管。请使用原仓库、选择新的 -SkillRoot，或人工复核迁移。'
    }
}
if (-not $DryRun -and -not (Test-Path -LiteralPath $SkillRoot)) {
    New-Item -ItemType Directory -Force -Path $SkillRoot | Out-Null
}
$managedSkills = $manifest.Skills
$session = $null
if (-not $DryRun) {
    $session = New-BackupSession -Root $BackupRoot -Reason "sync-skills"
    Write-Info "备份目录（仅在发生变更时创建）: $($session.Directory)"
}

$results = New-Object System.Collections.Generic.List[object]
$conflicts = New-Object System.Collections.Generic.List[string]
$failed = $false

$sourceDirectories = @(Get-ChildItem -LiteralPath $sourceRoot -Directory -Filter "matlab-*" | Sort-Object Name)
if ($sourceDirectories.Count -eq 0) {
    throw "仓库里没有匹配 matlab-* 的 skill 目录: $sourceRoot"
}

try {
    foreach ($source in $sourceDirectories) {
        $destination = Join-Path $SkillRoot $source.Name
        $isManaged = $managedSkills.Contains($source.Name)

        try {
            $destination = Assert-MasManagedSkillPath -SkillRoot $SkillRoot -Name $source.Name
            $result = Sync-SkillDirectory -Name $source.Name -Source $source.FullName -Destination $destination `
                -IsManaged $isManaged -Session $session -BackupRoot $BackupRoot -Force:$Force -DryRun:$DryRun
        }
        catch {
            $failed = $true
            $result = [pscustomobject]@{
                Name        = $source.Name
                Destination = $destination
                Decision    = "error"
                Changed     = $false
                Message     = $_.Exception.Message
                BackupPath  = $null
                SourceHash  = $null
                DestinationHash = $null
            }
        }

        switch ($result.Decision) {
            "conflict" {
                $conflicts.Add($source.Name)
                Write-Warning "冲突: $($source.Name) -> $destination；$($result.Message)"
            }
            "unchanged" {
                Write-Info "跳过（内容一致）: $($source.Name)"
            }
            default {
                Write-Host "  $($result.Decision): $($source.Name) -> $destination" -ForegroundColor Green
            }
        }

        # 只登记“内容已与本仓库一致”的目录，避免把外来目录误标为本项目管理。
        $adopt = $result.Decision -in @("install", "update", "unchanged")
        if ($adopt -and -not $DryRun) {
            $installedHash = Get-DirectoryTreeHash -Path $destination
            $managedSkills[$source.Name] = [ordered]@{
                hash        = $installedHash
                installedAt = (Get-Date).ToString("o")
            }
        }

        $results.Add($result)
    }

    if ($Prune) {
        $sourceNames = @($sourceDirectories | Select-Object -ExpandProperty Name)
        foreach ($managedName in @($managedSkills.Keys)) {
            if ($sourceNames -contains $managedName) { continue }
            $managedPath = Join-Path $SkillRoot $managedName
            $managedPath = Assert-MasManagedSkillPath -SkillRoot $SkillRoot -Name $managedName
            if (-not (Test-Path -LiteralPath $managedPath)) {
                $managedSkills.Remove($managedName)
                continue
            }
            $currentHash = Get-DirectoryTreeHash -Path $managedPath
            $expectedHash = $null
            if ($managedSkills[$managedName] -and $managedSkills[$managedName].hash) {
                $expectedHash = $managedSkills[$managedName].hash
            }
            if (-not $expectedHash -or $currentHash -ne $expectedHash) {
                Write-Warning "跳过清理（目录已被本地修改或缺少可信安装指纹）: $managedName"
                continue
            }
            if ($DryRun) {
                Write-Step "[DryRun] 将清理已从仓库移除的技能: $managedName"
            }
            else {
                Save-DirectoryBackupToSession -Session $session -Path $managedPath -Label $managedName | Out-Null
                Remove-Item -LiteralPath $managedPath -Recurse -Force
                Write-Host "  pruned: $managedName" -ForegroundColor Yellow
            }
            $managedSkills.Remove($managedName)
        }
    }

    $manifestPath = Write-SkillManifest -SkillRoot $SkillRoot -Skills $managedSkills `
        -RepositoryRoot $RepositoryRoot -DryRun:$DryRun

    if ($session -and -not $DryRun) { Save-BackupManifest -Session $session }
}
catch {
    $failed = $true
    if ($session -and -not $DryRun) {
        $rollback = Invoke-BackupRollback -Session $session
        Write-Warning "同步失败，已回滚 $($rollback.Actions.Count) 项"
        $rollback.Actions | ForEach-Object { Write-Info $_ }
    }
    throw
}

$summary = [pscustomobject]@{
    syncTime      = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    dryRun        = [bool]$DryRun
    sourceRoot    = $sourceRoot
    skillRoot     = $SkillRoot
    skillEnvironment = $installation
    manifestPath  = if ($DryRun) { Join-Path $SkillRoot ".matlab-agent-skills-manifest.json" } else { $manifestPath }
    backupRoot    = if ($session) { $session.Directory } else { $null }
    installed     = @($results | Where-Object { $_.Decision -eq "install" }).Count
    updated       = @($results | Where-Object { $_.Decision -eq "update" }).Count
    unchanged     = @($results | Where-Object { $_.Decision -eq "unchanged" }).Count
    conflicts     = [string[]]$conflicts.ToArray()
    failed        = $failed
    skills        = @($results | ForEach-Object {
            [pscustomobject]@{
                name       = $_.Name
                decision   = $_.Decision
                changed    = [bool]$_.Changed
                backupPath = $_.BackupPath
                message    = $_.Message
            }
        })
}

$summary | ConvertTo-Json -Depth 8

if ($Strict -and ($conflicts.Count -gt 0 -or $failed)) {
    exit 2
}
