<#
.SYNOPSIS
配置 MATLAB 官方 MCP 自动化工作流。

.DESCRIPTION
安装 MATLAB MCP Server Toolbox，修正 MATLAB MCP 数据目录 ACL，
可选写入 startup.m 自动共享当前 MATLAB 会话，并把官方 MCP server
注册到 Codex，作为后续 skills 的默认 MATLAB 交互通道。
#>
[CmdletBinding()]
param(
    [string]$ServerExePath = "",
    [string]$MatlabRoot = "",
    [string]$McpServerName = "matlab-official",
    [string]$McpServerDownloadUrl = "https://github.com/matlab/matlab-mcp-server/releases/latest/download/matlab-mcp-server-windows-x64.exe",
    [ValidateSet("auto", "existing", "new")]
    [string]$SessionMode = "auto",
    [bool]$InitializeMatlabOnStartup = $true,
    [bool]$WriteStartupShare = $true
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Ensure-FileExists {
    param(
        [string]$Path,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "${Label} missing: $Path"
    }
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

    throw "Unable to auto-detect MATLAB root. Pass -MatlabRoot explicitly."
}

function Resolve-ServerExePath {
    param(
        [string]$Hint,
        [string]$DownloadUrl
    )

    if ($Hint -and (Test-Path -LiteralPath $Hint)) {
        return (Resolve-Path -LiteralPath $Hint).Path
    }

    $candidates = @(
        (Join-Path $PSScriptRoot "..\bin\matlab-mcp-server-windows-x64.exe"),
        (Join-Path (Get-Location).Path "matlab-mcp-server-windows-x64.exe"),
        (Join-Path $HOME "Downloads\matlab-mcp-server-windows-x64.exe"),
        (Join-Path $HOME "download\matlab-mcp-server-windows-x64.exe")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $binDir = Join-Path $PSScriptRoot "..\bin"
    if (-not (Test-Path -LiteralPath $binDir)) {
        New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    }
    $downloadPath = Join-Path $binDir "matlab-mcp-server-windows-x64.exe"
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $downloadPath
    return (Resolve-Path -LiteralPath $downloadPath).Path
}

function Ensure-McpAcl {
    param([string]$TargetPath)

    if (-not (Test-Path -LiteralPath $TargetPath)) {
        New-Item -ItemType Directory -Force -Path $TargetPath | Out-Null
    }

    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls $TargetPath /inheritance:r /grant:r "*${sid}:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" | Out-Null

    [pscustomobject]@{
        Path = $TargetPath
        UserSid = $sid
        Sddl = (Get-Acl -LiteralPath $TargetPath).Sddl
    }
}

function Ensure-StartupShare {
    $documents = [Environment]::GetFolderPath("MyDocuments")
    $matlabDir = Join-Path $documents "MATLAB"
    if (-not (Test-Path -LiteralPath $matlabDir)) {
        New-Item -ItemType Directory -Force -Path $matlabDir | Out-Null
    }

    $startupPath = Join-Path $matlabDir "startup.m"
    $shareBlock = @"
if exist('shareMATLABSession','file') == 2
    try
        shareMATLABSession();
    catch me
        warning('MATLAB:MCP:ShareFailed', 'shareMATLABSession failed: %s', me.message);
    end
end
"@

    if (Test-Path -LiteralPath $startupPath) {
        $current = Get-Content -Raw -LiteralPath $startupPath
        if ($current -notmatch "shareMATLABSession") {
            $content = $current.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + $shareBlock
            Set-Content -LiteralPath $startupPath -Value $content -Encoding UTF8
        }
    }
    else {
        Set-Content -LiteralPath $startupPath -Value $shareBlock -Encoding UTF8
    }

    $startupPath
}

function Ensure-CodexMcpServer {
    param(
        [string]$Name,
        [string]$ExePath,
        [string]$RootPath,
        [string]$Mode,
        [bool]$InitializeMatlab
    )

    $existing = & codex mcp list 2>$null
    if ($existing -match "(?m)^$([regex]::Escape($Name))\s") {
        & codex mcp remove $Name | Out-Null
    }

    $commandArgs = @("mcp", "add", $Name, "--", $ExePath, "--matlab-session-mode=$Mode", "--matlab-display-mode=desktop")
    if ($InitializeMatlab) {
        $commandArgs += "--initialize-matlab-on-startup=true"
    }
    if ($Mode -ne "existing" -and $RootPath) {
        $commandArgs += "--matlab-root=$RootPath"
    }

    & codex @commandArgs | Out-Null
    (& codex mcp get $Name) -join [Environment]::NewLine
}

$ServerExePath = Resolve-ServerExePath -Hint $ServerExePath -DownloadUrl $McpServerDownloadUrl
$MatlabRoot = Resolve-MatlabRoot -Hint $MatlabRoot

Ensure-FileExists -Path $ServerExePath -Label "MATLAB MCP Server executable"
Ensure-FileExists -Path $MatlabRoot -Label "MATLAB root"

Write-Step "Install MATLAB MCP Server Toolbox"
& $ServerExePath --setup-matlab --matlab-root=$MatlabRoot

Write-Step "Fix MATLAB MCP data ACL"
$mcpDataDir = Join-Path $env:APPDATA "MathWorks\MATLAB MCP Server"
$aclInfo = Ensure-McpAcl -TargetPath $mcpDataDir

$startupPath = $null
if ($WriteStartupShare) {
    Write-Step "Write startup.m share hook"
    $startupPath = Ensure-StartupShare
}

Write-Step "Register Codex MCP server"
$mcpServerInfo = Ensure-CodexMcpServer -Name $McpServerName -ExePath $ServerExePath -RootPath $MatlabRoot -Mode $SessionMode -InitializeMatlab $InitializeMatlabOnStartup

$summary = [pscustomobject]@{
    setupTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    serverExePath = $ServerExePath
    matlabRoot = $MatlabRoot
    mcpServerName = $McpServerName
    sessionMode = $SessionMode
    initializeMatlabOnStartup = $InitializeMatlabOnStartup
    writeStartupShare = $WriteStartupShare
    startupPath = $startupPath
    acl = $aclInfo
    codexMcp = $mcpServerInfo
}

$summary | ConvertTo-Json -Depth 6
