#Requires -Version 5.1
<#
.SYNOPSIS
最小 MCP stdio 客户端：启动官方 matlab-mcp-server.exe 并发送 JSON-RPC 2.0 请求。

.DESCRIPTION
为什么不用 HTTP 直连 MATLAB 的共享会话：
实测 R2026a 的 connector 服务在 POST /mcp 上稳定返回 403（无论 x-api-key、
Bearer 还是 apiKey 头），而官方 matlab-mcp-server.exe 用 --matlab-session-mode
=existing/auto 能正常握手。也就是说"官方客户端"才是被支持的集成路径。

协议事实（实测 v0.15.0）：
- 传输：stdio，一行一条 JSON-RPC 消息（newline-delimited JSON）；
- 握手：initialize -> notifications/initialized -> tools/list -> tools/call；
- 工具：check_matlab_code / detect_matlab_toolboxes / evaluate_matlab_code /
  run_matlab_file / run_matlab_test_file；
- 连接 MATLAB 发生在第一次工具调用，而不是 initialize（所以握手快不代表 MATLAB 可用）。

设计约束：
- 读超时必须存在，否则服务端挂起会拖死整个验收；
- 非 JSON 行（日志）要跳过而不是当成响应；
- 进程退出后要立刻返回失败，不能等到超时；
- 所有失败都带 stderr 尾部，便于审计。
#>

function Start-McpStdioServer {
    <#
    .SYNOPSIS
    启动 MCP stdio 服务端进程，返回会话对象。

    .PARAMETER ServerArgumentLine
    传给服务端的参数串。注意不要用 $args 之类的自动变量名保存它。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerExe,
        [string]$ServerArgumentLine = "",
        [string]$WorkingDirectory = (Get-Location).Path,
        [string]$Label = "mcp-stdio"
    )

    if (-not (Test-Path -LiteralPath $ServerExe)) {
        throw "MCP server 可执行文件不存在：$ServerExe"
    }
    if (-not (Test-Path -LiteralPath $WorkingDirectory)) {
        New-Item -ItemType Directory -Force -Path $WorkingDirectory | Out-Null
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ServerExe
    $psi.Arguments = $ServerArgumentLine
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # MCP 是 UTF-8 JSON-RPC。不显式设置时，StandardInput 的 StreamWriter 用进程默认
    # 编码（Windows 上是 OEM 代码页），发送含非 ASCII 的 MATLAB 代码会被转码损坏
    # （实测：中文变成 U+FFFD 写进产物）。这里把三个流都钉死为 UTF-8。
    $psi.StandardInputEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $WorkingDirectory

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    $startedAt = Get-Date
    $process.Start() | Out-Null

    $session = [pscustomobject]@{
        Label        = $Label
        Process      = $process
        Reader       = (New-Object System.IO.StreamReader($process.StandardOutput.BaseStream))
        ErrTask      = $process.StandardError.ReadToEndAsync()
        NextId       = 0
        StartedAt    = $startedAt
        Exe          = (Resolve-Path -LiteralPath $ServerExe).Path
        ArgumentLine = $ServerArgumentLine
        RequestLog   = (New-Object System.Collections.ArrayList)
        TimedOut     = $false
        # 同一时刻只允许一个待决读取：见 Read-McpStdioResponseLine 的说明。
        PendingRead  = $null
    }
    return $session
}

function Test-McpStdioServerAlive {
    param([Parameter(Mandatory)]$Session)
    try { return (-not $Session.Process.HasExited) } catch { return $false }
}

function Get-McpStdioStderrTail {
    <#
    .SYNOPSIS
    取服务端 stderr 尾部。进程未退出时返回空串（ReadToEnd 会阻塞）。
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [int]$MaxChars = 1200
    )
    if (-not $Session.Process.HasExited) { return "" }
    try {
        $text = "$($Session.ErrTask.Result)"
        if ($text.Length -gt $MaxChars) { return $text.Substring($text.Length - $MaxChars) }
        return $text
    }
    catch { return "" }
}

