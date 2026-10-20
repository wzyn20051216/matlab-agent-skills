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
    $candidates.Add((Join-Path (Get-Location).Path "matlab-mcp-server-windows-x64.exe"))
    $candidates.Add((Join-Path $HOME "Downloads\matlab-mcp-server-windows-x64.exe"))
    $candidates.Add((Join-Path $HOME "download\matlab-mcp-server-windows-x64.exe"))
    return [string[]]$candidates.ToArray()
}

function Resolve-McpServerExecutable {
    <#
    .SYNOPSIS
    找到或下载 MCP server 可执行文件。

    安全措施：下载走 Save-VerifiedDownload（HTTPS、临时文件、可选 SHA256、原子替换），
    已存在文件默认复用（幂等），可用 -ForceDownload 覆盖。
    #>
    [CmdletBinding()]
    param(
        [string]$Hint,
        [string]$DownloadUrl = "https://github.com/matlab/matlab-mcp-server/releases/latest/download/matlab-mcp-server-windows-x64.exe",
        [string]$ScriptRoot,
        [string]$ExpectedSha256 = "",
        [switch]$NoDownload,
        [switch]$ForceDownload,
        [switch]$DryRun
    )

    if ($Hint) {
        if (-not (Test-Path -LiteralPath $Hint)) { throw "指定的 ServerExePath 不存在: $Hint" }
        $resolved = (Resolve-Path -LiteralPath $Hint).Path
        return [pscustomobject]@{
            Path     = $resolved
            Source   = "explicit"
            Sha256   = (Get-FileSha256 -Path $resolved)
            Verified = (Test-HashMatch -Expected $ExpectedSha256 -Actual (Get-FileSha256 -Path $resolved))
            Downloaded = $false
        }
    }

    foreach ($candidate in (Get-McpServerCandidatePaths -ScriptRoot $ScriptRoot)) {
        if (Test-Path -LiteralPath $candidate) {
            $resolved = (Resolve-Path -LiteralPath $candidate).Path
            $sha = Get-FileSha256 -Path $resolved
            return [pscustomobject]@{
                Path     = $resolved
                Source   = "existing"
                Sha256   = $sha
                Verified = (Test-HashMatch -Expected $ExpectedSha256 -Actual $sha)
                Downloaded = $false
            }
        }
    }

    if ($NoDownload) {
        throw "未找到 matlab-mcp-server 可执行文件，且指定了 -NoDownload。请用 -ServerExePath 显式传入。"
    }

    $binDir = if ($ScriptRoot) { Join-Path $ScriptRoot "..\bin" } else { Join-Path (Get-Location).Path "bin" }
    $downloadPath = Join-Path $binDir "matlab-mcp-server-windows-x64.exe"

    $download = Save-VerifiedDownload -Uri $DownloadUrl -Destination $downloadPath `
        -ExpectedSha256 $ExpectedSha256 -DryRun:$DryRun

    return [pscustomobject]@{
        Path       = $downloadPath
        Source     = "download"
        Sha256     = $download.Sha256
        Verified   = $download.Verified
        Downloaded = [bool]$download.Downloaded
    }
}

#endregion

#region 下载（P0-6）

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

        if ($ExpectedSha256) {
            if (-not (Test-HashMatch -Expected $ExpectedSha256 -Actual $sha)) {
                throw "SHA256 校验失败。期望 $ExpectedSha256，实际 $sha。已丢弃下载内容。"
            }
            $record.Verified = $true
        }
        else {
            Write-Warning "未提供 -ExpectedServerSha256，无法校验下载文件来源完整性。实际 SHA256=$sha（已记录到安装摘要）。"
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
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $resolved = (Resolve-Path -LiteralPath $Path).Path

    $lines = New-Object System.Collections.Generic.List[string]
    Get-ChildItem -LiteralPath $resolved -Recurse -File -Force -ErrorAction SilentlyContinue |
        Sort-Object FullName |
        ForEach-Object {
            $relative = $_.FullName.Substring($resolved.Length) -replace '^[\\/]+', '' -replace '\\', '/'
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

    $sourceHash = Get-DirectoryTreeHash -Path $Source
    $destinationHash = Get-DirectoryTreeHash -Path $Destination
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
    }

    switch ($decision) {
        "unchanged" {
            $result.Message = "内容一致，跳过"
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
            Remove-Item -LiteralPath $Destination -Recurse -Force
        }
        elseif ($null -ne $Session) {
            Add-BackupRecord -Session $Session -Kind "dir-absent" -TargetPath $Destination | Out-Null
        }

        Move-Item -LiteralPath $staging -Destination $Destination
        $result.Message = if ($decision -eq "install") { "已安装" } else { "已更新（旧版本已备份）" }
        return $result
    }
    catch {
        $result.Changed = $false
        $result.Message = "同步失败: $($_.Exception.Message)"
        throw
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
