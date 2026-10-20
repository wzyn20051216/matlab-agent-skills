<#
.SYNOPSIS
核心逻辑单元测试（不需要 MATLAB / Codex / Claude）。

.DESCRIPTION
覆盖第一阶段 P0 缺陷的判定逻辑：
- existing 模式参数裁剪（不携带 --matlab-display-mode / --matlab-root / --initialize-matlab-on-startup）
- MCP 配置安全合并（保留用户其它 server）
- skills 冲突判定（install / unchanged / update / conflict）
- startup.m 托管块幂等
- 备份与回滚
- 客户端注册文本解析与幂等判定
- 下载安全（拒绝非 HTTPS）
- 仓库卫生（无机器专属路径、脚本带 BOM 可被 Windows PowerShell 5.1 解析）

语法兼容 Pester 3.4（本机可用版本）与 Pester 5.x 的 legacy Should 形式。
#>

. (Join-Path $PSScriptRoot "helpers\Assertions.ps1")
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:CoreModulePath = Join-Path $script:RepoRoot "scripts\MatlabAgentSkills.Core.psm1"
Import-Module -Name $script:CoreModulePath -Force -DisableNameChecking

function New-TestDirectory {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("mas-test-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    return $path
}

function Remove-TestDirectory {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

Describe "MCP server 参数构造（P0-1：existing 模式非法参数）" {

    It "existing 模式只输出 --matlab-session-mode=existing" {
        $built = New-MatlabMcpServerArgs -SessionMode "existing" -MatlabRoot "C:\MATLAB\R2026a" -InitializeMatlabOnStartup $true
        ($built.Arguments -join ";") | Should Be "--matlab-session-mode=existing"
    }

    It "existing 模式会显式记录被省略的参数" {
        $built = New-MatlabMcpServerArgs -SessionMode "existing" -MatlabRoot "C:\MATLAB\R2026a" -InitializeMatlabOnStartup $true
        $built.DroppedArguments.Count | Should Be 3
        ($built.DroppedArguments -join ";") | Should Match "matlab-display-mode"
        ($built.DroppedArguments -join ";") | Should Match "matlab-root"
        ($built.DroppedArguments -join ";") | Should Match "initialize-matlab-on-startup"
    }

    It "auto 模式保留 display-mode / root / initialize 三项" {
        $built = New-MatlabMcpServerArgs -SessionMode "auto" -MatlabRoot "C:\MATLAB\R2026a" -InitializeMatlabOnStartup $true
        $joined = $built.Arguments -join ";"
        $joined | Should Match "--matlab-session-mode=auto"
        $joined | Should Match "--matlab-display-mode=desktop"
        $joined | Should Match "--matlab-root=C:\\MATLAB\\R2026a"
        $joined | Should Match "--initialize-matlab-on-startup=true"
    }

    It "new 模式支持 nodesktop" {
        $built = New-MatlabMcpServerArgs -SessionMode "new" -MatlabRoot "C:\MATLAB\R2026a" -InitializeMatlabOnStartup $false -DisplayMode "nodesktop"
        $joined = $built.Arguments -join ";"
        $joined | Should Match "--matlab-display-mode=nodesktop"
        $joined | Should Not Match "initialize-matlab-on-startup"
    }

    It "DisplayMode 为空时 auto 模式不输出 display-mode" {
        $built = New-MatlabMcpServerArgs -SessionMode "auto" -MatlabRoot "" -InitializeMatlabOnStartup $false -DisplayMode ""
        ($built.Arguments -join ";") | Should Be "--matlab-session-mode=auto"
    }

    It "Test-McpServerArgsCompatible 判定合法 existing 参数无违规" {
        $built = New-MatlabMcpServerArgs -SessionMode "existing" -MatlabRoot "C:\MATLAB" -InitializeMatlabOnStartup $true
        (Test-McpServerArgsCompatible -Arguments $built.Arguments).Count | Should Be 0
    }

    It "Test-McpServerArgsCompatible 能检出历史错误组合" {
        $bad = @("--matlab-session-mode=existing", "--matlab-display-mode=desktop")
        (Test-McpServerArgsCompatible -Arguments $bad).Count | Should Be 1
    }

    It "Get-MatlabMcpServerArgv 保持旧版扁平形状（向后兼容）" {
        $argv = Get-MatlabMcpServerArgv -ExePath "C:\bin\srv.exe" -SessionMode "existing" -MatlabRoot "C:\MATLAB"
        $argv[0] | Should Be "C:\bin\srv.exe"
        ($argv -join ";") | Should Not Match "display-mode"
    }
}

Describe "MCP 配置安全合并（P0-3：破坏性覆盖）" {

    It "保留用户已有的其它 MCP server 与顶层键" {
        $dir = New-TestDirectory
        try {
            $cfg = Join-Path $dir ".mcp.json"
            Write-Utf8NoBom -Path $cfg -Text '{"mcpServers":{"user-server":{"command":"node","args":["server.js"]}},"customTop":{"keep":true}}'

            $entry = [ordered]@{ command = "C:\bin\srv.exe"; args = @("--matlab-session-mode=auto") }
            $result = Merge-McpServerConfig -Path $cfg -RootProperty "mcpServers" -ServerName "matlab-official" -Entry $entry
            $result.Action | Should Be "created"
            $result.PreservedEntries | Should Be 1

            $parsed = Get-Content -Raw -LiteralPath $cfg | ConvertFrom-Json
            $parsed.mcpServers.'user-server'.command | Should Be "node"
            $parsed.mcpServers.'matlab-official'.command | Should Be "C:\bin\srv.exe"
            $parsed.customTop.keep | Should Be $true
        }
        finally { Remove-TestDirectory $dir }
    }

    It "重复写入相同条目返回 unchanged 且不产生备份" {
        $dir = New-TestDirectory
        try {
            $cfg = Join-Path $dir ".mcp.json"
            $entry = [ordered]@{ command = "C:\bin\srv.exe"; args = @("--matlab-session-mode=auto") }
            Merge-McpServerConfig -Path $cfg -RootProperty "mcpServers" -ServerName "matlab-official" -Entry $entry | Out-Null
            $backupRoot = Join-Path $dir "backups"
            $second = Merge-McpServerConfig -Path $cfg -RootProperty "mcpServers" -ServerName "matlab-official" -Entry $entry -BackupRoot $backupRoot
            $second.Action | Should Be "unchanged"
            $second.Changed | Should Be $false
            $second.BackupPath | Should BeNullOrEmpty
            (Test-Path -LiteralPath $backupRoot) | Should Be $false
        }
        finally { Remove-TestDirectory $dir }
    }

    It "参数变化时 updated 并生成备份文件" {
        $dir = New-TestDirectory
        try {
            $cfg = Join-Path $dir ".mcp.json"
            $old = [ordered]@{ command = "C:\bin\srv.exe"; args = @("--matlab-session-mode=auto", "--matlab-display-mode=desktop") }
            $new = [ordered]@{ command = "C:\bin\srv.exe"; args = @("--matlab-session-mode=existing") }
            Merge-McpServerConfig -Path $cfg -RootProperty "mcpServers" -ServerName "matlab-official" -Entry $old | Out-Null
            $result = Merge-McpServerConfig -Path $cfg -RootProperty "mcpServers" -ServerName "matlab-official" -Entry $new -BackupRoot (Join-Path $dir "backups")
            $result.Action | Should Be "updated"
            (Test-Path -LiteralPath $result.BackupPath) | Should Be $true
            (Get-Content -Raw -LiteralPath $result.BackupPath) | Should Match "matlab-display-mode"
        }
        finally { Remove-TestDirectory $dir }
    }

    It "配置文件 JSON 非法时中止且不改动原文件" {
        $dir = New-TestDirectory
        try {
            $cfg = Join-Path $dir ".mcp.json"
            $broken = '{ "mcpServers": { "a": { "command": "x" } , }'
            Write-Utf8NoBom -Path $cfg -Text $broken
            $before = [System.IO.File]::ReadAllBytes($cfg)

            $entry = [ordered]@{ command = "C:\bin\srv.exe"; args = @() }
            (Test-Throws { Merge-McpServerConfig -Path $cfg -RootProperty "mcpServers" -ServerName "matlab-official" -Entry $entry }) | Should Be $true

            $after = [System.IO.File]::ReadAllBytes($cfg)
            ($after -join ",") | Should Be ($before -join ",")
        }
        finally { Remove-TestDirectory $dir }
    }

    It "写出的 JSON 不带 BOM" {
        $dir = New-TestDirectory
        try {
            $cfg = Join-Path $dir ".mcp.json"
            $entry = [ordered]@{ command = "C:\bin\srv.exe"; args = @("a") }
            Merge-McpServerConfig -Path $cfg -RootProperty "mcpServers" -ServerName "matlab-official" -Entry $entry | Out-Null
            $bytes = [System.IO.File]::ReadAllBytes($cfg)
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should Be $false
        }
        finally { Remove-TestDirectory $dir }
    }

    It "DryRun 不写文件且返回 would_ 前缀动作" {
        $dir = New-TestDirectory
        try {
            $cfg = Join-Path $dir ".mcp.json"
            $entry = [ordered]@{ command = "C:\bin\srv.exe"; args = @("a") }
            $result = Merge-McpServerConfig -Path $cfg -RootProperty "mcpServers" -ServerName "matlab-official" -Entry $entry -DryRun
            $result.Action | Should Be "would_created"
            (Test-Path -LiteralPath $cfg) | Should Be $false
        }
        finally { Remove-TestDirectory $dir }
    }

    It "单元素 args 仍写成数组（不塌缩成字符串）" {
        $dir = New-TestDirectory
        try {
            $cfg = Join-Path $dir ".mcp.json"
            $entry = [ordered]@{ command = "C:\bin\srv.exe"; args = @("--matlab-session-mode=existing") }
            Merge-McpServerConfig -Path $cfg -RootProperty "mcpServers" -ServerName "matlab-official" -Entry $entry | Out-Null
            (Get-Content -Raw -LiteralPath $cfg) | Should Match '"args":\s*\['
        }
        finally { Remove-TestDirectory $dir }
    }
}

Describe "skills 冲突判定（P0-5：破坏性覆盖）" {

    It "目标不存在时返回 install" {
        Get-SkillSyncDecision -SourceHash "AAA" -DestinationHash $null -IsManaged $false -Force $false | Should Be "install"
    }

    It "哈希一致时返回 unchanged" {
        Get-SkillSyncDecision -SourceHash "AAA" -DestinationHash "AAA" -IsManaged $true -Force $false | Should Be "unchanged"
    }

    It "非托管目录内容不同时返回 conflict" {
        Get-SkillSyncDecision -SourceHash "AAA" -DestinationHash "BBB" -IsManaged $false -Force $false | Should Be "conflict"
    }

    It "托管目录内容不同时返回 update" {
        Get-SkillSyncDecision -SourceHash "AAA" -DestinationHash "BBB" -IsManaged $true -Force $false | Should Be "update"
    }

    It "非托管目录加 -Force 时允许 update" {
        Get-SkillSyncDecision -SourceHash "AAA" -DestinationHash "BBB" -IsManaged $false -Force $true | Should Be "update"
    }

    It "目录指纹与路径无关，内容变化则变化" {
        $a = New-TestDirectory
        $b = New-TestDirectory
        try {
            Write-Utf8NoBom -Path (Join-Path $a "SKILL.md") -Text "hello"
            Write-Utf8NoBom -Path (Join-Path $b "SKILL.md") -Text "hello"
            (Get-DirectoryTreeHash -Path $a) | Should Be (Get-DirectoryTreeHash -Path $b)

            Write-Utf8NoBom -Path (Join-Path $b "SKILL.md") -Text "hello2"
            (Get-DirectoryTreeHash -Path $a) | Should Not Be (Get-DirectoryTreeHash -Path $b)
        }
        finally {
            Remove-TestDirectory $a
            Remove-TestDirectory $b
        }
    }
}

Describe "startup.m 托管块（P0-6：无备份的隐式改写）" {

    It "首次写入创建托管块并保留用户已有内容" {
        $dir = New-TestDirectory
        try {
            $startup = Join-Path $dir "startup.m"
            Write-Utf8NoBom -Path $startup -Text "disp('user line');"
            $result = Merge-StartupShareFile -Path $startup -BackupRoot (Join-Path $dir "backups")
            $result.Action | Should Be "appended"
            $content = [System.IO.File]::ReadAllText($startup)
            $content | Should Match "disp\('user line'\);"
            $content | Should Match "shareMATLABSession"
        }
        finally { Remove-TestDirectory $dir }
    }

    It "重复执行返回 unchanged 且内容逐字节不变（幂等）" {
        $dir = New-TestDirectory
        try {
            $startup = Join-Path $dir "startup.m"
            Write-Utf8NoBom -Path $startup -Text "disp('user line');"
            Merge-StartupShareFile -Path $startup -BackupRoot (Join-Path $dir "backups") | Out-Null
            $first = [System.IO.File]::ReadAllText($startup)
            $second = Merge-StartupShareFile -Path $startup -BackupRoot (Join-Path $dir "backups")
            $after = [System.IO.File]::ReadAllText($startup)
            $second.Action | Should Be "unchanged"
            $after.Length | Should Be $first.Length
            $after | Should Be $first
            ([regex]::Matches($after, "BEGIN matlab-agent-skills")).Count | Should Be 1
        }
        finally { Remove-TestDirectory $dir }
    }

    It "用户自己已有 shareMATLABSession 调用时不覆盖" {
        $dir = New-TestDirectory
        try {
            $startup = Join-Path $dir "startup.m"
            Write-Utf8NoBom -Path $startup -Text "shareMATLABSession();"
            $result = Merge-StartupShareFile -Path $startup -BackupRoot (Join-Path $dir "backups")
            $result.Action | Should Be "skipped-foreign-hook"
            ([System.IO.File]::ReadAllText($startup)).Trim() | Should Be "shareMATLABSession();"
        }
        finally { Remove-TestDirectory $dir }
    }

    It "DryRun 不落盘" {
        $dir = New-TestDirectory
        try {
            $startup = Join-Path $dir "startup.m"
            $result = Merge-StartupShareFile -Path $startup -DryRun
            $result.Action | Should Be "would-created"
            (Test-Path -LiteralPath $startup) | Should Be $false
        }
        finally { Remove-TestDirectory $dir }
    }
}

Describe "备份与回滚（P0-6）" {

    It "文件备份后可逐字节还原" {
        $dir = New-TestDirectory
        try {
            $file = Join-Path $dir "config.json"
            Write-Utf8NoBom -Path $file -Text '{"a":1}'
            $session = New-BackupSession -Root (Join-Path $dir "backups") -Reason "unit"
            Save-FileBackupToSession -Session $session -Path $file -Label "config" | Out-Null
            Write-Utf8NoBom -Path $file -Text '{"a":2}'

            $rollback = Invoke-BackupRollback -Session $session
            $rollback.RolledBack | Should Be $true
            ((Get-Content -Raw -LiteralPath $file).Trim()) | Should Be '{"a":1}'
        }
        finally { Remove-TestDirectory $dir }
    }

    It "回滚会删除新建文件" {
        $dir = New-TestDirectory
        try {
            $file = Join-Path $dir "new.txt"
            $session = New-BackupSession -Root (Join-Path $dir "backups") -Reason "unit"
            Save-FileBackupToSession -Session $session -Path $file -Label "new" | Out-Null
            Write-Utf8NoBom -Path $file -Text "created"
            Invoke-BackupRollback -Session $session | Out-Null
            (Test-Path -LiteralPath $file) | Should Be $false
        }
        finally { Remove-TestDirectory $dir }
    }

    It "目录备份后可整体还原" {
        $dir = New-TestDirectory
        try {
            $target = Join-Path $dir "skill"
            Write-Utf8NoBom -Path (Join-Path $target "SKILL.md") -Text "original"
            $session = New-BackupSession -Root (Join-Path $dir "backups") -Reason "unit"
            Save-DirectoryBackupToSession -Session $session -Path $target -Label "skill" | Out-Null
            Write-Utf8NoBom -Path (Join-Path $target "SKILL.md") -Text "changed"

            Invoke-BackupRollback -Session $session | Out-Null
            ((Get-Content -Raw -LiteralPath (Join-Path $target "SKILL.md")).Trim()) | Should Be "original"
        }
        finally { Remove-TestDirectory $dir }
    }

    It "备份清单 record 数与操作数一致" {
        $dir = New-TestDirectory
        try {
            $file = Join-Path $dir "a.json"
            Write-Utf8NoBom -Path $file -Text "{}"
            $session = New-BackupSession -Root (Join-Path $dir "backups") -Reason "unit"
            Save-FileBackupToSession -Session $session -Path $file -Label "a" | Out-Null
            Save-FileBackupToSession -Session $session -Path (Join-Path $dir "missing.json") -Label "b" | Out-Null
            Save-BackupManifest -Session $session
            (Test-Path -LiteralPath $session.ManifestPath) | Should Be $true
            $manifest = Get-Content -Raw -LiteralPath $session.ManifestPath | ConvertFrom-Json
            @($manifest.records).Count | Should Be 2
        }
        finally { Remove-TestDirectory $dir }
    }

    It "无任何变更时不创建备份目录（重复安装零写入）" {
        $dir = New-TestDirectory
        try {
            $session = New-BackupSession -Root (Join-Path $dir "backups") -Reason "noop"
            Save-BackupManifest -Session $session
            (Test-Path -LiteralPath $session.Directory) | Should Be $false
        }
        finally { Remove-TestDirectory $dir }
    }
}

Describe "客户端注册解析与幂等判定" {

    It "能从 mcp get 输出解析 command 与 args" {
        $text = @"
matlab-official
  enabled: true
  transport: stdio
  command: C:\bin\matlab-mcp-server.exe
  args: --matlab-session-mode=auto --matlab-display-mode=desktop
"@
        $parsed = ConvertFrom-ClientMcpGetText -Text $text
        $parsed.Command | Should Be "C:\bin\matlab-mcp-server.exe"
        ($parsed.Arguments -join ";") | Should Be "--matlab-session-mode=auto;--matlab-display-mode=desktop"
    }

    It "参数完全一致时判定为已注册（幂等）" {
        $text = "command: C:\bin\srv.exe`nargs: --matlab-session-mode=existing"
        (Test-ClientRegistrationMatch -ExistingText $text -ServerArgs @("C:\bin\srv.exe", "--matlab-session-mode=existing")) | Should Be $true
    }

    It "参数不一致时判定为需要更新" {
        $text = "command: C:\bin\srv.exe`nargs: --matlab-session-mode=auto"
        (Test-ClientRegistrationMatch -ExistingText $text -ServerArgs @("C:\bin\srv.exe", "--matlab-session-mode=existing")) | Should Be $false
    }
}

Describe "下载安全（P0-6：无校验远程下载）" {

    It "拒绝非 HTTPS 下载地址" {
        $dir = New-TestDirectory
        try {
            (Test-Throws { Save-VerifiedDownload -Uri "http://example.com/a.exe" -Destination (Join-Path $dir "a.exe") }) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $dir "a.exe")) | Should Be $false
        }
        finally { Remove-TestDirectory $dir }
    }

    It "SHA256 比较忽略大小写与分隔符" {
        $expected = "aa,bb"
        (Test-HashMatch -Expected $expected -Actual "AABB") | Should Be $true
        (Test-HashMatch -Expected "AABB" -Actual "AABC") | Should Be $false
    }

    It "DryRun 下载不产生文件" {
        $dir = New-TestDirectory
        try {
            $dest = Join-Path $dir "srv.exe"
            $result = Save-VerifiedDownload -Uri "https://example.com/a.exe" -Destination $dest -DryRun
            $result.Downloaded | Should Be $false
            (Test-Path -LiteralPath $dest) | Should Be $false
        }
        finally { Remove-TestDirectory $dir }
    }
}

