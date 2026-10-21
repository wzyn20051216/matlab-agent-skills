<#
.SYNOPSIS
matlab-agent-skills 安装器共享核心逻辑（可测试、无副作用优先）。

.DESCRIPTION
本模块把安装器里“决定要不要改、怎么改、改坏了怎么退”的逻辑集中起来，
供 Setup / Install / Sync / Bootstrap 四个脚本复用，并被 tests/ 直接单元测试。

设计约束：
1. 所有纯决策函数（*Decision、New-MatlabMcpServerArgs、Test-ClientRegistrationMatch）
   不触碰文件系统，可脱离 MATLAB / Codex / Claude 环境测试。
2. 所有写操作函数都支持 -DryRun，并且写入前登记备份，失败时可由
   Invoke-BackupRollback 逆序回退。
3. 不自动读写真实用户全局配置——路径一律由调用方传入。

MATLAB MCP Server 参数约束（来自 MathWorks 官方文档）：
existing 模式不得与 matlab-root、initial-working-folder、matlab-display-mode 同时使用。
#>

$script:CoreVersion = "1.0.0"

$script:StartupBeginMarker = "% BEGIN matlab-agent-skills: share MATLAB session (managed block)"
$script:StartupEndMarker = "% END matlab-agent-skills: share MATLAB session (managed block)"
$script:SkillManifestFileName = ".matlab-agent-skills-manifest.json"

#region 输出与通用工具

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor DarkGray
}

function Test-CommandExists {
    param([string]$Name)
    if (-not $Name) { return $false }
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-CoreVersion {
    return $script:CoreVersion
}

function Get-StartupShareMarkers {
    return [pscustomobject]@{
        Begin = $script:StartupBeginMarker
        End   = $script:StartupEndMarker
    }
}

function Get-NormalizedPathText {
    param([string]$Text)
    if (-not $Text) { return "" }
    return ($Text.ToLowerInvariant() -replace '\\', '/')
}

function Test-HashMatch {
    param(
        [string]$Expected,
        [string]$Actual
    )
    if (-not $Expected -or -not $Actual) { return $false }
    $normalize = {
        param($Value)
        return ($Value -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    }
    $left = & $normalize $Expected
    $right = & $normalize $Actual
    if (-not $left -or -not $right) { return $false }
    return [string]::Equals($left, $right, [System.StringComparison]::Ordinal)
}

function Get-FileSha256 {
    <#
    .SYNOPSIS
    直接用 .NET 计算 SHA-256，避免嵌套 PS5.1 的模块路径导致 Get-FileHash 不可用。
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        return [System.BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '')
    }
    finally {
        if ($stream) { $stream.Dispose() }
        $sha.Dispose()
    }
}

#endregion

#region MATLAB MCP 参数构造（P0-1）

function New-MatlabMcpServerArgs {
    <#
    .SYNOPSIS
    构造传给 matlab-mcp-server 的参数列表，并按官方约束裁剪非法组合。

    .OUTPUTS
    PSCustomObject: SessionMode / Arguments / DroppedArguments / Warnings
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("auto", "existing", "new")]
        [string]$SessionMode,
        [string]$MatlabRoot = "",
        [bool]$InitializeMatlabOnStartup = $true,
        [ValidateSet("desktop", "nodesktop", "")]
        [string]$DisplayMode = "desktop"
    )

    $arguments = New-Object System.Collections.Generic.List[string]
    $dropped = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    $arguments.Add("--matlab-session-mode=$SessionMode")

    if ($SessionMode -eq "existing") {
        # 官方文档：existing 模式不得与 matlab-root / initial-working-folder / matlab-display-mode 同时使用。
        if ($DisplayMode) {
            $dropped.Add("--matlab-display-mode=$DisplayMode")
            $warnings.Add("SessionMode=existing 不允许 --matlab-display-mode，已自动省略（否则 MCP server 启动即失败）。")
        }
        if ($MatlabRoot) {
            $dropped.Add("--matlab-root=$MatlabRoot")
            $warnings.Add("SessionMode=existing 不允许 --matlab-root，已自动省略。")
        }
        if ($InitializeMatlabOnStartup) {
            $dropped.Add("--initialize-matlab-on-startup=true")
            $warnings.Add("SessionMode=existing 表示复用已有会话，不会启动新 MATLAB，已自动省略 --initialize-matlab-on-startup。")
        }
    }
    else {
        if ($DisplayMode) {
            $arguments.Add("--matlab-display-mode=$DisplayMode")
        }
        if ($MatlabRoot) {
            $arguments.Add("--matlab-root=$MatlabRoot")
        }
        if ($InitializeMatlabOnStartup) {
            $arguments.Add("--initialize-matlab-on-startup=true")
        }
    }

    return [pscustomobject]@{
        SessionMode      = $SessionMode
        Arguments        = [string[]]$arguments.ToArray()
        DroppedArguments = [string[]]$dropped.ToArray()
        Warnings         = [string[]]$warnings.ToArray()
    }
}

