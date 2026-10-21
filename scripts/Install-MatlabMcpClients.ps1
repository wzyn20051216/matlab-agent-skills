<#
.SYNOPSIS
一键把 MATLAB MCP 接入多个 AI 客户端。

.DESCRIPTION
先完成 MATLAB MCP 基础配置（安装 Toolbox、ACL、startup.m），再把 MCP server
注册到选定客户端。基础配置与客户端注册已解耦：
- 基础配置不再隐式注册 Codex；
- 没有安装 Codex 也能只用 `-Clients claude` 配好 Claude Code。

安全策略（第一阶段 P0 重构后）：
1. existing 模式下不再传 --matlab-display-mode / --matlab-root / -initialize-matlab-on-startup。
2. .mcp.json / .vscode/mcp.json 走安全合并：保留用户其它 server 与其它键，解析失败直接中止。
3. Codex / Claude 注册幂等：参数一致则不动；需要变更时先留快照，失败自动还原。
4. -DryRun 预演全部动作；真实写入登记备份，失败逆序回滚。
#>
[CmdletBinding()]
param(
    [string]$ServerExePath = "",
    [string]$MatlabRoot = "",
    [string]$ServerName = "matlab-official",
    [string]$McpServerDownloadUrl = "",
    [ValidateSet("auto", "existing", "new")]
    [string]$SessionMode = "auto",
    [bool]$InitializeMatlabOnStartup = $true,
    [ValidateSet("desktop", "nodesktop")]
    [string]$DisplayMode = "desktop",
    [string[]]$Clients = @("auto"),
    [string]$ProjectPath = "",
    [switch]$SkipBaseSetup,

    [switch]$NoGeneric,
    [switch]$SkipAclFix,
    [string]$ExpectedServerSha256 = "",
    [switch]$NoDownload,
    [switch]$ForceDownload,
    # 只有操作员明确接受风险时才允许使用未通过固定清单校验的二进制；状态会被记录为非验证。
    [switch]$AllowUnverifiedServer,

    [string]$BackupRoot = "",
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$corePath = Join-Path $PSScriptRoot "MatlabAgentSkills.Core.psm1"
if (-not (Test-Path -LiteralPath $corePath)) {
    throw "缺少核心模块: $corePath"
}
Import-Module -Name $corePath -Force -DisableNameChecking

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $BackupRoot) {
    $BackupRoot = Join-Path $repoRoot "artifacts\backups"
}

#region 参数构造与自检（P0-1）

