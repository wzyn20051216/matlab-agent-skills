<#
.SYNOPSIS
    持有 MATLAB 共享会话，供 MCP server `--matlab-session-mode=existing` 使用。

.DESCRIPTION
    shareMATLABSession() 会在 %APPDATA%\MathWorks\MATLAB MCP Server\v1\sessionDetails.json
    写下 port / certificate / apiKey / pid，官方 MCP server 的 existing 模式读它来接入
    一个**已经在跑**的 MATLAB，避免为每次调用冷启动一个 MATLAB（冷启动约 20~60 秒）。

    **关键陷阱：不能用 pause() 持有会话。**

    早期实现用：
        matlab -r "... shareMATLABSession; pause(86400);"

    结果是：
      - shareMATLABSession() 的 HTTP 监听跑在 MATLAB 后台线程，所以
        `GET https://localhost:<port>/` 依然返回 200
        "The connector service is running."，看起来完全正常；
      - 但执行 MATLAB 代码必须回到**主线程**，而主线程被 pause() 永久阻塞；
      - 表现为 MCP initialize / tools/list 全部正常，tools/call 永远挂起
        （实测 300 秒无任何响应，且服务端 stderr 干净、无错误可查）。

    本实现改用一个空转 timer 让 MATLAB 事件循环保持运行：timer 回调进入主线程队列，
    主线程空闲即可对外服务，既不退出、也不占住主线程。

    **另一个约束：会话文件会被任何一次 MATLAB 启动重写**（含 `matlab -batch`）。
    所以持有共享会话期间，不要在机器上再启动任何 MATLAB 进程，否则 existing 模式
    会指向一个刚刚覆写掉的、已经失效的会话。

.SECURITY INVARIANT（2026-10 安全整改后）
    清理不再是"读 sessionDetails.json 的 pid 然后 Stop-Process -Force"。

    现在的安全不变量（INVARIANT）：
      1. 只有**本次运行亲自启动、并在启动时把身份写进本次运行所有者文件**的进程
         才会进入清理流程。sessionDetails.json 里的 pid 只是观测值，
         **永远不能单独作为终止依据**。
      2. 终止（以及温和关闭）之前必须重新校验全部五项身份：
           进程仍存在 / ProcessName=MATLAB / StartTimeUtc 与记录相差 <= 2s /
           可执行文件路径与记录完全一致 / Windows 会话 id 与记录一致。
         任何一项失败 → 不终止，只报告 SKIPPED_IDENTITY_MISMATCH（附观测值）。
      3. 所有者文件按运行隔离：owner-<runid>.json，内含 runId 与 runStartedAtUtc。
         旧运行遗留的所有者文件（runId 不匹配、或时间超过 OwnerMaxAgeMinutes）
         一律拒绝，绝不产生终止动作。被中断的运行留下的文件因此不会误杀后续进程。
      4. 记录的可执行文件已不存在时失败关闭（SKIPPED_EXECUTABLE_MISSING）。
      5. 默认 CleanupMode=Graceful：只尝试温和关闭（CloseMainWindow），
         不强制结束。只有显式传入 -AllowForceStop，且强制前立即重新做一遍五项校验，
         才会对已验证归属的进程执行 Stop-Process -Force。
         传 -CleanupMode ReportOnly 则完全不终止，只报告。
      6. 本脚本绝不把 sessionDetails.json 里的 apiKey / certificate 写入日志、报告、
         就绪文件或任何 artifact；就绪快照只保留 port / pid 等非敏感字段。

.PARAMETER HoldMinutes
    持有会话的分钟数。到点后按 CleanupMode 处理 MATLAB 进程。

.PARAMETER Work
    工作目录，也是信号文件、清理审计与（默认）所有者文件的落盘位置。

.PARAMETER MatlabExe
    matlab.exe 路径。默认从 PATH 与常见安装位置解析。

.PARAMETER ReadyFilePath
    会话就绪信号文件路径。默认 <Work>\session_ready.json。
    只包含 port / pid / 时间等非敏感字段，永远不含 apiKey / certificate。

.PARAMETER StopFilePath
    停止信号文件路径。默认 <Work>\stop_session.flag。文件出现即提前结束持有。

.PARAMETER OwnerDirectory
    本次运行所有者文件的目录。默认 <Work>\artifacts\validation\matlab_session。
    必须是调用方自己的运行目录：不要指向用户配置目录或机器级共享位置。

.PARAMETER CleanupMode
    Graceful（默认）：身份校验通过后尝试温和关闭；失败则保留并报告，除非 -AllowForceStop。
    ReportOnly：身份校验通过也不终止，只写审计。

.PARAMETER AllowForceStop
    允许在温和关闭失败后强制结束**已通过五项身份校验**的进程。默认关闭。

.PARAMETER OwnerMaxAgeMinutes
    所有者文件的最大可信年龄（分钟）。超过即视为旧运行遗留并拒绝。

.PARAMETER GracefulCloseSeconds
    温和关闭后等待进程退出的秒数。

.OUTPUTS
    [pscustomobject] Port / Pid / ReadyFilePath / HoldMinutes / PortProbe / ObservedAt。
    不含 apiKey / certificate。

.EXAMPLE
    .\Start-MatlabSharedSession.ps1 -HoldMinutes 30

.EXAMPLE
    .\Start-MatlabSharedSession.ps1 -HoldMinutes 30 -AllowForceStop

.NOTES
    sessionDetails.json 里的 ApiKey / Certificate 是本地回环服务的临时凭据；
    本脚本只从中读取 port 与 pid，不复制、不打印、不落盘。
    审计文件默认 <Work>\matlab_shared_session_cleanup.jsonl，只记录 pid、身份观测值、
    判定结果与动作，同样不含任何凭据。
#>
[CmdletBinding()]
param(
    [int]$HoldMinutes = 25,
    [string]$Work = ".",
    [string]$MatlabExe = "",
    [string]$ReadyFilePath = "",
    [string]$StopFilePath = "",
    [string]$OwnerDirectory = "",
    [ValidateSet('Graceful', 'ReportOnly')]
    [string]$CleanupMode = 'Graceful',
    [switch]$AllowForceStop,
    [int]$OwnerMaxAgeMinutes = 720,
    [int]$GracefulCloseSeconds = 10
)

