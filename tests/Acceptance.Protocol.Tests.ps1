<#
.SYNOPSIS
验收协议测试：JSON Schema、语义约束、等级判定、合并与退出码。

.DESCRIPTION
不依赖 MATLAB / MCP / 网络，可在免费 CI 上完整运行。
#>

. (Join-Path $PSScriptRoot "helpers\Assertions.ps1")
$helpers = Join-Path $PSScriptRoot "helpers\TestSandbox.ps1"
. $helpers

$repoRoot = Get-TestRepositoryRoot
Import-TestModule -Name "MatlabAgentSkills.Acceptance.psm1" -RepositoryRoot $repoRoot | Out-Null

function New-ValidReport {
    param([string]$TaskId = "unit-report")
    $report = New-AcceptanceReport -TaskId $TaskId -Backend "static"
    $report = Add-AcceptanceCheck -Report $report -Id "unit.pass" -Title "示例通过项" -Level "L2" -Status "PASS" `
        -Metrics ([ordered]@{ sampleCount = 3 })
    return (Update-AcceptanceSummary -Report $report)
}

Describe "验收 JSON Schema" {
    It "schema 文件存在且是合法 JSON" {
        $schemaPath = Get-AcceptanceSchemaPath
        (Test-Path -LiteralPath $schemaPath) | Should Be $true
        $schema = Read-AcceptanceJsonFile -Path $schemaPath
        $schema.title | Should Match "Acceptance"
        ($schema.required -contains "schemaVersion") | Should Be $true
        ($schema.required -contains "overallStatus") | Should Be $true
    }

    It "schema 覆盖任务要求的全部顶层字段" {
        $schema = Read-AcceptanceJsonFile -Path (Get-AcceptanceSchemaPath)
        foreach ($field in @("schemaVersion", "taskId", "backend", "matlabVersion", "toolboxInventory",
                "startedAt", "finishedAt", "checks", "overallStatus")) {
            ($schema.required -contains $field) | Should Be $true
        }
        $checkRequired = $schema.definitions.check.required
        foreach ($field in @("status", "command", "exitCode", "metrics", "reason", "artifactPaths")) {
            ($checkRequired -contains $field) | Should Be $true
        }
    }

    It "新建报告能通过 schema 与语义校验" {
        $report = New-ValidReport
        $result = Test-AcceptanceReport -Report $report
        ($result.Errors -join " | ") | Should Be ""
        $result.Valid | Should Be $true
    }

    It "非法 backend 会被 schema 拒绝" {
        $report = New-ValidReport
        $report.backend = "octave"
        $result = Test-AcceptanceReport -Report $report
        $result.Valid | Should Be $false
        ($result.Errors -join " ") | Should Match "backend"
    }

    It "未知 errorClass 会被 schema 拒绝" {
        $report = New-ValidReport
        $report.checks[0].errorClass = "NOT_A_CLASS"
        $result = Test-AcceptanceReport -Report $report
        $result.Valid | Should Be $false
        ($result.Errors -join " ") | Should Match "errorClass"
    }

    It "缺少必需字段会被 schema 拒绝" {
        $report = New-ValidReport
        $report.PSObject.Properties.Remove("taskId")
        $result = Test-AcceptanceReport -Report $report
        $result.Valid | Should Be $false
        ($result.Errors -join " ") | Should Match "taskId"
    }

    It "metrics 类型错误会被 schema 拒绝" {
        $report = New-ValidReport
        $report.checks[0].metrics = "not-an-object"
        $result = Test-AcceptanceReport -Report $report
        $result.Valid | Should Be $false
        ($result.Errors -join " ") | Should Match "metrics"
    }
}

Describe "SKIP 语义" {
    It "SKIP 缺少 reason 时构造检查项直接报错" {
        $report = New-AcceptanceReport -TaskId "skip-guard" -Backend "static"
        (Test-Throws { Add-AcceptanceCheck -Report $report -Id "a.skip" -Title "t" -Level "L1" -Status "SKIP" }) | Should Be $true
    }

    It "FAIL 缺少 reason 时构造检查项直接报错" {
        $report = New-AcceptanceReport -TaskId "fail-guard" -Backend "static"
        (Test-Throws { Add-AcceptanceCheck -Report $report -Id "a.fail" -Title "t" -Level "L1" -Status "FAIL" }) | Should Be $true
    }

    It "校验器会拦截被外部改坏的 SKIP（reason 为空）" {
        $report = New-ValidReport
        $report = Add-AcceptanceCheck -Report $report -Id "a.skip" -Title "t" -Level "L1" -Status "SKIP" -Reason "因为缺许可证"
        $report = Update-AcceptanceSummary -Report $report
        $report.checks[1].reason = $null
        $result = Test-AcceptanceReport -Report $report
        $result.Valid | Should Be $false
        ($result.Errors -join " ") | Should Match "SKIP"
    }

    It "存在 SKIP 时整体状态不得为 PASS" {
        $report = New-ValidReport
        $report = Add-AcceptanceCheck -Report $report -Id "a.skip" -Title "t" -Level "L1" -Status "SKIP" -Reason "缺编译器"
        $report = Update-AcceptanceSummary -Report $report
        $report.overallStatus | Should Be "SKIP"
        (Get-AcceptanceExitCode -Report $report) | Should Be 3
    }

    It "全部 PASS 时整体为 PASS 且退出码 0" {
        $report = New-ValidReport
        $report.overallStatus | Should Be "PASS"
        (Get-AcceptanceExitCode -Report $report) | Should Be 0
    }

    It "任一 FAIL 时整体为 FAIL 且退出码 1" {
        $report = New-ValidReport
        $report = Add-AcceptanceCheck -Report $report -Id "a.fail" -Title "t" -Level "L1" -Status "FAIL" -Reason "数值不一致"
        $report = Update-AcceptanceSummary -Report $report
        $report.overallStatus | Should Be "FAIL"
        (Get-AcceptanceExitCode -Report $report) | Should Be 1
    }
}

Describe "五级验收与连续判定" {
    It "L1 未通过时 achievedLevel 停在 L0" {
        $report = New-AcceptanceReport -TaskId "level-0" -Backend "static"
        $report = Add-AcceptanceCheck -Report $report -Id "l1" -Title "t" -Level "L1" -Status "FAIL" -Reason "文件未生成"
        $report = Add-AcceptanceCheck -Report $report -Id "l2" -Title "t" -Level "L2" -Status "PASS"
        $report = Update-AcceptanceSummary -Report $report
        $report.achievedLevel | Should Be "L0"
    }

    It "L2 为 SKIP 时即使 L3 通过也只能到 L1" {
        $report = New-AcceptanceReport -TaskId "level-1" -Backend "static"
        $report = Add-AcceptanceCheck -Report $report -Id "l1" -Title "t" -Level "L1" -Status "PASS"
        $report = Add-AcceptanceCheck -Report $report -Id "l2" -Title "t" -Level "L2" -Status "SKIP" -Reason "无编译器"
        $report = Add-AcceptanceCheck -Report $report -Id "l3" -Title "t" -Level "L3" -Status "PASS"
        $report = Update-AcceptanceSummary -Report $report
        $report.achievedLevel | Should Be "L1"
    }

    It "L1~L3 全通过时 achievedLevel 为 L3" {
        $report = New-AcceptanceReport -TaskId "level-3" -Backend "static"
        foreach ($level in @("L1", "L2", "L3")) {
            $report = Add-AcceptanceCheck -Report $report -Id "check.$level" -Title "t" -Level $level -Status "PASS"
        }
        $report = Update-AcceptanceSummary -Report $report
        $report.achievedLevel | Should Be "L3"
    }
}

Describe "报告落盘与合并" {
    It "写入后可按 UTF-8 读回并通过校验" {
        $sandbox = New-TestSandbox
        try {
            $report = New-ValidReport -TaskId "write-read"
            $path = Join-Path $sandbox.Validation "acceptance_report.json"
            $written = Write-AcceptanceReport -Report $report -Path $path
            (Test-Path -LiteralPath $path) | Should Be $true
            $written.finishedAt | Should Not Be $null

            $bytes = [System.IO.File]::ReadAllBytes($path)
            $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
            # 标准 JSON 不带 BOM，避免 Python/jq 等工具解析失败。
            $hasBom | Should Be $false

            $back = Import-AcceptanceReport -Path $path
            (Test-AcceptanceReport -Report $back).Valid | Should Be $true
        }
        finally { Remove-TestSandbox $sandbox }
    }

    It "覆盖写同一路径是原子替换：不残留临时文件，旧内容被替换" {
        # 旧实现是 Remove-Item + Move-Item。两者之间有一段时间目标文件不存在；
        # 若删除被安全钩子拦截或文件被占用，就会留下"目标消失、临时文件还在"的状态。
        $sandbox = New-TestSandbox -Prefix "acceptance-atomic"
        try {
            $path = Join-Path $sandbox.Validation "atomic.json"
            $first = New-ValidReport -TaskId "atomic-first"
            Write-AcceptanceReport -Report $first -Path $path | Out-Null
            (Test-Path -LiteralPath $path) | Should Be $true

            $second = New-ValidReport -TaskId "atomic-second"
            Write-AcceptanceReport -Report $second -Path $path | Out-Null

            $reloaded = Import-AcceptanceReport -Path $path
            "$($reloaded.taskId)" | Should Be "atomic-second"
            @(Get-ChildItem -LiteralPath $sandbox.Validation -Filter "*.tmp-*" -File).Count | Should Be 0
        }
        finally {
            Remove-TestSandbox -Sandbox $sandbox
        }
    }

    It "合并子报告时保留全部检查并处理 id 冲突" {
        $parent = New-ValidReport -TaskId "parent"
        $child = New-AcceptanceReport -TaskId "child" -Backend "matlab-batch"
        $child = Add-AcceptanceCheck -Report $child -Id "unit.pass" -Title "重复 id" -Level "L1" -Status "PASS"
        $child = Add-AcceptanceCheck -Report $child -Id "codegen.compile" -Title "编译" -Level "L2" -Status "SKIP" -Reason "无编译器"
        $child = Update-AcceptanceSummary -Report $child
        $child.limitations = @("子报告限制")

        $merged = Merge-AcceptanceReport -Report $parent -Child $child -SourceName "child"
        @($merged.checks).Count | Should Be 3
        (@($merged.checks | ForEach-Object { $_.id }) -contains "child.unit.pass") | Should Be $true
        (@($merged.checks | ForEach-Object { $_.id }) -contains "codegen.compile") | Should Be $true
        @($merged.limitations).Count | Should Be 1
        (Test-AcceptanceReport -Report $merged).Valid | Should Be $true
    }

    It "父报告没有工具箱清单时从子报告继承，而不是留一个空数组" {
        # 真实场景：只有真正跑过 MATLAB 的那一层才能拿到 ver/license 结果。
        # 空数组也算合法 schema，所以"有字段"并不等于"有内容"，这里专门守住这一点。
        $parent = New-AcceptanceReport -TaskId "merge-inventory" -Backend "matlab-batch"
        @($parent.toolboxInventory).Count | Should Be 0

        $child = New-AcceptanceReport -TaskId "merge-inventory" -Backend "matlab-batch"
        $child.toolboxInventory = @(
            [pscustomobject][ordered]@{ name = "MATLAB"; version = "26.1"; licensed = $true }
            [pscustomobject][ordered]@{ name = "Simulink"; version = "26.1"; licensed = $true }
        )
        $child = Add-AcceptanceCheck -Report $child -Id "inventory.products" -Title "枚举产品" -Level "L1" -Status "PASS"

        $merged = Merge-AcceptanceReport -Report $parent -Child $child -SourceName "toolbox_inventory"
        @($merged.toolboxInventory).Count | Should Be 2
        (@($merged.toolboxInventory | ForEach-Object { $_.name }) -contains "Simulink") | Should Be $true
        (Test-AcceptanceReport -Report $merged).Valid | Should Be $true
    }

    It "父报告已有工具箱清单时不被子报告覆盖" {
        $parent = New-AcceptanceReport -TaskId "merge-inventory2" -Backend "matlab-batch"
        $parent.toolboxInventory = @([pscustomobject][ordered]@{ name = "MATLAB"; version = "26.1"; licensed = $true })
        $parent = Add-AcceptanceCheck -Report $parent -Id "parent.check" -Title "父检查" -Level "L1" -Status "PASS"

        $child = New-AcceptanceReport -TaskId "merge-inventory2" -Backend "matlab-batch"
        $child.toolboxInventory = @(
            [pscustomobject][ordered]@{ name = "Other"; version = "1.0"; licensed = $false }
        )
        $child = Add-AcceptanceCheck -Report $child -Id "child.check" -Title "子检查" -Level "L1" -Status "PASS"

        $merged = Merge-AcceptanceReport -Report $parent -Child $child -SourceName "child"
        @($merged.toolboxInventory).Count | Should Be 1
        $merged.toolboxInventory[0].name | Should Be "MATLAB"
    }
}

Describe "等级名称与元数据" {
    It "每个等级都有可读说明" {
        foreach ($level in @("L1", "L2", "L3", "L4", "L5")) {
            (Get-AcceptanceLevelName -Level $level).Length | Should BeGreaterThan 0
        }
    }

    It "协议版本是语义化版本号" {
        (Get-AcceptanceSchemaVersion) | Should Match '^\d+\.\d+\.\d+$'
    }

    It "taskId 只含安全字符" {
        (New-AcceptanceTaskId -Prefix "my task/id") | Should Match '^[A-Za-z0-9._-]+$'
    }
}

Describe "验收范围（capability scope）" {
    function New-ScopedReport {
        param(
            [string]$NumericStatus = "PASS",
            [string]$InventoryStatus = "PASS",
            [string]$CoderStatus = "SKIP",
            [switch]$OmitCoder
        )
        $report = New-AcceptanceReport -TaskId "scope-unit" -Backend "matlab-batch"
        $report = Add-AcceptanceCheck -Report $report -Id "matlab.executable" -Title "解析 MATLAB" -Level "L1" -Status "PASS"
        $report = Add-AcceptanceCheck -Report $report -Id "inventory.products" -Title "产品清单" -Level "L1" -Status $InventoryStatus `
            -Reason $(if ($InventoryStatus -ne "PASS") { "清单为空" } else { "" })
        $report = Add-AcceptanceCheck -Report $report -Id "inventory.gated-license" -Title "核心授权" -Level "L1" -Status "PASS"
        foreach ($id in @("skill.numeric-fit", "skill.figure-export", "skill.data-export")) {
            $report = Add-AcceptanceCheck -Report $report -Id $id -Title $id -Level "L1" -Status $NumericStatus `
                -Reason $(if ($NumericStatus -ne "PASS") { "数值不符" } else { "" })
        }
        if (-not $OmitCoder) {
            $report = Add-AcceptanceCheck -Report $report -Id "codegen.generate" -Title "生成 C 源码" -Level "L1" -Status $CoderStatus `
                -Reason $(if ($CoderStatus -ne "PASS") { "缺少 MATLAB Coder 授权" } else { "" })
        }
        return (Update-AcceptanceSummary -Report $report)
    }

    It "四个范围都有定义，且 full 的必选集最大" {
        $core = Get-AcceptanceScopeDefinition -Scope "core"
        $simulink = Get-AcceptanceScopeDefinition -Scope "simulink"
        $coder = Get-AcceptanceScopeDefinition -Scope "coder"
        $full = Get-AcceptanceScopeDefinition -Scope "full"
        ($core.required.Count -gt 0) | Should Be $true
        ($simulink.required.Count -gt $core.required.Count) | Should Be $true
        ($coder.required.Count -gt $core.required.Count) | Should Be $true
        ($full.required.Count -gt $coder.required.Count) | Should Be $true
        ($full.required -contains "embedded.hardware-in-loop") | Should Be $true
    }

    It "core 范围不因 Coder 检查 SKIP 而失败" {
        $report = New-ScopedReport -CoderStatus "SKIP"
        $status = Get-AcceptanceScopeStatus -Report $report -Scope "core"
        $status.status | Should Be "PASS"
        ($status.optionalSkipped -contains "codegen.generate") | Should Be $true
        $status.optionalSkippedCount | Should Be 1
    }

    It "可选 SKIP 不影响 core，但整体状态仍然是 SKIP（不被改写）" {
        $report = New-ScopedReport -CoderStatus "SKIP"
        (Get-AcceptanceOverallStatus -Report $report) | Should Be "SKIP"
        (Get-AcceptanceScopeStatus -Report $report -Scope "core").status | Should Be "PASS"
    }

    It "coder 范围内必选检查 SKIP 时判为 SKIP，而不是 PASS" {
        $report = New-ScopedReport -CoderStatus "SKIP"
        $status = Get-AcceptanceScopeStatus -Report $report -Scope "coder"
        $status.status | Should Be "SKIP"
        ($status.skippedRequired -contains "codegen.generate") | Should Be $true
    }

    It "必选检查 FAIL 时范围判为 FAIL" {
        $report = New-ScopedReport -NumericStatus "FAIL"
        (Get-AcceptanceScopeStatus -Report $report -Scope "core").status | Should Be "FAIL"
    }

    It "必选检查在报告里缺失时判为 SKIP（未产出不等于通过）" {
        $report = New-ScopedReport -OmitCoder
        $status = Get-AcceptanceScopeStatus -Report $report -Scope "coder"
        $status.status | Should Be "SKIP"
        ($status.missingRequired -contains "codegen.generate") | Should Be $true
    }

    It "范围退出码与状态一致：PASS=0 / FAIL=1 / SKIP=3" {
        (Get-AcceptanceScopeExitCode -ScopeStatus ([pscustomobject]@{ status = "PASS" })) | Should Be 0
        (Get-AcceptanceScopeExitCode -ScopeStatus ([pscustomobject]@{ status = "FAIL" })) | Should Be 1
        (Get-AcceptanceScopeExitCode -ScopeStatus ([pscustomobject]@{ status = "SKIP" })) | Should Be 3
    }

    It "四个范围可以一次性求值，顺序固定" {
        $report = New-ScopedReport
        $evaluations = Get-AcceptanceScopeEvaluations -Report $report
        @($evaluations).Count | Should Be 4
        (@($evaluations | ForEach-Object { $_.name }) -join ",") | Should Be "core,simulink,coder,full"
    }

    It "范围求值结果能写进报告并通过 schema 校验" {
        $report = New-ScopedReport
        $evaluations = Get-AcceptanceScopeEvaluations -Report $report
        $selected = $evaluations | Where-Object { $_.name -eq "core" } | Select-Object -First 1
        $report | Add-Member -NotePropertyName scopes -NotePropertyValue $evaluations -Force
        $report | Add-Member -NotePropertyName scope -NotePropertyValue $selected -Force
        $validation = Test-AcceptanceReport -Report $report
        ($validation.Errors -join " | ") | Should Be ""
        $validation.Valid | Should Be $true
    }
}

