<#
.SYNOPSIS
通过隔离子进程和模拟模块验证代码执行回执及脱敏；不启动官方服务或 MATLAB。
#>
$script:InvokeCodeSource = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Invoke-MatlabMcpCode.ps1'

function Invoke-CodeEvidenceFixture {
    param([string]$Mode, [string]$Code = "x = '中文'; % 文件末尾注释")
    $root = Join-Path ([IO.Path]::GetTempPath()) ('mas-code-evidence-' + [guid]::NewGuid().ToString('N'))
    $scripts = Join-Path $root 'scripts'
    New-Item -ItemType Directory -Path $scripts -Force | Out-Null
    Copy-Item -LiteralPath $script:InvokeCodeSource -Destination (Join-Path $scripts 'Invoke-MatlabMcpCode.ps1')
    $utf8 = New-Object Text.UTF8Encoding($true)
    $core = @'
function Format-ProcessArgument { param($Argument) return [string]$Argument }
function New-MatlabMcpServerArgs { param($SessionMode,$MatlabRoot,$DisplayMode,$InitializeMatlabOnStartup) return [pscustomobject]@{Arguments=@('--simulated-only')} }
Export-ModuleMember -Function *
'@
    $execution = @'
function Resolve-MatlabExecutable { return (Join-Path (Split-Path -Parent $PSScriptRoot) 'matlab/bin/matlab.exe') }
Export-ModuleMember -Function *
'@
    $stdio = @'
$script:FixtureMode = '__MODE__'
function Enable-McpLocalhostProxyBypass { return @{} }
function Restore-McpProxyEnvironment { param($State) }
function Protect-McpSensitiveText { param($Text) return $Text }
function Start-McpStdioServer { param($ServerExe,$ServerArgumentLine,$WorkingDirectory) return [pscustomobject]@{Simulated=$true} }
function Stop-McpStdioServer { param($Session) return [pscustomobject]@{Exited=$true;ExitCode=0} }
function Get-McpStdioToolText { param($ResultNode) return ($ResultNode.content.text -join "`n") }
function Send-McpStdioRequest {
    param($Session,$Method,$Params,[switch]$Notification,$TimeoutSeconds)
    if ($Method -eq 'initialize') { return [pscustomobject]@{Ok=$true;Result=[pscustomobject]@{serverInfo=@{name='simulation'}}} }
    if ($Notification) { return $null }
    $marker = [regex]::Match($Params.arguments.code, 'MAS_MCP_CODE_COMPLETE_[a-f0-9]+').Value
    $text = "MATLAB output`n$marker`n"
    $isError = $false
    switch ($script:FixtureMode) {
        'runtime-error' { $text = "错误使用 assert`n出错 task (第1行)" }
        'missing-marker' { $text = 'ordinary output only' }
        'duplicate-marker' { $text = "$marker`n$marker" }
        'wrong-marker' { $text = 'MAS_MCP_CODE_COMPLETE_00000000000000000000000000000000' }
        'error-flag' { $isError = $true }
        'credential-error' { $isError = $true; $text = 'apiKey=SHORT'; }
    }
    return [pscustomobject]@{
        Ok=$true;Error=$null
        Result=[pscustomobject]@{isError=$isError;content=@([pscustomobject]@{type='text';text=$text});authorization='Bearer PRIVATE_AUTH';nested=@{password='PRIVATE_PASSWORD'}}
        StdErrTail='Authorization: Bearer PRIVATE_STDERR'
    }
}
Export-ModuleMember -Function *
'@
    # 传输与 MATLAB 发现仍为假实现；输出边界必须使用实际公共脱敏器。
    $actualCore = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/MatlabAgentSkills.Core.psm1'))
    [IO.File]::WriteAllText((Join-Path $scripts 'MatlabAgentSkills.Core.psm1'), ($actualCore + "`r`n" + $core), $utf8)
    [IO.File]::WriteAllText((Join-Path $scripts 'MatlabAgentSkills.Execution.psm1'), $execution, $utf8)
    [IO.File]::WriteAllText((Join-Path $scripts 'MatlabAgentSkills.McpStdio.psm1'), $stdio.Replace('__MODE__', $Mode), $utf8)
    [IO.File]::WriteAllText((Join-Path $root 'code.m'), $Code, $utf8)
    $harness = @'
$ErrorActionPreference='Stop'
$output = Join-Path $PSScriptRoot 'output'
$summary = & (Join-Path $PSScriptRoot 'scripts/Invoke-MatlabMcpCode.ps1') -CodeFile (Join-Path $PSScriptRoot 'code.m') -OutputDirectory $output -TimeoutSeconds 1
$code = $LASTEXITCODE
$summary | ConvertTo-Json -Depth 5
if ($summary.status -ne 'PASS') { exit 1 }
exit 0
'@
    [IO.File]::WriteAllText((Join-Path $root 'harness.ps1'), $harness, $utf8)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = New-Object Diagnostics.ProcessStartInfo
    $process.StartInfo.FileName = (Get-Process -Id $PID).Path
    $process.StartInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $root 'harness.ps1') + '"'
    $process.StartInfo.UseShellExecute = $false; $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true; $process.StartInfo.RedirectStandardError = $true
    try {
        [void]$process.Start()
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(20000)) { $process.Kill(); throw '模拟调用测试超时，不涉及 MATLAB。' }
        $stdout = $outTask.Result
        $stderr = $errTask.Result
        if (-not (Test-Path -LiteralPath (Join-Path $root 'output/mcp_execution.json'))) { throw "模拟脚本未写报告: $stderr" }
        $raw = [IO.File]::ReadAllText((Join-Path $root 'output/mcp_execution.json'))
        return [pscustomobject]@{exitCode=$process.ExitCode;summary=($stdout | ConvertFrom-Json);record=($raw | ConvertFrom-Json);raw=$raw;stdout=$stdout;stderr=$stderr}
    } finally {
        $process.Dispose()
        $full = [IO.Path]::GetFullPath($root)
        $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
        if (-not $full.StartsWith($prefix) -or (Split-Path -Leaf $full) -notlike 'mas-code-evidence-*') { throw '模拟目录清理越界。' }
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}

