<#
.SYNOPSIS
配置 MATLAB 官方 MCP 自动化工作流（基础环境部分）。

.DESCRIPTION
执行 MATLAB MCP 基础配置，与具体 AI 客户端解耦：
1. 安装 MATLAB MCP Server Toolbox（`--setup-matlab`）。
2. 给 MATLAB MCP 数据目录追加当前用户 FullControl（默认不动继承、不删其它 ACE）。
3. 可选写入 startup.m 托管块，让 MATLAB 启动时自动共享会话。
4. 可选把 MCP server 注册到 Codex（未安装 Codex 时只告警，不中断）。

安全策略（第一阶段 P0 重构后）：
- 所有写操作可 -DryRun 预演。
- 每次真实写入前登记备份（目录记录在 -BackupRoot 下的时间戳会话里）。
- 任一步骤失败自动逆序回滚，并保留备份清单供人工审计。
- 远程二进制下载要求 HTTPS，支持 -ExpectedServerSha256 校验，先落临时文件再原子替换。

.PARAMETER Client
要注册的客户端。codex = 尝试注册到 Codex（未安装时跳过）；none = 完全不注册。

.PARAMETER FailAfterStep
仅用于自动化测试的故障注入：让脚本在指定步骤后抛错，以验证回滚。
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
    [bool]$WriteStartupShare = $true,
    [ValidateSet("desktop", "nodesktop")]
    [string]$DisplayMode = "desktop",

    [ValidateSet("codex", "none")]
    [string]$Client = "codex",
    [switch]$SkipClientRegistration,

    [string]$McpDataDir = "",
    [string]$StartupDirectory = "",
    [switch]$SkipAclFix,
    [switch]$RestrictAclInheritance,

    [string]$ExpectedServerSha256 = "",
    [switch]$NoDownload,
    [switch]$ForceDownload,

    [string]$BackupRoot = "",
    [switch]$DryRun,
    [switch]$Force,

    [ValidateSet("none", "toolbox", "acl", "startup", "client")]
    [string]$FailAfterStep = "none"
)

$ErrorActionPreference = "Stop"

$corePath = Join-Path $PSScriptRoot "MatlabAgentSkills.Core.psm1"
if (-not (Test-Path -LiteralPath $corePath)) {
    throw "缺少核心模块: $corePath"
}
Import-Module -Name $corePath -Force -DisableNameChecking

if (-not $McpDataDir) {
    $McpDataDir = Join-Path $env:APPDATA "MathWorks\MATLAB MCP Server"
}
if (-not $StartupDirectory) {
    $StartupDirectory = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "MATLAB"
}
if (-not $BackupRoot) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $BackupRoot = Join-Path $repoRoot "artifacts\backups"
}

#region 参数兼容性自检（P0-1）

