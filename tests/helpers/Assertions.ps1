<#
.SYNOPSIS
跨 PowerShell 版本可靠的断言辅助。

.DESCRIPTION
为什么不用 `Should Throw`：
    Pester 3.4 的 `Should Throw` 在 Windows PowerShell 5.1 上正常工作，
    但在 PowerShell 7 上不会检测到异常（用例直接失败，提示
    "Expected: the expression to throw an exception"）。
    这会让"同一份代码在 CI（pwsh 7）全红、在本机（5.1）全绿"，
    而且失败信息看起来像是被测代码没抛错。

    这里改用 try/catch 自己判定，5.1 与 7 行为一致。
    Pester 版本仍然锁定 3.4.0（语法是 Pester 3 的 `Should Be`），
    但断言实现不依赖框架的 Throw 语义。

用法：
    (Test-Throws { Do-Something -Bad }) | Should Be $true
    (Test-Throws { Do-Something -Good }) | Should Be $false
#>

function Test-Throws {
    <#
    .SYNOPSIS
    执行脚本块；抛异常返回 $true，正常返回 $false。
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )

    try {
        & $ScriptBlock | Out-Null
        return $false
    }
    catch {
        return $true
    }
}

function Get-ThrownError {
    <#
    .SYNOPSIS
    执行脚本块并返回捕获到的异常；没有异常时返回 $null。
    .DESCRIPTION
    需要断言"抛的是哪一种错"时用它，避免只判断"有没有抛"。
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )

    try {
        & $ScriptBlock | Out-Null
        return $null
    }
    catch {
        return $_
    }
}
