#Requires -Version 5.1
<#
.SYNOPSIS
统一工程验收协议：报告构造、JSON Schema 校验、等级判定与退出码。

.DESCRIPTION
本模块把“跑完了”与“验证通过”分开：
- 每个 check 必须有 PASS / FAIL / SKIP 三态之一；
- SKIP 与 FAIL 必须写明 reason，SKIP 永不计入 PASS；
- achievedLevel 从 L1 起连续判定，L2 未通过时不得声称 L3 达成；
- 报告的权威结构由 schemas/acceptance-report.schema.json 定义，本模块内置一个
  只依赖 PowerShell 的 draft-07 子集校验器，避免 CI 额外依赖 Node/Python。

等级定义：
- L1 文件/模型/源码等产物已生成
- L2 编译或构建成功（生成产物不等于编译成功）
- L3 数值结果与 golden 一致（在容限内）
- L4 多工况与异常场景通过
- L5 实际硬件运行验证（无硬件即 SKIP）
#>

$script:AcceptanceSchemaVersion = "1.0.0"
$script:AcceptanceStatuses = @("PASS", "FAIL", "SKIP")
$script:AcceptanceLevels = @("L1", "L2", "L3", "L4", "L5")
$script:AcceptanceBackends = @("static", "matlab-batch", "matlab-mcp-auto", "matlab-mcp-existing", "matlab-mcp-new")
$script:AcceptanceErrorClasses = @(
    "ENVIRONMENT_ERROR",
    "LICENSE_ERROR",
    "MCP_CONNECTION_ERROR",
    "MATLAB_RUNTIME_ERROR",
    "SIMULATION_ERROR",
    "CODEGEN_ERROR",
    "VALIDATION_ERROR",
    "TIMEOUT"
)

function Get-AcceptanceSchemaVersion {
    <# .SYNOPSIS 返回当前协议版本。 #>
    return $script:AcceptanceSchemaVersion
}

function Get-AcceptanceLevelName {
    <# .SYNOPSIS 返回等级的中文说明，用于报告与文档。 #>
    param([Parameter(Mandatory)][ValidateSet("L1", "L2", "L3", "L4", "L5")][string]$Level)

    switch ($Level) {
        "L1" { return "产物生成" }
        "L2" { return "编译/构建成功" }
        "L3" { return "数值一致" }
        "L4" { return "多工况与异常场景" }
        "L5" { return "实际硬件运行" }
    }
}

function Get-AcceptanceSchemaPath {
    <# .SYNOPSIS 返回仓库内验收 JSON Schema 的绝对路径。 #>
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    return (Join-Path $moduleRoot "schemas\acceptance-report.schema.json")
}

function Get-AcceptanceTimestamp {
    <# .SYNOPSIS 返回带时区的 ISO 8601 时间戳。 #>
    param([datetime]$Value = (Get-Date))
    return $Value.ToString("yyyy-MM-ddTHH:mm:sszzz")
}

function New-AcceptanceTaskId {
    <# .SYNOPSIS 生成可追踪的 taskId。 #>
    param(
        [string]$Prefix = "matlab-acceptance",
        [datetime]$Value = (Get-Date)
    )
    $safePrefix = ($Prefix -replace '[^A-Za-z0-9._-]', '-')
    return "$safePrefix-$($Value.ToString('yyyyMMdd-HHmmss'))"
}

function New-AcceptanceReport {
    <#
    .SYNOPSIS
    创建一份空的验收报告骨架。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][ValidateSet("static", "matlab-batch", "matlab-mcp-auto", "matlab-mcp-existing", "matlab-mcp-new")][string]$Backend,
        [string]$MatlabVersion = "",
        [string]$MatlabRelease = "",
        [object[]]$ToolboxInventory = @(),
        [string]$MatlabExecutable = $null,
        [bool]$MatlabInstalled = $false,
        [string]$MachineClass = $null
    )

    $environment = [ordered]@{
        os                  = "$([System.Environment]::OSVersion.VersionString)"
        hostName            = "$([System.Environment]::MachineName)"
        matlabInstalled     = $MatlabInstalled
        matlabExecutable    = $MatlabExecutable
        powerShellVersion   = "$($PSVersionTable.PSVersion)"
    }
    if ($MachineClass) { $environment["machineClass"] = $MachineClass }

    return [pscustomobject][ordered]@{
        schemaVersion   = $script:AcceptanceSchemaVersion
        taskId          = $TaskId
        backend         = $Backend
        matlabVersion   = $MatlabVersion
        matlabRelease   = $MatlabRelease
        startedAt       = (Get-AcceptanceTimestamp)
        finishedAt      = $null
        environment     = [pscustomobject]$environment
        toolboxInventory = @($ToolboxInventory)
        checks          = @()
        summary         = [pscustomobject][ordered]@{ total = 0; pass = 0; fail = 0; skip = 0 }
        overallStatus   = "SKIP"
        achievedLevel   = "L0"
        limitations     = @()
        unexecuted      = @()
    }
}