# ============================================================================
# 可测试的纯逻辑/身份校验函数
#
# 这些函数在脚本被 dot-source 时也会定义，但主流程不会执行：
# tests/ProcessCleanup.Tests.ps1 通过 `. .\scripts\Start-MatlabSharedSession.ps1`
# 只取函数，不启动 MATLAB、不读写用户配置。
# ============================================================================

function Get-MasPropertyValue {
    <#
    .SYNOPSIS
    安全读取属性；属性不存在时返回默认值。
    .DESCRIPTION
    同时兼容 PSCustomObject 与 System.Diagnostics.Process 快照，
    并避免 Set-StrictMode 下访问不存在属性直接抛错。
    #>
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()]$Default = $null
    )
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function ConvertTo-MasUtc {
    <#
    .SYNOPSIS
    把日期/日期字符串归一化成 UTC DateTime；无法解析返回 $null。
    #>
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) {
        $date = [datetime]$Value
        if ($date.Kind -eq [System.DateTimeKind]::Unspecified) {
            return [datetime]::SpecifyKind($date, [System.DateTimeKind]::Utc)
        }
        return $date.ToUniversalTime()
    }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try {
        $parsed = [datetime]::Parse($text, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind)
        return $parsed.ToUniversalTime()
    }
    catch {
        return $null
    }
}

function Get-MasProcessSnapshot {
    <#
    .SYNOPSIS
    读取进程的五项身份；读取失败的字段返回 $null（调用方必须失败关闭）。
    .DESCRIPTION
    进程已退出时返回 HasExited=$true 的快照。所有属性读取都单独 try/catch，
    因为跨会话/受保护进程的 MainModule / StartTime 访问可能抛异常。
    #>
    param([Parameter(Mandatory)]$Process)

    $pidValue = 0
    try { $pidValue = [int]$Process.Id } catch { $pidValue = 0 }

    $hasExited = $true
    try { $hasExited = [bool]$Process.HasExited } catch { $hasExited = $true }

    if ($hasExited) {
        return [pscustomobject][ordered]@{
            Pid              = $pidValue
            ProcessName      = $null
            StartTimeUtc     = $null
            ExecutablePath   = $null
            WindowsSessionId = $null
            HasExited        = $true
        }
    }

    $processName = $null
    try { $processName = [string]$Process.ProcessName } catch { $processName = $null }

    $startTimeUtc = $null
    try { $startTimeUtc = ([datetime]$Process.StartTime).ToUniversalTime() } catch { $startTimeUtc = $null }

    $executablePath = $null
    try { $executablePath = [string]$Process.MainModule.FileName } catch { $executablePath = $null }
    if ([string]::IsNullOrWhiteSpace($executablePath)) {
        try { $executablePath = [string]$Process.Path } catch { $executablePath = $null }
    }

    $windowsSessionId = $null
    try { $windowsSessionId = [int]$Process.SessionId } catch { $windowsSessionId = $null }

    return [pscustomobject][ordered]@{
        Pid              = $pidValue
        ProcessName      = $processName
        StartTimeUtc     = $startTimeUtc
        ExecutablePath   = $executablePath
        WindowsSessionId = $windowsSessionId
        HasExited        = $false
    }
}

function Get-MasProcessParentId {
    <#
    .SYNOPSIS
    读取指定进程的父进程 PID；读取失败返回 $null。
    .DESCRIPTION
    只在"会话文件记录的 pid 与启动器 pid 不同"时用于确认父子关系。
    读不到父 PID 时必须失败关闭（不把该 pid 记进所有者文件）。
    #>
    param([Parameter(Mandatory)][int]$Id)
    try {
        $wmiProcess = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $Id" -ErrorAction Stop
        if ($null -ne $wmiProcess -and $null -ne $wmiProcess.ParentProcessId) {
            return [int]$wmiProcess.ParentProcessId
        }
    }
    catch {
        return $null
    }
    return $null
}

function New-MasOwnedProcessEntry {
    <#
    .SYNOPSIS
    把进程身份快照转成所有者文件中的一个条目；字段缺失时抛错（失败关闭）。
    #>
    param(
        [Parameter(Mandatory)]$Identity,
        [string]$Role = 'owned',
        [AllowNull()]$ParentPid = $null
    )

    $pidValue = 0
    try { $pidValue = [int](Get-MasPropertyValue $Identity 'Pid' 0) } catch { $pidValue = 0 }
    if ($pidValue -le 0) { throw "无法记录进程身份：PID 非法（$pidValue）。" }

    $processName = [string](Get-MasPropertyValue $Identity 'ProcessName' '')
    if ([string]::IsNullOrWhiteSpace($processName)) { throw "无法记录进程身份：ProcessName 为空（pid=$pidValue）。" }

    $startTimeUtc = ConvertTo-MasUtc (Get-MasPropertyValue $Identity 'StartTimeUtc' $null)
    if ($null -eq $startTimeUtc) { throw "无法记录进程身份：StartTime 不可读（pid=$pidValue）。" }

    $executablePath = [string](Get-MasPropertyValue $Identity 'ExecutablePath' '')
    if ([string]::IsNullOrWhiteSpace($executablePath)) { throw "无法记录进程身份：可执行文件路径为空（pid=$pidValue）。" }
    try { $executablePath = [System.IO.Path]::GetFullPath($executablePath.Trim().Trim('"')) }
    catch { throw "无法记录进程身份：可执行文件路径非法（pid=$pidValue）。" }

    $windowsSessionId = Get-MasPropertyValue $Identity 'WindowsSessionId' $null
    if ($null -eq $windowsSessionId) { throw "无法记录进程身份：Windows 会话 id 不可读（pid=$pidValue）。" }

    $parentPidValue = $null
    if ($null -ne $ParentPid) {
        try { $parentPidValue = [int]$ParentPid } catch { $parentPidValue = $null }
    }

    return [pscustomobject][ordered]@{
        pid              = $pidValue
        processName      = $processName
        startTimeUtc     = $startTimeUtc.ToString('o')
        executablePath   = $executablePath
        windowsSessionId = [int]$windowsSessionId
        parentPid        = $parentPidValue
        role             = $Role
    }
}

