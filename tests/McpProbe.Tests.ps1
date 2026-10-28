<#
.SYNOPSIS
MCP 分级探测测试：用本地假服务端验证 PASS / FAIL / SKIP 判定，不需要 MATLAB。

.DESCRIPTION
重点验证“配置存在 ≠ 真实连接”：
- 只有会话文件、端口不可达时，握手必须 FAIL，只读执行必须 SKIP；
- 服务端不暴露执行工具时，只读执行必须 SKIP 并保留工具列表；
- 回读内容不一致时，文件读写必须 FAIL；
- 握手成功且工具可用时，五阶段才允许全部 PASS。
#>

$helpers = Join-Path $PSScriptRoot "helpers\TestSandbox.ps1"
. $helpers

$repoRoot = Get-TestRepositoryRoot
Import-TestModule -Name "MatlabAgentSkills.Acceptance.psm1" -RepositoryRoot $repoRoot | Out-Null
Import-TestModule -Name "MatlabAgentSkills.Execution.psm1" -RepositoryRoot $repoRoot | Out-Null
Import-TestModule -Name "MatlabAgentSkills.McpProbe.psm1" -RepositoryRoot $repoRoot | Out-Null

$fakeServer = Join-Path $PSScriptRoot "helpers\FakeMcpServer.ps1"
$fakeStdioServerPath = Join-Path $PSScriptRoot "helpers\FakeMcpStdioServer.ps1"

function Get-Check {
    param($Report, [string]$Id)
    return ($Report.checks | Where-Object { $_.id -eq $Id } | Select-Object -First 1)
}

