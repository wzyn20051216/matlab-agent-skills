<#
.SYNOPSIS
用生产归属判定函数复核"当前仍在监听的那对 MATLAB 进程"到底归谁，并且只报告、不终止。

.DESCRIPTION
2026-10-26 S3 的真实遗留：本轮 Start-MatlabSharedSession.ps1 启动的会话（启动器存根 51072 已退出，
其派生的 bin\win64\MATLAB.exe = 15392 监听 31519，15392 再派生引擎 42956 监听 31520）
被旧判定误报成"不是我们的进程"，于是持有者提前退出、会话被孤儿化，
而 sessionDetails.json 至今仍把 42956 作为对外公布的会话。

本脚本只做三件事：
  1. 从既有审计事件 ownership_recorded 取回**当时写下的**启动器身份（不臆造）；
  2. 对会话描述符里的 pid 及其 MATLAB 祖先，逐个调用生产的
     Test-MasSessionRuntimeOwnership（纯判定，零动作），验证修复后的父链判据在真实进程树上成立；
  3. 以 CleanupMode=ReportOnly 走一遍 Invoke-MasOwnedCleanup，记录"如果现在授权清理，
     每个进程会得到什么判定"。ReportOnly 分支不存在任何终止代码路径。

绝不打印 apiKey / certificate；结束时对输出文本做一次字段自检。
#>
[CmdletBinding()]
param(
    [string]$RepositoryRoot = "",
    [string]$AuditPath = "",
    [string]$OutputPath = "",
    [int]$MaxAncestorDepth = 3
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    # 脚本位于 <repo>\artifacts\s3\evidence\tools\
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
}
$sessionDir = Join-Path $RepositoryRoot 'artifacts\s3\evidence\session'
if ([string]::IsNullOrWhiteSpace($AuditPath)) { $AuditPath = Join-Path $sessionDir 'matlab_shared_session_cleanup.jsonl' }
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $RepositoryRoot 'artifacts\s3\evidence\green\session-ownership-live-reportonly.json'
}

. (Join-Path $RepositoryRoot 'scripts\Start-MatlabSharedSession.ps1')

# ---- 1. 取回当时记录的启动器身份 ----
$recordedLauncher = $null
$recordedAtUtc = $null
foreach ($line in @(Get-Content -LiteralPath $AuditPath -Encoding UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $evt = $line | ConvertFrom-Json
    if ([string]$evt.event -eq 'ownership_recorded' -and $null -ne $evt.data.processes) {
        foreach ($procEntry in @($evt.data.processes)) {
            if ([string]$procEntry.role -eq 'launcher') {
                $recordedLauncher = $procEntry
                $recordedAtUtc = $evt.atUtc
            }
        }
    }
}
if ($null -eq $recordedLauncher) { throw "审计文件里没有 ownership_recorded 的启动器条目：$AuditPath" }

$launcherPid = [int]$recordedLauncher.pid
$launcherStartUtc = [datetime]$recordedLauncher.startTimeUtc
$launcherSessionId = [int]$recordedLauncher.windowsSessionId
# 生产的 runStartedAtUtc 语义：不晚于启动器启动。取记录值，绝不向未来移动。
$runStartedAtUtc = $launcherStartUtc.ToUniversalTime()

# ---- 2. 会话描述符只读 port / pid ----
$descriptor = Join-Path $env:APPDATA 'MathWorks\MATLAB MCP Server\v1\sessionDetails.json'
$session = Get-Content -Raw -LiteralPath $descriptor | ConvertFrom-Json
$sessionPid = [int](Get-MasPropertyValue $session 'pid' 0)
$sessionPort = [int](Get-MasPropertyValue $session 'port' 0)

# 允许的 MATLAB 可执行形态：审计里记录的启动器存根 + 同级 bin\win64\MATLAB.exe
# （与生产主流程给 Test-MasSessionRuntimeOwnership 的集合形状一致）
$acceptedExe = @([string]$recordedLauncher.executablePath)
$matlabBin = Split-Path -Parent ([string]$recordedLauncher.executablePath)
$matlabRoot = Split-Path -Parent $matlabBin
if ($matlabRoot) {
    $win64 = Join-Path $matlabRoot 'bin\win64\MATLAB.exe'
    if (Test-Path -LiteralPath $win64) { $acceptedExe += $win64 }
}

function Get-ListenerOwner {
    param([int]$Port)
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $conn) { return $null }
    return [int]$conn.OwningProcess
}