function New-MasOwnerRecord {
    <#
    .SYNOPSIS
    构造本次运行的所有者记录（runId + 运行开始时间 + 进程身份清单）。
    #>
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][datetime]$RunStartedAtUtc,
        [Parameter(Mandatory)]$Processes,
        [int]$OwnerScriptPid = $PID,
        [string]$OwnerScriptPath = ""
    )

    if ($RunId -notmatch '^[A-Za-z0-9-]{8,64}$') { throw "run id 非法：$RunId" }

    $entries = @()
    foreach ($entry in @($Processes)) {
        if ($null -ne $entry) { $entries += $entry }
    }
    if ($entries.Count -eq 0) { throw "所有者记录至少需要一个进程身份。" }

    $startedAtUtc = ConvertTo-MasUtc $RunStartedAtUtc
    if ($null -eq $startedAtUtc) { throw "运行开始时间非法。" }

    return [pscustomobject][ordered]@{
        schemaVersion    = '1.0.0'
        runId            = $RunId
        runStartedAtUtc  = $startedAtUtc.ToString('o')
        ownerScriptPid   = $OwnerScriptPid
        ownerScriptPath  = $OwnerScriptPath
        processes        = $entries
    }
}

function Get-MasOwnerFileForRun {
    <#
    .SYNOPSIS
    返回本次运行的所有者文件路径（owner-<runid>.json）。
    .DESCRIPTION
    runId 做了字符白名单校验，避免调用方传入的 runId 变成路径穿越。
    #>
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$RunId
    )
    if ($RunId -notmatch '^[A-Za-z0-9-]{8,64}$') { throw "run id 非法：$RunId" }
    $fullDirectory = [System.IO.Path]::GetFullPath($Directory)
    return (Join-Path $fullDirectory ("owner-$RunId.json"))
}

function Write-MasOwnerRecord {
    <#
    .SYNOPSIS
    原子写所有者文件（UTF-8 无 BOM）；只包含身份字段，不含任何凭据。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$OwnerRecord
    )
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $fullPath
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    $json = $OwnerRecord | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($fullPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $fullPath
}

function Read-MasOwnerRecord {
    <#
    .SYNOPSIS
    读取并做最小结构校验；不存在/损坏/结构非法时返回 $null（调用方按无归属处理）。
    #>
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { return $null }
        $raw = [System.IO.File]::ReadAllText($fullPath)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $record = $raw | ConvertFrom-Json
        if ($null -eq $record) { return $null }
        $runId = [string](Get-MasPropertyValue $record 'runId' '')
        if ([string]::IsNullOrWhiteSpace($runId)) { return $null }
        $entries = @(Get-MasPropertyValue $record 'processes' @())
        if ($entries.Count -eq 0) { return $null }
        return $record
    }
    catch {
        return $null
    }
}

