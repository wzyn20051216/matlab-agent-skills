<#
.SYNOPSIS
测试用最小 MCP 服务端（TCP + 纯 HTTP/1.1，无 TLS、无外部依赖）。

.DESCRIPTION
仅用于验证 scripts/MatlabAgentSkills.McpProbe.psm1 的探测逻辑，模拟 MATLAB MCP
服务端的行为，不连接真实 MATLAB，也不代表真实协议实现。

用法：
  powershell -File .\tests\helpers\FakeMcpServer.ps1 -PortFile <path> -Mode pass

Mode：
  pass           initialize / tools/list / tools/call 全部正常
  no-tool        tools/list 不暴露可识别的执行工具
  bad-handshake  initialize 返回 500
  auth-fail      initialize 返回 401
  wrong-io       文件读写返回错误令牌且不落盘
  slow           每个请求延迟 30 秒（用于超时测试）
#>
[CmdletBinding()]
param(
    [int]$Port = 0,
    [Parameter(Mandatory)][string]$PortFile,
    [ValidateSet("pass", "no-tool", "bad-handshake", "auth-fail", "wrong-io", "slow")]
    [string]$Mode = "pass",
    [int]$MaxRequests = 12
)

$ErrorActionPreference = "Stop"

function Read-HttpRequest {
    param([System.IO.Stream]$Stream)

    $buffer = New-Object System.Collections.Generic.List[byte]
    $one = New-Object byte[] 1
    while ($true) {
        $read = $Stream.Read($one, 0, 1)
        if ($read -le 0) { return $null }
        $buffer.Add($one[0])
        $count = $buffer.Count
        if ($count -ge 4 -and
            $buffer[$count - 4] -eq 13 -and $buffer[$count - 3] -eq 10 -and
            $buffer[$count - 2] -eq 13 -and $buffer[$count - 1] -eq 10) {
            break
        }
        if ($count -gt 65536) { return $null }
    }

    $headerText = [System.Text.Encoding]::ASCII.GetString($buffer.ToArray())
    $lines = $headerText -split "`r`n"
    $contentLength = 0
    foreach ($line in $lines) {
        if ($line -match '^(?i)Content-Length:\s*(\d+)') { $contentLength = [int]$Matches[1] }
    }

    $body = ""
    if ($contentLength -gt 0) {
        $bodyBytes = New-Object byte[] $contentLength
        $offset = 0
        while ($offset -lt $contentLength) {
            $read = $Stream.Read($bodyBytes, $offset, $contentLength - $offset)
            if ($read -le 0) { break }
            $offset += $read
        }
        $body = [System.Text.Encoding]::UTF8.GetString($bodyBytes, 0, $offset)
    }

    return [pscustomobject]@{ RequestLine = $lines[0]; Body = $body }
}

