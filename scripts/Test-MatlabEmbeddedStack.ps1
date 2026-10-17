<#
.SYNOPSIS
MATLAB + 嵌入式工程栈总验收：MATLAB 能力链 + 硬件支持 + STM32 代码生成栈 + 外部工具链。

.DESCRIPTION
与旧版差异：
- 旧版把 `matlabValidation.passed` 硬编码为 `$true`，只要脚本不崩溃就当成 MATLAB 验收通过；
- 新版读取 Test-MatlabSkills.ps1 产出的验收 JSON 并合并，MATLAB 侧 FAIL 会直接反映到总报告；
- 硬件/工具链探测未就绪时输出 SKIP 并写明原因，不再伪装成 ready；
- L5（真实硬件运行）固定 SKIP 并说明缺少回读通道；
- 输出统一验收 JSON，可用 schemas/acceptance-report.schema.json 复核。
#>
[CmdletBinding()]
param(
    [string]$MatlabPath = $env:MATLAB_EXE,
    [string]$Root,
    [int]$TimeoutSeconds = 900,
    [string]$OutputPath
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
if (-not (Test-Path -LiteralPath $validationDir)) {
    New-Item -ItemType Directory -Force -Path $validationDir | Out-Null
}
if (-not $OutputPath) {
    $OutputPath = Join-Path $validationDir "embedded_stack_acceptance.json"
}

$matlabSkillTest = Join-Path $scriptDir "Test-MatlabSkills.ps1"
$externalProbeScript = Join-Path $scriptDir "Test-EmbeddedToolchains.ps1"
$hardwareProbeScript = Join-Path $Root "matlab\validation\matlab_hardware_support_probe.m"
$stm32CodegenProbeScript = Join-Path $Root "matlab\validation\stm32_codegen_stack_probe.m"

$matlabSkillsReportPath = Join-Path $validationDir "acceptance_report.json"

$report = New-AcceptanceReport -TaskId (New-AcceptanceTaskId -Prefix "embedded-stack") -Backend "matlab-batch"
$report.limitations = @(
    "总报告合并了 MATLAB 能力验收与外部工具链探测；SKIP 项表示未验证，不代表可用。",
    "STM32 代码生成栈 ready 仅表示 MATLAB 已注册 CubeMX 与目标硬件，不代表固件已烧录或运行。",
    "L5（硬件在环）没有实现：仓库缺少板卡回读通道与测试台架。"
)

# ---------------- 1. MATLAB 能力验收（子报告） ----------------
if (-not (Test-Path -LiteralPath $matlabSkillTest)) {
    $report = Add-AcceptanceCheck -Report $report -Id "stack.matlab-validation" -Title "MATLAB 能力验收" -Level "L1" `
        -Status "FAIL" -Reason "未找到 Test-MatlabSkills.ps1" -ErrorClass "ENVIRONMENT_ERROR"
}
else {
    & $matlabSkillTest -MatlabPath $MatlabPath -Root $Root -TimeoutSeconds $TimeoutSeconds
    $matlabExitCode = $LASTEXITCODE

    if (-not (Test-Path -LiteralPath $matlabSkillsReportPath)) {
        $report = Add-AcceptanceCheck -Report $report -Id "stack.matlab-validation" -Title "MATLAB 能力验收" -Level "L1" `
            -Status "FAIL" -Reason "Test-MatlabSkills.ps1 未产出验收报告（退出码 $matlabExitCode）" `
            -ErrorClass "VALIDATION_ERROR" -ExitCode $matlabExitCode
    }
    else {
        $child = Import-AcceptanceReport -Path $matlabSkillsReportPath
        $childValidation = Test-AcceptanceReport -Report $child
        if (-not $childValidation.Valid) {
            $report = Add-AcceptanceCheck -Report $report -Id "stack.matlab-validation" -Title "MATLAB 能力验收" -Level "L1" `
                -Status "FAIL" -Reason ("子报告不合规：" + ($childValidation.Errors -join " | ")) `
                -ErrorClass "VALIDATION_ERROR" -ExitCode $matlabExitCode -ArtifactPaths @($matlabSkillsReportPath)
        }
        else {
            $report = Merge-AcceptanceReport -Report $report -Child $child -SourceName "matlabSkills"
        }
    }
}

# ---------------- 2. MATLAB 侧硬件支持探测 ----------------
function Invoke-MatlabProbe {
    param([string]$ScriptPath, [string]$Label)

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        return [pscustomobject]@{ Ran = $false; Reason = "脚本不存在: $ScriptPath" }
    }
    $resolved = Resolve-MatlabExecutable -ExplicitPath $MatlabPath
    if (-not $resolved) {
        return [pscustomobject]@{ Ran = $false; Reason = "MATLAB 未安装，无法执行 $Label" }
    }

    $escaped = $ScriptPath.Replace("'", "''")
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $run = Invoke-MatlabBatchProcess -MatlabPath $resolved -ArgumentList @("-batch", "run('$escaped')") `
        -WorkingDirectory $Root -TimeoutSeconds $TimeoutSeconds `
        -StdoutPath (Join-Path $Root "artifacts\logs\$Label`_$timestamp.stdout.log") `
        -StderrPath (Join-Path $Root "artifacts\logs\$Label`_$timestamp.stderr.log") `
        -StageLogPath (Join-Path $Root "artifacts\logs\$Label`_$timestamp.stages.log") `
        -Label $Label

    return [pscustomobject]@{ Ran = $true; Run = $run }
}

$hardwareProbePath = Join-Path $validationDir "hardware_support_probe.json"
$hardwareOutcome = Invoke-MatlabProbe -ScriptPath $hardwareProbeScript -Label "hardware_support_probe"
if (-not $hardwareOutcome.Ran) {
    $report = Add-AcceptanceCheck -Report $report -Id "embedded.hardware-support" -Title "MATLAB 硬件支持包" -Level "L1" `
        -Status "SKIP" -Reason $hardwareOutcome.Reason -ErrorClass "ENVIRONMENT_ERROR"
}
elseif (-not (Test-Path -LiteralPath $hardwareProbePath)) {
    $report = Add-AcceptanceCheck -Report $report -Id "embedded.hardware-support" -Title "MATLAB 硬件支持包" -Level "L1" `
        -Status "FAIL" -Reason "探测脚本未产出 hardware_support_probe.json（退出码 $($hardwareOutcome.Run.ExitCode)）" `
        -ErrorClass "VALIDATION_ERROR" -ExitCode $hardwareOutcome.Run.ExitCode
}
else {
    $hardware = Import-AcceptanceReport -Path $hardwareProbePath
    $ready = [bool]$hardware.overall.ready
    $missing = @()
    foreach ($name in @("simulink", "matlabCoder", "embeddedCoder", "stm32", "raspberryPi")) {
        if ($hardware.support.$name.status -ne "installed") { $missing += $name }
    }
    if ($ready) {
        $report = Add-AcceptanceCheck -Report $report -Id "embedded.hardware-support" -Title "MATLAB 硬件支持包" -Level "L1" `
            -Status "PASS" -Metrics ([ordered]@{ status = $hardware.overall.status }) -ArtifactPaths @($hardwareProbePath)
    }
    else {
        $report = Add-AcceptanceCheck -Report $report -Id "embedded.hardware-support" -Title "MATLAB 硬件支持包" -Level "L1" `
            -Status "SKIP" -Reason ("缺少：" + ($missing -join ", ")) `
            -Metrics ([ordered]@{ status = $hardware.overall.status; missing = $missing }) -ArtifactPaths @($hardwareProbePath)
    }
}