function Describe-Target {
    param([int]$Id, [string]$Role)
    $process = Get-Process -Id $Id -ErrorAction SilentlyContinue
    if ($null -eq $process) {
        return [pscustomobject][ordered]@{
            role = $Role; pid = $Id; alive = $false; snapshot = $null; processName = $null; parentPid = $null
            startTimeUtc = $null; executablePath = $null; windowsSessionId = $null
            chain = @(); ownership = $null
        }
    }
    $snapshot = Get-MasProcessSnapshot -Process $process
    $parentPid = Get-MasProcessParentId -Id $Id
    $chain = @(Get-MasAncestorChain -Id $Id -MaxDepth $MaxAncestorDepth)
    $launcherEntry = New-MasOwnedProcessEntry -Identity ([pscustomobject][ordered]@{
            Pid              = $launcherPid
            ProcessName      = $recordedLauncher.processName
            StartTimeUtc     = $launcherStartUtc
            ExecutablePath   = $recordedLauncher.executablePath
            WindowsSessionId = $launcherSessionId
            HasExited        = $false
        }) -Role 'launcher'
    $decision = Test-MasSessionRuntimeOwnership -Candidate $snapshot -Ancestors $chain `
        -Launcher $launcherEntry -RunStartedAtUtc $runStartedAtUtc `
        -MatlabExecutablePath $acceptedExe -MaxAncestorDepth $MaxAncestorDepth
    return [pscustomobject][ordered]@{
        role             = $Role
        pid              = $Id
        alive            = $true
        snapshot         = $snapshot
        processName      = $snapshot.ProcessName
        parentPid        = $parentPid
        startTimeUtc     = $(if ($null -ne $snapshot.StartTimeUtc) { $snapshot.StartTimeUtc.ToString('o') } else { $null })
        executablePath   = $snapshot.ExecutablePath
        windowsSessionId = $snapshot.WindowsSessionId
        chain            = @($chain | ForEach-Object {
                [pscustomobject][ordered]@{
                    pid              = $_.Pid
                    processName      = $_.ProcessName
                    startTimeUtc     = $(if ($null -ne $_.StartTimeUtc) { $_.StartTimeUtc.ToString('o') } else { $null })
                    executablePath   = $_.ExecutablePath
                    windowsSessionId = $_.WindowsSessionId
                    hasExited        = $_.HasExited
                }
            })
        ownership        = [pscustomobject][ordered]@{
            owned          = $decision.owned
            reason         = $decision.reason
            hops           = $decision.hops
            launcherHopPid = $decision.launcherHopPid
        }
    }
}

$targets = @()
$targets += Describe-Target -Id $sessionPid -Role 'session-runtime (named by sessionDetails.json)'
$runtimeParent = Get-MasProcessParentId -Id $sessionPid
if ($null -ne $runtimeParent -and [int]$runtimeParent -gt 0 -and [int]$runtimeParent -ne $launcherPid) {
    $targets += Describe-Target -Id ([int]$runtimeParent) -Role 'session-head (parent of the runtime)'
}
# 启动器自身：应已退出（存根），原样记录
$launcherLive = Get-Process -Id $launcherPid -ErrorAction SilentlyContinue

# 对照组：机器上**不是本轮启动**的 MATLAB（Qoder MCP 客户端长期连接的那个）。
# 修复放宽了跳数，必须同时证明它不会因此把别人的 MATLAB 认成自家进程。
$controlOther = $null
foreach ($candidate in @(Get-Process -Name MATLAB -ErrorAction SilentlyContinue)) {
    if ([int]$candidate.Id -eq $sessionPid) { continue }
    $candParent = Get-MasProcessParentId -Id ([int]$candidate.Id)
    if ($null -ne $candParent -and [int]$candParent -eq $launcherPid) { continue }
    $controlOther = [int]$candidate.Id
    break
}
if ($null -ne $controlOther) {
    $targets += Describe-Target -Id $controlOther -Role 'control (MATLAB not started by this run)'
}

# ---- 3. ReportOnly 走一遍生产清理入口 ----
$verificationRunId = 'mas-s3-verify-' + (Get-Random -Maximum 999999).ToString('000000')
$entries = @()
$entries += New-MasOwnedProcessEntry -Identity ([pscustomobject][ordered]@{
        Pid = $launcherPid; ProcessName = $recordedLauncher.processName; StartTimeUtc = $launcherStartUtc
        ExecutablePath = $recordedLauncher.executablePath; WindowsSessionId = $launcherSessionId; HasExited = $false
    }) -Role 'launcher'
foreach ($t in $targets) {
    if (-not $t.alive) { continue }
    if ($t.role -match 'control') { continue }
    if (-not [bool]$t.ownership.owned) { continue }
    $entries += New-MasOwnedProcessEntry -Identity $t.snapshot -Role 'session-runtime' -ParentPid $t.parentPid
}
$verificationRecord = New-MasOwnerRecord -RunId $verificationRunId -RunStartedAtUtc $runStartedAtUtc `
    -Processes $entries -OwnerScriptPid $PID -OwnerScriptPath $PSCommandPath

$reportAudit = Join-Path $sessionDir 'live-ownership-report.jsonl'
$cleanupReport = @(Invoke-MasOwnedCleanup -OwnerRecord $verificationRecord -RunId $verificationRunId `
        -CleanupMode ReportOnly -AuditPath $reportAudit -ExpectedProcessName 'MATLAB')

$targetsForJson = @($targets | ForEach-Object {
        [pscustomobject][ordered]@{
            role             = $_.role
            pid              = $_.pid
            alive            = $_.alive
            processName      = $_.processName
            parentPid        = $_.parentPid
            startTimeUtc     = $_.startTimeUtc
            executablePath   = $_.executablePath
            windowsSessionId = $_.windowsSessionId
            chain            = @($_.chain)
            ownership        = $_.ownership
        }
    })
