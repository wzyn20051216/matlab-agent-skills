<#
.SYNOPSIS
    持有 MATLAB 共享会话，供 MCP server `--matlab-session-mode=existing` 使用。

.DESCRIPTION
    shareMATLABSession() 会在 %APPDATA%\MathWorks\MATLAB MCP Server\v1\sessionDetails.json
    写下 port / certificate / apiKey / pid，官方 MCP server 的 existing 模式读它来接入
    一个**已经在跑**的 MATLAB，避免为每次调用冷启动一个 MATLAB（冷启动约 20~60 秒）。

    **关键陷阱：不能用 pause() 持有会话。**

    早期实现用：
        matlab -r "... shareMATLABSession; pause(86400);"

    结果是：
      - shareMATLABSession() 的 HTTP 监听跑在 MATLAB 后台线程，所以
        `GET https://localhost:<port>/` 依然返回 200
        "The connector service is running."，看起来完全正常；
      - 但执行 MATLAB 代码必须回到**主线程**，而主线程被 pause() 永久阻塞；
      - 表现为 MCP initialize / tools/list 全部正常，tools/call 永远挂起
        （实测 300 秒无任何响应，且服务端 stderr 干净、无错误可查）。

    本实现改用一个空转 timer 让 MATLAB 事件循环保持运行：timer 回调进入主线程队列，
    主线程空闲即可对外服务，既不退出、也不占住主线程。

    **另一个约束：会话文件会被任何一次 MATLAB 启动重写**（含 `matlab -batch`）。
    所以持有共享会话期间，不要在机器上再启动任何 MATLAB 进程，否则 existing 模式
    会指向一个刚刚覆写掉的、已经失效的会话。

.PARAMETER HoldMinutes
    持有会话的分钟数。到点后回收 MATLAB 进程。

.PARAMETER Work
    工作目录，也是信号文件与会话快照的落盘位置。

.PARAMETER MatlabExe
    matlab.exe 路径。默认从 PATH 与常见安装位置解析。

.PARAMETER ReadyFilePath
    会话就绪信号文件路径。默认 <Work>\session_ready.json。

.PARAMETER StopFilePath
    停止信号文件路径。默认 <Work>\stop_session.flag。文件出现即提前结束持有。

.OUTPUTS
    [pscustomobject] Port / Pid / Certificate / ApiKey / ReadyFilePath / HoldMinutes

.EXAMPLE
    .\Start-MatlabSharedSession.ps1 -HoldMinutes 30

.NOTES
    ApiKey 是本地回环服务的临时凭据，只在本机内存与用户配置目录内流转；
    本函数输出它仅为便于调用方调试，不要在日志或 CI 输出里回显。
#>
[CmdletBinding()]
param(
    [int]$HoldMinutes = 25,
    [string]$Work = ".",
    [string]$MatlabExe = "",
    [string]$ReadyFilePath = "",
    [string]$StopFilePath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $Work) { $Work = (Get-Location).Path }
$Work = (Resolve-Path -LiteralPath $Work).Path
if (-not (Test-Path -LiteralPath $Work)) {
    New-Item -ItemType Directory -Force -Path $Work | Out-Null
}
if (-not $ReadyFilePath) { $ReadyFilePath = Join-Path $Work "session_ready.json" }
if (-not $StopFilePath) { $StopFilePath = Join-Path $Work "stop_session.flag" }

# ---- 解析 matlab.exe ----
# 复用 Execution 模块的解析逻辑（显式 > MATLAB_EXE > PATH > MATLAB_ROOT > 全盘扫描），
# 不在这里硬编码任何盘符或安装路径——仓库有卫生检查禁止盘符硬编码。
$matlabModule = Join-Path $PSScriptRoot "MatlabAgentSkills.Execution.psm1"
if (-not (Test-Path -LiteralPath $matlabModule)) {
    throw "未找到 $matlabModule"
}
Import-Module -Name $matlabModule -Force -DisableNameChecking -ErrorAction Stop

if (-not $MatlabExe) {
    $MatlabExe = Resolve-MatlabExecutable -ErrorAction SilentlyContinue
}
if (-not $MatlabExe -or -not (Test-Path -LiteralPath $MatlabExe)) {
    throw "未找到 matlab.exe；请用 -MatlabExe 显式指定，或设置 MATLAB_EXE 环境变量"
}