function Invoke-Probe {
    param(
        [Parameter(Mandatory)][string]$SessionFile,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [string]$IoDirectory,
        [int]$TimeoutSeconds = 10
    )
    if (-not $IoDirectory) { $IoDirectory = Join-Path $RepositoryRoot "io_probe" }
    # 这套夹具模拟的是 connector 的 HTTP 端点，所以必须钉住 -Transport https：
    # 默认 auto 会优先去找真实的官方 matlab-mcp-server 子进程，
    # 那样测试就不再是在验这套判定逻辑，而是在碰巧跑一次真机连接。
    return Invoke-McpStagedProbe -SessionFile $SessionFile -RepositoryRoot $RepositoryRoot `
        -Backend "matlab-mcp-existing" -Scheme "http" -EndpointPath "/mcp" `
        -Transport https -IoProbeDirectory $IoDirectory -TimeoutSeconds $TimeoutSeconds `
        -SkipCodexCli -SkipUserConfigs -SkipTlsValidation
}

function Write-ValidRegistration {
    param([string]$RepositoryRoot, [string[]]$Arguments)
    $serverScript = Join-Path $RepositoryRoot "fake-server.js"
    Set-Content -LiteralPath $serverScript -Value "// stub" -Encoding ascii
    $config = [ordered]@{
        mcpServers = [ordered]@{
            "matlab-official" = [ordered]@{
                command = $serverScript
                args    = $Arguments
            }
        }
    }
    $config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $RepositoryRoot ".mcp.json") -Encoding UTF8
}

Describe 'HTTP 与 SSE 安全输出不改变线上鉴权或 JSON-RPC 请求' {
    foreach ($fixtureMode in @('security-json','security-sse','security-error')) {
        It "实际本机 TCP 往返 $fixtureMode 的响应和异常不回显合成凭据" {
            $sandbox = New-TestSandbox
            $server = $null
            try {
                $server = Start-FakeMcpServer -HelperPath $fakeServer -PortFile (Join-Path $sandbox.Root 'port.txt') -Mode $fixtureMode
                $parameters = @{code="disp('中文'); matrix=[1 2;3 4];"}
                $wire = [ordered]@{jsonrpc='2.0';id=17;method='tools/call';params=$parameters} | ConvertTo-Json -Depth 12 -Compress
                $sha = [Security.Cryptography.SHA256]::Create()
                try { $expected = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($wire))).Replace('-', '').ToLowerInvariant() }
                finally { $sha.Dispose() }
                $result = Invoke-McpJsonRpc -Endpoint "http://127.0.0.1:$($server.Port)/mcp" -Method 'tools/call' -Params $parameters -Id 17 -ApiKey 'SYNTHETIC-HTTP-AUTH!' -TimeoutSeconds 5
                ($result | ConvertTo-Json -Depth 20) | Should Not Match 'SYNTHETIC-HTTP-'
                $result.Json.id | Should Be 17
                if ($fixtureMode -eq 'security-error') {
                    $result.Ok | Should Be $false
                    $result.Json.error.code | Should Be -32001
                    $result.Json.error.message | Should Be 'controlled failure'
                } else {
                    $result.Ok | Should Be $true
                    $result.Json.result.authUnchanged | Should Be $true
                    $result.Json.result.bodySha256 | Should Be $expected
                    $result.Json.result.matrix[1][1] | Should Be 4
                    $result.Json.result.paths[0] | Should Be 'C:/data/sample.m'
                    $result.Json.result.content[0].text | Should Match 'diagnostic'
                }
                $jsonLine = if ($fixtureMode -eq 'security-sse') { ($result.Body -split '\r?\n' | Where-Object { $_ -match '^data:' }) -replace '^data:\s*','' } else { $result.Body }
                ($jsonLine | ConvertFrom-Json).id | Should Be 17
            } finally {
                if ($server) { Stop-TestProcess $server.Process }
                Remove-TestSandbox $sandbox
            }
        }
    }
}

Describe "阶段 3~5 只有在真实可执行时才 PASS" {
    It "全套正常时五阶段通过，且整体为 PASS" {
        $sandbox = New-TestSandbox
        $server = $null
        try {
            $portFile = Join-Path $sandbox.Root "port.txt"
            $server = Start-FakeMcpServer -HelperPath $fakeServer -PortFile $portFile -Mode "pass"
            $sessionPath = Join-Path $sandbox.Root "sessionDetails.json"
            New-FakeSession -Path $sessionPath -Port $server.Port
            Write-ValidRegistration -RepositoryRoot $sandbox.Root -Arguments @("--matlab-session-mode=existing")

            $report = Invoke-Probe -SessionFile $sessionPath -RepositoryRoot $sandbox.Root

            (Get-Check $report "mcp.protocol-handshake").status | Should Be "PASS"
            (Get-Check $report "mcp.readonly-exec").status | Should Be "PASS"
            (Get-Check $report "mcp.file-io").status | Should Be "PASS"
            (Get-Check $report "mcp.client-registration").status | Should Be "PASS"

            # mcp.matlab-install 依赖本机是否装了 MATLAB。GitHub runner 上没有 MATLAB，
            # 该项必然 FAIL —— 这是正确行为（没装就不能声称环境就绪），不是本用例要验证的东西。
            # 所以整体状态按 matlab-install 的真实结果推导，而不是硬写 PASS。
            $installCheck = Get-Check $report "mcp.matlab-install"
            $expectedOverall = if ("$($installCheck.status)" -eq "PASS") { "PASS" } else { "FAIL" }
            $report.overallStatus | Should Be $expectedOverall
            if ($expectedOverall -eq "FAIL") {
                # 只允许因为"没有 MATLAB"而 FAIL，不能因为 MCP 相关阶段失败而 FAIL。
                $failedIds = @($report.checks | Where-Object { $_.status -eq "FAIL" } | ForEach-Object { $_.id })
                ($failedIds -join ",") | Should Be "mcp.matlab-install"
            }
            (Test-AcceptanceReport -Report $report).Valid | Should Be $true
        }
        finally {
            Stop-TestProcess $server.Process
            Remove-TestSandbox $sandbox
        }
    }

    It "端口不可达时握手 FAIL，后续阶段 SKIP（不冒充成功）" {
        $sandbox = New-TestSandbox
        try {
            $sessionPath = Join-Path $sandbox.Root "sessionDetails.json"
            New-FakeSession -Path $sessionPath -Port 1
            $report = Invoke-Probe -SessionFile $sessionPath -RepositoryRoot $sandbox.Root -TimeoutSeconds 3

            (Get-Check $report "mcp.session-config").status | Should Be "PASS"
            (Get-Check $report "mcp.protocol-handshake").status | Should Be "FAIL"
            (Get-Check $report "mcp.protocol-handshake").errorClass | Should Be "MCP_CONNECTION_ERROR"
            (Get-Check $report "mcp.readonly-exec").status | Should Be "SKIP"
            (Get-Check $report "mcp.file-io").status | Should Be "SKIP"
            $report.overallStatus | Should Be "FAIL"
        }
        finally { Remove-TestSandbox $sandbox }
    }

    It "只有配置文件没有会话时，握手必须 SKIP 而不是 PASS" {
        $sandbox = New-TestSandbox
        try {
            Write-ValidRegistration -RepositoryRoot $sandbox.Root -Arguments @("--matlab-session-mode=auto")
            $sessionPath = Join-Path $sandbox.Root "missing-session.json"
            $report = Invoke-Probe -SessionFile $sessionPath -RepositoryRoot $sandbox.Root -TimeoutSeconds 3

            (Get-Check $report "mcp.session-config").status | Should Be "SKIP"
            (Get-Check $report "mcp.client-registration").status | Should Be "PASS"
            (Get-Check $report "mcp.protocol-handshake").status | Should Be "SKIP"
            ($report.overallStatus -ne "PASS") | Should Be $true
        }
        finally { Remove-TestSandbox $sandbox }
    }

    It "会话文件损坏时配置阶段 FAIL" {
        $sandbox = New-TestSandbox
        try {
            $sessionPath = Join-Path $sandbox.Root "sessionDetails.json"
            Set-Content -LiteralPath $sessionPath -Value "{ not json" -Encoding ascii
            $report = Invoke-Probe -SessionFile $sessionPath -RepositoryRoot $sandbox.Root -TimeoutSeconds 3
            (Get-Check $report "mcp.session-config").status | Should Be "FAIL"
            (Get-Check $report "mcp.session-config").errorClass | Should Be "MCP_CONNECTION_ERROR"
        }
        finally { Remove-TestSandbox $sandbox }
    }

    It "证书缺失时按过期会话处理，输出 SKIP 并给出原因" {
        $sandbox = New-TestSandbox
        $server = $null
        try {
            $portFile = Join-Path $sandbox.Root "port.txt"
            $server = Start-FakeMcpServer -HelperPath $fakeServer -PortFile $portFile -Mode "pass"
            $sessionPath = Join-Path $sandbox.Root "sessionDetails.json"
            New-FakeSession -Path $sessionPath -Port $server.Port -WithoutCertificate
            $report = Invoke-Probe -SessionFile $sessionPath -RepositoryRoot $sandbox.Root
            (Get-Check $report "mcp.session-config").status | Should Be "SKIP"
            ((Get-Check $report "mcp.session-config").reason -join " ") | Should Match "证书"
        }
        finally {
            Stop-TestProcess $server.Process
            Remove-TestSandbox $sandbox
        }
    }
}

Describe "工具探测与文件回读" {
    It "服务端没有执行工具时只读阶段 SKIP 并记录工具清单" {
        $sandbox = New-TestSandbox
        $server = $null
        try {
            $portFile = Join-Path $sandbox.Root "port.txt"
            $server = Start-FakeMcpServer -HelperPath $fakeServer -PortFile $portFile -Mode "no-tool"
            $sessionPath = Join-Path $sandbox.Root "sessionDetails.json"
            New-FakeSession -Path $sessionPath -Port $server.Port
            Write-ValidRegistration -RepositoryRoot $sandbox.Root -Arguments @("--matlab-session-mode=existing")

            $report = Invoke-Probe -SessionFile $sessionPath -RepositoryRoot $sandbox.Root
            $readonly = Get-Check $report "mcp.readonly-exec"
            $readonly.status | Should Be "SKIP"
            ($readonly.metrics.tools -contains "inspect_workspace") | Should Be $true
            (Get-Check $report "mcp.file-io").status | Should Be "SKIP"
        }
        finally {
            Stop-TestProcess $server.Process
            Remove-TestSandbox $sandbox
        }
    }

    It "回读内容不一致时文件读写阶段 FAIL" {
        $sandbox = New-TestSandbox
        $server = $null
        try {
            $portFile = Join-Path $sandbox.Root "port.txt"
            $server = Start-FakeMcpServer -HelperPath $fakeServer -PortFile $portFile -Mode "wrong-io"
            $sessionPath = Join-Path $sandbox.Root "sessionDetails.json"
            New-FakeSession -Path $sessionPath -Port $server.Port
            Write-ValidRegistration -RepositoryRoot $sandbox.Root -Arguments @("--matlab-session-mode=existing")

            $report = Invoke-Probe -SessionFile $sessionPath -RepositoryRoot $sandbox.Root
            (Get-Check $report "mcp.readonly-exec").status | Should Be "PASS"
            $io = Get-Check $report "mcp.file-io"
            $io.status | Should Be "FAIL"
            $io.errorClass | Should Be "VALIDATION_ERROR"
            $report.overallStatus | Should Be "FAIL"
        }
        finally {
            Stop-TestProcess $server.Process
            Remove-TestSandbox $sandbox
        }
    }

    It "握手失败（HTTP 500）时判定 FAIL 且不继续执行" {
        $sandbox = New-TestSandbox
        $server = $null
        try {
            $portFile = Join-Path $sandbox.Root "port.txt"
            $server = Start-FakeMcpServer -HelperPath $fakeServer -PortFile $portFile -Mode "bad-handshake"
            $sessionPath = Join-Path $sandbox.Root "sessionDetails.json"
            New-FakeSession -Path $sessionPath -Port $server.Port
            $report = Invoke-Probe -SessionFile $sessionPath -RepositoryRoot $sandbox.Root
            (Get-Check $report "mcp.protocol-handshake").status | Should Be "FAIL"
            (Get-Check $report "mcp.readonly-exec").status | Should Be "SKIP"
        }
        finally {
            Stop-TestProcess $server.Process
            Remove-TestSandbox $sandbox
        }
    }

    It "鉴权失败（HTTP 401）时握手 FAIL" {
        $sandbox = New-TestSandbox
        $server = $null
        try {
            $portFile = Join-Path $sandbox.Root "port.txt"
            $server = Start-FakeMcpServer -HelperPath $fakeServer -PortFile $portFile -Mode "auth-fail"
            $sessionPath = Join-Path $sandbox.Root "sessionDetails.json"
            New-FakeSession -Path $sessionPath -Port $server.Port
            $report = Invoke-Probe -SessionFile $sessionPath -RepositoryRoot $sandbox.Root
            $handshake = Get-Check $report "mcp.protocol-handshake"
            $handshake.status | Should Be "FAIL"
            ($handshake.reason -join " ") | Should Match "401"
        }
        finally {
            Stop-TestProcess $server.Process
            Remove-TestSandbox $sandbox
        }
    }

    It "服务端挂起时握手在超时后 FAIL（不会无限等待）" {
        $sandbox = New-TestSandbox
        $server = $null
        try {
            $portFile = Join-Path $sandbox.Root "port.txt"
            $server = Start-FakeMcpServer -HelperPath $fakeServer -PortFile $portFile -Mode "slow"
            $sessionPath = Join-Path $sandbox.Root "sessionDetails.json"
            New-FakeSession -Path $sessionPath -Port $server.Port

            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $report = Invoke-Probe -SessionFile $sessionPath -RepositoryRoot $sandbox.Root -TimeoutSeconds 2
            $stopwatch.Stop()

            (Get-Check $report "mcp.protocol-handshake").status | Should Be "FAIL"
            ($stopwatch.Elapsed.TotalSeconds -lt 30) | Should Be $true
        }
        finally {
            Stop-TestProcess $server.Process
            Remove-TestSandbox $sandbox
        }
    }
}

Describe "客户端注册校验" {
    It "existing 模式带 display-mode 会被判为非法注册" {
        $sandbox = New-TestSandbox
        try {
            Write-ValidRegistration -RepositoryRoot $sandbox.Root `
                -Arguments @("--matlab-session-mode=existing", "--matlab-display-mode=desktop")
            $report = Invoke-Probe -SessionFile (Join-Path $sandbox.Root "none.json") -RepositoryRoot $sandbox.Root -TimeoutSeconds 3
            $registration = Get-Check $report "mcp.client-registration"
            $registration.status | Should Be "FAIL"
            ($registration.reason -join " ") | Should Match "display-mode"
        }
        finally { Remove-TestSandbox $sandbox }
    }

    It "注册指向不存在的 command 会被判为 FAIL" {
        $sandbox = New-TestSandbox
        try {
            $config = [ordered]@{
                mcpServers = [ordered]@{
                    "matlab-official" = [ordered]@{
                        command = (Join-Path $sandbox.Root "missing-server.exe")
                        args    = @("--matlab-session-mode=auto")
                    }
                }
            }
            $config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $sandbox.Root ".mcp.json") -Encoding UTF8
            $report = Invoke-Probe -SessionFile (Join-Path $sandbox.Root "none.json") -RepositoryRoot $sandbox.Root -TimeoutSeconds 3
            $registration = Get-Check $report "mcp.client-registration"
            $registration.status | Should Be "FAIL"
            ($registration.reason -join " ") | Should Match "command"
        }
        finally { Remove-TestSandbox $sandbox }
    }

    It "没有注册时输出 SKIP 并说明检查了哪些客户端" {
        $sandbox = New-TestSandbox
        try {
            $report = Invoke-Probe -SessionFile (Join-Path $sandbox.Root "none.json") -RepositoryRoot $sandbox.Root -TimeoutSeconds 3
            $registration = Get-Check $report "mcp.client-registration"
            $registration.status | Should Be "SKIP"
            ($registration.reason -join " ") | Should Match "未发现"
        }
        finally { Remove-TestSandbox $sandbox }
    }
}

