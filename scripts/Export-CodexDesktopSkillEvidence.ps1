<#
.SYNOPSIS
从真实 Desktop 会话导出技能注入及正文读取证据，避免用磁盘存在代替发现。
.DESCRIPTION
仅读取指定会话的 session_meta、开发者注入的 MATLAB 技能目录行以及读取技能的
工具调用/返回。加载记录只保存名称、哈希及来源指针，不复制混合调用的原始内容、
用户消息、推理或整份会话，也不宣称 MATLAB 执行通过。
CLI 的证据必须来自另一个独立 CLI 进程，不能用此导出代替。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SessionFile,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'

function Get-EvidenceTextSha256 {
    <#
    .SYNOPSIS
    对观察文本的 UTF-8 字节计算摘要，避免将混合调用中的无关内容复制到证据。
    #>
    param([AllowEmptyString()][string]$Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        [BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-', '')
    } finally { $algorithm.Dispose() }
}

$sourceStream = [IO.File]::Open($SessionFile, [IO.FileMode]::Open, [IO.FileAccess]::Read,
    ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
$snapshot = New-Object IO.MemoryStream
try { $sourceStream.CopyTo($snapshot); $sourceBytes = $snapshot.ToArray() }
finally { $sourceStream.Dispose(); $snapshot.Dispose() }
$hashAlgorithm = [Security.Cryptography.SHA256]::Create()
try { $sourceHash = [BitConverter]::ToString($hashAlgorithm.ComputeHash($sourceBytes)).Replace('-', '') }
finally { $hashAlgorithm.Dispose() }
$sourceText = [Text.Encoding]::UTF8.GetString($sourceBytes).TrimStart([char]0xFEFF)
$events = @($sourceText -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object {
    try { $_ | ConvertFrom-Json } catch { throw "会话 JSONL 损坏：$($_.Exception.Message)" }
})
$meta = $events | Where-Object { $_.type -eq 'session_meta' } | Select-Object -First 1
# originator 不能区分客户端：CLI 0.147.0 的 exec 会话同样写 'Codex Desktop'。
# 真实 Desktop UI 会话的判据是 source='vscode' 且会话内出现 <app-context> 标记。
$sessionSource = if ($meta) { [string]$meta.payload.source } else { '' }
# 真实客户端的 JSONL 用字面 <app-context>；由 PowerShell ConvertTo-Json 生成的夹具
# 会把 < 转义成 \u003c，两种编码都要认，否则合法会话会被误判成非桌面会话。
$hasAppContext = $sourceText.Contains('<app-context>') -or $sourceText.Contains('\u003capp-context\u003e')
if (-not $meta -or $meta.payload.originator -ne 'Codex Desktop' -or $sessionSource -ne 'vscode' -or -not $hasAppContext) {
    throw ('输入不是真实 Desktop UI 会话（要求 originator=Codex Desktop、source=vscode、且含 <app-context>；' +
        "实际 originator=$($meta.payload.originator)、source=$sessionSource、appContext=$hasAppContext）。CLI exec 会话不能替代桌面端证据。")
}
$catalog = @($events | Where-Object {
    $_.type -eq 'response_item' -and $_.payload.type -eq 'message' -and
    $_.payload.role -eq 'developer'
} | ForEach-Object {
    ($_.payload.content.text -join "`n") -split "`r?`n" | Where-Object {
        $_ -match '^- (matlab-[a-z-]+):.*\(file:'
    }
} | Select-Object -Unique)
$names = @($catalog | ForEach-Object {
    if ($_ -match '^- (matlab-[a-z-]+):') { $Matches[1] }
} | Select-Object -Unique)
$reads = @($events | Where-Object {
    $_.type -eq 'response_item' -and $_.payload.type -eq 'custom_tool_call' -and
    $_.payload.input -match 'Get-Content' -and
    $_.payload.input -match '\.agents[\\/]+skills[\\/]+matlab-' -and
    $_.payload.input -notmatch '\.workbuddy'
} | ForEach-Object {
    $call = $_
    $response = $events | Where-Object {
        $_.type -eq 'response_item' -and $_.payload.type -eq 'custom_tool_call_output' -and
        $_.payload.call_id -eq $call.payload.call_id
    } | Select-Object -First 1
    # 仅选取返回技能正文的读取；未完成调用不能构成加载证据。
    $responseText = if ($response.payload.output -is [string]) {
        $response.payload.output
    } else { $response.payload.output.text -join "`n" }
    $failedResponse = ($response.payload.isError -eq $true) -or [bool]$response.payload.error -or
        ($responseText -match '(?m)^Script (?:failed|error)\b|"exit_code"\s*:\s*-[0-9]+|"exit_code"\s*:\s*[1-9][0-9]*|"isError"\s*:\s*true')
    # 同批其他文件可能也含 name:；只关联输入中实际请求读取的共享 SKILL.md。
    $requestedNames = @([regex]::Matches([string]$call.payload.input,
        '(?i)\.agents[\\/]+skills[\\/]+(matlab-[a-z0-9]+(?:-[a-z0-9]+)*)[\\/]+SKILL\.md') |
        ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() } | Select-Object -Unique)
    # 名称只取平台已注入的目录项；工具返回中的其他文本永不进入导出文件。
    $observedNames = @([regex]::Matches($responseText, 'name:\s*(matlab-[a-z0-9]+(?:-[a-z0-9]+)*)(?![a-z0-9_-])') |
        ForEach-Object { $_.Groups[1].Value } | Where-Object { $names -contains $_ -and $requestedNames -contains $_ } |
        Select-Object -Unique)
    if ($response -and -not $failedResponse -and $observedNames.Count -gt 0) {
        [pscustomobject][ordered]@{
            callId = $call.payload.call_id
            timestamp = $call.timestamp
            inputSha256 = Get-EvidenceTextSha256 -Text ([string]$call.payload.input)
            outputSha256 = Get-EvidenceTextSha256 -Text $responseText
            observedSkillNames = $observedNames
            # 零基序号对应 sourceHash 快照中按非空行解码后的事件数组。
            sourcePointer = [ordered]@{
                callEventIndex = [Array]::IndexOf($events, $call)
                outputEventIndex = [Array]::IndexOf($events, $response)
            }
        }
    }
})
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$result = [pscustomobject][ordered]@{
    schema = 'mas-desktop-skill-evidence/2'
    generatedAt = (Get-Date).ToString('o')
    sourceSession = (Resolve-Path -LiteralPath $SessionFile).Path
    sourceHash = $sourceHash
    sessionId = $meta.payload.id
    client = $meta.payload.originator
    sessionSource = $sessionSource
    appContextPresent = $hasAppContext
    engineVersion = $meta.payload.cli_version
    startedAt = $meta.timestamp
    skillDiscovery = [ordered]@{
        source = '真实会话中平台注入的 developer Available skills 目录'
        names = $names
        catalogLines = $catalog
    }
    loads = $reads
    limitations = @('此文件记录本会话的发现与技能正文标识；调用及数值验收需独立 MCP 返回。',
        '运行中会话会继续追加，sourceHash 仅标识导出时快照。',
        '加载记录仅含观察名称、文本 UTF-8 SHA256 和零基事件指针；不复制混合调用的原始输入输出。')
}
$target = Join-Path $OutputDirectory 'skill_evidence.json'
[IO.File]::WriteAllText($target, ($result | ConvertTo-Json -Depth 12),
    (New-Object Text.UTF8Encoding($false)))
[pscustomobject]@{path=$target; discovered=$names.Count; loadCalls=$reads.Count; client=$result.client}