# ---------------- 3. STM32 代码生成栈 ----------------
$stm32ProbePath = Join-Path $validationDir "stm32_codegen_stack_probe.json"
$stm32Outcome = Invoke-MatlabProbe -ScriptPath $stm32CodegenProbeScript -Label "stm32_codegen_stack_probe"
if (-not $stm32Outcome.Ran) {
    $report = Add-AcceptanceCheck -Report $report -Id "embedded.stm32-codegen-stack" -Title "STM32 代码生成链路" -Level "L1" `
        -Status "SKIP" -Reason $stm32Outcome.Reason -ErrorClass "ENVIRONMENT_ERROR"
}
elseif (-not (Test-Path -LiteralPath $stm32ProbePath)) {
    $report = Add-AcceptanceCheck -Report $report -Id "embedded.stm32-codegen-stack" -Title "STM32 代码生成链路" -Level "L1" `
        -Status "FAIL" -Reason "探测脚本未产出 stm32_codegen_stack_probe.json（退出码 $($stm32Outcome.Run.ExitCode)）" `
        -ErrorClass "VALIDATION_ERROR" -ExitCode $stm32Outcome.Run.ExitCode
}
else {
    $stm32 = Import-AcceptanceReport -Path $stm32ProbePath
    if ([bool]$stm32.overall.ready) {
        $report = Add-AcceptanceCheck -Report $report -Id "embedded.stm32-codegen-stack" -Title "STM32 代码生成链路" -Level "L1" `
            -Status "PASS" -Metrics ([ordered]@{ status = $stm32.overall.status }) -ArtifactPaths @($stm32ProbePath)
    }
    else {
        $report = Add-AcceptanceCheck -Report $report -Id "embedded.stm32-codegen-stack" -Title "STM32 代码生成链路" -Level "L1" `
            -Status "SKIP" -Reason "STM32 代码生成前置条件不足（产品/目标硬件/CubeMX 注册/固件包）" `
            -Metrics ([ordered]@{ status = $stm32.overall.status }) -ArtifactPaths @($stm32ProbePath)
    }
}

