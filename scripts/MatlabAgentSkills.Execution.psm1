#Requires -Version 5.1
<#
.SYNOPSIS
MATLAB 执行可靠性：进程超时控制、错误分类与有限次重试。

.DESCRIPTION
解决的问题：
1. 旧版 `Invoke-MatlabBatch.ps1` 使用 Start-Process -Wait，MATLAB 启动挂起时会无限等待；
2. 失败只有“退出码非 0”，无法区分许可证、环境、仿真、代码生成、数值验收等根因；
3. 没有重试策略，或重试完全靠人。

本模块提供：
- `Invoke-MatlabBatchProcess`：带超时、阶段日志、进程树终止、日志尾部摘要；
- `Get-MatlabErrorClassification`：把日志映射到 8 类错误，并判定是否可恢复；
- `Invoke-WithRetry`：有限次重试；非幂等操作必须显式批准才允许重试。
#>

$script:ErrorClassTable = @(
    @{
        Class      = "LICENSE_ERROR"
        Recoverable = $false
        Patterns   = @(
            'License checkout failed',
            'License Manager Error',
            'licensing error',
            'No licenses? (are )?available',
            'Cannot (connect to|find) license',
            'license.{0,20}expired',
            'LICMGR',
            'MATLAB:license',
            'License server',
            '\bError -(4|15|18|95|96)\b'
        )
    },
    @{
        Class      = "MCP_CONNECTION_ERROR"
        Recoverable = $true
        Patterns   = @(
            'ECONNREFUSED',
            'ECONNRESET',
            'Failed to (initialize|connect) MCP',
            'MCP (handshake|initialize|connection)',
            'mcp server (did not|failed)',
            'sessionDetails\.json',
            'matlab-session-mode',
            'apiKey',
            'x-api-key',
            'Connection refused',
            'TLS handshake',
            'HTTP 40[13]'
        )
    },
    @{
        Class      = "ENVIRONMENT_ERROR"
        Recoverable = $false
        Patterns   = @(
            'MATLAB executable not found',
            'MATLAB 可执行文件未找到',
            'No supported compiler or SDK was found',
            'No supported compiler',
            'mex -setup',
            'is not installed',
            '未安装',
            'Unrecognized function or variable ''(codegen|coder|sim|slbuild|ver|license|mex|masacc)''',
            'Undefined function ''(codegen|coder|sim|slbuild|ver|license)''',
            'not found on PATH',
            'Unsupported MATLAB release'
        )
    },
    @{
        Class      = "VALIDATION_ERROR"
        Recoverable = $false
        Patterns   = @(
            'Assertion failed',
            'smoke check failed',
            'deviates? from',
            'deviation',
            'tolerance',
            'golden',
            'MISMATCH',
            'expected .{0,40} got',
            '数值不一致',
            '验收未通过'
        )
    },
    @{
        Class      = "SIMULATION_ERROR"
        Recoverable = $false
        Patterns   = @(
            'Simulink\.SimulationError',
            'SimulationInput',
            'Simulation (was )?stopped',
            'Derivative of state',
            'Solver (failed|error)',
            'Error due to multiple causes',
            'Cannot simulate'
        )
    },
    @{
        Class      = "CODEGEN_ERROR"
        Recoverable = $false
        Patterns   = @(
            'Error using (codegen|slbuild|rtwbuild)',
            'Error\(s\) encountered while building',
            'Build process completed with errors',
            'Target language',
            'coder\.config',
            '\bcodegen\b',
            '\bslbuild\b',
            '\brtwbuild\b',
            'rtwtypes\.h'
        )
    },
    @{
        Class      = "MATLAB_RUNTIME_ERROR"
        Recoverable = $false
        Patterns   = @(
            'Error using ',
            'Error in ',
            'Undefined function',
            'Index exceeds',
            'Matrix dimensions must agree',
            'Too many (input|output) arguments',
            'Not enough input arguments',
            'MATLAB:'
        )
    }
)

$script:RecoverableErrorClasses = @("TIMEOUT", "MCP_CONNECTION_ERROR")

function Get-RecoverableErrorClasses {
    <# .SYNOPSIS 返回允许自动重试的错误类别。 #>
    return @($script:RecoverableErrorClasses)
}

