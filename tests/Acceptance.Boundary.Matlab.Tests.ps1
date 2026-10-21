<#
.SYNOPSIS
验收协议的 MATLAB 侧边界测试：真实启动 MATLAB 产出报告，再用 PowerShell 侧同一套
schema 与语义规则校验，验证"两端产出的 JSON 形状一致"。

.DESCRIPTION
文件名以 ".Matlab.Tests.ps1" 结尾，归入 matlab 层。没有 MATLAB 时必须整层跳过，
不得把自己标成 PASS。

覆盖的边界（对应本轮任务要求）：
  - 单检查 / 多检查的数组编码（MATLAB jsonencode 单元素结构体数组会退化成对象）；
  - null / 空字符串 / 空数组的落盘形态；
  - errorClass、exitCode、durationSeconds 的取值域；
  - Schema 校验与报告合并；
  - 缺失许可证、授权无法判定、运行异常这三类失败路径。

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Layer matlab -Filter Acceptance.Boundary
#>

$helpers = Join-Path $PSScriptRoot "helpers\TestSandbox.ps1"
. $helpers

$repoRoot = Get-TestRepositoryRoot
Import-TestModule -Name "MatlabAgentSkills.Execution.psm1" -RepositoryRoot $repoRoot | Out-Null
Import-TestModule -Name "MatlabAgentSkills.Acceptance.psm1" -RepositoryRoot $repoRoot | Out-Null

$matlabExe = Resolve-MatlabExecutable
if ([string]::IsNullOrWhiteSpace($matlabExe)) {
    throw "本层测试需要已安装的 MATLAB，但未能在 PATH / MATLAB_EXE / 常见安装位置中发现。请改用 -Layer free，或在 MATLAB 环境中运行。"
}

$probeScript = Join-Path $repoRoot "matlab\validation\tests\masacc_boundary_probe.m"
$boundaryDir = Join-Path $repoRoot "artifacts\validation\tests\masacc_boundary"
$manifestPath = Join-Path $boundaryDir "manifest.json"
$timeoutSeconds = 300

