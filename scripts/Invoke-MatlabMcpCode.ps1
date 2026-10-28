<#
.SYNOPSIS
通过官方 MATLAB MCP auto 执行代码，保存原始返回、耗时及真实失败。
.DESCRIPTION
用于客户端原生绑定已失效时重建独立官方 stdio 连接；仍使用 MCP，不切换批处理。
会话启动与数值结果验收分别记录。不得以本脚本的调用成功替代独立数值判定。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CodeFile,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$ServerExe,
    [ValidateRange(1, 900)][int]$TimeoutSeconds = 120,
    [string]$SessionFile
)
$ErrorActionPreference = 'Stop'

function Protect-MasCodeEvidenceValue {
    <# .SYNOPSIS 在 JSON 序列化前按字段和文本行脱敏，保留合法的 JSON 结构。 #>
    param([AllowNull()]$Value)
    return Protect-MasValue -Value $Value -RedactionText '<redacted>' -OmitSensitiveTextLines
}

$repo = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'MatlabAgentSkills.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'MatlabAgentSkills.Execution.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'MatlabAgentSkills.McpStdio.psm1') -Force -DisableNameChecking
if (-not $ServerExe) { $ServerExe = Join-Path $repo 'bin/matlab-mcp-server-windows-x64.exe' }
$OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$code = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $CodeFile).Path)
# 完成回执位于同一次 evalin 的代码末尾：异常或提前 return 不会执行到它。
# 逐行字面量加 char(10)，既保留中文和单引号，也不受文件末尾 % 注释影响。
$completionMarker = 'MAS_MCP_CODE_COMPLETE_' + [guid]::NewGuid().ToString('N')
$receiptCode = $code + "`n" + "fprintf('$completionMarker\n');"
$literalLines = @($receiptCode -split "`r?`n" | ForEach-Object { "'" + $_.Replace("'", "''") + "'" })
$submittedCode = "evalin('base', [" + ($literalLines -join ' char(10) ') + ']);'
$matlabExe = Resolve-MatlabExecutable
if (-not $matlabExe) { throw '没有找到 MATLAB 可执行文件。' }
$matlabRoot = Split-Path -Parent (Split-Path -Parent $matlabExe)
$built = New-MatlabMcpServerArgs -SessionMode auto -MatlabRoot $matlabRoot -DisplayMode desktop -InitializeMatlabOnStartup $true
$argumentLine = ($built.Arguments | ForEach-Object { Format-ProcessArgument -Argument $_ }) -join ' '
$proxyState = Enable-McpLocalhostProxyBypass
if (-not $SessionFile -and $env:APPDATA) { $SessionFile = Join-Path $env:APPDATA 'MathWorks/MATLAB MCP Server/v1/sessionDetails.json' }
$session = $null
$timer = [Diagnostics.Stopwatch]::StartNew()
$record = [ordered]@{schema='mas-mcp-code/2';startedAt=(Get-Date).ToString('o');status='FAIL';reason=$null;code=$code;submittedCode=$submittedCode;completionMarker=$completionMarker;executionCompleted=$false;serverExe=$ServerExe;serverArgs=$built.Arguments}
try {
    $session = Start-McpStdioServer -ServerExe $ServerExe -ServerArgumentLine $argumentLine -WorkingDirectory $repo -CredentialFile $SessionFile
    $init = Send-McpStdioRequest -Session $session -Method initialize -Params @{
        protocolVersion='2024-11-05';capabilities=@{};clientInfo=@{name='mas-codex-evaluation';version='1.0'}
    } -TimeoutSeconds $TimeoutSeconds
    if (-not $init.Ok) { throw "MCP initialize 失败：$($init.Error)" }
    $record.initialize = $init.Result
    $null = Send-McpStdioRequest -Session $session -Method 'notifications/initialized' -Params @{} -Notification
    $response = Send-McpStdioRequest -Session $session -Method 'tools/call' -Params @{
        name='evaluate_matlab_code';arguments=@{code=$submittedCode;project_path=$repo}
    } -TimeoutSeconds $TimeoutSeconds
    $record.response = $response
    $rawText = Get-McpStdioToolText -ResultNode $response.Result
    $text = Protect-MasCodeEvidenceValue -Value $rawText
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'matlab_raw_output.txt'), $text, (New-Object Text.UTF8Encoding($false)))
    if (-not $response.Ok -or -not $response.Result -or $response.Result.isError) {
        throw "官方 MCP 执行失败：$($response.Error) $text"
    }
    $receiptCount = @($rawText -split '\r?\n' | Where-Object { $_.Trim() -ceq $completionMarker }).Count
    if ($receiptCount -ne 1) {
        throw '未观察到本次代码末尾唯一完成回执；传输成功不能证明 MATLAB 代码执行成功。'
    }
    $record.executionCompleted = $true
    $record.status = 'PASS'
} catch { $record.reason = $_.Exception.Message }
finally {
    if ($session) {
        try { $record.shutdown = Stop-McpStdioServer -Session $session }
        catch { $record.shutdownError = $_.Exception.Message }
    }
    Restore-McpProxyEnvironment -State $proxyState
    $timer.Stop()
    $record.finishedAt = (Get-Date).ToString('o')
    $record.durationMs = $timer.ElapsedMilliseconds
    $safeRecord = Protect-MasCodeEvidenceValue -Value $record
    $safeJson = $safeRecord | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'mcp_execution.json'), $safeJson, (New-Object Text.UTF8Encoding($false)))
}
[pscustomobject]@{status=$record.status;reason=$safeRecord.reason;durationMs=$record.durationMs;report=(Join-Path $OutputDirectory 'mcp_execution.json')}
if ($record.status -ne 'PASS') { exit 1 }
