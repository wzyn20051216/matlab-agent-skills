<#
.SYNOPSIS
    MCP 开工前健康检查：几秒内判断 existing 模式的共享会话能不能真的执行代码，
    会话已死时可选自动拉起一个新的，避免客户端在 tools/call 上静默等待超时（120s+）。

.DESCRIPTION
    为什么需要这个脚本

    `--matlab-session-mode=existing` 依赖一个**正在运行**的共享 MATLAB 会话。
    该会话一旦失效（持有时间到、MATLAB 被关、期间又启动过别的 MATLAB 把
    sessionDetails.json 覆写掉），客户端看到的现象都是同一个：

        initialize 成功  →  tools/list 成功  →  tools/call 静默等 120 秒 → 失败

    更糟的是 `sessionDetails.json` 里的 pid 可能是死的、端口可能还在 listen，
    所以"文件存在 + pid 存活 + 端口在听"这三个条件**都不能证明可执行**——
    实测过 pause() 持有会话时端口照样返回 200，但 tools/call 永远不返回。

    因此本脚本只认一个证据：**探针的 mcp.readonly-exec 通过**（真实 tools/call
    返回真实数值）。三个廉价前置条件只用来尽早短路，不用来宣布健康。

.EXAMPLE
    # 只检查，不动任何进程：健康 exit 0，不健康 exit 1（并打印该跑的两条命令）
    .\Ensure-MatlabMcpReady.ps1 -Work .\artifacts\runtime

.EXAMPLE
    # 供程序消费，同时落盘
    .\Ensure-MatlabMcpReady.ps1 -Json -OutputPath .\artifacts\runtime\mcp-ready.json

.OUTPUTS
    [pscustomobject] Status / Pid / Port / Action / Checks / Reasons / NextAction /
    StartCommand / RecheckCommand。不含 apiKey / certificate。

.NOTES
    退出码：0 = 已验证可执行；1 = 不可用（nextAction 给出确切命令）；3 = 只做了廉价检查（SKIP）。

    本脚本**不自己拉起 MATLAB**：受管环境里 Start-Process 启动解释器会被安全策略拦截，
    且持有会话必须是独立长驻进程，脚本活不到那一刻。所以它只判定并给出命令：
    调用方（Agent 的后台任务，或用户）先跑 StartCommand，等 session_ready.json 出现，
    再跑 RecheckCommand。
#>
[CmdletBinding()]
param(
    # 工作目录：会话信号文件与产物落盘处。
    [string]$Work = ".",

    # 自动拉起时的持有分钟数。默认 240。
    [int]$HoldMinutes = 240,

    # 探针 tools/call 的超时。默认 20 秒；失败很快，不会像客户端那样干等 120 秒。
    [int]$ProbeTimeoutSeconds = 20,

    [string]$MatlabPath = "",
    [string]$McpServerName = "matlab-official",
    [switch]$Json,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
$holdScript = Join-Path $scriptRoot 'Start-MatlabSharedSession.ps1'
$probeScript = Join-Path $scriptRoot 'Test-MatlabMcpExistingSession.ps1'

if (-not (Test-Path -LiteralPath $holdScript)) {
    throw "缺少 Start-MatlabSharedSession.ps1：$holdScript"
}
if (-not (Test-Path -LiteralPath $probeScript)) {
    throw "缺少 Test-MatlabMcpExistingSession.ps1：$probeScript"
}

$workDir = [System.IO.Path]::GetFullPath($Work)
if (-not (Test-Path -LiteralPath $workDir)) {
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null
}

$sessionFile = Join-Path $env:APPDATA 'MathWorks\MATLAB MCP Server\v1\sessionDetails.json'

$checks = [ordered]@{
    'session-file'  = 'SKIP'
    'pid-alive'     = 'SKIP'
    'port-listening'= 'SKIP'
    'readonly-exec' = 'SKIP'
}
$reasons = [ordered]@{}
$sessPid = $null
$sessPort = $null
$action = 'none'

function Get-SessionSnapshot {
    <#
        读取会话快照里的 pid / port。这两项是非敏感字段。
        凭据（apiKey / certificate）一律不读、不存、不打印。
    #>
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Exists = $false; Pid = $null; Port = $null }
    }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ Exists = $true; Pid = $null; Port = $null }
    }

    $pidValue = $null
    foreach ($name in @('pid', 'matlabPid', 'processId')) {
        if ($obj.PSObject.Properties.Name -contains $name -and $obj.$name) {
            $pidValue = [int]$obj.$name
            break
        }
    }
    $portValue = $null
    foreach ($name in @('port', 'matlabPort')) {
        if ($obj.PSObject.Properties.Name -contains $name -and $obj.$name) {
            $portValue = [int]$obj.$name
            break
        }
    }
    return [pscustomobject]@{ Exists = $true; Pid = $pidValue; Port = $portValue }
}

