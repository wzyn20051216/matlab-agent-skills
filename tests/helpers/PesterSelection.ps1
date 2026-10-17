<#
.SYNOPSIS
Pester 模块选择：按"主.次.构建"精确匹配，绝不降级到其他主版本。

.DESCRIPTION
为什么要单独成文件：
    本仓库的测试套件使用 Pester 3 的 Should 语法（Should Be / Should Throw）。
    Pester 5 会直接抛 "Legacy Should syntax is not supported in Pester 5"，
    结果表现为"整套用例失败"，很容易被误读成被测代码坏了。

    真实事故：GitHub Actions 的 windows-latest 同时预装 Pester 3.4.0 与 5.9.0，
    旧实现用 `Sort-Object Version -Descending | Select-Object -First 1` 取到 5.9.0，
    124 个用例全部失败；本机只装了 3.4.0，所以本地一直是绿的。
    "选最高版本"本身就是 bug，不是环境问题。

因此这里的选择逻辑是纯函数，可以脱离 Pester 单独测试。
#>

function ConvertTo-EffectiveVersionPart {
    <#
    .SYNOPSIS
    把 [version] 的缺省段（-1）归一化成 0。
    .DESCRIPTION
    [version]"3.4" 的 Build 与 Revision 都是 -1，而不是 0；
    直接比较会让 "3.4" 与 "3.4.0" 被判成不同版本。
    #>
    param([int]$Value)
    if ($Value -lt 0) { return 0 }
    return $Value
}

function Select-PesterCandidate {
    <#
    .SYNOPSIS
    从候选模块里挑出与要求版本完全一致的 Pester；找不到返回 $null。
    .DESCRIPTION
    只比较 主.次.构建 三段；缺省段按 0 处理，所以 3.4 与 3.4.0 视为同一版本。
    #>
    param(
        [object[]]$Candidates = @(),
        [Parameter(Mandatory)][string]$RequiredVersion
    )

    try {
        $required = [version]$RequiredVersion
    }
    catch {
        throw "RequiredVersion 无法解析为版本号：$RequiredVersion"
    }
    $requiredMajor = ConvertTo-EffectiveVersionPart $required.Major
    $requiredMinor = ConvertTo-EffectiveVersionPart $required.Minor
    $requiredBuild = ConvertTo-EffectiveVersionPart $required.Build

    foreach ($candidate in @($Candidates)) {
        if ($null -eq $candidate) { continue }
        $candidateVersion = $null
        try { $candidateVersion = [version]([string]$candidate.Version) } catch { continue }
        if ($null -eq $candidateVersion) { continue }
        if ((ConvertTo-EffectiveVersionPart $candidateVersion.Major) -ne $requiredMajor) { continue }
        if ((ConvertTo-EffectiveVersionPart $candidateVersion.Minor) -ne $requiredMinor) { continue }
        if ((ConvertTo-EffectiveVersionPart $candidateVersion.Build) -ne $requiredBuild) { continue }
        return $candidate
    }
    return $null
}

function Get-PesterVersionSummary {
    <#
    .SYNOPSIS
    把候选列表压成一行可读的版本清单，用于报错信息。
    #>
    param([object[]]$Candidates = @())

    $versions = @(
        foreach ($candidate in @($Candidates)) {
            if ($null -ne $candidate -and $candidate.Version) { [string]$candidate.Version }
        }
    )
    if ($versions.Count -eq 0) { return "（无）" }
    return ($versions -join ", ")
}

function Resolve-TestPesterModule {
    <#
    .SYNOPSIS
    返回可用的 Pester 模块信息；本地没有就尝试下载到仓库内的隔离目录。
    .DESCRIPTION
    下载目标固定在 <RepositoryRoot>\artifacts\.pester，不写用户模块目录：
    CI 与本地行为一致，也不会因为需要管理员权限而失败。
    #>
    param(
        [Parameter(Mandatory)][string]$RequiredVersion,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [switch]$SkipDownload
    )

    $installed = @(Get-Module -ListAvailable Pester)
    $match = Select-PesterCandidate -Candidates $installed -RequiredVersion $RequiredVersion
    if ($match) {
        return [pscustomobject]@{
            Version = [string]$match.Version
            Path    = $match.Path
            Source  = "installed"
        }
    }

    $localModuleRoot = Join-Path $RepositoryRoot "artifacts\.pester"
    if (-not $SkipDownload) {
        try {
            if (-not (Test-Path -LiteralPath $localModuleRoot)) {
                New-Item -ItemType Directory -Force -Path $localModuleRoot | Out-Null
            }
            Save-Module -Name Pester -RequiredVersion $RequiredVersion -Path $localModuleRoot -Force -ErrorAction Stop
        }
        catch {
            Write-Host "==> 无法下载 Pester $RequiredVersion：$($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    $saved = @(Get-ChildItem -LiteralPath $localModuleRoot -Recurse -Filter "Pester.psd1" -File -ErrorAction SilentlyContinue)
    $savedCandidates = @(
        foreach ($moduleFile in $saved) {
            [pscustomobject]@{
                Version = (Split-Path -Leaf (Split-Path -Parent $moduleFile.FullName))
                Path    = $moduleFile.FullName
            }
        }
    )
    $savedMatch = Select-PesterCandidate -Candidates $savedCandidates -RequiredVersion $RequiredVersion
    if ($savedMatch) {
        return [pscustomobject]@{
            Version = [string]$savedMatch.Version
            Path    = $savedMatch.Path
            Source  = "downloaded"
        }
    }

    $summary = Get-PesterVersionSummary -Candidates $installed
    throw ("本测试套件要求 Pester $RequiredVersion，但本机没有该版本，也无法下载。" +
        " 当前已安装：$summary。" +
        " 请不要改用 Pester 5：套件使用的是 Pester 3 的 Should 语法，" +
        "在 Pester 5 下会以 'Legacy Should syntax is not supported' 整体失败。" +
        " 安装方式：Install-Module Pester -RequiredVersion $RequiredVersion -Scope CurrentUser -SkipPublisherCheck")
}
