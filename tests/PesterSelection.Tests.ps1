<#
.SYNOPSIS
Pester 版本选择回归测试（免费层，无需 MATLAB）。

.DESCRIPTION
真实事故：CI runner 上同时有 Pester 3.4.0 与 5.9.0，旧实现取"最高版本"选到 5.9.0，
本套件的 Pester 3 语法在 5.x 下直接抛错，124 个用例全失败，而本地因为只装了 3.4.0 一直是通过的。
这里把选择逻辑当纯函数测，保证它永远不会"自作聪明"降级或升级到别的版本。
#>

$helpers = Join-Path $PSScriptRoot "helpers\PesterSelection.ps1"
. $helpers

Describe "Pester 版本选择" {

    It "同时存在 3.4.0 与 5.9.0 时必须选 3.4.0" {
        $candidates = @(
            [pscustomobject]@{ Version = "5.9.0"; Path = "C:\pwsh\Pester\5.9.0\Pester.psd1" }
            [pscustomobject]@{ Version = "3.4.0"; Path = "C:\winps\Pester\3.4.0\Pester.psd1" }
        )
        $picked = Select-PesterCandidate -Candidates $candidates -RequiredVersion "3.4.0"
        $picked | Should Not Be $null
        [string]$picked.Version | Should Be "3.4.0"
    }

    It "顺序反过来也必须选 3.4.0（不依赖输入顺序）" {
        $candidates = @(
            [pscustomobject]@{ Version = "3.4.0"; Path = "a" }
            [pscustomobject]@{ Version = "5.9.0"; Path = "b" }
        )
        [string](Select-PesterCandidate -Candidates $candidates -RequiredVersion "3.4.0").Version | Should Be "3.4.0"
    }

    It "只有 5.x 时返回 null，绝不降级到 5.x" {
        $candidates = @([pscustomobject]@{ Version = "5.9.0"; Path = "b" })
        $picked = Select-PesterCandidate -Candidates $candidates -RequiredVersion "3.4.0"
        $picked | Should Be $null
    }

    It "同主版本不同次版本不匹配（3.3 不能顶替 3.4）" {
        $candidates = @([pscustomobject]@{ Version = "3.3.5"; Path = "c" })
        (Select-PesterCandidate -Candidates $candidates -RequiredVersion "3.4.0") | Should Be $null
    }

    It "3.4 与 3.4.0 视为同一版本（版本号缺省段视为 0）" {
        $candidates = @([pscustomobject]@{ Version = "3.4"; Path = "d" })
        ($null -ne (Select-PesterCandidate -Candidates $candidates -RequiredVersion "3.4.0")) | Should Be $true
    }

    It "空候选列表返回 null 而不是抛异常" {
        (Select-PesterCandidate -Candidates @() -RequiredVersion "3.4.0") | Should Be $null
    }

    It "无法解析的候选版本会被跳过而不是让整个函数崩掉" {
        $candidates = @(
            [pscustomobject]@{ Version = "not-a-version"; Path = "e" }
            [pscustomobject]@{ Version = "3.4.0"; Path = "f" }
        )
        [string](Select-PesterCandidate -Candidates $candidates -RequiredVersion "3.4.0").Version | Should Be "3.4.0"
    }

    It "要求版本本身非法时给出可读错误" {
        { Select-PesterCandidate -Candidates @() -RequiredVersion "abc" } | Should Throw
    }

    It "版本摘要列出全部候选，便于排障" {
        $candidates = @(
            [pscustomobject]@{ Version = "5.9.0" }
            [pscustomobject]@{ Version = "3.4.0" }
        )
        $summary = Get-PesterVersionSummary -Candidates $candidates
        ($summary -match "5\.9\.0") | Should Be $true
        ($summary -match "3\.4\.0") | Should Be $true
    }

    It "无候选时版本摘要显示（无）" {
        (Get-PesterVersionSummary -Candidates @()) | Should Be "（无）"
    }

    It "套件默认锁定的 Pester 版本必须是 3.4.0" {
        # 防止有人把默认值改回"最高版本"或误改成 5.x。
        $scriptText = [System.IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) "tests\Invoke-Tests.ps1"))
        ($scriptText -match '\[string\]\$PesterVersion\s*=\s*"3\.4\.0"') | Should Be $true
    }
}