function Invoke-ReadonlyProbe {
    <#
        跑官方分级探针，只认 mcp.readonly-exec 的结论。
        返回 @{ Status = 'PASS'|'FAIL'|'SKIP'; Reason = '<verbatim>' }
    #>
    param(
        [string]$ProbePath,
        [string]$ProjectRoot,
        [string]$ServerName,
        [int]$TimeoutSeconds,
        [string]$MatlabPathArg
    )

    $probeArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ProbePath,
        '-McpServerName', $ServerName,
        '-Backend', 'matlab-mcp-existing',
        '-Transport', 'stdio',
        # 显式 existing：auto/new 的冷启动在本机 R2026a 上会挂起，用它们探测毫无意义。
        '-SessionMode', 'existing',
        '-TimeoutSeconds', $TimeoutSeconds,
        '-SkipCodexCli',
        '-ProjectRoot', $ProjectRoot,
        '-Json'
    )
    if ($MatlabPathArg) { $probeArgs += @('-MatlabPath', $MatlabPathArg) }

    $probeJson = Join-Path $ProjectRoot ("mcp-ready-probe-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $probeArgs += @('-OutputPath', $probeJson)

    $out = & powershell @probeArgs 2>&1 | Out-String
    $exit = $LASTEXITCODE

    $verdict = [pscustomobject]@{ Status = 'FAIL'; Reason = "探针退出码 $exit" }
    if (Test-Path -LiteralPath $probeJson) {
        try {
            # 必须显式按 UTF-8 读：Windows PowerShell 5.1 的 Get-Content 默认按 ANSI(GBK)
            # 解码 UTF-8 文件，报告里的中文会变成乱码，ConvertFrom-Json 直接抛"对象无效"。
            $reportRaw = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $probeJson).Path,
                [System.Text.Encoding]::UTF8)
            $report = $reportRaw | ConvertFrom-Json
            $exec = @($report.checks) | Where-Object { $_.id -eq 'mcp.readonly-exec' } | Select-Object -First 1
            if ($exec) {
                $verdict.Status = [string]$exec.status
                $verdict.Reason = [string]$exec.reason
            } else {
                $verdict.Reason = '探针报告里没有 mcp.readonly-exec 这一项'
            }
        } catch {
            $verdict.Reason = "探针报告无法解析：$($_.Exception.Message)"
        }
    } else {
        $verdict.Reason = "探针没有写出报告文件（退出码 $exit）：" + ($out.Trim().Split("`n") | Select-Object -Last 1)
    }
    return $verdict
}

# ---------------------------------------------------------------- 1. 廉价短路

$snapshot = Get-SessionSnapshot -Path $sessionFile
if (-not $snapshot.Exists) {
    $checks['session-file'] = 'FAIL'
    $reasons['session-file'] = "会话文件不存在：$sessionFile"
} else {
    $checks['session-file'] = 'PASS'
    $sessPid = $snapshot.Pid
    $sessPort = $snapshot.Port

    if ($null -eq $sessPid) {
        $checks['pid-alive'] = 'FAIL'
        $reasons['pid-alive'] = '会话文件里没有可用的 pid 字段'
    } else {
        $proc = Get-Process -Id $sessPid -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -match '^(matlab|MATLAB)$') {
            $checks['pid-alive'] = 'PASS'
        } else {
            $checks['pid-alive'] = 'FAIL'
            $reasons['pid-alive'] = "会话记录的 pid $sessPid 不是活着的 MATLAB 进程（这是会话失效最常见的原因）"
        }
    }

    if ($null -eq $sessPort) {
        $checks['port-listening'] = 'FAIL'
        $reasons['port-listening'] = '会话文件里没有可用的 port 字段'
    } else {
        $listener = Get-NetTCPConnection -LocalPort $sessPort -State Listen -ErrorAction SilentlyContinue
        if ($listener) {
            $checks['port-listening'] = 'PASS'
        } else {
            $checks['port-listening'] = 'FAIL'
            $reasons['port-listening'] = "端口 $sessPort 没有监听"
        }
    }
}