function Test-ErrorClassRecoverable {
    <# .SYNOPSIS 判断错误类别是否允许自动重试。 #>
    param([string]$ErrorClass)
    return ($script:RecoverableErrorClasses -contains $ErrorClass)
}

function Get-MatlabErrorClassification {
    <#
    .SYNOPSIS
    把 MATLAB / MCP 的失败信息归类为 8 类错误之一。

.DESCRIPTION
    优先级（先匹配先返回）：TIMEOUT → LICENSE → MCP_CONNECTION → ENVIRONMENT →
    VALIDATION → SIMULATION → CODEGEN → MATLAB_RUNTIME。
    未命中但退出码非 0 时兜底为 MATLAB_RUNTIME_ERROR；退出码为 0 且无匹配时返回 $null。
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Text = "",
        [Nullable[int]]$ExitCode = $null,
        [switch]$TimedOut
    )

    if ($TimedOut) {
        return [pscustomobject][ordered]@{
            Class       = "TIMEOUT"
            Recoverable = $true
            Evidence    = "进程超过超时阈值被终止"
            Reason      = "执行超时（TIMEOUT），未得到任何结果"
        }
    }

    $normalized = "$Text"
    foreach ($entry in $script:ErrorClassTable) {
        foreach ($pattern in $entry.Patterns) {
            if ($normalized -match $pattern) {
                $match = [regex]::Match($normalized, $pattern, "IgnoreCase")
                $evidence = ""
                if ($match.Success) {
                    $start = [Math]::Max(0, $match.Index - 60)
                    $length = [Math]::Min(220, $normalized.Length - $start)
                    $evidence = ($normalized.Substring($start, $length) -replace "\s+", " ").Trim()
                }
                return [pscustomobject][ordered]@{
                    Class       = $entry.Class
                    Recoverable = [bool]$entry.Recoverable
                    Evidence    = $evidence
                    Reason      = "匹配模式 '$pattern' → $($entry.Class)"
                }
            }
        }
    }

    if ($null -ne $ExitCode -and [int]$ExitCode -ne 0) {
        return [pscustomobject][ordered]@{
            Class       = "MATLAB_RUNTIME_ERROR"
            Recoverable = $false
            Evidence    = ""
            Reason      = "退出码 $ExitCode，未匹配到更具体的错误类别"
        }
    }

    return $null
}

function Get-LogTailText {
    <# .SYNOPSIS 读取文本文件尾部若干行，用于错误诊断。 #>
    param(
        [string]$Path,
        [int]$Lines = 40
    )
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return "" }
    try {
        return ((Get-Content -LiteralPath $Path -Tail $Lines -ErrorAction Stop) -join "`n")
    }
    catch {
        return ""
    }
}

function Stop-ProcessTree {
    <# .SYNOPSIS 终止进程及其子进程（MATLAB 会派生多个子进程）。 #>
    param([Parameter(Mandatory)][int]$ProcessId)

    if ($IsWindows -ne $false) {
        $taskkill = Get-Command taskkill.exe -ErrorAction SilentlyContinue
        if ($taskkill) {
            & $taskkill.Source /PID $ProcessId /T /F 2>&1 | Out-Null
            return
        }
    }
    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
    }
    catch {
        # 进程可能已退出，忽略。
    }
}

