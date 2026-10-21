<#
.SYNOPSIS
安装器端到端场景测试（沙箱内运行，不触碰真实用户配置）。

.DESCRIPTION
用 PATH 里的 codex / claude 桩程序模拟客户端，验证：
- 首次安装（generic / vscode / claude）
- 重复安装幂等
- 冲突配置不丢数据（已有 .mcp.json 条目、非法 JSON）
- 无 Codex 时单独配置 Claude
- existing 模式生成的配置不含 display-mode
- 客户端注册失败后回滚到变更前状态
- Setup 中途失败后 startup.m 回滚
- DryRun 零写入
- Sync-Skills 冲突 / 强制 / 托管更新

所有路径都在临时目录，脚本以 -SkipBaseSetup / -McpDataDir / -StartupDirectory 隔离。
#>

. (Join-Path $PSScriptRoot "helpers\Assertions.ps1")
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:InstallScript = Join-Path $script:RepoRoot "scripts\Install-MatlabMcpClients.ps1"
$script:SetupScript = Join-Path $script:RepoRoot "scripts\Setup-MatlabMcpExistingSession.ps1"
$script:SyncScript = Join-Path $script:RepoRoot "scripts\Sync-Skills.ps1"
Import-Module (Join-Path $script:RepoRoot "scripts\MatlabAgentSkills.Core.psm1") -Force -DisableNameChecking

$script:OriginalPath = $env:PATH

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function New-Sandbox {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("mas-e2e-" + [guid]::NewGuid().ToString('N'))
    $sandbox = [pscustomobject]@{
        Root       = $root
        StubDir    = Join-Path $root "stubs"
        Work       = Join-Path $root "work"
        Backup     = Join-Path $root "backups"
        MatlabRoot = Join-Path $root "matlab"
        DataDir    = Join-Path $root "mcpdata"
        StartupDir = Join-Path $root "matlabuser"
        FakeServer = Join-Path $root "fake-mcp-server.cmd"
    }
    foreach ($path in @($sandbox.StubDir, $sandbox.Work, $sandbox.MatlabRoot, $sandbox.DataDir, $sandbox.StartupDir)) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
    }
    Write-Utf8NoBom -Path $sandbox.FakeServer -Text "@echo off`r`nexit /b 0`r`n"
    return $sandbox
}