$cheapOk = ($checks['session-file'] -eq 'PASS') -and ($checks['pid-alive'] -eq 'PASS') -and ($checks['port-listening'] -eq 'PASS')

# ---------------------------------------------------------------- 2. 真实执行证据

if ($cheapOk) {
    $verdict = Invoke-ReadonlyProbe -ProbePath $probeScript -ProjectRoot $workDir `
        -ServerName $McpServerName -TimeoutSeconds $ProbeTimeoutSeconds -MatlabPathArg $MatlabPath
    $checks['readonly-exec'] = $verdict.Status
    if ($verdict.Reason) { $reasons['readonly-exec'] = $verdict.Reason }
} else {
    # 廉价检查已不通过，跳过真实探测并写明原因，不伪造 PASS。
    $checks['readonly-exec'] = 'SKIP'
    $reasons['readonly-exec'] = '前置检查未通过，未执行真实 tools/call（避免再等一次超时）'
}

$status = if ($checks['readonly-exec'] -eq 'PASS') { 'READY' }
          elseif ($checks['readonly-exec'] -eq 'FAIL') { 'NOT_READY' }
          else { 'NOT_READY' }

# ---------------------------------------------------------------- 3. 不可用时的补救指令

# 说明：这里**刻意不自己拉起 MATLAB**。
# 一是在受管环境里 Start-Process 启动解释器会被安全策略拦截（实测被拒）；
# 二是持有会话必须是一个独立长驻进程，而脚本本身活不到那一刻。
# 因此本脚本只负责判定和给出确切的两条命令，由调用方（Agent 的后台任务 / 用户）
# 在后台执行第一步，再回头跑第二步。

$sessionAlive = ($checks['session-file'] -eq 'PASS') -and
                ($checks['pid-alive'] -eq 'PASS') -and
                ($checks['port-listening'] -eq 'PASS')

$startCommand = 'powershell -ExecutionPolicy Bypass -File "' + $holdScript + '"' +
                ' -HoldMinutes ' + $HoldMinutes +
                ' -Work "' + $workDir + '" -CleanupMode ReportOnly'

$recheckCommand = 'powershell -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"' +
                  ' -Work "' + $workDir + '" -Json'

if ($status -ne 'READY' -and -not $sessionAlive) {
    $action = 'start-shared-session-required'
} elseif ($status -ne 'READY') {
    $action = 'execution-broken-with-live-session'
}

# ---------------------------------------------------------------- 4. 汇报

$nextAction = if ($status -eq 'READY') {
    '可以直接执行 MATLAB MCP 任务。持有会话期间不要再启动任何 MATLAB 进程（会覆写 sessionDetails.json）；结束时用 stop_session.flag 温和关闭。'
} elseif ($action -eq 'start-shared-session-required') {
    '① 在后台启动共享会话：' + $startCommand + '  ② 等它写出 session_ready.json（约 30 s）后重跑本脚本：' + $recheckCommand
} else {
    '会话活着但执行不通（reason 见 checks）。不要盲目重试：先按 readonly-exec 的 reason 处理；若反复出现，用 stop_session.flag 结束旧会话后按 ① 重启。'
}

$result = [pscustomobject]@{
    status        = $status
    pid           = $sessPid
    port          = $sessPort
    action        = $action
    checks        = $checks
    reasons       = $reasons
    nextAction    = $nextAction
    startCommand  = $startCommand
    recheckCommand= $recheckCommand
    sessionFile   = $sessionFile
    workDir       = $workDir
    observedAt    = (Get-Date).ToString('o')
}

if ($OutputPath) {
    $dir = Split-Path -Parent $OutputPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
}

if ($Json) {
    $result | ConvertTo-Json -Depth 6
} else {
    "[$($result.status)] pid=$($result.pid) port=$($result.port) action=$($result.action)"
    foreach ($k in $result.checks.Keys) {
        $reason = if ($result.reasons.Contains($k)) { $result.reasons[$k] } else { '' }
        "  {0,-15} {1,-5} {2}" -f $k, $result.checks[$k], $reason
    }
    "下一步: $($result.nextAction)"
}

switch ($status) {
    'READY' { exit 0 }
    'NOT_READY' { exit 1 }
    default { exit 3 }
}
