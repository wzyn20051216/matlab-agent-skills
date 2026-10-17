<#
.SYNOPSIS
运行仓库内全部 Pester 测试，并按测试层分离执行。

.DESCRIPTION
测试分两层，靠文件名区分，避免"没跑也算验证"：

  free    不需要 MATLAB / MCP / 网络，可在免费 CI 上完整执行。
          文件名不以 ".Matlab.Tests.ps1" 结尾的测试都属于这一层。
  matlab  需要本机已安装 MATLAB。文件名以 ".Matlab.Tests.ps1" 结尾。

运行结束后会把"哪一层真的执行了、哪一层没执行、为什么没执行"写进
artifacts/validation/tests/layer_report.json，CI 与验收报告可以直接引用，
不会因为某一层没跑就把整体当成通过。

退出码：
  0  请求的层全部执行且全部通过
  1  有测试失败
  2  请求的层因为缺少依赖没有执行（不等于通过，也不等于失败）

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1
powershell -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -Layer all
#>
[CmdletBinding()]
param(
    [ValidateSet("free", "matlab", "all")]
    [string]$Layer = "free",
    [string]$Filter = "",
    [switch]$CI,
    [string]$MatlabPath = "",
    [string]$OutputPath = "",
    # 本套件使用 Pester 3 语法（Should Be，不带中划线）。
    # 需要断言“抛异常”时用 helpers/Assertions.ps1 的 Test-Throws：
    # Pester 3.4 的 Should Throw 在 PowerShell 7 上失效，会造成 CI 全红而本机全绿。
    # Pester 5 会直接抛 "Legacy Should syntax is not supported in Pester 5"，
    # 因此必须锁定具体版本，不能"取已安装的最高版本"——那是 CI 全红的直接原因。
    [string]$PesterVersion = "3.4.0"
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$matlabLayerSuffix = ".Matlab.Tests.ps1"

# 版本选择逻辑放在 helpers 里，便于脱离 Pester 单独做回归测试。
. (Join-Path $PSScriptRoot "helpers\PesterSelection.ps1")

function Get-TestFileLayer {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name.EndsWith($matlabLayerSuffix, [System.StringComparison]::OrdinalIgnoreCase)) { return "matlab" }
    return "free"
}

$pester = Resolve-TestPesterModule -RequiredVersion $PesterVersion -RepositoryRoot $repoRoot
Write-Host "==> 使用 Pester $($pester.Version) ($($pester.Path)) [$($pester.Source)]" -ForegroundColor Cyan

Import-Module -Name $pester.Path -Force

$requestedLayers = switch ($Layer) {
    "free" { @("free") }
    "matlab" { @("matlab") }
    default { @("free", "matlab") }
}

$allFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter "*.Tests.ps1" -File | Sort-Object Name)
if ($Filter) {
    $allFiles = @($allFiles | Where-Object { $_.Name -like "*$Filter*" })
}
if ($allFiles.Count -eq 0) {
    throw "没有找到匹配的测试文件（Filter='$Filter'）。"
}

$selectedFiles = @($allFiles | Where-Object { $requestedLayers -contains (Get-TestFileLayer $_.Name) })
if ($selectedFiles.Count -eq 0) {
    throw "层 '$Layer' 下没有匹配的测试文件（Filter='$Filter'）。"
}

# ---- 探测 matlab 层的前置条件：只探测，不伪装 ----
$matlabExe = $null
$matlabInfo = $null
$matlabAvailable = $false
if ($requestedLayers -contains "matlab") {
    Import-Module (Join-Path $repoRoot "scripts\MatlabAgentSkills.Execution.psm1") -Force -DisableNameChecking
    # -MatlabPath 是显式覆盖：传空串表示自动探测（PATH / MATLAB_EXE / 常见安装位置）。
    # 传了但不存在的路径会得到 $null，从而走"matlab 层未执行"分支，便于确定性地验证跳过语义。
    $matlabExe = Resolve-MatlabExecutable -ExplicitPath $MatlabPath
    if (-not [string]::IsNullOrWhiteSpace($matlabExe)) {
        $matlabAvailable = $true
        $matlabInfo = Get-MatlabInstallInfo -ExecutablePath $matlabExe
    }
}

# 注意：写盘时用 .ToArray() 而不是 @($list)。
# Windows PowerShell 5.1 对 List[object] 使用数组子表达式 @($list) 会抛
# "参数类型不匹配"（List[string] / List[hashtable] 反而不受影响），
# 用 .ToArray() 可以稳定绕过。
$layerRecords = New-Object System.Collections.Generic.List[object]
$results = @()
$executedLayers = New-Object System.Collections.Generic.List[string]
$notExecutedLayers = New-Object System.Collections.Generic.List[string]

