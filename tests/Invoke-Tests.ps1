<#
.SYNOPSIS
运行仓库内全部 Pester 测试。

.DESCRIPTION
优先使用本机可用最高版本 Pester；测试本身用 legacy Should 语法，兼容 3.4 / 4.x / 5.x。
不需要 MATLAB、Codex 或 Claude；所有写操作都在临时目录内。

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1
#>
[CmdletBinding()]
param(
    [string]$Filter = "",
    [switch]$CI
)

$ErrorActionPreference = "Stop"

$available = Get-Module -ListAvailable Pester | Sort-Object Version -Descending
if (-not $available) {
    throw "未找到 Pester。请先安装（Install-Module Pester -Scope CurrentUser），或在 CI 中预装 Pester。"
}

$pester = $available | Select-Object -First 1
Write-Host "==> 使用 Pester $($pester.Version) ($($pester.Path))" -ForegroundColor Cyan

Import-Module -Name $pester.Path -Force

$testFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter "*.Tests.ps1" -File | Sort-Object Name)
if ($Filter) {
    $testFiles = @($testFiles | Where-Object { $_.Name -like "*$Filter*" })
}
if ($testFiles.Count -eq 0) {
    throw "没有找到匹配的测试文件（Filter='$Filter'）。"
}

$results = @()
foreach ($file in $testFiles) {
    Write-Host "==> 运行 $($file.Name)" -ForegroundColor Cyan
    $results += Invoke-Pester -Path $file.FullName -PassThru
}

$total = ($results | Measure-Object -Property TotalCount -Sum).Sum
$passed = ($results | Measure-Object -Property PassedCount -Sum).Sum
$failed = ($results | Measure-Object -Property FailedCount -Sum).Sum
$skipped = 0
foreach ($result in $results) {
    if ($result.PSObject.Properties.Name -contains "SkippedCount" -and $result.SkippedCount) {
        $skipped += $result.SkippedCount
    }
}

Write-Host ""
Write-Host ("==> 汇总: 共 $total 个用例，通过 $passed，失败 $failed，跳过 $skipped") -ForegroundColor Cyan

if ($failed -gt 0 -or $passed -lt $total) {
    exit 1
}
exit 0
