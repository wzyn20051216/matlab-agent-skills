<#
.SYNOPSIS
执行可靠性测试：错误分类、有限重试、超时终止、进程树清理。

.DESCRIPTION
不依赖 MATLAB：用一个会长时间休眠的 PowerShell 进程模拟挂起的 MATLAB。
#>

$helpers = Join-Path $PSScriptRoot "helpers\TestSandbox.ps1"
. $helpers

$repoRoot = Get-TestRepositoryRoot
Import-TestModule -Name "MatlabAgentSkills.Execution.psm1" -RepositoryRoot $repoRoot | Out-Null

$shellPath = (Get-Process -Id $PID).Path

Describe "错误分类" {
    It "许可证失败归类为 LICENSE_ERROR 且不可自动重试" {
        $result = Get-MatlabErrorClassification -Text "License checkout failed.`nLicense Manager Error -15"
        $result.Class | Should Be "LICENSE_ERROR"
        $result.Recoverable | Should Be $false
        (Test-ErrorClassRecoverable -ErrorClass $result.Class) | Should Be $false
    }

    It "MCP 连接失败归类为 MCP_CONNECTION_ERROR 且可重试" {
        $result = Get-MatlabErrorClassification -Text "Failed to initialize MCP: ECONNREFUSED 127.0.0.1:31516"
        $result.Class | Should Be "MCP_CONNECTION_ERROR"
        (Test-ErrorClassRecoverable -ErrorClass $result.Class) | Should Be $true
    }

    It "缺少编译器归类为 ENVIRONMENT_ERROR" {
        $result = Get-MatlabErrorClassification -Text "No supported compiler or SDK was found. Install a supported compiler."
        $result.Class | Should Be "ENVIRONMENT_ERROR"
    }

    It "仿真错误归类为 SIMULATION_ERROR" {
        $result = Get-MatlabErrorClassification -Text "Simulink.SimulationError: Derivative of state 1 in block is not finite"
        $result.Class | Should Be "SIMULATION_ERROR"
    }

    It "构建错误归类为 CODEGEN_ERROR" {
        $result = Get-MatlabErrorClassification -Text "Error(s) encountered while building ""pi_control_step"" model"
        $result.Class | Should Be "CODEGEN_ERROR"
    }

    It "数值不一致归类为 VALIDATION_ERROR" {
        $result = Get-MatlabErrorClassification -Text "Assertion failed: compiled result deviates from MATLAB result."
        $result.Class | Should Be "VALIDATION_ERROR"
    }

    It "普通运行时报错归类为 MATLAB_RUNTIME_ERROR" {
        $result = Get-MatlabErrorClassification -Text "Error using pi_control_step`nNot enough input arguments." -ExitCode 1
        $result.Class | Should Be "MATLAB_RUNTIME_ERROR"
    }

    It "超时标记优先于任何日志匹配" {
        $result = Get-MatlabErrorClassification -Text "License checkout failed" -TimedOut
        $result.Class | Should Be "TIMEOUT"
    }

    It "退出码为 0 且无匹配时返回 null" {
        $result = Get-MatlabErrorClassification -Text "everything is fine" -ExitCode 0
        ($null -eq $result) | Should Be $true
    }

    It "可恢复集合只包含 TIMEOUT 与 MCP_CONNECTION_ERROR" {
        $classes = Get-RecoverableErrorClasses
        ($classes -contains "TIMEOUT") | Should Be $true
        ($classes -contains "MCP_CONNECTION_ERROR") | Should Be $true
        ($classes -contains "LICENSE_ERROR") | Should Be $false
        ($classes -contains "VALIDATION_ERROR") | Should Be $false
    }
}