function Get-MatlabMcpServerArgv {
    <#
    .SYNOPSIS
    返回旧版扁平形状：第 0 项是 exe 路径，其后是参数。保留给历史调用方。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][ValidateSet("auto", "existing", "new")][string]$SessionMode,
        [string]$MatlabRoot = "",
        [bool]$InitializeMatlabOnStartup = $true,
        [ValidateSet("desktop", "nodesktop", "")][string]$DisplayMode = "desktop"
    )

    $built = New-MatlabMcpServerArgs -SessionMode $SessionMode -MatlabRoot $MatlabRoot `
        -InitializeMatlabOnStartup $InitializeMatlabOnStartup -DisplayMode $DisplayMode

    return @($ExePath) + $built.Arguments
}

function Test-McpServerArgsCompatible {
    <#
    .SYNOPSIS
    校验一组参数是否会被官方 MCP server 拒绝（用于安装后自检与测试）。
    #>
    param([string[]]$Arguments)

    $violations = New-Object System.Collections.Generic.List[string]
    if (-not $Arguments) { return [string[]]$violations.ToArray() }

    $mode = $null
    foreach ($arg in $Arguments) {
        if ($arg -match '^--matlab-session-mode=(.+)$') { $mode = $Matches[1] }
    }
    if ($mode -ne "existing") { return [string[]]$violations.ToArray() }

    foreach ($arg in $Arguments) {
        if ($arg -match '^--matlab-display-mode=') { $violations.Add("existing 模式不允许 $arg") }
        if ($arg -match '^--matlab-root=') { $violations.Add("existing 模式不允许 $arg") }
        if ($arg -match '^--initial-working-folder=') { $violations.Add("existing 模式不允许 $arg") }
        if ($arg -match '^--initialize-matlab-on-startup=') { $violations.Add("existing 模式不需要 $arg") }
    }
    return [string[]]$violations.ToArray()
}

#endregion

#region MATLAB / 可执行文件解析

function Resolve-MatlabRoot {
    <#
    .SYNOPSIS
    解析 MATLAB 安装根目录。显式传入 > 环境变量 > PATH > 常见安装位置。
    #>
    [CmdletBinding()]
    param(
        [string]$Hint,
        [switch]$SkipDriveScan
    )

    if ($Hint) {
        if (Test-Path -LiteralPath $Hint) { return (Resolve-Path -LiteralPath $Hint).Path }
        throw "指定的 MatlabRoot 不存在: $Hint"
    }

    if ($env:MATLAB_ROOT -and (Test-Path -LiteralPath $env:MATLAB_ROOT)) {
        return (Resolve-Path -LiteralPath $env:MATLAB_ROOT).Path
    }

    $matlabCmd = Get-Command matlab -ErrorAction SilentlyContinue
    if ($matlabCmd -and $matlabCmd.Source) {
        $binDir = Split-Path -Parent $matlabCmd.Source
        return (Split-Path -Parent $binDir)
    }

    if ($SkipDriveScan) {
        throw "未找到 MATLAB 安装目录。请使用 -MatlabRoot 显式指定。"
    }

    $drives = @()
    try { $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue } catch { $drives = @() }
    foreach ($drive in $drives) {
        $root = $drive.Root
        $programFilesMatlab = Join-Path $root "Program Files\MATLAB"
        if (Test-Path -LiteralPath $programFilesMatlab) {
            $release = Get-ChildItem -LiteralPath $programFilesMatlab -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                Select-Object -First 1
            if ($release) { return $release.FullName }
        }
        $flatMatlab = Join-Path $root "MATLAB"
        if (Test-Path -LiteralPath $flatMatlab) { return $flatMatlab }
    }

    throw "未找到 MATLAB 安装目录。请使用 -MatlabRoot 显式指定。"
}

function Get-McpServerCandidatePaths {
    param([string]$ScriptRoot)

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($ScriptRoot) {
        $candidates.Add((Join-Path $ScriptRoot "..\bin\matlab-mcp-server-windows-x64.exe"))
    }
    # 不再把"当前工作目录"作为隐式候选：在共享目录/下载目录里执行时，
    # 同名的攻击文件会被当作服务器执行（安全审查已复现：24 字节非 PE 文件被接受）。
    # 确实要放在 CWD 时必须显式 -ServerExePath。
    $candidates.Add((Join-Path $HOME "Downloads\matlab-mcp-server-windows-x64.exe"))
    $candidates.Add((Join-Path $HOME "download\matlab-mcp-server-windows-x64.exe"))
    return [string[]]$candidates.ToArray()
}

function Get-McpServerManifest {
    <#
    .SYNOPSIS
    读取固定的 MCP server 发布清单（config/mcp-server-manifest.json）。

    没有清单就拒绝自动下载与执行：fail closed，而不是"没有哈希就当作可信"。
    #>
    [CmdletBinding()]
    param([string]$RepositoryRoot)
    if (-not $RepositoryRoot) { $RepositoryRoot = Split-Path -Parent $PSScriptRoot }
    $manifestPath = Join-Path $RepositoryRoot "config/mcp-server-manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw ("缺少 MCP server 固定发布清单: $manifestPath。" +
            " 为避免执行未经校验的二进制，本工具链拒绝在无清单时自动下载或执行。" +
            " 手动安装：从 https://github.com/matlab/matlab-mcp-server/releases 下载与你的 MATLAB 匹配的版本，" +
            "校验其 SHA-256 后用 -ServerExePath <路径> 显式指定（或 -AllowUnverifiedServer 明确承担风险）。")
    }
    $data = $null
    try { $data = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json }
    catch { throw "MCP server 清单无法解析: $manifestPath（$($_.Exception.Message)）" }
    if ($data.schema -ne "mas-mcp-server-manifest/1") { throw "MCP server 清单 schema 不受支持: $($data.schema)" }
    if (-not $data.upstream -or -not $data.upstream.releaseTag -or [string]$data.upstream.releaseTag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+') {
        throw "MCP server 清单的 upstream.releaseTag 未固定为具体版本（不得使用 latest）。"
    }
    [pscustomobject]@{ Path = $manifestPath; Data = $data; ReleaseTag = [string]$data.upstream.releaseTag }
}

function Get-McpServerAssetName {
    <# .SYNOPSIS 按当前平台选择清单条目名；不做跨平台猜测。 #>
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { return "matlab-mcp-server-windows-x64.exe" }
    $uname = ""
    try { $uname = (& uname -sm 2>$null) -join " " } catch { $uname = "" }
    if ($uname -match "Darwin.*arm64") { return "matlab-mcp-server-macos-arm64" }
    if ($uname -match "Darwin") { return "matlab-mcp-server-macos-x64" }
    if ($uname -match "Linux.*x86_64") { return "matlab-mcp-server-linux-x64" }
    throw "无法从平台信息（$uname）确定 MCP server 资产名；请在清单中显式添加该平台条目。"
}

function Get-McpServerAsset {
    <# .SYNOPSIS 取某个平台的固定资产条目，并校验清单自身的一致性。 #>
    [CmdletBinding()]
    param($Manifest, [string]$AssetName)
    if (-not $AssetName) { $AssetName = Get-McpServerAssetName }
    $asset = $Manifest.Data.assets.PSObject.Properties[$AssetName]
    if (-not $asset) {
        throw "MCP server 清单缺少平台条目 '$AssetName'；拒绝猜测下载地址。请手动安装并用 -ServerExePath 指定。"
    }
    $a = $asset.Value
    if ([string]$a.sha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw "清单条目 $AssetName 的 sha256 非法。" }
    $expectedFragment = "/releases/download/$($Manifest.ReleaseTag)/"
    if ([string]$a.url -notlike "*$expectedFragment*") { throw "清单条目 $AssetName 的 URL 与 releaseTag $($Manifest.ReleaseTag) 不一致。" }
    if (-not $a.bytes -or [int64]$a.bytes -le 0) { throw "清单条目 $AssetName 缺少字节数，无法检测截断下载。" }
    [pscustomobject]@{
        Name      = $AssetName
        Url       = [string]$a.url
        Sha256    = ([string]$a.sha256).ToUpperInvariant()
        Bytes     = [int64]$a.bytes
        ReleaseTag = $Manifest.ReleaseTag
    }
}

function Get-McpServerIntegrity {
    <#
    .SYNOPSIS 计算并核对二进制完整性。

    Hashed   = 已经算过哈希（任何文件都能算）
    Verified = 哈希与固定清单一致（这才叫"可信来源已验证"）
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, $Asset)
    if (-not (Test-Path -LiteralPath $Path)) { throw "文件不存在: $Path" }
    $sha = (Get-FileSha256 -Path $Path).ToUpperInvariant()
    $size = (Get-Item -LiteralPath $Path).Length
    $matchesHash = $false
    if ($Asset) { $matchesHash = [string]::Equals($sha, $Asset.Sha256, [StringComparison]::OrdinalIgnoreCase) }
    [pscustomobject]@{
        Path             = $Path
        Sha256           = $sha
        Bytes            = $size
        ExpectedSha256   = if ($Asset) { $Asset.Sha256 } else { $null }
        ExpectedBytes    = if ($Asset) { $Asset.Bytes } else { $null }
        Hashed           = $true
        Verified         = $matchesHash
        ReleaseTag       = if ($Asset) { $Asset.ReleaseTag } else { $null }
        Source           = if ($Asset) { $Asset.Url } else { $null }
        IntegrityStatus  = if ($matchesHash) { "VERIFIED_AGAINST_MANIFEST" } elseif ($Asset) { "HASH_MISMATCH" } else { "UNVERIFIED_NO_MANIFEST_ENTRY" }
    }
}

function Assert-McpServerTrusted {
    <# .SYNOPSIS Verified=false 绝不能被静默当成安装成功；只有操作员显式授权才放行并记录。 #>
    [CmdletBinding()]
    param($Server, [switch]$AllowUnverifiedServer)
    if ($Server -and $Server.Verified -eq $true) { return }
    if ($AllowUnverifiedServer) {
        Write-Warning ("正在使用未经固定清单校验的 MCP server: $($Server.Path)（SHA256=$($Server.Sha256)）。" +
            " 状态记为 UNVERIFIED_ACCEPTED_BY_OPERATOR，安装摘要不会把它标为已验证。")
        return
    }
    throw ("MCP server 未通过固定清单校验（Verified=false），拒绝继续执行。" +
        " 路径: $($Server.Path)；实际 SHA256: $($Server.Sha256)。" +
        " 处理方式：1) 删除该文件后重跑以从固定版本重新下载；2) 或传入 -ExpectedServerSha256 显式固定；" +
        " 3) 或从官方 releases 手动下载并校验后用 -ServerExePath 指定；" +
        " 4) 明确接受风险时加 -AllowUnverifiedServer（会被记录为非验证状态）。")
}

function Resolve-McpServerExecutable {
    <#
    .SYNOPSIS
    找到或下载 MCP server 可执行文件，并强制对照固定发布清单校验。

    安全策略（Phase 4.7）：
    - 下载地址来自 config/mcp-server-manifest.json 的固定 release tag，不再用 releases/latest；
    - 本地已有文件和下载结果都必须匹配清单 SHA-256 才会被标记 Verified；
    - 清单缺失、平台条目缺失、哈希不符、字节数不符都 fail closed，并给出手动安装指引；
    - 只有显式 -AllowUnverifiedServer 才允许使用未验证二进制，且状态必须记录为未验证。
    #>
    [CmdletBinding()]
    param(
        [string]$Hint,
        [string]$DownloadUrl,
        [string]$ScriptRoot,
        [string]$ExpectedSha256 = "",
        [string]$RepositoryRoot,
        [switch]$NoDownload,
        [switch]$ForceDownload,
        [switch]$AllowUnverifiedServer,
        [switch]$DryRun
    )

    if (-not $RepositoryRoot) {
        $RepositoryRoot = if ($ScriptRoot) { Split-Path -Parent $ScriptRoot } else { Split-Path -Parent $PSScriptRoot }
    }

    $manifest = $null; $asset = $null; $manifestProblem = $null
    try { $manifest = Get-McpServerManifest -RepositoryRoot $RepositoryRoot } catch { $manifestProblem = $_.Exception.Message }
    if ($manifest) {
        try { $asset = Get-McpServerAsset -Manifest $manifest } catch { $manifestProblem = $_.Exception.Message }
    }

    $build = {
        param($path, $source, $integrityStatus, $downloaded)
        $sha = $null; $bytes = 0
        if ($path -and (Test-Path -LiteralPath $path)) {
            $sha = (Get-FileSha256 -Path $path).ToUpperInvariant()
            $bytes = (Get-Item -LiteralPath $path).Length
        }
        $verified = ($integrityStatus -eq "VERIFIED_AGAINST_MANIFEST")
        [pscustomobject]@{
            Path            = $path
            Source          = $source
            Sha256          = $sha
            Bytes           = $bytes
            Hashed          = [bool]$sha
            Verified        = $verified
            IntegrityStatus = $integrityStatus
            ReleaseTag      = if ($asset) { $asset.ReleaseTag } else { $null }
            DownloadSource  = if ($asset) { $asset.Url } else { $DownloadUrl }
            Downloaded      = [bool]$downloaded
        }
    }

    if ($Hint) {
        if (-not (Test-Path -LiteralPath $Hint)) { throw "指定的 ServerExePath 不存在: $Hint" }
        $resolved = (Resolve-Path -LiteralPath $Hint).Path
        if (-not $asset) {
            if (-not $AllowUnverifiedServer) { throw ($manifestProblem + " 因此拒绝使用未校验的文件: $resolved。") }
            return (& $build $resolved "explicit" "UNVERIFIED_ACCEPTED_BY_OPERATOR" $false)
        }
        $integrity = Get-McpServerIntegrity -Path $resolved -Asset $asset
        if ($integrity.Verified) { return (& $build $resolved "explicit" $integrity.IntegrityStatus $false) }
        if ($ExpectedSha256 -and (Test-HashMatch -Expected $ExpectedSha256 -Actual $integrity.Sha256)) {
            return (& $build $resolved "explicit" "VERIFIED_AGAINST_OPERATOR_DIGEST" $false)
        }
        if ($AllowUnverifiedServer) { return (& $build $resolved "explicit" "UNVERIFIED_ACCEPTED_BY_OPERATOR" $false) }
        throw ("指定的 MCP server 与固定清单不匹配：期望 $($asset.Sha256)（$($asset.ReleaseTag)），实际 $($integrity.Sha256)。" +
            " 可能被替换或版本不符；已拒绝执行。确认无误可加 -AllowUnverifiedServer，或删除后用 -ForceDownload 重新获取。")
    }

    foreach ($candidate in (Get-McpServerCandidatePaths -ScriptRoot $ScriptRoot)) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        $resolved = (Resolve-Path -LiteralPath $candidate).Path
        if (-not $asset) {
            if ($AllowUnverifiedServer) { return (& $build $resolved "existing" "UNVERIFIED_ACCEPTED_BY_OPERATOR" $false) }
            throw ($manifestProblem + " 因此拒绝使用未校验的现有文件: $resolved。")
        }
        $integrity = Get-McpServerIntegrity -Path $resolved -Asset $asset
        if ($integrity.Verified) { return (& $build $resolved "existing" $integrity.IntegrityStatus $false) }
        if ($ForceDownload) {
            Write-Warning "现有文件 $resolved 与固定清单不匹配（期望 $($asset.Sha256)，实际 $($integrity.Sha256)），将重新下载。"
            break
        }
        if ($AllowUnverifiedServer) { return (& $build $resolved "existing" "UNVERIFIED_ACCEPTED_BY_OPERATOR" $false) }
        throw ("现有 MCP server 文件与固定清单不匹配：$resolved（期望 $($asset.Sha256)，实际 $($integrity.Sha256)）。" +
            " 为避免执行被替换的二进制已拒绝；确认后可用 -ForceDownload 重新获取，或删除该文件。")
    }

    if ($NoDownload) {
        throw ("未找到与固定清单匹配的 matlab-mcp-server 可执行文件，且指定了 -NoDownload。" +
            " 手动安装：从 https://github.com/matlab/matlab-mcp-server/releases/tag/$($manifest.ReleaseTag) 下载，" +
            "校验 SHA-256 后用 -ServerExePath 显式指定。")
    }
    if (-not $asset) {
        throw ($manifestProblem + " 为避免执行未校验的二进制，拒绝自动下载。请手动安装并用 -ServerExePath 指定。")
    }

    $binDir = if ($ScriptRoot) { Join-Path $ScriptRoot "..\bin" } else { Join-Path $RepositoryRoot "bin" }
    $downloadPath = Join-Path $binDir $asset.Name
    $download = Save-VerifiedDownload -Uri $asset.Url -Destination $downloadPath `
        -ExpectedSha256 $asset.Sha256 -ExpectedBytes $asset.Bytes -DryRun:$DryRun

    if ($DryRun) { return (& $build $downloadPath "download" "DRY_RUN" $false) }
    if (-not $download.Verified) {
        throw ("下载得到的 MCP server 未通过固定清单校验（期望 $($asset.Sha256)）。已丢弃，不执行。" +
            " 请检查网络/代理是否篡改内容，或手动安装后用 -ServerExePath 指定。")
    }
    return (& $build $downloadPath "download" "VERIFIED_AGAINST_MANIFEST" $true)
}

