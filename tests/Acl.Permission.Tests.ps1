<#
.SYNOPSIS
ACL 有效权限校验的回归测试（隔离临时目录内运行）。

.DESCRIPTION
背景：原来的写后校验只判断"SID 是否出现在 ACL 里"。这个判断有四种失真形态：

  1. 只有 Deny ACE        -> SID 在 ACL 里，实际权限是 0
  2. 只有 (OI)(CI)R       -> SID 在 ACL 里，目录只读，安装写文件必失败
  3. FullControl 但无继承  -> 目录本身可写，新建子项拿不到权限
  4. 同一 SID 多条 ACE     -> 任取一条判断都不成立，必须做集合运算

本文件分两层验证：
  - 纯函数层（Resolve-AclRuleSet）：覆盖真实 ACL 造不出来的组合（icacls 会把
    同一 SID 的多条 ACE 合并），包括多 ACE 并集、Deny 优先、InheritOnly。
  - 真实 ACL 层：用 icacls 在临时目录上真实写入拒绝 / 只读 / 无继承 / RID 500，
    确认校验函数与 Set-DirectoryAclGrant 的行为与真实权限一致。

所有权限变更只发生在 %TEMP% 下的专用子目录；测试结束删除。
不修改用户真实工作目录或配置文件。
#>

. (Join-Path $PSScriptRoot "helpers\Assertions.ps1")
. (Join-Path $PSScriptRoot "helpers\TestSandbox.ps1")

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $script:RepoRoot "scripts\MatlabAgentSkills.Core.psm1") -Force -DisableNameChecking

$script:FullControl = 2032127

function New-AceRule {
    <#
    .SYNOPSIS
    造一条归一化 ACE 记录，供纯函数层使用。
    #>
    param(
        [ValidateSet("Allow", "Deny")][string]$AccessType = "Allow",
        [int]$Rights = 2032127,
        [switch]$NoSelf,
        [switch]$NoChild,
        [switch]$NoContainer,
        [switch]$NoObject
    )
    return [pscustomobject]@{
        AccessType     = $AccessType
        Rights         = $Rights
        AppliesToSelf  = (-not $NoSelf)
        AppliesToChild = (-not $NoChild)
        HasContainer   = (-not $NoContainer)
        HasObject      = (-not $NoObject)
    }
}

function New-SealedTestDir {
    <#
    .SYNOPSIS
    在沙箱里建一个"封闭继承"的目录：先移除继承 ACE，再显式给当前用户 FullControl。
    .DESCRIPTION
    不封闭继承的话，父目录继承来的 Allow 会混进有效权限计算，
    让"只读 ACE"这类用例失去意义（继承的 FullControl 会把它补全）。
    #>
    param([Parameter(Mandatory)]$Sandbox)

    $dir = Join-Path $Sandbox.Root ("data-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls $dir /inheritance:r /grant:r ("*" + $me + ":(OI)(CI)F") | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "无法封闭测试目录的继承（icacls exit=$LASTEXITCODE）"
    }
    return $dir
}

function Get-Rid500Sid {
    <#
    .SYNOPSIS
    取一个 RID 500 账户的 SID：优先当前身份，其次本机内置 Administrator。
    .DESCRIPTION
    GitHub runner 的 runneradmin 本身就是 RID 500，此时直接用当前身份；
    普通开发机上当前用户不是 RID 500，就去翻译本机 Administrator。
    两者都不可用时返回 $null，由调用方 SKIP 并打印原因——不静默通过。
    #>
    $current = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    if ($current.Value.EndsWith("-500")) { return $current.Value }

    foreach ($name in @("$env:COMPUTERNAME\Administrator", "Administrator")) {
        try {
            $sid = (New-Object System.Security.Principal.NTAccount($name)).Translate([System.Security.Principal.SecurityIdentifier])
            if ($null -ne $sid) { return $sid.Value }
        }
        catch { continue }
    }
    return $null
}