Describe "有限次重试" {
    It "可恢复错误会重试并最终成功" {
        $script:counter = 0
        $result = Invoke-WithRetry -Operation "retry-ok" -MaxAttempts 3 -DelaySeconds 0 -Sleep { param($s) } -Action {
            $script:counter++
            if ($script:counter -lt 2) {
                return [pscustomobject]@{ Succeeded = $false; ErrorClass = "TIMEOUT"; Reason = "第一次超时" }
            }
            return [pscustomobject]@{ Succeeded = $true; Value = "done" }
        }
        $result.Succeeded | Should Be $true
        $result.AttemptCount | Should Be 2
        $result.Attempts[0].ErrorClass | Should Be "TIMEOUT"
    }

    It "不可恢复错误不重试" {
        $script:counter = 0
        $result = Invoke-WithRetry -Operation "retry-license" -MaxAttempts 3 -DelaySeconds 0 -Sleep { param($s) } -Action {
            $script:counter++
            return [pscustomobject]@{ Succeeded = $false; ErrorClass = "LICENSE_ERROR"; Reason = "no license" }
        }
        $result.Succeeded | Should Be $false
        $result.AttemptCount | Should Be 1
        $result.BlockedReason | Should Match "NON_RECOVERABLE"
    }

    It "非幂等操作未获批准时不重试" {
        $script:counter = 0
        $result = Invoke-WithRetry -Operation "retry-danger" -MaxAttempts 3 -DelaySeconds 0 -Idempotent $false `
            -Sleep { param($s) } -Action {
            $script:counter++
            return [pscustomobject]@{ Succeeded = $false; ErrorClass = "TIMEOUT"; Reason = "超时" }
        }
        $result.AttemptCount | Should Be 1
        $result.BlockedReason | Should Match "NON_IDEMPOTENT_REQUIRES_APPROVAL"
    }

    It "非幂等操作获得批准后允许重试" {
        $script:counter = 0
        $result = Invoke-WithRetry -Operation "retry-danger-approved" -MaxAttempts 2 -DelaySeconds 0 -Idempotent $false -Approved `
            -Sleep { param($s) } -Action {
            $script:counter++
            return [pscustomobject]@{ Succeeded = $false; ErrorClass = "TIMEOUT"; Reason = "超时" }
        }
        $result.AttemptCount | Should Be 2
    }

    It "最大尝试次数被限制在 1..5，不会无限循环" {
        $script:counter = 0
        $result = Invoke-WithRetry -Operation "retry-clamp" -MaxAttempts 99 -DelaySeconds 0 -Sleep { param($s) } -Action {
            $script:counter++
            return [pscustomobject]@{ Succeeded = $false; ErrorClass = "TIMEOUT"; Reason = "超时" }
        }
        $result.AttemptCount | Should Be 5
        $script:counter | Should Be 5
    }

    It "Action 抛异常时按消息分类" {
        $result = Invoke-WithRetry -Operation "retry-throw" -MaxAttempts 2 -DelaySeconds 0 -Sleep { param($s) } -Action {
            throw "License Manager Error -4"
        }
        $result.Succeeded | Should Be $false
        $result.ErrorClass | Should Be "LICENSE_ERROR"
        $result.AttemptCount | Should Be 1
    }
}

Describe "进程超时与清理" {
    It "超过超时阈值会终止进程并归类 TIMEOUT" {
        $sandbox = New-TestSandbox
        try {
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $run = Invoke-MatlabBatchProcess -MatlabPath $shellPath `
                -ArgumentList @("-NoProfile", "-Command", "Start-Sleep -Seconds 60") `
                -WorkingDirectory $sandbox.Root -TimeoutSeconds 2 `
                -StdoutPath (Join-Path $sandbox.Logs "slow.out.log") `
                -StderrPath (Join-Path $sandbox.Logs "slow.err.log") `
                -StageLogPath (Join-Path $sandbox.Logs "slow.stages.log") `
                -Label "timeout-sim"
            $stopwatch.Stop()

            $run.TimedOut | Should Be $true
            $run.ErrorClass | Should Be "TIMEOUT"
            ($stopwatch.Elapsed.TotalSeconds -lt 25) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $sandbox.Logs "slow.stages.log")) | Should Be $true
            (Get-Content -Raw -LiteralPath (Join-Path $sandbox.Logs "slow.stages.log")) | Should Match "timeout"
        }
        finally { Remove-TestSandbox $sandbox }
    }

    It "正常退出的进程返回真实退出码" {
        $sandbox = New-TestSandbox
        try {
            $run = Invoke-MatlabBatchProcess -MatlabPath $shellPath `
                -ArgumentList @("-NoProfile", "-Command", "Write-Output 'hello'; exit 0") `
                -WorkingDirectory $sandbox.Root -TimeoutSeconds 30 `
                -StdoutPath (Join-Path $sandbox.Logs "ok.out.log") `
                -StderrPath (Join-Path $sandbox.Logs "ok.err.log") `
                -Label "ok-sim"
            $run.TimedOut | Should Be $false
            $run.ExitCode | Should Be 0
            (Get-Content -Raw -LiteralPath (Join-Path $sandbox.Logs "ok.out.log")) | Should Match "hello"
        }
        finally { Remove-TestSandbox $sandbox }
    }

    It "非零退出码会被分类而不是被吞掉" {
        $sandbox = New-TestSandbox
        try {
            $run = Invoke-MatlabBatchProcess -MatlabPath $shellPath `
                -ArgumentList @("-NoProfile", "-Command", "Write-Error 'License checkout failed'; exit 1") `
                -WorkingDirectory $sandbox.Root -TimeoutSeconds 30 `
                -StdoutPath (Join-Path $sandbox.Logs "fail.out.log") `
                -StderrPath (Join-Path $sandbox.Logs "fail.err.log") `
                -Label "fail-sim"
            $run.ExitCode | Should Be 1
            $run.ErrorClass | Should Be "LICENSE_ERROR"
        }
        finally { Remove-TestSandbox $sandbox }
    }

    It "可执行文件不存在时抛错而不是静默通过" {
        $sandbox = New-TestSandbox
        try {
            {
                Invoke-MatlabBatchProcess -MatlabPath (Join-Path $sandbox.Root "no-such-matlab.exe") `
                    -ArgumentList @("-batch", "disp(1)") -WorkingDirectory $sandbox.Root -TimeoutSeconds 5
            } | Should Throw
        }
        finally { Remove-TestSandbox $sandbox }
    }

    It "超时阈值小于 1 秒会被拒绝（避免无法区分挂起与正常结束）" {
        $sandbox = New-TestSandbox
        try {
            {
                Invoke-MatlabBatchProcess -MatlabPath $shellPath -ArgumentList @("-NoProfile", "-Command", "exit 0") `
                    -WorkingDirectory $sandbox.Root -TimeoutSeconds 0
            } | Should Throw
        }
        finally { Remove-TestSandbox $sandbox }
    }

    It "调用方不传阶段日志路径时仍然落盘（否则超时排查没有证据）" {
        $sandbox = New-TestSandbox
        try {
            # 真实缺陷复现：StageLogPath 是可选的，之前不传就静默不写日志，
            # MATLAB 挂起时只剩两个 0 字节的 stdout/stderr，无法定位卡在哪个阶段。
            $run = Invoke-MatlabBatchProcess -MatlabPath $shellPath `
                -ArgumentList @("-NoProfile", "-Command", "Write-Output 'staged'") `
                -WorkingDirectory $sandbox.Root -TimeoutSeconds 30 -Label "default-stagelog"

            $run.StageLogPath | Should Not Be $null
            (Test-Path -LiteralPath $run.StageLogPath) | Should Be $true
            $stageText = Get-Content -Raw -LiteralPath $run.StageLogPath
            $stageText | Should Match "launch"
            $stageText | Should Match "running"
            $stageText | Should Match "exited"
        }
        finally { Remove-TestSandbox $sandbox }
    }
}