# ---------------- 4. 外部工具链 ----------------
$toolchainPath = Join-Path $validationDir "embedded_toolchain_probe.json"
if (-not (Test-Path -LiteralPath $externalProbeScript)) {
    $report = Add-AcceptanceCheck -Report $report -Id "embedded.external-toolchains" -Title "外部嵌入式工具链" -Level "L1" `
        -Status "FAIL" -Reason "未找到 Test-EmbeddedToolchains.ps1" -ErrorClass "ENVIRONMENT_ERROR"
}
else {
    & $externalProbeScript -MatlabPath $MatlabPath -Root $Root | Out-Null
    if (-not (Test-Path -LiteralPath $toolchainPath)) {
        $report = Add-AcceptanceCheck -Report $report -Id "embedded.external-toolchains" -Title "外部嵌入式工具链" -Level "L1" `
            -Status "FAIL" -Reason "探测脚本未产出 embedded_toolchain_probe.json" -ErrorClass "VALIDATION_ERROR"
    }
    else {
        $toolchain = Import-AcceptanceReport -Path $toolchainPath
        if ([bool]$toolchain.overall.ready) {
            $report = Add-AcceptanceCheck -Report $report -Id "embedded.external-toolchains" -Title "外部嵌入式工具链" -Level "L1" `
                -Status "PASS" -Metrics ([ordered]@{ status = $toolchain.overall.status }) -ArtifactPaths @($toolchainPath)
        }
        else {
            $report = Add-AcceptanceCheck -Report $report -Id "embedded.external-toolchains" -Title "外部嵌入式工具链" -Level "L1" `
                -Status "SKIP" -Reason "VS Code / CubeMX / GNU Tools / CMSIS / 固件包 / Keil 未全部就绪" `
                -Metrics ([ordered]@{ status = $toolchain.overall.status }) -ArtifactPaths @($toolchainPath)
        }
    }
}

# ---------------- 5. 硬件在环（L5） ----------------
$report = Add-AcceptanceCheck -Report $report -Id "embedded.hardware-in-loop" -Title "L5 实际硬件运行验证" -Level "L5" `
    -Status "SKIP" -Reason "仓库未提供板卡回读通道（串口/调试探针）与在环测试台架，L5 无法自动验证"

$report = Write-AcceptanceReport -Report $report -Path $OutputPath

# 一条检查项一行：Format-Table 会把长 reason 折行，反而不易读。
foreach ($check in $report.checks) {
    $reasonText = if ($check.status -ne "PASS" -and $check.reason) { ($check.reason -replace "\s+", " ") } else { "" }
    Write-Host ("{0,-32} {1,-4} {2,-5} {3}" -f $check.id, $check.level, $check.status, $reasonText)
}

Write-Host ("==> overall={0} achievedLevel={1} pass={2} fail={3} skip={4}" -f `
    $report.overallStatus, $report.achievedLevel, `
    $report.summary.pass, $report.summary.fail, $report.summary.skip) -ForegroundColor Cyan
Write-Host "EMBEDDED_STACK_ACCEPTANCE=$OutputPath"

exit (Get-AcceptanceExitCode -Report $report)