function Write-StageLog {
    <# .SYNOPSIS 追加一条阶段诊断记录。 #>
    param(
        [string]$Path,
        [Parameter(Mandatory)][string]$Stage,
        [string]$Detail = ""
    )
    if (-not $Path) { return }
    $line = "{0} [{1}] {2}" -f (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss.fff"), $Stage, $Detail
    try {
        Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
    }
    catch {
        # 阶段日志失败不应影响主流程。
    }
}

function Format-ProcessArgument {
    <# .SYNOPSIS 把单个参数按 Windows 命令行规则加引号。 #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Argument)
    if ($Argument -eq "") { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }
    return '"' + ($Argument -replace '"', '\"') + '"'
}

function Invoke-MatlabBatchProcess {
    <#
    .SYNOPSIS
    启动 MATLAB 批处理进程，带超时、阶段日志与错误分类。

.DESCRIPTION
    与旧实现的差异：
    - 不再使用 Start-Process -Wait，改为 WaitForExit(timeout)，超时后终止整个进程树；
    - 不用 Start-Process 启动：Windows PowerShell 5.1 在环境变量存在大小写重复键
      （例如 HTTPS_PROXY 与 https_proxy 同时存在）时会抛“字典中的关键字重复”，
      改用 ProcessStartInfo 直接启动可绕过该缺陷；
    - 输出经异步流写入日志文件，避免管道缓冲导致超时后读不到日志；
    - 记录 started/finished/exitCode/timedOut/errorClass，供验收报告直接引用。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MatlabPath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [int]$TimeoutSeconds = 1800,
        [string]$StdoutPath,
        [string]$StderrPath,
        [string]$StageLogPath,
        [string]$Label = "matlab"
    )

    if ($TimeoutSeconds -lt 1) { throw "TimeoutSeconds 必须 >= 1，否则无法区分挂起与正常结束。" }
    if (-not (Test-Path -LiteralPath $MatlabPath)) { throw "MATLAB 可执行文件不存在: $MatlabPath" }
    if (-not (Test-Path -LiteralPath $WorkingDirectory)) { throw "工作目录不存在: $WorkingDirectory" }

    if (-not $StdoutPath) {
        $StdoutPath = Join-Path $WorkingDirectory "artifacts\logs\$Label.stdout.log"
    }
    if (-not $StderrPath) {
        $StderrPath = Join-Path $WorkingDirectory "artifacts\logs\$Label.stderr.log"
    }
    # 阶段日志是超时排查的主要证据，不能因为调用方没传就静默不写。
    if (-not $StageLogPath) {
        $StageLogPath = Join-Path $WorkingDirectory "artifacts\logs\$Label.stages.log"
    }
    foreach ($path in @($StdoutPath, $StderrPath, $StageLogPath)) {
        $dir = Split-Path -Parent $path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
    }

    $argumentText = ($ArgumentList | ForEach-Object { Format-ProcessArgument -Argument $_ }) -join ' '
    $commandText = "$MatlabPath $argumentText"
    Write-StageLog -Path $StageLogPath -Stage "launch" -Detail $commandText

    $startedAt = Get-Date
    $timedOut = $false
    $exitCode = $null

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $MatlabPath
    $psi.Arguments = $argumentText
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    $stdoutStream = $null
    $stderrStream = $null
    try {
        $stdoutStream = New-Object System.IO.FileStream($StdoutPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        $stderrStream = New-Object System.IO.FileStream($StderrPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    }
    catch {
        $launchError = "无法创建日志文件: $($_.Exception.Message)"
        Write-StageLog -Path $StageLogPath -Stage "launch-failed" -Detail $launchError
        $finishedAt = Get-Date
        return [pscustomobject][ordered]@{
            Label            = $Label
            Command          = $commandText
            WorkingDirectory = $WorkingDirectory
            StartedAt        = $startedAt.ToString("o")
            FinishedAt       = $finishedAt.ToString("o")
            DurationSeconds  = [math]::Round(($finishedAt - $startedAt).TotalSeconds, 3)
            ExitCode         = -1
            TimedOut         = $false
            StdoutPath       = $StdoutPath
            StderrPath       = $StderrPath
            StageLogPath     = $StageLogPath
            ErrorClass       = "ENVIRONMENT_ERROR"
            ErrorReason      = $launchError
            LogTail          = ""
            LaunchFailed     = $true
        }
    }

    $stdoutTask = $null
    $stderrTask = $null
    try {
        $process.Start() | Out-Null
        # 空 stdin，避免 MATLAB 等待交互输入。
        try { $process.StandardInput.Close() } catch { }
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutStream)
        $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrStream)
    }
    catch {
        $launchError = $_.Exception.Message
        Write-StageLog -Path $StageLogPath -Stage "launch-failed" -Detail $launchError
        $finishedAt = Get-Date
        foreach ($stream in @($stdoutStream, $stderrStream)) {
            try { if ($stream) { $stream.Dispose() } } catch { }
        }
        $classification = Get-MatlabErrorClassification -Text $launchError -ExitCode -1
        return [pscustomobject][ordered]@{
            Label            = $Label
            Command          = $commandText
            WorkingDirectory = $WorkingDirectory
            StartedAt        = $startedAt.ToString("o")
            FinishedAt       = $finishedAt.ToString("o")
            DurationSeconds  = [math]::Round(($finishedAt - $startedAt).TotalSeconds, 3)
            ExitCode         = -1
            TimedOut         = $false
            StdoutPath       = $StdoutPath
            StderrPath       = $StderrPath
            StageLogPath     = $StageLogPath
            ErrorClass       = if ($classification) { $classification.Class } else { "ENVIRONMENT_ERROR" }
            ErrorReason      = $launchError
            LogTail          = ""
            LaunchFailed     = $true
        }
    }

    Write-StageLog -Path $StageLogPath -Stage "running" -Detail "pid=$($process.Id) timeout=${TimeoutSeconds}s"

    $timeoutMs = [int]([Math]::Min([double]$TimeoutSeconds * 1000, [double][int]::MaxValue))
    $exited = $process.WaitForExit($timeoutMs)

    if (-not $exited) {
        $timedOut = $true
        Write-StageLog -Path $StageLogPath -Stage "timeout" -Detail "超过 ${TimeoutSeconds}s，终止进程树"
        Stop-ProcessTree -ProcessId $process.Id
        $process.WaitForExit(10000) | Out-Null
    }

    $finishedAt = Get-Date
    if (-not $timedOut) {
        try { $exitCode = $process.ExitCode } catch { $exitCode = $null }
        Write-StageLog -Path $StageLogPath -Stage "exited" -Detail "exitCode=$exitCode"
    }
    else {
        $exitCode = -1
    }

    foreach ($task in @($stdoutTask, $stderrTask)) {
        if ($task) { try { $task.Wait(5000) | Out-Null } catch { } }
    }
    foreach ($stream in @($stdoutStream, $stderrStream)) {
        try { if ($stream) { $stream.Flush(); $stream.Dispose() } } catch { }
    }
    try { $process.Dispose() } catch { }

    $stdoutTail = Get-LogTailText -Path $StdoutPath -Lines 60
    $stderrTail = Get-LogTailText -Path $StderrPath -Lines 40
    $combinedText = ($stdoutTail + "`n" + $stderrTail)

    $classification = Get-MatlabErrorClassification -Text $combinedText -ExitCode $exitCode -TimedOut:$timedOut
    Write-StageLog -Path $StageLogPath -Stage "classified" -Detail $(if ($classification) { $classification.Class } else { "none" })

    return [pscustomobject][ordered]@{
        Label           = $Label
        Command         = $commandText
        WorkingDirectory = $WorkingDirectory
        StartedAt       = $startedAt.ToString("o")
        FinishedAt      = $finishedAt.ToString("o")
        DurationSeconds = [math]::Round(($finishedAt - $startedAt).TotalSeconds, 3)
        ExitCode        = $exitCode
        TimedOut        = $timedOut
        StdoutPath      = $StdoutPath
        StderrPath      = $StderrPath
        StageLogPath    = $StageLogPath
        ErrorClass      = if ($classification) { $classification.Class } else { $null }
        ErrorReason     = if ($classification) { $classification.Reason } else { $null }
        LogTail         = $combinedText.Trim()
        LaunchFailed    = $false
    }
}