Describe "MATLAB 安装探测" {
    It "能从合成安装目录读出版本与 release" {
        $sandbox = New-TestSandbox
        try {
            $bin = Join-Path $sandbox.Root "bin"
            New-Item -ItemType Directory -Force -Path $bin | Out-Null
            $exe = Join-Path $bin "matlab.exe"
            Set-Content -LiteralPath $exe -Value "stub" -Encoding ascii
            $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<MathWorks_version_info>
  <version>26.1.0.3276743</version>
  <release>R2026a</release>
  <description>Update 3</description>
</MathWorks_version_info>
"@
            Set-Content -LiteralPath (Join-Path $sandbox.Root "VersionInfo.xml") -Value $xml -Encoding UTF8

            $info = Get-MatlabInstallInfo -ExecutablePath $exe
            $info.Readable | Should Be $true
            $info.Version | Should Be "26.1.0.3276743"
            $info.Release | Should Be "R2026a"
        }
        finally { Remove-TestSandbox $sandbox }
    }

    It "VersionInfo 缺失时标记不可读而不是抛错" {
        $sandbox = New-TestSandbox
        try {
            $bin = Join-Path $sandbox.Root "bin"
            New-Item -ItemType Directory -Force -Path $bin | Out-Null
            $exe = Join-Path $bin "matlab.exe"
            Set-Content -LiteralPath $exe -Value "stub" -Encoding ascii
            $info = Get-MatlabInstallInfo -ExecutablePath $exe
            $info.Readable | Should Be $false
        }
        finally { Remove-TestSandbox $sandbox }
    }

    It "显式路径不存在时返回 null" {
        ($null -eq (Resolve-MatlabExecutable -ExplicitPath "Z:\definitely\not\matlab.exe")) | Should Be $true
    }
}

Describe "短进程超时" {
    It "Invoke-ProcessWithTimeout 能终止超时的外部命令" {
        $result = Invoke-ProcessWithTimeout -FilePath $shellPath -ArgumentList @("-NoProfile", "-Command", "Start-Sleep -Seconds 30") -TimeoutSeconds 2
        $result.TimedOut | Should Be $true
        $result.DurationSeconds | Should BeLessThan 25
    }

    It "Invoke-ProcessWithTimeout 返回标准输出与退出码" {
        $result = Invoke-ProcessWithTimeout -FilePath $shellPath -ArgumentList @("-NoProfile", "-Command", "Write-Output 'pong'; exit 0") -TimeoutSeconds 20
        $result.TimedOut | Should Be $false
        $result.ExitCode | Should Be 0
        $result.StandardOutput | Should Match "pong"
    }
}
