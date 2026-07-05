<#
.SYNOPSIS
一键把 MATLAB MCP 接入多个 AI 客户端。

.DESCRIPTION
默认接入 Codex 和 Claude Code。会先调用仓库内的
Setup-MatlabMcpExistingSession.ps1 完成 MATLAB MCP 基础配置，
然后把 MCP server 注册到选定客户端。
#>
[CmdletBinding()]
param(
    [string]$ServerExePath = "",
    [string]$MatlabRoot = "",
    [string]$ServerName = "matlab-official",
    [string]$McpServerDownloadUrl = "https://github.com/matlab/matlab-mcp-server/releases/latest/download/matlab-mcp-server-windows-x64.exe",
    [ValidateSet("auto", "existing", "new")]
    [string]$SessionMode = "auto",
    [bool]$InitializeMatlabOnStartup = $true,
    [string[]]$Clients = @("auto"),
    [string]$ProjectPath = "",
    [switch]$SkipBaseSetup
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Get-ServerArgs {
    param(
        [string]$ExePath,
        [string]$RootPath,
        [string]$Mode,
        [bool]$InitializeMatlab
    )

    $args = @($ExePath, "--matlab-session-mode=$Mode", "--matlab-display-mode=desktop")
    if ($InitializeMatlab) {
        $args += "--initialize-matlab-on-startup=true"
    }
    if ($Mode -ne "existing" -and $RootPath) {
        $args += "--matlab-root=$RootPath"
    }
    return $args
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

function Resolve-Clients {
    param([string[]]$RequestedClients)

    $resolved = [System.Collections.Generic.List[string]]::new()
    foreach ($client in $RequestedClients) {
        switch ($client.ToLowerInvariant()) {
            "auto" {
                if (Test-CommandExists "codex") { $resolved.Add("codex") }
                if (Test-CommandExists "claude") { $resolved.Add("claude") }
                $resolved.Add("generic")
            }
            default {
                $resolved.Add($client.ToLowerInvariant())
            }
        }
    }

    return @($resolved | Select-Object -Unique)
}

function Install-CodexMcp {
    param(
        [string]$Name,
        [string[]]$ServerArgs
    )

    $existing = & codex mcp list 2>$null
    if ($existing -match "(?m)^$([regex]::Escape($Name))\s") {
        & codex mcp remove $Name | Out-Null
    }

    $commandArgs = @("mcp", "add", $Name, "--") + $ServerArgs
    & codex @commandArgs | Out-Null
    return (& codex mcp get $Name) -join [Environment]::NewLine
}

function Install-ClaudeMcp {
    param(
        [string]$Name,
        [string[]]$ServerArgs
    )

    $existing = & claude mcp list 2>$null
    if ($existing -match [regex]::Escape($Name)) {
        & claude mcp remove $Name | Out-Null
    }

    $commandArgs = @("mcp", "add", $Name, "--") + $ServerArgs
    & claude @commandArgs | Out-Null
    return (& claude mcp get $Name) -join [Environment]::NewLine
}

function Install-VsCodeMcp {
    param(
        [string]$Name,
        [string[]]$ServerArgs,
        [string]$TargetProjectPath
    )

    if (-not $TargetProjectPath) {
        throw "VS Code 模式需要传入 -ProjectPath"
    }

    $vscodeDir = Join-Path $TargetProjectPath ".vscode"
    if (-not (Test-Path -LiteralPath $vscodeDir)) {
        New-Item -ItemType Directory -Force -Path $vscodeDir | Out-Null
    }

    $configPath = Join-Path $vscodeDir "mcp.json"
    $command = $ServerArgs[0]
    $argList = @()
    if ($ServerArgs.Length -gt 1) {
        $argList = $ServerArgs[1..($ServerArgs.Length - 1)]
    }

    $json = [ordered]@{
        servers = [ordered]@{
            $Name = [ordered]@{
                type = "stdio"
                command = $command
                args = $argList
            }
        }
    }

    $json | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath -Encoding UTF8
    return $configPath
}

function Install-GenericMcp {
    param(
        [string]$Name,
        [string[]]$ServerArgs,
        [string]$TargetProjectPath
    )

    $root = $TargetProjectPath
    if (-not $root) {
        $root = (Get-Location).Path
    }

    $configPath = Join-Path $root ".mcp.json"
    $command = $ServerArgs[0]
    $argList = @()
    if ($ServerArgs.Length -gt 1) {
        $argList = $ServerArgs[1..($ServerArgs.Length - 1)]
    }

    $json = [ordered]@{
        mcpServers = [ordered]@{
            $Name = [ordered]@{
                command = $command
                args = $argList
            }
        }
    }

    $json | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath -Encoding UTF8
    return $configPath
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$setupScript = Join-Path $PSScriptRoot "Setup-MatlabMcpExistingSession.ps1"
$ServerExePath = Resolve-ServerExePath -Hint $ServerExePath -DownloadUrl $McpServerDownloadUrl
$MatlabRoot = Resolve-MatlabRoot -Hint $MatlabRoot

if (-not $SkipBaseSetup) {
    Write-Step "运行 MATLAB MCP 基础配置"
    & $setupScript `
        -ServerExePath $ServerExePath `
        -MatlabRoot $MatlabRoot `
        -McpServerName $ServerName `
        -McpServerDownloadUrl $McpServerDownloadUrl `
        -SessionMode $SessionMode `
        -InitializeMatlabOnStartup:$InitializeMatlabOnStartup `
        -WriteStartupShare:$true | Out-Null
}

$serverArgs = Get-ServerArgs -ExePath $ServerExePath -RootPath $MatlabRoot -Mode $SessionMode -InitializeMatlab $InitializeMatlabOnStartup
$resolvedClients = Resolve-Clients -RequestedClients $Clients
$results = [ordered]@{}

foreach ($client in $resolvedClients) {
    switch ($client.ToLowerInvariant()) {
        "codex" {
            Write-Step "接入 Codex"
            $results["codex"] = Install-CodexMcp -Name $ServerName -ServerArgs $serverArgs
        }
        "claude" {
            Write-Step "接入 Claude Code"
            $results["claude"] = Install-ClaudeMcp -Name $ServerName -ServerArgs $serverArgs
        }
        "vscode" {
            Write-Step "写入 VS Code MCP 配置"
            $results["vscode"] = Install-VsCodeMcp -Name $ServerName -ServerArgs $serverArgs -TargetProjectPath $ProjectPath
        }
        "generic" {
            Write-Step "写入通用 .mcp.json"
            $results["generic"] = Install-GenericMcp -Name $ServerName -ServerArgs $serverArgs -TargetProjectPath $ProjectPath
        }
        default {
            throw "不支持的客户端: $client"
        }
    }
}

[pscustomobject]@{
    installTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    serverName = $ServerName
    sessionMode = $SessionMode
    initializeMatlabOnStartup = $InitializeMatlabOnStartup
    clients = $resolvedClients
    results = $results
} | ConvertTo-Json -Depth 6
