<#
.SYNOPSIS
一键下载并安装 matlab-agent-skills 与 MATLAB MCP 客户端接入。
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $HOME "matlab-agent-skills"),
    [string]$RepoUrl = "https://github.com/wzyn20051216/matlab-agent-skills.git",
    [string]$RepoZipUrl = "https://github.com/wzyn20051216/matlab-agent-skills/archive/refs/heads/main.zip",
    [string]$McpServerDownloadUrl = "https://github.com/matlab/matlab-mcp-server/releases/latest/download/matlab-mcp-server-windows-x64.exe",
    [string]$ServerName = "matlab-official",
    [ValidateSet("auto", "existing", "new")]
    [string]$SessionMode = "auto",
    [bool]$InitializeMatlabOnStartup = $true,
    [string[]]$Clients = @("auto"),
    [string]$MatlabRoot = ""
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Resolve-MatlabRoot {
    param([string]$Hint)

    if ($Hint -and (Test-Path -LiteralPath $Hint)) {
        return $Hint
    }

    if ($env:MATLAB_ROOT -and (Test-Path -LiteralPath $env:MATLAB_ROOT)) {
        return $env:MATLAB_ROOT
    }

    $matlabCmd = Get-Command matlab -ErrorAction SilentlyContinue
    if ($matlabCmd) {
        $binDir = Split-Path -Parent $matlabCmd.Source
        return Split-Path -Parent $binDir
    }

    $roots = @()
    $roots += Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Root }
    foreach ($root in ($roots | Select-Object -Unique)) {
        $programFilesMatlab = Join-Path $root "Program Files\MATLAB"
        if (Test-Path -LiteralPath $programFilesMatlab) {
            $release = Get-ChildItem -LiteralPath $programFilesMatlab -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                Select-Object -First 1
            if ($release) {
                return $release.FullName
            }
        }

        $flatMatlab = Join-Path $root "MATLAB"
        if (Test-Path -LiteralPath $flatMatlab) {
            return $flatMatlab
        }
    }

    throw "未能自动发现 MATLAB 安装目录。请使用 -MatlabRoot 显式指定。"
}

function Ensure-Repo {
    param(
        [string]$TargetDir,
        [string]$GitUrl,
        [string]$ZipUrl
    )

    if (Test-Path -LiteralPath (Join-Path $TargetDir ".git")) {
        Write-Step "更新已有仓库"
        git -C $TargetDir pull --ff-only | Out-Null
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
    $zipPath = Join-Path ([System.IO.Path]::GetTempPath()) "matlab-agent-skills-main.zip"
    Invoke-WebRequest -Uri $ZipUrl -OutFile $zipPath
    $extractDir = Join-Path ([System.IO.Path]::GetTempPath()) "matlab-agent-skills-main"
    if (Test-Path -LiteralPath $extractDir) {
        Remove-Item -Recurse -Force -LiteralPath $extractDir
    }
    Expand-Archive -Path $zipPath -DestinationPath ([System.IO.Path]::GetTempPath()) -Force
    Copy-Item -Recurse -Force -Path (Join-Path $extractDir "*") -Destination $TargetDir
    return $TargetDir
}

function Ensure-McpBinary {
    param(
        [string]$RepoDir,
        [string]$DownloadUrl
    )

    $binDir = Join-Path $RepoDir "bin"
    if (-not (Test-Path -LiteralPath $binDir)) {
        New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    }

    $exePath = Join-Path $binDir "matlab-mcp-server-windows-x64.exe"
    Write-Step "下载 MATLAB MCP Server"
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $exePath
    return $exePath
}

$repoDir = Ensure-Repo -TargetDir $InstallDir -GitUrl $RepoUrl -ZipUrl $RepoZipUrl
$resolvedMatlabRoot = Resolve-MatlabRoot -Hint $MatlabRoot
$serverExePath = Ensure-McpBinary -RepoDir $repoDir -DownloadUrl $McpServerDownloadUrl

Write-Step "同步 Skills"
& (Join-Path $repoDir "scripts\Sync-Skills.ps1")

Write-Step "安装 MCP 客户端接入"
& (Join-Path $repoDir "scripts\Install-MatlabMcpClients.ps1") `
    -ServerExePath $serverExePath `
    -MatlabRoot $resolvedMatlabRoot `
    -ServerName $ServerName `
    -SessionMode $SessionMode `
    -InitializeMatlabOnStartup:$InitializeMatlabOnStartup `
    -Clients $Clients `
    -ProjectPath $repoDir

[pscustomobject]@{
    installTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    repoDir = $repoDir
    matlabRoot = $resolvedMatlabRoot
    serverExePath = $serverExePath
    serverName = $ServerName
    clients = $Clients
} | ConvertTo-Json -Depth 4
