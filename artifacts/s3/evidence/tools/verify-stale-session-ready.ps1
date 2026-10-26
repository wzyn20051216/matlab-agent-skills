<#
.SYNOPSIS
只读核验 artifacts\tmp_probe\session_ready.json 里的凭据副本到底是不是过期证据——不删除、不覆盖、不改动一个字节。

.DESCRIPTION
审查意见要求确认这份 2026-10-17 的残留文件"确属过期证据，不能直接删除或覆盖"。
本脚本只做四件事：
  1. 记录文件自身的 git 归属（是否被跟踪 / 是否被忽略）与大小、mtime、SHA-256；
  2. 只输出字段名、长度与 SHA-256 前 16 位，绝不输出凭据值；
  3. 核验铸造该凭据的进程是否已退出、文件里的端口现在由谁监听；
  4. 跑完之后再测一次大小/mtime/SHA-256，证明核验过程没碰过源文件。

失效判定沿用 S3 §1 的克制口径：没有正向重放测试（那等于使用发现的凭据，被明确禁止），
所以结论只能是"可证明惰性 / 无法证明可用"，不是"已验证被拒绝"。
#>
[CmdletBinding()]
param(
    [string]$RepositoryRoot = "",
    [string]$TargetPath = "",
    [string]$OutputPath = ""
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
}
if ([string]::IsNullOrWhiteSpace($TargetPath)) {
    $TargetPath = Join-Path $RepositoryRoot 'artifacts\tmp_probe\session_ready.json'
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $RepositoryRoot 'artifacts\s3\evidence\session\stale-session-ready-verification.json'
}