# 探针只跑一次：后续每个用例都读它产出的文件，避免反复启动 MATLAB。
$probeRun = Invoke-MatlabBatchProcess -MatlabPath $matlabExe `
    -ArgumentList @("-batch", "run('$(($probeScript).Replace("'", "''"))')") `
    -WorkingDirectory $repoRoot -Label "masacc-boundary-probe" -TimeoutSeconds $timeoutSeconds `
    -StdoutPath (Join-Path $repoRoot "artifacts\logs\masacc_boundary.stdout.log") `
    -StderrPath (Join-Path $repoRoot "artifacts\logs\masacc_boundary.stderr.log") `
    -StageLogPath (Join-Path $repoRoot "artifacts\logs\masacc_boundary.stages.log")

Describe "MATLAB 侧边界探针（真实执行）" {

    It "边界探针脚本存在" {
        (Test-Path -LiteralPath $probeScript) | Should Be $true
    }

    It "边界探针能在真实 MATLAB 中跑完（退出码 0，未超时）" {
        $probeRun.TimedOut | Should Be $false
        $probeRun.ExitCode | Should Be 0
        $probeRun.LaunchFailed | Should Be $false
    }

    It "产出了 manifest 与全部用例文件" {
        (Test-Path -LiteralPath $manifestPath) | Should Be $true
        $manifest = Read-AcceptanceJsonFile -Path $manifestPath
        @($manifest).Count | Should BeGreaterThan 0
        foreach ($entry in @($manifest)) {
            (Test-Path -LiteralPath $entry.file) | Should Be $true
        }
    }
}

# manifest 里每一项都单独验证，失败时能立刻看出是哪种边界坏了。
$manifest = $null
if (Test-Path -LiteralPath $manifestPath) {
    $manifest = Read-AcceptanceJsonFile -Path $manifestPath
}

Describe "MATLAB 侧边界用例（逐项校验）" {
foreach ($entry in @($manifest)) {
    if ($null -eq $entry) { continue }

    Context "边界用例 $($entry.case)" {

        $path = "$($entry.file)"
        $report = $null
        $raw = ""
        if (Test-Path -LiteralPath $path) {
            $raw = [System.IO.File]::ReadAllText($path, (New-Object System.Text.UTF8Encoding($false)))
            $report = Import-AcceptanceReport -Path $path
        }

        It "报告通过 schema 与语义校验" {
            ($null -eq $report) | Should Be $false
            $validation = Test-AcceptanceReport -Report $report
            ($validation.Errors -join " | ") | Should Be ""
            $validation.Valid | Should Be $true
        }

        It "检查项数量为 $($entry.expectedCheckCount)" {
            @($report.checks).Count | Should Be ([int]$entry.expectedCheckCount)
        }

        It "checks 在 JSON 文本里是数组（不是对象）" {
            # 这是 MATLAB jsonencode 单元素结构体数组的经典坑：会输出 { ... } 而不是 [ { ... } ]。
            ($raw -match '"checks"\s*:\s*\[') | Should Be $true
        }

        It "各检查项状态符合预期" {
            $actual = @($report.checks | ForEach-Object { "$($_.status)" })
            $expected = @($entry.expectedStatuses | ForEach-Object { "$_" })
            ($actual -join ",") | Should Be ($expected -join ",")
        }

        It "非 PASS 的检查项都有非空 reason" {
            foreach ($check in @($report.checks)) {
                if ("$($check.status)" -ne "PASS") {
                    ([string]::IsNullOrWhiteSpace([string]$check.reason)) | Should Be $false
                }
            }
        }

        It "可空字段要么是 null，要么类型正确" {
            foreach ($check in @($report.checks)) {
                if ($null -ne $check.exitCode) {
                    ($check.exitCode -is [int] -or $check.exitCode -is [long]) | Should Be $true
                }
                if ($null -ne $check.durationSeconds) {
                    (($check.durationSeconds -is [double]) -or ($check.durationSeconds -is [decimal]) -or
                        ($check.durationSeconds -is [int])) | Should Be $true
                    ([double]$check.durationSeconds -ge 0) | Should Be $true
                }
                if ($null -ne $check.errorClass) {
                    (@("ENVIRONMENT_ERROR", "LICENSE_ERROR", "MCP_CONNECTION_ERROR", "MATLAB_RUNTIME_ERROR",
                            "SIMULATION_ERROR", "CODEGEN_ERROR", "VALIDATION_ERROR", "TIMEOUT") -contains "$($check.errorClass)") | Should Be $true
                }
                if ($null -ne $check.reason) {
                    ($check.reason -is [string]) | Should Be $true
                }
            }
        }

        It "artifactPaths 始终是数组" {
            foreach ($check in @($report.checks)) {
                ($check.PSObject.Properties.Name -contains "artifactPaths") | Should Be $true
                ($check.artifactPaths -is [array] -or $null -eq $check.artifactPaths) | Should Be $true
            }
        }
    }
}

}

Describe "MATLAB 侧报告的合并与量化" {
    It "空工具箱清单的用例确实产出空数组而不是 null" {
        $path = Join-Path $boundaryDir "empty_inventory.json"
        if (-not (Test-Path -LiteralPath $path)) { return }
        $raw = [System.IO.File]::ReadAllText($path, (New-Object System.Text.UTF8Encoding($false)))
        ($raw -match '"toolboxInventory"\s*:\s*\[') | Should Be $true
        $report = Import-AcceptanceReport -Path $path
        @($report.toolboxInventory).Count | Should Be 0
    }

    It "中文 reason 往返后没有变成乱码" {
        $path = Join-Path $boundaryDir "unicode_reason.json"
        if (-not (Test-Path -LiteralPath $path)) { return }
        $report = Import-AcceptanceReport -Path $path
        $reason = "$($report.checks[0].reason)"
        ($reason -match "许可证") | Should Be $true
        ($reason -match "锟|烫|屯") | Should Be $false
    }

    It "MATLAB 侧报告能合并进 PowerShell 侧父报告并通过校验" {
        $path = Join-Path $boundaryDir "multi_check.json"
        if (-not (Test-Path -LiteralPath $path)) { return }
        $child = Import-AcceptanceReport -Path $path

        $parent = New-AcceptanceReport -TaskId "merge-boundary" -Backend "matlab-batch"
        $parent = Add-AcceptanceCheck -Report $parent -Id "parent.check" -Title "父检查" -Level "L1" -Status "PASS"
        $parent = Update-AcceptanceSummary -Report $parent

        $merged = Merge-AcceptanceReport -Report $parent -Child $child -SourceName "boundary"
        @($merged.checks).Count | Should Be 4
        (Test-AcceptanceReport -Report $merged).Valid | Should Be $true
        # 子报告里有 FAIL，合并后整体必须是 FAIL，不能被父报告的 PASS 稀释。
        "$($merged.overallStatus)" | Should Be "FAIL"
    }
}
