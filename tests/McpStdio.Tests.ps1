<#
.SYNOPSIS
MCP stdio 客户端测试：在两种 PowerShell 宿主上都要能启动服务端并完成 JSON-RPC 往返。

.DESCRIPTION
这套测试是 S3 解除真实 MCP 阻塞的第一层保障。它针对的是实测到的两个缺陷：

1. Start-McpStdioServer 直接赋值 ProcessStartInfo.StandardInputEncoding。
   该属性只存在于 .NET Core / PowerShell 7；在 Windows PowerShell 5.1 上赋值会抛
   "在此对象上找不到属性"，于是官方服务端根本没被启动，L1 直接 FAIL，
   后面所有层级都变成 SKIP —— 而 Skill 文档给出的正是 powershell（5.1）调用方式。
2. JSON-RPC 通过 StandardInput 写出时，.NET Framework 默认使用 OEM 代码页，
   含非 ASCII 的 MATLAB 代码会被转码损坏（服务端收到 U+FFFD）。
   客户端必须显式使用 UTF-8 写字节流。

测试不依赖 MATLAB、网络和证书：使用 tests/helpers/FakeMcpStdioServer.ps1 作为假服务端。
#>

$helpers = Join-Path $PSScriptRoot "helpers\TestSandbox.ps1"
. $helpers

$repoRoot = Get-TestRepositoryRoot
Import-TestModule -Name "MatlabAgentSkills.McpStdio.psm1" -RepositoryRoot $repoRoot | Out-Null

$fakeStdioServer = Join-Path $PSScriptRoot "helpers\FakeMcpStdioServer.ps1"

function Get-HostPowerShellExe {
    # 用当前宿主自身的可执行文件启动假服务端：5.1 跑 powershell.exe，7 跑 pwsh.exe，
    # 这样同一个测试文件在两台主机上都能覆盖各自当年的失败路径。
    $process = Get-Process -Id $PID
    try { return [string]$process.MainModule.FileName } catch { return (Get-Command PowerShell).Source }
}

function New-FakeStdioSession {
    param([string]$Mode = "pass")
    $exe = Get-HostPowerShellExe
    $sandbox = New-TestSandbox
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$fakeStdioServer`" -Mode $Mode"
    $session = Start-McpStdioServer -ServerExe $exe -ServerArgumentLine $arguments `
        -WorkingDirectory $sandbox.Root -Label "fake-stdio-$Mode"
    return [pscustomobject]@{ Session = $session; Sandbox = $sandbox }
}

Describe "stdio 传输在两种宿主都必须能启动服务端" {
    It "Start-McpStdioServer 不依赖 PS7 专有属性，进程保持存活" {
        $h = $null
        try {
            $h = New-FakeStdioSession -Mode "pass"
            { Test-McpStdioServerAlive -Session $h.Session } | Should Be $true
        }
        finally {
            if ($h) { Stop-McpStdioServer -Session $h.Session | Out-Null; Remove-TestSandbox $h.Sandbox }
        }
    }

    It "initialize 返回真实 result（协议版本与服务端名）" {
        $h = $null
        try {
            $h = New-FakeStdioSession -Mode "pass"
            $init = Send-McpStdioRequest -Session $h.Session -Method "initialize" -TimeoutSeconds 30 -Params ([ordered]@{
                protocolVersion = "2025-06-18"
                capabilities    = [ordered]@{}
                clientInfo      = [ordered]@{ name = "matlab-agent-skills-test"; version = "1.0.0" }
            })
            $init.Ok | Should Be $true
            "$($init.Result.protocolVersion)" | Should Be "2025-06-18"
            "$($init.Result.serverInfo.name)" | Should Be "fake-mcp-stdio"
        }
        finally {
            if ($h) { Stop-McpStdioServer -Session $h.Session | Out-Null; Remove-TestSandbox $h.Sandbox }
        }
    }

    It "握手失败时返回 error 而不是假装成功" {
        $h = $null
        try {
            $h = New-FakeStdioSession -Mode "fail-handshake"
            $init = Send-McpStdioRequest -Session $h.Session -Method "initialize" -TimeoutSeconds 30
            $init.Ok | Should Be $false
            $init.Error | Should Not BeNullOrEmpty
        }
        finally {
            if ($h) { Stop-McpStdioServer -Session $h.Session | Out-Null; Remove-TestSandbox $h.Sandbox }
        }
    }
}

Describe "JSON-RPC 载荷按 UTF-8 往返" {
    It "含非 ASCII 的 MATLAB 代码不被代码页损坏" {
        $h = $null
        try {
            $h = New-FakeStdioSession -Mode "pass"
            $null = Send-McpStdioRequest -Session $h.Session -Method "initialize" -TimeoutSeconds 30
            $code = "disp('中文标记＝MCP-UTF8');"
            $call = Send-McpStdioRequest -Session $h.Session -Method "tools/call" -TimeoutSeconds 30 -Params ([ordered]@{
                name      = "evaluate_matlab_code"
                arguments = [ordered]@{ code = $code }
            })
            $call.Ok | Should Be $true
            $text = Get-McpStdioToolText -ResultNode $call.Result
            # 损坏的表现为 U+FFFD 替换字符或问号；这里要求原文逐字回来。
            $text | Should Match ([regex]::Escape($code))
            ($text.Contains([char]0xFFFD)) | Should Be $false
        }
        finally {
            if ($h) { Stop-McpStdioServer -Session $h.Session | Out-Null; Remove-TestSandbox $h.Sandbox }
        }
    }

    It "tools/list 能发现工具名（阶段 4 的前置条件）" {
        $h = $null
        try {
            $h = New-FakeStdioSession -Mode "pass"
            $null = Send-McpStdioRequest -Session $h.Session -Method "initialize" -TimeoutSeconds 30
            $list = Send-McpStdioRequest -Session $h.Session -Method "tools/list" -TimeoutSeconds 30
            $list.Ok | Should Be $true
            $names = @($list.Result.tools | ForEach-Object { "$($_.name)" })
            ($names -contains "evaluate_matlab_code") | Should Be $true
        }
        finally {
            if ($h) { Stop-McpStdioServer -Session $h.Session | Out-Null; Remove-TestSandbox $h.Sandbox }
        }
    }
}