function Remove-Sandbox {
    param($Sandbox)
    $env:PATH = $script:OriginalPath
    if ($Sandbox -and (Test-Path -LiteralPath $Sandbox.Root)) {
        Remove-Item -LiteralPath $Sandbox.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function New-ClientStub {
    param(
        [Parameter(Mandatory)][string]$StubDir,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not (Test-Path -LiteralPath $StubDir)) { New-Item -ItemType Directory -Force -Path $StubDir | Out-Null }

    $ps1 = Join-Path $StubDir "$Name-stub.ps1"
    $stateFile = Join-Path $StubDir "$Name-registration.txt"
    $logFile = Join-Path $StubDir "$Name-calls.log"
    $failFlag = Join-Path $StubDir "$Name-fail-add-once.flag"

    $body = @'
$stateDir = Split-Path -Parent $PSCommandPath
$name = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath) -replace '-stub$', ''
$stateFile = Join-Path $stateDir "$name-registration.txt"
$logFile = Join-Path $stateDir "$name-calls.log"
$failFlag = Join-Path $stateDir "$name-fail-add-once.flag"

Add-Content -LiteralPath $logFile -Value ($args -join ' ')

$first = if ($args.Count -gt 0) { [string]$args[0] } else { '' }
$second = if ($args.Count -gt 1) { [string]$args[1] } else { '' }

if ($first -ne 'mcp') { exit 0 }

switch ($second) {
    'list' {
        if (Test-Path -LiteralPath $stateFile) { Get-Content -LiteralPath $stateFile -TotalCount 1 }
        exit 0
    }
    'get' {
        if (Test-Path -LiteralPath $stateFile) {
            Get-Content -Raw -LiteralPath $stateFile
            exit 0
        }
        [Console]::Error.WriteLine("no such server")
        exit 1
    }
    'remove' {
        Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
        exit 0
    }
    'add' {
        if (Test-Path -LiteralPath $failFlag) {
            Remove-Item -LiteralPath $failFlag -Force
            [Console]::Error.WriteLine("stub: transient add failure")
            exit 3
        }
        $separator = -1
        for ($i = 0; $i -lt $args.Count; $i++) { if ([string]$args[$i] -eq '--') { $separator = $i; break } }
        if ($separator -lt 0) { $separator = 3 }
        $serverName = if ($args.Count -gt 2) { [string]$args[2] } else { 'unknown' }
        $exe = if ($args.Count -gt ($separator + 1)) { [string]$args[$separator + 1] } else { '' }
        $tail = @()
        if ($args.Count -gt ($separator + 2)) { $tail = $args[($separator + 2)..($args.Count - 1)] }
        $text = "$serverName`n  enabled: true`n  transport: stdio`n  command: $exe`n  args: $($tail -join ' ')"
        Set-Content -LiteralPath $stateFile -Value $text -Encoding ascii
        exit 0
    }
    default { exit 0 }
}
'@
    Write-Utf8NoBom -Path $ps1 -Text $body

    $cmd = Join-Path $StubDir "$Name.cmd"
    $cmdBody = "@echo off`r`n`"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -File `"%~dp0$Name-stub.ps1`" %*`r`n"
    Write-Utf8NoBom -Path $cmd -Text $cmdBody

    return [pscustomobject]@{
        Name       = $Name
        Cmd        = $cmd
        StateFile  = $stateFile
        LogFile    = $logFile
        FailFlag   = $failFlag
    }
}

function Use-StubsOnly {
    param($Sandbox)
    $env:PATH = "$($Sandbox.StubDir);$env:SystemRoot\System32;$env:SystemRoot"
}

function Read-McpConfig {
    param([string]$Path)
    return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json)
}