#endregion

#region 下载（P0-6）

function Test-DownloadIntegrity {
    <#
    .SYNOPSIS 纯函数：判定一次下载是否可接受（可单测，不触碰网络）。

    返回 Ok + Reason：TOO_SMALL / SIZE_MISMATCH / HASH_MISMATCH / NO_EXPECTED_DIGEST / VERIFIED。
    "算过哈希"不等于"验证过来源"：没有期望摘要时一律不返回 Ok。
    #>
    [CmdletBinding()]
    param(
        [int64]$Bytes,
        [string]$Sha256,
        [string]$ExpectedSha256 = "",
        [int64]$ExpectedBytes = 0,
        [int]$MinimumBytes = 1024
    )
    if ($Bytes -lt $MinimumBytes) {
        return [pscustomobject]@{ Ok = $false; Reason = "TOO_SMALL"; Detail = "只有 $Bytes 字节，低于最小阈值 $MinimumBytes（可能是错误页或截断）" }
    }
    if ($ExpectedBytes -gt 0 -and $Bytes -ne $ExpectedBytes) {
        return [pscustomobject]@{ Ok = $false; Reason = "SIZE_MISMATCH"; Detail = "期望 $ExpectedBytes 字节，实际 $Bytes" }
    }
    if (-not $ExpectedSha256) {
        return [pscustomobject]@{ Ok = $false; Reason = "NO_EXPECTED_DIGEST"; Detail = "未提供期望 SHA256，只能算过哈希、不能验证来源" }
    }
    if (-not (Test-HashMatch -Expected $ExpectedSha256 -Actual $Sha256)) {
        return [pscustomobject]@{ Ok = $false; Reason = "HASH_MISMATCH"; Detail = "期望 $ExpectedSha256，实际 $Sha256" }
    }
    [pscustomobject]@{ Ok = $true; Reason = "VERIFIED"; Detail = "字节数与 SHA256 均匹配" }
}

function Save-VerifiedDownload {
    <#
    .SYNOPSIS
    带校验的下载：仅 HTTPS（除非显式 -AllowInsecure）、先落临时文件、
    校验大小与可选 SHA256、最后原子移动到目标路径，失败清理临时文件。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination,
        [string]$ExpectedSha256 = "",
        [int64]$ExpectedBytes = 0,
        [int]$MinimumBytes = 1024,
        [switch]$AllowInsecure,
        [switch]$DryRun
    )

    $parsed = $null
    try { $parsed = [System.Uri]$Uri } catch { throw "下载地址不是合法 URI: $Uri" }

    if ($parsed.Scheme -ne "https" -and -not $AllowInsecure) {
        throw "拒绝从非 HTTPS 地址下载（$($parsed.Scheme)://）。如确需自定义源，请显式加 -AllowInsecure。"
    }

    $record = [pscustomobject]@{
        Source     = $Uri
        Destination = $Destination
        Sha256     = $null
        Bytes      = 0
        Verified   = $false
        Downloaded = $false
        DryRun     = [bool]$DryRun
        Hashed     = $false
        IntegrityStatus = "NOT_CHECKED"
    }

    if ($DryRun) {
        Write-Step "[DryRun] 将下载 $Uri -> $Destination"
        return $record
    }

    $dir = Split-Path -Parent $Destination
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $tempPath = "$Destination.part-$([guid]::NewGuid().ToString('N'))"
    try {
        $params = @{ Uri = $Uri; OutFile = $tempPath }
        if (Get-Command Invoke-WebRequest -ErrorAction SilentlyContinue) {
            if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey("UseBasicParsing")) {
                $params["UseBasicParsing"] = $true
            }
        }
        Invoke-WebRequest @params | Out-Null

        if (-not (Test-Path -LiteralPath $tempPath)) { throw "下载未产生文件: $Uri" }
        $size = (Get-Item -LiteralPath $tempPath).Length
        $record.Bytes = $size
        if ($size -lt $MinimumBytes) {
            throw "下载文件只有 $size 字节，低于最小阈值 $MinimumBytes，可能是错误页面或被截断。"
        }

        $sha = Get-FileSha256 -Path $tempPath
        $record.Sha256 = $sha
        $record.Hashed = $true

        $verdict = Test-DownloadIntegrity -Bytes $size -Sha256 $sha -ExpectedSha256 $ExpectedSha256 `
            -ExpectedBytes $ExpectedBytes -MinimumBytes $MinimumBytes
        $record.IntegrityStatus = $verdict.Reason
        if (-not $verdict.Ok) {
            if ($verdict.Reason -eq "NO_EXPECTED_DIGEST") {
                # 只"算过哈希"不等于"已验证来源"；调用方不得把这种状态当成成功。
                Write-Warning "未提供期望 SHA256，无法校验下载文件来源完整性。实际 SHA256=$sha（记为未验证状态）。"
            }
            else {
                throw "下载校验失败[$($verdict.Reason)]：$($verdict.Detail)。已丢弃下载内容。"
            }
        }
        else {
            $record.Verified = $true
        }

        Move-Item -LiteralPath $tempPath -Destination $Destination -Force
        $record.Downloaded = $true
        return $record
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

#endregion

#region JSON 配置安全合并（P0-3 / P0-4）

function ConvertTo-OrderedConfig {
    <#
    .SYNOPSIS
    把 ConvertFrom-Json 的 PSCustomObject 递归转成 ordered dictionary，保持键顺序与数组形状。
    #>
    param($InputObject)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $ordered = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $ordered[$property.Name] = ConvertTo-OrderedConfig $property.Value
        }
        return $ordered
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $ordered[$key] = ConvertTo-OrderedConfig $InputObject[$key]
        }
        return $ordered
    }

    if ($InputObject -is [System.Array]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $InputObject) {
            [void]$list.Add((ConvertTo-OrderedConfig $item))
        }
        return , ([object[]]$list.ToArray())
    }

    return $InputObject
}

function Read-JsonConfig {
    <#
    .SYNOPSIS
    读取 JSON 配置。文件不存在返回 $null；解析失败抛错（绝不返回空对象，避免后续覆盖用户配置）。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    $raw = Get-Content -Raw -LiteralPath $Path -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

    try {
        $object = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "无法解析 JSON 配置: $Path。为避免破坏你已有的配置，安装器已中止。请先修复该文件的语法（含注释的 JSONC 也会导致此错误）。"
    }

    if ($null -eq $object) { return $null }
    return (ConvertTo-OrderedConfig $object)
}

function Write-JsonFileAtomic {
    <#
    .SYNOPSIS
    原子写 JSON：UTF-8 无 BOM（PS 5.1 的 Set-Content -Encoding UTF8 会写 BOM），先写临时文件再替换。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        $Object,
        [int]$Depth = 20
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $json = $Object | ConvertTo-Json -Depth $Depth
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $tempPath = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText($tempPath, $json + [Environment]::NewLine, $encoding)
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-McpMergeDecision {
    <#
    .SYNOPSIS
    纯决策：给定已有条目与新条目，判断 created / unchanged / updated。
    #>
    param($PreviousEntry, $NewEntry)

    if ($null -eq $PreviousEntry) { return "created" }
    $previousJson = $PreviousEntry | ConvertTo-Json -Depth 20 -Compress
    $newJson = $NewEntry | ConvertTo-Json -Depth 20 -Compress
    if ($previousJson -eq $newJson) { return "unchanged" }
    return "updated"
}

function Merge-McpServerConfig {
    <#
    .SYNOPSIS
    安全合并单个 MCP server 条目：保留文件里所有其它键与其它 server，只替换目标条目。

    .OUTPUTS
    PSCustomObject: Path / RootProperty / ServerName / Action / Changed / BackupPath / PreservedEntries
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RootProperty,
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)]$Entry,
        [string]$BackupRoot = "",
        [string]$BackupLabel = "mcp-config",
        [switch]$DryRun
    )

    $existing = Read-JsonConfig -Path $Path

    if ($null -eq $existing) {
        $root = [ordered]@{}
    }
    else {
        if ($existing -isnot [System.Collections.IDictionary]) {
            throw "配置文件顶层不是 JSON 对象: $Path。已中止，未做任何写入。"
        }
        $root = $existing
    }

    if (-not $root.Contains($RootProperty) -or $null -eq $root[$RootProperty]) {
        $root[$RootProperty] = [ordered]@{}
    }

    $servers = $root[$RootProperty]
    if ($servers -isnot [System.Collections.IDictionary]) {
        throw "配置文件里的 `"$RootProperty`" 不是对象: $Path。已中止，未做任何写入。"
    }

    $previousEntry = $null
    if ($servers.Contains($ServerName)) { $previousEntry = $servers[$ServerName] }

    $preserved = @($servers.Keys | Where-Object { $_ -ne $ServerName }).Count
    $decision = Get-McpMergeDecision -PreviousEntry $previousEntry -NewEntry $Entry
    $servers[$ServerName] = $Entry

    $result = [pscustomobject]@{
        Path             = $Path
        RootProperty     = $RootProperty
        ServerName       = $ServerName
        Action           = $decision
        Changed          = ($decision -ne "unchanged")
        BackupPath       = $null
        PreservedEntries = $preserved
        DryRun           = [bool]$DryRun
    }

    if ($decision -eq "unchanged") {
        return $result
    }

    if ($DryRun) {
        $result.Action = "would_$decision"
        $verb = if ($decision -eq "created") { "创建" } else { "更新" }
        Write-Step "[DryRun] 将$verb $Path 中的 $RootProperty.$ServerName（其余 $preserved 个条目保持不变）"
        return $result
    }

    if ($BackupRoot -and (Test-Path -LiteralPath $Path)) {
        $session = New-BackupSession -Root $BackupRoot -Reason $BackupLabel
        $result.BackupPath = Save-FileBackupToSession -Session $session -Path $Path -Label $ServerName
        Save-BackupManifest -Session $session
    }

    Write-JsonFileAtomic -Path $Path -Object $root
    return $result
}