function Send-McpStdioRequest {
    <#
    .SYNOPSIS
    发送一条 JSON-RPC 消息并等待同 id 的响应（notification 不等待）。

    .OUTPUTS
    对象：Ok / Id / Result / Error / TimedOut / DurationMs / SkippedLines / StdErrTail
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Method,
        [object]$Params = $null,
        [switch]$Notification,
        [int]$TimeoutSeconds = 60
    )

    $requestId = $null
    $payload = [ordered]@{ jsonrpc = "2.0" }
    if (-not $Notification) {
        $Session.NextId = [int]$Session.NextId + 1
        $requestId = $Session.NextId
        $payload["id"] = $requestId
    }
    $payload["method"] = $Method
    if ($null -ne $Params) { $payload["params"] = $Params }

    $json = $payload | ConvertTo-Json -Depth 20 -Compress
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $outcome = [pscustomobject][ordered]@{
        Method        = $Method
        Id            = $requestId
        Notification  = [bool]$Notification
        Ok            = $false
        Result        = $null
        Error         = $null
        TimedOut      = $false
        DurationMs    = 0
        SkippedLines  = 0
        RequestBytes  = 0
        StdErrTail    = ""
    }

    try {
        $Session.Process.StandardInput.WriteLine($json)
        $Session.Process.StandardInput.Flush()
        $outcome.RequestBytes = [System.Text.Encoding]::UTF8.GetByteCount($json)
    }
    catch {
        $stopwatch.Stop()
        $outcome.DurationMs = [int]$stopwatch.ElapsedMilliseconds
        $outcome.Error = "写入 stdin 失败：$($_.Exception.Message)"
        return $outcome
    }

    if ($Notification) {
        $stopwatch.Stop()
        $outcome.Ok = $true
        $outcome.DurationMs = [int]$stopwatch.ElapsedMilliseconds
        [void]$Session.RequestLog.Add($outcome)
        return $outcome
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $remainingMs = [int](($deadline - (Get-Date)).TotalMilliseconds)
        if ($remainingMs -le 0) { break }

        if ($Session.Process.HasExited) {
            # 进程已退出：再尝试读一次缓冲，仍无响应就立即失败，不空等到超时。
            $final = Read-McpStdioResponseLine -Session $Session -TimeoutMs 500
            if ($null -ne $final) {
                if (Resolve-McpStdioLine -Outcome $outcome -Line $final -ExpectedId $requestId) { $break }
            }
            $outcome.Error = "服务端进程已退出（exit=$($Session.Process.ExitCode)），未返回响应"
            break
        }

        $line = Read-McpStdioResponseLine -Session $Session -TimeoutMs ([Math]::Min($remainingMs, 1000))
        if ($null -eq $line) { continue }
        if (Resolve-McpStdioLine -Outcome $outcome -Line $line -ExpectedId $requestId) { break }
    }

    $stopwatch.Stop()
    $outcome.DurationMs = [int]$stopwatch.ElapsedMilliseconds
    if (-not $outcome.Ok -and -not $outcome.TimedOut -and -not $outcome.Error) {
        $outcome.TimedOut = $true
        $Session.TimedOut = $true
        $outcome.Error = "等待 $Method 响应超时（${TimeoutSeconds}s）"
    }
    $outcome.StdErrTail = Get-McpStdioStderrTail -Session $Session
    if (-not $outcome.Ok -and -not $outcome.Error) {
        $outcome.Error = "$Method 未得到可识别的 JSON-RPC 响应"
    }
    [void]$Session.RequestLog.Add($outcome)
    return $outcome
}

function Read-McpStdioResponseLine {
    <#
    .SYNOPSIS
    读一行 stdout，带超时。超时或流结束返回 $null。

    .DESCRIPTION
    关键：**同一时刻只能有一个待决的 ReadLineAsync**。

    早期实现是"每轮询一次就新建一个 ReadLineAsync，等不到就丢弃"，结果是
    长时间运行的 tools/call（MATLAB 首次连接要 30 秒）会把同一行数据撕成多段：
    前 N 个被丢弃的任务各自消费掉半行，最终没有任何一行能解析成 JSON，
    表现为"服务端日志显示 Done，客户端却报超时"。
    实测环境：matlab-mcp-server v0.15.0，detect_matlab_toolboxes 31 秒完成，
    客户端 180 秒超时。

    现在同一行由一个跨轮询复用的任务持有；只有它完成（拿到整行）后才创建下一个。
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [int]$TimeoutMs = 1000
    )

    try {
        if ($null -ne $Session.PendingRead) {
            if ($Session.PendingRead.IsCompleted) {
                $buffered = $null
                try { $buffered = $Session.PendingRead.Result } catch { $buffered = $null }
                $Session.PendingRead = $null
                return $buffered
            }
        }
        else {
            $Session.PendingRead = $Session.Reader.ReadLineAsync()
        }

        if (-not $Session.PendingRead.Wait([Math]::Max(1, $TimeoutMs))) {
            # 未完成：保留任务，下轮继续等同一行，不新建。
            return $null
        }

        $line = $null
        try { $line = $Session.PendingRead.Result } catch { $line = $null }
        $Session.PendingRead = $null
        return $line
    }
    catch {
        return $null
    }
}

