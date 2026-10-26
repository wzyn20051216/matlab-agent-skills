#Requires -Version 5.1
<#
.SYNOPSIS
MATLAB MCP 分级探测：把“配置看起来对”与“MCP 真的能执行”分开。

.DESCRIPTION
阶段划分（每阶段独立输出 PASS / FAIL / SKIP，互不冒充）：
1. MATLAB 安装与许可证可用
2. MCP Server 进程与配置正确（会话文件、客户端注册参数）
3. MCP 协议握手成功（JSON-RPC initialize）
4. 只读命令真实执行成功（tools/call 执行 disp(version)）
5. 文件写入与读取验证成功（仅限隔离测试目录）

设计原则：
- 会话文件存在、PID 存活、配置字符串正确，都只作为阶段 2 的证据，绝不等于阶段 3 成功；
- 无证书 / 无端口 / 未配置时输出 SKIP 并写明原因，不臆造 PASS；
- 阶段 4、5 依赖阶段 3 成功，否则 SKIP；
- 每个阶段都有超时，避免挂起。
#>

$coreModulePath = Join-Path $PSScriptRoot "MatlabAgentSkills.Core.psm1"
if (Test-Path -LiteralPath $coreModulePath) {
    Import-Module $coreModulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue
}

$defaultSessionRelative = "MathWorks\MATLAB MCP Server\v1\sessionDetails.json"
# 凭据只在进程内短暂持有，绝不进入可序列化的会话信息对象或验收报告。
$script:McpSessionCredential = $null

function Get-McpDefaultSessionFile {
    <# .SYNOPSIS 返回默认的 MCP 会话文件路径。 #>
    return (Join-Path $env:APPDATA $defaultSessionRelative)
}

function ConvertFrom-JsonCaseSensitive {
    <#
    .SYNOPSIS
    按大小写敏感语义解析 JSON。
    .DESCRIPTION
    Windows PowerShell 5.1 的 ConvertFrom-Json 用大小写不敏感的字典，遇到同时存在
    "C:/Windows" 与 "C:/WINDOWS" 这类键会直接抛“重复的键”，把合法 JSON 误判为损坏。
    这里优先用 JavaScriptSerializer（字典大小写敏感），不可用时回退到 ConvertFrom-Json。
    #>
    param([Parameter(Mandatory)][string]$Text)

    try {
        Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
        $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $serializer.MaxJsonLength = [int]::MaxValue
        $serializer.RecursionLimit = 512
        $parsed = $serializer.DeserializeObject($Text)
        if ($null -eq $parsed) { return $null }
        # IDictionary 是 IEnumerable，直接 return 会被展开成 DictionaryEntry 流。
        return ,$parsed
    }
    catch {
        return ($Text | ConvertFrom-Json)
    }
}

function Find-DictionaryKey {
    <#
    .SYNOPSIS
    在字典中按大小写敏感语义查找真实键名。
    .DESCRIPTION
    Dictionary<string,object> 的 Contains 是显式接口实现，PowerShell 直接调用会命中
    ICollection<KeyValuePair>.Contains 而报“没有 1 参数重载”。这里显式遍历键并做 -ceq 比较。
    #>
    param($Dictionary, [string]$Name)
    if ($null -eq $Dictionary) { return $null }
    foreach ($key in $Dictionary.Keys) {
        if ([string]$key -ceq $Name) { return $key }
    }
    return $null
}

function Test-NodeProperty {
    <# .SYNOPSIS 判断解析出的 JSON 节点是否含某个属性（兼容字典与 PSCustomObject）。 #>
    param($Node, [string]$Name)
    if ($null -eq $Node) { return $false }
    if ($Node -is [System.Collections.IDictionary]) { return ($null -ne (Find-DictionaryKey -Dictionary $Node -Name $Name)) }
    return [bool]($Node.PSObject.Properties[$Name])
}

