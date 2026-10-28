<#
.SYNOPSIS
共享技能目录解析、安装升级卸载及 Windows/WSL 隔离回归；全部在临时沙箱执行。
#>
. (Join-Path $PSScriptRoot 'helpers/Assertions.ps1')
$script:InstallationRepo = Split-Path -Parent $PSScriptRoot
$script:InstallationModule = Join-Path $script:InstallationRepo 'scripts/MatlabAgentSkills.SkillInstallation.psm1'
$script:InstallationSync = Join-Path $script:InstallationRepo 'scripts/Sync-Skills.ps1'
$script:InstallationRemove = Join-Path $script:InstallationRepo 'scripts/Remove-Skills.ps1'
Import-Module $script:InstallationModule -Force -DisableNameChecking
Import-Module (Join-Path $script:InstallationRepo 'scripts/MatlabAgentSkills.Core.psm1') -Force -DisableNameChecking

function New-InstallationSandbox {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('mas-skill-install-' + [guid]::NewGuid().ToString('N'))
    $repo = Join-Path $root 'repo'
    $source = Join-Path $repo 'skills/matlab-runner'
    New-Item -ItemType Directory -Path $source -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $source 'SKILL.md'), 'version-one')
    [pscustomobject]@{ Root = $root; Repo = $repo; Skills = (Join-Path $root 'skills'); Backup = (Join-Path $root 'backup') }
}
function Remove-InstallationSandbox {
    param($Sandbox)
    $target = [IO.Path]::GetFullPath($Sandbox.Root)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    if (-not $target.StartsWith($tempPrefix) -or (Split-Path -Leaf $target) -notlike 'mas-skill-install-*') {
        throw "测试清理路径越界: $target"
    }
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
}
function Install-SandboxSkills {
    param($Sandbox)
    & $script:InstallationSync -RepositoryRoot $Sandbox.Repo -SkillRoot $Sandbox.Skills -BackupRoot $Sandbox.Backup |
        Out-String | ConvertFrom-Json
}

Describe '技能目录解析：客户端共用与运行环境隔离' {
    It '文件指纹符合 SHA-256 标准向量且不依赖 Get-FileHash 自动加载' {
        $s = New-InstallationSandbox
        try {
            $sample = Join-Path $s.Root 'hash-vector.txt'
            [IO.File]::WriteAllText($sample, 'abc', (New-Object Text.UTF8Encoding($false)))
            (Get-FileSha256 -Path $sample) | Should Be 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD'
        } finally { Remove-InstallationSandbox $s }
    }
    It 'Windows 使用本机用户共享目录，CODEX_HOME 仅是旧目录诊断' {
        $r = Resolve-MasSkillInstallation -Runtime Windows -UserHome 'C:\Users\alice' -CodexHome 'C:\custom-codex'
        $r.skillRoot | Should Be 'C:\Users\alice\.agents\skills'
        $r.legacySkillRoot | Should Be 'C:\custom-codex\skills'
        $r.source | Should Be 'native-user-shared'
    }
    It 'WSL 使用 Linux 用户目录，不沿用 Windows CODEX_HOME' {
        $r = Resolve-MasSkillInstallation -Runtime WSL -UserHome '/home/alice' -CodexHome 'C:\Users\alice\.codex'
        $r.skillRoot | Should Be '/home/alice/.agents/skills'
        $r.legacySkillRoot | Should Be '/home/alice/.codex/skills'
    }
    It '原生 Linux 和 WSL 按当前用户分别解析' {
        (Resolve-MasSkillInstallation -Runtime Linux -UserHome '/home/researcher').skillRoot |
            Should Be '/home/researcher/.agents/skills'
    }
    It 'WSL 不接受误传的 Windows 用户目录' {
        (Test-Throws { Resolve-MasSkillInstallation -Runtime WSL -UserHome 'C:\Users\alice' }) | Should Be $true
    }
    It 'Windows 不接受误传的 Linux 用户目录' {
        (Test-Throws { Resolve-MasSkillInstallation -Runtime Windows -UserHome '/home/alice' }) | Should Be $true
    }
    It '显式 SkillRoot 优先，可兼容经验证的旧客户端目录' {
        $s = New-InstallationSandbox
        try {
            $legacy = Join-Path $s.Root '.codex/skills'
            $r = Resolve-MasSkillInstallation -SkillRoot $legacy
            $r.skillRoot | Should Be ([IO.Path]::GetFullPath($legacy))
            $r.source | Should Be 'explicit'
        } finally { Remove-InstallationSandbox $s }
    }
    It '没有 CLI 命令时仍能解析相同共享目录' {
        $previousPath = $env:PATH
        try {
            $before = Resolve-MasSkillInstallation
            $env:PATH = ''
            (Resolve-MasSkillInstallation).skillRoot | Should Be $before.skillRoot
        } finally { $env:PATH = $previousPath }
    }
    It '显式相对路径以 PowerShell 当前目录解析' {
        $s = New-InstallationSandbox
        try {
            Push-Location -LiteralPath $s.Root
            (Resolve-MasSkillInstallation -SkillRoot './custom').skillRoot | Should Be (Join-Path $s.Root 'custom')
        } finally {
            Pop-Location
            Remove-InstallationSandbox $s
        }
    }
    It 'Sync 默认写入当前用户 .agents，不写入 CODEX_HOME' {
        $s = New-InstallationSandbox
        $homeKey = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'USERPROFILE' } else { 'HOME' }
        $previousUserHome = [Environment]::GetEnvironmentVariable($homeKey)
        $previousCodex = $env:CODEX_HOME
        try {
            [Environment]::SetEnvironmentVariable($homeKey, $s.Root)
            $env:CODEX_HOME = Join-Path $s.Root 'legacy-codex'
            $r = & $script:InstallationSync -RepositoryRoot $s.Repo -BackupRoot $s.Backup | Out-String | ConvertFrom-Json
            $r.skillRoot | Should Be (Join-Path $s.Root '.agents/skills')
            (Test-Path -LiteralPath (Join-Path $s.Root '.agents/skills/matlab-runner/SKILL.md')) | Should Be $true
            (Test-Path -LiteralPath $env:CODEX_HOME) | Should Be $false
        } finally {
            [Environment]::SetEnvironmentVariable($homeKey, $previousUserHome)
            $env:CODEX_HOME = $previousCodex
            Remove-InstallationSandbox $s
        }
    }
}

