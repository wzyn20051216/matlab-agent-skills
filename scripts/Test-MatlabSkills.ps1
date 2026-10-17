<#
.SYNOPSIS
MATLAB 能力验收总控：执行全部验证脚本并产出统一验收 JSON。

.DESCRIPTION
与旧版差异：
- 不再“第一个脚本失败就 exit”，而是逐项执行并汇总，输出 PASS / FAIL / SKIP 三态证据；
- 每个脚本都有超时（默认 900s），MATLAB 启动挂起会被终止并归类为 TIMEOUT；
- 子脚本各自产出符合 schemas/acceptance-report.schema.json 的报告，本脚本负责合并；
- 缺少 MATLAB / 工具箱 / 许可证时输出 SKIP 并写明原因，不把“没跑”当成“通过”；
- 退出码：0=全部通过，1=有 FAIL，3=全部 SKIP。

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabSkills.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabSkills.ps1 -TimeoutSeconds 300 -SkipSimulink
#>
[CmdletBinding()]
param(
    [string]$MatlabPath = $env:MATLAB_EXE,
    [string]$Root,
    [int]$TimeoutSeconds = 900,
    [switch]$SkipCodegen,
    [switch]$SkipSimulink,
    [switch]$StopOnFirstFailure,
    [string]$OutputPath,
    [string]$TaskId,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Root) {
    $Root = Split-Path -Parent $scriptDir
}
$Root = (Resolve-Path -LiteralPath $Root).Path