Describe "仓库卫生（P0-7：机器专属路径与编码）" {

    # 旧测试名（历史失败文本，保留以便检索）：仓库里没有 E:/D: 盘符硬编码路径。
    # 旧名里的 “E:/D:” 是规则名/散文，不是路径：Windows 路径段里冒号非法，
    # 所以下面谓词要求分隔符后不能紧跟“字母:”，而真正的正斜杠盘符路径照常命中。
    It "仓库里没有盘符硬编码路径（E 盘 / D 盘）" {
        # 动态拼 pattern，避免测试文件自身命中。
        # 盘符必须处于“路径起点”上下文：左侧不能粘着单词字符（否则 name:\s
        # 这类转义序列会误报），右侧不能是另一个“字母:”盘符标记（散文写法）。
        # 大小写不敏感是故意的：小写盘符同样是机器专属路径。
        $drivePattern = "(?<![A-Za-z0-9_])[" + [char]69 + [char]68 + "]:[\\/](?![A-Za-z]:)"

        # 谓词自检：真盘符必须命中，转义序列与其他盘符必须不命中。
        # 样本同样动态拼装，避免本测试文件自己变成第 0 个命中。
        $colon = [string][char]58
        $sep = [string][char]92
        $E = [string][char]69
        $D = [string][char]68
        $C = [string][char]67
        $positiveSamples = @(
            ($E + $colon + $sep + "desktop" + $sep + "MATLAB"),
            ($D + $colon + $sep + "Temp" + $sep + "x.m"),
            ("e" + $colon + $sep + "desktop"),
            ($E + $colon + "/desktop"),
            ("--out=" + $D + $colon + $sep + "out")
        )
        $negativeSamples = @(
            ("name" + $colon + $sep + "s*(matlab-"),
            ("allowed" + $colon + $sep + "n"),
            ($C + $colon + $sep + "Windows"),
            # 约定名/散文写法：“X:/Y:” 不是路径（路径段里不能有冒号）。
            ($E + $colon + "/" + $D + $colon)
        )
        foreach ($sample in $positiveSamples) {
            ([bool]($sample | Select-String -Pattern $drivePattern -AllMatches)) | Should Be $true
        }
        foreach ($sample in $negativeSamples) {
            ([bool]($sample | Select-String -Pattern $drivePattern -AllMatches)) | Should Be $false
        }

        # “仓库里”只指仓库真正分发的内容：git 忽略的本机文件（.mcp.json、
        # .workbuddy/、.codex/ 等）是本机状态、不随仓库分发，不是仓库里的硬编码
        # 路径。不在 git 工作区时（例如从源码压缩包运行）退回全量遍历 + 显式排除。
        $tracked = @{}
        Push-Location -LiteralPath $script:RepoRoot
        try {
            $listing = & git ls-files -z 2>$null
            if ($LASTEXITCODE -eq 0 -and $listing) {
                foreach ($relativePath in (($listing -join "") -split [string][char]0)) {
                    if ($relativePath) { $tracked[($relativePath -replace "\\", "/")] = $true }
                }
            }
        }
        catch {
            $tracked = @{}
        }
        finally { Pop-Location }

        $files = Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -File |
            Where-Object { $_.FullName -notmatch "[\\/]\.(git|workbuddy|codex|vscode)[\\/]" } |
            Where-Object { $_.Name -ne ".mcp.json" -and $_.FullName -notmatch "[\\/]artifacts[\\/]" -and $_.FullName -notmatch "[\\/]bin[\\/]" } |
            Where-Object { $_.Extension -in @(".ps1", ".psm1", ".m", ".md", ".json", ".yml", ".yaml") }
        if ($tracked.Count -gt 0) {
            $files = $files | Where-Object {
                $tracked.ContainsKey(($_.FullName.Substring($script:RepoRoot.Length + 1) -replace "\\", "/"))
            }
        }

        $hits = @()
        foreach ($file in $files) {
            $matches = Select-String -LiteralPath $file.FullName -Pattern $drivePattern -AllMatches -ErrorAction SilentlyContinue
            if ($matches) { $hits += $matches }
        }
        $summary = ($hits | ForEach-Object { "$($_.Filename):$($_.LineNumber)" }) -join ";"
        # 失败信息里带上扫描模式与文件数：走 git 列表和走文件系统遍历的排除项
        # 不同，不写清楚就无法判断这次失败到底扫了什么。
        if ($summary) {
            $scanMode = if ($tracked.Count -gt 0) { "git-tracked" } else { "filesystem-walk" }
            $summary = "$summary [scan=$scanMode; files=$(@($files).Count)]"
        }
        $summary | Should Be ""
    }

    It "所有 PowerShell 脚本都能被 Windows PowerShell 5.1 解析" {
        $errors = @()
        $scripts = Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot "scripts") -Recurse -File |
            Where-Object { $_.Extension -in @(".ps1", ".psm1") }
        foreach ($script in $scripts) {
            $tokens = $null
            $parseErrors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
            if ($parseErrors) { $errors += "$($script.Name): $($parseErrors[0].Message)" }
        }
        ($errors -join "; ") | Should Be ""
    }

    It "含非 ASCII 字符的脚本带 UTF-8 BOM（PS5.1 正确解码的前提）" {
        $missing = @()
        $scripts = Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot "scripts") -Recurse -File |
            Where-Object { $_.Extension -in @(".ps1", ".psm1") }
        foreach ($script in $scripts) {
            $bytes = [System.IO.File]::ReadAllBytes($script.FullName)
            $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
            $text = [System.IO.File]::ReadAllText($script.FullName)
            $hasNonAscii = [bool]($text -match "[^\x00-\x7F]")
            if ($hasNonAscii -and -not $hasBom) { $missing += $script.Name }
        }
        ($missing -join "; ") | Should Be ""
    }
}
