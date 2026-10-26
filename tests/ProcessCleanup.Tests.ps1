<#
.SYNOPSIS
    MATLAB 共享会话清理的归属校验回归测试（免费层：不启动真实 MATLAB，不执行 COM/MCP）。

.DESCRIPTION
    背景：安全评审确认，旧实现直接读取 sessionDetails.json 里的 pid 并
    Stop-Process -Force，不校验进程名/启动时间/可执行文件路径/Windows 会话 id。
    sessionDetails.json 会被任意一次 MATLAB 启动重写，所以过期或回收的 PID
    可能让脚本杀掉用户的 MATLAB 或无关进程。

    本文件验证整改后的 INVARIANT：
      - 只有本次运行记录、且五项身份全部复核通过的进程才允许清理；
      - PID 被回收（同 PID、不同 StartTime）、exe 路径不符、会话 id 不符、
        进程已退出、旧运行遗留的所有者文件，都必须不产生终止动作；
      - 就绪文件、审计日志、清理报告都不包含 apiKey / certificate。

    所有真实进程都是 powershell.exe -NoProfile -Command Start-Sleep 60 替身，
    测试结束一定会结束替身；不会结束任何 MATLAB 进程。
#>

. (Join-Path $PSScriptRoot 'helpers/Assertions.ps1')

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:CleanupScriptPath = Join-Path $script:RepoRoot 'scripts/Start-MatlabSharedSession.ps1'

# dot-source 只定义函数：脚本检测到 InvocationName 为 '.' 后直接 return，
# 不会解析 matlab.exe、不会启动/终止进程、不会写任何文件。
. $script:CleanupScriptPath

function New-CleanupSandbox {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('mas-process-cleanup-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    [pscustomobject]@{
        Root      = $root
        OwnerFile = (Join-Path $root 'owner-test.json')
        Audit     = (Join-Path $root 'cleanup_audit.jsonl')
        FakeExe   = (Join-Path $root 'fake-matlab.exe')
    }
}

function Remove-CleanupSandbox {
    param($Sandbox)
    $root = [IO.Path]::GetFullPath($Sandbox.Root)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    if (-not $root.StartsWith($temp) -or (Split-Path -Leaf $root) -notlike 'mas-process-cleanup-*') {
        throw '清理测试目录越界，拒绝删除。'
    }
    Remove-Item -LiteralPath $root -Recurse -Force
}

function New-CleanupRunId {
    return [guid]::NewGuid().ToString('N')
}

function Get-CleanupStandInExe {
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $exe)) { $exe = (Get-Command powershell.exe -ErrorAction Stop).Source }
    return $exe
}

function Start-CleanupStandIn {
    # 替身进程：无害、长生命周期、可被本测试安全结束。
    return Start-Process -FilePath (Get-CleanupStandInExe) `
        -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60' `
        -PassThru -WindowStyle Hidden
}

function Stop-CleanupStandIn {
    param($Process)
    try {
        if ($null -ne $Process -and -not $Process.HasExited) {
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        }
    }
    catch { }
}

function New-CleanupOwner {
    <#
    .SYNOPSIS
    构造一份所有者记录；身份字段完全由调用方指定，便于制造回收/错配场景。
    #>
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$StartTimeUtc,
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$RunId,
        [datetime]$RunStartedAtUtc = [datetime]::UtcNow,
        [int]$WindowsSessionId = 1,
        [string]$ProcessName = 'MATLAB',
        [int]$ParentPid = 0
    )
    $parentValue = $null
    if ($ParentPid -gt 0) { $parentValue = $ParentPid }
    $entry = [pscustomobject][ordered]@{
        pid              = $ProcessId
        processName      = $ProcessName
        startTimeUtc     = $StartTimeUtc
        executablePath   = $ExecutablePath
        windowsSessionId = $WindowsSessionId
        parentPid        = $parentValue
        role             = 'test'
    }
    $record = [pscustomobject][ordered]@{
        schemaVersion   = '1.0.0'
        runId           = $RunId
        runStartedAtUtc = $RunStartedAtUtc.ToUniversalTime().ToString('o')
        ownerScriptPid  = $PID
        ownerScriptPath = 'test-double'
        processes       = @($entry)
    }
    return [pscustomobject]@{ Record = $record; Entry = $entry }
}