#endregion

#region 备份与回滚（P0-5 / P0-6）

function New-BackupSession {
    <#
    .SYNOPSIS
    创建一次安装动作的备份会话（目录 + manifest）。所有写操作都应登记到会话以便回滚。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Reason = "install"
    )

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $safeReason = ($Reason -replace '[^A-Za-z0-9\-_]', '_')
    $directory = Join-Path $Root "$stamp-$safeReason"
    $suffix = 1
    while (Test-Path -LiteralPath $directory) {
        $directory = Join-Path $Root "$stamp-$safeReason-$suffix"
        $suffix++
    }

    # 目录延迟创建：只在真的产生备份记录时落盘，保证重复安装（无变更）零写入。
    return [pscustomobject]@{
        Id           = [guid]::NewGuid().ToString('N')
        Directory    = $directory
        Reason       = $Reason
        CreatedAt    = (Get-Date).ToString("o")
        Records      = New-Object System.Collections.ArrayList
        ManifestPath = (Join-Path $directory "manifest.json")
    }
}

function Ensure-BackupDirectory {
    param([Parameter(Mandatory)]$Session)

    if (-not (Test-Path -LiteralPath $Session.Directory)) {
        New-Item -ItemType Directory -Force -Path $Session.Directory | Out-Null
    }
    return $Session.Directory
}

function Add-BackupRecord {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Kind,
        [string]$TargetPath = "",
        [string]$BackupPath = "",
        $Data = $null
    )

    $record = [pscustomobject]@{
        Kind       = $Kind
        TargetPath = $TargetPath
        BackupPath = $BackupPath
        Existed    = if ($TargetPath) { [bool](Test-Path -LiteralPath $TargetPath) } else { $false }
        Data       = $Data
    }
    if ($null -ne $Session -and $null -ne $Session.Records) {
        [void]$Session.Records.Add($record)
    }
    return $record
}

function Save-FileBackupToSession {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Path,
        [string]$Label = "file"
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-BackupRecord -Session $Session -Kind "file-absent" -TargetPath $Path | Out-Null
        return $null
    }

    $safeLabel = ($Label -replace '[\\/:*?"<>|]', '_')
    Ensure-BackupDirectory -Session $Session | Out-Null
    $filesDir = Join-Path $Session.Directory "files"
    if (-not (Test-Path -LiteralPath $filesDir)) {
        New-Item -ItemType Directory -Force -Path $filesDir | Out-Null
    }
    $destination = Join-Path $filesDir ("$safeLabel-" + (Split-Path -Leaf $Path))
    Copy-Item -LiteralPath $Path -Destination $destination -Force

    Add-BackupRecord -Session $Session -Kind "file" -TargetPath $Path -BackupPath $destination | Out-Null
    return $destination
}

function Save-DirectoryBackupToSession {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Path,
        [string]$Label = "dir"
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-BackupRecord -Session $Session -Kind "dir-absent" -TargetPath $Path | Out-Null
        return $null
    }

    $safeLabel = ($Label -replace '[\\/:*?"<>|]', '_')
    Ensure-BackupDirectory -Session $Session | Out-Null
    $dirsRoot = Join-Path $Session.Directory "dirs"
    if (-not (Test-Path -LiteralPath $dirsRoot)) {
        New-Item -ItemType Directory -Force -Path $dirsRoot | Out-Null
    }
    $destination = Join-Path $dirsRoot ("$safeLabel-" + (Split-Path -Leaf $Path))
    Copy-Item -LiteralPath $Path -Destination $destination -Recurse -Force

    Add-BackupRecord -Session $Session -Kind "dir" -TargetPath $Path -BackupPath $destination | Out-Null
    return $destination
}

function Save-BackupManifest {
    param([Parameter(Mandatory)]$Session)

    if ($null -eq $Session -or $Session.Records.Count -eq 0) { return }

    $records = @()
    foreach ($record in $Session.Records) {
        $records += [pscustomobject]@{
            kind       = $record.Kind
            target     = $record.TargetPath
            backup     = $record.BackupPath
            existed    = $record.Existed
            data       = $record.Data
        }
    }

    $payload = [pscustomobject]@{
        id        = $Session.Id
        reason    = $Session.Reason
        createdAt = $Session.CreatedAt
        records   = $records
    }

    try {
        Write-JsonFileAtomic -Path $Session.ManifestPath -Object $payload
    }
    catch {
        Write-Warning "备份清单写入失败: $($_.Exception.Message)"
    }
}

function Invoke-BackupRollback {
    <#
    .SYNOPSIS
    逆序回退一次安装动作留下的所有改动。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [switch]$DryRun
    )

    $actions = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Session -or $null -eq $Session.Records) {
        return [pscustomobject]@{ RolledBack = $false; Actions = @() }
    }

    for ($index = $Session.Records.Count - 1; $index -ge 0; $index--) {
        $record = $Session.Records[$index]
        try {
            switch ($record.Kind) {
                "file-absent" {
                    if (Test-Path -LiteralPath $record.TargetPath) {
                        if (-not $DryRun) { Remove-Item -LiteralPath $record.TargetPath -Force }
                        $actions.Add("删除新建文件: $($record.TargetPath)")
                    }
                }
                "file" {
                    if ($record.BackupPath -and (Test-Path -LiteralPath $record.BackupPath)) {
                        if (-not $DryRun) {
                            $parent = Split-Path -Parent $record.TargetPath
                            if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                                New-Item -ItemType Directory -Force -Path $parent | Out-Null
                            }
                            Copy-Item -LiteralPath $record.BackupPath -Destination $record.TargetPath -Force
                        }
                        $actions.Add("还原文件: $($record.TargetPath)")
                    }
                }
                "dir-absent" {
                    if (Test-Path -LiteralPath $record.TargetPath) {
                        if (-not $DryRun) { Remove-Item -LiteralPath $record.TargetPath -Recurse -Force }
                        $actions.Add("删除新建目录: $($record.TargetPath)")
                    }
                }
                "dir" {
                    if ($record.BackupPath -and (Test-Path -LiteralPath $record.BackupPath)) {
                        if (-not $DryRun) {
                            if (Test-Path -LiteralPath $record.TargetPath) {
                                Remove-Item -LiteralPath $record.TargetPath -Recurse -Force
                            }
                            Copy-Item -LiteralPath $record.BackupPath -Destination $record.TargetPath -Recurse -Force
                        }
                        $actions.Add("还原目录: $($record.TargetPath)")
                    }
                }
                "acl" {
                    if ($record.Data -and $record.Data.Before) {
                        if (-not $DryRun) {
                            $acl = Get-Acl -LiteralPath $record.TargetPath
                            $acl.SetSecurityDescriptorSddlForm($record.Data.Before)
                            Set-Acl -LiteralPath $record.TargetPath -AclObject $acl
                        }
                        $actions.Add("还原 ACL: $($record.TargetPath)")
                    }
                }
                "client" {
                    if ($record.Data) {
                        if (-not $DryRun) { Restore-ClientRegistration -Record $record } 
                        $actions.Add("还原客户端注册: $($record.Data.Client) $($record.Data.Name)")
                    }
                }
                default {
                    $actions.Add("跳过未知记录类型 $($record.Kind): $($record.TargetPath)")
                }
            }
        }
        catch {
            $actions.Add("回滚失败($($record.Kind) $($record.TargetPath)): $($_.Exception.Message)")
        }
    }

    return [pscustomobject]@{
        RolledBack = ($actions.Count -gt 0)
        Actions    = [string[]]$actions.ToArray()
        DryRun     = [bool]$DryRun
    }
}

#endregion

