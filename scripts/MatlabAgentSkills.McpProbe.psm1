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

function ConvertFrom-JsonElement {
    <#
    .SYNOPSIS
    把 System.Text.Json 元素转成 PowerShell 对象，保留键名大小写。
    .DESCRIPTION
    仅用于 PowerShell 7 缺少 System.Web.Extensions 时的回退路径。对象一律转成
    Ordinal 字典，因为 PSCustomObject 的属性名不区分大小写，会把 "C:/Windows"
    与 "C:/WINDOWS" 合并成一个属性。
    #>
    param([System.Text.Json.JsonElement]$Element)

    switch ($Element.ValueKind.ToString()) {
        'Object' {
            $dictionary = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
            foreach ($property in $Element.EnumerateObject()) {
                $dictionary[$property.Name] = ConvertFrom-JsonElement -Element $property.Value
            }
            return , $dictionary
        }
        'Array' {
            $items = New-Object System.Collections.Generic.List[object]
            foreach ($item in $Element.EnumerateArray()) {
                $items.Add((ConvertFrom-JsonElement -Element $item))
            }
            return , $items.ToArray()
        }
        'String' { return $Element.GetString() }
        'Number' {
            $asLong = [long]0
            if ($Element.TryGetInt64([ref]$asLong)) { return $asLong }
            return $Element.GetDouble()
        }
        'True' { return $true }
        'False' { return $false }
        default { return $null }
    }
}

function ConvertFrom-JsonCaseSensitive {
    <#
    .SYNOPSIS
    按大小写敏感语义解析 JSON。
    .DESCRIPTION
    Windows PowerShell 5.1 的 ConvertFrom-Json 用大小写不敏感的字典，遇到同时存在
    "C:/Windows" 与 "C:/WINDOWS" 这类键会直接抛“重复的键”，把合法 JSON 误判为损坏。
    这里优先用 JavaScriptSerializer（字典大小写敏感）；PowerShell 7 没有
    System.Web.Extensions，改用 System.Text.Json 构造同样大小写敏感的字典。
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
        try {
            $document = [System.Text.Json.JsonDocument]::Parse($Text)
        }
        catch {
            return ($Text | ConvertFrom-Json)
        }
        try {
            return , (ConvertFrom-JsonElement -Element $document.RootElement)
        }
        finally {
            $document.Dispose()
        }
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

function Test-McpLoopbackHostName {
    <#
    .SYNOPSIS
    判断主机名是否为回环（127.0.0.0/8、localhost、::1）。
    .DESCRIPTION
    证书固定只对回环端点生效。把这个判断做成独立函数而不是内联正则，
    是因为误把远端主机当成回环就等于对公网关闭了证书校验。
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$HostName)

    if ([string]::IsNullOrWhiteSpace($HostName)) { return $false }
    $value = $HostName.Trim().ToLowerInvariant()
    # IPv6 字面量在 URL 里带方括号。
    if ($value.StartsWith("[") -and $value.EndsWith("]")) { $value = $value.Substring(1, $value.Length - 2) }
    if ($value -eq "localhost") { return $true }
    if ($value -eq "::1" -or $value -eq "0:0:0:0:0:0:0:1") { return $true }
    if (-not $value.StartsWith("127.")) { return $false }

    $octets = $value.Split(".")
    if ($octets.Count -ne 4) { return $false }
    foreach ($octet in $octets) {
        $number = 0
        if (-not [int]::TryParse($octet, [ref]$number)) { return $false }
        if ($number -lt 0 -or $number -gt 255) { return $false }
    }
    return $true
}