function Remove-MasOwnerRecord {
    <#
    .SYNOPSIS
    只删除 runId 与本次运行一致的所有者文件；其他运行的文件一律不动。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RunId
    )
    $record = Read-MasOwnerRecord -Path $Path
    if ($null -eq $record) { return $false }
    $recordRunId = [string](Get-MasPropertyValue $record 'runId' '')
    if (-not [string]::Equals($recordRunId, $RunId, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    Remove-Item -LiteralPath ([System.IO.Path]::GetFullPath($Path)) -Force
    return $true
}

function Test-MasOwnedProcess {
    <#
    .SYNOPSIS
    归属判定：只有本次运行记录的身份与观测到的进程身份五项全部一致时返回 ALLOW。
    .DESCRIPTION
    这是清理的唯一决策入口，不做任何终止动作。判定顺序（先归属、后身份、失败关闭）：

      1. 所有者记录结构合法（runId/时间戳/进程字段齐全）        -> SKIPPED_OWNER_RECORD_INVALID
      2. owner.runId == 当前 runId                                -> SKIPPED_OWNER_RUN_MISMATCH
      3. owner.runStartedAtUtc 不是未来时间                        -> SKIPPED_OWNER_TIMESTAMP_INVALID
      4. owner 年龄 <= OwnerMaxAgeMinutes                          -> SKIPPED_OWNER_STALE
      5. 进程仍存在                                                -> NOOP_PROCESS_EXITED（不是错误）
      6. ProcessName == MATLAB                                     -> SKIPPED_IDENTITY_MISMATCH
      7. StartTime 与记录相差 <= StartTimeToleranceSeconds         -> SKIPPED_IDENTITY_MISMATCH
      8. 记录的可执行文件仍存在                                    -> SKIPPED_EXECUTABLE_MISSING
      9. 可执行文件路径与记录完全一致（忽略大小写）                -> SKIPPED_IDENTITY_MISMATCH
     10. Windows 会话 id 与记录一致                                -> SKIPPED_IDENTITY_MISMATCH
     全部通过                                                      -> ALLOW

    返回值包含 checks（每一项布尔值）与 observed（实际观测值），
    供审计日志原样记录；不含任何凭据。
    #>
    param(
        [AllowNull()]$OwnerRecord,
        [AllowNull()]$ProcessRecord,
        [AllowNull()]$Process,
        [Parameter(Mandatory)][string]$RunId,
        [string]$ExpectedProcessName = 'MATLAB',
        [datetime]$NowUtc = [datetime]::UtcNow,
        [int]$StartTimeToleranceSeconds = 2,
        [int]$OwnerMaxAgeMinutes = 720
    )

    $checks = [ordered]@{
        ownerRecordShapeValid    = $false
        ownerRunIdMatches        = $false
        ownerTimestampValid      = $false
        ownerAgeWithinLimit      = $false
        processExists            = $false
        processNameMatches       = $false
        startTimeMatches         = $false
        executableRecordedExists = $false
        executablePathMatches    = $false
        windowsSessionIdMatches  = $false
    }

    $observed = [ordered]@{
        exists           = $false
        pid              = $null
        processName      = $null
        startTimeUtc     = $null
        executablePath   = $null
        windowsSessionId = $null
    }

    # ---- 观测值（进程已退出时也保留 pid，便于审计）----
    if ($null -ne $Process) {
        $hasExited = Get-MasPropertyValue $Process 'HasExited' $null
        $observed.exists = ($hasExited -ne $true)
        $observed.pid = Get-MasPropertyValue $Process 'Pid' $null
        $observed.processName = Get-MasPropertyValue $Process 'ProcessName' $null
        $observed.startTimeUtc = ConvertTo-MasUtc (Get-MasPropertyValue $Process 'StartTimeUtc' $null)
        $observed.executablePath = Get-MasPropertyValue $Process 'ExecutablePath' $null
        $observed.windowsSessionId = Get-MasPropertyValue $Process 'WindowsSessionId' $null
    }

    # ---- 所有者记录字段 ----
    $ownerRunId = [string](Get-MasPropertyValue $OwnerRecord 'runId' '')
    $ownerStartedAtUtc = ConvertTo-MasUtc (Get-MasPropertyValue $OwnerRecord 'runStartedAtUtc' $null)
    $recordPid = 0
    try { $recordPid = [int](Get-MasPropertyValue $ProcessRecord 'pid' 0) } catch { $recordPid = 0 }
    $recordProcessName = [string](Get-MasPropertyValue $ProcessRecord 'processName' '')
    $recordStartTimeUtc = ConvertTo-MasUtc (Get-MasPropertyValue $ProcessRecord 'startTimeUtc' $null)
    $recordExecutablePath = [string](Get-MasPropertyValue $ProcessRecord 'executablePath' '')
    $recordSessionId = Get-MasPropertyValue $ProcessRecord 'windowsSessionId' $null

    $owner = [ordered]@{
        runId            = $ownerRunId
        pid              = $recordPid
        processName      = $recordProcessName
        startTimeUtc     = $(if ($null -ne $recordStartTimeUtc) { $recordStartTimeUtc.ToString('o') } else { $null })
        executablePath   = $recordExecutablePath
        windowsSessionId = $recordSessionId
    }

    if ($null -eq $OwnerRecord -or $null -eq $ProcessRecord -or
        [string]::IsNullOrWhiteSpace($ownerRunId) -or $null -eq $ownerStartedAtUtc -or
        $recordPid -le 0 -or [string]::IsNullOrWhiteSpace($recordProcessName) -or
        $null -eq $recordStartTimeUtc -or [string]::IsNullOrWhiteSpace($recordExecutablePath) -or
        $null -eq $recordSessionId) {
        return [pscustomobject][ordered]@{
            allowed  = $false
            noOp     = $false
            reason   = 'SKIPPED_OWNER_RECORD_INVALID'
            runId    = $RunId
            pid      = $recordPid
            checks   = [pscustomobject]$checks
            observed = [pscustomobject]$observed
            owner    = [pscustomobject]$owner
        }
    }
    $checks.ownerRecordShapeValid = $true

    # ---- 归属：runId / 时间戳 / 年龄 ----
    $checks.ownerRunIdMatches = [string]::Equals($ownerRunId, $RunId, [System.StringComparison]::OrdinalIgnoreCase)

    $nowValue = ConvertTo-MasUtc $NowUtc
    if ($null -eq $nowValue) { $nowValue = [datetime]::UtcNow }
    $checks.ownerTimestampValid = ($ownerStartedAtUtc -le $nowValue.AddMinutes(5))
    $checks.ownerAgeWithinLimit = ($ownerStartedAtUtc -ge $nowValue.AddMinutes(-1 * [math]::Abs($OwnerMaxAgeMinutes)))

    # ---- 五项身份 ----
    $checks.processExists = [bool]$observed.exists
    if ($checks.processExists) {
        $checks.processNameMatches = (-not [string]::IsNullOrWhiteSpace([string]$observed.processName)) -and
            ([string]$observed.processName -ieq $ExpectedProcessName)

        if ($null -ne $observed.startTimeUtc) {
            $delta = [math]::Abs(($observed.startTimeUtc - $recordStartTimeUtc).TotalSeconds)
            $checks.startTimeMatches = ($delta -le [math]::Abs($StartTimeToleranceSeconds))
        }

        if (-not [string]::IsNullOrWhiteSpace($recordExecutablePath)) {
            try { $checks.executableRecordedExists = Test-Path -LiteralPath $recordExecutablePath -PathType Leaf }
            catch { $checks.executableRecordedExists = $false }
        }

        if ($checks.executableRecordedExists -and -not [string]::IsNullOrWhiteSpace([string]$observed.executablePath)) {
            $checks.executablePathMatches = [string]::Equals(
                ([string]$observed.executablePath).Trim(),
                $recordExecutablePath.Trim(),
                [System.StringComparison]::OrdinalIgnoreCase)
        }

        $checks.windowsSessionIdMatches = ($null -ne $observed.windowsSessionId) -and
            ([int]$observed.windowsSessionId -eq [int]$recordSessionId)
    }

    # ---- 判定（先归属，后身份；任何不通过都不终止）----
    $reason = 'ALLOW'
    $noOp = $false
    if (-not $checks.ownerRunIdMatches) {
        $reason = 'SKIPPED_OWNER_RUN_MISMATCH'
    }
    elseif (-not $checks.ownerTimestampValid) {
        $reason = 'SKIPPED_OWNER_TIMESTAMP_INVALID'
    }
    elseif (-not $checks.ownerAgeWithinLimit) {
        $reason = 'SKIPPED_OWNER_STALE'
    }
    elseif (-not $checks.processExists) {
        $reason = 'NOOP_PROCESS_EXITED'
        $noOp = $true
    }
    elseif (-not $checks.processNameMatches) {
        $reason = 'SKIPPED_IDENTITY_MISMATCH'
    }
    elseif (-not $checks.startTimeMatches) {
        $reason = 'SKIPPED_IDENTITY_MISMATCH'
    }
    elseif (-not $checks.executableRecordedExists) {
        $reason = 'SKIPPED_EXECUTABLE_MISSING'
    }
    elseif (-not $checks.executablePathMatches) {
        $reason = 'SKIPPED_IDENTITY_MISMATCH'
    }
    elseif (-not $checks.windowsSessionIdMatches) {
        $reason = 'SKIPPED_IDENTITY_MISMATCH'
    }

    return [pscustomobject][ordered]@{
        allowed  = ($reason -eq 'ALLOW')
        noOp     = $noOp
        reason   = $reason
        runId    = $RunId
        pid      = $recordPid
        checks   = [pscustomobject]$checks
        observed = [pscustomobject]$observed
        owner    = [pscustomobject]$owner
    }
}

function Protect-MasSecretText {
    <#
    .SYNOPSIS
    从任意文本中去掉已知密钥值与 apiKey/certificate 字段值。
    .DESCRIPTION
    防御性最后一层：调用方本来就不应该把凭据放进报告；即使误放，
    这里也会把已知密钥字面值和 "apiKey": "..."/"certificate": "..." 字段值替换掉。
    #>
    param(
        [AllowNull()][string]$Text,
        [string[]]$Secrets = @()
    )
    if ($null -eq $Text) { return "" }
    $result = $Text
    foreach ($secret in @($Secrets)) {
        if ([string]::IsNullOrEmpty($secret) -or $secret.Length -lt 4) { continue }
        $result = $result.Replace($secret, '[REDACTED]')
    }
    # 整个字段替换，连字段名一起移除，避免"值没了但字段名还在"仍被当成泄露。
    $result = [regex]::Replace(
        $result,
        '(?i)"(?:api[_-]?key|certificate)"\s*:\s*"(?:[^"\\]|\\.)*"',
        '"[REDACTED_FIELD]"')
    $result = [regex]::Replace(
        $result,
        '(?i)(?:api[_-]?key|certificate)\s*[:=]\s*[^\s,;"'']+',
        '[REDACTED_FIELD]')
    return $result
}

function Write-MasAuditEvent {
    <#
    .SYNOPSIS
    追加一条 JSONL 审计事件；写入前统一做密钥脱敏。
    .DESCRIPTION
    审计内容只应包含 pid、身份观测值、判定与动作；函数本身不做凭据采集。
    #>
    param(
        [Parameter(Mandatory)][string]$AuditPath,
        [Parameter(Mandatory)][string]$Event,
        [AllowNull()]$Data = $null,
        [string[]]$Secrets = @()
    )
    $fullPath = [System.IO.Path]::GetFullPath($AuditPath)
    $directory = Split-Path -Parent $fullPath
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    $payload = [pscustomobject][ordered]@{
        schemaVersion = '1.0.0'
        atUtc         = [datetime]::UtcNow.ToString('o')
        event         = $Event
        data          = $Data
    }
    $json = $payload | ConvertTo-Json -Depth 8 -Compress
    $json = Protect-MasSecretText -Text $json -Secrets $Secrets
    [System.IO.File]::AppendAllText($fullPath, $json + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    return $json
}

function Invoke-MasOwnedCleanup {
    <#
    .SYNOPSIS
    对所有者记录中的每个进程执行"先判定、后动作"；绝不终止未通过校验的进程。
    .DESCRIPTION
    - 判定统一走 Test-MasOwnedProcess（五项身份 + 归属 freshness）。
    - CleanupMode=ReportOnly：判定通过也不动进程，只写审计。
    - CleanupMode=Graceful（默认）：先 CloseMainWindow；未退出则保留并报告。
    - -AllowForceStop：温和关闭失败后，**立即重新判定一次**，仍为 ALLOW 才 Stop-Process -Force。
    .OUTPUTS
    结果数组：pid / decision / action / checks / observed。
    #>
    param(
        [AllowNull()]$OwnerRecord,
        [Parameter(Mandatory)][string]$RunId,
        [ValidateSet('Graceful', 'ReportOnly')]
        [string]$CleanupMode = 'Graceful',
        [switch]$AllowForceStop,
        [string]$AuditPath = "",
        [string]$ExpectedProcessName = 'MATLAB',
        [int]$OwnerMaxAgeMinutes = 720,
        [int]$StartTimeToleranceSeconds = 2,
        [int]$GracefulCloseSeconds = 10,
        [string[]]$Secrets = @()
    )

    $results = New-Object System.Collections.Generic.List[object]
    if ($null -eq $OwnerRecord) { return $results.ToArray() }

    $entries = @(Get-MasPropertyValue $OwnerRecord 'processes' @())
    if ($entries.Count -eq 0) { return $results.ToArray() }

    foreach ($entry in $entries) {
        if ($null -eq $entry) { continue }

        $pidValue = 0
        try { $pidValue = [int](Get-MasPropertyValue $entry 'pid' 0) } catch { $pidValue = 0 }

        $target = $null
        if ($pidValue -gt 0) {
            $target = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
            if ($null -eq $target) { $target = $null }
        }

        $snapshot = $null
        if ($null -ne $target) { $snapshot = Get-MasProcessSnapshot -Process $target }

        $decision = Test-MasOwnedProcess -OwnerRecord $OwnerRecord -ProcessRecord $entry -Process $snapshot `
            -RunId $RunId -ExpectedProcessName $ExpectedProcessName `
            -OwnerMaxAgeMinutes $OwnerMaxAgeMinutes `
            -StartTimeToleranceSeconds $StartTimeToleranceSeconds
        $action = 'NONE'

        if ($decision.allowed) {
            if ($CleanupMode -eq 'ReportOnly') {
                $action = 'REPORT_ONLY'
            }
            elseif ($null -ne $target) {
                $closed = $false
                try { $closed = [bool]$target.CloseMainWindow() } catch { $closed = $false }
                if ($closed) {
                    try {
                        if ($target.WaitForExit([int]([math]::Abs($GracefulCloseSeconds) * 1000))) { $action = 'CLOSED' }
                    }
                    catch { $action = 'NONE' }
                }
                if ($action -ne 'CLOSED') {
                    $hasExited = $true
                    try { $hasExited = [bool]$target.HasExited } catch { $hasExited = $true }
                    if ($hasExited) { $action = 'CLOSED' }
                }
                if ($action -ne 'CLOSED') {
                    if ($AllowForceStop) {
                        # TOCTOU：终止前紧邻重做一次完整身份校验。
                        $resnapshot = Get-MasProcessSnapshot -Process $target
                        $recheck = Test-MasOwnedProcess -OwnerRecord $OwnerRecord -ProcessRecord $entry -Process $resnapshot `
                            -RunId $RunId -ExpectedProcessName $ExpectedProcessName `
                            -OwnerMaxAgeMinutes $OwnerMaxAgeMinutes `
                            -StartTimeToleranceSeconds $StartTimeToleranceSeconds
                        if ($recheck.allowed) {
                            try {
                                Stop-Process -Id $target.Id -Force -ErrorAction Stop
                                $action = 'TERMINATED'
                            }
                            catch {
                                $action = 'TERMINATION_FAILED'
                            }
                        }
                        else {
                            $decision = $recheck
                            $action = 'BLOCKED_BY_RECHECK'
                        }
                    }
                    else {
                        # 默认不强制：身份匹配也不以 Force 结束，交给用户处理。
                        $action = 'LEFT_RUNNING'
                    }
                }
            }
        }
        elseif ($decision.noOp) {
            $action = 'NOOP'
        }
        else {
            $action = 'SKIPPED'
        }

        $eventName = 'cleanup_skipped'
        if ($action -eq 'REPORT_ONLY') { $eventName = 'cleanup_report_only' }
        elseif ($action -eq 'CLOSED' -or $action -eq 'TERMINATED') { $eventName = 'cleanup_completed' }
        elseif ($action -eq 'LEFT_RUNNING') { $eventName = 'cleanup_left_running' }
        elseif ($action -eq 'NOOP') { $eventName = 'cleanup_noop' }
        elseif ($action -eq 'TERMINATION_FAILED') { $eventName = 'cleanup_failed' }

        $auditData = [pscustomobject][ordered]@{
            runId    = $RunId
            pid      = $pidValue
            decision = $decision.reason
            action   = $action
            observed = $decision.observed
        }
        if (-not [string]::IsNullOrWhiteSpace($AuditPath)) {
            Write-MasAuditEvent -AuditPath $AuditPath -Event $eventName -Data $auditData -Secrets $Secrets | Out-Null
        }

        $results.Add([pscustomobject][ordered]@{
            pid      = $pidValue
            decision = $decision.reason
            action   = $action
            checks   = $decision.checks
            observed = $decision.observed
        })
    }

    return $results.ToArray()
}