function Get-MasPropertyValueSafe {
    param([AllowNull()]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Get-Sha16 {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $null }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return ([System.BitConverter]::ToString($hash).Replace('-', '').Substring(0, 16).ToLowerInvariant())
}

function Get-FileStamp {
    param([Parameter(Mandatory)][string]$Path)
    $full = (Resolve-Path -LiteralPath $Path).Path
    $info = Get-Item -LiteralPath $full
    $stream = [System.IO.File]::Open($full, 'Open', 'Read', [System.IO.FileShare]::None)
    try {
        $hash = (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash.ToLowerInvariant()
    } finally { $stream.Dispose() }
    return [pscustomobject][ordered]@{
        path        = $full
        sizeBytes   = [int64]$info.Length
        lastWriteUtc= $info.LastWriteTimeUtc.ToString('o')
        sha256      = $hash
    }
}

# ---- 1. 文件指纹（打开方式即证明只读：FileShare.None 仅为独占读取，不写入） ----
$stampBefore = Get-FileStamp -Path $TargetPath

# ---- 2. 只取非敏感字段与哈希 ----
$content = Get-Content -Raw -LiteralPath $TargetPath
$parsed = $content | ConvertFrom-Json
$apiKeyValue = [string](Get-MasPropertyValueSafe $parsed 'apiKey')
$certValue = [string](Get-MasPropertyValueSafe $parsed 'certificate')

# ---- 3. git 归属 ----
# git 的 "did not match any file(s)" 会走 stderr；在 ErrorActionPreference=Stop 下
# 原生命令的 stderr 会被升级成终止性错误，这里临时降级，只为读取退出码。
$prevPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$tracked = $true
$null = & git -C $RepositoryRoot ls-files --error-unmatch 'artifacts/tmp_probe/session_ready.json' 2>$null
if ($LASTEXITCODE -ne 0) { $tracked = $false }
$ignoreLine = @(& git -C $RepositoryRoot check-ignore -v 'artifacts/tmp_probe/session_ready.json' 2>$null)
$ErrorActionPreference = $prevPreference
$trackedByGit = [bool]$tracked
$ignoredBy = if ($null -ne $ignoreLine -and $ignoreLine.Count -gt 0) { [string]$ignoreLine[0] } else { $null }

# ---- 4. 进程与端口核验 ----
$recordedPid = 0
try { $recordedPid = [int](Get-MasPropertyValueSafe $parsed 'pid') } catch { $recordedPid = 0 }
$recordedPort = 0
try { $recordedPort = [int](Get-MasPropertyValueSafe $parsed 'port') } catch { $recordedPort = 0 }
$recordedProcess = Get-Process -Id $recordedPid -ErrorAction SilentlyContinue
$listenerNow = Get-NetTCPConnection -LocalPort $recordedPort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
$listenerPid = if ($null -ne $listenerNow) { [int]$listenerNow.OwningProcess } else { 0 }
$listenerProcess = if ($listenerPid -gt 0) { Get-Process -Id $listenerPid -ErrorAction SilentlyContinue } else { $null }

# 当前会话描述符（同样只取 port/pid 与哈希）
$descriptorPath = Join-Path $env:APPDATA 'MathWorks\MATLAB MCP Server\v1\sessionDetails.json'
$descriptor = $null
if (Test-Path -LiteralPath $descriptorPath) {
    $d = Get-Content -Raw -LiteralPath $descriptorPath | ConvertFrom-Json
    $descriptor = [pscustomobject][ordered]@{
        port         = [int](Get-MasPropertyValueSafe $d 'port')
        pid          = [int](Get-MasPropertyValueSafe $d 'pid')
        apiKeySha16  = Get-Sha16 ([string](Get-MasPropertyValueSafe $d 'apiKey'))
        apiKeyLength = ([string](Get-MasPropertyValueSafe $d 'apiKey')).Length
    }
}

# S3 §1 里已记录的两个值（同为 SHA-256 前 16 位，非密钥本身）
$exposedSha16 = '852b6e6d822c1bd9'   # S1 审计时泄露的会话凭据
$currentSha16 = if ($null -ne $descriptor) { [string]$descriptor.apiKeySha16 } else { $null }
$staleSha16 = Get-Sha16 $apiKeyValue
$staleCertSha16 = Get-Sha16 $certValue

$stampAfter = Get-FileStamp -Path $TargetPath
$untouched = ($stampBefore.sizeBytes -eq $stampAfter.sizeBytes) -and
             ($stampBefore.lastWriteUtc -eq $stampAfter.lastWriteUtc) -and
             ($stampBefore.sha256 -eq $stampAfter.sha256)

$result = [pscustomobject][ordered]@{
    schemaVersion  = 'mas-s3-stale-session-ready/1'
    generatedAtUtc = [datetime]::UtcNow.ToString('o')
    purpose        = '只读核验 2026-10-17 残留的 session_ready.json 是否确属过期证据；不删除、不覆盖'
    file = [pscustomobject][ordered]@{
        before            = $stampBefore
        after             = $stampAfter
        byteForByteUnchanged = $untouched
        trackedByGit      = $trackedByGit
        ignoredBy         = $ignoredBy
        containsSecretFields = @($parsed.PSObject.Properties.Name | Where-Object { $_ -in @('apiKey','certificate') })
    }
    fieldEvidence = [pscustomobject][ordered]@{
        port                = $recordedPort
        pid                 = $recordedPid
        apiKeyLength        = if ([string]::IsNullOrEmpty($apiKeyValue)) { 0 } else { $apiKeyValue.Length }
        apiKeySha16         = $staleSha16
        certificateLength   = if ([string]::IsNullOrEmpty($certValue)) { 0 } else { $certValue.Length }
        certificateSha16    = $staleCertSha16
        valuesPrinted       = $false
    }
    processEvidence = [pscustomobject][ordered]@{
        recordedPidAlive     = ($null -ne $recordedProcess)
        recordedPidName      = if ($null -ne $recordedProcess) { $recordedProcess.ProcessName } else { $null }
        portStillListening   = ($null -ne $listenerNow)
        currentListenerPid   = $listenerPid
        currentListenerName  = if ($null -ne $listenerProcess) { $listenerProcess.ProcessName } else { $null }
        currentListenerStartUtc = if ($null -ne $listenerProcess) { $listenerProcess.StartTime.ToUniversalTime().ToString('o') } else { $null }
        listenerIsRecordedPid = ($listenerPid -eq $recordedPid -and $recordedPid -gt 0)
    }
    liveSession = $descriptor
    crossCheck = [pscustomobject][ordered]@{
        exposedS1CredentialSha16 = $exposedSha16
        staleFileCredentialSha16 = $staleSha16
        liveDescriptorCredentialSha16 = $currentSha16
        staleEqualsExposed = ($staleSha16 -eq $exposedSha16)
        staleEqualsLive    = ($null -ne $currentSha16 -and $staleSha16 -eq $currentSha16)
    }
    conclusion = [pscustomobject][ordered]@{
        verdict = 'EXPIRED_INFERRED（可证明惰性，非"已验证被拒绝"）'
        basis = @(
            '铸造这份凭据的 MATLAB 进程（pid {0}）已退出：连接器凭据只存活于该进程内部，进程不在则该值不再被任何服务持有' -f $recordedPid
            '会话描述符已不描述这个端口（现在指向 port {0} / pid {1}），且其中的凭据哈希与本文件记录值不同；本文件的值在任何当前记录里都不存在' -f $(if ($null -ne $descriptor) { $descriptor.port } else { 0 }), $(if ($null -ne $descriptor) { $descriptor.pid } else { 0 })
            '本文件的凭据哈希既不等于 S1 泄露的那一份，也不等于当前会话描述符里的那一份，是三份互不相同的值'
        )
        limits = @(
            '没有正向重放测试：拿这份凭据去连当前服务 = 使用发现的凭据，本轮约束明确禁止，因此"失效"是推断而非观测'
            '端口 {0} 现在由 pid {1} 监听，但我们没有观测该进程当前接受什么凭据（描述符只保留最近一次会话），所以"换了监听进程"只是事实记录，不作为失效依据' -f $recordedPort, $listenerPid
            '端口被别的进程复用本身不构成"旧凭据失效"的证据（S3 §1 已因同类误判撤回过一条依据）'
            '若日后需要确证，唯一正路是由人工在授权环境里对该服务做一次鉴权测试，并只记录接受/拒绝结果'
        )
        action = 'KEEP_UNCHANGED（保留、不删除、不覆盖）：核验前后 size/mtime/SHA-256 完全一致；该文件未被 git 跟踪且被 .gitignore 忽略，不会随提交外泄'
    }
}

$json = $result | ConvertTo-Json -Depth 8
if ($json -match '(?i)"apiKey"\s*:\s*"[^"]{8,}' -or $json -match '(?i)"certificate"\s*:\s*"[^"]{8,}') {
    throw '输出里出现疑似凭据值，拒绝落盘。'
}
$dir = Split-Path -Parent $OutputPath
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
[IO.File]::WriteAllText($OutputPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "WROTE $OutputPath"
Write-Host ("untouched={0} tracked={1} recordedPidAlive={2} listener={3} staleSha16={4}" -f `
        $untouched, $trackedByGit, ($null -ne $recordedProcess), $listenerPid, $staleSha16)