Describe "报告边界值编码" {
    # 语义校验要求 summary 与 checks 一致，所以每次改完检查项都要收尾一次。
    function Complete-Report {
        param($Report)
        return (Update-AcceptanceSummary -Report $Report)
    }

    It "单条检查的 checks 仍然是数组（不能退化成对象）" {
        $report = New-AcceptanceReport -TaskId "boundary-single" -Backend "static"
        $report = Add-AcceptanceCheck -Report $report -Id "only.check" -Title "唯一检查" -Level "L1" -Status "PASS"
        $report = Complete-Report $report
        $validation = Test-AcceptanceReport -Report $report
        ($validation.Errors -join " | ") | Should Be ""
        $validation.Valid | Should Be $true
    }

    It "exitCode 允许整数与 null，拒绝字符串" {
        $report = New-AcceptanceReport -TaskId "boundary-exit" -Backend "static"
        $report = Add-AcceptanceCheck -Report $report -Id "exit.ok" -Title "整数退出码" -Level "L1" -Status "PASS" -ExitCode 0
        ($report = Complete-Report $report) | Out-Null
        (Test-AcceptanceReport -Report $report).Valid | Should Be $true

        $report2 = New-AcceptanceReport -TaskId "boundary-exit2" -Backend "static"
        $report2 = Add-AcceptanceCheck -Report $report2 -Id "exit.null" -Title "空退出码" -Level "L1" -Status "PASS"
        ($report2 = Complete-Report $report2) | Out-Null
        (Test-AcceptanceReport -Report $report2).Valid | Should Be $true

        # 公开 API 的参数是强类型的，传字符串会被转成 int。
        # 这里直接改对象字段，模拟"外部生产者写坏了 JSON"的情形，验证校验器能拦住。
        $bad = New-AcceptanceReport -TaskId "boundary-exit3" -Backend "static"
        $bad = Add-AcceptanceCheck -Report $bad -Id "exit.bad" -Title "字符串退出码" -Level "L1" -Status "PASS" -ExitCode 0
        ($bad = Complete-Report $bad) | Out-Null
        $bad.checks[0].exitCode = "0"
        (Test-AcceptanceReport -Report $bad).Valid | Should Be $false
    }

    It "durationSeconds 允许数字与 null，拒绝负数" {
        $report = New-AcceptanceReport -TaskId "boundary-duration" -Backend "static"
        $report = Add-AcceptanceCheck -Report $report -Id "dur.ok" -Title "时长" -Level "L1" -Status "PASS" -DurationSeconds 1.25
        ($report = Complete-Report $report) | Out-Null
        (Test-AcceptanceReport -Report $report).Valid | Should Be $true

        $bad = New-AcceptanceReport -TaskId "boundary-duration2" -Backend "static"
        $bad = Add-AcceptanceCheck -Report $bad -Id "dur.bad" -Title "负时长" -Level "L1" -Status "PASS" -DurationSeconds 1
        ($bad = Complete-Report $bad) | Out-Null
        $bad.checks[0].durationSeconds = -1
        (Test-AcceptanceReport -Report $bad).Valid | Should Be $false
    }

    It "errorClass 只接受约定的 8 个类别（另加 null）" {
        $allowed = @("ENVIRONMENT_ERROR", "LICENSE_ERROR", "MCP_CONNECTION_ERROR", "MATLAB_RUNTIME_ERROR",
            "SIMULATION_ERROR", "CODEGEN_ERROR", "VALIDATION_ERROR", "TIMEOUT")
        foreach ($class in $allowed) {
            $report = New-AcceptanceReport -TaskId "boundary-class" -Backend "static"
            $report = Add-AcceptanceCheck -Report $report -Id "cls.check" -Title "错误类别" -Level "L1" -Status "FAIL" `
                -Reason "示例" -ErrorClass $class
            ($report = Complete-Report $report) | Out-Null
            (Test-AcceptanceReport -Report $report).Valid | Should Be $true
        }

        # 非法 errorClass 在构造期就抛错，比"先写出去再被校验器拒绝"更早挡住问题。
        $threw = $false
        try {
            Add-AcceptanceCheck -Report (New-AcceptanceReport -TaskId "boundary-class2" -Backend "static") `
                -Id "cls.bad" -Title "非法类别" -Level "L1" -Status "FAIL" -Reason "示例" -ErrorClass "SOMETHING_ELSE" | Out-Null
        }
        catch { $threw = $true }
        $threw | Should Be $true

        # 同时确认校验器也能拦住被外部改坏的报告。
        $tampered = New-AcceptanceReport -TaskId "boundary-class3" -Backend "static"
        $tampered = Add-AcceptanceCheck -Report $tampered -Id "cls.ok" -Title "合法类别" -Level "L1" -Status "FAIL" `
            -Reason "示例" -ErrorClass "VALIDATION_ERROR"
        ($tampered = Complete-Report $tampered) | Out-Null
        $tampered.checks[0].errorClass = "SOMETHING_ELSE"
        (Test-AcceptanceReport -Report $tampered).Valid | Should Be $false
    }

    It "空字符串 reason 不能冒充有效原因（SKIP 必须可审计）" {
        $report = New-AcceptanceReport -TaskId "boundary-reason" -Backend "static"
        $threw = $false
        try {
            Add-AcceptanceCheck -Report $report -Id "skip.no-reason" -Title "无原因跳过" -Level "L1" -Status "SKIP" | Out-Null
        }
        catch { $threw = $true }
        $threw | Should Be $true
    }

    It "artifactPaths 为空数组时仍然合法" {
        $report = New-AcceptanceReport -TaskId "boundary-artifacts" -Backend "static"
        $report = Add-AcceptanceCheck -Report $report -Id "art.none" -Title "无产物" -Level "L1" -Status "PASS"
        ($report = Complete-Report $report) | Out-Null
        (Test-AcceptanceReport -Report $report).Valid | Should Be $true
        @($report.checks[0].artifactPaths).Count | Should Be 0
    }

    It "空工具箱清单是合法数组，但缺少 name/version 的条目非法" {
        $report = New-AcceptanceReport -TaskId "boundary-inventory" -Backend "static"
        $report = Add-AcceptanceCheck -Report $report -Id "inv.check" -Title "清单" -Level "L1" -Status "PASS"
        ($report = Complete-Report $report) | Out-Null
        (Test-AcceptanceReport -Report $report).Valid | Should Be $true

        $report.toolboxInventory = @([pscustomobject][ordered]@{ name = "MATLAB" })
        (Test-AcceptanceReport -Report $report).Valid | Should Be $false
    }

    It "licensed 允许 null（无法判定授权），但不允许字符串" {
        $report = New-AcceptanceReport -TaskId "boundary-licensed" -Backend "static"
        $report = Add-AcceptanceCheck -Report $report -Id "lic.check" -Title "授权三态" -Level "L1" -Status "PASS"
        ($report = Complete-Report $report) | Out-Null
        $report.toolboxInventory = @(
            [pscustomobject][ordered]@{ name = "A"; version = "1"; licensed = $true }
            [pscustomobject][ordered]@{ name = "B"; version = "1"; licensed = $null }
        )
        (Test-AcceptanceReport -Report $report).Valid | Should Be $true

        $report.toolboxInventory = @([pscustomobject][ordered]@{ name = "C"; version = "1"; licensed = "unknown" })
        (Test-AcceptanceReport -Report $report).Valid | Should Be $false
    }
}