Describe "JSON 解析保持键名大小写" {
    It "大小写不同但合法的键不会被当成重复键" {
        $json = '{"path":"lower","Path":"upper","nested":{"Value":1},"items":[1,{"Key":"v"}]}'
        $parsed = ConvertFrom-JsonCaseSensitive -Text $json
        ($parsed -is [System.Collections.IDictionary]) | Should Be $true
        ([string]$parsed['path']) | Should Be 'lower'
        ([string]$parsed['Path']) | Should Be 'upper'
        ([int]$parsed['nested']['Value']) | Should Be 1
        ([int]$parsed['items'][0]) | Should Be 1
        ([string]$parsed['items'][1]['Key']) | Should Be 'v'
    }
}

Describe "回环证书固定取代全量放行" {
    It "只有回环主机名被认定为可信链路" {
        (Test-McpLoopbackHostName -HostName "127.0.0.1") | Should Be $true
        (Test-McpLoopbackHostName -HostName "localhost") | Should Be $true
        (Test-McpLoopbackHostName -HostName "::1") | Should Be $true
        (Test-McpLoopbackHostName -HostName "127.5.5.5") | Should Be $true
        (Test-McpLoopbackHostName -HostName "matlab.example.com") | Should Be $false
        (Test-McpLoopbackHostName -HostName "999.1.1.1") | Should Be $false
        (Test-McpLoopbackHostName -HostName "") | Should Be $false
    }

    It "从证书文件读出指纹；缺失或私钥文件失败关闭" {
        $sandbox = New-TestSandbox
        try {
            $anchor = @(Get-ChildItem -LiteralPath "Cert:\LocalMachine\Root" -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($anchor.Count -eq 0) { Set-ItResult -Skipped -Because "本机没有可导出的只读锚定证书" }
            $der = $anchor[0].Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
            $wrapped = ([convert]::ToBase64String($der)) -replace '(.{64})', "`$1`r`n"
            $pem = "-----BEGIN CERTIFICATE-----`r`n" + $wrapped + "`r`n-----END CERTIFICATE-----`r`n"
            $certPath = Join-Path $sandbox.Root "anchor.pem"
            [System.IO.File]::WriteAllText($certPath, $pem, (New-Object System.Text.UTF8Encoding($false)))

            $thumbprint = Get-McpCertificateThumbprint -CertificatePath $certPath
            $thumbprint | Should Be $anchor[0].Thumbprint

            (Get-McpCertificateThumbprint -CertificatePath (Join-Path $sandbox.Root "missing.pem")) | Should BeNullOrEmpty

            $keyOnly = Join-Path $sandbox.Root "only-key.pem"
            Set-Content -LiteralPath $keyOnly -Value @("-----BEGIN PRIVATE KEY-----", "TUVM", "-----END PRIVATE KEY-----") -Encoding ascii
            (Get-McpCertificateThumbprint -CertificatePath $keyOnly) | Should BeNullOrEmpty
        }
        finally { Remove-TestSandbox $sandbox }
    }

    It "校验回调仅在主机为回环且指纹一致时放行" {
        $validator = New-McpCertificatePinValidator -PinnedThumbprint "AABBCC" -HostName "127.0.0.1"
        $matching = "" | Add-Member -PassThru -MemberType ScriptMethod -Name GetCertHashString -Value { return "aabbcc" }
        $other = "" | Add-Member -PassThru -MemberType ScriptMethod -Name GetCertHashString -Value { return "dddddd" }

        (& $validator $null $matching $null [System.Net.Security.SslPolicyErrors]::None) | Should Be $true
        # 自签名必然报链错误：指纹一致才允许在这种情况下放行。
        (& $validator $null $matching $null [System.Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors) | Should Be $true
        (& $validator $null $other $null [System.Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors) | Should Be $false
        # R2026a 的 thisMatlab.pem 只有 CN=127.0.0.1、没有 SAN，.NET 必然报名称不匹配。
        # 指纹逐字相等已经比"名字对得上"更强，所以这里必须放行；
        # 若坚持名称匹配，唯一出路就是对本进程整体关掉证书校验。
        (& $validator $null $matching $null [System.Net.Security.SslPolicyErrors]::RemoteCertificateNameMismatch) | Should Be $true

        $remoteHost = New-McpCertificatePinValidator -PinnedThumbprint "AABBCC" -HostName "matlab.example.com"
        (& $remoteHost $null $matching $null [System.Net.Security.SslPolicyErrors]::None) | Should Be $false

        $noPin = New-McpCertificatePinValidator -PinnedThumbprint "" -HostName "127.0.0.1"
        (& $noPin $null $matching $null [System.Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors) | Should Be $false
    }

    It "未提供指纹且未显式跳过校验时，绝不安装全量放行回调" {
        $sandbox = New-TestSandbox
        $previous = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
        try {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null
            $outcome = Invoke-McpJsonRpc -Endpoint "https://127.0.0.1:1/unused" -Method "initialize" -TimeoutSeconds 2
            $outcome.Ok | Should Be $false
            $outcome.TlsMode | Should Be "system-default"
            # 关键安全断言：调用结束后进程级回调必须仍是"未安装"，
            # 否则一次探测会把整个 .NET 进程的证书校验永久关掉。
            ([System.Net.ServicePointManager]::ServerCertificateValidationCallback -eq $null) | Should Be $true
        }
        finally { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previous; Remove-TestSandbox $sandbox }
    }

    It "有指纹可固定时，-SkipTlsValidation 不能把它降级成全量放行" {
        $previous = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
        try {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null
            $pinned = Invoke-McpJsonRpc -Endpoint "https://127.0.0.1:1/unused" -Method "initialize" `
                -PinnedCertificateThumbprint "AABBCC" -SkipTlsValidation -TimeoutSeconds 2
            $pinned.TlsMode | Should Be "pinned"

            # 只有确实没有指纹可用时，显式跳过才会留下 insecure-skip 痕迹
            $skipped = Invoke-McpJsonRpc -Endpoint "https://127.0.0.1:1/unused" -Method "initialize" `
                -SkipTlsValidation -TimeoutSeconds 2
            $skipped.TlsMode | Should Be "insecure-skip"
            ([System.Net.ServicePointManager]::ServerCertificateValidationCallback -eq $null) | Should Be $true
        }
        finally { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previous }
    }
}

function Get-HostPowerShellExe {
    # 用当前宿主自身的可执行文件启动假服务端：5.1 跑 powershell.exe，7 跑 pwsh.exe。
    $process = Get-Process -Id $PID
    try { return [string]$process.MainModule.FileName } catch { return (Get-Command PowerShell).Source }
}

function New-FakeOfficialServerShim {
    param([string]$SandboxRoot)
    # 官方 server 是"一个可执行文件 + --matlab-session-mode 这类参数"。
    # 夹具用 .cmd 转发，才能把 Start-McpStdioChannel 真实拼出的参数原样收到，
    # 而不是在测试里给生产代码开后门。
    $shim = Join-Path $SandboxRoot "fake-official-server.cmd"
    $lines = @(
        "@echo off",
        ("`"{0}`" -NoProfile -ExecutionPolicy Bypass -File `"{1}`" %*" -f (Get-HostPowerShellExe), $fakeStdioServerPath)
    )
    [System.IO.File]::WriteAllLines($shim, $lines, (New-Object System.Text.ASCIIEncoding))
    return $shim
}

Describe "stdio 通道：安装副本的探测走官方 server 路径" {
    It "Start-McpStdioChannel 拼出官方参数并完成 initialize" {
        $sandbox = New-TestSandbox
        $channel = $null
        try {
            $shim = New-FakeOfficialServerShim -SandboxRoot $sandbox.Root
            $channel = Start-McpStdioChannel -ServerExe $shim -SessionMode "existing" `
                -WorkingDirectory $sandbox.Root -Label "fake-official"
            ($channel.Arguments -like "--matlab-session-mode=existing*") | Should Be $true
            # existing 模式下官方 server 会拒绝 --matlab-root / --matlab-display-mode
            ($channel.Arguments -match "matlab-display-mode") | Should Be $false

            $channelObject = [pscustomobject][ordered]@{
                Kind = "stdio"; Session = $channel.Session; TimeoutSeconds = 30
            }
            $init = Invoke-McpTransportRequest -Channel $channelObject -Method "initialize" -Params ([ordered]@{
                protocolVersion = "2025-06-18"
                capabilities    = [ordered]@{}
                clientInfo      = [ordered]@{ name = "matlab-agent-skills-test"; version = "1.0.0" }
            }) -Id 1
            $init.Ok | Should Be $true
            $init.TlsMode | Should Be "stdio"
            "$($init.Json.result.serverInfo.name)" | Should Be "fake-mcp-stdio"

            $list = Invoke-McpTransportRequest -Channel $channelObject -Method "tools/list" -Id 2
            $list.Ok | Should Be $true
            @($list.Json.result.tools).Count | Should Be 2
        }
        finally {
            if ($channel) { Stop-McpStdioChannel -Channel $channel | Out-Null }
            Remove-TestSandbox $sandbox
        }
    }

    It "关闭通道时回收子进程并还原代理环境" {
        $sandbox = New-TestSandbox
        $beforeNoProxy = [System.Environment]::GetEnvironmentVariable("NO_PROXY", "Process")
        $channel = $null
        try {
            $shim = New-FakeOfficialServerShim -SandboxRoot $sandbox.Root
            $channel = Start-McpStdioChannel -ServerExe $shim -SessionMode "existing" -WorkingDirectory $sandbox.Root
            $childPid = $channel.ProcessId
            $info = Stop-McpStdioChannel -Channel $channel
            $info.Exited | Should Be $true
            # 句柄释放与进程表项消失之间有一小段窗口，轮询而不是立刻断言
            $gone = $false
            for ($i = 0; $i -lt 20; $i++) {
                if ($null -eq (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) { $gone = $true; break }
                Start-Sleep -Milliseconds 100
            }
            $gone | Should Be $true
            $after = [System.Environment]::GetEnvironmentVariable("NO_PROXY", "Process")
            if ([string]::IsNullOrEmpty($beforeNoProxy)) { $after | Should BeNullOrEmpty }
            else { $after | Should Be $beforeNoProxy }
        }
        finally {
            if ($channel -and -not $info) { Stop-McpStdioChannel -Channel $channel | Out-Null }
            Remove-TestSandbox $sandbox
        }
    }

    It "只接受与固定清单匹配的服务端，绝不下载" {
        $sandbox = New-TestSandbox
        try {
            $missing = Join-Path $sandbox.Root "not-here.exe"
            $absent = Resolve-McpStdioServer -ServerExe $missing
            $absent.Found | Should Be $false
            $parameterEntry = @($absent.Searched) | Where-Object { $_.origin -eq "parameter" } | Select-Object -First 1
            ($null -ne $parameterEntry) | Should Be $true
            $parameterEntry.result | Should Be "missing"

            # 同名但内容任意的文件必须被清单拒绝：这条路径曾经把 24 字节的假二进制当真服务端执行
            $impostor = Join-Path $sandbox.Root "matlab-mcp-server-windows-x64.exe"
            [System.IO.File]::WriteAllText($impostor, "not a binary", (New-Object System.Text.UTF8Encoding($false)))
            $rejected = Resolve-McpStdioServer -ServerExe $impostor
            $rejected.Found | Should Be $false
            $reason = (@($rejected.Searched) | ForEach-Object { $_.reason }) -join " "
            ($reason -match "清单|manifest|拒绝|不匹配") | Should Be $true
            # 显式指定的二进制被拒后不得回退到本机其它候选：报告里"指定的"和"实际执行的"必须是同一个文件
            (@($rejected.Searched) | Where-Object { $_.origin -ne "parameter" } | Measure-Object).Count | Should Be 0
        }
        finally { Remove-TestSandbox $sandbox }
    }

    It "本机已有的官方服务端按清单校验后才被使用" {
        $repoBin = Join-Path (Get-TestRepositoryRoot) "bin\matlab-mcp-server-windows-x64.exe"
        if (-not (Test-Path -LiteralPath $repoBin)) {
            Set-ItResult -Skipped -Because "本机没有 bin\matlab-mcp-server-windows-x64.exe"
        }
        $resolved = Resolve-McpStdioServer -ServerExe $repoBin
        $resolved.Found | Should Be $true
        # 通过校验不等于"随便一个本地文件"：Verified 必须由清单给出
        $resolved.Verified | Should Be $true
        ([string]$resolved.Path).ToLowerInvariant() | Should Be ([string](Resolve-Path -LiteralPath $repoBin)).ToLowerInvariant()
    }
}