function Invoke-WithRetry {
    <#
    .SYNOPSIS
    有限次重试封装：只对可恢复错误重试，非幂等操作需显式批准。

.DESCRIPTION
    Action 需返回一个对象，至少包含 `Succeeded`（bool）；可选 `ErrorClass`、`Reason`、`Value`。
    Action 抛异常时按异常消息分类。
    参数约束：MaxAttempts 被限制在 1..5，杜绝无限循环。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][scriptblock]$Action,
        [int]$MaxAttempts = 2,
        [int]$DelaySeconds = 2,
        [int]$MaxDelaySeconds = 15,
        [bool]$Idempotent = $true,
        [switch]$Approved,
        [scriptblock]$Sleep = { param([int]$s) Start-Sleep -Seconds $s }
    )

    if ($MaxAttempts -lt 1) { $MaxAttempts = 1 }
    if ($MaxAttempts -gt 5) { $MaxAttempts = 5 }

    $attempts = New-Object System.Collections.Generic.List[object]
    $blockedReason = $null
    $lastValue = $null
    $lastClass = $null
    $lastReason = $null
    $succeeded = $false

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $attemptStarted = Get-Date
        $attemptSucceeded = $false
        $attemptClass = $null
        $attemptReason = $null

        try {
            $lastValue = & $Action
            if ($lastValue -is [bool]) {
                $attemptSucceeded = $lastValue
            }
            elseif ($null -ne $lastValue -and $lastValue.PSObject.Properties.Name -contains "Succeeded") {
                $attemptSucceeded = [bool]$lastValue.Succeeded
                if ($lastValue.PSObject.Properties.Name -contains "ErrorClass") { $attemptClass = $lastValue.ErrorClass }
                if ($lastValue.PSObject.Properties.Name -contains "Reason") { $attemptReason = $lastValue.Reason }
            }
            else {
                $attemptSucceeded = $true
            }
        }
        catch {
            $attemptSucceeded = $false
            $classified = Get-MatlabErrorClassification -Text $_.Exception.Message
            if ($classified) {
                $attemptClass = $classified.Class
                $attemptReason = $classified.Reason
            }
            else {
                $attemptClass = "MATLAB_RUNTIME_ERROR"
                $attemptReason = $_.Exception.Message
            }
        }

        $attemptFinished = Get-Date
        $attempts.Add([pscustomobject][ordered]@{
            Number          = $attempt
            Succeeded       = $attemptSucceeded
            ErrorClass      = $attemptClass
            Reason          = $attemptReason
            StartedAt       = $attemptStarted.ToString("o")
            FinishedAt      = $attemptFinished.ToString("o")
            DurationSeconds = [math]::Round(($attemptFinished - $attemptStarted).TotalSeconds, 3)
        })

        $lastClass = $attemptClass
        $lastReason = $attemptReason

        if ($attemptSucceeded) {
            $succeeded = $true
            break
        }

        if ($attempt -ge $MaxAttempts) {
            $blockedReason = "已达到最大尝试次数 $MaxAttempts"
            break
        }

        if (-not $Idempotent -and -not $Approved) {
            $blockedReason = "NON_IDEMPOTENT_REQUIRES_APPROVAL：非幂等操作未获批准，不自动重试"
            break
        }

        if ($attemptClass -and -not (Test-ErrorClassRecoverable -ErrorClass $attemptClass)) {
            $blockedReason = "NON_RECOVERABLE:$attemptClass"
            break
        }

        $delay = [Math]::Min($DelaySeconds * $attempt, $MaxDelaySeconds)
        if ($delay -gt 0) { & $Sleep $delay }
    }

    return [pscustomobject][ordered]@{
        Operation     = $Operation
        Succeeded     = $succeeded
        Attempts      = @($attempts.ToArray())
        AttemptCount  = $attempts.Count
        ErrorClass    = $lastClass
        Reason        = $lastReason
        BlockedReason = $blockedReason
        Value         = $lastValue
        Idempotent    = $Idempotent
        Approved      = [bool]$Approved
    }
}