function New-AcceptanceCheck {
    <#
    .SYNOPSIS
    构造单个检查项。SKIP / FAIL 缺少 reason 时直接抛错，防止“静默跳过”。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][ValidateSet("L1", "L2", "L3", "L4", "L5")][string]$Level,
        [Parameter(Mandatory)][ValidateSet("PASS", "FAIL", "SKIP")][string]$Status,
        [string]$Command = $null,
        [Nullable[int]]$ExitCode = $null,
        [object]$Metrics = $null,
        [string]$Reason = $null,
        [string]$ErrorClass = $null,
        [string[]]$ArtifactPaths = @(),
        [string]$StartedAt = $null,
        [string]$FinishedAt = $null,
        [Nullable[double]]$DurationSeconds = $null,
        [string]$SourceReport = $null,
        [object]$Retry = $null
    )

    if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "检查项 id 非法（只允许字母、数字、点、下划线、连字符）: '$Id'"
    }
    if ($Status -ne "PASS" -and [string]::IsNullOrWhiteSpace($Reason)) {
        throw "检查项 '$Id' 的状态为 $Status，必须提供 reason，否则无法审计。"
    }
    # 强类型 [string] 参数会把 $null 变成 ""，而给 [string] 变量赋 $null 又会立刻变回 ""。
    # 因此这里在构造对象时用条件表达式归一化，空串一律写成 JSON null。
    if ($ErrorClass -and ($script:AcceptanceErrorClasses -notcontains $ErrorClass)) {
        throw "检查项 '$Id' 使用了未知 errorClass: '$ErrorClass'"
    }
    if ($null -eq $Metrics) { $Metrics = [pscustomobject][ordered]@{} }

    return [pscustomobject][ordered]@{
        id              = $Id
        title           = $Title
        level           = $Level
        status          = $Status
        command         = if ([string]::IsNullOrWhiteSpace($Command)) { $null } else { $Command }
        exitCode        = $ExitCode
        startedAt       = if ([string]::IsNullOrWhiteSpace($StartedAt)) { $null } else { $StartedAt }
        finishedAt      = if ([string]::IsNullOrWhiteSpace($FinishedAt)) { $null } else { $FinishedAt }
        durationSeconds = $DurationSeconds
        metrics         = $Metrics
        reason          = if ([string]::IsNullOrWhiteSpace($Reason)) { $null } else { $Reason }
        errorClass      = if ([string]::IsNullOrWhiteSpace($ErrorClass)) { $null } else { $ErrorClass }
        artifactPaths   = @($ArtifactPaths)
        sourceReport    = if ([string]::IsNullOrWhiteSpace($SourceReport)) { $null } else { $SourceReport }
        retry           = $Retry
    }
}

