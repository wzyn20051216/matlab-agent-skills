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

function Test-MasSafePayloadRelativePath {
    <#
    .SYNOPSIS
    拒绝绝对路径、驱动器路径、ADS、通配符与任何 .. 片段。
    #>
    [CmdletBinding()]
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $normalized = $Value -replace '\\', '/'
    if ($normalized.StartsWith('/')) { return $false }
    if ($normalized -match '^[A-Za-z]:') { return $false }
    if ($normalized -match '(^|/)\.\.?(/|$)') { return $false }
    if ($normalized -match '[<>:"|?*\x00-\x1F]') { return $false }
    return $true
}

function Assert-MasContainedPayloadPath {
    <#
    .SYNOPSIS
    把清单里的相对路径解析到仓库内，并拒绝链接跳转。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$RelativePath,
        [switch]$RequireFile
    )
    if (-not (Test-MasSafePayloadRelativePath -Value $RelativePath)) {
        throw "payload 路径不安全: $RelativePath"
    }
    $rootPath = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([char[]]'\/')
    $nativeRelative = ($RelativePath -replace '\\', '/') -replace '/', [IO.Path]::DirectorySeparatorChar
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootPath $nativeRelative))
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [StringComparison]::OrdinalIgnoreCase
    } else { [StringComparison]::Ordinal }
    $prefix = $rootPath + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, $comparison)) {
        throw "payload 路径越出仓库: $RelativePath"
    }
    # 只检查仓库根以下的层级，避免把用户主目录的链接误判成 payload 问题。
    $cursor = $candidate
    while ($cursor -and $cursor.Length -ge $rootPath.Length) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "payload 路径包含链接，拒绝安装: $cursor"
            }
        }
        if ([string]::Equals($cursor, $rootPath, $comparison)) { break }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    if ($RequireFile -and -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "payload 源文件不存在: $RelativePath"
    }
    return $candidate
}

function Get-MasSkillPayloadManifest {
    <#
    .SYNOPSIS
    读取并校验 config/skill-payloads.json，返回 skill 名到文件清单的映射。

    .DESCRIPTION
    清单只允许把仓库 scripts/、schemas/、config/ 下的文件发布到已安装 Skill 的
    scripts/、schemas/、config/ 目录。任何绝对路径、..、链接、凭据类文件或与 Skill
    自带文件冲突的目标都会被拒绝。清单缺失时返回空映射，保持旧仓库检出的兼容性；
    清单存在但非法时立即失败，绝不半装。

    config/ 必须在内：Core 的 Get-McpServerManifest 固定读 <根>/config/mcp-server-manifest.json，
    且没有这份清单就拒绝启动官方 stdio server（fail closed）。不把清单发进安装副本，
    安装后的 Skill 就永远只能报"缺少发布清单"，真实 MCP 路径无法打通。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$ConfigPath
    )
    $repositoryPath = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([char[]]'\/')
    if (-not $ConfigPath) { $ConfigPath = Join-Path $repositoryPath 'config/skill-payloads.json' }
    $result = @{}
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        Write-Warning "未找到 Skill payload 清单，按无附加资源处理: $ConfigPath"
        return $result
    }

    try {
        $text = [System.IO.File]::ReadAllText($ConfigPath, (New-Object System.Text.UTF8Encoding($false)))
        $config = $text | ConvertFrom-Json
    }
    catch {
        throw "Skill payload 清单不是合法 JSON: $ConfigPath；$($_.Exception.Message)"
    }
    if ($null -eq $config -or -not ($config.PSObject.Properties.Name -contains 'schemaVersion') -or
        [int]$config.schemaVersion -ne 1) {
        throw "Skill payload 清单 schemaVersion 必须为 1: $ConfigPath"
    }
    if (-not ($config.PSObject.Properties.Name -contains 'payloads') -or $null -eq $config.payloads) {
        throw "Skill payload 清单缺少 payloads 对象: $ConfigPath"
    }

    $secretPattern = '(?i)(^|/)(sessiondetails\.json|\.env|id_rsa|id_ed25519)(/|$)|\.(pem|key|pfx|p12|cer|crt)$'
    foreach ($entry in @($config.payloads.PSObject.Properties)) {
        $skillName = $entry.Name
        if ($skillName -notmatch '^matlab-[a-z0-9]+(?:-[a-z0-9]+)*$') {
            throw "payload 清单中的 Skill 名称不安全: $skillName"
        }
        $skillDirectory = Join-Path (Join-Path $repositoryPath 'skills') $skillName
        if (-not (Test-Path -LiteralPath $skillDirectory -PathType Container)) {
            throw "payload 清单引用了不存在的 Skill: $skillName"
        }
        $skillDirectory = Assert-MasContainedPayloadPath -RepositoryRoot $repositoryPath `
            -RelativePath ("skills/" + $skillName)

        $files = @($entry.Value.files)
        if ($files.Count -eq 0) { throw "Skill payload 清单为空: $skillName" }
        $targets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $records = New-Object System.Collections.Generic.List[object]
        foreach ($file in $files) {
            $sourceRelative = ([string]$file.source -replace '\\', '/')
            $targetRelative = ([string]$file.target -replace '\\', '/')
            if (-not (Test-MasSafePayloadRelativePath -Value $sourceRelative)) {
                throw "payload 源路径不安全: $skillName -> $sourceRelative"
            }
            if (-not (Test-MasSafePayloadRelativePath -Value $targetRelative)) {
                throw "payload 目标路径不安全: $skillName -> $targetRelative"
            }
            if ($sourceRelative -notmatch '^(scripts|schemas|config)/') {
                throw "payload 源必须位于 scripts/、schemas/ 或 config/ 下: $sourceRelative"
            }
            if ($sourceRelative -match '(?i)(^|/)(artifacts|tests|docs|skills)(/|$)') {
                throw "payload 源不能来自测试或证据目录: $sourceRelative"
            }
            if ($targetRelative -notmatch '^(scripts|schemas|config)/') {
                throw "payload 目标必须位于 Skill 的 scripts/、schemas/ 或 config/ 下: $targetRelative"
            }
            if ($sourceRelative -match $secretPattern -or $targetRelative -match $secretPattern) {
                throw "payload 不得包含会话或凭据文件: $sourceRelative"
            }
            if (-not $targets.Add($targetRelative)) {
                throw "payload 目标重复: $skillName -> $targetRelative"
            }
            $sourceFullPath = Assert-MasContainedPayloadPath -RepositoryRoot $repositoryPath `
                -RelativePath $sourceRelative -RequireFile
            $targetFullPath = Assert-MasContainedPayloadPath -RepositoryRoot $skillDirectory `
                -RelativePath $targetRelative
            if (Test-Path -LiteralPath $targetFullPath) {
                throw "payload 目标与 Skill 自带文件冲突: $skillName -> $targetRelative"
            }
            $records.Add([pscustomobject]@{
                    SkillName      = $skillName
                    Source         = $sourceFullPath
                    SourceRelative = $sourceRelative
                    Target         = $targetRelative
                    TargetFullPath = $targetFullPath
                })
        }
        $result[$skillName] = [object[]]$records.ToArray()
    }
    return $result
}

Export-ModuleMember -Function Resolve-MasSkillInstallation, Assert-MasManagedSkillPath, Assert-MasSkillRootPath, Get-MasSkillPayloadManifest