function New-MasReadySnapshot {
    <#
    .SYNOPSIS
    构造就绪快照：只从会话对象白名单读取 port / pid，凭据字段永不进入结果。
    .DESCRIPTION
    即使传入的 Session 对象包含 apiKey / certificate / 未知字段，
    返回对象也只有 Port / Pid / ReadyFilePath / HoldMinutes / PortProbe / ObservedAt。
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [string]$ReadyFilePath = "",
        [int]$HoldMinutes = 0,
        [bool]$PortProbe = $false,
        [datetime]$ObservedAtUtc = [datetime]::UtcNow
    )

    $port = 0
    try { $port = [int](Get-MasPropertyValue $Session 'port' 0) } catch { $port = 0 }
    if ($port -lt 1 -or $port -gt 65535) { throw "会话端口非法（$port）。" }

    $pidValue = 0
    try { $pidValue = [int](Get-MasPropertyValue $Session 'pid' 0) } catch { $pidValue = 0 }
    if ($pidValue -le 0) { throw "会话 PID 非法（$pidValue）。" }

    $observedAtUtc = ConvertTo-MasUtc $ObservedAtUtc
    if ($null -eq $observedAtUtc) { $observedAtUtc = [datetime]::UtcNow }

    return [pscustomobject][ordered]@{
        Port          = $port
        Pid           = $pidValue
        ReadyFilePath = $ReadyFilePath
        HoldMinutes   = $HoldMinutes
        PortProbe     = [bool]$PortProbe
        ObservedAt    = $observedAtUtc.ToString('o')
    }
}