Describe 'MCP 代码执行完成与报告脱敏' {
    It '只有本次唯一完成回执才允许 PASS，末尾注释与中文保留' {
        $r = Invoke-CodeEvidenceFixture -Mode pass
        $r.exitCode | Should Be 0
        $r.record.status | Should Be 'PASS'
        $r.record.executionCompleted | Should Be $true
        $r.record.code | Should Be "x = '中文'; % 文件末尾注释"
        $r.record.submittedCode | Should Match "^evalin\('base', \["
        $r.record.submittedCode | Should Match "char\(10\) 'fprintf\(''MAS_MCP_CODE_COMPLETE_"
        $r.record.submittedCode | Should Match '\]\);$'
        $r.record.response.Result.authorization | Should Be '<redacted>'
        $r.record.response.Result.nested.password | Should Be '<redacted>'
    }
    It '普通 content 中的 MATLAB 错误即使 isError=false 也失败' {
        $r = Invoke-CodeEvidenceFixture -Mode runtime-error
        $r.exitCode | Should Be 1
        $r.record.status | Should Be 'FAIL'
        $r.record.executionCompleted | Should Be $false
    }
    It '提前 return 对应缺少末尾回执，不可因传输成功而通过' {
        $r = Invoke-CodeEvidenceFixture -Mode missing-marker -Code 'return;'
        $r.record.status | Should Be 'FAIL'
        $r.record.submittedCode | Should Match "'return;' char\(10\) 'fprintf"
    }
    It '错误回执与重复回执均不能冒充本次唯一完成' {
        foreach ($mode in @('wrong-marker','duplicate-marker')) {
            $r = Invoke-CodeEvidenceFixture -Mode $mode
            $r.record.status | Should Be 'FAIL'
            $r.record.executionCompleted | Should Be $false
        }
    }
    It '工具标记 isError 时即使带完成回执也失败' {
        $r = Invoke-CodeEvidenceFixture -Mode error-flag
        $r.record.status | Should Be 'FAIL'
    }
    It '短密钥和认证信息不进入 JSON、原始摘要或返回 reason' {
        $r = Invoke-CodeEvidenceFixture -Mode credential-error -Code "apiKey = 'PRIVATE_CODE';"
        $r.record.status | Should Be 'FAIL'
        ($r.raw + $r.stdout + $r.stderr) | Should Not Match 'SHORT|PRIVATE_CODE|PRIVATE_AUTH|PRIVATE_PASSWORD|PRIVATE_STDERR'
        $r.record.reason | Should Not Match 'apiKey|Bearer'
        $r.record.response.Result.content[0].text | Should Be '[已省略凭据相关行]'
    }
}