function Send-HttpResponse {
    param(
        [System.IO.Stream]$Stream,
        [int]$StatusCode = 200,
        [string]$Body = ""
    )

    $reason = switch ($StatusCode) {
        200 { "OK" }
        401 { "Unauthorized" }
        500 { "Internal Server Error" }
        default { "OK" }
    }
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $header = "HTTP/1.1 $StatusCode $reason`r`n" +
        "Content-Type: application/json`r`n" +
        "Content-Length: $($bodyBytes.Length)`r`n" +
        "Connection: close`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($bodyBytes.Length -gt 0) { $Stream.Write($bodyBytes, 0, $bodyBytes.Length) }
    $Stream.Flush()
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
$actualPort = $listener.LocalEndpoint.Port

# 端口文件必须允许并发读取。
# 早期实现用 Set-Content，它内部以 FileShare.None 打开文件；父进程（Start-FakeMcpServer）
# 轮询到这个文件时如果写句柄还没释放，Get-Content 会抛
# "文件正由另一进程使用" —— 这是个纯竞态：空载单跑时窗口小到不触发，
# 整套测试并发压力大时稳定复现（2026-10-17 实测 free 层 3 个失败全部来自这里）。
# 显式用 FileShare.Read 打开，让读者永远不必等写者。
$portStream = [System.IO.File]::Open($PortFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
$portWriter = New-Object System.IO.StreamWriter($portStream, [System.Text.Encoding]::ASCII)
$portWriter.Write("port=$actualPort")
$portWriter.Flush()
$portWriter.Close()

try {
    for ($requestIndex = 0; $requestIndex -lt $MaxRequests; $requestIndex++) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $request = Read-HttpRequest -Stream $stream
            if ($null -eq $request) { continue }

            if ($Mode -eq "slow") { Start-Sleep -Seconds 30 }

            $payload = $null
            try { $payload = $request.Body | ConvertFrom-Json } catch { }

            $method = $null
            $id = 1
            if ($payload) {
                if ($payload.PSObject.Properties.Name -contains "method") { $method = "$($payload.method)" }
                if ($payload.PSObject.Properties.Name -contains "id") { $id = $payload.id }
            }

            if ($Mode -eq "auth-fail") {
                Send-HttpResponse -Stream $stream -StatusCode 401 -Body '{"error":"unauthorized"}'
                continue
            }
            if ($Mode -eq "bad-handshake") {
                Send-HttpResponse -Stream $stream -StatusCode 500 -Body 'not-json'
                continue
            }

            switch ($method) {
                "initialize" {
                    $result = [ordered]@{
                        jsonrpc = "2.0"
                        id      = $id
                        result  = [ordered]@{
                            protocolVersion = "2025-06-18"
                            capabilities    = [ordered]@{ tools = [ordered]@{} }
                            serverInfo      = [ordered]@{ name = "fake-matlab-mcp"; version = "0.0.1" }
                        }
                    }
                    Send-HttpResponse -Stream $stream -Body ($result | ConvertTo-Json -Depth 8 -Compress)
                }
                "tools/list" {
                    $tools = if ($Mode -eq "no-tool") {
                        @([ordered]@{ name = "inspect_workspace"; description = "read-only workspace listing" })
                    }
                    else {
                        @([ordered]@{ name = "evaluate_matlab_code"; description = "run code in MATLAB" })
                    }
                    $result = [ordered]@{ jsonrpc = "2.0"; id = $id; result = [ordered]@{ tools = $tools } }
                    Send-HttpResponse -Stream $stream -Body ($result | ConvertTo-Json -Depth 8 -Compress)
                }
                "tools/call" {
                    $code = ""
                    if ($payload.PSObject.Properties.Name -contains "params") {
                        $arguments = $payload.params.arguments
                        if ($arguments -and $arguments.PSObject.Properties.Name -contains "code") { $code = "$($arguments.code)" }
                    }

                    $text = "26.1.0.3276743 (R2026a)"
                    if ($code -match 'fileread') {
                        $pathMatch = [regex]::Match($code, "p\s*=\s*'([^']+)'")
                        $tokenMatch = [regex]::Match($code, "'([0-9a-f]{32})'")
                        $token = if ($tokenMatch.Success) { $tokenMatch.Groups[1].Value } else { "missing-token" }
                        if ($pathMatch.Success -and $Mode -ne "wrong-io") {
                            $target = $pathMatch.Groups[1].Value
                            $parent = Split-Path -Parent $target
                            if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                                New-Item -ItemType Directory -Force -Path $parent | Out-Null
                            }
                            Set-Content -LiteralPath $target -Value $token -Encoding ascii -NoNewline
                        }
                        $text = if ($Mode -eq "wrong-io") { "deadbeef" } else { $token }
                    }

                    $result = [ordered]@{
                        jsonrpc = "2.0"
                        id      = $id
                        result  = [ordered]@{ content = @([ordered]@{ type = "text"; text = $text }) }
                    }
                    Send-HttpResponse -Stream $stream -Body ($result | ConvertTo-Json -Depth 8 -Compress)
                }
                default {
                    $result = [ordered]@{
                        jsonrpc = "2.0"
                        id      = $id
                        error   = [ordered]@{ code = -32601; message = "method not found: $method" }
                    }
                    Send-HttpResponse -Stream $stream -Body ($result | ConvertTo-Json -Depth 8 -Compress)
                }
            }
        }
        finally {
            $client.Close()
        }
    }
}
finally {
    $listener.Stop()
}