foreach ($name in $requestedLayers) {
    $files = @($selectedFiles | Where-Object { (Get-TestFileLayer $_.Name) -eq $name })
    if ($files.Count -eq 0) { continue }

    if ($name -eq "matlab" -and -not $matlabAvailable) {
        $reason = if ($MatlabPath) {
            "显式指定的 MATLAB 路径不存在或不可用：$MatlabPath，本层未执行"
        }
        else {
            "未发现已安装的 MATLAB（PATH / MATLAB_EXE / 常见安装位置均未命中），本层未执行"
        }
        Write-Host "==> 跳过层 matlab：$reason" -ForegroundColor Yellow
        $notExecutedLayers.Add("matlab")
        $layerRecords.Add([pscustomobject][ordered]@{
                layer       = "matlab"
                executed    = $false
                reason      = $reason
                total       = 0
                passed      = 0
                failed      = 0
                durationSec = 0
            })
        continue
    }

    $layerStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $layerResults = @()
    # 把解析结果通过 MATLAB_EXE 传给测试进程内代码，保证"用哪一个 MATLAB"只有一处来源。
    $previousMatlabExe = $env:MATLAB_EXE
    if ($name -eq "matlab" -and $matlabAvailable) { $env:MATLAB_EXE = $matlabExe }
    try {
        foreach ($file in $files) {
            Write-Host "==> 运行 [$name] $($file.Name)" -ForegroundColor Cyan
            $layerResults += Invoke-Pester -Path $file.FullName -PassThru
        }
    }
    finally {
        $env:MATLAB_EXE = $previousMatlabExe
    }
    $layerStopwatch.Stop()
    $results += $layerResults
    $executedLayers.Add($name)

    $layerRecords.Add([pscustomobject][ordered]@{
            layer       = $name
            executed    = $true
            reason      = $null
            total       = [int](($layerResults | Measure-Object -Property TotalCount -Sum).Sum)
            passed      = [int](($layerResults | Measure-Object -Property PassedCount -Sum).Sum)
            failed      = [int](($layerResults | Measure-Object -Property FailedCount -Sum).Sum)
            durationSec = [math]::Round($layerStopwatch.Elapsed.TotalSeconds, 1)
        })
}

$total = [int](($results | Measure-Object -Property TotalCount -Sum).Sum)
$passed = [int](($results | Measure-Object -Property PassedCount -Sum).Sum)
$failed = [int](($results | Measure-Object -Property FailedCount -Sum).Sum)
$skipped = 0
foreach ($result in $results) {
    if ($result.PSObject.Properties.Name -contains "SkippedCount" -and $result.SkippedCount) {
        $skipped += $result.SkippedCount
    }
}

Write-Host ""
Write-Host ("==> 汇总: 共 $total 个用例，通过 $passed，失败 $failed，跳过 $skipped") -ForegroundColor Cyan
foreach ($record in $layerRecords) {
    if ($record.executed) {
        Write-Host ("    层 {0}: 已执行 {1} 个用例，通过 {2}，失败 {3}，耗时 {4}s" -f `
                $record.layer, $record.total, $record.passed, $record.failed, $record.durationSec) -ForegroundColor Cyan
    }
    else {
        Write-Host ("    层 {0}: 未执行（{1}）" -f $record.layer, $record.reason) -ForegroundColor Yellow
    }
}

# ---- 落盘层报告，供验收/CI 引用 ----
if (-not $OutputPath) {
    $OutputPath = Join-Path $repoRoot "artifacts\validation\tests\layer_report.json"
}
$outputDir = Split-Path -Parent $OutputPath
if ($outputDir -and -not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}
$layerReport = [pscustomobject][ordered]@{
    schemaVersion   = "1.0.0"
    generatedAt     = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
    requestedLayer  = $Layer
    filter          = $(if ($Filter) { $Filter } else { $null })
    pesterVersionRequired = $PesterVersion
    pesterVersion   = "$($pester.Version)"
    pesterSource    = "$($pester.Source)"
    pesterPath      = "$($pester.Path)"
    # 记录"到底用哪个 PowerShell 跑的"。5.1 与 7 的 JSON/日期/异常语义不同，
    # 不写清楚运行面，跨版本失败就无从复现。
    powerShellVersion = $PSVersionTable.PSVersion.ToString()
    powerShellEdition = "$($PSVersionTable.PSEdition)"
    matlabAvailable = $matlabAvailable
    matlabPath      = $(if ($matlabAvailable) { $matlabExe } else { $null })
    matlabRelease   = $(if ($matlabInfo) { $matlabInfo.Release } else { $null })
    layers          = $layerRecords.ToArray()
    executedLayers  = $executedLayers.ToArray()
    notExecuted     = $notExecutedLayers.ToArray()
    totals          = [pscustomobject][ordered]@{
        total   = $total
        passed  = $passed
        failed  = $failed
        skipped = $skipped
    }
}
$json = $layerReport | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($OutputPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "==> 层报告: $OutputPath" -ForegroundColor Cyan

if ($failed -gt 0 -or $passed -lt $total) { exit 1 }
if ($notExecutedLayers.Count -gt 0) { exit 2 }
exit 0