function Resolve-McpStdioLine {
    <#
    .SYNOPSIS
    把一行输出解析进 outcome；命中期望 id 时返回 $true。
    .DESCRIPTION
    服务端可能夹带日志行或服务器主动通知（无 id）。这些要跳过而不是当成响应，
    否则一次日志就会把整个验收判成失败。
    #>
    param(
        [Parameter(Mandatory)]$Outcome,
        [AllowNull()][AllowEmptyString()][string]$Line,
        [int]$ExpectedId
    )

    if ([string]::IsNullOrWhiteSpace($Line)) { return $false }

    $trimmed = $Line.Trim()
    if (-not $trimmed.StartsWith("{")) {
        $Outcome.SkippedLines = [int]$Outcome.SkippedLines + 1
        return $false
    }

    $parsed = $null
    try { $parsed = $trimmed | ConvertFrom-Json } catch {
        $Outcome.SkippedLines = [int]$Outcome.SkippedLines + 1
        return $false
    }

    $hasId = $parsed.PSObject.Properties.Name -contains "id"
    if (-not $hasId) {
        # 服务器主动通知（notifications/*），不是本次请求的响应。
        $Outcome.SkippedLines = [int]$Outcome.SkippedLines + 1
        return $false
    }

    if ([int]$parsed.id -ne $ExpectedId) {
        $Outcome.SkippedLines = [int]$Outcome.SkippedLines + 1
        return $false
    }

    if ($parsed.PSObject.Properties.Name -contains "error") {
        $Outcome.Error = ($parsed.error | ConvertTo-Json -Compress -Depth 8)
        return $true
    }

    $Outcome.Ok = $true
    $Outcome.Result = $parsed.result
    return $true
}

function Enable-McpLocalhostProxyBypass {
    <#
    .SYNOPSIS
    为当前进程设置 NO_PROXY，让子进程（官方 server）不走代理访问 localhost。

    .DESCRIPTION
    实测问题：机器上设置了 HTTPS_PROXY 但没有 NO_PROXY 时，官方 matlab-mcp-server
    的 Go HTTP 客户端会把 https://localhost:<port>/messageservice/json/secure
    也发给代理，结果是 403 Forbidden 或 context deadline exceeded，
    表现为 existing 模式永远连不上已共享的 MATLAB 会话。

    为什么不改用户环境变量：
    - 只设置当前进程的 NO_PROXY，子进程继承，脚本结束即还原；
    - 不写用户级/机器级设置，避免影响用户其它工具。

    返回状态对象，供 Restore-McpProxyEnvironment 还原并写入报告。
    #>
    param([string[]]$Hosts = @("localhost", "127.0.0.1", "::1"))

    $names = @("NO_PROXY", "no_proxy")
    $previous = @{}
    foreach ($name in $names) {
        $previous[$name] = [System.Environment]::GetEnvironmentVariable($name, "Process")
    }

    $existing = New-Object System.Collections.Generic.List[string]
    foreach ($name in $names) {
        $value = $previous[$name]
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        foreach ($item in ($value -split ",")) {
            $trimmed = $item.Trim()
            if ($trimmed) { $existing.Add($trimmed) }
        }
    }
    foreach ($item in $Hosts) { $existing.Add($item) }

    $merged = (@($existing | Select-Object -Unique) -join ",")
    foreach ($name in $names) {
        [System.Environment]::SetEnvironmentVariable($name, $merged, "Process")
    }

    return [pscustomobject][ordered]@{
        Applied  = $merged
        Previous = $previous
        Changed  = $true
    }
}