#region 客户端注册（P0-2 / P0-3）

function ConvertFrom-ClientMcpGetText {
    <#
    .SYNOPSIS
    尽力从 `codex mcp get` / `claude mcp get` 的文本输出里还原 command/args，
    用于注册失败时的回滚。解析不出来就返回 $null（调用方降级为人工指引）。
    #>
    param([string]$Text)

    if (-not $Text) { return $null }

    $command = $null
    $arguments = @()
    foreach ($line in ($Text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $command -and $trimmed -match '^command\s*:\s*(.+)$') {
            $command = $Matches[1].Trim()
        }
        elseif ($trimmed -match '^args\s*:\s*(.*)$') {
            $raw = $Matches[1].Trim()
            if ($raw -and $raw -ne '-' -and $raw -ne '[]') {
                $arguments = @($raw -split '\s+(?=--)')
                $arguments = @($arguments | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }
        }
    }

    if (-not $command) { return $null }
    return [pscustomobject]@{ Command = $command; Arguments = [string[]]$arguments }
}

function Test-ClientRegistrationMatch {
    <#
    .SYNOPSIS
    判断已有注册是否已经等于期望参数（用于幂等：相同则不删不加）。
    #>
    param(
        [string]$ExistingText,
        [string[]]$ServerArgs
    )

    if (-not $ExistingText -or -not $ServerArgs) { return $false }

    $normalized = Get-NormalizedPathText $ExistingText
    $command = Get-NormalizedPathText $ServerArgs[0]
    if (-not $normalized.Contains($command)) { return $false }

    for ($index = 1; $index -lt $ServerArgs.Length; $index++) {
        $candidate = Get-NormalizedPathText $ServerArgs[$index]
        if (-not $normalized.Contains($candidate)) { return $false }
    }
    return $true
}

function Register-ClientMcpServer {
    <#
    .SYNOPSIS
    幂等注册 MCP server 到 codex / claude：参数一致则完全不碰，
    需要变更时先留旧配置快照再 remove + add，add 或校验失败立即还原。

    .OUTPUTS
    PSCustomObject: Client / Name / Action / Verified / VerifiedOutput / CommandLine
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet("codex", "claude")][string]$ClientName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$ServerArgs,
        [string]$ExecutablePath = "",
        $Session = $null,
        [switch]$DryRun
    )

    if (-not (Test-CommandExists $ClientName)) {
        throw "客户端 $ClientName 未安装（PATH 中找不到 $ClientName 命令）。"
    }

    $displayPath = if ($ExecutablePath) { $ExecutablePath } else { $ServerArgs[0] }
    $argv = @("mcp", "add", $Name, "--") + $ServerArgs
    $commandLine = "$ClientName mcp add $Name -- $($ServerArgs -join ' ')"

    $listText = ""
    try { $listText = (& $ClientName mcp list 2>&1 | Out-String) } catch { $listText = "" }
    $exists = [bool]($listText -match ("(?m)^\s*" + [regex]::Escape($Name) + "\b"))

    $previousText = ""
    if ($exists) {
        try { $previousText = (& $ClientName mcp get $Name 2>&1 | Out-String) } catch { $previousText = "" }
    }

    $result = [pscustomobject]@{
        Client         = $ClientName
        Name           = $Name
        Action         = "created"
        Verified       = $false
        VerifiedOutput = $null
        CommandLine    = $commandLine
        ExecutablePath = $displayPath
        RestoredOnFailure = $false
        DryRun         = [bool]$DryRun
    }

    if ($exists -and (Test-ClientRegistrationMatch -ExistingText $previousText -ServerArgs $ServerArgs)) {
        $result.Action = "unchanged"
        $result.Verified = $true
        $result.VerifiedOutput = $previousText
        return $result
    }

    $result.Action = if ($exists) { "updated" } else { "created" }

    if ($DryRun) {
        $result.Action = "would_$($result.Action)"
        Write-Info "[DryRun] $commandLine"
        return $result
    }

    $parsed = if ($exists) { ConvertFrom-ClientMcpGetText -Text $previousText } else { $null }
    if ($exists -and $null -ne $Session) {
        Add-BackupRecord -Session $Session -Kind "client" -TargetPath "$ClientName`:$Name" -Data ([pscustomobject]@{
                Client            = $ClientName
                Name              = $Name
                PreviousCommand   = if ($parsed) { $parsed.Command } else { $null }
                PreviousArguments = if ($parsed) { $parsed.Arguments } else { @() }
                PreviousText      = $previousText
            }) | Out-Null
    }

    if ($exists) {
        & $ClientName mcp remove $Name 2>&1 | Out-Null
    }

    $addOutput = ""
    try {
        $addOutput = (& $ClientName @argv 2>&1 | Out-String)
        $addExit = $LASTEXITCODE
    }
    catch {
        $addOutput = $_.Exception.Message
        $addExit = 1
    }

    if ($addExit -ne 0) {
        $restored = $false
        if ($exists -and $parsed) {
            try {
                & $ClientName mcp remove $Name 2>&1 | Out-Null
                $restoreArgv = @("mcp", "add", $Name, "--", $parsed.Command) + @($parsed.Arguments)
                & $ClientName @restoreArgv 2>&1 | Out-Null
                $restored = ($LASTEXITCODE -eq 0)
            }
            catch {
                $restored = $false
            }
        }
        $result.RestoredOnFailure = $restored
        $hint = if ($restored) { "已还原变更前的注册。" } else { "自动还原失败，变更前的配置快照见备份清单 manifest.json。" }
        throw "注册到 $ClientName 失败（exit=$addExit）：$($addOutput.Trim()) $hint"
    }

    $verifyText = ""
    try { $verifyText = (& $ClientName mcp get $Name 2>&1 | Out-String) } catch { $verifyText = "" }
    $result.VerifiedOutput = $verifyText
    $result.Verified = Test-ClientRegistrationMatch -ExistingText $verifyText -ServerArgs $ServerArgs

    if (-not $result.Verified) {
        throw "注册到 $ClientName 后校验失败：$ClientName mcp get $Name 的输出里没有预期参数。已保留输出供审计。"
    }

    return $result
}

function Restore-ClientRegistration {
    <#
    .SYNOPSIS
    回滚客户端注册：删掉当前条目，恢复变更前的 command/args。
    #>
    param($Record)

    $data = $Record.Data
    if (-not $data) { return }
    $exe = $data.Client
    if (-not (Test-CommandExists $exe)) { return }

    & $exe mcp remove $data.Name 2>$null | Out-Null
    if ($data.PreviousCommand) {
        $argv = @("mcp", "add", $data.Name, "--", $data.PreviousCommand) + @($data.PreviousArguments)
        & $exe @argv | Out-Null
    }
}

#endregion

#region Skills 同步（P0-5）

function Get-DirectoryTreeHash {
    <#
    .SYNOPSIS
    目录内容指纹：按相对路径排序后对 “路径|SHA256” 聚合。
    .PARAMETER ExcludeRelative
    不参与聚合的相对路径（用户自己新增的文件），用于判断"受管内容是否一致"。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string[]]$ExcludeRelative = @())

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $excluded = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($relativePath in @($ExcludeRelative)) {
        if ([string]::IsNullOrWhiteSpace($relativePath)) { continue }
        [void]$excluded.Add((($relativePath -replace '\\', '/').TrimStart('/')))
    }

    $lines = New-Object System.Collections.Generic.List[string]
    Get-ChildItem -LiteralPath $resolved -Recurse -File -Force -ErrorAction SilentlyContinue |
        Sort-Object FullName |
        ForEach-Object {
            $relative = $_.FullName.Substring($resolved.Length) -replace '^[\\/]+', '' -replace '\\', '/'
            if ($excluded.Contains($relative)) { return }
            $fileHash = Get-FileSha256 -Path $_.FullName
            $lines.Add("$($relative.ToLowerInvariant())|$fileHash")
        }

    $joined = ($lines -join "`n")
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($joined)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }
    return ([System.BitConverter]::ToString($hashBytes) -replace '-', '')
}

function Get-SkillSyncDecision {
    <#
    .SYNOPSIS
    纯决策：install / unchanged / update / conflict。
    managed = 在 manifest 中登记过（本项目管理的目录）。
    #>
    param(
        [string]$SourceHash,
        [string]$DestinationHash,
        [bool]$IsManaged,
        [bool]$Force
    )

    if (-not $DestinationHash) { return "install" }
    if ($SourceHash -and $SourceHash -eq $DestinationHash) { return "unchanged" }
    if ($IsManaged) { return "update" }
    if ($Force) { return "update" }
    return "conflict"
}

function Read-SkillManifest {
    param([Parameter(Mandatory)][string]$SkillRoot)

    $path = Join-Path $SkillRoot $script:SkillManifestFileName
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ Path = $path; Exists = $false; Skills = [ordered]@{} }
    }

    try {
        $raw = Read-JsonConfig -Path $path
    }
    catch {
        Write-Warning "skills manifest 解析失败，将按“全部非本项目管理”处理: $($_.Exception.Message)"
        return [pscustomobject]@{ Path = $path; Exists = $false; Skills = [ordered]@{} }
    }

    $skills = [ordered]@{}
    if ($raw -and $raw.Contains("skills") -and $raw["skills"] -is [System.Collections.IDictionary]) {
        foreach ($name in $raw["skills"].Keys) { $skills[$name] = $raw["skills"][$name] }
    }
    return [pscustomobject]@{ Path = $path; Exists = $true; Skills = $skills }
}

function Write-SkillManifest {
    param(
        [Parameter(Mandatory)][string]$SkillRoot,
        [Parameter(Mandatory)]$Skills,
        [string]$RepositoryRoot = "",
        [switch]$DryRun
    )

    $path = Join-Path $SkillRoot $script:SkillManifestFileName
    if ($DryRun) {
        Write-Step "[DryRun] 将写入 skills manifest: $path"
        return $path
    }

    $payload = [ordered]@{
        schemaVersion = 1
        generatedAt   = (Get-Date).ToString("o")
        repository    = $RepositoryRoot
        skills        = $Skills
    }
    Write-JsonFileAtomic -Path $path -Object $payload
    return $path
}

