<#
.SYNOPSIS
把"仅大小写不同"的重复环境变量折叠成一份，避免 Windows PowerShell 5.1 直接抛异常。

.DESCRIPTION
Windows 的环境变量名**不区分大小写**，但环境块里可以同时存在 `HTTPS_PROXY` 和
`https_proxy` 两条记录 —— 只要父进程是用一份手工拼装的环境块把子进程创建出来的，
就会出现这种状态（Git Bash、Docker Desktop、Clash 之类的代理注入、CI runner 都常见）。

在这个状态下，Windows PowerShell 5.1 的多处路径会直接炸：

  - `Get-ChildItem Env:` / `[Environment]::GetEnvironmentVariables()`：
    "已添加项。字典中的关键字:"HTTPS_PROXY"所添加的关键字:"https_proxy""
  - `Start-Process`：同样的 ArgumentException，异常抛出点在被测代码的调用栈里，
    看起来像是"被测功能坏了"，实际与被测行为无关。

实测（2026-10-28）：同一份仓库、同一台机器，仅因为当前进程里有大写+小写两份代理变量，
免费层从 402/403 掉到 398/403，四个失败全是 `Start-Process` 抛的同一个 ArgumentException。
这不是被测代码的缺陷，但它会稳定地把"环境问题"伪装成"功能回归"，必须在框架层消掉。

**为什么不能用 $env: 或 Env: 提供程序来修**：存在重复项时它们连枚举都会抛，
所以这里改用 kernel32 的 `GetEnvironmentStringsW` 读取**保留大小写与重复项**的原始环境块。

.OUTPUTS
Repair-DuplicateEnvironmentNames 返回 Normalized / Groups / RemovedCount / RemainingGroups。
不虚构"已修复"：RemainingGroups 非 0 时 Normalized 为 false，调用方必须如实报告。
#>

if (-not ('Mas.EnvNative' -as [type])) {
    Add-Type -Namespace Mas -Name EnvNative -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr GetEnvironmentStringsW();

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool FreeEnvironmentStringsW(IntPtr block);
'@
}

function Get-RawEnvironmentEntry {
    <#
    .SYNOPSIS
    读取当前进程的原始环境块，保留每一项的原始大小写与重复项。

    .OUTPUTS
    string[]，每项形如 "NAME=VALUE"，顺序与系统返回一致。
    #>
    [OutputType([string[]])]
    [CmdletBinding()]
    param()

    $entries = New-Object 'System.Collections.Generic.List[string]'
    try {
        $block = [Mas.EnvNative]::GetEnvironmentStringsW()
    }
    catch {
        return $entries.ToArray()
    }
    if ($block -eq [IntPtr]::Zero) { return $entries.ToArray() }

    try {
        $offset = 0
        while ($true) {
            $ptr = [IntPtr]::Add($block, $offset * 2)
            $item = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr)
            if ([string]::IsNullOrEmpty($item)) { break }
            $entries.Add($item)
            $offset += $item.Length + 1
        }
    }
    finally {
        [void][Mas.EnvNative]::FreeEnvironmentStringsW($block)
    }
    return $entries.ToArray()
}

function Get-EnvironmentNormalizationPlan {
    <#
    .SYNOPSIS
    纯函数：从原始环境项算出"每组重复项保留谁、删谁"，不触碰真实环境，便于单测。

    .DESCRIPTION
    赢家规则：优先取**全大写名称**（Windows 的通行写法，也是 $env:HTTP_PROXY 的惯用写法），
    否则取出现顺序最靠前的一条。被跳过的是 `=C:=...` 这类以 '=' 开头的驱动器当前目录项。

    .OUTPUTS
    PSCustomObject[]：Name / Value / Removed / DuplicateCount，只包含真有重复的组。
    #>
    [CmdletBinding()]
    param([string[]]$Entry = @())

    $groups = [ordered]@{}
    foreach ($item in $Entry) {
        if ([string]::IsNullOrEmpty($item)) { continue }
        $eq = $item.IndexOf('=')
        # '=' 开头的是驱动器当前目录项（=C:=C:\path），不是普通变量，跳过。
        if ($eq -le 0) { continue }
        $name = $item.Substring(0, $eq)
        $value = $item.Substring($eq + 1)
        $key = $name.ToLowerInvariant()
        if (-not $groups.Contains($key)) {
            $groups[$key] = New-Object 'System.Collections.Generic.List[object]'
        }
        $groups[$key].Add([pscustomobject]@{ Name = $name; Value = $value })
    }

    $plan = New-Object 'System.Collections.Generic.List[object]'
    foreach ($key in $groups.Keys) {
        $items = $groups[$key]
        if ($items.Count -lt 2) { continue }

        $winner = $items[0]
        foreach ($candidate in $items) {
            if ($candidate.Name -ceq $candidate.Name.ToUpperInvariant()) {
                $winner = $candidate
                break
            }
        }

        $removed = New-Object 'System.Collections.Generic.List[string]'
        $seenWinner = $false
        foreach ($candidate in $items) {
            # 用引用比较，不用名称比较：名称只差大小写，按名比较会把赢家自己也删掉。
            if (-not $seenWinner -and [object]::ReferenceEquals($candidate, $winner)) {
                $seenWinner = $true
                continue
            }
            $removed.Add($candidate.Name)
        }

        $plan.Add([pscustomobject]@{
                Name           = $winner.Name
                Value          = $winner.Value
                Removed        = $removed.ToArray()
                DuplicateCount = $items.Count
            })
    }
    return $plan.ToArray()
}

function Repair-DuplicateEnvironmentNames {
    <#
    .SYNOPSIS
    把大小写重复的环境变量折叠成一份，并如实报告是否真的折叠成功。

    .DESCRIPTION
    删除与重设都走 [Environment]::SetEnvironmentVariable，它对名称大小写不敏感 ——
    删除 https_proxy 有可能删掉的是 HTTPS_PROXY。所以每轮结束后**重新读取原始环境块复验**，
    未收敛就重试，最多 5 轮；仍不收敛则 Normalized=false，绝不谎报成功。

    .OUTPUTS
    PSCustomObject：Normalized / Groups / RemovedCount / RemainingGroups / Error
    #>
    [CmdletBinding()]
    param()

    $applied = New-Object 'System.Collections.Generic.List[object]'
    $removedTotal = 0
    $errorText = ""

    for ($round = 0; $round -lt 5; $round++) {
        $plan = @(Get-EnvironmentNormalizationPlan -Entry (Get-RawEnvironmentEntry))
        if ($plan.Count -eq 0) { break }
        foreach ($group in $plan) {
            foreach ($duplicateName in $group.Removed) {
                try {
                    [Environment]::SetEnvironmentVariable($duplicateName, $null)
                    $removedTotal++
                }
                catch {
                    $errorText = $_.Exception.Message
                }
            }
            try {
                [Environment]::SetEnvironmentVariable($group.Name, $group.Value)
            }
            catch {
                $errorText = $_.Exception.Message
            }
            $applied.Add($group)
        }
    }

    $remaining = @(Get-EnvironmentNormalizationPlan -Entry (Get-RawEnvironmentEntry))
    return [pscustomobject]@{
        Normalized      = ($remaining.Count -eq 0)
        Groups          = $applied.ToArray()
        RemovedCount    = $removedTotal
        RemainingGroups = $remaining.Count
        Error           = $errorText
    }
}