function Get-NodeProperty {
    <# .SYNOPSIS 读取 JSON 节点属性，缺失返回 $null。 #>
    param($Node, [string]$Name)
    if ($null -eq $Node) { return $null }
    if ($Node -is [System.Collections.IDictionary]) {
        $key = Find-DictionaryKey -Dictionary $Node -Name $Name
        if ($null -eq $key) { return $null }
        return $Node[$key]
    }
    $property = $Node.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-McpSessionInfo {
    <#
    .SYNOPSIS
    解析 sessionDetails.json，仅描述“配置层”事实。
    #>
    [CmdletBinding()]
    param([string]$SessionFile = (Get-McpDefaultSessionFile))

    $script:McpSessionCredential = $null
    $info = [pscustomobject][ordered]@{
        Path               = $SessionFile
        Exists             = $false
        Parsed             = $false
        Port               = $null
        HasApiKey          = $false
        ApiKeyLength       = 0
        Certificate        = $null
        CertificateExists  = $false
        Pid                = $null
        ProcessAlive       = $false
        ProcessName        = $null
        Error              = $null
    }

    if (-not $SessionFile -or -not (Test-Path -LiteralPath $SessionFile)) {
        $info.Error = "会话文件不存在"
        return $info
    }

    $info.Exists = $true
    try {
        $sessionText = [System.IO.File]::ReadAllText($SessionFile, (New-Object System.Text.UTF8Encoding($false)))
        $session = ConvertFrom-JsonCaseSensitive -Text $sessionText
    }
    catch {
        $info.Error = "会话文件不是合法 JSON: $($_.Exception.Message)"
        return $info
    }

    $info.Parsed = $true
    if (Test-NodeProperty -Node $session -Name "port") { $info.Port = [int](Get-NodeProperty -Node $session -Name "port") }
    if (Test-NodeProperty -Node $session -Name "apiKey") {
        $apiKeyText = "$(Get-NodeProperty -Node $session -Name "apiKey")"
        if (-not [string]::IsNullOrEmpty($apiKeyText)) {
            $info.HasApiKey = $true
            $info.ApiKeyLength = $apiKeyText.Length
            # 凭据只在这里落地一次；调用方通过 Get-McpSessionCredential 短期读取，不进入任何可序列化对象。
            $script:McpSessionCredential = [pscustomobject]@{
                Path   = [System.IO.Path]::GetFullPath($SessionFile)
                ApiKey = $apiKeyText
            }
        }
        $apiKeyText = $null
    }
    if (Test-NodeProperty -Node $session -Name "certificate") { $info.Certificate = "$(Get-NodeProperty -Node $session -Name "certificate")" }
    if (Test-NodeProperty -Node $session -Name "pid") { $info.Pid = [int](Get-NodeProperty -Node $session -Name "pid") }

    if ($info.Certificate) {
        $info.CertificateExists = Test-Path -LiteralPath $info.Certificate
    }
    if ($info.Pid) {
        $process = Get-Process -Id $info.Pid -ErrorAction SilentlyContinue
        if ($process) {
            $info.ProcessAlive = $true
            $info.ProcessName = $process.ProcessName
        }
    }
    return $info
}

function Get-McpSessionCredential {
    <#
    .SYNOPSIS
    返回进程内短持有的 MCP apiKey，仅供鉴权头使用。
    .DESCRIPTION
    凭据不进入 Get-McpSessionInfo 的返回对象，也不写入报告或日志。
    调用方必须显式通过本函数取值，避免整份会话对象被序列化时顺带泄露。
    #>
    [CmdletBinding()]
    param([string]$SessionFile = (Get-McpDefaultSessionFile))

    if ([string]::IsNullOrWhiteSpace($SessionFile)) { return $null }
    $fullPath = [System.IO.Path]::GetFullPath($SessionFile)

    $holder = $script:McpSessionCredential
    $holderMatches = ($null -ne $holder -and
        [string]::Equals([string]$holder.Path, $fullPath, [System.StringComparison]::OrdinalIgnoreCase))
    if (-not $holderMatches) {
        $null = Get-McpSessionInfo -SessionFile $SessionFile
        $holder = $script:McpSessionCredential
        $holderMatches = ($null -ne $holder -and
            [string]::Equals([string]$holder.Path, $fullPath, [System.StringComparison]::OrdinalIgnoreCase))
    }
    if (-not $holderMatches) { return $null }
    if ([string]::IsNullOrEmpty([string]$holder.ApiKey)) { return $null }
    return [string]$holder.ApiKey
}

function Get-McpClientRegistrations {
    <#
    .SYNOPSIS
    收集 Codex / Claude / VS Code / generic 的 MCP 注册信息（只读）。
    .DESCRIPTION
    优先读取配置文件；Codex 额外尝试 `codex mcp get`，但受超时保护。
    返回条目包含 command/args/参数合法性/可执行文件是否存在，供阶段 2 判定。
    #>
    [CmdletBinding()]
    param(
        [string]$ServerName = "matlab-official",
        [string]$RepositoryRoot = (Get-Location).Path,
        [int]$CliTimeoutSeconds = 15,
        [switch]$SkipCodexCli,
        [switch]$SkipUserConfigs
    )

    $entries = New-Object System.Collections.Generic.List[object]

    $addEntry = {
        param($Client, $Source, $Command, $ArgumentValues, $Raw = "")
        $argList = @()
        if ($null -ne $ArgumentValues) { $argList = @($ArgumentValues) }
        $violations = @()
        if (Get-Command Test-McpServerArgsCompatible -ErrorAction SilentlyContinue) {
            $violations = @(Test-McpServerArgsCompatible -Arguments $argList)
        }
        $commandExists = $false
        if ($Command) {
            if (Test-Path -LiteralPath "$Command") { $commandExists = $true }
            elseif (Get-Command "$Command" -ErrorAction SilentlyContinue) { $commandExists = $true }
        }
        $entries.Add([pscustomobject][ordered]@{
            client         = $Client
            source         = $Source
            command        = $Command
            args           = $argList
            commandExists  = $commandExists
            violations     = $violations
            valid          = ($violations.Count -eq 0 -and $commandExists)
            raw            = $Raw
        })
    }

    $jsonConfigs = @(
        @{ Client = "generic"; Path = (Join-Path $RepositoryRoot ".mcp.json"); Root = "mcpServers" },
        @{ Client = "vscode"; Path = (Join-Path $RepositoryRoot ".vscode\mcp.json"); Root = "servers" },
        @{ Client = "vscode"; Path = (Join-Path $RepositoryRoot ".vscode\mcp.json"); Root = "mcpServers" }
    )
    if (-not $SkipUserConfigs) {
        $jsonConfigs += @{ Client = "claude"; Path = (Join-Path $HOME ".claude.json"); Root = "mcpServers" }
        $jsonConfigs += @{ Client = "claude"; Path = (Join-Path $env:APPDATA "Claude\claude_desktop_config.json"); Root = "mcpServers" }
    }

    foreach ($config in $jsonConfigs) {
        if (-not (Test-Path -LiteralPath $config.Path)) { continue }
        try {
            $configText = [System.IO.File]::ReadAllText($config.Path, (New-Object System.Text.UTF8Encoding($false)))
            $parsed = ConvertFrom-JsonCaseSensitive -Text $configText
        }
        catch {
            $entries.Add([pscustomobject][ordered]@{
                client = $config.Client; source = $config.Path; command = $null; args = @()
                commandExists = $false; violations = @("配置文件不是合法 JSON"); valid = $false
                raw = $_.Exception.Message
            })
            continue
        }
        $rootNode = $null
        if (Test-NodeProperty -Node $parsed -Name $config.Root) {
            $rootNode = Get-NodeProperty -Node $parsed -Name $config.Root
        }
        if ($null -eq $rootNode) { continue }
        $serverNode = $null
        if (Test-NodeProperty -Node $rootNode -Name $ServerName) { $serverNode = Get-NodeProperty -Node $rootNode -Name $ServerName }
        if ($null -eq $serverNode) { continue }
        $command = $null
        if (Test-NodeProperty -Node $serverNode -Name "command") { $command = "$(Get-NodeProperty -Node $serverNode -Name 'command')" }
        $args = @()
        if (Test-NodeProperty -Node $serverNode -Name "args") { $args = @(Get-NodeProperty -Node $serverNode -Name "args") }
        & $addEntry $config.Client $config.Path $command $args
    }

    # Codex：配置文件是 TOML，直接解析不稳定；优先用 CLI，带超时。
    if (-not $SkipCodexCli) {
        $codex = Get-Command codex -ErrorAction SilentlyContinue
        if ($codex) {
            $result = Invoke-ProcessWithTimeout -FilePath $codex.Source -ArgumentList @("mcp", "get", $ServerName) -TimeoutSeconds $CliTimeoutSeconds
            if (-not $result.TimedOut -and $result.ExitCode -eq 0) {
                $text = "$($result.StandardOutput)`n$($result.StandardError)"
                $mode = $null
                if ($text -match '--matlab-session-mode=([A-Za-z]+)') { $mode = $Matches[1] }
                $args = @()
                if ($text -match '(?s)args\s*[:=]\s*(.+)') {
                    $argMatches = [regex]::Matches($text, '--[A-Za-z0-9-]+(=[^\s,"\]]+)?')
                    foreach ($m in $argMatches) { $args += $m.Value }
                }
                $command = $null
                if ($text -match '(?m)^\s*(command|Command)\s*[:=]\s*"?([^"\r\n]+)"?') { $command = $Matches[2].Trim() }
                $codexViolations = @()
                if (Get-Command Test-McpServerArgsCompatible -ErrorAction SilentlyContinue) {
                    $codexViolations = @(Test-McpServerArgsCompatible -Arguments $args)
                }
                $codexCommandExists = $false
                if ($command) {
                    $codexCommandExists = (Test-Path -LiteralPath $command) -or [bool](Get-Command $command -ErrorAction SilentlyContinue)
                }
                $entries.Add([pscustomobject][ordered]@{
                    client        = "codex"
                    source        = "codex mcp get $ServerName"
                    command       = $command
                    args          = $args
                    commandExists = $codexCommandExists
                    violations    = $codexViolations
                    valid         = ($codexViolations.Count -eq 0 -and $args.Count -gt 0 -and $codexCommandExists)
                    raw           = $text.Trim()
                    sessionMode   = $mode
                })
            }
            elseif ($result.TimedOut) {
                $entries.Add([pscustomobject][ordered]@{
                    client = "codex"; source = "codex mcp get $ServerName"; command = $null; args = @()
                    commandExists = $false; violations = @("codex CLI 超时（${CliTimeoutSeconds}s）"); valid = $false
                    raw = "timeout"
                })
            }
        }
    }

    return @($entries.ToArray())
}

function ConvertFrom-McpResponseBody {
    <#
    .SYNOPSIS
    解析 MCP 响应体，兼容纯 JSON 与 SSE（event/data 行）。
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Body)

    if ([string]::IsNullOrWhiteSpace($Body)) { return $null }

    $trimmed = $Body.Trim()
    if ($trimmed.StartsWith("{") -or $trimmed.StartsWith("[")) {
        try { return ($trimmed | ConvertFrom-Json) } catch { return $null }
    }

    foreach ($line in ($trimmed -split "`r?`n")) {
        $candidate = $line.Trim()
        if ($candidate.StartsWith("data:")) {
            $payload = $candidate.Substring(5).Trim()
            if ($payload.StartsWith("{")) {
                try { return ($payload | ConvertFrom-Json) } catch { continue }
            }
        }
    }
    return $null
}