function Sync-SkillDirectory {
    <#
    .SYNOPSIS
    同步单个 skill 目录：先比对指纹，冲突默认不动，更新前备份，替换前先落到暂存目录。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [bool]$IsManaged = $false,
        $Session = $null,
        [string]$BackupRoot = "",
        [switch]$Force,
        [switch]$DryRun
    )

    # 用户自己加进技能目录的文件（源目录没有的相对路径）不能在升级时被静默删掉；
    # 同时它们不参与"受管内容是否一致"的判定，否则每次同步都会被判成 update。
    $localExtras = @()
    if (Test-Path -LiteralPath $Destination) {
        $sourceRelative = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($file in @(Get-ChildItem -LiteralPath $Source -Recurse -File -Force)) {
            [void]$sourceRelative.Add($file.FullName.Substring($Source.Length).TrimStart([char[]]'\/'))
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $Destination -Recurse -File -Force)) {
            $relative = $file.FullName.Substring($Destination.Length).TrimStart([char[]]'\/')
            if (-not $sourceRelative.Contains($relative)) { $localExtras += $relative }
        }
    }

    $sourceHash = Get-DirectoryTreeHash -Path $Source
    $destinationHash = Get-DirectoryTreeHash -Path $Destination -ExcludeRelative $localExtras
    $decision = Get-SkillSyncDecision -SourceHash $sourceHash -DestinationHash $destinationHash `
        -IsManaged $IsManaged -Force:$Force

    $result = [pscustomobject]@{
        Name            = $Name
        Destination     = $Destination
        Decision        = $decision
        Changed         = ($decision -in @("install", "update"))
        SourceHash      = $sourceHash
        DestinationHash = $destinationHash
        BackupPath      = $null
        Message         = ""
        PreservedUserFiles = @()
        RestoredFromBackup = $false
        RecreatedFiles  = 0
        MissingAfterRestore = @()
    }

    switch ($decision) {
        "unchanged" {
            if ($localExtras.Count -gt 0) {
                # 未交换也要如实报告"目录里存在用户文件"，否则脚本化消费者看到空数组会误判。
                $result.PreservedUserFiles = [string[]]$localExtras
                $result.Message = "受管内容一致，跳过（保留用户新增文件 $($localExtras.Count) 个）"
            } else {
                $result.Message = "内容一致，跳过"
            }
            return $result
        }
        "conflict" {
            $result.Changed = $false
            $result.Message = "目标目录已存在且内容不同，且不属于本项目管理的技能（未在 manifest 中登记）。默认不覆盖；确认后可用 -Force。"
            return $result
        }
    }

    if ($DryRun) {
        $result.Message = "将$($decision)：$Destination"
        return $result
    }

    $staging = "$Destination.__incoming__$([guid]::NewGuid().ToString('N'))"
    try {
        Copy-Item -LiteralPath $Source -Destination $staging -Recurse -Force

        if (Test-Path -LiteralPath $Destination) {
            if ($null -ne $Session) {
                $result.BackupPath = Save-DirectoryBackupToSession -Session $Session -Path $Destination -Label $Name
            }
            elseif ($BackupRoot) {
                $tempSession = New-BackupSession -Root $BackupRoot -Reason "skill-$Name"
                $result.BackupPath = Save-DirectoryBackupToSession -Session $tempSession -Path $Destination -Label $Name
                Save-BackupManifest -Session $tempSession
            }
            # 必须显式 Stop：Remove-Item -Recurse 遇到被占用文件默认只报非终止错误，
            # 会继续走到 Move-Item，最后把"缺文件的半装目录"当成成功上报。
            Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction Stop
        }
        elseif ($null -ne $Session) {
            Add-BackupRecord -Session $Session -Kind "dir-absent" -TargetPath $Destination | Out-Null
        }

        Move-Item -LiteralPath $staging -Destination $Destination -ErrorAction Stop
        # 交换后自检：目标必须包含源目录的全部文件，否则判失败并进入恢复路径。
        $missingAfterSwap = @(Get-ChildItem -LiteralPath $Source -Recurse -File -Force | Where-Object {
            $relativeFile = $_.FullName.Substring($Source.Length).TrimStart([char[]]'\/')
            -not (Test-Path -LiteralPath (Join-Path $Destination $relativeFile))
        })
        if ($missingAfterSwap.Count -gt 0) {
            throw "SYNC_INCOMPLETE: 交换后缺少 $($missingAfterSwap.Count) 个文件"
        }
        if ($localExtras.Count -gt 0 -and $result.BackupPath -and (Test-Path -LiteralPath $result.BackupPath)) {
            $preserved = @()
            foreach ($relative in $localExtras) {
                $from = Join-Path $result.BackupPath $relative
                $to = Join-Path $Destination $relative
                if (-not (Test-Path -LiteralPath $from)) { continue }
                $parent = Split-Path -Parent $to
                if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
                Copy-Item -LiteralPath $from -Destination $to -Force
                $preserved += $relative
            }
            $result.PreservedUserFiles = [string[]]$preserved
        }
        $result.Message = if ($decision -eq "install") { "已安装" } else { "已更新（旧版本已备份）" }
        if (@($result.PreservedUserFiles).Count -gt 0) {
            $result.Message += "；保留用户新增文件 $($result.PreservedUserFiles.Count) 个"
        }
        return $result
    }
    catch {
        $result.Changed = $false
        $result.Decision = "error"
        # 单技能失败必须自愈。关键：不能再用"删除目标目录"来恢复——
        # 失败原因往往正是某个文件被占用，再删一次会撞同一个锁；而且删除成功一半时
        # 目标目录已经残缺。这里改成"只重建缺失文件"：仍在的文件（含被占用的那个）
        # 保持原样，缺的从本次备份补回，因此不依赖任何删除操作。
        $restored = $false
        if ($result.BackupPath -and (Test-Path -LiteralPath $result.BackupPath)) {
            try {
                if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Force -Path $Destination | Out-Null }
                $backupRoot = (Resolve-Path -LiteralPath $result.BackupPath).Path
                $recreated = 0
                foreach ($backupFile in @(Get-ChildItem -LiteralPath $backupRoot -Recurse -File -Force)) {
                    $relative = $backupFile.FullName.Substring($backupRoot.Length).TrimStart([char[]]'\/')
                    $target = Join-Path $Destination $relative
                    if (Test-Path -LiteralPath $target) { continue }
                    $parent = Split-Path -Parent $target
                    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
                    Copy-Item -LiteralPath $backupFile.FullName -Destination $target -Force -ErrorAction Stop
                    $recreated++
                }
                foreach ($backupDirectory in @(Get-ChildItem -LiteralPath $backupRoot -Recurse -Directory -Force)) {
                    $relative = $backupDirectory.FullName.Substring($backupRoot.Length).TrimStart([char[]]'\/')
                    $target = Join-Path $Destination $relative
                    if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Force -Path $target | Out-Null }
                }
                $result.RecreatedFiles = $recreated
                # 恢复成功的判据是"备份里的每个文件都已在目标上"，而不是"没抛异常"。
                $stillMissing = @(Get-ChildItem -LiteralPath $backupRoot -Recurse -File -Force | Where-Object {
                    $relativeFile = $_.FullName.Substring($backupRoot.Length).TrimStart([char[]]'\/')
                    -not (Test-Path -LiteralPath (Join-Path $Destination $relativeFile))
                })
                $restored = ($stillMissing.Count -eq 0)
                if (-not $restored) { $result.MissingAfterRestore = [string[]]$stillMissing }
            } catch { $restored = $false }
        }
        $result.RestoredFromBackup = $restored
        $result.Message = "同步失败: $($_.Exception.Message)" +
            $(if ($restored) { "；已从备份补齐缺失文件（重建 $($result.RecreatedFiles) 个），被占用的文件保持原样" } else { "；未能恢复，可能留下半装目录，请检查" })
        return $result
    }
    finally {
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

#endregion

#region startup.m 托管块（P0-6）

function Get-StartupShareBlock {
    param(
        [string]$BeginMarker = $script:StartupBeginMarker,
        [string]$EndMarker = $script:StartupEndMarker
    )

    $lines = @(
        $BeginMarker,
        "if exist('shareMATLABSession','file') == 2",
        "    try",
        "        shareMATLABSession();",
        "    catch me",
        "        warning('MATLAB:MCP:ShareFailed', 'shareMATLABSession failed: %s', me.message);",
        "    end",
        "end",
        $EndMarker
    )
    return ($lines -join "`n")
}

