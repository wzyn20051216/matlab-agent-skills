<#
.SYNOPSIS
环境变量名大小写重复的折叠逻辑：纯函数可单测，真实折叠要如实报告结果。

.DESCRIPTION
Windows 的环境变量名不区分大小写，但环境块里可以有 `HTTPS_PROXY` 和 `https_proxy` 两条。
该状态下 Windows PowerShell 5.1 的 `Get-ChildItem Env:` 与 `Start-Process` 都会抛
ArgumentException —— 实测 2026-10-28 让免费层从 402/403 掉到 398/403，而被测功能并没有坏。

这里钉住三件事：

1. 只有**真的仅大小写不同**才算重复；`HTTP_PROXY` 与 `HTTPS_PROXY` 不是重复；
2. 赢家优先全大写名称，值取赢家自己的值（不能因为折叠把值改掉）；
3. `=C:=...` 这类驱动器当前目录项必须被跳过，不能当成变量处理。

另外验证幂等与"没有重复时零动作"：一个能自己制造重复的修复脚本，
在没有重复的环境里必须什么都不做。
#>

. (Join-Path $PSScriptRoot 'helpers/Assertions.ps1')
. (Join-Path $PSScriptRoot 'helpers/EnvironmentNormalization.ps1')

Describe '环境变量大小写重复：计划计算' {

    It '没有重复时返回空计划' {
        $plan = @(Get-EnvironmentNormalizationPlan -Entry @('PATH=C:\x', 'TEMP=C:\t'))
        $plan.Count | Should Be 0
    }

    It '仅大小写不同的两条算重复，且保留全大写名称与它自己的值' {
        $plan = @(Get-EnvironmentNormalizationPlan -Entry @(
                'HTTPS_PROXY=http://upper:1',
                'https_proxy=http://lower:2'
            ))
        $plan.Count | Should Be 1
        $plan[0].Name | Should Be 'HTTPS_PROXY'
        $plan[0].Value | Should Be 'http://upper:1'
        $plan[0].DuplicateCount | Should Be 2
        @($plan[0].Removed).Count | Should Be 1
        $plan[0].Removed[0] | Should Be 'https_proxy'
    }

    It '仅大小写不同的名称不算重复（HTTP_PROXY 与 HTTPS_PROXY 是两个变量）' {
        $plan = @(Get-EnvironmentNormalizationPlan -Entry @(
                'HTTP_PROXY=http://a:1',
                'HTTPS_PROXY=http://b:1'
            ))
        $plan.Count | Should Be 0
    }

    It '没有全大写形式时保留先出现的那条' {
        $plan = @(Get-EnvironmentNormalizationPlan -Entry @(
                'my_var=first',
                'My_Var=second'
            ))
        $plan.Count | Should Be 1
        $plan[0].Name | Should Be 'my_var'
        $plan[0].Value | Should Be 'first'
    }

    It '三条重复只留一条，其余两条进 Removed' {
        $plan = @(Get-EnvironmentNormalizationPlan -Entry @(
                'api_key=a',
                'API_KEY=b',
                'Api_Key=c'
            ))
        $plan.Count | Should Be 1
        $plan[0].Name | Should Be 'API_KEY'
        $plan[0].Value | Should Be 'b'
        @($plan[0].Removed).Count | Should Be 2
    }

    It '跳过驱动器当前目录项与空项' {
        $plan = @(Get-EnvironmentNormalizationPlan -Entry @('=C:=C:\work', '', 'PATH=C:\x', 'path=C:\y'))
        $plan.Count | Should Be 1
        $plan[0].Name | Should Be 'PATH'
        $plan[0].Value | Should Be 'C:\x'
    }

    It '值里含等号时只按第一个等号切分' {
        $plan = @(Get-EnvironmentNormalizationPlan -Entry @('EQ_TEST=a=b=c', 'eq_test=d'))
        $plan.Count | Should Be 1
        $plan[0].Name | Should Be 'EQ_TEST'
        $plan[0].Value | Should Be 'a=b=c'
    }
}

Describe '环境变量大小写重复：真实环境折叠' {

    It '当前进程没有重复时什么都不做，并报告 Normalized' {
        # 先清一次，保证本用例的起点确定
        [void](Repair-DuplicateEnvironmentNames)
        $result = Repair-DuplicateEnvironmentNames
        $result.Groups.Count | Should Be 0
        $result.Normalized | Should Be $true
        $result.RemainingGroups | Should Be 0
    }

    It '折叠后再次调用是幂等的' {
        $first = Repair-DuplicateEnvironmentNames
        $second = Repair-DuplicateEnvironmentNames
        $second.Groups.Count | Should Be 0
        $second.Normalized | Should Be $true
        $first.Normalized | Should Be $true
    }

    It '原始环境块能读出至少一项，且折叠后不再有重复' {
        $entries = @(Get-RawEnvironmentEntry)
        $entries.Count -gt 0 | Should Be $true
        @(Get-EnvironmentNormalizationPlan -Entry $entries).Count | Should Be 0
    }
}
