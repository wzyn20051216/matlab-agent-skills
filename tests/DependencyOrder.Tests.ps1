<#
.SYNOPSIS
依赖检查顺序回归测试（免费层，无需 MATLAB）。

.DESCRIPTION
真实缺陷：matlab_codegen_smoke.m 曾经在第 34 行构造参数时调用 coder.typeof(state)，
而依赖检测 masacc.availability("MATLAB Coder") 在第 35 行。
缺少 MATLAB Coder 授权时，脚本会在进入 SKIP 分支之前就抛出未捕获异常，
结果是"崩溃"而不是"带原因的 SKIP"，报告里什么也看不到。

这里用静态扫描把这条规则钉住：
凡是使用 coder.typeof / coder.config / codegen / slbuild 的验证脚本，
第一次出现这些调用的位置必须晚于第一次依赖检测。
注释行不参与判断（文档里可以随便举例）。
#>

$helpers = Join-Path $PSScriptRoot "helpers\TestSandbox.ps1"
. $helpers

$repoRoot = Get-TestRepositoryRoot
$validationDir = Join-Path $repoRoot "matlab\validation"

function Get-CodeLines {
    param([Parameter(Mandatory)][string]$Path)
    $lines = [System.IO.File]::ReadAllLines($Path)
    $result = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $trimmed = $lines[$i].TrimStart()
        if ($trimmed.StartsWith("%")) { continue }          # 整行注释
        $result.Add([pscustomobject]@{ Number = $i + 1; Text = $lines[$i] })
    }
    return $result
}

function Get-FirstMatchLine {
    param(
        [object[]]$Lines,
        [Parameter(Mandatory)][string]$Pattern
    )
    foreach ($line in $Lines) {
        if ($line.Text -match $Pattern) { return $line.Number }
    }
    return $null
}

Describe "依赖检查顺序" {

    $scripts = @(Get-ChildItem -LiteralPath $validationDir -Filter "*.m" -File)

    It "验证脚本目录存在且包含 .m 脚本" {
        $scripts.Count -gt 0 | Should Be $true
    }

    foreach ($script in $scripts) {
        $codeLines = Get-CodeLines -Path $script.FullName
        $dependencyLine = Get-FirstMatchLine -Lines $codeLines -Pattern '\bcoder\.(typeof|config)\b|\bcodegen\s+-config\b|\bslbuild\s*\('
        if ($null -eq $dependencyLine) { continue }

        Context "$($script.Name)" {

            It "使用 Coder/Slbuild 的脚本必须先做依赖检测" {
                $detectLine = Get-FirstMatchLine -Lines $codeLines -Pattern 'masacc\.availability\s*\('
                $detectLine | Should Not Be $null
            }

            It "首次 Coder 调用（行 $dependencyLine）必须晚于首次依赖检测" {
                $detectLine = Get-FirstMatchLine -Lines $codeLines -Pattern 'masacc\.availability\s*\('
                if ($null -eq $detectLine) { return }   # 上一条用例已报错
                ($dependencyLine -gt $detectLine) | Should Be $true
            }
        }
    }

    It "matlab_codegen_smoke.m 的参数构造已被移入 try 块" {
        # 专门针对历史缺陷：顶层不得再出现 coder.typeof 调用。
        $path = Join-Path $validationDir "matlab_codegen_smoke.m"
        $lines = [System.IO.File]::ReadAllLines($path)
        $typeofLines = @()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].TrimStart().StartsWith("%")) { continue }
            if ($lines[$i] -match 'coder\.typeof') { $typeofLines += ($i + 1) }
        }
        $typeofLines.Count -gt 0 | Should Be $true

        # 每一处 coder.typeof 前 12 行内必须出现 try，说明它在受保护的分支里。
        foreach ($lineNumber in $typeofLines) {
            $start = [math]::Max(0, $lineNumber - 13)
            $window = ($lines[$start..($lineNumber - 1)] -join "`n")
            ($window -match '\btry\b') | Should Be $true
        }
    }
}
