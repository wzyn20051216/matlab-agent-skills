<#
.SYNOPSIS
MATLAB + 嵌入式工程栈总验收脚本。

.DESCRIPTION
串联 MATLAB 核心能力验收、MATLAB 硬件支持探测、以及 STM32 / Raspberry Pi /
CubeMX / Keil / VS Code 外部工具链探测，输出统一 JSON 验收报告。
#>

param(
    [string]$MatlabPath = $env:MATLAB_EXE,
    [string]$Root
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Root) {
    $Root = Split-Path -Parent $scriptDir
}

$validationDir = Join-Path $Root "artifacts\validation"
New-Item -ItemType Directory -Force -Path $validationDir | Out-Null

$matlabSkillTest = Join-Path $scriptDir "Test-MatlabSkills.ps1"
$matlabRunner = Join-Path $scriptDir "Invoke-MatlabBatch.ps1"
$hardwareProbeScript = Join-Path $Root "matlab\validation\matlab_hardware_support_probe.m"
$stm32CodegenProbeScript = Join-Path $Root "matlab\validation\stm32_codegen_stack_probe.m"
$externalProbeScript = Join-Path $scriptDir "Test-EmbeddedToolchains.ps1"

& $matlabSkillTest -MatlabPath $MatlabPath -Root $Root
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $matlabRunner -MatlabPath $MatlabPath -Script $hardwareProbeScript -WorkingDirectory $Root -Label "hardware_support_probe"
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $matlabRunner -MatlabPath $MatlabPath -Script $stm32CodegenProbeScript -WorkingDirectory $Root -Label "stm32_codegen_stack_probe"
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $externalProbeScript -MatlabPath $MatlabPath -Root $Root
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$featureProbePath = Join-Path $validationDir "feature_probe.json"
$hardwareProbePath = Join-Path $validationDir "hardware_support_probe.json"
$stm32CodegenProbePath = Join-Path $validationDir "stm32_codegen_stack_probe.json"
$toolchainProbePath = Join-Path $validationDir "embedded_toolchain_probe.json"

$featureProbe = Get-Content -Raw -Path $featureProbePath | ConvertFrom-Json
$hardwareProbe = Get-Content -Raw -Path $hardwareProbePath | ConvertFrom-Json
$stm32CodegenProbe = Get-Content -Raw -Path $stm32CodegenProbePath | ConvertFrom-Json
$toolchainProbe = Get-Content -Raw -Path $toolchainProbePath | ConvertFrom-Json

$summary = [ordered]@{
    generatedAt = (Get-Date).ToString('s')
    matlabValidation = [ordered]@{
        passed = $true
        featureProbe = $featureProbePath
        blocksetsStatus = $featureProbe.features.blocksets.status
    }
    hardwareSupport = [ordered]@{
        passed = [bool]$hardwareProbe.overall.ready
        report = $hardwareProbePath
        status = $hardwareProbe.overall.status
    }
    stm32CodegenStack = [ordered]@{
        passed = [bool]$stm32CodegenProbe.overall.ready
        report = $stm32CodegenProbePath
        status = $stm32CodegenProbe.overall.status
    }
    externalToolchains = [ordered]@{
        passed = [bool]$toolchainProbe.overall.ready
        report = $toolchainProbePath
        status = $toolchainProbe.overall.status
    }
}

$summary.overall = [ordered]@{
    passed = $summary.matlabValidation.passed -and
        ($summary.matlabValidation.blocksetsStatus -eq 'installed') -and
        $summary.hardwareSupport.passed -and
        $summary.stm32CodegenStack.passed -and
        $summary.externalToolchains.passed
    status = 'incomplete'
}

if ($summary.overall.passed) {
    $summary.overall.status = 'ready'
}

$summaryPath = Join-Path $validationDir 'embedded_stack_acceptance.json'
$summary | ConvertTo-Json -Depth 6 | Set-Content -Path $summaryPath -Encoding UTF8

Write-Host "EMBEDDED_STACK_ACCEPTANCE=$summaryPath"
Write-Host "EMBEDDED_STACK_READY=$($summary.overall.passed)"

if (-not $summary.overall.passed) {
    exit 1
}