function Merge-StartupShareFile {
    <#
    .SYNOPSIS
    把共享钩子写进 startup.m：用托管标记块包住，重复执行只替换托管块，绝不重写用户其它内容。

    .OUTPUTS
    PSCustomObject: Path / Action / Changed / Content / BackupPath / DryRun
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$BeginMarker = $script:StartupBeginMarker,
        [string]$EndMarker = $script:StartupEndMarker,
        $Session = $null,
        [string]$BackupRoot = "",
        [switch]$DryRun
    )

    $block = Get-StartupShareBlock -BeginMarker $BeginMarker -EndMarker $EndMarker
    $exists = Test-Path -LiteralPath $Path
    $current = if ($exists) { Get-Content -Raw -LiteralPath $Path } else { "" }
    if ($null -eq $current) { $current = "" }

    $newline = "`n"
    if ($current -match "`r`n") { $newline = "`r`n" }

    $hasBegin = $current.Contains($BeginMarker)
    $hasEnd = $current.Contains($EndMarker)
    $hasForeignHook = (-not $hasBegin) -and ($current -match 'shareMATLABSession')

    $result = [pscustomobject]@{
        Path       = $Path
        Action     = "unchanged"
        Changed    = $false
        Content    = $current
        BackupPath = $null
        DryRun     = [bool]$DryRun
    }

    if ($hasForeignHook) {
        $result.Action = "skipped-foreign-hook"
        $result.Content = $current
        return $result
    }

    if ($hasBegin -and $hasEnd) {
        $pattern = "(?s)" + [regex]::Escape($BeginMarker) + ".*?" + [regex]::Escape($EndMarker)
        $updated = [regex]::Replace($current, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            return $block
        })
        $result.Action = "replaced-managed-block"
    }
    elseif (-not $exists -or [string]::IsNullOrWhiteSpace($current)) {
        $updated = $block
        $result.Action = "created"
    }
    else {
        $trimmed = $current.TrimEnd([char[]]@("`r", "`n"))
        $updated = $trimmed + $newline + $newline + $block
        $result.Action = "appended"
    }

    if ($newline -eq "`r`n") {
        $updated = $updated -replace "(?<!`r)`n", "`r`n"
    }

    # 统一成“单个结尾换行”，并用归一化结果做比较，保证重复执行判定为 unchanged。
    $normalizedUpdated = $updated.TrimEnd([char[]]@("`r", "`n")) + $newline
    $normalizedCurrent = ""
    if ($exists -and -not [string]::IsNullOrWhiteSpace($current)) {
        $normalizedCurrent = $current.TrimEnd([char[]]@("`r", "`n")) + $newline
    }

    if ($normalizedUpdated -eq $normalizedCurrent) {
        $result.Action = "unchanged"
        $result.Content = $normalizedCurrent
        return $result
    }

    $result.Content = $normalizedUpdated
    $result.Changed = $true

    if ($DryRun) {
        $result.Action = "would-$($result.Action)"
        return $result
    }

    if ($null -ne $Session) {
        $result.BackupPath = Save-FileBackupToSession -Session $Session -Path $Path -Label "startup"
    }
    elseif ($BackupRoot) {
        $tempSession = New-BackupSession -Root $BackupRoot -Reason "startup"
        $result.BackupPath = Save-FileBackupToSession -Session $tempSession -Path $Path -Label "startup"
        Save-BackupManifest -Session $tempSession
    }

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $result.Content, $encoding)
    return $result
}

#endregion

#region Windows 目录 ACL（P0-6）

# FileSystemRights.FullControl 的数值（含 Synchronize 0x100000）。
# 用常量而不是 [enum]::Parse，是为了在 PS 5.1 与 7 上得到同一结果。
$script:FileSystemFullControlMask = 2032127

function Get-AclNormalizedRules {
    <#
    .SYNOPSIS
    取目录 DACL 中属于指定 SID 的 ACE，并归一化成可直接比较的结构。

    .DESCRIPTION
    用 GetAccessRules(..., [SecurityIdentifier]) 拿 SID 对象，避免 SDDL 别名问题
    （S-1-5-21-xxx-500 在 SDDL 里是 LA、S-1-5-18 是 SY、S-1-5-32-544 是 BA）。

    每条规则输出：
      AccessType    Allow / Deny
      Rights        FileSystemRights 的整数掩码
      Inheritance   ContainerInherit / ObjectInherit
      Propagation   None / NoPropagateInherit / InheritOnly
      AppliesToSelf 该 ACE 是否作用于目录本身（InheritOnly 的 ACE 不作用于自身）
      AppliesToChild 该 ACE 是否会被子对象继承
      IsInherited   是否来自父目录继承（用于诊断，不参与判定）

    注意：这里只做"同一 SID 上的 ACE 集合"层面的计算，不做组展开。
    也就是说它回答的是"这条授权是否真的把 FullControl 给了这个 SID"，
    而不是"这个登录令牌的全部有效权限"。后者需要 AccessCheck，超出本仓库职责。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Sid
    )

    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    try {
        $acl = Get-Acl -LiteralPath $Path
        $rules = $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])
    }
    catch {
        return @()
    }

    $normalized = New-Object System.Collections.ArrayList
    foreach ($rule in $rules) {
        if ($null -eq $rule) { continue }

        $ruleSid = $null
        try { $ruleSid = [string]$rule.IdentityReference.Value } catch { continue }
        if ($ruleSid -ne $Sid) { continue }

        $rights = 0
        try { $rights = [int]$rule.FileSystemRights } catch { $rights = 0 }

        $inheritance = [System.Security.AccessControl.InheritanceFlags]::None
        try {
            if ($null -ne $rule.InheritanceFlags) { $inheritance = $rule.InheritanceFlags }
        }
        catch { $inheritance = [System.Security.AccessControl.InheritanceFlags]::None }

        $propagation = [System.Security.AccessControl.PropagationFlags]::None
        try {
            if ($null -ne $rule.PropagationFlags) { $propagation = $rule.PropagationFlags }
        }
        catch { $propagation = [System.Security.AccessControl.PropagationFlags]::None }

        $isInherited = $false
        try { $isInherited = [bool]$rule.IsInherited } catch { $isInherited = $false }

        $inheritOnly = (($propagation -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0)
        $hasContainer = (($inheritance -band [System.Security.AccessControl.InheritanceFlags]::ContainerInherit) -ne 0)
        $hasObject = (($inheritance -band [System.Security.AccessControl.InheritanceFlags]::ObjectInherit) -ne 0)

        [void]$normalized.Add([pscustomobject]@{
                Sid            = $ruleSid
                AccessType     = [string]$rule.AccessControlType
                Rights         = $rights
                Inheritance    = $inheritance
                Propagation    = $propagation
                HasContainer   = $hasContainer
                HasObject      = $hasObject
                InheritOnly    = $inheritOnly
                AppliesToSelf  = (-not $inheritOnly)
                AppliesToChild = ($hasContainer -or $hasObject)
                IsInherited    = $isInherited
            })
    }

    return $normalized.ToArray()
}

function Resolve-AclRuleSet {
    <#
    .SYNOPSIS
    纯函数：由归一化后的 ACE 集合计算目录自身与子对象的有效权限。

    .DESCRIPTION
    抽成纯函数是为了让"多条 ACE / Deny 优先 / InheritOnly"这些语义能被单测覆盖，
    而不必依赖 icacls 是否把同一 SID 的多条 ACE 合并（实测它会合并，
    所以用真实 ACL 造不出所有组合）。

    规则必须包含：AccessType(Allow|Deny)、Rights(int)、AppliesToSelf(bool)、
    AppliesToChild(bool)、HasContainer(bool)、HasObject(bool)。

    求值方式与 Windows DACL 一致的两条核心语义：
    1. 同一 SID 的 Allow 取并集、Deny 取并集，最终 Allow & ~Deny —— Deny 优先；
    2. 继承标志决定 ACE 是否作用于子对象；InheritOnly 的 ACE 不作用于目录自身。
    #>
    param([object[]]$Rules = @())

    $selfAllow = 0; $selfDeny = 0
    $childAllow = 0; $childDeny = 0
    $hasInheritingFullControl = $false

    foreach ($rule in @($Rules)) {
        if ($null -eq $rule) { continue }

        $type = [string]$rule.AccessType
        if ($type -ne "Allow" -and $type -ne "Deny") { continue }

        $rights = [int]$rule.Rights
        $appliesToSelf = [bool]$rule.AppliesToSelf
        $appliesToChild = [bool]$rule.AppliesToChild

        if ($appliesToSelf) {
            if ($type -eq "Deny") { $selfDeny = $selfDeny -bor $rights }
            else { $selfAllow = $selfAllow -bor $rights }
        }
        if ($appliesToChild) {
            if ($type -eq "Deny") { $childDeny = $childDeny -bor $rights }
            else { $childAllow = $childAllow -bor $rights }
        }

        if ($type -eq "Allow" -and [bool]$rule.HasContainer -and [bool]$rule.HasObject) {
            if (($rights -band $script:FileSystemFullControlMask) -eq $script:FileSystemFullControlMask) {
                $hasInheritingFullControl = $true
            }
        }
    }

    return [pscustomobject]@{
        FolderAllow              = $selfAllow
        FolderDeny               = $selfDeny
        ChildAllow               = $childAllow
        ChildDeny                = $childDeny
        FolderRights             = ($selfAllow -band (-bnot $selfDeny))
        ChildRights              = ($childAllow -band (-bnot $childDeny))
        HasInheritingFullControl = $hasInheritingFullControl
    }
}

function Measure-AclEffectiveRights {
    <#
    .SYNOPSIS
    按"同一 SID 的 ACE 集合"计算目录本身与子对象上的有效权限掩码。

    .DESCRIPTION
    采集真实 DACL 后交给 Resolve-AclRuleSet 求值。
    FolderRights（目录自身）与 ChildRights（子对象继承后）必须分别检查：
    目录可写但新文件不可继承，是真实存在的失败形态。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Sid
    )

    $rules = @(Get-AclNormalizedRules -Path $Path -Sid $Sid)
    $resolved = Resolve-AclRuleSet -Rules $rules

    return [pscustomobject]@{
        Path                     = $Path
        Sid                      = $Sid
        PathExists               = (Test-Path -LiteralPath $Path)
        RuleCount                = $rules.Count
        Rules                    = $rules
        FolderAllow              = $resolved.FolderAllow
        FolderDeny               = $resolved.FolderDeny
        ChildAllow               = $resolved.ChildAllow
        ChildDeny                = $resolved.ChildDeny
        FolderRights             = $resolved.FolderRights
        ChildRights              = $resolved.ChildRights
        HasInheritingFullControl = $resolved.HasInheritingFullControl
    }
}