function Resolve-MatlabExecutable {
    <#
    .SYNOPSIS
    解析 matlab 可执行文件路径（显式 > 环境变量 > PATH > 常见安装位置）。
    .OUTPUTS
    路径字符串，未找到时返回 $null（由调用方决定 FAIL 或 SKIP）。
    #>
    [CmdletBinding()]
    param(
        [string]$ExplicitPath,
        [switch]$SkipDriveScan
    )

    if ($ExplicitPath) {
        if (Test-Path -LiteralPath $ExplicitPath) { return (Resolve-Path -LiteralPath $ExplicitPath).Path }
        return $null
    }

    if ($env:MATLAB_EXE -and (Test-Path -LiteralPath $env:MATLAB_EXE)) {
        return (Resolve-Path -LiteralPath $env:MATLAB_EXE).Path
    }

    $command = Get-Command matlab -ErrorAction SilentlyContinue
    if ($command -and $command.Source -and (Test-Path -LiteralPath $command.Source)) {
        return (Resolve-Path -LiteralPath $command.Source).Path
    }

    if ($env:MATLAB_ROOT) {
        $candidate = Join-Path $env:MATLAB_ROOT "bin\matlab.exe"
        if (Test-Path -LiteralPath $candidate) { return (Resolve-Path -LiteralPath $candidate).Path }
        $candidate = Join-Path $env:MATLAB_ROOT "bin\matlab"
        if (Test-Path -LiteralPath $candidate) { return (Resolve-Path -LiteralPath $candidate).Path }
    }

    if ($SkipDriveScan) { return $null }

    $drives = @()
    try { $drives = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Root) } catch { $drives = @() }
    foreach ($drive in $drives) {
        foreach ($relative in @("MATLAB\bin\matlab.exe", "matlab\bin\matlab.exe")) {
            $candidate = Join-Path $drive $relative
            if (Test-Path -LiteralPath $candidate) { return (Resolve-Path -LiteralPath $candidate).Path }
        }
        $programFiles = Join-Path $drive "Program Files\MATLAB"
        if (Test-Path -LiteralPath $programFiles) {
            $release = Get-ChildItem -LiteralPath $programFiles -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 1
            if ($release) {
                $candidate = Join-Path $release.FullName "bin\matlab.exe"
                if (Test-Path -LiteralPath $candidate) { return (Resolve-Path -LiteralPath $candidate).Path }
            }
        }
    }
    return $null
}

