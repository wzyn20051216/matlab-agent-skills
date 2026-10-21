<#
.SYNOPSIS
一键下载并安装 matlab-agent-skills 与 MATLAB MCP 客户端接入。

.DESCRIPTION
安全策略（第一阶段 P0 重构后）：
- 仓库获取失败时不再静默覆盖：git pull 失败只告警并继续使用现有检出。
- ZIP 分支解压到唯一临时目录，避免误删他人共用的临时目录。
- MCP server 二进制默认复用已存在文件（幂等），下载要求 HTTPS 且可选 SHA256 校验。
- 支持 -DryRun 预演；下游脚本共享同一备份根目录。

.PARAMETER Force
强制重新下载二进制 / 强制覆盖技能目录中的外来内容。
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $HOME "matlab-agent-skills"),
    [string]$RepoUrl = "https://github.com/wzyn20051216/matlab-agent-skills.git",
    [string]$RepoZipUrl = "https://github.com/wzyn20051216/matlab-agent-skills/archive/refs/heads/main.zip",
    [string]$McpServerDownloadUrl = "",
    [string]$ServerName = "matlab-official",
    [ValidateSet("auto", "existing", "new")]
    [string]$SessionMode = "auto",
    [bool]$InitializeMatlabOnStartup = $true,
    [ValidateSet("desktop", "nodesktop")]
    [string]$DisplayMode = "desktop",
    [string[]]$Clients = @("auto"),
    [string]$MatlabRoot = "",
    [string]$SkillRoot = "",
    [string]$ExpectedServerSha256 = "",
    [string]$BackupRoot = "",
    [switch]$SkipBaseSetup,
    [switch]$SkipSkillsSync,
    [switch]$NoDownload,
    [switch]$AllowUnverifiedServer,
    [switch]$Force,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

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
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Ensure-Repo {
    param(
        [string]$TargetDir,
        [string]$GitUrl,
        [string]$ZipUrl
    )

    if (Test-Path -LiteralPath (Join-Path $TargetDir ".git")) {
        Write-Step "更新已有仓库"
        if ($DryRun) {
            Write-Info "[DryRun] git -C $TargetDir pull --ff-only"
            return $TargetDir
        }
        try {
            git -C $TargetDir pull --ff-only | Out-Null
        }
        catch {
            Write-Warning "git pull 失败（可能有本地修改），继续使用现有检出: $($_.Exception.Message)"
        }
        return $TargetDir
    }

    if ($DryRun) {
        Write-Info "[DryRun] 将把仓库获取到 $TargetDir"
        return $TargetDir
    }

    if (-not (Test-Path -LiteralPath $TargetDir)) {
        New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
    }

    if (Test-CommandExists "git") {
        Write-Step "克隆仓库"
        git clone $GitUrl $TargetDir | Out-Null
        return $TargetDir
    }

    Write-Step "下载仓库 ZIP"
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("matlab-agent-skills-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
    try {
        $zipPath = Join-Path $tempRoot "repo.zip"
        Invoke-WebRequest -Uri $ZipUrl -OutFile $zipPath -UseBasicParsing
        Expand-Archive -Path $zipPath -DestinationPath $tempRoot -Force

        $extracted = Get-ChildItem -LiteralPath $tempRoot -Directory | Select-Object -First 1
        if (-not $extracted) { throw "ZIP 解压后没有找到仓库目录" }

        Copy-Item -Path (Join-Path $extracted.FullName "*") -Destination $TargetDir -Recurse -Force
        return $TargetDir
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$repoDir = Ensure-Repo -TargetDir $InstallDir -GitUrl $RepoUrl -ZipUrl $RepoZipUrl

$corePath = Join-Path (Join-Path $repoDir "scripts") "MatlabAgentSkills.Core.psm1"
if (-not (Test-Path -LiteralPath $corePath)) {
    throw "仓库不完整，缺少核心模块: $corePath"
}
Import-Module -Name $corePath -Force -DisableNameChecking

if (-not $BackupRoot) {
    $BackupRoot = Join-Path (Join-Path $repoDir "artifacts") "backups"
}

Write-Step "解析 MATLAB 安装目录"
$resolvedMatlabRoot = Resolve-MatlabRoot -Hint $MatlabRoot
Write-Info "matlabRoot: $resolvedMatlabRoot"

Write-Step "准备 MATLAB MCP Server 二进制（固定清单校验）"
$server = Resolve-McpServerExecutable -ScriptRoot (Join-Path $repoDir "scripts") `
    -DownloadUrl $McpServerDownloadUrl -ExpectedSha256 $ExpectedServerSha256 `
    -NoDownload:$NoDownload -ForceDownload:$Force -AllowUnverifiedServer:$AllowUnverifiedServer -DryRun:$DryRun
$binPath = $server.Path
$serverExePath = $server.Path
$serverSha = $server.Sha256
$serverVerified = [bool]$server.Verified
Write-Info "server: $binPath (source=$($server.Source), release=$($server.ReleaseTag), integrity=$($server.IntegrityStatus))"
# Verified=false 不能被静默当成成功；DryRun 只预演，不做信任断言。
if (-not $DryRun) {
    Assert-McpServerTrusted -Server $server -AllowUnverifiedServer:$AllowUnverifiedServer
}

if (-not $SkipSkillsSync) {
    Write-Step "同步 Skills"
    $syncScript = Join-Path (Join-Path $repoDir "scripts") "Sync-Skills.ps1"
    if (-not (Test-Path -LiteralPath $syncScript)) { throw "缺少脚本: $syncScript" }
    $syncSummary = & $syncScript -RepositoryRoot $repoDir -SkillRoot $SkillRoot -BackupRoot $BackupRoot `
        -Force:$Force -DryRun:$DryRun | Out-String | ConvertFrom-Json
    if ($syncSummary.failed -or @($syncSummary.conflicts).Count -gt 0) {
        throw '技能同步存在错误或冲突，Bootstrap 停止；请先查看 Sync-Skills 的结果。'
    }
}

Write-Step "安装 MCP 客户端接入"
$installScript = Join-Path (Join-Path $repoDir "scripts") "Install-MatlabMcpClients.ps1"
if (-not (Test-Path -LiteralPath $installScript)) { throw "缺少脚本: $installScript" }

$installParams = @{
    MatlabRoot                = $resolvedMatlabRoot
    ServerName                = $ServerName
    SessionMode               = $SessionMode
    InitializeMatlabOnStartup = $InitializeMatlabOnStartup
    DisplayMode               = $DisplayMode
    Clients                   = $Clients
    ProjectPath               = $repoDir
    BackupRoot                = $BackupRoot
    DryRun                    = $DryRun
    Force                     = $Force
    ExpectedServerSha256      = $ExpectedServerSha256
}
# 只有二进制真实存在时才把路径传下去；DryRun 且尚未下载时让下游自己预演下载。
if ($serverExePath -and (Test-Path -LiteralPath $serverExePath)) {
    $installParams["ServerExePath"] = $serverExePath
    $installParams["NoDownload"] = $true
}
elseif (-not $DryRun) {
    throw "MCP 二进制准备失败: $serverExePath"
}
if ($SkipBaseSetup) { $installParams["SkipBaseSetup"] = $true }

$installOutput = & $installScript @installParams
$installSummary = if ($installOutput) { $installOutput | ConvertFrom-Json } else { $null }

[pscustomobject]@{
    installTime       = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    dryRun            = [bool]$DryRun
    repoDir           = $repoDir
    matlabRoot        = $resolvedMatlabRoot
    serverExePath     = $serverExePath
    serverExeSha256   = $serverSha
    serverExeVerified = $serverVerified
    serverName        = $ServerName
    sessionMode       = $SessionMode
    clients           = $Clients
    backupRoot        = $BackupRoot
    skills            = if ($SkipSkillsSync) { $null } else { $syncSummary }
    install           = $installSummary
} | ConvertTo-Json -Depth 8