function Restore-McpProxyEnvironment {
    <#
    .SYNOPSIS
    还原 Enable-McpLocalhostProxyBypass 改动的进程环境变量。
    #>
    param($State)

    if ($null -eq $State -or -not $State.Changed) { return }
    foreach ($name in @($State.Previous.Keys)) {
        $value = $State.Previous[$name]
        try {
            if ([string]::IsNullOrEmpty($value)) {
                [System.Environment]::SetEnvironmentVariable($name, $null, "Process")
            }
            else {
                [System.Environment]::SetEnvironmentVariable($name, $value, "Process")
            }
        }
        catch { }
    }
}

function Get-McpProxyEnvironmentSnapshot {
    <#
    .SYNOPSIS
    记录当前进程的代理环境，供报告审计（不含任何凭据）。
    #>
    $names = @("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "NO_PROXY", "no_proxy")
    $snapshot = [ordered]@{}
    foreach ($name in $names) {
        $value = [System.Environment]::GetEnvironmentVariable($name, "Process")
        $snapshot[$name] = $(if ([string]::IsNullOrEmpty($value)) { $null } else { $value })
    }
    return $snapshot
}

function Protect-McpSensitiveText {
    <#
    .SYNOPSIS
    把 MCP 输出里的许可证号与凭据替换成占位符，供报告落盘时使用。

    .DESCRIPTION
    真实工具输出会带上 "MATLAB 许可证编号: 41305290" 这类信息；
    sessionDetails.json 里的 apiKey 也可能出现在诊断文本里。
    验收报告是会被提交/分享的产物，不应该顺带把凭据带走。
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return "" }
    $result = $Text
    $result = [regex]::Replace($result, '(?i)(许可证编号|License\s*Number|License\s*No\.?)\s*[:：=]\s*\d+', '$1: <redacted>')
    $result = [regex]::Replace($result, '(?i)("?api[_-]?key"?\s*[:=]\s*"?)[A-Za-z0-9\-_]{8,}', '$1<redacted>')
    return $result
}

function Get-McpStdioToolText {
    <#
    .SYNOPSIS
    从 tools/call 的 result 中提取文本内容。
    #>
    param($ResultNode)

    if ($null -eq $ResultNode) { return "" }
    $texts = New-Object System.Collections.Generic.List[string]

    if ($ResultNode.PSObject.Properties.Name -contains "content") {
        foreach ($item in @($ResultNode.content)) {
            if ($null -eq $item) { continue }
            if ($item.PSObject.Properties.Name -contains "text") { $texts.Add("$($item.text)") }
        }
    }
    foreach ($name in @("output", "stdout", "result", "value")) {
        if ($ResultNode.PSObject.Properties.Name -contains $name) {
            $value = $ResultNode.$name
            if ($value -is [string]) { $texts.Add($value) }
        }
    }
    return ($texts -join "`n")
}

function Stop-McpStdioServer {
    <#
    .SYNOPSIS
    关闭服务端进程并返回收尾信息（stderr 尾部、退出码）。
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [int]$GraceSeconds = 3
    )

    $info = [pscustomobject][ordered]@{
        Exited     = $false
        ExitCode   = $null
        Forced     = $false
        StdErrTail = ""
    }

    try {
        if (-not $Session.Process.HasExited) {
            try { $Session.Process.StandardInput.Close() } catch { }
            if (-not $Session.Process.WaitForExit($GraceSeconds * 1000)) {
                try { $Session.Process.Kill() } catch { }
                $info.Forced = $true
                $Session.Process.WaitForExit(5000) | Out-Null
            }
        }
        $info.Exited = $Session.Process.HasExited
        if ($info.Exited) { $info.ExitCode = $Session.Process.ExitCode }
        $info.StdErrTail = Get-McpStdioStderrTail -Session $Session
    }
    catch {
        $info.StdErrTail = "关闭服务端时出错：$($_.Exception.Message)"
    }
    finally {
        try { $Session.Reader.Dispose() } catch { }
        try { $Session.Process.Dispose() } catch { }
    }
    return $info
}

Export-ModuleMember -Function *