$sessionFile = Join-Path $env:APPDATA "MathWorks\MATLAB MCP Server\v1\sessionDetails.json"
$logFile = Join-Path $Work "matlab_shared_session.log"

foreach ($f in @($ReadyFilePath, $StopFilePath, $logFile)) {
    if (Test-Path -LiteralPath $f) { [System.IO.File]::Delete($f) }
}
$before = if (Test-Path -LiteralPath $sessionFile) { (Get-Item -LiteralPath $sessionFile).LastWriteTime } else { $null }

# ---- 启动 MATLAB：用空转 timer 保持事件循环，绝不用 pause() 阻塞主线程 ----
$startup = "disp('BOOT_OK'); shareMATLABSession; disp('SESSION_SHARED'); " +
           "t=timer('Period',600,'ExecutionMode','fixedSpacing','TimerFcn',@(~,~)[]); start(t);"

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $MatlabExe
$psi.Arguments = "-nosplash -nodesktop -logfile `"$logFile`" -r `"$startup`""
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.WorkingDirectory = $Work

$process = New-Object System.Diagnostics.Process
$process.StartInfo = $psi
$process.Start() | Out-Null
Write-Verbose "MATLAB launcher pid=$($process.Id)"

# ---- 等会话文件刷新 ----
$deadline = (Get-Date).AddSeconds(180)
$shared = $false
while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $sessionFile) {
        $item = Get-Item -LiteralPath $sessionFile
        if ($null -eq $before -or $item.LastWriteTime -gt $before) { $shared = $true; break }
    }
    Start-Sleep -Milliseconds 500
}

if (-not $shared) {
    $tail = ""
    if (Test-Path -LiteralPath $logFile) {
        $tail = (Get-Content -LiteralPath $logFile -Encoding utf8 | Select-Object -Last 20) -join "`n"
    }
    throw "MATLAB 未在 180 秒内共享会话。日志尾部：`n$tail"
}

Start-Sleep -Seconds 2
$session = Get-Content -Raw -LiteralPath $sessionFile | ConvertFrom-Json

# ---- 自检：会话必须真的能执行代码，而不只是端口在听 ----
# 这一步专门用来抓"pause() 阻塞主线程"那一类假活会话：
# HTTP 监听在后台线程，端口探活会通过，但 tools/call 会永久挂起。
$probe = $null
try {
    $probe = Invoke-RestMethod -Uri "https://localhost:$($session.port)/" -SkipCertificateCheck -TimeoutSec 10 -Proxy $null -ErrorAction Stop
} catch {
    Write-Verbose "端口自检未通过（不视为致命）：$($_.Exception.Message)"
}

$ready = [pscustomobject]@{
    Port            = [int]$session.port
    Pid             = [int]$session.pid
    Certificate     = "$($session.certificate)"
    ApiKey          = "$($session.apiKey)"
    ReadyFilePath   = $ReadyFilePath
    HoldMinutes     = $HoldMinutes
    PortProbe       = ("$probe" -ne "")
    ObservedAt      = (Get-Date).ToString("o")
}
$ready | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ReadyFilePath -Encoding utf8

Write-Host "SESSION_READY port=$($ready.Port) pid=$($ready.Pid) hold=${HoldMinutes}m"

# ---- 持有 ----
$stopAt = (Get-Date).AddMinutes($HoldMinutes)
while ((Get-Date) -lt $stopAt) {
    if (Test-Path -LiteralPath $StopFilePath) { Write-Host "STOP_FILE detected"; break }
    if ($process.HasExited) { Write-Host "MATLAB_PROCESS_EXITED"; break }
    Start-Sleep -Seconds 2
}

foreach ($id in @($ready.Pid, $process.Id)) {
    try {
        $p = Get-Process -Id ([int]$id) -ErrorAction SilentlyContinue
        if ($p) { Stop-Process -Id ([int]$id) -Force -ErrorAction SilentlyContinue; Write-Host "KILLED $id" }
    } catch { }
}
Write-Host "HOLDER_DONE"
return $ready
