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

Describe '进程 stdout stderr 与元数据落盘前保护' {
    It '观察子进程运行期间的日志也没有先明文落盘再擦除的窗口' {
        $sandbox = New-CredentialSandbox
        $observer = $null
        try {
            $child = Join-Path $sandbox.Root 'stream-child.ps1'
            $ready = Join-Path $sandbox.Root 'stream-ready.txt'
            $stdout = Join-Path $sandbox.Root 'stream.stdout.log'
            $stderr = Join-Path $sandbox.Root 'stream.stderr.log'
            $childText = "[Console]::Out.WriteLine('password=SYNTHETIC-LIVE-OUT'); [Console]::Out.Flush(); [Console]::Error.WriteLine('token=SYNTHETIC-LIVE-ERR'); [Console]::Error.Flush(); [IO.File]::WriteAllText('" + $ready.Replace("'", "''") + "','READY'); Start-Sleep -Seconds 3"
            [IO.File]::WriteAllText($child, $childText, (New-Object Text.UTF8Encoding($true)))
            $harness = Join-Path $sandbox.Root 'stream-harness.ps1'
            $module = Join-Path $script:RepoRoot 'scripts/MatlabAgentSkills.Execution.psm1'
            $harnessText = @'
param($Module, $Child, $Root, $Stdout, $Stderr, $Stage)
Import-Module $Module -Force -DisableNameChecking
$r = Invoke-MatlabBatchProcess -MatlabPath ((Get-Process -Id $PID).Path) -ArgumentList @('-NoProfile','-File',$Child) -WorkingDirectory $Root -StdoutPath $Stdout -StderrPath $Stderr -StageLogPath $Stage -TimeoutSeconds 15
exit $r.ExitCode
'@
            [IO.File]::WriteAllText($harness, $harnessText, (New-Object Text.UTF8Encoding($true)))
            $psi = New-Object Diagnostics.ProcessStartInfo
            $psi.FileName = (Get-Process -Id $PID).Path
            $psi.Arguments = (@('-NoProfile','-File',$harness,$module,$child,$sandbox.Root,$stdout,$stderr,$sandbox.StageLog) | ForEach-Object { Format-ProcessArgument -Argument $_ }) -join ' '
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $observer = New-Object Diagnostics.Process
            $observer.StartInfo = $psi
            $observer.Start() | Out-Null
            $deadline = (Get-Date).AddSeconds(12)
            while (-not (Test-Path -LiteralPath $ready) -and -not $observer.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 40 }
            (Test-Path -LiteralPath $ready) | Should Be $true
            $observedWhileRunning = 0
            while (-not $observer.HasExited -and (Get-Date) -lt $deadline) {
                foreach ($path in @($stdout, $stderr)) {
                    if (Test-Path -LiteralPath $path) {
                        $stream = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
                        $reader = New-Object IO.StreamReader($stream)
                        try { $reader.ReadToEnd() | Should Not Match 'SYNTHETIC-LIVE' }
                        finally { $reader.Dispose() }
                    }
                }
                $observedWhileRunning++
                Start-Sleep -Milliseconds 40
            }
            $observer.WaitForExit(5000) | Should Be $true
            $observer.ExitCode | Should Be 0
            $observedWhileRunning | Should BeGreaterThan 5
            ([IO.File]::ReadAllText($stdout) + [IO.File]::ReadAllText($stderr)) | Should Not Match 'SYNTHETIC-LIVE'
        } finally {
            if ($observer -and -not $observer.HasExited) { Stop-ProcessTree -ProcessId $observer.Id }
            if ($observer) { $observer.Dispose() }
            Remove-CredentialSandbox $sandbox
        }
    }

    It '子进程原始输出不先写入明文日志' {
        $sandbox = New-CredentialSandbox
        try {
            $child = Join-Path $sandbox.Root 'synthetic-child.ps1'
            $source = @'
[Console]::Out.WriteLine('{"x-mcp-api-key":"SYNTHETIC-CHILD-STDOUT"}')
[Console]::Out.WriteLine('matrix=[1 2;3 4]')
[Console]::Error.WriteLine('Authorization: Bearer SYNTHETIC-CHILD-STDERR')
'@
            [IO.File]::WriteAllText($child, $source, (New-Object Text.UTF8Encoding($true)))
            $stdout = Join-Path $sandbox.Root 'stdout.log'
            $stderr = Join-Path $sandbox.Root 'stderr.log'
            $result = Invoke-MatlabBatchProcess -MatlabPath ((Get-Process -Id $PID).Path) -ArgumentList @('-NoProfile', '-File', $child) -WorkingDirectory $sandbox.Root -TimeoutSeconds 20 -StdoutPath $stdout -StderrPath $stderr -StageLogPath $sandbox.StageLog
            $result.ExitCode | Should Be 0
            ([IO.File]::ReadAllText($stdout) + [IO.File]::ReadAllText($stderr)) | Should Not Match 'SYNTHETIC-CHILD-STD'
            [IO.File]::ReadAllText($stdout) | Should Match 'matrix=\[1 2;3 4\]'
            ($result | ConvertTo-Json -Depth 8) | Should Not Match 'SYNTHETIC-CHILD-STD'
        } finally { Remove-CredentialSandbox $sandbox }
    }

    It '通用短进程边界同样保护标准输出和错误输出' {
        $sandbox = New-CredentialSandbox
        try {
            $child = Join-Path $sandbox.Root 'synthetic-cli.ps1'
            [IO.File]::WriteAllText($child, "[Console]::Out.WriteLine('password=SYNTHETIC-CLI-PASSWORD'); [Console]::Error.WriteLine('x-mcp-api-key: SYNTHETIC-CLI-KEY')", (New-Object Text.UTF8Encoding($true)))
            $result = Invoke-ProcessWithTimeout -FilePath ((Get-Process -Id $PID).Path) -ArgumentList @('-NoProfile', '-File', $child) -WorkingDirectory $sandbox.Root
            $result.ExitCode | Should Be 0
            ($result | ConvertTo-Json -Depth 8) | Should Not Match 'SYNTHETIC-CLI'
        } finally { Remove-CredentialSandbox $sandbox }
    }

    It '阶段名称与阶段内容均不得泄漏凭据' {
        $sandbox = New-CredentialSandbox
        try {
            Write-StageLog -Path $sandbox.StageLog -Stage 'password=SYNTHETIC-STAGE-PASSWORD' -Detail 'normal diagnostic'
            [IO.File]::ReadAllText($sandbox.StageLog) | Should Not Match 'SYNTHETIC-STAGE-PASSWORD'
            [IO.File]::ReadAllText($sandbox.StageLog) | Should Match 'normal diagnostic'
        } finally { Remove-CredentialSandbox $sandbox }
    }

    It '会话数值字段类型错误产生安全诊断而不是回显原值的异常' {
        $sandbox = New-CredentialSandbox
        try {
            '{"port":"SYNTHETIC-INVALID-PORT","apiKey":"SYNTHETIC-SESSION-KEY"}' | Set-Content -LiteralPath $sandbox.SessionFile -Encoding UTF8
            $info = Get-McpSessionInfo -SessionFile $sandbox.SessionFile
            $info.Error | Should Not BeNullOrEmpty
            ($info | ConvertTo-Json -Depth 6) | Should Not Match 'SYNTHETIC-INVALID-PORT|SYNTHETIC-SESSION-KEY'
        } finally { Remove-CredentialSandbox $sandbox }
    }
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
            $credential = & (Get-Module MatlabAgentSkills.McpProbe) { param($Path) Get-McpSessionCredential -SessionFile $Path } $sandbox.SessionFile
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
                -Transport https -TimeoutSeconds 2 -SkipStage1 -SkipCodexCli -SkipUserConfigs -SkipTlsValidation

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

Describe '鉴权函数的模块边界' {
    It '返回原始鉴权值的内部函数不向普通模块调用者导出' {
        @(Get-Command Get-McpSessionCredential -Module MatlabAgentSkills.McpProbe -ErrorAction SilentlyContinue).Count | Should Be 0
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
