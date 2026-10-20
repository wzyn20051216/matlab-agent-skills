<#
.SYNOPSIS
解析当前运行环境的共享技能目录，并校验受管目录的文件系统边界。
.DESCRIPTION
CLI 与 Desktop 共用当前系统用户的 .agents/skills；不根据客户端是否在 PATH
推断发现能力。旧版 .codex/skills 或 CODEX_HOME/skills 仅用于诊断，可显式覆盖。
#>

function Resolve-MasSkillInstallation {
    <#
    .SYNOPSIS
    返回共享技能目录；UserHome、Runtime、CodexHome 可注入以测试环境隔离。
    #>
    [CmdletBinding()]
    param(
        [string]$SkillRoot,
        [string]$UserHome,
        [ValidateSet('Auto', 'Windows', 'Linux', 'WSL')][string]$Runtime = 'Auto',
        [string]$CodexHome = $env:CODEX_HOME
    )
    if ($Runtime -eq 'Auto') {
        $Runtime = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            'Windows'
        } elseif ($env:WSL_DISTRO_NAME -or $env:WSL_INTEROP) { 'WSL' } else { 'Linux' }
    }
    if (-not $UserHome) {
        $UserHome = if ($Runtime -eq 'Windows') { $env:USERPROFILE } else { $env:HOME }
        if (-not $UserHome) { $UserHome = [Environment]::GetFolderPath('UserProfile') }
    }
    $nativePattern = if ($Runtime -eq 'Windows') { '^(?:[A-Za-z]:[\\/]|\\\\)' } else { '^/' }
    if (-not $UserHome -or $UserHome -notmatch $nativePattern) {
        throw "无法确定 $Runtime 的本机用户目录；请检查当前进程的用户环境。"
    }
    $separator = if ($Runtime -eq 'Windows') { '\' } else { '/' }
    $nativeHome = $UserHome.TrimEnd([char[]]'\/')
    $defaultRoot = $nativeHome + $separator + '.agents' + $separator + 'skills'
    $legacyRoot = $nativeHome + $separator + '.codex' + $separator + 'skills'
    if ($CodexHome -and $CodexHome -match $nativePattern) {
        $legacyRoot = $CodexHome.TrimEnd([char[]]'\/') + $separator + 'skills'
    }
    $explicit = -not [string]::IsNullOrWhiteSpace($SkillRoot)
    if ($explicit) {
        # 显式路径由当前 PowerShell 解析，不把 Windows 路径自动翻译成 WSL 路径。
        if ($Runtime -ne 'Windows' -and $SkillRoot -match '^[A-Za-z]:[\\/]') {
            throw '当前是 Linux/WSL 进程，-SkillRoot 必须使用当前系统路径。'
        }
        $resolvedRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SkillRoot)
    } else { $resolvedRoot = $defaultRoot }
    [pscustomobject]@{
        skillRoot = $resolvedRoot
        userHome = $nativeHome
        runtime = $Runtime
        source = if ($explicit) { 'explicit' } else { 'native-user-shared' }
        legacySkillRoot = $legacyRoot
    }
}

function Assert-MasSkillRootPath {
    <#
    .SYNOPSIS
    在创建目录或写清单之前验证根目录及祖先，避免穿过链接写入其他目录。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SkillRoot)
    $fullRoot = [IO.Path]::GetFullPath($SkillRoot)
    $rootPath = $fullRoot.TrimEnd([char[]]'\/')
    if ($rootPath -eq ([IO.Path]::GetPathRoot($fullRoot).TrimEnd([char[]]'\/'))) {
        throw '技能目录不能是文件系统根目录。'
    }
    $ancestorPath = $rootPath
    while ($ancestorPath) {
        if (Test-Path -LiteralPath $ancestorPath) {
            $item = Get-Item -LiteralPath $ancestorPath -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "技能路径包含链接，拒绝自动修改: $ancestorPath"
            }
            if (-not $item.PSIsContainer) { throw "技能路径不是目录: $ancestorPath" }
        }
        $ancestorPath = [IO.Path]::GetDirectoryName($ancestorPath)
    }
    return $rootPath
}

function Assert-MasManagedSkillPath {
    <#
    .SYNOPSIS
    验证技能是根目录的直接子目录，拒绝路径穿越及指向外部的链接。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SkillRoot,
        [Parameter(Mandatory)][string]$Name
    )
    if ($Name -notmatch '^matlab-[a-z0-9]+(?:-[a-z0-9]+)*$') {
        throw "受管技能名称不安全: $Name"
    }
    $rootPath = Assert-MasSkillRootPath -SkillRoot $SkillRoot
    $targetPath = [IO.Path]::GetFullPath((Join-Path $rootPath $Name))
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [StringComparison]::OrdinalIgnoreCase
    } else { [StringComparison]::Ordinal }
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($targetPath), $rootPath, $comparison)) {
        throw "受管技能越出指定根目录: $targetPath"
    }
    # 逐层遍历，不递归进入 junction/symlink 的目标。
    if (Test-Path -LiteralPath $targetPath) {
        $pending = New-Object 'System.Collections.Generic.Stack[string]'
        $pending.Push($targetPath)
        while ($pending.Count -gt 0) {
            $entry = Get-Item -LiteralPath $pending.Pop() -Force
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "技能目录包含链接，拒绝自动修改: $($entry.FullName)"
            }
            if ($entry.PSIsContainer) {
                foreach ($child in @(Get-ChildItem -LiteralPath $entry.FullName -Force -ErrorAction Stop)) {
                    $pending.Push($child.FullName)
                }
            }
        }
    }
    return $targetPath
}

Export-ModuleMember -Function Resolve-MasSkillInstallation, Assert-MasManagedSkillPath, Assert-MasSkillRootPath