Describe "ACL 有效权限：纯规则求解" {

    It "单条 (OI)(CI) FullControl Allow 满足目录与子对象要求" {
        $resolved = Resolve-AclRuleSet -Rules @((New-AceRule))
        $resolved.FolderRights | Should Be $script:FullControl
        $resolved.ChildRights | Should Be $script:FullControl
        $resolved.HasInheritingFullControl | Should Be $true
    }

    It "只读 ACE 不会被当成 FullControl" {
        $readOnly = 1179785   # (OI)(CI)R 的实测掩码
        $resolved = Resolve-AclRuleSet -Rules @((New-AceRule -Rights $readOnly))
        (($resolved.FolderRights -band $script:FullControl) -eq $script:FullControl) | Should Be $false
        (($resolved.FolderRights -band 0x2) -eq 0x2) | Should Be $false   # 没有 WriteData
        $resolved.HasInheritingFullControl | Should Be $false
    }

    It "只有 Deny ACE 时有效权限为零" {
        $resolved = Resolve-AclRuleSet -Rules @((New-AceRule -AccessType "Deny"))
        $resolved.FolderRights | Should Be 0
        $resolved.ChildRights | Should Be 0
        $resolved.HasInheritingFullControl | Should Be $false
    }

    It "Deny 优先于同范围 Allow：Allow F + Deny W 扣掉写权限" {
        $resolved = Resolve-AclRuleSet -Rules @(
            (New-AceRule -AccessType "Allow" -Rights $script:FullControl)
            (New-AceRule -AccessType "Deny" -Rights 0x116)     # WriteData|AppendData|WriteAttributes
        )
        (($resolved.FolderRights -band 0x2) -eq 0x2) | Should Be $false
        (($resolved.FolderRights -band 0x10000) -eq 0x10000) | Should Be $true   # Delete 仍在
        ($resolved.FolderDeny -eq 0x116) | Should Be $true
    }

    It "同一 SID 多条 ACE 取并集：R + W + D 仍不等于 FullControl" {
        # icacls 会把同一 SID 的多条 ACE 合并，真实 ACL 造不出这个形态，所以在这里测。
        $resolved = Resolve-AclRuleSet -Rules @(
            (New-AceRule -Rights 1179785)     # R
            (New-AceRule -Rights 0x2)         # WriteData
            (New-AceRule -Rights 0x10000)     # Delete
        )
        (($resolved.FolderRights -band 0x2) -eq 0x2) | Should Be $true
        (($resolved.FolderRights -band 0x10000) -eq 0x10000) | Should Be $true
        (($resolved.FolderRights -band $script:FullControl) -eq $script:FullControl) | Should Be $false
        $resolved.HasInheritingFullControl | Should Be $false
    }

    It "多条 Allow 覆盖全部位时并集等于 FullControl" {
        # 把 FullControl 拆成两半，验证并集运算本身正确：
        #   0x120089 = Synchronize|ReadPermissions|ReadAttributes|ReadExtendedAttributes|ReadData
        #   0x0D0176 = TakeOwnership|ChangePermissions|Delete|WriteAttributes|DeleteSubdirs|
        #              Traverse|WriteExtendedAttributes|AppendData|WriteData
        # 两者 OR 之后必须正好是 0x1F01FF。
        $resolved = Resolve-AclRuleSet -Rules @(
            (New-AceRule -Rights 1179785)
            (New-AceRule -Rights 852342)
        )
        ($resolved.FolderRights -eq $script:FullControl) | Should Be $true
        $resolved.HasInheritingFullControl | Should Be $false   # 单条都不完整，只有并集完整
    }

    It "InheritOnly ACE 不作用于目录自身，但作用于子对象" {
        $resolved = Resolve-AclRuleSet -Rules @(
            (New-AceRule -NoSelf)
        )
        $resolved.FolderRights | Should Be 0
        $resolved.ChildRights | Should Be $script:FullControl
    }

    It "无继承标志的 ACE 满足目录自身但不满足子对象" {
        $resolved = Resolve-AclRuleSet -Rules @(
            (New-AceRule -NoChild -NoContainer -NoObject)
        )
        $resolved.FolderRights | Should Be $script:FullControl
        $resolved.ChildRights | Should Be 0
        $resolved.HasInheritingFullControl | Should Be $false
    }

    It "只有 ContainerInherit（缺 ObjectInherit）不满足继承要求" {
        $resolved = Resolve-AclRuleSet -Rules @(
            (New-AceRule -NoObject)
        )
        $resolved.HasInheritingFullControl | Should Be $false
    }
}

