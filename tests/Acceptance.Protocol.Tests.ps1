<#
.SYNOPSIS
验收协议测试：JSON Schema、语义约束、等级判定、合并与退出码。

.DESCRIPTION
不依赖 MATLAB / MCP / 网络，可在免费 CI 上完整运行。
#>

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
        { Add-AcceptanceCheck -Report $report -Id "a.skip" -Title "t" -Level "L1" -Status "SKIP" } | Should Throw
    }

    It "FAIL 缺少 reason 时构造检查项直接报错" {
        $report = New-AcceptanceReport -TaskId "fail-guard" -Backend "static"
        { Add-AcceptanceCheck -Report $report -Id "a.fail" -Title "t" -Level "L1" -Status "FAIL" } | Should Throw
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