function Add-AcceptanceCheck {
    <#
    .SYNOPSIS
    向报告追加检查项并返回报告（便于链式调用）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][ValidateSet("L1", "L2", "L3", "L4", "L5")][string]$Level,
        [Parameter(Mandatory)][ValidateSet("PASS", "FAIL", "SKIP")][string]$Status,
        [string]$Command = $null,
        [Nullable[int]]$ExitCode = $null,
        [object]$Metrics = $null,
        [string]$Reason = $null,
        [string]$ErrorClass = $null,
        [string[]]$ArtifactPaths = @(),
        [string]$StartedAt = $null,
        [string]$FinishedAt = $null,
        [Nullable[double]]$DurationSeconds = $null,
        [string]$SourceReport = $null,
        [object]$Retry = $null
    )

    $check = New-AcceptanceCheck -Id $Id -Title $Title -Level $Level -Status $Status `
        -Command $Command -ExitCode $ExitCode -Metrics $Metrics -Reason $Reason `
        -ErrorClass $ErrorClass -ArtifactPaths $ArtifactPaths -StartedAt $StartedAt `
        -FinishedAt $FinishedAt -DurationSeconds $DurationSeconds -SourceReport $SourceReport -Retry $Retry

    $Report.checks = @($Report.checks) + $check
    return $Report
}

function Get-AcceptanceSummary {
    <# .SYNOPSIS 按 checks 统计 PASS/FAIL/SKIP 数量。 #>
    param([Parameter(Mandatory)]$Report)

    $checks = @($Report.checks)
    $pass = @($checks | Where-Object { $_.status -eq "PASS" }).Count
    $fail = @($checks | Where-Object { $_.status -eq "FAIL" }).Count
    $skip = @($checks | Where-Object { $_.status -eq "SKIP" }).Count

    return [pscustomobject][ordered]@{
        total = $checks.Count
        pass  = $pass
        fail  = $fail
        skip  = $skip
    }
}

function Get-AcceptanceOverallStatus {
    <#
    .SYNOPSIS
    整体状态：任一 FAIL 即 FAIL；存在 SKIP 即 SKIP；全部 PASS 才是 PASS。
    .DESCRIPTION
    “配置存在但没验证”这类情况会落到 SKIP，绝不会因为有一条 PASS 就把整体标成 PASS。
    #>
    param([Parameter(Mandatory)]$Report)

    $checks = @($Report.checks)
    if ($checks.Count -eq 0) { return "SKIP" }
    if (@($checks | Where-Object { $_.status -eq "FAIL" }).Count -gt 0) { return "FAIL" }
    if (@($checks | Where-Object { $_.status -eq "SKIP" }).Count -gt 0) { return "SKIP" }
    return "PASS"
}

function Get-AchievedLevel {
    <#
    .SYNOPSIS
    计算连续达成等级：从 L1 起逐级判定，全部 PASS 才进入下一级。
    #>
    param([Parameter(Mandatory)]$Report)

    $checks = @($Report.checks)
    $achieved = "L0"
    foreach ($level in $script:AcceptanceLevels) {
        $levelChecks = @($checks | Where-Object { $_.level -eq $level })
        if ($levelChecks.Count -eq 0) { break }
        $failed = @($levelChecks | Where-Object { $_.status -ne "PASS" }).Count
        if ($failed -gt 0) { break }
        $achieved = $level
    }
    return $achieved
}

function Update-AcceptanceSummary {
    <# .SYNOPSIS 重算 summary / overallStatus / achievedLevel。 #>
    param([Parameter(Mandatory)]$Report)

    $Report.summary = Get-AcceptanceSummary -Report $Report
    $Report.overallStatus = Get-AcceptanceOverallStatus -Report $Report
    $Report.achievedLevel = Get-AchievedLevel -Report $Report
    return $Report
}

function Write-AcceptanceReport {
    <#
    .SYNOPSIS
    收尾并写出验收 JSON（UTF-8 无 BOM，原子替换）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Report.finishedAt)) {
        $Report.finishedAt = Get-AcceptanceTimestamp
    }
    $Report = Update-AcceptanceSummary -Report $Report

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $json = $Report | ConvertTo-Json -Depth 16
    $tempPath = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    [System.IO.File]::WriteAllText($tempPath, $json, (New-Object System.Text.UTF8Encoding($false)))

    # 原子替换：不要用 Remove-Item + Move-Item。
    # "先删再移"在两者之间有一段真空期，删除失败（被安全删除钩子拦截、文件被占用）时
    # 会留下"目标已消失、临时文件还在"的状态。File.Replace 是单步操作，
    # 目标存在时直接换名，失败则原文件保持不动。
    if (Test-Path -LiteralPath $Path) {
        try {
            [System.IO.File]::Replace($tempPath, $Path, $null)
        }
        catch {
            # 跨卷或文件系统不支持 Replace 时退化为覆盖写，仍然不经过删除步骤。
            [System.IO.File]::Copy($tempPath, $Path, $true)
            [System.IO.File]::Delete($tempPath)
        }
    }
    else {
        [System.IO.File]::Move($tempPath, $Path)
    }

    return $Report
}

function Read-AcceptanceJsonFile {
    <#
    .SYNOPSIS
    以 UTF-8 显式读取 JSON 文件。
    .DESCRIPTION
    Windows PowerShell 5.1 的 Get-Content 默认按 ANSI 解码，会把 UTF-8 中文说明变成乱码，
    进而导致 schema / 报告解析失败。这里统一按 UTF-8 读取。
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "文件不存在: $Path" }
    $text = [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false)))
    return ($text | ConvertFrom-Json)
}

function Import-AcceptanceReport {
    <# .SYNOPSIS 从磁盘读取验收 JSON。 #>
    param([Parameter(Mandatory)][string]$Path)
    return (Read-AcceptanceJsonFile -Path $Path)
}

function Merge-AcceptanceReport {
    <#
    .SYNOPSIS
    把子报告（MATLAB 侧产出的 summary.json）合并进父报告。
    .DESCRIPTION
    子检查项冲突时用 "<source>.<id>" 重命名；同时合并 limitations 与 unexecuted。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)]$Child,
        [Parameter(Mandatory)][string]$SourceName
    )

    $existingIds = @($Report.checks | ForEach-Object { $_.id })
    foreach ($check in @($Child.checks)) {
        $id = "$($check.id)"
        if ($existingIds -contains $id) { $id = "$SourceName.$id" }
        $Report.checks = @($Report.checks) + [pscustomobject]$check.PSObject.Copy()
        $Report.checks[-1].id = $id
        $Report.checks[-1].sourceReport = $SourceName
        $existingIds += $id
    }

    if ($Child.PSObject.Properties.Name -contains "limitations") {
        $Report.limitations = @($Report.limitations) + @($Child.limitations | Where-Object { $_ })
    }
    if ($Child.PSObject.Properties.Name -contains "unexecuted") {
        $Report.unexecuted = @($Report.unexecuted) + @($Child.unexecuted)
    }

    # 工具箱清单只有真正跑过 MATLAB 的那一层才拿得到。父报告是空的就继承子报告，
    # 否则"报告里有 toolboxInventory 字段"就只是一句空话（空数组也满足 schema）。
    $parentInventory = @($Report.toolboxInventory | Where-Object { $_ })
    $childInventory = @($Child.toolboxInventory | Where-Object { $_ })
    if ($parentInventory.Count -eq 0 -and $childInventory.Count -gt 0) {
        $Report.toolboxInventory = $childInventory
    }

    return Update-AcceptanceSummary -Report $Report
}

function Get-AcceptanceScopeDefinition {
    <#
    .SYNOPSIS
    返回验收范围（capability scope）的定义：哪些检查是必选，哪些是可选。
    .DESCRIPTION
    为什么需要范围：
        整套六阶段验收包含"基础 MATLAB 数值"到"硬件在环"的能力，跨度很大。
        如果拿"整体状态"当 CI 门禁，只要有一条可选能力（例如 Coder 未授权、
        没有 STM32 板卡）是 SKIP，CI 就永远红；反过来，为了让 CI 变绿去删掉
        那些 SKIP 又是在造假。

        正确的做法是：范围声明"这一次要验证哪些能力"，门禁只看这些必选检查；
        可选能力的 SKIP 全部保留在完整报告里，谁都能看到"没验证什么"。

    未被任何范围收录的检查仍然会进入完整报告，不影响任何范围判定。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("core", "simulink", "coder", "full")]
        [string]$Scope
    )

    # core：MATLAB 能启动、能枚举产品、能算出正确数值、能导出产物。
    $coreRequired = @(
        "matlab.executable"
        "inventory.products"
        "inventory.gated-license"
        "skill.numeric-fit"
        "skill.figure-export"
        "skill.data-export"
    )

    switch ($Scope) {
        "core" {
            return [pscustomobject]@{
                name        = "core"
                title       = "Core MATLAB：运行时、产品清点与数值/导出能力"
                required    = $coreRequired
                optional    = @("*")
                description = "只要求 MATLAB 自身可用；Simulink / Coder / 硬件相关检查允许 SKIP 并保留在报告中。"
            }
        }
        "simulink" {
            return [pscustomobject]@{
                name        = "simulink"
                title       = "Simulink：模型加载、更新、仿真数值与多工况"
                required    = $coreRequired + @(
                    "skill.simulink-sim"
                    "simulink.model-artifact"
                    "simulink.model-update"
                    "simulink.simulation"
                    "simulink.parameter-sweep"
                )
                optional    = @("simulink.codegen-build", "codegen.*", "compiler.*", "feature.*")
                description = "要求 Simulink 建模与仿真确实跑通；Simulink Coder 构建、MATLAB Coder、硬件不在必选范围内。"
            }
        }
        "coder" {
            return [pscustomobject]@{
                name        = "coder"
                title       = "Coder：C 代码生成、真实编译与数值一致性"
                required    = $coreRequired + @(
                    "codegen.generate"
                    "codegen.compile"
                    "compiler.mex-build"
                    "compiler.numeric"
                    "compiler.robustness"
                )
                optional    = @("simulink.codegen-build", "simulink.*", "feature.*")
                description = "要求 MATLAB Coder 与 C 编译器真实可用；Simulink 与硬件相关检查允许 SKIP。"
            }
        }
        "full" {
            return [pscustomobject]@{
                name        = "full"
                title       = "Full Stack：全部工程能力，含 Simulink Coder 与硬件在环"
                required    = $coreRequired + @(
                    "skill.simulink-sim"
                    "simulink.model-artifact"
                    "simulink.model-update"
                    "simulink.simulation"
                    "simulink.parameter-sweep"
                    "simulink.codegen-build"
                    "codegen.generate"
                    "codegen.compile"
                    "compiler.mex-build"
                    "compiler.numeric"
                    "compiler.robustness"
                    "feature.direct-import"
                    "feature.blocksets"
                    "feature.agentic"
                    "embedded.hardware-in-loop"
                )
                optional    = @()
                description = "全部必选。硬件在环与 STM32 下载回读只能由层 C 的受控 runner 满足，因此公开 CI 上本范围必然不是 PASS。"
            }
        }
    }
}

function Test-AcceptanceCheckIdMatch {
    <# .SYNOPSIS 检查 id 是否命中给定模式（支持 * 通配）。 #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Pattern
    )
    foreach ($item in $Pattern) {
        if ($Id -like $item) { return $true }
    }
    return $false
}

function Get-AcceptanceScopeStatus {
    <#
    .SYNOPSIS
    按范围计算门禁状态：PASS / FAIL / SKIP，以及为什么。
    .DESCRIPTION
    规则（刻意保守）：
      - 任一必选检查 FAIL            -> FAIL
      - 任一必选检查 SKIP            -> SKIP
      - 任一必选检查在报告里不存在    -> SKIP（"未产出"不等于"通过"）
      - 全部必选检查 PASS            -> PASS
    可选检查的 SKIP 只记录、不影响门禁状态。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)]
        [ValidateSet("core", "simulink", "coder", "full")]
        [string]$Scope
    )

    $definition = Get-AcceptanceScopeDefinition -Scope $Scope
    $checks = @($Report.checks)

    $requiredResults = @()
    $missing = @()
    $failed = @()
    $skipped = @()

    foreach ($requiredId in $definition.required) {
        $matched = @($checks | Where-Object { $_.id -eq $requiredId })
        if ($matched.Count -eq 0) {
            $missing += $requiredId
            $requiredResults += [pscustomobject][ordered]@{
                id = $requiredId; status = "MISSING"; reason = "报告中没有该检查项"
            }
            continue
        }
        $check = $matched[0]
        $requiredResults += [pscustomobject][ordered]@{
            id = $requiredId
            status = "$($check.status)"
            reason = $(if ($check.reason) { "$($check.reason)" } else { $null })
        }
        switch ("$($check.status)") {
            "FAIL" { $failed += $requiredId }
            "SKIP" { $skipped += $requiredId }
        }
    }

    $optionalSkipped = @(
        $checks |
            Where-Object { -not (Test-AcceptanceCheckIdMatch -Id "$($_.id)" -Pattern $definition.required) } |
            Where-Object { $_.status -eq "SKIP" } |
            ForEach-Object { "$($_.id)" }
    )

    $status = "PASS"
    $reason = "所有必选检查均已 PASS"
    if ($failed.Count -gt 0) {
        $status = "FAIL"
        $reason = "必选检查失败：" + ($failed -join ", ")
    }
    elseif ($missing.Count -gt 0) {
        $status = "SKIP"
        $reason = "必选检查未产出（未执行）：" + ($missing -join ", ")
    }
    elseif ($skipped.Count -gt 0) {
        $status = "SKIP"
        $reason = "必选检查被跳过（未验证）：" + ($skipped -join ", ")
    }

    return [pscustomobject][ordered]@{
        name            = $definition.name
        title           = $definition.title
        description     = $definition.description
        status          = $status
        reason          = $reason
        requiredIds     = $definition.required
        optionalIds     = $definition.optional
        requiredResults = $requiredResults
        failedRequired  = $failed
        skippedRequired = $skipped
        missingRequired = $missing
        optionalSkipped = $optionalSkipped
        optionalSkippedCount = $optionalSkipped.Count
    }
}

function Get-AcceptanceScopeEvaluations {
    <# .SYNOPSIS 对四个范围全部求值，便于在报告里一次性展示"哪些范围能过"。 #>
    param([Parameter(Mandatory)]$Report)
    return @(
        foreach ($scopeName in @("core", "simulink", "coder", "full")) {
            Get-AcceptanceScopeStatus -Report $Report -Scope $scopeName
        }
    )
}

function Get-AcceptanceScopeExitCode {
    <# .SYNOPSIS 范围门禁退出码：0=PASS，1=FAIL，3=SKIP（未验证）。 #>
    param([Parameter(Mandatory)]$ScopeStatus)
    switch ("$($ScopeStatus.status)") {
        "PASS" { return 0 }
        "FAIL" { return 1 }
        default { return 3 }
    }
}

function Get-AcceptanceExitCode {
    <# .SYNOPSIS 验收退出码：0=PASS，1=FAIL，3=全部 SKIP。 #>
    param([Parameter(Mandatory)]$Report)
    switch (Get-AcceptanceOverallStatus -Report $Report) {
        "PASS" { return 0 }
        "FAIL" { return 1 }
        default { return 3 }
    }
}

#region JSON Schema（draft-07 子集）校验

function Get-JsonValueKind {
    param($Value)

    if ($null -eq $Value) { return "null" }
    if ($Value -is [bool]) { return "boolean" }
    if ($Value -is [string]) { return "string" }
    if ($Value -is [System.Collections.IDictionary]) { return "object" }
    if ($Value -is [System.Management.Automation.PSCustomObject]) { return "object" }
    if ($Value -is [System.Collections.IEnumerable]) { return "array" }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal] -or
        $Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte] -or
        $Value -is [int64] -or $Value -is [uint32] -or $Value -is [uint64]) {
        return "number"
    }
    return "unknown"
}

function Find-JsonDictionaryKey {
    <# .SYNOPSIS 在字典中按大小写敏感语义查找真实键名。 #>
    param($Dictionary, [string]$Name)
    if ($null -eq $Dictionary) { return $null }
    foreach ($key in $Dictionary.Keys) {
        if ([string]$key -ceq $Name) { return $key }
    }
    return $null
}

function Test-JsonObjectHasProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return ($null -ne (Find-JsonDictionaryKey -Dictionary $Object -Name $Name)) }
    return [bool]($Object.PSObject.Properties[$Name])
}

function Get-JsonObjectProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $value = $null
    if ($Object -is [System.Collections.IDictionary]) {
        $key = Find-JsonDictionaryKey -Dictionary $Object -Name $Name
        if ($null -eq $key) { return $null }
        $value = $Object[$key]
    }
    else {
        $property = $Object.PSObject.Properties[$Name]
        if (-not $property) { return $null }
        $value = $property.Value
    }
    # 关键：函数 return 会把数组展开，导致单元素数组变标量、空数组变 $null。
    # 数组必须用 ",$value" 阻止展开，否则 schema 校验会把 [] 误判为 null。
    if ($null -ne $value -and $value -isnot [string] -and $value -is [System.Collections.IEnumerable]) {
        return ,$value
    }
    return $value
}

function Get-JsonObjectPropertyNames {
    param($Object)
    if ($null -eq $Object) { return @() }
    if ($Object -is [System.Collections.IDictionary]) { return @($Object.Keys) }
    return @($Object.PSObject.Properties | ForEach-Object { $_.Name })
}

function Resolve-JsonSchemaRef {
    param($RootSchema, [string]$Ref)
    if ($Ref -notmatch '^#/(.+)$') { return $null }
    $current = $RootSchema
    foreach ($segment in ($Matches[1] -split '/')) {
        $name = $segment -replace '~1', '/' -replace '~0', '~'
        if (-not (Test-JsonObjectHasProperty -Object $current -Name $name)) { return $null }
        $current = Get-JsonObjectProperty -Object $current -Name $name
    }
    return $current
}

function Test-JsonAgainstSchema {
    <#
    .SYNOPSIS
    用内置的 draft-07 子集校验器校验一个 JSON 实例。
    .DESCRIPTION
    支持关键字：type / required / properties / additionalProperties / items / minItems /
    enum / const / minLength / pattern / minimum / maximum / format(date-time) / $ref(本地)。
    返回 @{ Valid = bool; Errors = string[] }。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$Instance,
        [Parameter(Mandatory)]$Schema,
        [string]$Path = "$"
    )

    $script:SchemaErrors = New-Object System.Collections.Generic.List[string]
    Invoke-JsonSchemaNode -Instance $Instance -Schema $Schema -Path $Path -RootSchema $Schema -Depth 0

    return [pscustomobject][ordered]@{
        Valid  = ($script:SchemaErrors.Count -eq 0)
        Errors = @($script:SchemaErrors.ToArray())
    }
}

function Invoke-JsonSchemaNode {
    param($Instance, $Schema, [string]$Path, $RootSchema, [int]$Depth)

    if ($null -eq $Schema) { return }
    if ($Depth -gt 40) {
        $script:SchemaErrors.Add("$Path : schema 递归层级过深")
        return
    }

    if (Test-JsonObjectHasProperty -Object $Schema -Name '$ref') {
        $resolved = Resolve-JsonSchemaRef -RootSchema $RootSchema -Ref (Get-JsonObjectProperty -Object $Schema -Name '$ref')
        if ($null -eq $resolved) {
            $script:SchemaErrors.Add("$Path : 无法解析 `$ref '$((Get-JsonObjectProperty -Object $Schema -Name '$ref'))'")
            return
        }
        Invoke-JsonSchemaNode -Instance $Instance -Schema $resolved -Path $Path -RootSchema $RootSchema -Depth ($Depth + 1)
        return
    }

    $kind = Get-JsonValueKind -Value $Instance

    if (Test-JsonObjectHasProperty -Object $Schema -Name 'type') {
        $typeValue = Get-JsonObjectProperty -Object $Schema -Name 'type'
        $expected = @()
        if ($null -ne $typeValue) { $expected = @($typeValue) }
        $matched = $false
        foreach ($typeName in $expected) {
            if ($typeName -eq $kind) { $matched = $true; break }
            if ($typeName -eq "integer" -and $kind -eq "number") {
                if ([double]$Instance -eq [math]::Floor([double]$Instance)) { $matched = $true; break }
            }
        }
        if (-not $matched) {
            $script:SchemaErrors.Add("$Path : 类型应为 $($expected -join '|')，实际为 $kind")
            return
        }
    }

    if (Test-JsonObjectHasProperty -Object $Schema -Name 'enum') {
        # 直接遍历 IList，避免 @($null) 把枚举里的 null 丢掉。
        $rawAllowed = Get-JsonObjectProperty -Object $Schema -Name 'enum'
        $allowedList = $rawAllowed -as [System.Collections.IList]
        $allowedText = New-Object System.Collections.Generic.List[string]
        $hit = $false
        if ($null -ne $allowedList) {
            foreach ($candidate in $allowedList) {
                if ($null -eq $candidate) {
                    $allowedText.Add("null")
                    if ($null -eq $Instance) { $hit = $true }
                    continue
                }
                $allowedText.Add("$candidate")
                if ($null -ne $Instance -and "$candidate" -ceq "$Instance") { $hit = $true }
            }
        }
        else {
            if ($null -eq $rawAllowed) {
                $allowedText.Add("null")
                if ($null -eq $Instance) { $hit = $true }
            }
            elseif ("$rawAllowed" -ceq "$Instance") {
                $allowedText.Add("$rawAllowed")
                $hit = $true
            }
        }
        if (-not $hit) {
            $script:SchemaErrors.Add("$Path : 值 '$Instance' 不在枚举 [$($allowedText -join ', ')] 中")
        }
    }

    if (Test-JsonObjectHasProperty -Object $Schema -Name 'const') {
        $const = Get-JsonObjectProperty -Object $Schema -Name 'const'
        if ("$const" -cne "$Instance") {
            $script:SchemaErrors.Add("$Path : 值应为常量 '$const'")
        }
    }

    if ($kind -eq "string") {
        if (Test-JsonObjectHasProperty -Object $Schema -Name 'minLength') {
            $minLength = [int](Get-JsonObjectProperty -Object $Schema -Name 'minLength')
            if ($Instance.Length -lt $minLength) {
                $script:SchemaErrors.Add("$Path : 字符串长度 $($Instance.Length) 小于最小长度 $minLength")
            }
        }
        if (Test-JsonObjectHasProperty -Object $Schema -Name 'pattern') {
            $pattern = [string](Get-JsonObjectProperty -Object $Schema -Name 'pattern')
            if (-not [regex]::IsMatch($Instance, $pattern)) {
                $script:SchemaErrors.Add("$Path : 字符串 '$Instance' 不匹配模式 $pattern")
            }
        }
        if (Test-JsonObjectHasProperty -Object $Schema -Name 'format') {
            $format = [string](Get-JsonObjectProperty -Object $Schema -Name 'format')
            if ($format -eq "date-time" -and -not [regex]::IsMatch($Instance, '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$')) {
                $script:SchemaErrors.Add("$Path : '$Instance' 不是合法的 date-time")
            }
        }
    }

    if ($kind -eq "number") {
        if (Test-JsonObjectHasProperty -Object $Schema -Name 'minimum') {
            $minimum = [double](Get-JsonObjectProperty -Object $Schema -Name 'minimum')
            if ([double]$Instance -lt $minimum) {
                $script:SchemaErrors.Add("$Path : 数值 $Instance 小于最小值 $minimum")
            }
        }
        if (Test-JsonObjectHasProperty -Object $Schema -Name 'maximum') {
            $maximum = [double](Get-JsonObjectProperty -Object $Schema -Name 'maximum')
            if ([double]$Instance -gt $maximum) {
                $script:SchemaErrors.Add("$Path : 数值 $Instance 大于最大值 $maximum")
            }
        }
    }

    if ($kind -eq "array") {
        $items = @($Instance)
        if (Test-JsonObjectHasProperty -Object $Schema -Name 'minItems') {
            $minItems = [int](Get-JsonObjectProperty -Object $Schema -Name 'minItems')
            if ($items.Count -lt $minItems) {
                $script:SchemaErrors.Add("$Path : 数组长度 $($items.Count) 小于 minItems $minItems")
            }
        }
        if (Test-JsonObjectHasProperty -Object $Schema -Name 'items') {
            $itemSchema = Get-JsonObjectProperty -Object $Schema -Name 'items'
            for ($i = 0; $i -lt $items.Count; $i++) {
                Invoke-JsonSchemaNode -Instance $items[$i] -Schema $itemSchema -Path "$Path[$i]" -RootSchema $RootSchema -Depth ($Depth + 1)
            }
        }
    }

    if ($kind -eq "object") {
        if (Test-JsonObjectHasProperty -Object $Schema -Name 'required') {
            $requiredValue = Get-JsonObjectProperty -Object $Schema -Name 'required'
            $requiredNames = @()
            if ($null -ne $requiredValue) { $requiredNames = @($requiredValue) }
            foreach ($requiredName in $requiredNames) {
                if (-not (Test-JsonObjectHasProperty -Object $Instance -Name $requiredName)) {
                    $script:SchemaErrors.Add("$Path : 缺少必需字段 '$requiredName'")
                }
            }
        }
        $properties = Get-JsonObjectProperty -Object $Schema -Name 'properties'
        $knownNames = @()
        if ($properties) {
            foreach ($name in (Get-JsonObjectPropertyNames -Object $properties)) {
                $knownNames += $name
                if (Test-JsonObjectHasProperty -Object $Instance -Name $name) {
                    $childSchema = Get-JsonObjectProperty -Object $properties -Name $name
                    $childValue = Get-JsonObjectProperty -Object $Instance -Name $name
                    Invoke-JsonSchemaNode -Instance $childValue -Schema $childSchema -Path "$Path.$name" -RootSchema $RootSchema -Depth ($Depth + 1)
                }
            }
        }
        if (Test-JsonObjectHasProperty -Object $Schema -Name 'additionalProperties') {
            $additional = Get-JsonObjectProperty -Object $Schema -Name 'additionalProperties'
            if ($additional -is [bool] -and $additional -eq $false) {
                foreach ($actualName in (Get-JsonObjectPropertyNames -Object $Instance)) {
                    if ($knownNames -notcontains $actualName) {
                        $script:SchemaErrors.Add("$Path : 不允许的额外字段 '$actualName'")
                    }
                }
            }
        }
    }
}