$argBuild = New-MatlabMcpServerArgs -SessionMode $SessionMode -MatlabRoot $MatlabRoot `
    -InitializeMatlabOnStartup $InitializeMatlabOnStartup -DisplayMode $DisplayMode
$serverArgs = [string[]]$argBuild.Arguments

$violations = Test-McpServerArgsCompatible -Arguments $serverArgs
if ($violations.Count -gt 0) {
    throw "内部错误：构造出的 MCP 参数会被官方 server 拒绝 -> $($violations -join "; ")"
}

foreach ($warning in $argBuild.Warnings) { Write-Warning $warning }

#endregion

function Resolve-Clients {
    param([string[]]$RequestedClients)

    $resolved = New-Object System.Collections.Generic.List[string]
    foreach ($client in $RequestedClients) {
        switch ($client.ToLowerInvariant()) {
            "auto" {
                if (Test-CommandExists "codex") { $resolved.Add("codex") }
                if (Test-CommandExists "claude") { $resolved.Add("claude") }
                if (-not $NoGeneric) { $resolved.Add("generic") }
            }
            default { $resolved.Add($client.ToLowerInvariant()) }
        }
    }
    return @($resolved | Select-Object -Unique)
}

function New-McpClientEntry {
    param(
        [string]$ExePath,
        [string[]]$Arguments,
        [switch]$IncludeType
    )

    if ($IncludeType) {
        return [ordered]@{
            type    = "stdio"
            command = $ExePath
            args    = @($Arguments)
        }
    }
    return [ordered]@{
        command = $ExePath
        args    = @($Arguments)
    }
}

Write-Step "解析 MATLAB MCP Server 可执行文件"
$server = Resolve-McpServerExecutable -Hint $ServerExePath -DownloadUrl $McpServerDownloadUrl `
    -ScriptRoot $PSScriptRoot -ExpectedSha256 $ExpectedServerSha256 `
    -NoDownload:$NoDownload -ForceDownload:$ForceDownload -AllowUnverifiedServer:$AllowUnverifiedServer -DryRun:$DryRun
Write-Info "server: $($server.Path) (source=$($server.Source), release=$($server.ReleaseTag), integrity=$($server.IntegrityStatus))"

if (-not $DryRun -and -not (Test-Path -LiteralPath $server.Path)) {
    throw "MATLAB MCP Server 可执行文件不存在: $($server.Path)"
}
# 未通过固定清单校验的二进制不得被静默当成安装成功。
if (-not $DryRun) {
    Assert-McpServerTrusted -Server $server -AllowUnverifiedServer:$AllowUnverifiedServer
}

$resolvedClients = Resolve-Clients -RequestedClients $Clients
if ($resolvedClients.Count -eq 0) {
    throw "没有可接入的客户端：未检测到 codex / claude，且指定了 -NoGeneric。"
}

$session = $null
if (-not $DryRun) {
    $session = New-BackupSession -Root $BackupRoot -Reason "install-clients"
    Write-Info "备份目录（仅在发生变更时创建）: $($session.Directory)"
}

$summary = [ordered]@{
    ok                = $false
    dryRun            = [bool]$DryRun
    installTime       = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    serverName        = $ServerName
    sessionMode       = $SessionMode
    displayMode       = if ($SessionMode -eq "existing") { $null } else { $DisplayMode }
    initializeMatlabOnStartup = ($SessionMode -ne "existing") -and $InitializeMatlabOnStartup
    serverExePath     = $server.Path
    serverExeSha256   = $server.Sha256
    serverExeVerified = [bool]$server.Verified
    serverReleaseTag  = $server.ReleaseTag
    serverIntegrity   = $server.IntegrityStatus
    serverDownloadSrc = $server.DownloadSource
    serverArgs        = $serverArgs
    droppedArguments  = [string[]]$argBuild.DroppedArguments
    clients           = [string[]]$resolvedClients
    baseSetup         = $null
    results           = [ordered]@{}
    backupDirectory   = if ($session) { $session.Directory } else { $null }
    rollback          = $null
}

try {
    if (-not $SkipBaseSetup) {
        Write-Step "运行 MATLAB MCP 基础配置（不注册客户端）"
        $setupScript = Join-Path $PSScriptRoot "Setup-MatlabMcpExistingSession.ps1"
        if (-not (Test-Path -LiteralPath $setupScript)) {
            throw "缺少基础配置脚本: $setupScript"
        }

        $setupParams = @{
            ServerExePath             = $server.Path
            MatlabRoot                = $MatlabRoot
            McpServerName             = $ServerName
            McpServerDownloadUrl      = $McpServerDownloadUrl
            SessionMode               = $SessionMode
            InitializeMatlabOnStartup = $InitializeMatlabOnStartup
            DisplayMode               = $DisplayMode
            WriteStartupShare         = $true
            SkipClientRegistration    = $true
            BackupRoot                = $BackupRoot
            DryRun                    = $DryRun
            Force                     = $Force
            ExpectedServerSha256      = $ExpectedServerSha256
            NoDownload                = $NoDownload
        }
        if ($SkipAclFix) { $setupParams["SkipAclFix"] = $true }

        $setupOutput = & $setupScript @setupParams
        $summary.baseSetup = if ($setupOutput) { $setupOutput | ConvertFrom-Json } else { $null }
    }
    else {
        Write-Step "跳过基础配置（-SkipBaseSetup）"
    }

    foreach ($client in $resolvedClients) {
        switch ($client.ToLowerInvariant()) {
            "codex" {
                Write-Step "接入 Codex"
                if (-not (Test-CommandExists "codex")) {
                    throw "没有检测到 codex 命令，无法接入 Codex。请先安装 Codex CLI，或用 -Clients claude 单独接入 Claude Code。"
                }
                $summary.results["codex"] = Register-ClientMcpServer -ClientName "codex" -Name $ServerName `
                    -ServerArgs $serverArgs -ExecutablePath $server.Path -Session $session -DryRun:$DryRun
            }
            "claude" {
                Write-Step "接入 Claude Code"
                if (-not (Test-CommandExists "claude")) {
                    throw "没有检测到 claude 命令，无法接入 Claude Code。请先安装 Claude Code，或用 -Clients codex 单独接入 Codex。"
                }
                $summary.results["claude"] = Register-ClientMcpServer -ClientName "claude" -Name $ServerName `
                    -ServerArgs $serverArgs -ExecutablePath $server.Path -Session $session -DryRun:$DryRun
            }
            "vscode" {
                Write-Step "写入 VS Code MCP 配置（安全合并）"
                if (-not $ProjectPath) { throw "VS Code 模式需要传入 -ProjectPath" }
                $configPath = Join-Path (Join-Path $ProjectPath ".vscode") "mcp.json"
                $entry = New-McpClientEntry -ExePath $server.Path -Arguments $serverArgs -IncludeType
                $summary.results["vscode"] = Merge-McpServerConfig -Path $configPath -RootProperty "servers" `
                    -ServerName $ServerName -Entry $entry -BackupRoot $BackupRoot -BackupLabel "vscode-mcp" -DryRun:$DryRun
            }
            "generic" {
                Write-Step "写入通用 .mcp.json（安全合并）"
                $root = if ($ProjectPath) { $ProjectPath } else { (Get-Location).Path }
                $configPath = Join-Path $root ".mcp.json"
                $entry = New-McpClientEntry -ExePath $server.Path -Arguments $serverArgs
                $summary.results["generic"] = Merge-McpServerConfig -Path $configPath -RootProperty "mcpServers" `
                    -ServerName $ServerName -Entry $entry -BackupRoot $BackupRoot -BackupLabel "generic-mcp" -DryRun:$DryRun
            }
            default {
                throw "不支持的客户端: $client"
            }
        }
    }

    if ($session) { Save-BackupManifest -Session $session }
    $summary.ok = $true
}
catch {
    $failure = $_
    if ($session -and -not $DryRun) {
        Write-Warning "安装失败，开始回滚: $($failure.Exception.Message)"
        $rollback = Invoke-BackupRollback -Session $session
        $rollback.Actions | ForEach-Object { Write-Info $_ }
        Save-BackupManifest -Session $session
        $summary.rollback = $rollback
        $summary.error = $failure.Exception.Message
        $summary | ConvertTo-Json -Depth 10 | Write-Output
        throw
    }
    throw
}

$summary | ConvertTo-Json -Depth 10