function Get-McpCertificateThumbprint {
    <#
    .SYNOPSIS
    读取会话描述符里声明的证书指纹（公钥），读不出来时返回 $null。
    .DESCRIPTION
    MATLAB 的共享会话用自签名证书（实测 R2026a：CN=127.0.0.1 且没有 SAN），
    系统信任链必然拒绝它。正确做法不是关掉校验，而是只信任会话自己声明的那张证书。
    这里只接受公钥证书：文本里出现 PRIVATE KEY 一律拒绝，避免把私钥当证书加载进进程。
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$CertificatePath)

    if ([string]::IsNullOrWhiteSpace($CertificatePath)) { return $null }
    try { $fullPath = [System.IO.Path]::GetFullPath($CertificatePath) } catch { return $null }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { return $null }

    $raw = $null
    try { $raw = [System.IO.File]::ReadAllText($fullPath) } catch { return $null }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    if ($raw -match "PRIVATE KEY") { return $null }

    $certificate = $null
    try {
        # 必须用 ::new() 而不是 New-Object：New-Object 会把 byte[] 拆成构造参数列表，
        # Windows PowerShell 5.1 因此在"证书存在但解析失败"上返回 $null。
        if ($raw -match "-----BEGIN (CERTIFICATE|X509)-----") {
            $body = ($raw -replace "-----[^-]+-----", "") -replace "\s", ""
            $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
                [System.Convert]::FromBase64String($body))
        }
        else {
            $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($fullPath)
        }
        if ($null -eq $certificate -or [string]::IsNullOrWhiteSpace($certificate.Thumbprint)) { return $null }
        return ([string]$certificate.Thumbprint).ToUpperInvariant()
    }
    catch {
        return $null
    }
    finally {
        if ($null -ne $certificate) { try { $certificate.Dispose() } catch { } }
    }
}