Describe '归属判定：五项身份必须全部匹配' {

    It '本次运行记录的存活替身进程五项一致时判定 ALLOW' {
        $sandbox = New-CleanupSandbox
        $standIn = $null
        try {
            $standIn = Start-CleanupStandIn
            Start-Sleep -Milliseconds 300
            $snapshot = Get-MasProcessSnapshot -Process $standIn
            $runId = New-CleanupRunId
            $owner = New-CleanupOwner -ProcessId $snapshot.Pid -StartTimeUtc $snapshot.StartTimeUtc.ToString('o') `
                -ExecutablePath $snapshot.ExecutablePath -WindowsSessionId $snapshot.WindowsSessionId `
                -RunId $runId -ProcessName 'powershell'

            $decision = Test-MasOwnedProcess -OwnerRecord $owner.Record -ProcessRecord $owner.Entry `
                -Process $snapshot -RunId $runId -ExpectedProcessName 'powershell'

            $decision.allowed | Should Be $true
            $decision.reason | Should Be ALLOW
            @($decision.checks.PSObject.Properties | Where-Object { -not $_.Value }).Count | Should Be 0
            $decision.observed.pid | Should Be $standIn.Id
        }
        finally {
            Stop-CleanupStandIn $standIn
            Remove-CleanupSandbox $sandbox
        }
    }

    It '同一 PID 但启动时间不同（PID 回收）时判定 SKIPPED_IDENTITY_MISMATCH' {
        $sandbox = New-CleanupSandbox
        $standIn = $null
        try {
            $standIn = Start-CleanupStandIn
            Start-Sleep -Milliseconds 300
            $snapshot = Get-MasProcessSnapshot -Process $standIn
            $runId = New-CleanupRunId
            # 记录的是"同一个 PID，但创建时间早 120 秒"的旧进程。
            $owner = New-CleanupOwner -ProcessId $snapshot.Pid `
                -StartTimeUtc $snapshot.StartTimeUtc.AddSeconds(-120).ToString('o') `
                -ExecutablePath $snapshot.ExecutablePath -WindowsSessionId $snapshot.WindowsSessionId `
                -RunId $runId -ProcessName 'powershell'

            $decision = Test-MasOwnedProcess -OwnerRecord $owner.Record -ProcessRecord $owner.Entry `
                -Process $snapshot -RunId $runId -ExpectedProcessName 'powershell'

            $decision.allowed | Should Be $false
            $decision.reason | Should Be SKIPPED_IDENTITY_MISMATCH
            $decision.checks.startTimeMatches | Should Be $false
            $decision.checks.processNameMatches | Should Be $true
            $null -eq $decision.observed.startTimeUtc | Should Be $false
        }
        finally {
            Stop-CleanupStandIn $standIn
            Remove-CleanupSandbox $sandbox
        }
    }

    It '可执行文件路径与记录不一致时判定 SKIPPED_IDENTITY_MISMATCH' {
        $sandbox = New-CleanupSandbox
        $standIn = $null
        try {
            [IO.File]::WriteAllText($sandbox.FakeExe, 'test-double-only')
            $standIn = Start-CleanupStandIn
            Start-Sleep -Milliseconds 300
            $snapshot = Get-MasProcessSnapshot -Process $standIn
            $runId = New-CleanupRunId
            $owner = New-CleanupOwner -ProcessId $snapshot.Pid -StartTimeUtc $snapshot.StartTimeUtc.ToString('o') `
                -ExecutablePath $sandbox.FakeExe -WindowsSessionId $snapshot.WindowsSessionId `
                -RunId $runId -ProcessName 'powershell'

            $decision = Test-MasOwnedProcess -OwnerRecord $owner.Record -ProcessRecord $owner.Entry `
                -Process $snapshot -RunId $runId -ExpectedProcessName 'powershell'

            $decision.allowed | Should Be $false
            $decision.reason | Should Be SKIPPED_IDENTITY_MISMATCH
            $decision.checks.executableRecordedExists | Should Be $true
            $decision.checks.executablePathMatches | Should Be $false
            $decision.observed.executablePath | Should Be $snapshot.ExecutablePath
        }
        finally {
            Stop-CleanupStandIn $standIn
            Remove-CleanupSandbox $sandbox
        }
    }

    It '进程名不是 MATLAB 时判定 SKIPPED_IDENTITY_MISMATCH（默认期望名）' {
        $sandbox = New-CleanupSandbox
        $standIn = $null
        try {
            $standIn = Start-CleanupStandIn
            Start-Sleep -Milliseconds 300
            $snapshot = Get-MasProcessSnapshot -Process $standIn
            $runId = New-CleanupRunId
            $owner = New-CleanupOwner -ProcessId $snapshot.Pid -StartTimeUtc $snapshot.StartTimeUtc.ToString('o') `
                -ExecutablePath $snapshot.ExecutablePath -WindowsSessionId $snapshot.WindowsSessionId `
                -RunId $runId -ProcessName 'MATLAB'

            # 不传 -ExpectedProcessName，生产默认值就是 MATLAB。
            $decision = Test-MasOwnedProcess -OwnerRecord $owner.Record -ProcessRecord $owner.Entry `
                -Process $snapshot -RunId $runId

            $decision.allowed | Should Be $false
            $decision.reason | Should Be SKIPPED_IDENTITY_MISMATCH
            $decision.checks.processNameMatches | Should Be $false
            $decision.observed.processName | Should Be 'powershell'
        }
        finally {
            Stop-CleanupStandIn $standIn
            Remove-CleanupSandbox $sandbox
        }
    }

    It 'Windows 会话 id 与记录不一致时判定 SKIPPED_IDENTITY_MISMATCH' {
        $sandbox = New-CleanupSandbox
        $standIn = $null
        try {
            $standIn = Start-CleanupStandIn
            Start-Sleep -Milliseconds 300
            $snapshot = Get-MasProcessSnapshot -Process $standIn
            $runId = New-CleanupRunId
            $owner = New-CleanupOwner -ProcessId $snapshot.Pid -StartTimeUtc $snapshot.StartTimeUtc.ToString('o') `
                -ExecutablePath $snapshot.ExecutablePath -WindowsSessionId ($snapshot.WindowsSessionId + 1) `
                -RunId $runId -ProcessName 'powershell'

            $decision = Test-MasOwnedProcess -OwnerRecord $owner.Record -ProcessRecord $owner.Entry `
                -Process $snapshot -RunId $runId -ExpectedProcessName 'powershell'

            $decision.allowed | Should Be $false
            $decision.reason | Should Be SKIPPED_IDENTITY_MISMATCH
            $decision.checks.windowsSessionIdMatches | Should Be $false
        }
        finally {
            Stop-CleanupStandIn $standIn
            Remove-CleanupSandbox $sandbox
        }
    }

    It '记录的可执行文件已不存在时失败关闭为 SKIPPED_EXECUTABLE_MISSING' {
        $sandbox = New-CleanupSandbox
        $standIn = $null
        try {
            $standIn = Start-CleanupStandIn
            Start-Sleep -Milliseconds 300
            $snapshot = Get-MasProcessSnapshot -Process $standIn
            $runId = New-CleanupRunId
            $goneExe = Join-Path $sandbox.Root 'deleted-matlab.exe'
            $owner = New-CleanupOwner -ProcessId $snapshot.Pid -StartTimeUtc $snapshot.StartTimeUtc.ToString('o') `
                -ExecutablePath $goneExe -WindowsSessionId $snapshot.WindowsSessionId `
                -RunId $runId -ProcessName 'powershell'

            $decision = Test-MasOwnedProcess -OwnerRecord $owner.Record -ProcessRecord $owner.Entry `
                -Process $snapshot -RunId $runId -ExpectedProcessName 'powershell'

            $decision.allowed | Should Be $false
            $decision.reason | Should Be SKIPPED_EXECUTABLE_MISSING
            $decision.checks.executableRecordedExists | Should Be $false
        }
        finally {
            Stop-CleanupStandIn $standIn
            Remove-CleanupSandbox $sandbox
        }
    }

    It '进程已经退出时是 NOOP 而不是错误' {
        $sandbox = New-CleanupSandbox
        try {
            [IO.File]::WriteAllText($sandbox.FakeExe, 'test-double-only')
            $runId = New-CleanupRunId
            $owner = New-CleanupOwner -ProcessId 2147483000 `
                -StartTimeUtc ([datetime]::UtcNow.AddMinutes(-1).ToString('o')) `
                -ExecutablePath $sandbox.FakeExe -WindowsSessionId 1 `
                -RunId $runId -ProcessName 'MATLAB'

            # 观测值为 $null：进程已不存在，不得抛异常。
            $decision = Test-MasOwnedProcess -OwnerRecord $owner.Record -ProcessRecord $owner.Entry `
                -Process $null -RunId $runId -ExpectedProcessName 'powershell'

            $decision.allowed | Should Be $false
            $decision.noOp | Should Be $true
            $decision.reason | Should Be NOOP_PROCESS_EXITED
        }
        finally {
            Remove-CleanupSandbox $sandbox
        }
    }

    It '旧运行遗留的所有者记录（runId 不同）时判定 SKIPPED_OWNER_RUN_MISMATCH' {
        $sandbox = New-CleanupSandbox
        $standIn = $null
        try {
            $standIn = Start-CleanupStandIn
            Start-Sleep -Milliseconds 300
            $snapshot = Get-MasProcessSnapshot -Process $standIn
            $oldRunId = New-CleanupRunId
            $owner = New-CleanupOwner -ProcessId $snapshot.Pid -StartTimeUtc $snapshot.StartTimeUtc.ToString('o') `
                -ExecutablePath $snapshot.ExecutablePath -WindowsSessionId $snapshot.WindowsSessionId `
                -RunId $oldRunId -ProcessName 'powershell'

            $decision = Test-MasOwnedProcess -OwnerRecord $owner.Record -ProcessRecord $owner.Entry `
                -Process $snapshot -RunId (New-CleanupRunId) -ExpectedProcessName 'powershell'

            $decision.allowed | Should Be $false
            $decision.reason | Should Be SKIPPED_OWNER_RUN_MISMATCH
            $decision.checks.ownerRunIdMatches | Should Be $false
            $standIn.HasExited | Should Be $false
        }
        finally {
            Stop-CleanupStandIn $standIn
            Remove-CleanupSandbox $sandbox
        }
    }

    It '同一 runId 但所有者记录超过最大可信年龄时判定 SKIPPED_OWNER_STALE' {
        $sandbox = New-CleanupSandbox
        $standIn = $null
        try {
            $standIn = Start-CleanupStandIn
            Start-Sleep -Milliseconds 300
            $snapshot = Get-MasProcessSnapshot -Process $standIn
            $runId = New-CleanupRunId
            $owner = New-CleanupOwner -ProcessId $snapshot.Pid -StartTimeUtc $snapshot.StartTimeUtc.ToString('o') `
                -ExecutablePath $snapshot.ExecutablePath -WindowsSessionId $snapshot.WindowsSessionId `
                -RunId $runId -RunStartedAtUtc ([datetime]::UtcNow.AddDays(-3)) -ProcessName 'powershell'

            $decision = Test-MasOwnedProcess -OwnerRecord $owner.Record -ProcessRecord $owner.Entry `
                -Process $snapshot -RunId $runId -ExpectedProcessName 'powershell' -OwnerMaxAgeMinutes 720

            $decision.allowed | Should Be $false
            $decision.reason | Should Be SKIPPED_OWNER_STALE
            $decision.checks.ownerAgeWithinLimit | Should Be $false
        }
        finally {
            Stop-CleanupStandIn $standIn
            Remove-CleanupSandbox $sandbox
        }
    }

    It '所有者记录时间戳在未来时判定 SKIPPED_OWNER_TIMESTAMP_INVALID' {
        $sandbox = New-CleanupSandbox
        $standIn = $null
        try {
            $standIn = Start-CleanupStandIn
            Start-Sleep -Milliseconds 300
            $snapshot = Get-MasProcessSnapshot -Process $standIn
            $runId = New-CleanupRunId
            $owner = New-CleanupOwner -ProcessId $snapshot.Pid -StartTimeUtc $snapshot.StartTimeUtc.ToString('o') `
                -ExecutablePath $snapshot.ExecutablePath -WindowsSessionId $snapshot.WindowsSessionId `
                -RunId $runId -RunStartedAtUtc ([datetime]::UtcNow.AddHours(1)) -ProcessName 'powershell'

            $decision = Test-MasOwnedProcess -OwnerRecord $owner.Record -ProcessRecord $owner.Entry `
                -Process $snapshot -RunId $runId -ExpectedProcessName 'powershell'

            $decision.allowed | Should Be $false
            $decision.reason | Should Be SKIPPED_OWNER_TIMESTAMP_INVALID
        }
        finally {
            Stop-CleanupStandIn $standIn
            Remove-CleanupSandbox $sandbox
        }
    }

    It '所有者记录缺少必要身份字段时判定 SKIPPED_OWNER_RECORD_INVALID' {
        $decision = Test-MasOwnedProcess -OwnerRecord $null -ProcessRecord $null -Process $null `
            -RunId (New-CleanupRunId) -ExpectedProcessName 'powershell'
        $decision.allowed | Should Be $false
        $decision.reason | Should Be SKIPPED_OWNER_RECORD_INVALID
    }
}

Describe '清理动作只作用于已验证归属的替身进程' {

    It 'ALLOW + ReportOnly 只写报告，不结束替身进程' {
        $sandbox = New-CleanupSandbox
        $standIn = $null
        try {
            $standIn = Start-CleanupStandIn
            Start-Sleep -Milliseconds 300
            $snapshot = Get-MasProcessSnapshot -Process $standIn
            $runId = New-CleanupRunId
            $owner = New-CleanupOwner -ProcessId $snapshot.Pid -StartTimeUtc $snapshot.StartTimeUtc.ToString('o') `
                -ExecutablePath $snapshot.ExecutablePath -WindowsSessionId $snapshot.WindowsSessionId `
                -RunId $runId -ProcessName 'powershell'

            $results = @(Invoke-MasOwnedCleanup -OwnerRecord $owner.Record -RunId $runId `
                -CleanupMode ReportOnly -AuditPath $sandbox.Audit -ExpectedProcessName 'powershell')

            $results.Count | Should Be 1
            $results[0].decision | Should Be ALLOW
            $results[0].action | Should Be REPORT_ONLY
            $standIn.HasExited | Should Be $false
            ([IO.File]::ReadAllText($sandbox.Audit)) | Should Match 'cleanup_report_only'
        }
        finally {
            Stop-CleanupStandIn $standIn
            Remove-CleanupSandbox $sandbox
        }
    }

    It 'ALLOW + Graceful + AllowForceStop 只结束本次记录的替身进程' {
        $sandbox = New-CleanupSandbox
        $standIn = $null
        try {
            $standIn = Start-CleanupStandIn
            Start-Sleep -Milliseconds 300
            $snapshot = Get-MasProcessSnapshot -Process $standIn
            $runId = New-CleanupRunId
            $owner = New-CleanupOwner -ProcessId $snapshot.Pid -StartTimeUtc $snapshot.StartTimeUtc.ToString('o') `
                -ExecutablePath $snapshot.ExecutablePath -WindowsSessionId $snapshot.WindowsSessionId `
                -RunId $runId -ProcessName 'powershell'

            $results = @(Invoke-MasOwnedCleanup -OwnerRecord $owner.Record -RunId $runId `
                -CleanupMode Graceful -AllowForceStop -AuditPath $sandbox.Audit `
                -ExpectedProcessName 'powershell' -GracefulCloseSeconds 1)

            $results.Count | Should Be 1
            $results[0].decision | Should Be ALLOW
            $results[0].action | Should Be TERMINATED
            Start-Sleep -Milliseconds 300
            $standIn.HasExited | Should Be $true
            ([IO.File]::ReadAllText($sandbox.Audit)) | Should Match 'cleanup_completed'
        }
        finally {
            Stop-CleanupStandIn $standIn
            Remove-CleanupSandbox $sandbox
        }
    }

    It '默认 Graceful 不允许强制时即使 ALLOW 也保留进程（LEFT_RUNNING）' {
        $sandbox = New-CleanupSandbox
        $standIn = $null
        try {
            $standIn = Start-CleanupStandIn
            Start-Sleep -Milliseconds 300
            $snapshot = Get-MasProcessSnapshot -Process $standIn
            $runId = New-CleanupRunId
            $owner = New-CleanupOwner -ProcessId $snapshot.Pid -StartTimeUtc $snapshot.StartTimeUtc.ToString('o') `
                -ExecutablePath $snapshot.ExecutablePath -WindowsSessionId $snapshot.WindowsSessionId `
                -RunId $runId -ProcessName 'powershell'

            $results = @(Invoke-MasOwnedCleanup -OwnerRecord $owner.Record -RunId $runId `
                -CleanupMode Graceful -AuditPath $sandbox.Audit `
                -ExpectedProcessName 'powershell' -GracefulCloseSeconds 1)

            $results[0].decision | Should Be ALLOW
            $results[0].action | Should Be LEFT_RUNNING
            $standIn.HasExited | Should Be $false
            ([IO.File]::ReadAllText($sandbox.Audit)) | Should Match 'cleanup_left_running'
        }
        finally {
            Stop-CleanupStandIn $standIn
            Remove-CleanupSandbox $sandbox
        }
    }

    It 'PID 回收的替身进程在强制清理模式下仍然存活' {
        $sandbox = New-CleanupSandbox
        $standIn = $null
        try {
            $standIn = Start-CleanupStandIn
            Start-Sleep -Milliseconds 300
            $snapshot = Get-MasProcessSnapshot -Process $standIn
            $runId = New-CleanupRunId
            $owner = New-CleanupOwner -ProcessId $snapshot.Pid `
                -StartTimeUtc $snapshot.StartTimeUtc.AddSeconds(-180).ToString('o') `
                -ExecutablePath $snapshot.ExecutablePath -WindowsSessionId $snapshot.WindowsSessionId `
                -RunId $runId -ProcessName 'powershell'

            $results = @(Invoke-MasOwnedCleanup -OwnerRecord $owner.Record -RunId $runId `
                -CleanupMode Graceful -AllowForceStop -AuditPath $sandbox.Audit `
                -ExpectedProcessName 'powershell' -GracefulCloseSeconds 1)

            $results[0].decision | Should Be SKIPPED_IDENTITY_MISMATCH
            $results[0].action | Should Be SKIPPED
            $standIn.HasExited | Should Be $false
            ([IO.File]::ReadAllText($sandbox.Audit)) | Should Match 'cleanup_skipped'
        }
        finally {
            Stop-CleanupStandIn $standIn
            Remove-CleanupSandbox $sandbox
        }
    }

    It '磁盘上的旧运行所有者文件不会被本次运行清理，也不会触发终止' {
        $sandbox = New-CleanupSandbox
        $standIn = $null
        try {
            $standIn = Start-CleanupStandIn
            Start-Sleep -Milliseconds 300
            $snapshot = Get-MasProcessSnapshot -Process $standIn
            $oldRunId = New-CleanupRunId
            $owner = New-CleanupOwner -ProcessId $snapshot.Pid -StartTimeUtc $snapshot.StartTimeUtc.ToString('o') `
                -ExecutablePath $snapshot.ExecutablePath -WindowsSessionId $snapshot.WindowsSessionId `
                -RunId $oldRunId -RunStartedAtUtc ([datetime]::UtcNow.AddHours(-2)) -ProcessName 'powershell'
            Write-MasOwnerRecord -Path $sandbox.OwnerFile -OwnerRecord $owner.Record | Out-Null

            $loaded = Read-MasOwnerRecord -Path $sandbox.OwnerFile
            $null -eq $loaded | Should Be $false

            $currentRunId = New-CleanupRunId
            $results = @(Invoke-MasOwnedCleanup -OwnerRecord $loaded -RunId $currentRunId `
                -CleanupMode Graceful -AllowForceStop -AuditPath $sandbox.Audit `
                -ExpectedProcessName 'powershell' -GracefulCloseSeconds 1)

            $results[0].decision | Should Be SKIPPED_OWNER_RUN_MISMATCH
            $results[0].action | Should Be SKIPPED
            $standIn.HasExited | Should Be $false
            (Test-Path -LiteralPath $sandbox.OwnerFile) | Should Be $true
            (Remove-MasOwnerRecord -Path $sandbox.OwnerFile -RunId $currentRunId) | Should Be $false
        }
        finally {
            Stop-CleanupStandIn $standIn
            Remove-CleanupSandbox $sandbox
        }
    }

    It '进程已不存在时清理是 NOOP，不抛异常也不写终止动作' {
        $sandbox = New-CleanupSandbox
        try {
            [IO.File]::WriteAllText($sandbox.FakeExe, 'test-double-only')
            $runId = New-CleanupRunId
            $owner = New-CleanupOwner -ProcessId 2147483000 `
                -StartTimeUtc ([datetime]::UtcNow.AddMinutes(-1).ToString('o')) `
                -ExecutablePath $sandbox.FakeExe -WindowsSessionId 1 `
                -RunId $runId -ProcessName 'powershell'

            $results = @(Invoke-MasOwnedCleanup -OwnerRecord $owner.Record -RunId $runId `
                -CleanupMode Graceful -AllowForceStop -AuditPath $sandbox.Audit `
                -ExpectedProcessName 'powershell' -GracefulCloseSeconds 1)

            $results.Count | Should Be 1
            $results[0].decision | Should Be NOOP_PROCESS_EXITED
            $results[0].action | Should Be NOOP
            ([IO.File]::ReadAllText($sandbox.Audit)) | Should Match 'cleanup_noop'
        }
        finally {
            Remove-CleanupSandbox $sandbox
        }
    }

    It '所有者文件不存在或损坏时清理返回空结果且不报错' {
        $sandbox = New-CleanupSandbox
        try {
            $null -eq (Read-MasOwnerRecord -Path $sandbox.OwnerFile) | Should Be $true
            $results = @(Invoke-MasOwnedCleanup -OwnerRecord $null -RunId (New-CleanupRunId) -AuditPath $sandbox.Audit)
            $results.Count | Should Be 0

            [IO.File]::WriteAllText($sandbox.OwnerFile, '{"runId":"broken"')
            $null -eq (Read-MasOwnerRecord -Path $sandbox.OwnerFile) | Should Be $true
            $results = @(Invoke-MasOwnedCleanup -OwnerRecord (Read-MasOwnerRecord -Path $sandbox.OwnerFile) `
                -RunId (New-CleanupRunId) -AuditPath $sandbox.Audit)
            $results.Count | Should Be 0
        }
        finally {
            Remove-CleanupSandbox $sandbox
        }
    }

    It '所有者文件读写往返保留身份字段，且只删除本次 run 的文件' {
        $sandbox = New-CleanupSandbox
        try {
            $runId = New-CleanupRunId
            $owner = New-CleanupOwner -ProcessId 4242 `
                -StartTimeUtc ([datetime]::UtcNow.AddMinutes(-1).ToString('o')) `
                -ExecutablePath $sandbox.FakeExe -WindowsSessionId 7 `
                -RunId $runId -ProcessName 'MATLAB'
            [IO.File]::WriteAllText($sandbox.FakeExe, 'test-double-only')

            Write-MasOwnerRecord -Path $sandbox.OwnerFile -OwnerRecord $owner.Record | Out-Null
            $loaded = Read-MasOwnerRecord -Path $sandbox.OwnerFile

            $loaded.runId | Should Be $runId
            @($loaded.processes).Count | Should Be 1
            $loaded.processes[0].pid | Should Be 4242
            $loaded.processes[0].executablePath | Should Be $sandbox.FakeExe
            $loaded.processes[0].windowsSessionId | Should Be 7

            (Remove-MasOwnerRecord -Path $sandbox.OwnerFile -RunId $runId) | Should Be $true
            (Test-Path -LiteralPath $sandbox.OwnerFile) | Should Be $false
        }
        finally {
            Remove-CleanupSandbox $sandbox
        }
    }
}

