<#
.SYNOPSIS
测试辅助：临时沙箱、模块导入、假 MCP 服务端启停。

.DESCRIPTION
注意：这里刻意不使用 Start-Process。Windows PowerShell 5.1 在某些机器上会因环境变量
存在大小写重复键（HTTPS_PROXY / https_proxy）而抛“字典中的关键字重复”，
用 ProcessStartInfo 启动更稳定。
#>

function Get-TestRepositoryRoot {
    param([string]$StartPath = $PSScriptRoot)
    return (Resolve-Path (Join-Path $StartPath "..\..")).Path
}

function Import-TestModule {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$RepositoryRoot = (Get-TestRepositoryRoot)
    )
    $path = Join-Path $RepositoryRoot "scripts\$Name"
    Import-Module $path -Force -DisableNameChecking
    return $path
}

function New-TestSandbox {
    param([string]$Prefix = "mas-test")
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("$Prefix-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    return [pscustomobject]@{
        Root       = $root
        Backup     = (Join-Path $root "backup")
        Logs       = (Join-Path $root "logs")
        Validation = (Join-Path $root "artifacts\validation")
    }
}

function Remove-TestSandbox {
    param($Sandbox)
    if ($null -eq $Sandbox) { return }
    if (Test-Path -LiteralPath $Sandbox.Root) {
        Remove-Item -LiteralPath $Sandbox.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Start-FakeMcpServer {
    <#
    .SYNOPSIS
    以独立进程启动假 MCP 服务端，返回进程对象与端口。
    #>
    param(
        [Parameter(Mandatory)][string]$HelperPath,
        [Parameter(Mandatory)][string]$PortFile,
        [string]$Mode = "pass",
        [int]$WaitSeconds = 15
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Process -Id $PID).Path
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$HelperPath`" -PortFile `"$PortFile`" -Mode $Mode -MaxRequests 12"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $process.Start() | Out-Null

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    $port = $null
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $PortFile) {
            # 两个独立的竞态，都必须容错而不是让 Describe 变红：
            # 1) 写者（FakeMcpServer.ps1 用 FileMode.Create）先把文件建成 0 字节再写内容，
            #    此时 Get-Content -Raw 返回 $null，直接 .Trim() 会抛
            #    "不能对 Null 值表达式调用方法"；
            # 2) 写句柄尚未释放时读取会抛 IOException。
            # 这两种都只是"还没写好"，重试即可，不是测试失败。
            try {
                $raw = Get-Content -LiteralPath $PortFile -Raw -ErrorAction Stop
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    $text = $raw.Trim()
                    if ($text -match 'port=(\d+)') {
                        $port = [int]$Matches[1]
                        break
                    }
                }
            }
            catch [System.IO.IOException] {
                # 写者仍持有句柄，等下一个轮询周期
            }
        }
        Start-Sleep -Milliseconds 100
    }

    if ($null -eq $port) {
        try { $process.Kill() } catch { }
        throw "假 MCP 服务端未在 $WaitSeconds 秒内启动（PortFile=$PortFile）"
    }

    return [pscustomobject]@{ Process = $process; Port = $port }
}

function Stop-TestProcess {
    param($Process)
    if ($null -eq $Process) { return }
    try {
        if (-not $Process.HasExited) { $Process.Kill() }
        $Process.WaitForExit(3000) | Out-Null
    }
    catch { }
    finally {
        try { $Process.Dispose() } catch { }
    }
}

function New-FakeSession {
    <#
    .SYNOPSIS
    在沙箱里写一份 sessionDetails.json，指向本地端口。
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$Port,
        [string]$ApiKey = "test-api-key",
        [int]$ProcessId = 0,
        [switch]$WithoutCertificate,
        [string]$CertificatePath
    )

    if ($ProcessId -le 0) { $ProcessId = $PID }
    $certificate = $CertificatePath
    if (-not $certificate) {
        $certificate = Join-Path (Split-Path -Parent $Path) "cert.pem"
        if (-not $WithoutCertificate) {
            Set-Content -LiteralPath $certificate -Value "-----BEGIN CERTIFICATE-----" -Encoding ascii
        }
    }

    $session = [ordered]@{
        port        = $Port
        certificate = $certificate
        apiKey      = $ApiKey
        pid         = $ProcessId
    }
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $session | ConvertTo-Json | Set-Content -LiteralPath $Path -Encoding UTF8
}