function New-McpCertificatePinValidator {
    <#
    .SYNOPSIS
    构造"仅回环 + 指纹固定"的服务端证书校验回调。
    .DESCRIPTION
    放行条件必须同时满足：目标主机是回环、提供了固定指纹、服务端呈现的叶子证书
    指纹与固定指纹逐字一致。链错误与名称不匹配都在固定成功时忽略——
    因为固定的是会话声明的那张确定证书，这比"能对上名字"更强；
    MATLAB 的证书没有 SAN，若坚持名称匹配就只能关掉整进程证书校验，
    那是本项目明确不接受的做法。
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string]$PinnedThumbprint,
        [AllowNull()][string]$HostName
    )

    $pin = ""
    if ($PinnedThumbprint) { $pin = ([string]$PinnedThumbprint).Replace(" ", "").Trim().ToUpperInvariant() }
    $loopback = Test-McpLoopbackHostName -HostName $HostName

    $validator = {
        param($Sender, $Certificate, $Chain, $SslPolicyErrors)
        if (-not $loopback) { return $false }
        if ([string]::IsNullOrWhiteSpace($pin)) { return $false }
        if ($null -eq $Certificate) { return $false }
        $observed = ""
        try { $observed = "$($Certificate.GetCertHashString())".ToUpperInvariant() } catch { return $false }
        if ([string]::IsNullOrWhiteSpace($observed)) { return $false }
        return [string]::Equals($observed, $pin, [System.StringComparison]::OrdinalIgnoreCase)
    }
    return $validator.GetNewClosure()
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
        [string]$PinnedCertificateThumbprint,
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
        TlsMode    = $null
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

    $endpointHost = $null
    try { $endpointHost = ([System.Uri]$Endpoint).Host } catch { $endpointHost = $null }

    # 优先级是固定 > 跳过：能对上会话声明的证书就绝不需要关掉校验。
    # 反过来说，-SkipTlsValidation 也不能把一次"指纹对不上"洗成"连接成功"。
    if ($PinnedCertificateThumbprint -and (Test-McpLoopbackHostName -HostName $endpointHost)) {
        $result.TlsMode = "pinned"
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback =
            (New-McpCertificatePinValidator -PinnedThumbprint $PinnedCertificateThumbprint -HostName $endpointHost)
    }
    elseif ($PinnedCertificateThumbprint) {
        $result.TlsMode = "system-default"
    }
    elseif ($SkipTlsValidation) {
        $result.TlsMode = "insecure-skip"
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { param($a, $b, $c, $d) return $true }
    }
    else {
        $result.TlsMode = "system-default"
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

function Resolve-McpStdioServer {
    <#
    .SYNOPSIS
    只定位本机已有、且能通过固定发布清单校验的 matlab-mcp-server，绝不下载。

    .DESCRIPTION
    stdio 是唯一被官方支持的集成路径（直连 connector 的 POST /mcp 实测恒 403），
    所以安装后的 Skill 必须能找到这个二进制。查找顺序是显式的：
    参数 -ServerExe -> 环境变量 MATLAB_MCP_SERVER -> 客户端注册里的 command -> Core 的固定候选路径。
    每一条都必须过 Resolve-McpServerExecutable 的清单校验；
    对不上清单就是"可能被替换"，直接拒绝，不允许"本地有就用"。
    这里绝不触发下载：探测脚本是只读的，把下载二进制动作用户执行路径是越权。
    #>
    [CmdletBinding()]
    param(
        [string]$ServerExe,
        [AllowNull()]$Registrations = $null
    )

    if (-not (Get-Command Resolve-McpServerExecutable -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $PSScriptRoot "MatlabAgentSkills.Core.psm1") -Force -DisableNameChecking -ErrorAction SilentlyContinue
    }

    $searched = New-Object System.Collections.Generic.List[object]
    if (-not (Get-Command Resolve-McpServerExecutable -ErrorAction SilentlyContinue)) {
        return [pscustomobject][ordered]@{
            Found    = $false
            Reason   = "缺少 MatlabAgentSkills.Core.psm1，无法校验 MCP server 二进制完整性"
            Searched = $searched.ToArray()
        }
    }

    $candidates = New-Object System.Collections.Generic.List[object]
    if ($ServerExe) {
        # 操作方显式指定了二进制，就只用这一个：校验不通过时不能悄悄换成别的文件，
        # 否则"我指定了 A"和"实际执行了 B"会在报告里看不出来。
        $candidates.Add([pscustomobject]@{ Path = $ServerExe; Origin = "parameter" })
    }
    else {
        if ($env:MATLAB_MCP_SERVER) {
            $candidates.Add([pscustomobject]@{ Path = $env:MATLAB_MCP_SERVER; Origin = "env:MATLAB_MCP_SERVER" })
        }
        foreach ($reg in @($Registrations)) {
            if ($null -eq $reg) { continue }
            if ($reg.command -and $reg.commandExists) {
                $candidates.Add([pscustomobject]@{ Path = [string]$reg.command; Origin = "registration:$($reg.client)" })
            }
        }
        # Core 的固定候选（相对本模块的 ../bin 等）；不含当前工作目录，避免同名攻击文件。
        $candidates.Add([pscustomobject]@{ Path = $null; Origin = "core-candidates" })
    }

    foreach ($item in $candidates) {
        $path = $item.Path
        if ($null -ne $path -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $searched.Add([ordered]@{ origin = $item.Origin; path = $path; result = "missing" })
            continue
        }
        try {
            $server = if ($path) {
                Resolve-McpServerExecutable -Hint $path -ScriptRoot $PSScriptRoot -NoDownload
            }
            else {
                Resolve-McpServerExecutable -ScriptRoot $PSScriptRoot -NoDownload
            }
        }
        catch {
            $searched.Add([ordered]@{
                origin = $item.Origin
                path   = $path
                result = "rejected"
                reason = ($_.Exception.Message -replace "\s+", " ")
            })
            continue
        }
        if (-not $server -or -not $server.Path -or -not (Test-Path -LiteralPath $server.Path -PathType Leaf)) {
            $searched.Add([ordered]@{ origin = $item.Origin; path = $path; result = "not-found" })
            continue
        }
        $searched.Add([ordered]@{
            origin    = $item.Origin
            path      = $server.Path
            result    = "accepted"
            integrity = $server.IntegrityStatus
            verified  = [bool]$server.Verified
        })
        return [pscustomobject][ordered]@{
            Found           = $true
            Path            = $server.Path
            Origin          = $item.Origin
            ReleaseTag      = $server.ReleaseTag
            IntegrityStatus = $server.IntegrityStatus
            Verified        = [bool]$server.Verified
            Sha256          = $server.Sha256
            Searched        = $searched.ToArray()
        }
    }

    return [pscustomobject][ordered]@{
        Found    = $false
        Reason   = "本机没有可用且通过清单校验的 matlab-mcp-server（不下载）；已尝试：$((@($searched | ForEach-Object { $_.origin })) -join ', ')"
        Searched = $searched.ToArray()
    }
}

function Start-McpStdioChannel {
    <#
    .SYNOPSIS
    以官方 server 建立 stdio 通道；返回会话与需要在关闭时还原的代理状态。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerExe,
        [ValidateSet("auto", "existing", "new")][string]$SessionMode = "auto",
        [string]$MatlabRoot,
        [string]$WorkingDirectory = (Get-Location).Path,
        [string]$Label = "mcp-probe-stdio"
    )

    if (-not (Get-Command Start-McpStdioServer -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $PSScriptRoot "MatlabAgentSkills.McpStdio.psm1") -Force -DisableNameChecking -ErrorAction SilentlyContinue
    }
    if (-not (Get-Command Start-McpStdioServer -ErrorAction SilentlyContinue)) {
        throw "缺少 MatlabAgentSkills.McpStdio.psm1：Skill 资源不完整，无法建立 stdio 通道"
    }

    $arguments = "--matlab-session-mode=$SessionMode"
    # existing 模式下会话已由 MATLAB 共享，官方 server 会拒绝 --matlab-root / --matlab-display-mode。
    if ($SessionMode -ne "existing") {
        if ($MatlabRoot) { $arguments += " --matlab-root=`"$MatlabRoot`"" }
        $arguments += " --matlab-display-mode=nodesktop"
    }
    $arguments += " --disable-telemetry=true"

    # 官方 server 是 Go 程序，会读 HTTPS_PROXY；没有 NO_PROXY 时它把 localhost 也发给代理，
    # 表现为 403 / context deadline exceeded。只在子进程期间生效，关闭通道时还原。
    $proxyState = Enable-McpLocalhostProxyBypass
    try {
        $session = Start-McpStdioServer -ServerExe $ServerExe -ServerArgumentLine $arguments `
            -WorkingDirectory $WorkingDirectory -Label $Label
    }
    catch {
        Restore-McpProxyEnvironment -State $proxyState
        throw
    }

    return [pscustomobject][ordered]@{
        Session     = $session
        ProxyState  = $proxyState
        Arguments   = $arguments
        ProcessId   = $session.Process.Id
    }
}

function Stop-McpStdioChannel {
    <# .SYNOPSIS 关闭 stdio 通道并还原代理环境；返回收尾信息供报告记录。 #>
    param(
        $Channel,
        [int]$GraceSeconds = 3
    )

    if ($null -eq $Channel) { return $null }
    try {
        $info = Stop-McpStdioServer -Session $Channel.Session -GraceSeconds $GraceSeconds
    }
    catch {
        $info = [pscustomobject]@{ Exited = $false; ExitCode = $null; Forced = $false; StdErrTail = "关闭 stdio 通道时出错：$($_.Exception.Message)" }
    }
    Restore-McpProxyEnvironment -State $Channel.ProxyState
    return $info
}

function Invoke-McpTransportRequest {
    <#
    .SYNOPSIS
    在与传输方式无关的接口上发一条 JSON-RPC 请求，返回统一结构。
    .DESCRIPTION
    阶段 3~5 的判定只关心 result / error / 耗时，不应该关心底层是 HTTPS 还是 stdio。
    stdio 分支把 Send-McpStdioRequest 的 outcome 规整成与 Invoke-McpJsonRpc 同形的对象，
    这样两条通道共用同一套断言，也就无法出现"换传输就顺手放宽断言"。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Channel,
        [Parameter(Mandatory)][string]$Method,
        [object]$Params = $null,
        [switch]$Notification,
        [int]$Id = 1
    )

    if ($Channel.Kind -eq "stdio") {
        $outcome = Send-McpStdioRequest -Session $Channel.Session -Method $Method -Params $Params `
            -Notification:$Notification -TimeoutSeconds $Channel.TimeoutSeconds
        $json = $null
        if ($null -ne $outcome.Result -or $outcome.Error) {
            $node = [ordered]@{}
            if ($null -ne $outcome.Result) { $node["result"] = $outcome.Result }
            if ($outcome.Error) { $node["error"] = $outcome.Error }
            $json = [pscustomobject]$node
        }
        return [pscustomobject][ordered]@{
            Ok           = [bool]$outcome.Ok
            StatusCode   = $null
            Body         = ""
            Json         = $json
            Error        = $outcome.Error
            ErrorClass   = $(if ($outcome.Ok) { $null } else { "MCP_CONNECTION_ERROR" })
            DurationMs   = $outcome.DurationMs
            TlsMode      = "stdio"
            TimedOut     = [bool]$outcome.TimedOut
            StdErrTail   = $outcome.StdErrTail
            SkippedLines = $outcome.SkippedLines
        }
    }

    return Invoke-McpJsonRpc -Endpoint $Channel.Endpoint -Method $Method -Params $Params `
        -ApiKey $Channel.ApiKey -AuthHeaderName $Channel.AuthHeaderName `
        -TimeoutSeconds $Channel.TimeoutSeconds -PinnedCertificateThumbprint $Channel.PinnedThumbprint `
        -SkipTlsValidation:$Channel.SkipTlsValidation -Id $Id
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
        # 传输方式：stdio 走官方 matlab-mcp-server（实测唯一可用路径）；
        # https 直连 connector 仅作观测（R2026a 上 POST /mcp 恒 403）；
        # auto 优先 stdio，找不到通过清单校验的二进制时才退回 https 并记录原因。
        [ValidateSet("auto", "stdio", "https")][string]$Transport = "auto",
        [string]$ServerExe = "",
        [ValidateSet("auto", "existing", "new")][string]$SessionMode = "auto",
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
    # 通道优先级：stdio（官方 server，实测唯一可用路径）> HTTPS 直连（仅作观测）。
    $channel = $null
    $stdioChannel = $null
    $stdioServer = $null
    $transportFailure = $null

    if ($Transport -ne "https") {
        $stdioServer = Resolve-McpStdioServer -ServerExe $ServerExe -Registrations $registrations
        if ($stdioServer.Found) {
            try {
                $stdioMatlabRoot = $null
                if ($matlabExe) { $stdioMatlabRoot = Split-Path -Parent (Split-Path -Parent $matlabExe) }
                $stdioChannel = Start-McpStdioChannel -ServerExe $stdioServer.Path -SessionMode $SessionMode `
                    -MatlabRoot $stdioMatlabRoot -WorkingDirectory (Split-Path -Parent $IoProbeDirectory)
                # MATLAB 首次连接要 30 秒以上，探测默认值（20s）会把正常会话判成超时。
                $channel = [pscustomobject][ordered]@{
                    Kind           = "stdio"
                    Session        = $stdioChannel.Session
                    TimeoutSeconds = [Math]::Max($TimeoutSeconds, 120)
                }
            }
            catch { $transportFailure = "stdio 通道启动失败：$($_.Exception.Message)" }
        }
        else { $transportFailure = $stdioServer.Reason }
    }

    $endpoint = $null
    $sessionCredential = $null
    $pinnedThumbprint = $null
    $handshakeSkipReason = $null

    if ($null -eq $channel) {
        if ($Transport -eq "stdio") {
            # 显式要求 stdio 时不退回 HTTPS：否则报告会把自己造成的失败
            # 说成"连接器返回 403"，掩盖真实原因。
            $handshakeSkipReason = "无法建立 stdio 通道：$transportFailure"
        }
        elseif ($sessionStatus -ne "PASS") {
            $handshakeSkipReason = "阶段 2 未给出可用会话（$sessionStatus）：$sessionReason"
            if ($Transport -eq "auto") { $handshakeSkipReason += "；stdio 通道亦不可用（$transportFailure）" }
        }
        else {
            $endpoint = "${Scheme}://127.0.0.1:$($session.Port)$EndpointPath"
            $sessionCredential = Get-McpSessionCredential -SessionFile $SessionFile
            # 端点是回环，证书又是会话描述符自己声明的那张，因此默认按指纹固定；
            # 自签名证书走系统信任链必然被拒，而 -SkipTlsValidation 会把整进程的校验关掉。
            $pinnedThumbprint = Get-McpCertificateThumbprint -CertificatePath $session.Certificate
            if (-not $pinnedThumbprint -and -not $SkipTlsValidation) {
                $handshakeSkipReason = "会话证书无法解析出指纹（$($session.Certificate)）：不发起未固定证书的 HTTPS 握手；确认需要时可显式加 -SkipTlsValidation"
            }
            else {
                $channel = [pscustomobject][ordered]@{
                    Kind              = "https"
                    Endpoint          = $endpoint
                    ApiKey            = $sessionCredential
                    AuthHeaderName    = $AuthHeaderName
                    TimeoutSeconds    = $TimeoutSeconds
                    PinnedThumbprint  = $pinnedThumbprint
                    SkipTlsValidation = [bool]$SkipTlsValidation
                }
            }
        }
    }

    $handshakeReady = ($null -ne $channel)

    $handshakeStatus = "SKIP"
    $handshakeReason = $handshakeSkipReason
    $handshakeMetrics = [ordered]@{
        transport       = $(if ($channel) { $channel.Kind } else { $null })
        transportNote   = $transportFailure
        serverExe       = $(if ($stdioServer) { $stdioServer.Path } else { $null })
        serverOrigin    = $(if ($stdioServer) { $stdioServer.Origin } else { $null })
        serverIntegrity = $(if ($stdioServer) { $stdioServer.IntegrityStatus } else { $null })
        serverVerified  = $(if ($stdioServer) { [bool]$stdioServer.Verified } else { $null })
        serverRelease   = $(if ($stdioServer) { $stdioServer.ReleaseTag } else { $null })
        serverSha256    = $(if ($stdioServer) { $stdioServer.Sha256 } else { $null })
        sessionMode     = $SessionMode
        endpoint        = $endpoint
        tcpReachable    = $false
        protocolVersion = $null
        serverName      = $null
        tlsMode         = $null
        pinnedThumbprint = $pinnedThumbprint
    }
    $handshakeErrorClass = $null
    $handshakeCommand = $null

    if ($handshakeReady -and $channel.Kind -eq "https") {
        $handshakeMetrics.tcpReachable = Test-TcpEndpoint -ComputerName "127.0.0.1" -Port $session.Port -TimeoutMs ([Math]::Max(1000, $TimeoutSeconds * 250))
        if (-not $handshakeMetrics.tcpReachable) {
            $handshakeStatus = "FAIL"
            $handshakeReason = "TCP 无法连接 127.0.0.1:$($session.Port)：MCP server 未监听"
            $handshakeErrorClass = "MCP_CONNECTION_ERROR"
            $handshakeReady = $false
        }
    }

    if ($handshakeReady) {
        $handshakeCommand = $(if ($channel.Kind -eq "stdio") { "stdio: $($channel.Session.Exe) $($channel.Session.ArgumentLine) -> initialize" } else { "POST $endpoint (initialize)" })
        $initialize = Invoke-McpTransportRequest -Channel $channel -Method "initialize" -Params ([ordered]@{
                protocolVersion = "2025-06-18"
                capabilities    = [ordered]@{}
                clientInfo      = [ordered]@{ name = "matlab-agent-skills-probe"; version = "1.0.0" }
            }) -Id 1

        $handshakeMetrics["httpStatus"] = $initialize.StatusCode
        $handshakeMetrics["durationMs"] = $initialize.DurationMs
        $handshakeMetrics["tlsMode"] = $initialize.TlsMode
        $handshakeMetrics["skippedLines"] = $initialize.SkippedLines
        if ($initialize.Ok -and $null -ne $initialize.Json -and ($initialize.Json.PSObject.Properties.Name -contains "result")) {
            $resultNode = $initialize.Json.result
            if ($resultNode.PSObject.Properties.Name -contains "protocolVersion") { $handshakeMetrics.protocolVersion = "$($resultNode.protocolVersion)" }
            if ($resultNode.PSObject.Properties.Name -contains "serverInfo") {
                $handshakeMetrics.serverName = "$($resultNode.serverInfo.name)"
                $handshakeMetrics["serverVersion"] = "$($resultNode.serverInfo.version)"
            }
            $handshakeStatus = "PASS"
            $handshakeReason = $null
            if ($channel.Kind -eq "stdio") {
                # MCP 规范要求客户端在握手后发送 initialized 通知；官方 server 在收到前不接单条 tools/call。
                $null = Invoke-McpTransportRequest -Channel $channel -Method "notifications/initialized" -Notification
            }
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
            if ($initialize.StdErrTail) { $reasonParts.Add("stderr：$($initialize.StdErrTail)") }
            if ($reasonParts.Count -eq 0) {
                $reasonParts.Add("initialize 响应中既无 result 也无 error，响应体：$($initialize.Body)")
            }
            $handshakeReason = ($reasonParts -join "；")
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
        $list = Invoke-McpTransportRequest -Channel $channel -Method "tools/list" -Id 2
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
                $readCommand = $(if ($channel.Kind -eq "stdio") { "stdio: tools/call $selected" } else { "POST $endpoint (tools/call $selected)" })
                $callParams = [ordered]@{ name = $selected; arguments = [ordered]@{ $EvalToolArgument = "disp(version)" } }
                $call = Invoke-McpTransportRequest -Channel $channel -Method "tools/call" -Params $callParams -Id 3
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
        $ioCommand = $(if ($channel.Kind -eq "stdio") { "stdio: tools/call $ioToolName (write+read)" } else { "POST $endpoint (tools/call $ioToolName, write+read)" })
        $callParams = [ordered]@{ name = $ioToolName; arguments = [ordered]@{ $EvalToolArgument = $code } }
        $call = Invoke-McpTransportRequest -Channel $channel -Method "tools/call" -Params $callParams -Id 4

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

    # 通道必须收尾：stdio 子进程若留在机器上，下一次探测会连到上一轮的会话，
    # 报告里的 PID/端口就对不上任何一次真实执行。
    $channelShutdown = $null
    if ($stdioChannel) { $channelShutdown = Stop-McpStdioChannel -Channel $stdioChannel }

    $transportLimitation = if ($channelShutdown) {
        "stdio 通道已在本探针结束时关闭（exit=$($channelShutdown.ExitCode), forced=$([bool]$channelShutdown.Forced)）；本次探测未下载任何二进制。"
    }
    elseif ($Transport -eq "https") { "仅使用 HTTPS 直连（-Transport https）；未启动官方 matlab-mcp-server 子进程。" }
    else { "未建立 stdio 通道：$transportFailure" }

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
        "阶段 3~5 依赖真实 MCP server 的实现细节（端点路径、鉴权头、工具名）；未匹配时输出 FAIL/SKIP 并给出原因，不会偽造 PASS。",
        $transportLimitation
    )

    return Update-AcceptanceSummary -Report $report
}

Export-ModuleMember -Function *