function Invoke-McpJsonRpc {
    <#
    .SYNOPSIS
    向 MCP 端点发送一条 JSON-RPC 2.0 请求。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][string]$Method,
        [object]$Params = $null,
        [string]$ApiKey,
        [string]$AuthHeaderName = "x-api-key",
        [int]$TimeoutSeconds = 20,
        [switch]$SkipTlsValidation,
        [int]$Id = 1
    )

    $result = [pscustomobject][ordered]@{
        Ok         = $false
        StatusCode = $null
        Body       = ""
        Json       = $null
        Error      = $null
        ErrorClass = $null
        DurationMs = 0
    }

    $payload = [ordered]@{
        jsonrpc = "2.0"
        id      = $Id
        method  = $Method
    }
    if ($null -ne $Params) { $payload["params"] = $Params }
    $body = $payload | ConvertTo-Json -Depth 12 -Compress

    $headers = @{ "Accept" = "application/json, text/event-stream" }
    if ($ApiKey) { $headers[$AuthHeaderName] = $ApiKey }

    $previousCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    $previousProtocol = [System.Net.ServicePointManager]::SecurityProtocol
    if ($SkipTlsValidation) {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { param($a, $b, $c, $d) return $true }
    }
    try {
        try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch { }
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $response = Invoke-WebRequest -Uri $Endpoint -Method Post -Body $body `
                -ContentType "application/json" -Headers $headers -TimeoutSec $TimeoutSeconds -UseBasicParsing
            $result.StatusCode = [int]$response.StatusCode
            $result.Body = "$($response.Content)"
            $result.Ok = $true
        }
        catch {
            $exception = $_.Exception
            $httpResponse = $null
            if ($exception.PSObject.Properties.Name -contains "Response") { $httpResponse = $exception.Response }
            if ($httpResponse) {
                try { $result.StatusCode = [int]$httpResponse.StatusCode } catch { }
                try {
                    if ($httpResponse.PSObject.Methods["GetResponseStream"]) {
                        $reader = New-Object System.IO.StreamReader($httpResponse.GetResponseStream())
                        $result.Body = $reader.ReadToEnd()
                        $reader.Close()
                    }
                }
                catch { }
            }
            if (-not $result.Body -and $_.ErrorDetails) { $result.Body = "$($_.ErrorDetails.Message)" }
            $result.Error = $exception.Message
            $result.ErrorClass = "MCP_CONNECTION_ERROR"
        }
        finally {
            $stopwatch.Stop()
            $result.DurationMs = [int]$stopwatch.ElapsedMilliseconds
        }
    }
    finally {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previousCallback
        [System.Net.ServicePointManager]::SecurityProtocol = $previousProtocol
    }

    if ($result.Body) {
        $result.Json = ConvertFrom-McpResponseBody -Body $result.Body
    }
    return $result
}

function Get-McpToolText {
    <# .SYNOPSIS 从 tools/call 结果里提取文本内容。 #>
    param($Result)

    if ($null -eq $Result) { return "" }
    $texts = New-Object System.Collections.Generic.List[string]

    $content = $null
    if ($Result -is [System.Management.Automation.PSCustomObject] -and $Result.PSObject.Properties.Name -contains "content") {
        $content = $Result.content
    }
    if ($content) {
        foreach ($item in @($content)) {
            if ($item.PSObject.Properties.Name -contains "text") { $texts.Add("$($item.text)") }
        }
    }
    foreach ($name in @("output", "stdout", "result", "value")) {
        if ($Result -is [System.Management.Automation.PSCustomObject] -and $Result.PSObject.Properties.Name -contains $name) {
            $value = $Result.$name
            if ($value -is [string]) { $texts.Add($value) }
        }
    }
    return ($texts -join "`n")
}