Import-Module (Join-Path $scriptDir "MatlabAgentSkills.Acceptance.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $scriptDir "MatlabAgentSkills.Execution.psm1") -Force -DisableNameChecking

$validationDir = Join-Path $Root "artifacts\validation"
$acceptanceDir = Join-Path $validationDir "acceptance"
$logDir = Join-Path $Root "artifacts\logs"
foreach ($dir in @($validationDir, $acceptanceDir, $logDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
}
if (-not $OutputPath) {
    $OutputPath = Join-Path $validationDir "acceptance_report.json"
}
if (-not $TaskId) {
    $TaskId = New-AcceptanceTaskId -Prefix "matlab-skills"
}

$resolvedMatlab = Resolve-MatlabExecutable -ExplicitPath $MatlabPath
$installInfo = $null
if ($resolvedMatlab) { $installInfo = Get-MatlabInstallInfo -ExecutablePath $resolvedMatlab }

$report = New-AcceptanceReport -TaskId $TaskId -Backend "matlab-batch" `
    -MatlabVersion $(if ($installInfo -and $installInfo.Readable) { "$($installInfo.Version) $($installInfo.Description)" } else { "" }) `
    -MatlabRelease $(if ($installInfo -and $installInfo.Readable) { "$($installInfo.Release)" } else { "" }) `
    -MatlabExecutable $resolvedMatlab -MatlabInstalled ([bool]$resolvedMatlab)
$report.limitations = @(
    "所有检查只在本机真实执行；SKIP 表示未验证，不代表能力可用。",
    "L5（实际硬件运行）没有覆盖：仓库不包含 MCU 回读通道与在环测试台架。",
    "报告结构由 schemas/acceptance-report.schema.json 定义，可用 Test-AcceptanceReport 复核。"
)

if ($resolvedMatlab) {
    $report = Add-AcceptanceCheck -Report $report -Id "matlab.executable" -Title "解析 MATLAB 可执行文件" -Level "L1" `
        -Status "PASS" -Command "Resolve-MatlabExecutable" `
        -Metrics ([ordered]@{
            executable        = $resolvedMatlab
            version           = if ($installInfo) { $installInfo.Version } else { $null }
            release           = if ($installInfo) { $installInfo.Release } else { $null }
            versionInfoReadable = [bool]($installInfo -and $installInfo.Readable)
        })
}
else {
    $report = Add-AcceptanceCheck -Report $report -Id "matlab.executable" -Title "解析 MATLAB 可执行文件" -Level "L1" `
        -Status "FAIL" -Reason "未找到 matlab（MATLAB_EXE / PATH / MATLAB_ROOT / 常见安装目录均未命中）" `
        -ErrorClass "ENVIRONMENT_ERROR" -Command "Resolve-MatlabExecutable"
}

$stages = @(
    [pscustomobject]@{ Name = "toolbox_inventory"; Script = "matlab_toolbox_inventory.m"; Skipped = $false; SkipReason = "" }
    [pscustomobject]@{ Name = "feature_probe"; Script = "matlab_feature_probe.m"; Skipped = $false; SkipReason = "" }
    [pscustomobject]@{ Name = "skill_smoke"; Script = "matlab_skill_smoke.m"; Skipped = $false; SkipReason = "" }
    [pscustomobject]@{ Name = "compiler_chain_smoke"; Script = "matlab_compiler_chain_smoke.m"; Skipped = $false; SkipReason = "" }
    [pscustomobject]@{ Name = "codegen_smoke"; Script = "matlab_codegen_smoke.m"; Skipped = [bool]$SkipCodegen; SkipReason = "调用方使用 -SkipCodegen 跳过" }
    [pscustomobject]@{ Name = "simulink_coder_smoke"; Script = "simulink_coder_smoke.m"; Skipped = [bool]$SkipSimulink; SkipReason = "调用方使用 -SkipSimulink 跳过" }
)

function Invoke-Stage {
    param($Stage)

    $scriptPath = Join-Path $Root "matlab\validation\$($Stage.Script)"
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        return [pscustomobject]@{ Kind = "missing"; Message = "脚本不存在: $scriptPath" }
    }

    $escaped = $scriptPath.Replace("'", "''")
    $batchCommand = "run('$escaped')"
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $stdoutPath = Join-Path $logDir "$($Stage.Name)_$timestamp.stdout.log"
    $stderrPath = Join-Path $logDir "$($Stage.Name)_$timestamp.stderr.log"
    $stageLogPath = Join-Path $logDir "$($Stage.Name)_$timestamp.stages.log"

    if (-not $Quiet) {
        Write-Host ("==> {0}（超时 {1}s）" -f $Stage.Name, $TimeoutSeconds) -ForegroundColor Cyan
    }

    $run = Invoke-MatlabBatchProcess -MatlabPath $resolvedMatlab `
        -ArgumentList @("-batch", $batchCommand) `
        -WorkingDirectory $Root `
        -TimeoutSeconds $TimeoutSeconds `
        -StdoutPath $stdoutPath `
        -StderrPath $stderrPath `
        -StageLogPath $stageLogPath `
        -Label $Stage.Name

    return [pscustomobject]@{ Kind = "run"; Run = $run; Command = $batchCommand; Artifacts = @($stdoutPath, $stderrPath, $stageLogPath) }
}

foreach ($stage in $stages) {
    if ($stage.Skipped) {
        $report = Add-AcceptanceCheck -Report $report -Id "$($stage.Name).skipped" `
            -Title "$($stage.Script) 未执行" -Level "L1" -Status "SKIP" -Reason $stage.SkipReason
        $report.unexecuted = @($report.unexecuted) + @([pscustomobject]@{
            capability = $stage.Script; level = "L1"; reason = $stage.SkipReason
        })
        continue
    }

    if (-not $resolvedMatlab) {
        $report = Add-AcceptanceCheck -Report $report -Id "$($stage.Name).not-run" `
            -Title "$($stage.Script) 未执行" -Level "L1" -Status "SKIP" `
            -Reason "MATLAB 未安装，无法执行该验证脚本" -ErrorClass "ENVIRONMENT_ERROR"
        continue
    }

    $outcome = Invoke-Stage -Stage $stage
    if ($outcome.Kind -eq "missing") {
        $report = Add-AcceptanceCheck -Report $report -Id "$($stage.Name).missing" `
            -Title "$($stage.Script) 不存在" -Level "L1" -Status "FAIL" -Reason $outcome.Message -ErrorClass "ENVIRONMENT_ERROR"
        if ($StopOnFirstFailure) { break }
        continue
    }

    $run = $outcome.Run
    $childPath = Join-Path $acceptanceDir "$($stage.Name).json"

    if ($run.TimedOut) {
        $report = Add-AcceptanceCheck -Report $report -Id "$($stage.Name).execution" `
            -Title "$($stage.Script) 执行超时" -Level "L1" -Status "FAIL" `
            -Command $run.Command -ExitCode $run.ExitCode `
            -Reason "超过 $TimeoutSeconds 秒未结束，已终止进程树；MATLAB 可能卡在启动或许可证校验" `
            -ErrorClass "TIMEOUT" -StartedAt $run.StartedAt -FinishedAt $run.FinishedAt `
            -DurationSeconds $run.DurationSeconds -ArtifactPaths $outcome.Artifacts
    }
    elseif ($null -ne $run.ExitCode -and $run.ExitCode -ne 0) {
        $report = Add-AcceptanceCheck -Report $report -Id "$($stage.Name).execution" `
            -Title "$($stage.Script) 执行失败" -Level "L1" -Status "FAIL" `
            -Command $run.Command -ExitCode $run.ExitCode `
            -Reason "MATLAB 退出码 $($run.ExitCode)（$($run.ErrorClass)）：$(($run.LogTail -split "`n" | Select-Object -Last 3) -join ' / ')" `
            -ErrorClass $(if ($run.ErrorClass) { $run.ErrorClass } else { "MATLAB_RUNTIME_ERROR" }) `
            -StartedAt $run.StartedAt -FinishedAt $run.FinishedAt `
            -DurationSeconds $run.DurationSeconds -ArtifactPaths $outcome.Artifacts
    }
    else {
        if (-not (Test-Path -LiteralPath $childPath)) {
            $report = Add-AcceptanceCheck -Report $report -Id "$($stage.Name).no-report" `
                -Title "$($stage.Script) 未产出验收报告" -Level "L1" -Status "FAIL" `
                -Command $run.Command -ExitCode $run.ExitCode `
                -Reason "脚本退出码为 0 但未写出 $childPath，无法证明任何检查通过" `
                -ErrorClass "VALIDATION_ERROR" -ArtifactPaths $outcome.Artifacts
        }
        else {
            try {
                $child = Import-AcceptanceReport -Path $childPath
                $childValidation = Test-AcceptanceReport -Report $child
                if (-not $childValidation.Valid) {
                    $report = Add-AcceptanceCheck -Report $report -Id "$($stage.Name).invalid-report" `
                        -Title "$($stage.Script) 验收报告不合规" -Level "L1" -Status "FAIL" `
                        -Command $run.Command -ExitCode $run.ExitCode `
                        -Reason ($childValidation.Errors -join " | ") -ErrorClass "VALIDATION_ERROR" `
                        -ArtifactPaths @($childPath)
                }
                else {
                    $before = @($report.checks).Count
                    $report = Merge-AcceptanceReport -Report $report -Child $child -SourceName $stage.Name
                    # 把进程级证据补到子检查上：命令、退出码、artifact 目录。
                    for ($i = $before; $i -lt @($report.checks).Count; $i++) {
                        $check = $report.checks[$i]
                        if ($null -eq $check.exitCode) { $check.exitCode = $run.ExitCode }
                        if ([string]::IsNullOrWhiteSpace([string]$check.command)) { $check.command = $run.Command }
                        if (@($check.artifactPaths).Count -eq 0) { $check.artifactPaths = @($childPath) }
                    }
                }
            }
            catch {
                $report = Add-AcceptanceCheck -Report $report -Id "$($stage.Name).import-failed" `
                    -Title "$($stage.Script) 验收报告无法读取" -Level "L1" -Status "FAIL" `
                    -Command $run.Command -ExitCode $run.ExitCode `
                    -Reason $_.Exception.Message -ErrorClass "VALIDATION_ERROR" -ArtifactPaths @($childPath)
            }
        }
    }

    if ($StopOnFirstFailure -and $report.checks[-1].status -eq "FAIL") { break }
}

$report = Write-AcceptanceReport -Report $report -Path $OutputPath

if (-not $Quiet) {
    Write-Host ""
    # 一条检查项一行：Format-Table 会把长 reason 折行，反而不易读。
    foreach ($check in $report.checks) {
        $reasonText = if ($check.status -ne "PASS" -and $check.reason) { ($check.reason -replace "\s+", " ") } else { "" }
        Write-Host ("{0,-32} {1,-4} {2,-5} {3,7}s  {4}" -f `
                $check.id, $check.level, $check.status, ([math]::Round([double]$check.durationSeconds, 1)), $reasonText)
    }

    Write-Host ("==> overall={0} achievedLevel={1} pass={2} fail={3} skip={4}" -f `
        $report.overallStatus, $report.achievedLevel, `
        $report.summary.pass, $report.summary.fail, $report.summary.skip) -ForegroundColor Cyan
    Write-Host "ACCEPTANCE_REPORT=$OutputPath"
}

$validation = Test-AcceptanceReport -Report $report
if (-not $validation.Valid) {
    [Console]::Error.WriteLine("验收报告自身不合规：")
    foreach ($error in $validation.Errors) { [Console]::Error.WriteLine("  - $error") }
    exit 1
}

exit (Get-AcceptanceExitCode -Report $report)
