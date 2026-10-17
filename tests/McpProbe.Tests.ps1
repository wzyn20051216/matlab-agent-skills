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
    return Invoke-McpStagedProbe -SessionFile $SessionFile -RepositoryRoot $RepositoryRoot `
        -Backend "matlab-mcp-existing" -Scheme "http" -EndpointPath "/mcp" `
        -IoProbeDirectory $IoDirectory -TimeoutSeconds $TimeoutSeconds `
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
            $report.overallStatus | Should Be "PASS"
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