function Test-TcpEndpoint {
    <# .SYNOPSIS 判断 host:port 是否可建立 TCP 连接（不涉及 TLS/协议）。 #>
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 5000
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($ComputerName, $Port)
        if (-not $task.Wait($TimeoutMs)) { return $false }
        return $client.Connected
    }
    catch { return $false }
    finally { $client.Close() }
}

function Invoke-McpStagedProbe {
    <#
    .SYNOPSIS
    执行 5 阶段 MCP 探测并返回验收报告。
    .OUTPUTS
    验收报告对象（符合 schemas/acceptance-report.schema.json）。
    #>
    [CmdletBinding()]
    param(
        [string]$ServerName = "matlab-official",
        [string]$SessionFile = (Get-McpDefaultSessionFile),
        [string]$MatlabPath = $env:MATLAB_EXE,
        [string]$RepositoryRoot = (Get-Location).Path,
        [ValidateSet("static", "matlab-batch", "matlab-mcp-auto", "matlab-mcp-existing", "matlab-mcp-new")]
        [string]$Backend = "matlab-mcp-existing",
        [string]$EndpointPath = "/mcp",
        [ValidateSet("http", "https")][string]$Scheme = "https",
        [string]$AuthHeaderName = "x-api-key",
        [int]$TimeoutSeconds = 20,
        [switch]$SkipTlsValidation,
        [switch]$VerifyLicense,
        [switch]$SkipStage1,
        [switch]$SkipStage5,
        [string]$IoProbeDirectory,
        [string]$EvalTool = "",
        [string]$EvalToolArgument = "code",
        [switch]$SkipCodexCli,
        [switch]$SkipUserConfigs,
        [string]$TaskId = ""
    )

    if (-not $TaskId) { $TaskId = New-AcceptanceTaskId -Prefix "mcp-probe" }
    if (-not $IoProbeDirectory) { $IoProbeDirectory = Join-Path $RepositoryRoot "artifacts\validation\mcp_io_probe" }

    $matlabExe = Resolve-MatlabExecutable -ExplicitPath $MatlabPath
    $installInfo = $null
    if ($matlabExe) { $installInfo = Get-MatlabInstallInfo -ExecutablePath $matlabExe }

    $report = New-AcceptanceReport -TaskId $TaskId -Backend $Backend `
        -MatlabVersion $(if ($installInfo -and $installInfo.Readable) { "$($installInfo.Version) $($installInfo.Description)" } else { "" }) `
        -MatlabRelease $(if ($installInfo -and $installInfo.Readable) { "$($installInfo.Release)" } else { "" }) `
        -MatlabExecutable $matlabExe -MatlabInstalled ([bool]$matlabExe)

    # ---------------- 阶段 1：MATLAB 安装与许可证 ----------------
    if ($SkipStage1) {
        $report = Add-AcceptanceCheck -Report $report -Id "mcp.matlab-install" -Title "MATLAB 安装可解析" -Level "L1" -Status "SKIP" `
            -Reason "调用方要求跳过阶段 1"
    }
    elseif (-not $matlabExe) {
        $report = Add-AcceptanceCheck -Report $report -Id "mcp.matlab-install" -Title "MATLAB 安装可解析" -Level "L1" -Status "FAIL" `
            -Reason "未找到 matlab 可执行文件（MATLAB_EXE / PATH / MATLAB_ROOT 均未命中）" -ErrorClass "ENVIRONMENT_ERROR"
    }
    else {
        $metrics = [ordered]@{
            executable    = $matlabExe
            versionInfo   = if ($installInfo) { $installInfo.VersionInfo } else { $null }
            version       = if ($installInfo) { $installInfo.Version } else { $null }
            release       = if ($installInfo) { $installInfo.Release } else { $null }
            versionReadable = [bool]($installInfo -and $installInfo.Readable)
        }
        $report = Add-AcceptanceCheck -Report $report -Id "mcp.matlab-install" -Title "MATLAB 安装可解析" -Level "L1" -Status "PASS" `
            -Command "Resolve-MatlabExecutable" -Metrics $metrics -ArtifactPaths @()
    }

    if (-not $VerifyLicense) {
        $report = Add-AcceptanceCheck -Report $report -Id "mcp.matlab-license" -Title "MATLAB 许可证可用" -Level "L1" -Status "SKIP" `
            -Reason "许可证只能通过启动 MATLAB 验证；未指定 -VerifyLicense，故不声称许可证可用"
    }
    elseif (-not $matlabExe) {
        $report = Add-AcceptanceCheck -Report $report -Id "mcp.matlab-license" -Title "MATLAB 许可证可用" -Level "L1" -Status "SKIP" `
            -Reason "MATLAB 未解析成功，无法验证许可证"
    }
    else {
        $licenseCode = "fprintf('LICENSE_TEST=%d\n', license('test','MATLAB')); fprintf('RELEASE=%s\n', version('-release'));"
        $licenseResult = Invoke-MatlabBatchProcess -MatlabPath $matlabExe -ArgumentList @("-batch", $licenseCode) `
            -WorkingDirectory $RepositoryRoot -TimeoutSeconds ([Math]::Max($TimeoutSeconds, 60)) -Label "mcp_license_probe"
        $licenseText = "$($licenseResult.LogTail)"
        $licenseOk = $licenseText -match "LICENSE_TEST=1"
        $status = "FAIL"
        $reason = $null
        $errorClass = $licenseResult.ErrorClass
        if ($licenseOk) {
            $status = "PASS"
            $errorClass = $null
        }
        elseif ($licenseResult.TimedOut) {
            $errorClass = "TIMEOUT"
            $reason = "许可证探测超时（$($licenseResult.DurationSeconds)s），MATLAB 可能卡在在线许可校验"
        }
        elseif ($errorClass -eq "LICENSE_ERROR") {
            $reason = "许可证校验失败：$($licenseResult.ErrorReason)"
        }
        else {
            $reason = "未获得 LICENSE_TEST=1（错误类别：$errorClass）"
            if (-not $errorClass) { $errorClass = "LICENSE_ERROR" }
        }
        $report = Add-AcceptanceCheck -Report $report -Id "mcp.matlab-license" -Title "MATLAB 许可证可用" -Level "L1" -Status $status `
            -Command $licenseResult.Command -ExitCode $licenseResult.ExitCode -Reason $reason -ErrorClass $errorClass `
            -Metrics ([ordered]@{ durationSeconds = $licenseResult.DurationSeconds; timedOut = $licenseResult.TimedOut }) `
            -ArtifactPaths @($licenseResult.StdoutPath, $licenseResult.StderrPath)
    }

    # ---------------- 阶段 2：配置与会话 ----------------
    $session = Get-McpSessionInfo -SessionFile $SessionFile
    $registrationParams = @{
        ServerName     = $ServerName
        RepositoryRoot = $RepositoryRoot
    }
    if ($SkipCodexCli) { $registrationParams["SkipCodexCli"] = $true }
    if ($SkipUserConfigs) { $registrationParams["SkipUserConfigs"] = $true }
    $registrations = @(Get-McpClientRegistrations @registrationParams)

    # 报告只记录文件名与内容指纹：绝对路径会泄露用户目录结构，凭据更不能落盘。
    $sessionFileName = if ([string]::IsNullOrEmpty([string]$session.Path)) { $null } else { Split-Path -Leaf $session.Path }
    $sessionFileSha256 = $null
    if ($session.Exists -and $session.Path) {
        $sessionFileSha256 = Get-FileSha256 -Path $session.Path
    }

    $sessionMetrics = [ordered]@{
        sessionFile       = $sessionFileName
        sessionFileSha256 = $sessionFileSha256
        exists            = $session.Exists
        parsed            = $session.Parsed
        port              = $session.Port
        hasApiKey         = $session.HasApiKey
        apiKeyLength      = $session.ApiKeyLength
        certificate       = $session.Certificate
        certificateExists = $session.CertificateExists
        pid               = $session.Pid
        pidAlive          = $session.ProcessAlive
        processName       = $session.ProcessName
        note              = "会话文件与 PID 存活只说明配置存在，不代表 MCP 协议可用"
    }

    $sessionStatus = "PASS"
    $sessionReason = $null
    $sessionErrorClass = $null
    if (-not $session.Exists) {
        $sessionStatus = "SKIP"
        $sessionReason = "未发现 sessionDetails.json：MATLAB 未共享会话，阶段 3 无法进行"
    }
    elseif (-not $session.Parsed) {
        $sessionStatus = "FAIL"
        $sessionReason = $session.Error
        $sessionErrorClass = "MCP_CONNECTION_ERROR"
    }
    elseif (-not $session.Port -or -not $session.HasApiKey) {
        $sessionStatus = "FAIL"
        $sessionReason = "会话文件缺少 port 或 apiKey 字段"
        $sessionErrorClass = "MCP_CONNECTION_ERROR"
    }
    elseif (-not $session.CertificateExists) {
        $sessionStatus = "SKIP"
        $sessionReason = "会话证书不可读（$($session.Certificate)）：通常意味着会话已失效，需要重新 shareMATLABSession()"
    }
    elseif (-not $session.ProcessAlive) {
        $sessionStatus = "SKIP"
        $sessionReason = "会话 PID $($session.Pid) 已不存在：会话文件过期，需重新共享会话"
    }

    $report = Add-AcceptanceCheck -Report $report -Id "mcp.session-config" -Title "MCP 会话文件可解析" -Level "L1" `
        -Status $sessionStatus -Reason $sessionReason -ErrorClass $sessionErrorClass -Metrics $sessionMetrics

    $validRegistrations = @($registrations | Where-Object { $_.valid })
    $violationRegistrations = @($registrations | Where-Object { @($_.violations).Count -gt 0 })
    $missingCommandRegistrations = @($registrations | Where-Object { $_.command -and -not $_.commandExists })
    $registrationMetrics = [ordered]@{
        total            = $registrations.Count
        valid            = $validRegistrations.Count
        violationCount   = $violationRegistrations.Count
        missingCommand   = $missingCommandRegistrations.Count
        clients          = @($registrations | ForEach-Object { $_.client })
        entries          = @($registrations | ForEach-Object {
            [ordered]@{
                client        = $_.client
                source        = $_.source
                command       = $_.command
                args          = @($_.args)
                valid         = $_.valid
                commandExists = $_.commandExists
                violations    = @($_.violations)
            }
        })
    }

    $registrationStatus = "PASS"
    $registrationReason = $null
    if ($violationRegistrations.Count -gt 0) {
        $registrationStatus = "FAIL"
        $registrationReason = "存在非法参数注册：$((@($violationRegistrations | ForEach-Object { "$($_.client): $($_.violations -join '; ')" })) -join ' | ')"
    }
    elseif ($missingCommandRegistrations.Count -gt 0) {
        $registrationStatus = "FAIL"
        $registrationReason = "注册指向的 command 不存在：$((@($missingCommandRegistrations | ForEach-Object { "$($_.client): $($_.command)" })) -join ' | ')"
    }
    elseif ($validRegistrations.Count -eq 0) {
        $registrationStatus = "SKIP"
        $registrationReason = "未发现包含 '$ServerName' 的有效注册（检查 Codex / Claude / VS Code / .mcp.json）"
    }

    $report = Add-AcceptanceCheck -Report $report -Id "mcp.client-registration" -Title "客户端 MCP 注册参数合法" -Level "L2" `
        -Status $registrationStatus -Reason $registrationReason -Metrics $registrationMetrics `
        -ErrorClass $(if ($registrationStatus -eq "FAIL") { "MCP_CONNECTION_ERROR" } else { $null })

    # ---------------- 阶段 3：协议握手 ----------------
    $handshakeReady = ($sessionStatus -eq "PASS")
    $endpoint = $null
    $sessionCredential = $null
    if ($handshakeReady) {
        $endpoint = "${Scheme}://127.0.0.1:$($session.Port)$EndpointPath"
        $sessionCredential = Get-McpSessionCredential -SessionFile $SessionFile
    }

    $handshakeStatus = "SKIP"
    $handshakeReason = "阶段 2 未给出可用会话（$sessionStatus）：$sessionReason"
    $handshakeMetrics = [ordered]@{ endpoint = $endpoint; tcpReachable = $false; protocolVersion = $null; serverName = $null }
    $handshakeErrorClass = $null
    $handshakeCommand = $null

    if ($handshakeReady) {
        $handshakeCommand = "POST $endpoint (initialize)"
        $tcpOk = Test-TcpEndpoint -ComputerName "127.0.0.1" -Port $session.Port -TimeoutMs ([Math]::Max(1000, $TimeoutSeconds * 250))
        $handshakeMetrics.tcpReachable = $tcpOk
        if (-not $tcpOk) {
            $handshakeStatus = "FAIL"
            $handshakeReason = "TCP 无法连接 127.0.0.1:$($session.Port)：MCP server 未监听"
            $handshakeErrorClass = "MCP_CONNECTION_ERROR"
        }
        else {
            $initialize = Invoke-McpJsonRpc -Endpoint $endpoint -Method "initialize" -Params ([ordered]@{
                    protocolVersion = "2025-06-18"
                    capabilities    = [ordered]@{}
                    clientInfo      = [ordered]@{ name = "matlab-agent-skills-probe"; version = "1.0.0" }
                }) -ApiKey $sessionCredential -AuthHeaderName $AuthHeaderName -TimeoutSeconds $TimeoutSeconds -SkipTlsValidation:$SkipTlsValidation -Id 1

            $handshakeMetrics["httpStatus"] = $initialize.StatusCode
            $handshakeMetrics["durationMs"] = $initialize.DurationMs
            if ($initialize.Ok -and $null -ne $initialize.Json -and ($initialize.Json.PSObject.Properties.Name -contains "result")) {
                $resultNode = $initialize.Json.result
                if ($resultNode.PSObject.Properties.Name -contains "protocolVersion") { $handshakeMetrics.protocolVersion = "$($resultNode.protocolVersion)" }
                if ($resultNode.PSObject.Properties.Name -contains "serverInfo") {
                    $handshakeMetrics.serverName = "$($resultNode.serverInfo.name)"
                    $handshakeMetrics["serverVersion"] = "$($resultNode.serverInfo.version)"
                }
                $handshakeStatus = "PASS"
                $handshakeReason = $null
            }
            else {
                $handshakeStatus = "FAIL"
                $handshakeErrorClass = "MCP_CONNECTION_ERROR"
                # 诊断信息要同时保留传输层与协议层证据：401/403 的响应体里常常也带 JSON-RPC error，
                # 只记录其中一条会丢掉鉴权失败的原始状态码，审计时无法区分"密码错"和"服务没起"。
                $reasonParts = New-Object System.Collections.Generic.List[string]
                if ($initialize.StatusCode -and ($initialize.StatusCode -lt 200 -or $initialize.StatusCode -ge 300)) {
                    $reasonParts.Add("HTTP $($initialize.StatusCode)")
                }
                if ($initialize.Json -and $initialize.Json.PSObject.Properties.Name -contains "error") {
                    $reasonParts.Add("JSON-RPC 返回错误：$($initialize.Json.error | ConvertTo-Json -Compress -Depth 6)")
                }
                if ($initialize.Error) {
                    $reasonParts.Add("传输层错误：$($initialize.Error)")
                }
                if ($reasonParts.Count -eq 0) {
                    $reasonParts.Add("initialize 响应中既无 result 也无 error，响应体：$($initialize.Body)")
                }
                $handshakeReason = ($reasonParts -join "；")
            }
        }
    }

    $report = Add-AcceptanceCheck -Report $report -Id "mcp.protocol-handshake" -Title "MCP 协议握手（initialize）" -Level "L2" `
        -Status $handshakeStatus -Reason $handshakeReason -ErrorClass $handshakeErrorClass -Command $handshakeCommand -Metrics $handshakeMetrics

    # ---------------- 阶段 4：只读命令真实执行 ----------------
    $tools = @()
    $readStatus = "SKIP"
    $readReason = "阶段 3 未通过，无法执行只读命令"
    $readMetrics = [ordered]@{ tool = $null; toolCount = 0; output = $null; expectedPattern = "\d+\.\d+" }
    $readErrorClass = $null
    $readCommand = $null

    if ($handshakeStatus -eq "PASS") {
        $list = Invoke-McpJsonRpc -Endpoint $endpoint -Method "tools/list" -ApiKey $sessionCredential -AuthHeaderName $AuthHeaderName -TimeoutSeconds $TimeoutSeconds -SkipTlsValidation:$SkipTlsValidation -Id 2
        if ($list.Ok -and $null -ne $list.Json -and $list.Json.PSObject.Properties.Name -contains "result" -and
            $list.Json.result.PSObject.Properties.Name -contains "tools") {
            $tools = @($list.Json.result.tools)
            $readMetrics.toolCount = $tools.Count
            $toolNames = @($tools | ForEach-Object { "$($_.name)" })
            $readMetrics["tools"] = $toolNames

            $selected = $null
            if ($EvalTool) {
                $selected = $toolNames | Where-Object { $_ -eq $EvalTool } | Select-Object -First 1
            }
            else {
                $selected = $toolNames | Where-Object { $_ -match '(?i)(evaluate|execute|run).*(matlab|code)|(matlab|code).*(evaluate|execute|run)' } | Select-Object -First 1
                if (-not $selected) {
                    $selected = $toolNames | Where-Object { $_ -match '(?i)evaluate|execute' } | Select-Object -First 1
                }
            }

            if (-not $selected) {
                $readReason = "服务端未暴露可识别的代码执行工具；实际工具列表：$($toolNames -join ', ')。用 -EvalTool 显式指定。"
            }
            else {
                $readMetrics.tool = $selected
                $readCommand = "POST $endpoint (tools/call $selected)"
                $callParams = [ordered]@{ name = $selected; arguments = [ordered]@{ $EvalToolArgument = "disp(version)" } }
                $call = Invoke-McpJsonRpc -Endpoint $endpoint -Method "tools/call" -Params $callParams -ApiKey $sessionCredential -AuthHeaderName $AuthHeaderName -TimeoutSeconds $TimeoutSeconds -SkipTlsValidation:$SkipTlsValidation -Id 3
                $readMetrics["durationMs"] = $call.DurationMs
                if ($call.Ok -and $null -ne $call.Json -and $call.Json.PSObject.Properties.Name -contains "result") {
                    $text = Get-McpToolText -Result $call.Json.result
                    $readMetrics.output = $text
                    if ($text -match '\d+\.\d+') {
                        $readStatus = "PASS"
                        $readReason = $null
                    }
                    else {
                        $readStatus = "FAIL"
                        $readErrorClass = "VALIDATION_ERROR"
                        $readReason = "执行结果中未找到版本号，输出：$($text.Substring(0, [Math]::Min(200, $text.Length)))"
                    }
                }
                else {
                    $readStatus = "FAIL"
                    $readErrorClass = "MCP_CONNECTION_ERROR"
                    $readReason = "tools/call 失败：$(if ($call.Json -and $call.Json.PSObject.Properties.Name -contains 'error') { $call.Json.error | ConvertTo-Json -Compress } else { $call.Error })"
                }
            }
        }
        else {
            $readStatus = "FAIL"
            $readErrorClass = "MCP_CONNECTION_ERROR"
            $readReason = "tools/list 失败：$(if ($list.Json -and $list.Json.PSObject.Properties.Name -contains 'error') { $list.Json.error | ConvertTo-Json -Compress } else { $list.Error })"
        }
    }

    $report = Add-AcceptanceCheck -Report $report -Id "mcp.readonly-exec" -Title "只读命令真实执行" -Level "L3" `
        -Status $readStatus -Reason $readReason -ErrorClass $readErrorClass -Command $readCommand -Metrics $readMetrics

    # ---------------- 阶段 5：文件写入与读取 ----------------
    $ioStatus = "SKIP"
    $ioReason = "上游阶段未通过（handshake=$handshakeStatus, readonly=$readStatus），未执行文件读写验证"
    $ioMetrics = [ordered]@{ directory = $IoProbeDirectory; token = $null; echoed = $null; hostVerified = $false }
    $ioErrorClass = $null
    $ioCommand = $null
    $ioToolName = $readMetrics.tool

    if ($SkipStage5) {
        $ioReason = "调用方要求跳过阶段 5"
    }
    elseif ($readStatus -eq "PASS" -and $ioToolName) {
        if (-not (Test-Path -LiteralPath $IoProbeDirectory)) {
            New-Item -ItemType Directory -Force -Path $IoProbeDirectory | Out-Null
        }
        $token = [guid]::NewGuid().ToString("N")
        $probeFile = Join-Path $IoProbeDirectory "io_probe_$token.txt"
        $ioMetrics.token = $token
        $ioMetrics["file"] = $probeFile

        $code = "p = '$probeFile'; fid = fopen(p, 'w'); fprintf(fid, '%s', '$token'); fclose(fid); s = fileread(p); disp(s);"
        $ioCommand = "POST $endpoint (tools/call $ioToolName, write+read)"
        $callParams = [ordered]@{ name = $ioToolName; arguments = [ordered]@{ $EvalToolArgument = $code } }
        $call = Invoke-McpJsonRpc -Endpoint $endpoint -Method "tools/call" -Params $callParams -ApiKey $sessionCredential -AuthHeaderName $AuthHeaderName -TimeoutSeconds $TimeoutSeconds -SkipTlsValidation:$SkipTlsValidation -Id 4

        if ($call.Ok -and $null -ne $call.Json -and $call.Json.PSObject.Properties.Name -contains "result") {
            $text = Get-McpToolText -Result $call.Json.result
            $ioMetrics.echoed = $text
            $echoOk = $text -match [regex]::Escape($token)

            $hostOk = $false
            if (Test-Path -LiteralPath $probeFile) {
                $hostContent = (Get-Content -Raw -LiteralPath $probeFile).Trim()
                $hostOk = ($hostContent -eq $token)
                $ioMetrics.hostVerified = $true
                $ioMetrics["hostContent"] = $hostContent
                $ioMetrics["fileBytes"] = (Get-Item -LiteralPath $probeFile).Length
            }

            if (-not $echoOk) {
                $ioStatus = "FAIL"
                $ioErrorClass = "VALIDATION_ERROR"
                $ioReason = "回读内容与写入令牌不一致，期望 $token"
            }
            elseif (-not $hostOk) {
                $ioStatus = "FAIL"
                $ioErrorClass = "VALIDATION_ERROR"
                $ioReason = "宿主机未观察到一致的隔离文件（写到了别处或未真正落盘）：$probeFile"
            }
            else {
                $ioStatus = "PASS"
                $ioReason = $null
            }
        }
        else {
            $ioStatus = "FAIL"
            $ioErrorClass = "MCP_CONNECTION_ERROR"
            $ioReason = "文件读写 tools/call 失败：$(if ($call.Json -and $call.Json.PSObject.Properties.Name -contains 'error') { $call.Json.error | ConvertTo-Json -Compress } else { $call.Error })"
        }
    }

    $report = Add-AcceptanceCheck -Report $report -Id "mcp.file-io" -Title "隔离目录文件写入与回读" -Level "L4" `
        -Status $ioStatus -Reason $ioReason -ErrorClass $ioErrorClass -Command $ioCommand -Metrics $ioMetrics `
        -ArtifactPaths @($IoProbeDirectory)

    # 若阶段 4 真实执行成功，则许可证事实上已被证明（没有可用许可无法执行 MATLAB 代码）。
    # 这里把“未单独验证许可证”的 SKIP 升级为 PASS，并注明证据来源，避免整体状态被无谓拖成 SKIP。
    if ($readStatus -eq "PASS") {
        for ($index = 0; $index -lt @($report.checks).Count; $index++) {
            $check = $report.checks[$index]
            if ($check.id -eq "mcp.matlab-license" -and $check.status -eq "SKIP") {
                $check.status = "PASS"
                $check.reason = $null
                $check.metrics = [pscustomobject][ordered]@{
                    provenBy = "mcp.readonly-exec"
                    note     = "通过共享会话真实执行 disp(version)，证明 MATLAB 已授权且可运行"
                }
                break
            }
        }
    }

    $report.limitations = @(
        "阶段 1b（许可证）默认 SKIP：只有指定 -VerifyLicense 时才启动 MATLAB 校验。",
        "阶段 3~5 依赖真实 MCP server 的实现细节（端点路径、鉴权头、工具名）；未匹配时输出 FAIL/SKIP 并给出原因，不会偽造 PASS。"
    )

    return Update-AcceptanceSummary -Report $report
}

Export-ModuleMember -Function *