Describe "ACL 有效权限：真实目录" {

    It "只读授权被判为权限不足，且原因指出缺失位" {
        if (-not (Get-Command icacls -ErrorAction SilentlyContinue)) { return }
        $sandbox = New-TestSandbox -Prefix "acl-ro"
        try {
            $dir = New-SealedTestDir -Sandbox $sandbox
            & icacls $dir /grant:r "*S-1-5-18:(OI)(CI)R" | Out-Null
            $LASTEXITCODE | Should Be 0

            $verification = Test-AclGrantsFullControl -Path $dir -Sid "S-1-5-18" -RequireInheritance
            $verification.Granted | Should Be $false
            ($verification.Reason -match "权限不足") | Should Be $true
            ($verification.Reason -match "WriteData") | Should Be $true
            # SID 确实存在 —— 证明"存在性"判断会误判通过。
            (Test-AclContainsSid -Path $dir -Sid "S-1-5-18") | Should Be $true
        }
        finally { Remove-TestSandbox -Sandbox $sandbox }
    }

    It "只有 Deny ACE 时被判为无权限，原因点名 Deny" {
        if (-not (Get-Command icacls -ErrorAction SilentlyContinue)) { return }
        $sandbox = New-TestSandbox -Prefix "acl-deny"
        try {
            $dir = New-SealedTestDir -Sandbox $sandbox
            & icacls $dir /deny "*S-1-5-18:(OI)(CI)F" | Out-Null
            $LASTEXITCODE | Should Be 0

            $verification = Test-AclGrantsFullControl -Path $dir -Sid "S-1-5-18" -RequireInheritance
            $verification.Granted | Should Be $false
            ($verification.Reason -match "Deny") | Should Be $true
            $verification.FolderRights | Should Be 0
        }
        finally { Remove-TestSandbox -Sandbox $sandbox }
    }

    It "FullControl 但无继承标志时，目录通过、子对象不通过" {
        if (-not (Get-Command icacls -ErrorAction SilentlyContinue)) { return }
        # CI runner 上当前进程用户可能就是 S-1-5-18；与"外来 SID"撞车会让用例失真。
        $testSid = if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18') { 'S-1-5-11' } else { 'S-1-5-18' }
        $sandbox = New-TestSandbox -Prefix "acl-noinherit"
        try {
            $dir = New-SealedTestDir -Sandbox $sandbox
            & icacls $dir /remove ("*" + $testSid) | Out-Null
            & icacls $dir /grant:r ("*" + $testSid + ":F") | Out-Null
            $LASTEXITCODE | Should Be 0

            $withoutInheritance = Test-AclGrantsFullControl -Path $dir -Sid $testSid
            $withoutInheritance.Granted | Should Be $true
            $withoutInheritance.FolderRights | Should Be $script:FullControl

            $withInheritance = Test-AclGrantsFullControl -Path $dir -Sid $testSid -RequireInheritance
            $withInheritance.Granted | Should Be $false
            $withInheritance.ChildRights | Should Be 0
            ($withInheritance.Reason -match "继承") | Should Be $true
        }
        finally { Remove-TestSandbox -Sandbox $sandbox }
    }

    It "Allow F 叠加 Deny W 时判为权限不足，且 Deny 掩码被记录" {
        if (-not (Get-Command icacls -ErrorAction SilentlyContinue)) { return }
        $sandbox = New-TestSandbox -Prefix "acl-deny-w"
        try {
            $dir = New-SealedTestDir -Sandbox $sandbox
            & icacls $dir /grant:r "*S-1-5-18:(OI)(CI)F" | Out-Null
            & icacls $dir /deny "*S-1-5-18:(W)" | Out-Null
            $LASTEXITCODE | Should Be 0

            $verification = Test-AclGrantsFullControl -Path $dir -Sid "S-1-5-18" -RequireInheritance
            $verification.Granted | Should Be $false
            ($verification.FolderDeny -ne 0) | Should Be $true
            (($verification.FolderRights -band 0x2) -eq 0x2) | Should Be $false
            # 子对象继承的 FullControl 未被这条无继承标志的 Deny 影响。
            $verification.ChildRights | Should Be $script:FullControl
        }
        finally { Remove-TestSandbox -Sandbox $sandbox }
    }

    It "内置管理员账户（RID 500）在 SDDL 显示为别名时仍能正确判定" {
        if (-not (Get-Command icacls -ErrorAction SilentlyContinue)) { return }
        $sid = Get-Rid500Sid
        if (-not $sid) {
            Write-Host "SKIP：本机既有身份不是 RID 500，也无法翻译内置 Administrator 账户。"
            return
        }

        $sandbox = New-TestSandbox -Prefix "acl-rid500"
        try {
            $dir = New-SealedTestDir -Sandbox $sandbox
            & icacls $dir /grant:r ("*" + $sid + ":(OI)(CI)F") | Out-Null
            $LASTEXITCODE | Should Be 0

            $sddl = (Get-Acl -LiteralPath $dir).Sddl
            # 前提：SDDL 用别名 LA 表示 RID 500，字面量搜索必然落空。
            ($sddl -match [regex]::Escape($sid)) | Should Be $false
            ($sddl -match "\(A;OICI;FA;;;LA\)") | Should Be $true

            (Test-AclContainsSid -Path $dir -Sid $sid) | Should Be $true
            $verification = Test-AclGrantsFullControl -Path $dir -Sid $sid -RequireInheritance
            $verification.Granted | Should Be $true
            $verification.FolderRights | Should Be $script:FullControl
            $verification.ChildRights | Should Be $script:FullControl
        }
        finally { Remove-TestSandbox -Sandbox $sandbox }
    }

    It "Set-DirectoryAclGrant 写后校验通过，并带出可审计的验证结果" {
        if (-not (Get-Command icacls -ErrorAction SilentlyContinue)) { return }
        $sandbox = New-TestSandbox -Prefix "acl-grant"
        try {
            $dir = Join-Path $sandbox.Root "data"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null

            $grant = Set-DirectoryAclGrant -Path $dir
            $grant.Applied | Should Be $true
            $grant.Verified | Should Be $true
            $grant.Verification.FolderRights | Should Be $script:FullControl
            $grant.Verification.ChildRights | Should Be $script:FullControl
            $grant.Verification.RequireInheritance | Should Be $true
        }
        finally { Remove-TestSandbox -Sandbox $sandbox }
    }

    It "预先存在的 Deny 规则会让 Set-DirectoryAclGrant 拒绝宣告成功" {
        if (-not (Get-Command icacls -ErrorAction SilentlyContinue)) { return }
        $sandbox = New-TestSandbox -Prefix "acl-grant-deny"
        try {
            $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $dir = New-SealedTestDir -Sandbox $sandbox
            # 只拒绝写数据，不拒绝 WRITE_DAC：icacls 本身仍能改 ACL，测试环境可自愈。
            & icacls $dir /deny ("*" + $me + ":(W)") | Out-Null
            $LASTEXITCODE | Should Be 0

            $errorRecord = Get-ThrownError { Set-DirectoryAclGrant -Path $dir }
            ($null -ne $errorRecord) | Should Be $true
            ($errorRecord.Exception.Message -match "校验未通过") | Should Be $true
            ($errorRecord.Exception.Message -match "Deny") | Should Be $true

            # 清掉 Deny 以便沙箱可删除。
            & icacls $dir /remove:d ("*" + $me) | Out-Null
        }
        finally { Remove-TestSandbox -Sandbox $sandbox }
    }

    It "不存在路径时校验返回 false 而不是抛异常" {
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) ("no-such-" + [guid]::NewGuid().ToString("N"))
        $verification = Test-AclGrantsFullControl -Path $missing -Sid "S-1-5-18"
        $verification.Granted | Should Be $false
        ($verification.Reason -match "路径不存在") | Should Be $true
    }
}