Describe '技能安装生命周期与卸载保护' {
    It '首次安装后升级在同一目录更新并保留旧版备份' {
        $s = New-InstallationSandbox
        try {
            (Install-SandboxSkills $s).installed | Should Be 1
            [IO.File]::WriteAllText((Join-Path $s.Repo 'skills/matlab-runner/SKILL.md'), 'version-two')
            (Install-SandboxSkills $s).updated | Should Be 1
            (Get-Content -LiteralPath (Join-Path $s.Skills 'matlab-runner/SKILL.md') -Raw) | Should Be 'version-two'
            @((Get-ChildItem -LiteralPath $s.Backup -Filter SKILL.md -File -Recurse) |
                Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -eq 'version-one' }).Count | Should Be 1
        } finally { Remove-InstallationSandbox $s }
    }
    It '卸载未改动受管技能会备份，保留其他 MATLAB 同名域技能' {
        $s = New-InstallationSandbox
        try {
            Install-SandboxSkills $s | Out-Null
            $foreign = Join-Path $s.Skills 'matlab-other'
            New-Item -ItemType Directory -Path $foreign -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $foreign 'SKILL.md'), 'foreign')
            $r = & $script:InstallationRemove -RepositoryRoot $s.Repo -SkillRoot $s.Skills -BackupRoot $s.Backup |
                Out-String | ConvertFrom-Json
            @($r.removed).Count | Should Be 1
            (Test-Path -LiteralPath (Join-Path $s.Skills 'matlab-runner')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $foreign 'SKILL.md')) | Should Be $true
            @(Get-ChildItem -LiteralPath $r.backupRoot -Filter SKILL.md -File -Recurse).Count | Should Be 1
            (Read-SkillManifest -SkillRoot $s.Skills).Skills.Count | Should Be 0
        } finally { Remove-InstallationSandbox $s }
    }
    It '卸载保留本地修改和安装记录' {
        $s = New-InstallationSandbox
        try {
            Install-SandboxSkills $s | Out-Null
            [IO.File]::WriteAllText((Join-Path $s.Skills 'matlab-runner/SKILL.md'), 'local-edit')
            $r = & $script:InstallationRemove -RepositoryRoot $s.Repo -SkillRoot $s.Skills |
                Out-String | ConvertFrom-Json
            @($r.removed).Count | Should Be 0
            @($r.preserved).Count | Should Be 1
            (Read-SkillManifest -SkillRoot $s.Skills).Skills.Contains('matlab-runner') | Should Be $true
        } finally { Remove-InstallationSandbox $s }
    }
    It '卸载 DryRun 不改技能、清单或备份目录' {
        $s = New-InstallationSandbox
        try {
            Install-SandboxSkills $s | Out-Null
            $before = Get-DirectoryTreeHash -Path $s.Skills
            $backupBefore = Get-DirectoryTreeHash -Path $s.Backup
            $r = & $script:InstallationRemove -RepositoryRoot $s.Repo -SkillRoot $s.Skills -BackupRoot $s.Backup -DryRun |
                Out-String | ConvertFrom-Json
            @($r.removed).Count | Should Be 1
            (Get-DirectoryTreeHash -Path $s.Skills) | Should Be $before
            (Get-DirectoryTreeHash -Path $s.Backup) | Should Be $backupBefore
        } finally { Remove-InstallationSandbox $s }
    }
    It '没有安装清单时卸载零写入' {
        $s = New-InstallationSandbox
        try {
            $r = & $script:InstallationRemove -RepositoryRoot $s.Repo -SkillRoot $s.Skills |
                Out-String | ConvertFrom-Json
            @($r.removed).Count | Should Be 0
            (Test-Path -LiteralPath $s.Skills) | Should Be $false
        } finally { Remove-InstallationSandbox $s }
    }
    It '不卸载其他仓库登记的技能' {
        $s = New-InstallationSandbox
        try {
            Install-SandboxSkills $s | Out-Null
            (Test-Throws { & $script:InstallationRemove -RepositoryRoot $s.Root -SkillRoot $s.Skills }) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $s.Skills 'matlab-runner/SKILL.md')) | Should Be $true
        } finally { Remove-InstallationSandbox $s }
    }
    It '第二仓库不能接管共享 root 的非空清单，Force 也不例外' {
        $s = New-InstallationSandbox
        try {
            Install-SandboxSkills $s | Out-Null
            $otherRepo = Join-Path $s.Root 'other-repo'
            $otherSkill = Join-Path $otherRepo 'skills/matlab-data-analysis'
            New-Item -ItemType Directory -Path $otherSkill -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $otherSkill 'SKILL.md'), 'other-repository')
            $beforeSkills = Get-DirectoryTreeHash -Path $s.Skills
            $beforeBackups = Get-DirectoryTreeHash -Path $s.Backup
            (Test-Throws { & $script:InstallationSync -RepositoryRoot $otherRepo -SkillRoot $s.Skills `
                    -BackupRoot $s.Backup -Force }) | Should Be $true
            (Get-DirectoryTreeHash -Path $s.Skills) | Should Be $beforeSkills
            (Get-DirectoryTreeHash -Path $s.Backup) | Should Be $beforeBackups
            (Test-Throws { & $script:InstallationRemove -RepositoryRoot $otherRepo -SkillRoot $s.Skills }) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $s.Skills 'matlab-runner/SKILL.md')) | Should Be $true
        } finally { Remove-InstallationSandbox $s }
    }
    It 'Prune 对缺少指纹的合法清单条目保留目录和登记' {
        $s = New-InstallationSandbox
        try {
            Install-SandboxSkills $s | Out-Null
            $foreign = Join-Path $s.Skills 'matlab-foreign'
            New-Item -ItemType Directory -Path $foreign -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $foreign 'SKILL.md'), 'unverified-owner')
            $manifest = Read-SkillManifest -SkillRoot $s.Skills
            $manifest.Skills['matlab-foreign'] = @{}
            Write-SkillManifest -SkillRoot $s.Skills -Skills $manifest.Skills -RepositoryRoot $s.Repo | Out-Null
            & $script:InstallationSync -RepositoryRoot $s.Repo -SkillRoot $s.Skills -BackupRoot $s.Backup -Prune | Out-Null
            (Get-Content -LiteralPath (Join-Path $foreign 'SKILL.md') -Raw) | Should Be 'unverified-owner'
            (Read-SkillManifest -SkillRoot $s.Skills).Skills.Contains('matlab-foreign') | Should Be $true
        } finally { Remove-InstallationSandbox $s }
    }
    It '拒绝 manifest 名称路径穿越并保留越界目录' {
        $s = New-InstallationSandbox
        try {
            Install-SandboxSkills $s | Out-Null
            $manifest = Read-SkillManifest -SkillRoot $s.Skills
            $manifest.Skills['../repo'] = @{ hash = (Get-DirectoryTreeHash -Path $s.Repo) }
            Write-SkillManifest -SkillRoot $s.Skills -Skills $manifest.Skills -RepositoryRoot $s.Repo | Out-Null
            $r = & $script:InstallationRemove -RepositoryRoot $s.Repo -SkillRoot $s.Skills |
                Out-String | ConvertFrom-Json
            @($r.preserved | Where-Object name -eq '../repo').Count | Should Be 1
            (Test-Path -LiteralPath $s.Repo) | Should Be $true
        } finally { Remove-InstallationSandbox $s }
    }
    It '拒绝位于待卸载技能内部的备份位置' {
        $s = New-InstallationSandbox
        try {
            Install-SandboxSkills $s | Out-Null
            $r = & $script:InstallationRemove -RepositoryRoot $s.Repo -SkillRoot $s.Skills `
                -BackupRoot (Join-Path $s.Skills 'matlab-runner/backup') | Out-String | ConvertFrom-Json
            @($r.removed).Count | Should Be 0
            (Test-Path -LiteralPath (Join-Path $s.Skills 'matlab-runner/SKILL.md')) | Should Be $true
        } finally { Remove-InstallationSandbox $s }
    }
    It '显式校验拒绝链接目录，避免沿 junction 删除外部文件' {
        $s = New-InstallationSandbox
        $link = Join-Path $s.Skills 'matlab-runner'
        try {
            New-Item -ItemType Directory -Path $s.Skills -Force | Out-Null
            $linkKind = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'Junction' } else { 'SymbolicLink' }
            New-Item -ItemType $linkKind -Path $link -Target $s.Repo | Out-Null
            (Test-Throws { Assert-MasManagedSkillPath -SkillRoot $s.Skills -Name matlab-runner }) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $s.Repo 'skills/matlab-runner/SKILL.md')) | Should Be $true
        } finally {
            # 仅移除 junction 自身，沙箱清理不遍历链接目标。
            if (Test-Path -LiteralPath $link) { [IO.Directory]::Delete($link) }
            Remove-InstallationSandbox $s
        }
    }
    It '同步在根目录是 junction 时提前停止，不经链接写入清单' {
        $s = New-InstallationSandbox
        try {
            $linkKind = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'Junction' } else { 'SymbolicLink' }
            New-Item -ItemType $linkKind -Path $s.Skills -Target $s.Repo | Out-Null
            (Test-Throws { Install-SandboxSkills $s }) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $s.Repo '.matlab-agent-skills-manifest.json')) | Should Be $false
        } finally {
            if (Test-Path -LiteralPath $s.Skills) { [IO.Directory]::Delete($s.Skills) }
            Remove-InstallationSandbox $s
        }
    }
}