function Format-FileSystemRights {
    <#
    .SYNOPSIS
    把权限掩码渲染成"已有 / 缺失"的关键位，用于失败原因。

    只列会影响"目录能否正常读写与清理"的位；不是完整枚举，
    但对"只读 ACE 被当成 FullControl"这类误判足够定位。
    #>
    param([int]$Mask)

    $known = @(
        @{ Name = "ReadData"; Bit = 0x1 }
        @{ Name = "WriteData"; Bit = 0x2 }
        @{ Name = "AppendData"; Bit = 0x4 }
        @{ Name = "DeleteSubdirectoriesAndFiles"; Bit = 0x40 }
        @{ Name = "Delete"; Bit = 0x10000 }
        @{ Name = "ChangePermissions"; Bit = 0x40000 }
        @{ Name = "TakeOwnership"; Bit = 0x80000 }
    )

    $have = New-Object System.Collections.ArrayList
    $missing = New-Object System.Collections.ArrayList
    foreach ($item in $known) {
        if (($Mask -band $item.Bit) -eq $item.Bit) { [void]$have.Add($item.Name) }
        else { [void]$missing.Add($item.Name) }
    }

    if ($missing.Count -eq 0) { return "FullControl" }
    $haveText = if ($have.Count -gt 0) { $have -join "," } else { "无" }
    return ("已有[$haveText] 缺失[$($missing -join ',')] 掩码=0x{0:X}" -f $Mask)
}

function Test-AclGrantsFullControl {
    <#
    .SYNOPSIS
    判断某个 SID 在目录上是否**真的**拥有 FullControl（含子对象继承）。

    .DESCRIPTION
    "SID 出现在 ACL 里"和"这个 SID 有完整权限"是两件事：
      - 只有 Deny ACE 时 SID 也在 ACL 里，但权限是零；
      - 只有 (OI)(CI)R 时 SID 也在，但目录只读；
      - 有 FullControl 但 InheritanceFlags=None 时，目录可写、新建子项却可能不可访问；
      - 同一 SID 有多条 ACE 时，任取一条判断都不成立，必须做集合运算。

    本函数返回 Granted + Reason + 两个掩码，拒绝时 Reason 可直接进错误信息。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Sid,
        [switch]$RequireInheritance
    )

    $required = $script:FileSystemFullControlMask
    $measurement = Measure-AclEffectiveRights -Path $Path -Sid $Sid
    $issues = New-Object System.Collections.ArrayList

    if (-not $measurement.PathExists) {
        [void]$issues.Add("路径不存在：$Path")
    }
    elseif ($measurement.RuleCount -eq 0) {
        [void]$issues.Add("该 SID 在目录 DACL 中没有任何 ACE（既无 Allow 也无 Deny）")
    }
    else {
        $denyOnly = $true
        foreach ($rule in $measurement.Rules) {
            if ($rule.AccessType -eq "Allow") { $denyOnly = $false; break }
        }
        if ($denyOnly) {
            [void]$issues.Add(("该 SID 只有 Deny ACE，有效权限为 0（掩码=0x{0:X}）" -f $measurement.FolderDeny))
        }

        if (($measurement.FolderRights -band $required) -ne $required) {
            [void]$issues.Add("目录自身权限不足：" + (Format-FileSystemRights -Mask $measurement.FolderRights))
        }

        if ($measurement.FolderDeny -ne 0) {
            [void]$issues.Add(("存在 Deny ACE（掩码=0x{0:X}），已从 Allow 中扣除" -f $measurement.FolderDeny))
        }

        if ($RequireInheritance) {
            if (($measurement.ChildRights -band $required) -ne $required) {
                [void]$issues.Add("子对象继承后权限不足：" + (Format-FileSystemRights -Mask $measurement.ChildRights))
            }
            if (-not $measurement.HasInheritingFullControl) {
                [void]$issues.Add("没有同时带 (OI)(CI) 的 FullControl Allow ACE，新建文件/子目录无法继承完整权限")
            }
        }
    }

    return [pscustomobject]@{
        Path          = $Path
        Sid           = $Sid
        Granted       = ($issues.Count -eq 0)
        Reason        = $(if ($issues.Count -eq 0) { "" } else { ($issues -join "；") })
        FolderRights  = $measurement.FolderRights
        ChildRights   = $measurement.ChildRights
        FolderDeny    = $measurement.FolderDeny
        RuleCount     = $measurement.RuleCount
        Rules         = $measurement.Rules
        RequireInheritance = [bool]$RequireInheritance
    }
}

function Test-AclContainsSid {
    <#
    .SYNOPSIS
    判断目录的访问规则里是否存在指定 SID（按 SID 语义比较，不比字符串）。

    .DESCRIPTION
    这是**存在性**判断，不代表权限正确。要判断"是否真的可访问"请用
    Test-AclGrantsFullControl —— 它同时看 AccessControlType、权限掩码与继承标志。

    保留本函数的原因：
    - 给"ACL 里是否出现过这个 SID"这一类审计与诊断用；
    - 旧调用点与回归用例依赖它，语义不变。

    不能用 "SDDL 文本里是否包含 SID 字面量" 来判断：
    Get-Acl 生成的 SDDL 会把知名 SID 渲染成**别名**，例如
      S-1-5-21-xxx-500  ->  LA（Local Administrator）
      S-1-5-18          ->  SY
      S-1-5-32-544      ->  BA
    于是"给内置管理员账户授权"在 SDDL 里表现为 `(A;OICI;FA;;;LA)`，
    用 SID 字面量去搜必然搜不到，会把一次成功的授权误判成失败并触发回滚。
    实测触发环境：GitHub Actions runner（runneradmin 的 RID 是 500）；
    普通用户（RID 非 500）不会有别名，所以本机一直是通过的。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Sid
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    return (@(Get-AclNormalizedRules -Path $Path -Sid $Sid).Count -gt 0)
}

function Get-DirectoryAclSnapshot {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $acl = Get-Acl -LiteralPath $Path
    return [pscustomobject]@{
        Path = $Path
        Sddl = $acl.Sddl
        Owner = $acl.Owner
    }
}

function Get-AclFingerprint {
    <#
    .SYNOPSIS
    取 SDDL 的 DACL 指纹（ACE 集合排序后拼接）。

    说明：SDDL 前面的控制位（AI/AR/P 等，自动继承标记）在 Set-Acl 之后可能变化，
    但它不影响实际授权语义，所以比较 ACL 是否还原时用 ACE 指纹而不是整串 SDDL。
    #>
    param([string]$Sddl)

    if (-not $Sddl) { return "" }
    $daclIndex = $Sddl.IndexOf("D:")
    if ($daclIndex -lt 0) { return $Sddl }

    $dacl = $Sddl.Substring($daclIndex + 2)
    $aceIndex = $dacl.IndexOf("(")
    if ($aceIndex -gt 0) { $dacl = $dacl.Substring($aceIndex) }

    $aces = @([regex]::Matches($dacl, '\([^()]*\)') | ForEach-Object { $_.Value })
    return (($aces | Sort-Object) -join "")
}

function Set-DirectoryAclGrant {
    <#
    .SYNOPSIS
    给当前用户追加 FullControl ACE。默认不动继承、不删其它 ACE。

    .PARAMETER RestrictInheritance
    复刻历史行为（icacls /inheritance:r）——会移除继承 ACE，仅在明确需要时开启，且必须配合备份。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Sid = "",
        [switch]$RestrictInheritance,
        $Session = $null,
        [switch]$DryRun
    )

    if (-not (Test-CommandExists "icacls")) {
        throw "当前环境没有 icacls，无法设置目录 ACL。"
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        if ($DryRun) {
            Write-Step "[DryRun] 将创建目录 $Path"
        }
        else {
            New-Item -ItemType Directory -Force -Path $Path | Out-Null
            if ($null -ne $Session) {
                Add-BackupRecord -Session $Session -Kind "dir-absent" -TargetPath $Path | Out-Null
            }
        }
    }

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $userSid = if ($Sid) { $Sid } else { $identity.User.Value }
    $before = Get-DirectoryAclSnapshot -Path $Path

    $icaclsArgs = @($Path)
    if ($RestrictInheritance) { $icaclsArgs += "/inheritance:r" }
    $grantSpec = "*" + $userSid + ":(OI)(CI)F"
    $icaclsArgs += @("/grant:r", $grantSpec)

    $result = [pscustomobject]@{
        Path       = $Path
        UserSid    = $userSid
        BeforeSddl = if ($before) { $before.Sddl } else { $null }
        AfterSddl  = $null
        RestrictedInheritance = [bool]$RestrictInheritance
        Applied    = $false
        DryRun     = [bool]$DryRun
        CommandLine = ("icacls " + ($icaclsArgs -join " "))
    }

    if ($DryRun) { return $result }

    if ($null -ne $Session -and $before) {
        Add-BackupRecord -Session $Session -Kind "acl" -TargetPath $Path -Data ([pscustomobject]@{ Before = $before.Sddl }) | Out-Null
    }

    & icacls @icaclsArgs | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "icacls 执行失败（exit=$LASTEXITCODE）: $($result.CommandLine)"
    }

    $after = Get-DirectoryAclSnapshot -Path $Path
    $result.AfterSddl = $after.Sddl
    $result.Applied = $true

    # 写后校验必须看"有效权限"，不能只看 SID 是否存在：
    #   - SID 存在但只有 Deny ACE  -> 实际无权限
    #   - SID 存在但只有 R（只读）  -> 目录不可写，安装会中途失败
    #   - SID 存在且是 FullControl 但 InheritanceFlags=None -> 目录可写、新建子项不可继承
    #   - 同一 SID 有多条 ACE（如 R + W 分开授权）-> 必须做集合运算
    # 这里默认还要求带 (OI)(CI) 继承，因为授权目的就是让新文件/子目录可用。
    # 授予语句固定是 "(OI)(CI)F"，所以这是一个不随 RestrictInheritance 变化的硬要求：
    # /inheritance:r 只移除父目录继承来的 ACE，不会去掉我们刚加的 (OI)(CI)F。
    $verification = Test-AclGrantsFullControl -Path $Path -Sid $userSid -RequireInheritance

    $result | Add-Member -NotePropertyName Verified -NotePropertyValue $verification.Granted -Force
    $result | Add-Member -NotePropertyName Verification -NotePropertyValue $verification -Force

    if (-not $verification.Granted) {
        throw ("ACL 写入后校验未通过（SID=$userSid）：" + $verification.Reason + " 已触发回滚。")
    }

    return $result
}

#endregion