# ============================================================================
# 主流程
#
# dot-source 只取上面的函数，不执行任何启动/终止/文件写入。
# ============================================================================
if ($MyInvocation.InvocationName -eq '.') { return }

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $Work) { $Work = (Get-Location).Path }
if (-not (Test-Path -LiteralPath $Work)) {
    New-Item -ItemType Directory -Force -Path $Work | Out-Null
}
$Work = (Resolve-Path -LiteralPath $Work).Path
if (-not $ReadyFilePath) { $ReadyFilePath = Join-Path $Work "session_ready.json" }
if (-not $StopFilePath) { $StopFilePath = Join-Path $Work "stop_session.flag" }
if (-not $OwnerDirectory) { $OwnerDirectory = Join-Path $Work "artifacts\validation\matlab_session" }

# ---- 本次运行身份：runId + UTC 起点；所有者文件按 runId 隔离 ----
$runId = [guid]::NewGuid().ToString('N')
$runStartedAtUtc = [datetime]::UtcNow
$ownerFilePath = Get-MasOwnerFileForRun -Directory $OwnerDirectory -RunId $runId
$auditPath = Join-Path $Work "matlab_shared_session_cleanup.jsonl"

# ---- 解析 matlab.exe ----
# 复用 Execution 模块的解析逻辑（显式 > MATLAB_EXE > PATH > MATLAB_ROOT > 全盘扫描），
# 不在这里硬编码任何盘符或安装路径——仓库有卫生检查禁止盘符硬编码。
$matlabModule = Join-Path $PSScriptRoot "MatlabAgentSkills.Execution.psm1"
if (-not (Test-Path -LiteralPath $matlabModule)) {
    throw "未找到 $matlabModule"
}
Import-Module -Name $matlabModule -Force -DisableNameChecking -ErrorAction Stop