#endregion

function Test-AcceptanceReport {
    <#
    .SYNOPSIS
    校验验收报告：先过 JSON Schema，再检查协议语义（含 SKIP 不得计为 PASS）。
    .OUTPUTS
    [pscustomobject] @{ Valid; Errors }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Report,
        [string]$SchemaPath = (Get-AcceptanceSchemaPath),
        [switch]$ThrowOnError
    )

    $errors = New-Object System.Collections.Generic.List[string]

    if (-not (Test-Path -LiteralPath $SchemaPath)) {
        $errors.Add("Schema 文件不存在: $SchemaPath")
    }
    else {
        $schema = $null
        try {
            $schema = Read-AcceptanceJsonFile -Path $SchemaPath
        }
        catch {
            $errors.Add("Schema 无法解析: $($_.Exception.Message)")
        }
        if ($null -ne $schema) {
            $instance = $Report
            if ($Report -is [string]) {
                $instance = $Report | ConvertFrom-Json
            }
            try {
                $schemaResult = Test-JsonAgainstSchema -Instance $instance -Schema $schema
                foreach ($schemaError in $schemaResult.Errors) { $errors.Add("schema: $schemaError") }
            }
            catch {
                # Schema 校验本身出错必须视为校验失败，不能静默放行。
                $errors.Add("Schema 校验执行失败: $($_.Exception.Message)")
            }
        }
    }

    $instance = $Report
    if ($Report -is [string]) { $instance = $Report | ConvertFrom-Json }

    $checks = @()
    if (Test-JsonObjectHasProperty -Object $instance -Name "checks") {
        $checksValue = Get-JsonObjectProperty -Object $instance -Name "checks"
        if ($null -ne $checksValue) { $checks = @($checksValue) }
    }
    if ($checks.Count -eq 0) { $errors.Add("semantic: checks 为空，无法证明任何能力") }

    $seenIds = @{}
    foreach ($check in $checks) {
        $id = "$(Get-JsonObjectProperty -Object $check -Name 'id')"
        $status = "$(Get-JsonObjectProperty -Object $check -Name 'status')"
        $reason = Get-JsonObjectProperty -Object $check -Name 'reason'
        if ($seenIds.ContainsKey($id)) {
            $errors.Add("semantic: 检查项 id 重复 '$id'")
        }
        else {
            $seenIds[$id] = $true
        }
        if ($status -eq "SKIP" -and [string]::IsNullOrWhiteSpace([string]$reason)) {
            $errors.Add("semantic: '$id' 为 SKIP 但缺少 reason（跳过必须可审计）")
        }
        if ($status -eq "FAIL" -and [string]::IsNullOrWhiteSpace([string]$reason)) {
            $errors.Add("semantic: '$id' 为 FAIL 但缺少 reason")
        }
    }

    if ($checks.Count -gt 0) {
        $pass = @($checks | Where-Object { "$(Get-JsonObjectProperty -Object $_ -Name 'status')" -eq "PASS" }).Count
        $fail = @($checks | Where-Object { "$(Get-JsonObjectProperty -Object $_ -Name 'status')" -eq "FAIL" }).Count
        $skip = @($checks | Where-Object { "$(Get-JsonObjectProperty -Object $_ -Name 'status')" -eq "SKIP" }).Count

        $summary = Get-JsonObjectProperty -Object $instance -Name "summary"
        if ($summary) {
            foreach ($pair in @(@("total", $checks.Count), @("pass", $pass), @("fail", $fail), @("skip", $skip))) {
                $actual = Get-JsonObjectProperty -Object $summary -Name $pair[0]
                if ($null -ne $actual -and [int]$actual -ne [int]$pair[1]) {
                    $errors.Add("semantic: summary.$($pair[0])=$actual 与 checks 实际值 $($pair[1]) 不一致")
                }
            }
        }

        $expectedOverall = "PASS"
        if ($fail -gt 0) { $expectedOverall = "FAIL" }
        elseif ($skip -gt 0) { $expectedOverall = "SKIP" }
        $overall = "$(Get-JsonObjectProperty -Object $instance -Name 'overallStatus')"
        if ($overall -ne $expectedOverall) {
            $errors.Add("semantic: overallStatus=$overall 与 checks 推导值 $expectedOverall 不一致")
        }

        $expectedLevel = "L0"
        foreach ($level in $script:AcceptanceLevels) {
            $levelChecks = @($checks | Where-Object { "$(Get-JsonObjectProperty -Object $_ -Name 'level')" -eq $level })
            if ($levelChecks.Count -eq 0) { break }
            $notPassed = @($levelChecks | Where-Object { "$(Get-JsonObjectProperty -Object $_ -Name 'status')" -ne "PASS" }).Count
            if ($notPassed -gt 0) { break }
            $expectedLevel = $level
        }
        $achieved = "$(Get-JsonObjectProperty -Object $instance -Name 'achievedLevel')"
        if ($achieved -ne $expectedLevel) {
            $errors.Add("semantic: achievedLevel=$achieved 与连续判定值 $expectedLevel 不一致")
        }
    }

    $result = [pscustomobject][ordered]@{
        Valid  = ($errors.Count -eq 0)
        Errors = @($errors.ToArray())
    }
    if ($ThrowOnError -and -not $result.Valid) {
        throw ("验收报告校验失败:`n  - " + ($result.Errors -join "`n  - "))
    }
    return $result
}

function ConvertTo-AcceptanceStatus {
    <#
    .SYNOPSIS
    把探测脚本的布尔/字符串状态映射为 PASS/FAIL/SKIP。
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$Value,
        [string]$SkipReason = "上游条件不满足，未执行"
    )
    if ($null -eq $Value) { return "SKIP" }
    if ($Value -is [bool]) {
        if ($Value) { return "PASS" }
        return "FAIL"
    }
    switch ("$Value".ToLowerInvariant()) {
        "pass" { return "PASS" }
        "true" { return "PASS" }
        "ready" { return "PASS" }
        "installed" { return "PASS" }
        "present" { return "PASS" }
        "skip" { return "SKIP" }
        "not_executed" { return "SKIP" }
        "missing" { return "SKIP" }
        "missing_prerequisites" { return "SKIP" }
        "not_detected" { return "SKIP" }
        "not_installed" { return "SKIP" }
        "unavailable" { return "SKIP" }
        "fail" { return "FAIL" }
        "false" { return "FAIL" }
        "error" { return "FAIL" }
        default { return "FAIL" }
    }
}

Export-ModuleMember -Function *