function Get-MatlabInstallInfo {
    <#
    .SYNOPSIS
    从 MATLAB 安装目录读取 VersionInfo.xml，得到版本与 release（无需启动 MATLAB）。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ExecutablePath)

    $binDir = Split-Path -Parent $ExecutablePath
    $root = Split-Path -Parent $binDir
    $versionInfoPath = Join-Path $root "VersionInfo.xml"
    $result = [pscustomobject][ordered]@{
        Root          = $root
        VersionInfo   = $versionInfoPath
        Version       = $null
        Release       = $null
        Description   = $null
        Readable      = $false
        Error         = $null
    }

    if (-not (Test-Path -LiteralPath $versionInfoPath)) {
        $result.Error = "未找到 VersionInfo.xml"
        return $result
    }

    try {
        [xml]$xml = Get-Content -Raw -LiteralPath $versionInfoPath
        $result.Version = "$($xml.MathWorks_version_info.version)"
        $result.Release = "$($xml.MathWorks_version_info.release)"
        $result.Description = "$($xml.MathWorks_version_info.description)"
        $result.Readable = $true
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}

function Invoke-ProcessWithTimeout {
    <#
    .SYNOPSIS
    启动任意短进程并带超时，返回 stdout/stderr/exitCode/timedOut。
    .DESCRIPTION
    用于探测 CLI（codex / claude / git 等），避免外部命令挂起拖死整个验收。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = $null,
        [int]$TimeoutSeconds = 15
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

    $quoted = @()
    foreach ($arg in $ArgumentList) {
        if ($arg -match '[\s"]') { $quoted += ('"' + ($arg -replace '"', '\"') + '"') }
        else { $quoted += $arg }
    }
    $psi.Arguments = ($quoted -join ' ')

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    $startedAt = Get-Date
    try {
        $process.Start() | Out-Null
    }
    catch {
        return [pscustomobject][ordered]@{
            FilePath        = $FilePath
            ExitCode        = -1
            TimedOut        = $false
            StandardOutput  = ""
            StandardError   = $_.Exception.Message
            DurationSeconds = 0
            Started         = $false
        }
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $exited = $process.WaitForExit([int]([Math]::Min([double]$TimeoutSeconds * 1000, [double][int]::MaxValue)))
    $timedOut = -not $exited
    if ($timedOut) {
        try { Stop-ProcessTree -ProcessId $process.Id } catch { }
        $process.WaitForExit(5000) | Out-Null
    }

    $stdout = ""
    $stderr = ""
    try { $stdout = $stdoutTask.Result } catch { $stdout = "" }
    try { $stderr = $stderrTask.Result } catch { $stderr = "" }

    $exitCode = $null
    if (-not $timedOut) {
        try { $exitCode = $process.ExitCode } catch { $exitCode = $null }
    }
    else {
        $exitCode = -1
    }

    return [pscustomobject][ordered]@{
        FilePath        = $FilePath
        ExitCode        = $exitCode
        TimedOut        = $timedOut
        StandardOutput  = $stdout
        StandardError   = $stderr
        DurationSeconds = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 3)
        Started         = $true
    }
}

Export-ModuleMember -Function *