if (-not $MatlabExe) {
    $MatlabExe = Resolve-MatlabExecutable -ErrorAction SilentlyContinue
}
if (-not $MatlabExe -or -not (Test-Path -LiteralPath $MatlabExe)) {
    throw "未找到 matlab.exe；请用 -MatlabExe 显式指定，或设置 MATLAB_EXE 环境变量"
}
$matlabFullPath = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $MatlabExe).Path)

$sessionFile = Join-Path $env:APPDATA "MathWorks\MATLAB MCP Server\v1\sessionDetails.json"
$logFile = Join-Path $Work "matlab_shared_session.log"

foreach ($f in @($ReadyFilePath, $StopFilePath, $logFile)) {
    if (Test-Path -LiteralPath $f) { [System.IO.File]::Delete($f) }
}
$before = if (Test-Path -LiteralPath $sessionFile) { (Get-Item -LiteralPath $sessionFile).LastWriteTime } else { $null }

# ---- 启动 MATLAB：用空转 timer 保持事件循环，绝不用 pause() 阻塞主线程 ----
$startup = "disp('BOOT_OK'); shareMATLABSession; disp('SESSION_SHARED'); " +
           "t=timer('Period',600,'ExecutionMode','fixedSpacing','TimerFcn',@(~,~)[]); start(t);"

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $MatlabExe
$psi.Arguments = "-nosplash -nodesktop -logfile `"$logFile`" -r `"$startup`""
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.WorkingDirectory = $Work

$process = New-Object System.Diagnostics.Process
$process.StartInfo = $psi
$process.Start() | Out-Null
Write-Verbose "MATLAB launcher pid=$($process.Id)"