Describe '凭据不外泄' {

    It '就绪快照即使会话对象带 apiKey/certificate 也只输出白名单字段' {
        $secretApiKey = 'SECRET-API-KEY-0123456789'
        $secretCertificate = 'SECRET-CERTIFICATE-9876543210'
        $fakeSession = [pscustomobject]@{
            port        = 47823
            pid         = 4242
            apiKey      = $secretApiKey
            certificate = $secretCertificate
            unknown     = 'PRIVATE-UNKNOWN-FIELD'
        }

        $snapshot = New-MasReadySnapshot -Session $fakeSession -ReadyFilePath (Join-Path ([IO.Path]::GetTempPath()) 'ready.json') `
            -HoldMinutes 5 -PortProbe $true
        $json = $snapshot | ConvertTo-Json -Depth 4

        $snapshot.Port | Should Be 47823
        $snapshot.Pid | Should Be 4242
        $json | Should Not Match ([regex]::Escape($secretApiKey))
        $json | Should Not Match ([regex]::Escape($secretCertificate))
        $json | Should Not Match 'PRIVATE-UNKNOWN-FIELD'
        $json | Should Not Match '(?i)apikey|certificate'
    }

    It '清理审计日志不包含 apiKey/certificate 文本或已知密钥值' {
        $sandbox = New-CleanupSandbox
        $standIn = $null
        try {
            $secretApiKey = 'SECRET-API-KEY-0123456789'
            $secretCertificate = 'SECRET-CERTIFICATE-9876543210'
            $standIn = Start-CleanupStandIn
            Start-Sleep -Milliseconds 300
            $snapshot = Get-MasProcessSnapshot -Process $standIn
            $runId = New-CleanupRunId
            $owner = New-CleanupOwner -ProcessId $snapshot.Pid -StartTimeUtc $snapshot.StartTimeUtc.ToString('o') `
                -ExecutablePath $snapshot.ExecutablePath -WindowsSessionId $snapshot.WindowsSessionId `
                -RunId $runId -ProcessName 'powershell'

            $null = Invoke-MasOwnedCleanup -OwnerRecord $owner.Record -RunId $runId `
                -CleanupMode ReportOnly -AuditPath $sandbox.Audit -ExpectedProcessName 'powershell' `
                -Secrets @($secretApiKey, $secretCertificate)
            $null = Write-MasAuditEvent -AuditPath $sandbox.Audit -Event 'cleanup_test' `
                -Data ([pscustomobject]@{ apiKey = $secretApiKey; certificate = $secretCertificate }) `
                -Secrets @($secretApiKey, $secretCertificate)

            $auditText = [IO.File]::ReadAllText($sandbox.Audit)
            ($auditText.Length -gt 0) | Should Be $true
            $auditText | Should Not Match ([regex]::Escape($secretApiKey))
            $auditText | Should Not Match ([regex]::Escape($secretCertificate))
            $auditText | Should Not Match '(?i)apikey|certificate'
        }
        finally {
            Stop-CleanupStandIn $standIn
            Remove-CleanupSandbox $sandbox
        }
    }

    It '脱敏函数替换已知密钥值与 apiKey/certificate 字段' {
        $text = 'apiKey=DO_NOT_LOG_THIS; certificate=DO_NOT_LOG_THIS_EITHER; Authorization: Bearer PRIVATE'
        $safe = Protect-MasSecretText -Text $text -Secrets @('DO_NOT_LOG_THIS', 'DO_NOT_LOG_THIS_EITHER')
        $safe | Should Not Match 'DO_NOT_LOG_THIS'
        $safe | Should Match '\[REDACTED'
    }
}

Describe '脚本入口的回归边界' {

    It '清理决策函数存在，且不再按 sessionDetails 的 PID 直接强杀' {
        (Get-Command Test-MasOwnedProcess -ErrorAction SilentlyContinue) | Should Not Be $null
        (Get-Command Invoke-MasOwnedCleanup -ErrorAction SilentlyContinue) | Should Not Be $null

        $text = [IO.File]::ReadAllText($script:CleanupScriptPath)
        $text | Should Match 'Test-MasOwnedProcess'
        $text | Should Match 'SKIPPED_IDENTITY_MISMATCH'
        $text | Should Match 'INVARIANT'
        # 旧实现的循环：foreach ($id in @($ready.Pid, $process.Id)) { ... Stop-Process -Force }
        $text | Should Not Match '(?s)foreach\s*\(\s*\$id\s+in\s+@\(\$ready\.Pid'
    }

    It '脚本不把 apiKey/certificate 赋值进输出对象或就绪文件' {
        $text = [IO.File]::ReadAllText($script:CleanupScriptPath)
        $text | Should Not Match '(?i)\bApiKey\s*='
        $text | Should Not Match '(?i)\bCertificate\s*='
        $text | Should Not Match '\$session\.apiKey'
        $text | Should Not Match '\$session\.certificate'
    }
}

# 父链归属只比较字符串形状，路径全是合成的。根目录取自本测试文件所在盘，
# 不在源码里写死盘符——仓库有"盘符硬编码"卫生门禁，写死会把自家改动算成新违规（S3-T7 实测踩过）。
$script:MasFixtureRoot = [System.IO.Path]::GetPathRoot($PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($script:MasFixtureRoot)) { $script:MasFixtureRoot = [System.IO.Path]::DirectorySeparatorChar + [System.IO.Path]::DirectorySeparatorChar + 'fixture' + [System.IO.Path]::DirectorySeparatorChar }

function New-MasIdentityForTest {
    <#
    .SYNOPSIS
    构造一份合成进程身份（不启动任何真实进程），用于父链归属判定。
    #>
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [string]$ProcessName = 'MATLAB',
        [datetime]$StartTimeUtc = ([datetime]::UtcNow),
        [string]$ExecutablePath = ($script:MasFixtureRoot + 'matlab\bin\win64\MATLAB.exe'),
        [int]$WindowsSessionId = 1,
        [bool]$HasExited = $false
    )
    return [pscustomobject][ordered]@{
        Pid              = $ProcessId
        ProcessName      = $ProcessName
        StartTimeUtc     = $StartTimeUtc.ToUniversalTime()
        ExecutablePath   = $ExecutablePath
        WindowsSessionId = $WindowsSessionId
        HasExited        = $HasExited
    }
}

Describe '会话运行时归属：父链允许存根，但每一跳都必须自证' {
    <#
    .SYNOPSIS
    Windows 上 bin\matlab.exe 只是一个启动器存根：它派生 bin\win64\MATLAB.exe 后立即退出，
    后者再派生会话文件里记录的引擎进程。于是会话运行时永远是启动器的**孙进程**。
    旧实现只接受"启动器的直接子进程"，因此真实环境里恒判 not owned，
    holder 随即把 MATLAB 丢成孤儿并提前退出（2026-10-26 S3 实测：pid 51072→15392→42956）。
    修复必须是有界的：允许父链在有限跳数内到达启动器，但每一跳仍要自证是 MATLAB、
    在本次运行时间窗内启动、且与启动器同一 Windows 会话，否则一律失败关闭。
    #>

    $runStarted = [datetime]::UtcNow.AddSeconds(-30)
    $stubExe = $script:MasFixtureRoot + 'matlab\bin\matlab.exe'
    $realExe = $script:MasFixtureRoot + 'matlab\bin\win64\MATLAB.exe'

    It '启动器是存根、会话运行时是其孙进程时判定 owned' {
        $launcher = [pscustomobject][ordered]@{
            pid = 51072; processName = 'matlab'; executablePath = $stubExe; windowsSessionId = 1
        }
        $stubChild = New-MasIdentityForTest -ProcessId 15392 -StartTimeUtc $runStarted.AddSeconds(1) `
            -ExecutablePath $realExe
        $decision = Test-MasSessionRuntimeOwnership -Candidate (New-MasIdentityForTest -ProcessId 42956 `
            -StartTimeUtc $runStarted.AddSeconds(11) -ExecutablePath $realExe) `
            -Ancestors @($stubChild, (New-MasIdentityForTest -ProcessId 51072 -ProcessName 'matlab' `
                -StartTimeUtc $runStarted -ExecutablePath $stubExe)) `
            -Launcher $launcher -RunStartedAtUtc $runStarted -MatlabExecutablePath $realExe

        $decision.owned | Should Be $true
        $decision.reason | Should Be ALLOW
        $decision.launcherHopPid | Should Be 51072
    }

    It '会话运行时是启动器直接子进程时仍然判定 owned（不回归旧行为）' {
        $launcher = [pscustomobject][ordered]@{
            pid = 51072; processName = 'matlab'; executablePath = $stubExe; windowsSessionId = 1
        }
        $decision = Test-MasSessionRuntimeOwnership -Candidate (New-MasIdentityForTest -ProcessId 42956 `
            -StartTimeUtc $runStarted.AddSeconds(5) -ExecutablePath $realExe) `
            -Ancestors @(New-MasIdentityForTest -ProcessId 51072 -ProcessName 'matlab' `
                -StartTimeUtc $runStarted -ExecutablePath $stubExe) `
            -Launcher $launcher -RunStartedAtUtc $runStarted -MatlabExecutablePath $realExe

        $decision.owned | Should Be $true
        $decision.hops | Should Be 1
    }

    It '启动器存根已退出时仍可凭"记录在案的启动器 PID"收尾（真实树形状）' {
        <#
        真实形状（2026-10-26 实测）：启动器存根 51072 派生 bin\win64\MATLAB.exe 15392 后立即退出，
        15392 再派生引擎 42956。父链最后一跳只能观测到 PID（进程已不在），
        归属根据是"这个 PID 正是启动时写进所有者文件的那个"，不是它自身的身份。
        #>
        $launcher = [pscustomobject][ordered]@{
            pid = 51072; processName = 'matlab'; executablePath = $stubExe; windowsSessionId = 1
        }
        $exitedStubHop = [pscustomobject][ordered]@{
            Pid = 51072; ProcessName = $null; StartTimeUtc = $null
            ExecutablePath = $null; WindowsSessionId = $null; HasExited = $true
        }
        $decision = Test-MasSessionRuntimeOwnership -Candidate (New-MasIdentityForTest -ProcessId 42956 `
            -StartTimeUtc $runStarted.AddSeconds(11) -ExecutablePath $realExe) `
            -Ancestors @(
                (New-MasIdentityForTest -ProcessId 15392 -StartTimeUtc $runStarted.AddSeconds(1) -ExecutablePath $realExe),
                $exitedStubHop
            ) `
            -Launcher $launcher -RunStartedAtUtc $runStarted -MatlabExecutablePath @($stubExe, $realExe)

        $decision.owned | Should Be $true
        $decision.reason | Should Be ALLOW
        $decision.hops | Should Be 2
    }

    It '父链不含本次启动器时不判定 owned（不把别人的 MATLAB 记进归属）' {
        $launcher = [pscustomobject][ordered]@{
            pid = 51072; processName = 'matlab'; executablePath = $stubExe; windowsSessionId = 1
        }
        $decision = Test-MasSessionRuntimeOwnership -Candidate (New-MasIdentityForTest -ProcessId 42956 `
            -StartTimeUtc $runStarted.AddSeconds(5) -ExecutablePath $realExe) `
            -Ancestors @(
                (New-MasIdentityForTest -ProcessId 99998 -StartTimeUtc $runStarted.AddSeconds(4)),
                (New-MasIdentityForTest -ProcessId 99999 -StartTimeUtc $runStarted.AddSeconds(3))
            ) `
            -Launcher $launcher -RunStartedAtUtc $runStarted -MatlabExecutablePath $realExe

        $decision.owned | Should Be $false
        $decision.reason | Should Be SKIPPED_LAUNCHER_NOT_IN_CHAIN
    }

    It '中间跳不是 MATLAB 进程时不判定 owned，即使更上层就是启动器' {
        $launcher = [pscustomobject][ordered]@{
            pid = 51072; processName = 'matlab'; executablePath = $stubExe; windowsSessionId = 1
        }
        $decision = Test-MasSessionRuntimeOwnership -Candidate (New-MasIdentityForTest -ProcessId 42956 `
            -StartTimeUtc $runStarted.AddSeconds(5) -ExecutablePath $realExe) `
            -Ancestors @(
                (New-MasIdentityForTest -ProcessId 77777 -ProcessName 'notepad' `
                    -StartTimeUtc $runStarted.AddSeconds(4) -ExecutablePath 'C:\Windows\System32\notepad.exe'),
                (New-MasIdentityForTest -ProcessId 51072 -ProcessName 'matlab' `
                    -StartTimeUtc $runStarted -ExecutablePath $stubExe)
            ) `
            -Launcher $launcher -RunStartedAtUtc $runStarted -MatlabExecutablePath $realExe

        $decision.owned | Should Be $false
        $decision.reason | Should Be SKIPPED_ANCESTOR_NOT_MATLAB
    }

    It '中间跳早于本次运行启动（PID 复用）时不判定 owned' {
        $launcher = [pscustomobject][ordered]@{
            pid = 51072; processName = 'matlab'; executablePath = $stubExe; windowsSessionId = 1
        }
        $decision = Test-MasSessionRuntimeOwnership -Candidate (New-MasIdentityForTest -ProcessId 42956 `
            -StartTimeUtc $runStarted.AddSeconds(5) -ExecutablePath $realExe) `
            -Ancestors @(
                (New-MasIdentityForTest -ProcessId 15392 -StartTimeUtc $runStarted.AddMinutes(-90) `
                    -ExecutablePath $realExe),
                (New-MasIdentityForTest -ProcessId 51072 -ProcessName 'matlab' `
                    -StartTimeUtc $runStarted -ExecutablePath $stubExe)
            ) `
            -Launcher $launcher -RunStartedAtUtc $runStarted -MatlabExecutablePath $realExe

        $decision.owned | Should Be $false
        $decision.reason | Should Be SKIPPED_ANCESTOR_UNTRUSTED
    }

    It '启动器出现在超出有界跳数之后时不判定 owned' {
        $launcher = [pscustomobject][ordered]@{
            pid = 51072; processName = 'matlab'; executablePath = $stubExe; windowsSessionId = 1
        }
        $decision = Test-MasSessionRuntimeOwnership -Candidate (New-MasIdentityForTest -ProcessId 42956 `
            -StartTimeUtc $runStarted.AddSeconds(5) -ExecutablePath $realExe) `
            -Ancestors @(
                (New-MasIdentityForTest -ProcessId 1 -StartTimeUtc $runStarted.AddSeconds(4)),
                (New-MasIdentityForTest -ProcessId 2 -StartTimeUtc $runStarted.AddSeconds(3)),
                (New-MasIdentityForTest -ProcessId 51072 -ProcessName 'matlab' `
                    -StartTimeUtc $runStarted -ExecutablePath $stubExe)
            ) `
            -Launcher $launcher -RunStartedAtUtc $runStarted -MatlabExecutablePath $realExe -MaxAncestorDepth 2

        $decision.owned | Should Be $false
        $decision.reason | Should Be SKIPPED_LAUNCHER_NOT_IN_CHAIN
    }

    It '候选自身可执行文件路径与解析出的 MATLAB 路径不符时不判定 owned' {
        $launcher = [pscustomobject][ordered]@{
            pid = 51072; processName = 'matlab'; executablePath = $stubExe; windowsSessionId = 1
        }
        $decision = Test-MasSessionRuntimeOwnership -Candidate (New-MasIdentityForTest -ProcessId 42956 `
            -StartTimeUtc $runStarted.AddSeconds(5) -ExecutablePath ($script:MasFixtureRoot + 'other-tool\MATLAB.exe')) `
            -Ancestors @(New-MasIdentityForTest -ProcessId 51072 -ProcessName 'matlab' `
                -StartTimeUtc $runStarted -ExecutablePath $stubExe) `
            -Launcher $launcher -RunStartedAtUtc $runStarted -MatlabExecutablePath $realExe

        $decision.owned | Should Be $false
        $decision.reason | Should Be SKIPPED_IDENTITY_MISMATCH
    }

    It '候选与启动器不在同一 Windows 会话时不判定 owned' {
        $launcher = [pscustomobject][ordered]@{
            pid = 51072; processName = 'matlab'; executablePath = $stubExe; windowsSessionId = 1
        }
        $decision = Test-MasSessionRuntimeOwnership -Candidate (New-MasIdentityForTest -ProcessId 42956 `
            -StartTimeUtc $runStarted.AddSeconds(5) -ExecutablePath $realExe -WindowsSessionId 2) `
            -Ancestors @(New-MasIdentityForTest -ProcessId 51072 -ProcessName 'matlab' `
                -StartTimeUtc $runStarted -ExecutablePath $stubExe) `
            -Launcher $launcher -RunStartedAtUtc $runStarted -MatlabExecutablePath $realExe

        $decision.owned | Should Be $false
        $decision.reason | Should Be SKIPPED_IDENTITY_MISMATCH
    }

    It '候选进程已退出时不判定 owned 且不是错误' {
        $launcher = [pscustomobject][ordered]@{
            pid = 51072; processName = 'matlab'; executablePath = $stubExe; windowsSessionId = 1
        }
        $decision = Test-MasSessionRuntimeOwnership -Candidate (New-MasIdentityForTest -ProcessId 42956 `
            -StartTimeUtc $runStarted.AddSeconds(5) -ExecutablePath $realExe -HasExited $true) `
            -Ancestors @() -Launcher $launcher -RunStartedAtUtc $runStarted -MatlabExecutablePath $realExe

        $decision.owned | Should Be $false
        $decision.reason | Should Be SKIPPED_CANDIDATE_MISSING
    }

    It '对真实存活进程上溯父链不抛错且返回数组（本机 PS 5.1 的 @($list) 会抛 ArgumentException）' {
        { Get-MasAncestorChain -Id $PID -MaxDepth 3 } | Should Not Throw
        $chain = @(Get-MasAncestorChain -Id $PID -MaxDepth 3)
        $chain -is [array] | Should Be $true
        foreach ($hop in $chain) { $hop.Pid | Should Not Be $null }
    }

    It '主流程改用有界父链判定，不再只认直接父子' {
        (Get-Command Test-MasSessionRuntimeOwnership -ErrorAction SilentlyContinue) | Should Not Be $null
        (Get-Command Get-MasAncestorChain -ErrorAction SilentlyContinue) | Should Not Be $null
        $text = [IO.File]::ReadAllText($script:CleanupScriptPath)
        $text | Should Match 'Test-MasSessionRuntimeOwnership'
        $text | Should Match 'Get-MasAncestorChain'
        $text | Should Match 'SKIPPED_LAUNCHER_NOT_IN_CHAIN'
    }
}
