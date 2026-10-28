<#
.SYNOPSIS
测试用最小 MCP stdio 服务端：stdin 收 JSON-RPC 行，stdout 回 JSON-RPC 行。

.DESCRIPTION
只用于验证 scripts/MatlabAgentSkills.McpStdio.psm1 的客户端实现，不连接 MATLAB，
也不代表官方服务端行为。刻意保持零依赖：不需要网络、证书或第三方运行时。

刻意复刻的两个真实坑：
- 必须显式把 Console 输入/输出编码钉成 UTF-8。否则在 Windows PowerShell 5.1 上
  子进程按 OEM 代码页解码，含非 ASCII 的 MATLAB 代码会变成 U+FFFD，
  客户端“看起来通了但内容坏了”。
- 无 id 的行是通知（notifications/*），不能回响应。

Mode：
  pass            initialize / tools/list / tools/call 全部正常
  fail-handshake  initialize 返回 JSON-RPC error
  echo            tools/call 原样回显 code（用于 UTF-8 往返断言，默认行为）
#>
[CmdletBinding()]
param(
    [ValidateSet("pass", "fail-handshake")]
    [string]$Mode = "pass",
    # 官方服务端的参数语法（--matlab-session-mode=auto、--disable-telemetry=true）也要能吞下，
    # 否则用 Start-McpStdioChannel 拉起本假服务端时会在参数绑定阶段就退出，
    # 测不到 JSON-RPC 往返。这里刻意不解释它们：假服务端不连 MATLAB。
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$IgnoredArguments
)

$ErrorActionPreference = "Stop"

try {
    [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
}
catch { }

function Write-JsonLine {
    param($Payload)
    $json = $Payload | ConvertTo-Json -Depth 12 -Compress
    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
}

function Get-ResultPayload {
    param([string]$Method, $Message)

    switch ($Method) {
        "initialize" {
            if ($Mode -eq "fail-handshake") { return $null }
            return [ordered]@{
                protocolVersion = "2025-06-18"
                capabilities    = [ordered]@{ tools = [ordered]@{} }
                serverInfo      = [ordered]@{ name = "fake-mcp-stdio"; version = "0.0.0-test" }
            }
        }
        "tools/list" {
            return [ordered]@{
                tools = @(
                    [ordered]@{ name = "evaluate_matlab_code"; description = "echo stub" }
                    [ordered]@{ name = "run_matlab_file"; description = "echo stub" }
                )
            }
        }
        "tools/call" {
            $code = ""
            try { $code = "$($Message.params.arguments.code)" } catch { $code = "" }
            if (-not $code -and $Message.params.arguments.script_path) { $code = "FILE=$($Message.params.arguments.script_path)" }
            # 合成请求的摘要用于证明客户端输出脱敏没有改写线上执行代码。
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $codeSha256 = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($code))).Replace('-', '').ToLowerInvariant() }
            finally { $sha.Dispose() }
            return [ordered]@{
                content = @([ordered]@{ type = "text"; text = "ECHO=$code" })
                codeSha256 = $codeSha256
                isError = $false
            }
        }
        default { return $null }
    }
}

$out = New-Object System.Diagnostics.Stopwatch
while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    $line = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    $message = $null
    try { $message = $line | ConvertFrom-Json } catch { continue }
    if ($null -eq $message) { continue }

    # 通知没有 id，永远不应当产生响应。
    if (-not ($message.PSObject.Properties.Name -contains "id")) { continue }
    $id = $message.id
    $method = "$($message.method)"

    if ($Mode -eq "fail-handshake" -and $method -eq "initialize") {
        Write-JsonLine ([ordered]@{
            jsonrpc = "2.0"
            id      = $id
            error   = [ordered]@{ code = -32603; message = "fake handshake failure" }
        })
        continue
    }

    $result = Get-ResultPayload -Method $method -Message $message
    if ($null -eq $result) {
        Write-JsonLine ([ordered]@{
            jsonrpc = "2.0"
            id      = $id
            error   = [ordered]@{ code = -32601; message = "method not found: $method" }
        })
        continue
    }
    Write-JsonLine ([ordered]@{ jsonrpc = "2.0"; id = $id; result = $result })
}