Describe "ACL 归一化：真实 ACL 的字段" {

    It "(OI)(CI)F 归一化后带 ContainerInherit 与 ObjectInherit，且不继承自父目录" {
        if (-not (Get-Command icacls -ErrorAction SilentlyContinue)) { return }
        $sandbox = New-TestSandbox -Prefix "acl-normalize"
        try {
            $dir = New-SealedTestDir -Sandbox $sandbox
            & icacls $dir /grant:r "*S-1-5-18:(OI)(CI)F" | Out-Null

            $rules = @(Get-AclNormalizedRules -Path $dir -Sid "S-1-5-18")
            $rules.Count | Should Be 1
            $rules[0].AccessType | Should Be "Allow"
            $rules[0].HasContainer | Should Be $true
            $rules[0].HasObject | Should Be $true
            $rules[0].InheritOnly | Should Be $false
            $rules[0].AppliesToSelf | Should Be $true
            $rules[0].AppliesToChild | Should Be $true
            $rules[0].IsInherited | Should Be $false
            $rules[0].Rights | Should Be $script:FullControl
        }
        finally { Remove-TestSandbox -Sandbox $sandbox }
    }

    It "Deny ACE 的 AccessType 与继承标志被正确区分" {
        if (-not (Get-Command icacls -ErrorAction SilentlyContinue)) { return }
        $sandbox = New-TestSandbox -Prefix "acl-normalize-deny"
        try {
            $dir = New-SealedTestDir -Sandbox $sandbox
            $testSid = if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18') { 'S-1-5-11' } else { 'S-1-5-18' }
            & icacls $dir /remove ("*" + $testSid) | Out-Null
            & icacls $dir /deny ("*" + $testSid + ":(OI)(CI)R") | Out-Null

            $rules = @(Get-AclNormalizedRules -Path $dir -Sid $testSid)
            $rules.Count | Should Be 1
            $rules[0].AccessType | Should Be "Deny"
            $rules[0].HasContainer | Should Be $true
            $rules[0].HasObject | Should Be $true
        }
        finally { Remove-TestSandbox -Sandbox $sandbox }
    }

    It "查询其它 SID 时不会把当前用户的 ACE 算进来" {
        if (-not (Get-Command icacls -ErrorAction SilentlyContinue)) { return }
        $sandbox = New-TestSandbox -Prefix "acl-scope"
        try {
            $dir = New-SealedTestDir -Sandbox $sandbox
            $testSid = if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18') { 'S-1-5-11' } else { 'S-1-5-18' }
            & icacls $dir /remove ("*" + $testSid) | Out-Null
            @(Get-AclNormalizedRules -Path $dir -Sid $testSid).Count | Should Be 0
            $verification = Test-AclGrantsFullControl -Path $dir -Sid $testSid -RequireInheritance
            $verification.Granted | Should Be $false
            ($verification.Reason -match "没有任何 ACE") | Should Be $true
        }
        finally { Remove-TestSandbox -Sandbox $sandbox }
    }
}