$ownedCount = @($targets | Where-Object { $null -ne $_.ownership -and [bool]$_.ownership.owned }).Count
$ownedTargets = @($targets | Where-Object { $null -ne $_.ownership -and [bool]$_.ownership.owned })
$controlTargets = @($targets | Where-Object { $_.role -match 'control' })
$controlsNotOwned = (@($controlTargets | Where-Object { -not [bool]$_.ownership.owned }).Count -eq @($controlTargets).Count)
$realTargets = @($targets | Where-Object { $_.role -notmatch 'control' })

$result = [pscustomobject][ordered]@{
    schemaVersion = 'mas-s3-live-session-ownership/1'
    generatedAtUtc = [datetime]::UtcNow.ToString('o')
    powerShellVersion = $PSVersionTable.PSVersion.ToString()
    purpose = '复核修复后的父链归属判据在真实进程树上是否成立；ReportOnly，不终止任何进程'
    terminatesProcesses = $false
    cleanupMode = 'ReportOnly'
    recordedLauncher = [pscustomobject][ordered]@{
        pid = $launcherPid; processName = $recordedLauncher.processName
        startTimeUtc = $launcherStartUtc.ToString('o')
        executablePath = $recordedLauncher.executablePath
        windowsSessionId = $launcherSessionId
        recordedAtUtc = $recordedAtUtc
        auditSource = $AuditPath
        stillAlive = ($null -ne $launcherLive)
    }
    runStartedAtUtcBasis = '取自审计里当时写下的启动器 StartTimeUtc（不臆造、不向未来移动）'
    sessionDescriptor = [pscustomobject][ordered]@{
        path = $descriptor
        port = $sessionPort
        pid  = $sessionPid
        listenerOwnerPid = (Get-ListenerOwner -Port $sessionPort)
        secretFieldsRead = $false
    }
    acceptedExecutablePaths = @($acceptedExe)
    maxAncestorDepth = $MaxAncestorDepth
    targets = @($targetsForJson)
    reportOnlyDecisions = @($cleanupReport | ForEach-Object {
            [pscustomobject][ordered]@{
                pid           = $_.pid
                decision      = $_.decision
                action        = $_.action
                processName   = $_.observed.processName
                executablePath = $_.observed.executablePath
            }
        })
    judgement = [pscustomobject][ordered]@{
        targetCount               = @($targets).Count
        ownedTargetCount          = $ownedCount
        treeMatchesProductionFix  = (@($realTargets).Count -gt 0 -and (@($realTargets | Where-Object { [bool]$_.ownership.owned }).Count -eq @($realTargets).Count))
        controlTargets            = @($controlTargets | ForEach-Object { [pscustomobject][ordered]@{ pid = $_.pid; owned = $_.ownership.owned; reason = $_.ownership.reason } })
        controlNotOverTrusted     = $controlsNotOwned
        oldPredicateWouldSay      = 'SKIPPED_LAUNCHER_NOT_IN_CHAIN（旧实现只认直接父子 + 存根路径，孙进程恒判不归属）'
        ownerRecordOnDiskForThatRun = $false
        ownerRecordNote           = '该轮运行的 owner-<runid>.json 已不在磁盘上（仓库与临时目录全盘检索无命中），不存在可授权终止的原始归属记录'
        decision                  = 'KEEP（保留并记录）：42956 仍是 sessionDetails.json 对外公布的会话，本轮后续门禁复跑要用它；且该轮没有留下可授权终止的原始所有者文件，按失败关闭不得终止'
        keepRationale             = @(
            '会话是活的且正被对外公布：终止后 existing/auto 模式的客户端都得重新铸会话才能用'
            '归属判定成立（见 targets.ownership），但生产终止入口只认 owner-<runid>.json；该轮 owner 文件已不在磁盘上，用事后重建的记录去杀进程正是不变量禁止的"事后授权"'
            '审查意见明确要求：后续还要使用的会话要保留并记录，不能为了追求清理通过而误关'
        )
        stopProcedure             = '需要释放时由人工在该 MATLAB 里执行 exit（或关闭其窗口）。本轮流程不代为终止；修复后的 Start-MatlabSharedSession.ps1 在自己启动的那一轮会把存根与运行时都写进 owner 文件，届时默认 -CleanupMode Graceful 即可安全释放。'
    }
}

$json = $result | ConvertTo-Json -Depth 8
if ($json -match '(?i)apikey|certificate' -or $json -match '\[REDACTED') {
    throw '输出里出现凭据字段或脱敏标记，拒绝落盘。'
}
$directory = Split-Path -Parent $OutputPath
if ($directory -and -not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
}
[IO.File]::WriteAllText($OutputPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "WROTE $OutputPath"
Write-Host ("owned_targets=" + (@($targets | Where-Object { $_.ownership.owned }).Count) + "/" + @($targets).Count)
foreach ($t in $targets) {
    Write-Host ("  pid={0} role={1} owned={2} reason={3} hops={4}" -f $t.pid, $t.role, $t.ownership.owned, $t.ownership.reason, $t.ownership.hops)
}
