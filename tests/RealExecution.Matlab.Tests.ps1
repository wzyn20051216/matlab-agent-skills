<#
.SYNOPSIS
真实 MATLAB 执行层测试：必须在本机已安装 MATLAB 的环境中运行。

.DESCRIPTION
文件名以 ".Matlab.Tests.ps1" 结尾，`tests\Invoke-Tests.ps1` 据此把它归入 matlab 层。
免费环境（无 MATLAB）不得执行本层。本层一旦被误执行，会在加载阶段直接抛错，
而不是把自己标记成 PASS —— 这正是"没跑不等于通过"的要求。

这里刻意不写死任何 MATLAB 安装路径：路径来自 Resolve-MatlabExecutable
（优先 MATLAB_EXE 环境变量，由 Invoke-Tests.ps1 注入），
版本信息来自安装目录里的 VersionInfo.xml。

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Layer matlab
#>

$helpers = Join-Path $PSScriptRoot "helpers\TestSandbox.ps1"
. $helpers

$repoRoot = Get-TestRepositoryRoot
Import-TestModule -Name "MatlabAgentSkills.Execution.psm1" -RepositoryRoot $repoRoot | Out-Null

$matlabExe = Resolve-MatlabExecutable
if ([string]::IsNullOrWhiteSpace($matlabExe)) {
    throw "本层测试需要已安装的 MATLAB，但未能在 PATH / MATLAB_EXE / 常见安装位置中发现。请改用 -Layer free，或在 MATLAB 环境中运行。"
}

# 版本探测给足超时（首次启动要加载许可证），超时保护单独用更短的阈值验证。
$batchTimeoutSeconds = 180
$overrunTimeoutSeconds = 45

Describe "真实 MATLAB 执行" {
    It "能解析出真实 MATLAB 可执行文件路径" {
        (Test-Path -LiteralPath $matlabExe) | Should Be $true
        (Split-Path -Leaf $matlabExe) | Should Match "^(matlab|matlab\.exe)$"
    }

    It "能从真实安装目录读出 Release 与完整版本号" {
        $info = Get-MatlabInstallInfo -ExecutablePath $matlabExe
        ($null -eq $info) | Should Be $false
        $info.Readable | Should Be $true
        $info.Release | Should Match "^R\d{4}[ab]$"
        ($info.Version -match "^\d+\.\d+") | Should Be $true
    }

    It "真实 -batch 执行 disp(version) 并返回真实版本号" {
        $run = Invoke-MatlabBatchProcess -MatlabPath $matlabExe -ArgumentList @("-batch", "disp(version)") `
            -Label "real-version" -TimeoutSeconds $batchTimeoutSeconds -WorkingDirectory $repoRoot

        $evidence = "exitCode=$($run.ExitCode) timedOut=$($run.TimedOut) duration=$([math]::Round($run.DurationSeconds, 1))s errorClass=$($run.ErrorClass)"

        if ($run.TimedOut) {
            $stdoutBytes = 0
            $stderrBytes = 0
            if (Test-Path -LiteralPath $run.StdoutPath) { $stdoutBytes = (Get-Item -LiteralPath $run.StdoutPath).Length }
            if (Test-Path -LiteralPath $run.StderrPath) { $stderrBytes = (Get-Item -LiteralPath $run.StderrPath).Length }
            $hint = ""
            if ($stdoutBytes -eq 0 -and $stderrBytes -eq 0) {
                # 一个字都没输出就挂住，问题在启动阶段，不在被测代码。
                $hint = "；stdout/stderr 均为 0 字节，说明卡在 MATLAB 启动阶段（常见原因是许可证被已运行的桌面会话占用，或单实例机制阻塞），不是被测脚本出错"
            }
            throw "MATLAB -batch 在 $batchTimeoutSeconds 秒内没有返回（已被终止）。证据：$evidence$hint；阶段日志=$($run.StageLogPath)"
        }

        $run.ExitCode | Should Be 0

        $stdoutText = ""
        if (Test-Path -LiteralPath $run.StdoutPath) { $stdoutText = [System.IO.File]::ReadAllText($run.StdoutPath) }
        # 只断言"输出里出现形如 26.1.0.xxxxxxx (R2026a) 的版本串"，不绑定具体版本。
        ($stdoutText -match "\d+\.\d+\.\d+(\.\d+)?\s*\(R\d{4}[ab]\)") | Should Be $true

        # 输出要和安装目录里的版本信息对得上，避免"跑起来了但跑的是另一个 MATLAB"。
        $info = Get-MatlabInstallInfo -ExecutablePath $matlabExe
        ($stdoutText -match [regex]::Escape($info.Version)) | Should Be $true
        Write-Host "  证据: $evidence"
    }

    It "超时保护会在阈值内终止真实 MATLAB 进程" {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $run = Invoke-MatlabBatchProcess -MatlabPath $matlabExe -ArgumentList @("-batch", "pause(600)") `
            -Label "real-timeout" -TimeoutSeconds $overrunTimeoutSeconds -WorkingDirectory $repoRoot
        $stopwatch.Stop()

        $run.TimedOut | Should Be $true
        $run.ErrorClass | Should Be "TIMEOUT"
        # 允许启动开销，但必须明显小于 pause 的时长，证明确实被强杀而不是等它自己结束。
        ($stopwatch.Elapsed.TotalSeconds -lt ($overrunTimeoutSeconds + 60)) | Should Be $true
        Write-Host "  证据: 实测 $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s 后终止"
    }
}