Describe "Install-MatlabMcpClients：首次安装与安全合并" {

    It "existing 模式生成的 .mcp.json 不含 --matlab-display-mode" {
        $sandbox = New-Sandbox
        try {
            $json = & $script:InstallScript -ServerExePath $sandbox.FakeServer -MatlabRoot $sandbox.MatlabRoot `
                -Clients generic -ProjectPath $sandbox.Work -SkipBaseSetup -SessionMode existing `
                -BackupRoot $sandbox.Backup | Out-String | ConvertFrom-Json

            $json.ok | Should Be $true
            ($json.serverArgs -join ";") | Should Be "--matlab-session-mode=existing"

            $config = Read-McpConfig -Path (Join-Path $sandbox.Work ".mcp.json")
            $args = @($config.mcpServers.'matlab-official'.args)
            ($args -join ";") | Should Be "--matlab-session-mode=existing"
            ($args -join ";") | Should Not Match "display-mode"
            ($args -join ";") | Should Not Match "matlab-root"
            ($args -join ";") | Should Not Match "initialize-matlab-on-startup"
        }
        finally { Remove-Sandbox $sandbox }
    }

    It "auto 模式生成的配置包含 display-mode 与 matlab-root" {
        $sandbox = New-Sandbox
        try {
            & $script:InstallScript -ServerExePath $sandbox.FakeServer -MatlabRoot $sandbox.MatlabRoot `
                -Clients generic -ProjectPath $sandbox.Work -SkipBaseSetup -SessionMode auto `
                -BackupRoot $sandbox.Backup | Out-Null

            $config = Read-McpConfig -Path (Join-Path $sandbox.Work ".mcp.json")
            $args = @($config.mcpServers.'matlab-official'.args)
            ($args -join ";") | Should Match "--matlab-display-mode=desktop"
            ($args -join ";") | Should Match "--matlab-root="
        }
        finally { Remove-Sandbox $sandbox }
    }

    It "保留用户已有的其它 MCP server 配置" {
        $sandbox = New-Sandbox
        try {
            $configPath = Join-Path $sandbox.Work ".mcp.json"
            Write-Utf8NoBom -Path $configPath -Text '{"mcpServers":{"my-own":{"command":"node","args":["x.js"]}},"extra":{"keep":1}}'

            & $script:InstallScript -ServerExePath $sandbox.FakeServer -MatlabRoot $sandbox.MatlabRoot `
                -Clients generic -ProjectPath $sandbox.Work -SkipBaseSetup -BackupRoot $sandbox.Backup | Out-Null

            $config = Read-McpConfig -Path $configPath
            $config.mcpServers.'my-own'.command | Should Be "node"
            $config.mcpServers.'matlab-official'.command | Should Be $sandbox.FakeServer
            $config.extra.keep | Should Be 1
        }
        finally { Remove-Sandbox $sandbox }
    }

    It "VS Code 配置保留其它 server 并带 type=stdio" {
        $sandbox = New-Sandbox
        try {
            $vscodeDir = Join-Path $sandbox.Work ".vscode"
            New-Item -ItemType Directory -Force -Path $vscodeDir | Out-Null
            $configPath = Join-Path $vscodeDir "mcp.json"
            Write-Utf8NoBom -Path $configPath -Text '{"servers":{"other":{"type":"stdio","command":"x","args":[]}},"inputs":[]}'

            & $script:InstallScript -ServerExePath $sandbox.FakeServer -MatlabRoot $sandbox.MatlabRoot `
                -Clients vscode -ProjectPath $sandbox.Work -SkipBaseSetup -BackupRoot $sandbox.Backup | Out-Null

            $config = Read-McpConfig -Path $configPath
            $config.servers.other.command | Should Be "x"
            $config.servers.'matlab-official'.type | Should Be "stdio"
            @($config.inputs).Count | Should Be 0
        }
        finally { Remove-Sandbox $sandbox }
    }

    It "重复安装是幂等的（第二次全部 unchanged，文件字节不变）" {
        $sandbox = New-Sandbox
        try {
            & $script:InstallScript -ServerExePath $sandbox.FakeServer -MatlabRoot $sandbox.MatlabRoot `
                -Clients generic -ProjectPath $sandbox.Work -SkipBaseSetup -BackupRoot $sandbox.Backup | Out-Null
            $configPath = Join-Path $sandbox.Work ".mcp.json"
            $first = [System.IO.File]::ReadAllBytes($configPath)

            $json = & $script:InstallScript -ServerExePath $sandbox.FakeServer -MatlabRoot $sandbox.MatlabRoot `
                -Clients generic -ProjectPath $sandbox.Work -SkipBaseSetup -BackupRoot $sandbox.Backup | Out-String | ConvertFrom-Json

            $second = [System.IO.File]::ReadAllBytes($configPath)
            $json.results.generic.Action | Should Be "unchanged"
            ($second -join ",") | Should Be ($first -join ",")
        }
        finally { Remove-Sandbox $sandbox }
    }

    It "配置文件 JSON 非法时安装失败且原文件不被破坏" {
        $sandbox = New-Sandbox
        try {
            $configPath = Join-Path $sandbox.Work ".mcp.json"
            $broken = '{ "mcpServers": { "a": { "command": "x" }'
            Write-Utf8NoBom -Path $configPath -Text $broken
            $before = [System.IO.File]::ReadAllBytes($configPath)

            (Test-Throws { & $script:InstallScript -ServerExePath $sandbox.FakeServer -MatlabRoot $sandbox.MatlabRoot `
                    -Clients generic -ProjectPath $sandbox.Work -SkipBaseSetup -BackupRoot $sandbox.Backup }) | Should Be $true

            ([System.IO.File]::ReadAllBytes($configPath) -join ",") | Should Be ($before -join ",")
        }
        finally { Remove-Sandbox $sandbox }
    }

    It "DryRun 不写 .mcp.json" {
        $sandbox = New-Sandbox
        try {
            $json = & $script:InstallScript -ServerExePath $sandbox.FakeServer -MatlabRoot $sandbox.MatlabRoot `
                -Clients generic -ProjectPath $sandbox.Work -SkipBaseSetup -BackupRoot $sandbox.Backup -DryRun `
                | Out-String | ConvertFrom-Json

            $json.dryRun | Should Be $true
            $json.results.generic.Action | Should Be "would_created"
            (Test-Path -LiteralPath (Join-Path $sandbox.Work ".mcp.json")) | Should Be $false
        }
        finally { Remove-Sandbox $sandbox }
    }
}

Describe "Install-MatlabMcpClients：客户端解耦（P0-2）" {

    It "没有 Codex 时也能单独接入 Claude Code" {
        $sandbox = New-Sandbox
        try {
            New-ClientStub -StubDir $sandbox.StubDir -Name "claude" | Out-Null
            Use-StubsOnly $sandbox

            $json = & $script:InstallScript -ServerExePath $sandbox.FakeServer -MatlabRoot $sandbox.MatlabRoot `
                -Clients claude -SkipBaseSetup -BackupRoot $sandbox.Backup | Out-String | ConvertFrom-Json

            $json.ok | Should Be $true
            $json.results.claude.Action | Should Be "created"
            (Test-Path -LiteralPath (Join-Path $sandbox.StubDir "claude-registration.txt")) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $sandbox.StubDir "claude-calls.log")) | Should Be $true
        }
        finally { Remove-Sandbox $sandbox }
    }

    It "显式要求 Codex 但未安装时给出明确错误" {
        $sandbox = New-Sandbox
        try {
            New-ClientStub -StubDir $sandbox.StubDir -Name "claude" | Out-Null
            Use-StubsOnly $sandbox

            (Test-Throws { & $script:InstallScript -ServerExePath $sandbox.FakeServer -MatlabRoot $sandbox.MatlabRoot `
                    -Clients codex -SkipBaseSetup -BackupRoot $sandbox.Backup }) | Should Be $true
        }
        finally { Remove-Sandbox $sandbox }
    }

    It "Claude 注册重复执行是幂等的" {
        $sandbox = New-Sandbox
        try {
            New-ClientStub -StubDir $sandbox.StubDir -Name "claude" | Out-Null
            Use-StubsOnly $sandbox

            & $script:InstallScript -ServerExePath $sandbox.FakeServer -MatlabRoot $sandbox.MatlabRoot `
                -Clients claude -SkipBaseSetup -BackupRoot $sandbox.Backup | Out-Null
            $json = & $script:InstallScript -ServerExePath $sandbox.FakeServer -MatlabRoot $sandbox.MatlabRoot `
                -Clients claude -SkipBaseSetup -BackupRoot $sandbox.Backup | Out-String | ConvertFrom-Json

            $json.results.claude.Action | Should Be "unchanged"
        }
        finally { Remove-Sandbox $sandbox }
    }

    It "existing 模式注册到客户端时也不携带 display-mode" {
        $sandbox = New-Sandbox
        try {
            $stub = New-ClientStub -StubDir $sandbox.StubDir -Name "claude"
            Use-StubsOnly $sandbox

            & $script:InstallScript -ServerExePath $sandbox.FakeServer -MatlabRoot $sandbox.MatlabRoot `
                -Clients claude -SkipBaseSetup -SessionMode existing -BackupRoot $sandbox.Backup | Out-Null

            $registered = Get-Content -Raw -LiteralPath $stub.StateFile
            $registered | Should Match "--matlab-session-mode=existing"
            $registered | Should Not Match "display-mode"
            $registered | Should Not Match "matlab-root"
        }
        finally { Remove-Sandbox $sandbox }
    }

    It "Bootstrap -DryRun 在已有仓库上不写任何文件（幂等冒烟）" {
        $sandbox = New-Sandbox
        try {
            $bootstrap = Join-Path $script:RepoRoot "scripts\Bootstrap-MatlabAgentSkills.ps1"
            $configPath = Join-Path $script:RepoRoot ".mcp.json"
            $existedBefore = Test-Path -LiteralPath $configPath

            $json = & $bootstrap -InstallDir $script:RepoRoot -MatlabRoot $sandbox.MatlabRoot `
                -DryRun -SkipSkillsSync -SkipBaseSetup -Clients generic -BackupRoot $sandbox.Backup `
                | Out-String | ConvertFrom-Json

            $json.dryRun | Should Be $true
            $json.install.dryRun | Should Be $true
            if (-not $existedBefore) {
                (Test-Path -LiteralPath $configPath) | Should Be $false
            }
        }
        finally { Remove-Sandbox $sandbox }
    }

    It "注册失败时回滚到变更前的注册（P0-3）" {
        $sandbox = New-Sandbox
        try {
            $stub = New-ClientStub -StubDir $sandbox.StubDir -Name "codex"
            Use-StubsOnly $sandbox
            $previous = "matlab-official`n  enabled: true`n  command: C:\old\srv.exe`n  args: --matlab-session-mode=auto"
            Write-Utf8NoBom -Path $stub.StateFile -Text $previous
            Write-Utf8NoBom -Path $stub.FailFlag -Text "fail once"

            (Test-Throws { & $script:InstallScript -ServerExePath $sandbox.FakeServer -MatlabRoot $sandbox.MatlabRoot `
                    -Clients codex -SkipBaseSetup -BackupRoot $sandbox.Backup }) | Should Be $true

            $restored = Get-Content -Raw -LiteralPath $stub.StateFile
            $restored | Should Match "C:\\old\\srv.exe"
            $restored | Should Match "--matlab-session-mode=auto"
        }
        finally { Remove-Sandbox $sandbox }
    }
}

Describe "Setup-MatlabMcpExistingSession：失败回滚（P0-6）" {

    It "startup 步骤后失败会还原 startup.m" {
        $sandbox = New-Sandbox
        try {
            $startupPath = Join-Path $sandbox.StartupDir "startup.m"
            $original = "disp('original user startup');"
            Write-Utf8NoBom -Path $startupPath -Text $original

            (Test-Throws { & $script:SetupScript -ServerExePath $sandbox.FakeServer -MatlabRoot $sandbox.MatlabRoot `
                    -McpDataDir $sandbox.DataDir -StartupDirectory $sandbox.StartupDir `
                    -SessionMode auto -SkipClientRegistration -SkipAclFix `
                    -FailAfterStep startup -BackupRoot $sandbox.Backup }) | Should Be $true

            $after = [System.IO.File]::ReadAllText($startupPath)
            $after | Should Match "original user startup"
            $after | Should Not Match "shareMATLABSession"
        }
        finally { Remove-Sandbox $sandbox }
    }

    It "DryRun 不创建 startup.m、不改数据目录" {
        $sandbox = New-Sandbox
        try {
            $startupPath = Join-Path $sandbox.StartupDir "startup.m"
            $json = & $script:SetupScript -ServerExePath $sandbox.FakeServer -MatlabRoot $sandbox.MatlabRoot `
                -McpDataDir $sandbox.DataDir -StartupDirectory $sandbox.StartupDir `
                -SessionMode existing -SkipClientRegistration -SkipAclFix `
                -BackupRoot $sandbox.Backup -DryRun | Out-String | ConvertFrom-Json

            $json.dryRun | Should Be $true
            (Test-Path -LiteralPath $startupPath) | Should Be $false
            ($json.serverArgs -join ";") | Should Be "--matlab-session-mode=existing"
        }
        finally { Remove-Sandbox $sandbox }
    }

    It "知名 SID 在 SDDL 里显示为别名时不会被误判为授权失败" {
        # 真实缺陷（只在 GitHub runner 上暴露）：
        # Get-Acl 生成的 SDDL 会把 S-1-5-21-xxx-500 渲染成别名 LA、S-1-5-18 渲染成 SY。
        # 旧实现用 "SDDL 里是否包含 SID 字面量" 判断授权是否生效，于是给内置管理员
        # （RID 500）授权时必然误判失败并回滚；普通用户 RID 不是 500，本机不会暴露。
        if (-not (Get-Command icacls -ErrorAction SilentlyContinue)) { return }

        $sandbox = New-Sandbox
        try {
            # 用 LocalSystem（S-1-5-18，SDDL 别名 SY）做一次真实授权。
            $sid = "S-1-5-18"
            & icacls $sandbox.DataDir /grant:r ("*" + $sid + ":(OI)(CI)R") | Out-Null
            if ($LASTEXITCODE -ne 0) { return }

            $sddl = (Get-Acl -LiteralPath $sandbox.DataDir).Sddl
            # 前提成立：SDDL 用的是别名，字面量搜索必然落空。
            ($sddl -match [regex]::Escape($sid)) | Should Be $false
            # 语义比较必须能正确识别。
            (Test-AclContainsSid -Path $sandbox.DataDir -Sid $sid) | Should Be $true

            # 不存在的 SID 不能误报为存在。
            (Test-AclContainsSid -Path $sandbox.DataDir -Sid "S-1-5-21-9999999999-9999999999-9999999999-9999") | Should Be $false
        }
        finally { Remove-Sandbox $sandbox }
    }

    It "ACL 授权是追加式且可还原（P0-6）" {
        if (-not (Get-Command icacls -ErrorAction SilentlyContinue)) { return }
        $sandbox = New-Sandbox
        try {
            $beforeSddl = (Get-Acl -LiteralPath $sandbox.DataDir).Sddl
            $session = New-BackupSession -Root $sandbox.Backup -Reason "acl-test"
            try {
                $grant = Set-DirectoryAclGrant -Path $sandbox.DataDir -Session $session
            }
            catch {
                # 失败时把环境事实打全：这条用例在 GitHub runner 上曾经失败过，
                # 只有拿到 SID / SDDL 才能判断是代码问题还是运行面限制。
                $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
                Write-Host "ACL 诊断："
                Write-Host "  路径      = $($sandbox.DataDir)"
                Write-Host "  身份      = $($identity.Name)"
                Write-Host "  用户 SID  = $($identity.User.Value)"
                Write-Host "  之前 SDDL = $beforeSddl"
                Write-Host "  之后 SDDL = $((Get-Acl -LiteralPath $sandbox.DataDir).Sddl)"
                throw
            }
            $grant.Applied | Should Be $true
            $grant.RestrictedInheritance | Should Be $false
            # 用 SID 语义比较，不在 SDDL 文本里搜字面量：
            # RID 500 这类知名 SID 在 SDDL 里会显示成别名 LA，字面量搜索会误判失败。
            (Test-AclContainsSid -Path $sandbox.DataDir -Sid $grant.UserSid) | Should Be $true

            Invoke-BackupRollback -Session $session | Out-Null
            $afterSddl = (Get-Acl -LiteralPath $sandbox.DataDir).Sddl
            (Get-AclFingerprint -Sddl $afterSddl) | Should Be (Get-AclFingerprint -Sddl $beforeSddl)
        }
        finally { Remove-Sandbox $sandbox }
    }
}

Describe "Sync-Skills：冲突检测与备份（P0-5）" {

    It "首次同步安装全部技能并写 manifest" {
        $sandbox = New-Sandbox
        try {
            $skillRoot = Join-Path $sandbox.Root "skills"
            $json = & $script:SyncScript -RepositoryRoot $script:RepoRoot -SkillRoot $skillRoot `
                -BackupRoot $sandbox.Backup | Out-String | ConvertFrom-Json

            ($json.installed -gt 0) | Should Be $true
            @($json.conflicts).Count | Should Be 0
            (Test-Path -LiteralPath (Join-Path $skillRoot ".matlab-agent-skills-manifest.json")) | Should Be $true
        }
        finally { Remove-Sandbox $sandbox }
    }

    It "重复同步全部 unchanged 且不新建备份目录" {
        $sandbox = New-Sandbox
        try {
            $skillRoot = Join-Path $sandbox.Root "skills"
            & $script:SyncScript -RepositoryRoot $script:RepoRoot -SkillRoot $skillRoot -BackupRoot $sandbox.Backup | Out-Null
            $backupCount = @(Get-ChildItem -LiteralPath $sandbox.Backup -Directory -ErrorAction SilentlyContinue).Count

            $json = & $script:SyncScript -RepositoryRoot $script:RepoRoot -SkillRoot $skillRoot `
                -BackupRoot $sandbox.Backup | Out-String | ConvertFrom-Json

            $json.installed | Should Be 0
            $json.updated | Should Be 0
            @(Get-ChildItem -LiteralPath $sandbox.Backup -Directory -ErrorAction SilentlyContinue).Count | Should Be $backupCount
        }
        finally { Remove-Sandbox $sandbox }
    }

    It "外来同名目录内容不同时不覆盖（冲突）" {
        $sandbox = New-Sandbox
        try {
            $skillRoot = Join-Path $sandbox.Root "skills"
            $foreign = Join-Path $skillRoot "matlab-runner"
            Write-Utf8NoBom -Path (Join-Path $foreign "SKILL.md") -Text "USER OWNED CONTENT"

            $json = & $script:SyncScript -RepositoryRoot $script:RepoRoot -SkillRoot $skillRoot `
                -BackupRoot $sandbox.Backup | Out-String | ConvertFrom-Json

            @($json.conflicts) -contains "matlab-runner" | Should Be $true
            (Get-Content -Raw -LiteralPath (Join-Path $foreign "SKILL.md")) | Should Match "USER OWNED CONTENT"
        }
        finally { Remove-Sandbox $sandbox }
    }

    It "-Force 覆盖外来目录并留下备份" {
        $sandbox = New-Sandbox
        try {
            $skillRoot = Join-Path $sandbox.Root "skills"
            $foreign = Join-Path $skillRoot "matlab-runner"
            Write-Utf8NoBom -Path (Join-Path $foreign "SKILL.md") -Text "USER OWNED CONTENT"

            & $script:SyncScript -RepositoryRoot $script:RepoRoot -SkillRoot $skillRoot `
                -BackupRoot $sandbox.Backup -Force | Out-Null

            (Get-Content -Raw -LiteralPath (Join-Path $foreign "SKILL.md")) | Should Not Match "USER OWNED CONTENT"
            $backups = Get-ChildItem -LiteralPath $sandbox.Backup -Recurse -File -Filter "SKILL.md" -ErrorAction SilentlyContinue
            ($backups | Where-Object { (Get-Content -Raw -LiteralPath $_.FullName) -match "USER OWNED CONTENT" }).Count | Should Be 1
        }
        finally { Remove-Sandbox $sandbox }
    }

    It "托管目录被本地修改后再次同步会更新并备份旧内容" {
        $sandbox = New-Sandbox
        try {
            $skillRoot = Join-Path $sandbox.Root "skills"
            & $script:SyncScript -RepositoryRoot $script:RepoRoot -SkillRoot $skillRoot -BackupRoot $sandbox.Backup | Out-Null

            $target = Join-Path $skillRoot "matlab-runner\SKILL.md"
            Write-Utf8NoBom -Path $target -Text "LOCAL EDIT"

            $json = & $script:SyncScript -RepositoryRoot $script:RepoRoot -SkillRoot $skillRoot `
                -BackupRoot $sandbox.Backup | Out-String | ConvertFrom-Json

            $json.updated | Should Be 1
            (Get-Content -Raw -LiteralPath $target) | Should Not Match "LOCAL EDIT"
            $found = Get-ChildItem -LiteralPath $sandbox.Backup -Recurse -File -Filter "SKILL.md" -ErrorAction SilentlyContinue |
                Where-Object { (Get-Content -Raw -LiteralPath $_.FullName) -match "LOCAL EDIT" }
            @($found).Count | Should Be 1
        }
        finally { Remove-Sandbox $sandbox }
    }

    It "DryRun 不同步任何文件" {
        $sandbox = New-Sandbox
        try {
            $skillRoot = Join-Path $sandbox.Root "skills"
            $json = & $script:SyncScript -RepositoryRoot $script:RepoRoot -SkillRoot $skillRoot `
                -BackupRoot $sandbox.Backup -DryRun | Out-String | ConvertFrom-Json

            $json.dryRun | Should Be $true
            (Test-Path -LiteralPath (Join-Path $skillRoot "matlab-runner")) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $skillRoot ".matlab-agent-skills-manifest.json")) | Should Be $false
        }
        finally { Remove-Sandbox $sandbox }
    }
}
