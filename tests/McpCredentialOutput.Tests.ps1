<#
.SYNOPSIS
会话凭据输出面回归：探测对象、验收报告、阶段日志都不得出现 apiKey 或其绝对路径。

.DESCRIPTION
仅“把字符串里的值替换掉”不足以证明输出面安全。本用例直接检查三个落盘点：
  - Get-McpSessionInfo 的序列化结果（不能再有 ApiKey 属性）；
  - Invoke-McpStagedProbe 生成的验收报告（只允许文件名 + 指纹）；
  - Write-StageLog 写入的阶段日志（命令文本可能带 Authorization / --api-key）。

所有凭据都是合成值，测试目录在仓库 artifacts/ 下，不读取真实用户会话文件。
#>

. (Join-Path $PSScriptRoot 'helpers/Assertions.ps1')

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $script:RepoRoot 'scripts/MatlabAgentSkills.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $script:RepoRoot 'scripts/MatlabAgentSkills.Acceptance.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $script:RepoRoot 'scripts/MatlabAgentSkills.Execution.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $script:RepoRoot 'scripts/MatlabAgentSkills.McpProbe.psm1') -Force -DisableNameChecking

$script:FakeApiKey = 'FAKE-SESSION-KEY-0123456789ABCDEF'
$script:FakeBearer = 'FAKEBEARERTOKEN0123456789'
$script:FakeUuid = '11111111-2222-3333-4444-555555555555'

function New-CredentialSandbox {
    $root = Join-Path $script:RepoRoot ('artifacts\tmp_credential_tests\' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    return [pscustomobject]@{
        Root          = $root
        SessionFile   = (Join-Path $root 'sessionDetails.json')
        Certificate   = (Join-Path $root 'cert.pem')
        StageLog      = (Join-Path $root 'stages.log')
        ReportPath    = (Join-Path $root 'mcp_probe.json')
    }
}

function Remove-CredentialSandbox {
    param($Sandbox)
    if ($null -eq $Sandbox) { return }
    $full = [IO.Path]::GetFullPath($Sandbox.Root)
    $expectedPrefix = [IO.Path]::GetFullPath((Join-Path $script:RepoRoot 'artifacts\tmp_credential_tests')).TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($expectedPrefix)) { throw '测试目录越界，拒绝删除。' }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue }
}

function New-FakeSessionFile {
    param($Sandbox)
    Set-Content -LiteralPath $Sandbox.Certificate -Value '-----BEGIN CERTIFICATE-----' -Encoding ascii
    $session = [ordered]@{
        port        = 1
        certificate = $Sandbox.Certificate
        apiKey      = $script:FakeApiKey
        pid         = $PID
    }
    $session | ConvertTo-Json | Set-Content -LiteralPath $Sandbox.SessionFile -Encoding UTF8
}

Describe '会话凭据不出现在可序列化对象与报告中' {
    It 'Get-McpSessionInfo 只暴露是否存在与长度，序列化后无 apiKey 值' {
        $sandbox = New-CredentialSandbox
        try {
            New-FakeSessionFile $sandbox
            $info = Get-McpSessionInfo -SessionFile $sandbox.SessionFile
            ($info.PSObject.Properties.Name -contains 'ApiKey') | Should Be $false
            $info.HasApiKey | Should Be $true
            $info.ApiKeyLength | Should Be $script:FakeApiKey.Length

            $json = $info | ConvertTo-Json -Depth 6
            $json | Should Not Match ([regex]::Escape($script:FakeApiKey))
            $json | Should Not Match '"ApiKey"\s*:'
        }
        finally { Remove-CredentialSandbox $sandbox }
    }

    It '鉴权仍可用：内部凭据读取函数能取回同一个值' {
        $sandbox = New-CredentialSandbox
        try {
            New-FakeSessionFile $sandbox
            $null = Get-McpSessionInfo -SessionFile $sandbox.SessionFile
            $credential = Get-McpSessionCredential -SessionFile $sandbox.SessionFile
            ([string]::Equals([string]$credential, $script:FakeApiKey, [System.StringComparison]::Ordinal)) | Should Be $true
        }
        finally { Remove-CredentialSandbox $sandbox }
    }

    It '验收报告只记录会话文件名与指纹，不含绝对路径或凭据' {
        $sandbox = New-CredentialSandbox
        try {
            New-FakeSessionFile $sandbox
            $report = Invoke-McpStagedProbe -SessionFile $sandbox.SessionFile -RepositoryRoot $sandbox.Root `
                -Backend 'matlab-mcp-existing' -Scheme 'http' -EndpointPath '/mcp' `
                -MatlabPath (Join-Path $sandbox.Root 'no-matlab.exe') `
                -IoProbeDirectory (Join-Path $sandbox.Root 'io_probe') `
                -TimeoutSeconds 2 -SkipStage1 -SkipCodexCli -SkipUserConfigs -SkipTlsValidation

            $sessionCheck = @($report.checks | Where-Object { $_.id -eq 'mcp.session-config' })[0]
            $sessionCheck.metrics.sessionFile | Should Be 'sessionDetails.json'
            $sessionCheck.metrics.sessionFileSha256 | Should Match '^[0-9A-F]{64}$'
            ($sessionCheck.metrics.Keys -contains 'sessionFile') | Should Be $true
            @($sessionCheck.artifactPaths).Count | Should Be 0

            $json = $report | ConvertTo-Json -Depth 20
            $json | Should Not Match ([regex]::Escape($script:FakeApiKey))
            $json | Should Not Match ([regex]::Escape($sandbox.SessionFile))
            $json | Should Not Match '(?i)"sessionFilePath"'
        }
        finally { Remove-CredentialSandbox $sandbox }
    }
}

Describe '阶段日志落盘前必须脱敏' {
    It 'Authorization / --api-key / 裸 UUID 不会进入阶段日志' {
        $sandbox = New-CredentialSandbox
        try {
            $detail = 'pwsh -Command "tool --api-key ' + $script:FakeBearer + '" ; Authorization: Bearer ' + $script:FakeBearer + ' ; id=' + $script:FakeUuid
            Write-StageLog -Path $sandbox.StageLog -Stage 'credential-test' -Detail $detail

            $text = Get-Content -Raw -LiteralPath $sandbox.StageLog
            $text | Should Not Match ([regex]::Escape($script:FakeBearer))
            $text | Should Not Match ([regex]::Escape($script:FakeUuid))
            $text | Should Match 'credential-test'
            $text | Should Match '\[REDACTED'
        }
        finally { Remove-CredentialSandbox $sandbox }
    }

    It '普通启动命令保持可读' {
        $sandbox = New-CredentialSandbox
        try {
            Write-StageLog -Path $sandbox.StageLog -Stage 'launch' -Detail 'matlab.exe -batch disp(version)'
            $text = Get-Content -Raw -LiteralPath $sandbox.StageLog
            $text | Should Match 'matlab\.exe -batch disp\(version\)'
            $text | Should Not Match '\[REDACTED'
        }
        finally { Remove-CredentialSandbox $sandbox }
    }
}