$argBuild = New-MatlabMcpServerArgs -SessionMode $SessionMode -MatlabRoot $MatlabRoot `
    -InitializeMatlabOnStartup $InitializeMatlabOnStartup -DisplayMode $DisplayMode

$compatibilityViolations = Test-McpServerArgsCompatible -Arguments $argBuild.Arguments
if ($compatibilityViolations.Count -gt 0) {
    throw "内部错误：构造出的 MCP 参数会被官方 server 拒绝 -> $($compatibilityViolations -join "; ")"
}

foreach ($warning in $argBuild.Warnings) { Write-Warning $warning }
if ($argBuild.DroppedArguments.Count -gt 0) {
    Write-Info ("已省略参数: " + ($argBuild.DroppedArguments -join " "))
}

#endregion

$session = $null
if (-not $DryRun) {
    $session = New-BackupSession -Root $BackupRoot -Reason "setup-mcp"
    Write-Info "备份目录（仅在发生变更时创建）: $($session.Directory)"
}

$report = [ordered]@{
    ok                      = $false
    dryRun                  = [bool]$DryRun
    setupTime               = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    serverExePath           = $null
    serverExeSha256         = $null
    serverExeVerified       = $false
    matlabRoot              = $null
    mcpServerName           = $McpServerName
    sessionMode             = $SessionMode
    displayMode             = if ($SessionMode -eq "existing") { $null } else { $DisplayMode }
    initializeMatlabOnStartup = ($SessionMode -ne "existing") -and $InitializeMatlabOnStartup
    serverArgs              = [string[]]$argBuild.Arguments
    droppedArguments        = [string[]]$argBuild.DroppedArguments
    warnings                = [string[]]$argBuild.Warnings
    writeStartupShare       = $WriteStartupShare
    startupPath             = $null
    startupAction           = $null
    acl                     = $null
    client                  = $Client
    clientRegistration      = $null
    backupDirectory         = if ($session) { $session.Directory } else { $null }
    rollback                = $null
    failAfterStep           = $FailAfterStep
}

try {
    Write-Step "解析 MATLAB MCP Server 可执行文件"
    $server = Resolve-McpServerExecutable -Hint $ServerExePath -DownloadUrl $McpServerDownloadUrl `
        -ScriptRoot $PSScriptRoot -ExpectedSha256 $ExpectedServerSha256 `
        -NoDownload:$NoDownload -ForceDownload:$ForceDownload -DryRun:$DryRun

    $report.serverExePath = $server.Path
    $report.serverExeSha256 = $server.Sha256
    $report.serverExeVerified = [bool]$server.Verified
    Write-Info "server: $($server.Path) (source=$($server.Source))"

    Write-Step "解析 MATLAB 安装目录"
    $resolvedMatlabRoot = Resolve-MatlabRoot -Hint $MatlabRoot
    $report.matlabRoot = $resolvedMatlabRoot
    Write-Info "matlabRoot: $resolvedMatlabRoot"

    if (-not (Test-Path -LiteralPath $server.Path)) {
        throw "MATLAB MCP Server 可执行文件不存在: $($server.Path)"
    }
    if (-not (Test-Path -LiteralPath $resolvedMatlabRoot)) {
        throw "MATLAB root 不存在: $resolvedMatlabRoot"
    }

    Write-Step "安装 MATLAB MCP Server Toolbox"
    if ($DryRun) {
        Write-Info "[DryRun] $($server.Path) --setup-matlab --matlab-root=$resolvedMatlabRoot"
    }
    else {
        & $server.Path --setup-matlab "--matlab-root=$resolvedMatlabRoot"
        if ($LASTEXITCODE -ne 0) {
            throw "MATLAB MCP Server Toolbox 安装失败（exit=$LASTEXITCODE）。请确认 MATLAB 可用且有许可证。"
        }
    }
    if ($FailAfterStep -eq "toolbox") { throw "故障注入：toolbox 步骤后强制失败" }

    $aclInfo = $null
    if ($SkipAclFix) {
        Write-Step "跳过 ACL 修正（-SkipAclFix）"
    }
    else {
        Write-Step "修正 MATLAB MCP 数据目录 ACL（追加式授权）"
        $aclInfo = Set-DirectoryAclGrant -Path $McpDataDir -RestrictInheritance:$RestrictAclInheritance `
            -Session $session -DryRun:$DryRun
        if (-not $DryRun) {
            # 把"有效权限"证据一起落盘：只记 SDDL 无法区分"授权成功"与"授予了但不够用"。
            # verified = 写后校验结论（Allow/Deny、权限掩码、继承标志全部满足）。
            $verification = $aclInfo.Verification
            $report.acl = [pscustomobject]@{
                path                  = $aclInfo.Path
                userSid               = $aclInfo.UserSid
                beforeSddl            = $aclInfo.BeforeSddl
                afterSddl             = $aclInfo.AfterSddl
                restrictedInheritance = $aclInfo.RestrictedInheritance
                commandLine           = $aclInfo.CommandLine
                verified              = $aclInfo.Verified
                folderRights          = $(if ($verification) { $verification.FolderRights } else { $null })
                childRights           = $(if ($verification) { $verification.ChildRights } else { $null })
                aceCount              = $(if ($verification) { $verification.RuleCount } else { $null })
            }
        }
        else {
            $report.acl = [pscustomobject]@{ path = $McpDataDir; commandLine = $aclInfo.CommandLine; dryRun = $true }
            Write-Info "[DryRun] $($aclInfo.CommandLine)"
        }
    }
    if ($FailAfterStep -eq "acl") { throw "故障注入：ACL 步骤后强制失败" }

    $startupPath = Join-Path $StartupDirectory "startup.m"
    if ($WriteStartupShare) {
        Write-Step "写入 startup.m 托管块"
        $startupResult = Merge-StartupShareFile -Path $startupPath -Session $session `
            -BackupRoot $BackupRoot -DryRun:$DryRun
        $report.startupPath = $startupPath
        $report.startupAction = $startupResult.Action
        Write-Info "startup.m: $($startupResult.Action)"

        if ($startupResult.Action -eq "skipped-foreign-hook") {
            Write-Warning "startup.m 里已经有非本项目的 shareMATLABSession 调用，保持原样未修改: $startupPath"
        }
    }
    else {
        Write-Step "跳过 startup.m（-WriteStartupShare:`$false）"
    }
    if ($FailAfterStep -eq "startup") { throw "故障注入：startup 步骤后强制失败" }

    if ($SkipClientRegistration -or $Client -eq "none") {
        Write-Step "跳过客户端注册（基础配置与客户端解耦）"
        $report.clientRegistration = [pscustomobject]@{ skipped = $true; reason = "SkipClientRegistration" }
    }
    elseif ($Client -eq "codex") {
        if (-not (Test-CommandExists "codex")) {
            Write-Warning "未检测到 codex 命令，跳过 Codex 注册。基础 MCP 配置已完成；需要时可用 Install-MatlabMcpClients.ps1 -Clients codex（或 claude）单独接入。"
            $report.clientRegistration = [pscustomobject]@{ client = "codex"; skipped = $true; reason = "codex-not-installed" }
        }
        else {
            Write-Step "注册 Codex MCP server"
            if ($DryRun) {
                $argv = Get-MatlabMcpServerArgv -ExePath $server.Path -SessionMode $SessionMode -MatlabRoot $resolvedMatlabRoot `
                    -InitializeMatlabOnStartup $InitializeMatlabOnStartup -DisplayMode $DisplayMode
                Write-Info ("[DryRun] codex mcp add " + $McpServerName + " -- " + ($argv -join " "))
                $report.clientRegistration = [pscustomobject]@{ client = "codex"; skipped = $false; action = "would_update" }
            }
            else {
                $registration = Register-ClientMcpServer -ClientName "codex" -Name $McpServerName `
                    -ServerArgs $argBuild.Arguments -ExecutablePath $server.Path -Session $session
                $report.clientRegistration = $registration
                $report["codexMcp"] = $registration.VerifiedOutput
            }
        }
    }
    if ($FailAfterStep -eq "client") { throw "故障注入：客户端注册后强制失败" }

    $report.ok = $true
}
catch {
    $failure = $_
    if ($session -and -not $DryRun) {
        Write-Warning "配置失败，开始回滚: $($failure.Exception.Message)"
        $rollback = Invoke-BackupRollback -Session $session
        $rollback.Actions | ForEach-Object { Write-Info $_ }
        Save-BackupManifest -Session $session
        $report.rollback = $rollback
        $report.error = $failure.Exception.Message
        $report | ConvertTo-Json -Depth 8 | Write-Output
        throw
    }
    throw
}

$report | ConvertTo-Json -Depth 8