Describe 'Bootstrap 技能链路' {
    It '显式 SkillRoot 传入同步器，DryRun 不写真实或沙箱技能目录' {
        $s = New-InstallationSandbox
        try {
            $bootstrap = Join-Path $script:InstallationRepo 'scripts/Bootstrap-MatlabAgentSkills.ps1'
            $r = & $bootstrap -InstallDir $script:InstallationRepo -MatlabRoot $s.Root -SkillRoot $s.Skills `
                -BackupRoot $s.Backup -Clients generic -SkipBaseSetup -DryRun | Out-String | ConvertFrom-Json
            $r.skills.skillRoot | Should Be $s.Skills
            $r.skills.skillEnvironment.source | Should Be 'explicit'
            (Test-Path -LiteralPath $s.Skills) | Should Be $false
        } finally { Remove-InstallationSandbox $s }
    }
    It '同步器报告错误时 Bootstrap 停止，不继续客户端注册' {
        $s = New-InstallationSandbox
        try {
            New-Item -ItemType Directory -Path (Join-Path $s.Repo '.git') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $s.Repo 'scripts') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $s.Repo 'bin') -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:InstallationRepo 'scripts/MatlabAgentSkills.Core.psm1') `
                -Destination (Join-Path $s.Repo 'scripts/MatlabAgentSkills.Core.psm1')
            [IO.File]::WriteAllText((Join-Path $s.Repo 'bin/matlab-mcp-server-windows-x64.exe'), 'not-executed')
            $stub = 'param($RepositoryRoot,$SkillRoot,$BackupRoot,[switch]$Force,[switch]$DryRun); ''{"failed":true,"conflicts":[]}'''
            [IO.File]::WriteAllText((Join-Path $s.Repo 'scripts/Sync-Skills.ps1'), $stub)
            $bootstrap = Join-Path $script:InstallationRepo 'scripts/Bootstrap-MatlabAgentSkills.ps1'
            (Test-Throws { & $bootstrap -InstallDir $s.Repo -MatlabRoot $s.Root -SkillRoot $s.Skills `
                    -BackupRoot $s.Backup -Clients generic -SkipBaseSetup -DryRun }) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $s.Repo '.mcp.json')) | Should Be $false
        } finally { Remove-InstallationSandbox $s }
    }
}