# ---- 启动即固化身份：读不出来就失败关闭，绝不进入"未知归属但仍可终止"的状态 ----
$launcherSnapshot = Get-MasProcessSnapshot -Process $process
if ($null -eq $launcherSnapshot -or -not $launcherSnapshot.Pid) {
    throw "启动后无法读取 MATLAB 进程身份，拒绝继续（无法建立归属）。"
}
if ($launcherSnapshot.HasExited) {
    throw "MATLAB 启动器在身份固化前已退出，拒绝继续（无法建立归属）。"
}
if (-not ([string]$launcherSnapshot.ProcessName -ieq 'MATLAB')) {
    throw "启动的进程名不是 MATLAB（实际 '$($launcherSnapshot.ProcessName)'），拒绝继续。"
}
if (-not [string]::Equals([string]$launcherSnapshot.ExecutablePath, $matlabFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "启动的进程路径与解析出的 matlab.exe 不一致，拒绝继续。"
}
if ($null -eq $launcherSnapshot.StartTimeUtc -or
    $launcherSnapshot.StartTimeUtc -lt $runStartedAtUtc.AddSeconds(-5) -or
    $launcherSnapshot.StartTimeUtc -gt [datetime]::UtcNow.AddSeconds(5)) {
    throw "启动进程的 StartTime 不在本次启动窗口内，拒绝继续。"
}

$ownerScriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$launcherEntry = New-MasOwnedProcessEntry -Identity $launcherSnapshot -Role 'launcher'
$ownerRecord = New-MasOwnerRecord -RunId $runId -RunStartedAtUtc $runStartedAtUtc `
    -Processes @($launcherEntry) -OwnerScriptPid $PID -OwnerScriptPath $ownerScriptPath
Write-MasOwnerRecord -Path $ownerFilePath -OwnerRecord $ownerRecord | Out-Null
Write-MasAuditEvent -AuditPath $auditPath -Event 'ownership_recorded' -Data ([pscustomobject][ordered]@{
    runId = $runId
    processes = @($launcherEntry)
}) | Out-Null

$ready = $null
$ownedProcesses = @($launcherEntry)
$holderProcess = $process
$cleanupResults = @()

try {
    # ---- 等会话文件刷新 ----
    $deadline = (Get-Date).AddSeconds(180)
    $shared = $false
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $sessionFile) {
            $item = Get-Item -LiteralPath $sessionFile
            if ($null -eq $before -or $item.LastWriteTime -gt $before) { $shared = $true; break }
        }
        Start-Sleep -Milliseconds 500
    }

    if (-not $shared) {
        $tail = ""
        if (Test-Path -LiteralPath $logFile) {
            $tail = (Get-Content -LiteralPath $logFile -Encoding utf8 | Select-Object -Last 20) -join "`n"
            # MATLAB 的 -logfile 由 MATLAB 自己写；即使 shareMATLABSession 打印了凭据字段，
            # 也不允许它经由本脚本的错误信息进入 CI 输出或报告。
            $tail = Protect-MasSecretText -Text $tail
        }
        throw "MATLAB 未在 180 秒内共享会话。日志尾部：`n$tail"
    }

    Start-Sleep -Seconds 2
    # 只读取需要的 port / pid；证书与 apiKey 不取、不复制、不打印。
    $session = Get-Content -Raw -LiteralPath $sessionFile | ConvertFrom-Json

    # ---- 自检：会话必须真的能执行代码，而不只是端口在听 ----
    # 这一步专门用来抓"pause() 阻塞主线程"那一类假活会话：
    # HTTP 监听在后台线程，端口探活会通过，但 tools/call 会永久挂起。
    $probe = $null
    try {
        $probe = Invoke-RestMethod -Uri "https://localhost:$((Get-MasPropertyValue $session 'port' 0))/" -SkipCertificateCheck -TimeoutSec 10 -Proxy $null -ErrorAction Stop
    }
    catch {
        Write-Verbose "端口自检未通过（不视为致命）：$($_.Exception.Message)"
    }

    # ---- 会话文件里的 pid 只是观测值：必须是本次启动器的 MATLAB 子进程才记入归属 ----
    $sessionPidValue = 0
    try { $sessionPidValue = [int](Get-MasPropertyValue $session 'pid' 0) } catch { $sessionPidValue = 0 }

    if ($sessionPidValue -gt 0 -and $sessionPidValue -ne $process.Id) {
        $candidateProcess = Get-Process -Id $sessionPidValue -ErrorAction SilentlyContinue
        $candidateSnapshot = $null
        if ($null -ne $candidateProcess) { $candidateSnapshot = Get-MasProcessSnapshot -Process $candidateProcess }
        $candidateParentPid = Get-MasProcessParentId -Id $sessionPidValue

        $candidateOwned = $false
        if ($null -ne $candidateSnapshot -and -not $candidateSnapshot.HasExited -and
            $null -ne $candidateSnapshot.StartTimeUtc -and
            -not [string]::IsNullOrWhiteSpace([string]$candidateSnapshot.ExecutablePath)) {
            $candidateOwned =
                ([string]$candidateSnapshot.ProcessName -ieq 'MATLAB') -and
                ([string]::Equals([string]$candidateSnapshot.ExecutablePath, $matlabFullPath, [System.StringComparison]::OrdinalIgnoreCase)) -and
                ($candidateSnapshot.StartTimeUtc -ge $runStartedAtUtc.AddSeconds(-2)) -and
                ($null -ne $candidateSnapshot.WindowsSessionId) -and
                ([int]$candidateSnapshot.WindowsSessionId -eq [int]$launcherSnapshot.WindowsSessionId) -and
                ($null -ne $candidateParentPid) -and
                ([int]$candidateParentPid -eq $process.Id)
        }

        if ($candidateOwned) {
            $sessionEntry = New-MasOwnedProcessEntry -Identity $candidateSnapshot -Role 'session-runtime' -ParentPid $candidateParentPid
            $ownedProcesses = @($launcherEntry, $sessionEntry)
            $ownerRecord = New-MasOwnerRecord -RunId $runId -RunStartedAtUtc $runStartedAtUtc `
                -Processes $ownedProcesses -OwnerScriptPid $PID -OwnerScriptPath $ownerScriptPath
            Write-MasOwnerRecord -Path $ownerFilePath -OwnerRecord $ownerRecord | Out-Null
            $holderProcess = $candidateProcess
            Write-MasAuditEvent -AuditPath $auditPath -Event 'session_runtime_owned' -Data ([pscustomobject][ordered]@{
                runId = $runId
                pid = $sessionPidValue
                parentPid = $candidateParentPid
            }) | Out-Null
        }
        else {
            # 不满足父子 + 名称 + 路径 + 会话 + 时间窗：绝不把会话文件里的 pid 记入归属。
            Write-MasAuditEvent -AuditPath $auditPath -Event 'session_runtime_not_owned' -Data ([pscustomobject][ordered]@{
                runId = $runId
                pid = $sessionPidValue
                parentPid = $candidateParentPid
                observed = [pscustomobject][ordered]@{
                    processName = $(if ($null -ne $candidateSnapshot) { $candidateSnapshot.ProcessName } else { $null })
                    startTimeUtc = $(if ($null -ne $candidateSnapshot -and $null -ne $candidateSnapshot.StartTimeUtc) { $candidateSnapshot.StartTimeUtc.ToString('o') } else { $null })
                    executablePath = $(if ($null -ne $candidateSnapshot) { $candidateSnapshot.ExecutablePath } else { $null })
                    windowsSessionId = $(if ($null -ne $candidateSnapshot) { $candidateSnapshot.WindowsSessionId } else { $null })
                }
            }) | Out-Null
        }
    }

    # ---- 就绪快照：只保留非敏感字段 ----
    $ready = New-MasReadySnapshot -Session $session -ReadyFilePath $ReadyFilePath -HoldMinutes $HoldMinutes `
        -PortProbe ([bool]("$probe" -ne "")) -ObservedAtUtc ([datetime]::UtcNow)
    $session = $null

    $readyJson = $ready | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($ReadyFilePath), $readyJson,
        (New-Object System.Text.UTF8Encoding($false)))

    Write-Host "SESSION_READY port=$($ready.Port) pid=$($ready.Pid) hold=${HoldMinutes}m"

    # ---- 持有 ----
    $stopAt = (Get-Date).AddMinutes($HoldMinutes)
    while ((Get-Date) -lt $stopAt) {
        if (Test-Path -LiteralPath $StopFilePath) { Write-Host "STOP_FILE detected"; break }
        $holderExited = $true
        if ($null -ne $holderProcess) {
            try { $holderExited = [bool]$holderProcess.HasExited } catch { $holderExited = $true }
        }
        if ($holderExited) { Write-Host "MATLAB_PROCESS_EXITED"; break }
        Start-Sleep -Seconds 2
    }
}
finally {
    # ---- 清理：唯一入口是 Invoke-MasOwnedCleanup -> Test-MasOwnedProcess ----
    try {
        $cleanupResults = @(Invoke-MasOwnedCleanup -OwnerRecord $ownerRecord -RunId $runId `
            -CleanupMode $CleanupMode -AllowForceStop:$AllowForceStop `
            -AuditPath $auditPath -OwnerMaxAgeMinutes $OwnerMaxAgeMinutes `
            -GracefulCloseSeconds $GracefulCloseSeconds)
        foreach ($result in $cleanupResults) {
            $observedText = ""
            if ($result.observed) {
                $observedText = "observedName=$($result.observed.processName) observedStart=$($result.observed.startTimeUtc) observedExe=$($result.observed.executablePath) observedSession=$($result.observed.windowsSessionId)"
            }
            Write-Host "CLEANUP pid=$($result.pid) decision=$($result.decision) action=$($result.action) $observedText"
        }
        Remove-MasOwnerRecord -Path $ownerFilePath -RunId $runId | Out-Null
    }
    catch {
        Write-Host "CLEANUP_ERROR $($_.Exception.Message)"
    }
}
Write-Host "HOLDER_DONE"
return $ready
