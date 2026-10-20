<#
.SYNOPSIS
验证 Desktop 证据来自会话注入及成功正文读取，并排除用户消息。
#>
. (Join-Path $PSScriptRoot 'helpers/Assertions.ps1')
$script:DesktopExporter = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Export-CodexDesktopSkillEvidence.ps1'

Describe 'Desktop 技能证据的客户端与来源边界' {
    BeforeEach {
        $script:DesktopEvidenceRoot = Join-Path ([IO.Path]::GetTempPath()) ('mas-desktop-evidence-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:DesktopEvidenceRoot -Force | Out-Null
        $script:DesktopEvidenceSource = Join-Path $script:DesktopEvidenceRoot 'session.jsonl'
        $script:DesktopEvidenceOutput = Join-Path $script:DesktopEvidenceRoot 'out'
        $script:DesktopFixture = @(
            @{type='session_meta';timestamp='2026-10-20T00:00:00Z';payload=@{id='test';originator='Codex Desktop';source='vscode';cli_version='test'}}
            @{type='response_item';payload=@{type='message';role='developer';content=@(@{text='<app-context>cwd=/repo/matlab</app-context>'})}}
            @{type='response_item';payload=@{type='message';role='developer';content=@(@{text='- matlab-runner: 示例 (file: r1/matlab-runner/SKILL.md)'})}}
            @{type='response_item';payload=@{type='message';role='user';content=@(@{text='PRIVATE_USER_MESSAGE_DO_NOT_EXPORT'})}}
        )
    }
    AfterEach {
        $resolved = [IO.Path]::GetFullPath($script:DesktopEvidenceRoot)
        $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
        if (-not $resolved.StartsWith($prefix) -or (Split-Path -Leaf $resolved) -notlike 'mas-desktop-evidence-*') {
            throw '测试清理路径越界。'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    It '从平台注入发现技能，用户消息不进入导出结果' {
        $script:DesktopFixture | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress } |
            Set-Content -LiteralPath $script:DesktopEvidenceSource -Encoding UTF8
        $r = & $script:DesktopExporter -SessionFile $script:DesktopEvidenceSource -OutputDirectory $script:DesktopEvidenceOutput
        $r.discovered | Should Be 1
        $r.loadCalls | Should Be 0
        $raw = [IO.File]::ReadAllText((Join-Path $script:DesktopEvidenceOutput 'skill_evidence.json'))
        $raw.Contains('PRIVATE_USER_MESSAGE_DO_NOT_EXPORT') | Should Be $false
    }
    It '拒绝把 CLI 会话冒充 Desktop' {
        $script:DesktopFixture[0].payload.originator = 'Codex CLI'
        $script:DesktopFixture | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress } |
            Set-Content -LiteralPath $script:DesktopEvidenceSource -Encoding UTF8
        (Test-Throws { & $script:DesktopExporter -SessionFile $script:DesktopEvidenceSource -OutputDirectory $script:DesktopEvidenceOutput }) | Should Be $true
        (Test-Path -LiteralPath $script:DesktopEvidenceOutput) | Should Be $false
    }
    It 'originator 同为 Codex Desktop 但 source=exec 的 CLI 会话也必须被拒绝' {
        # CLI 0.147.0 的 exec 会话确实写 originator='Codex Desktop'，只查 originator 会放行。
        $script:DesktopFixture[0].payload.source = 'exec'
        $script:DesktopFixture | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress } |
            Set-Content -LiteralPath $script:DesktopEvidenceSource -Encoding UTF8
        (Test-Throws { & $script:DesktopExporter -SessionFile $script:DesktopEvidenceSource -OutputDirectory $script:DesktopEvidenceOutput }) | Should Be $true
        (Test-Path -LiteralPath $script:DesktopEvidenceOutput) | Should Be $false
    }
    It '缺少 app-context 标记的会话不算 Desktop UI 会话' {
        $script:DesktopFixture[1].payload.content[0].text = 'no marker here'
        $script:DesktopFixture | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress } |
            Set-Content -LiteralPath $script:DesktopEvidenceSource -Encoding UTF8
        (Test-Throws { & $script:DesktopExporter -SessionFile $script:DesktopEvidenceSource -OutputDirectory $script:DesktopEvidenceOutput }) | Should Be $true
    }
    It '只把带成功返回正文的读取记为加载' {
        $script:DesktopFixture += @{type='response_item';payload=@{type='custom_tool_call';name='exec';call_id='read';input='Get-Content C:\Users\alice\.agents\skills\matlab-runner\SKILL.md'}}
        $script:DesktopFixture += @{type='response_item';payload=@{type='custom_tool_call_output';call_id='read';output=@(@{type='input_text';text='name: matlab-runner'})}}
        $script:DesktopFixture += @{type='response_item';payload=@{type='custom_tool_call';name='exec';call_id='pending';input='Get-Content C:\Users\alice\.agents\skills\matlab-orchestrator\SKILL.md'}}
        $script:DesktopFixture | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress } |
            Set-Content -LiteralPath $script:DesktopEvidenceSource -Encoding UTF8
        $r = & $script:DesktopExporter -SessionFile $script:DesktopEvidenceSource -OutputDirectory $script:DesktopEvidenceOutput
        $r.loadCalls | Should Be 1
    }
    It '混合读取只导出哈希与技能名，不复制敏感哨兵或原始输入输出' {
        $inputText = 'Get-Content C:\Users\alice\.agents\skills\matlab-runner\SKILL.md; Get-Content INPUT_SECRET_DO_NOT_EXPORT.env'
        $outputText = "name: matlab-runner`nOUTPUT_SECRET_DO_NOT_EXPORT`nname: matlab-unknown-secret"
        $script:DesktopFixture += @{type='response_item';timestamp='2026-10-20T00:00:01Z';payload=@{type='custom_tool_call';name='exec';call_id='mixed';input=$inputText}}
        $script:DesktopFixture += @{type='response_item';payload=@{type='custom_tool_call_output';call_id='mixed';output=$outputText}}
        $script:DesktopFixture | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress } |
            Set-Content -LiteralPath $script:DesktopEvidenceSource -Encoding UTF8
        $r = & $script:DesktopExporter -SessionFile $script:DesktopEvidenceSource -OutputDirectory $script:DesktopEvidenceOutput
        $r.loadCalls | Should Be 1
        $raw = [IO.File]::ReadAllText((Join-Path $script:DesktopEvidenceOutput 'skill_evidence.json'))
        $raw.Contains('INPUT_SECRET_DO_NOT_EXPORT') | Should Be $false
        $raw.Contains('OUTPUT_SECRET_DO_NOT_EXPORT') | Should Be $false
        $raw.Contains('matlab-unknown-secret') | Should Be $false
        $evidence = $raw | ConvertFrom-Json
        $load = $evidence.loads[0]
        @($load.PSObject.Properties.Name | Where-Object { $_ -in @('input','output','tool') }).Count | Should Be 0
        @($load.observedSkillNames).Count | Should Be 1
        $load.observedSkillNames[0] | Should Be 'matlab-runner'
        ($load.inputSha256 -match '^[A-F0-9]{64}$') | Should Be $true
        ($load.outputSha256 -match '^[A-F0-9]{64}$') | Should Be $true
        ($load.inputSha256 -ne $load.outputSha256) | Should Be $true
        # 夹具在 meta 之后多了一条 <app-context> developer 消息，事件下标整体 +1。
        $load.sourcePointer.callEventIndex | Should Be 4
        $load.sourcePointer.outputEventIndex | Should Be 5
        # PS7 会将 JSON ISO 时间自动解码为 DateTime；按同一 UTC 时刻比较。
        ([datetimeoffset]$load.timestamp).UtcDateTime.Ticks |
            Should Be ([datetimeoffset]'2026-10-20T00:00:01Z').UtcDateTime.Ticks
    }
    It '失败返回即使出现技能名也不能记为成功观察' {
        $script:DesktopFixture += @{type='response_item';payload=@{type='custom_tool_call';name='exec';call_id='failed';input='Get-Content C:\Users\alice\.agents\skills\matlab-runner\SKILL.md'}}
        $script:DesktopFixture += @{type='response_item';payload=@{type='custom_tool_call_output';call_id='failed';output='{"exit_code":1,"output":"name: matlab-runner"}'}}
        $script:DesktopFixture | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress } |
            Set-Content -LiteralPath $script:DesktopEvidenceSource -Encoding UTF8
        $r = & $script:DesktopExporter -SessionFile $script:DesktopEvidenceSource -OutputDirectory $script:DesktopEvidenceOutput
        $r.loadCalls | Should Be 0
    }
    It '混合输出中的其他已发现技能名必须有对应读取路径' {
        $script:DesktopFixture += @{type='response_item';payload=@{type='message';role='developer';content=@(@{text='- matlab-orchestrator: 示例 (file: r1/matlab-orchestrator/SKILL.md)'})}}
        $script:DesktopFixture += @{type='response_item';payload=@{type='custom_tool_call';name='exec';call_id='mixed-names';input='Get-Content C:\Users\alice\.agents\skills\matlab-runner\SKILL.md; Get-Content local.txt'}}
        $script:DesktopFixture += @{type='response_item';payload=@{type='custom_tool_call_output';call_id='mixed-names';output="name: matlab-runner`nname: matlab-orchestrator"}}
        $script:DesktopFixture | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress } |
            Set-Content -LiteralPath $script:DesktopEvidenceSource -Encoding UTF8
        $r = & $script:DesktopExporter -SessionFile $script:DesktopEvidenceSource -OutputDirectory $script:DesktopEvidenceOutput
        $evidence = [IO.File]::ReadAllText($r.path) | ConvertFrom-Json
        @($evidence.loads[0].observedSkillNames).Count | Should Be 1
        $evidence.loads[0].observedSkillNames[0] | Should Be 'matlab-runner'
    }
    It '多轮注入同名技能即使描述变化也只累计一个发现项' {
        $script:DesktopFixture += @{type='response_item';payload=@{type='message';role='developer';content=@(@{text='- matlab-runner: 更新后的描述 (file: r1/matlab-runner/SKILL.md)'})}}
        $script:DesktopFixture | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress } |
            Set-Content -LiteralPath $script:DesktopEvidenceSource -Encoding UTF8
        $r = & $script:DesktopExporter -SessionFile $script:DesktopEvidenceSource -OutputDirectory $script:DesktopEvidenceOutput
        $r.discovered | Should Be 1
        $evidence = [IO.File]::ReadAllText($r.path) | ConvertFrom-Json
        @($evidence.skillDiscovery.names).Count | Should Be 1
        @($evidence.skillDiscovery.catalogLines).Count | Should Be 2
    }
}
