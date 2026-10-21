<#
.SYNOPSIS
MCP server 供应链：固定版本清单、完整性 vs 来源验证、fail-closed 与篡改/截断/断网回归。
不下载真实二进制；只用本机回环 TCP 服务模拟下载源。
#>
. (Join-Path $PSScriptRoot 'helpers/Assertions.ps1')
$global:MasTestRepoRoot = Split-Path -Parent $PSScriptRoot
$coreModule = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/MatlabAgentSkills.Core.psm1'
Import-Module $coreModule -Force -DisableNameChecking

InModuleScope MatlabAgentSkills.Core {
    function New-SupplyChainSandbox {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('mas-supply-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'config') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'scripts') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'bin') -Force | Out-Null
        [pscustomobject]@{ Root = $root; ScriptRoot = (Join-Path $root 'scripts'); Bin = (Join-Path $root 'bin'); Config = (Join-Path $root 'config') }
    }
    function Remove-SupplyChainSandbox {
        param($Sandbox)
        $full = [IO.Path]::GetFullPath($Sandbox.Root)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
        if (-not $full.StartsWith($temp) -or (Split-Path -Leaf $full) -notlike 'mas-supply-*') { throw '测试清理路径越界。' }
        Remove-Item -LiteralPath $full -Recurse -Force
    }
    function Write-TestManifest {
        param($Sandbox, [string]$Sha, [int64]$Bytes, [string]$Tag = 'v0.15.0', [string]$Url = '')
        if (-not $Url) { $Url = "https://example.invalid/releases/download/$Tag/matlab-mcp-server-windows-x64.exe" }
        $data = [ordered]@{
            schema = 'mas-mcp-server-manifest/1'
            upstream = [ordered]@{ repository = 'https://example.invalid'; releaseTag = $Tag }
            assets = [ordered]@{
                'matlab-mcp-server-windows-x64.exe' = [ordered]@{ platform = 'windows'; releaseTag = $Tag; url = $Url; sha256 = $Sha; bytes = $Bytes }
            }
        }
        [IO.File]::WriteAllText((Join-Path $Sandbox.Config 'mcp-server-manifest.json'), ($data | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    }
    Describe 'MCP server 供应链：固定清单与 fail-closed' {
        It '仓库清单固定到具体 release tag，且不含 moving latest' {
            $repo = $global:MasTestRepoRoot
            $manifest = Join-Path $repo 'config/mcp-server-manifest.json'
            (Test-Path -LiteralPath $manifest) | Should Be $true
            $raw = [IO.File]::ReadAllText($manifest)
            $data = $raw | ConvertFrom-Json
            ($data.upstream.releaseTag -match '^v\d+\.\d+\.\d+$') | Should Be $true
            @($data.assets.PSObject.Properties.Value.url | Where-Object { $_ -match 'releases/latest' }).Count | Should Be 0
            $win = $data.assets.'matlab-mcp-server-windows-x64.exe'
            ($win.sha256 -match '^[A-Fa-f0-9]{64}$') | Should Be $true
            ([int64]$win.bytes -gt 1000000) | Should Be $true
            ($win.url -match "/releases/download/$($data.upstream.releaseTag)/") | Should Be $true
        }

        It '清单缺失时解析器 fail closed，并给出手动安装指引' {
            $s = New-SupplyChainSandbox
            try {
                $threw = $false; $message = ''
                try { Resolve-McpServerExecutable -ScriptRoot $s.ScriptRoot -NoDownload | Out-Null }
                catch { $threw = $true; $message = $_.Exception.Message }
                $threw | Should Be $true
                ($message -match 'release|手动安装') | Should Be $true
            }
            finally { Remove-SupplyChainSandbox $s }
        }

        It '平台条目缺失时拒绝猜测下载地址' {
            $s = New-SupplyChainSandbox
            try {
                [IO.File]::WriteAllText((Join-Path $s.Config 'mcp-server-manifest.json'),
                    '{"schema":"mas-mcp-server-manifest/1","upstream":{"releaseTag":"v0.15.0"},"assets":{}}')
                $threw = $false
                try { Resolve-McpServerExecutable -ScriptRoot $s.ScriptRoot -NoDownload | Out-Null } catch { $threw = $true }
                $threw | Should Be $true
            }
            finally { Remove-SupplyChainSandbox $s }
        }

        It '清单 URL 与 releaseTag 不一致时判为清单缺陷' {
            $s = New-SupplyChainSandbox
            try {
                Write-TestManifest -Sandbox $s -Sha ('A' * 64) -Bytes 12345 -Url 'https://example.invalid/releases/download/v0.14.0/x.exe'
                $threw = $false
                try { Resolve-McpServerExecutable -ScriptRoot $s.ScriptRoot -NoDownload | Out-Null } catch { $threw = $true }
                $threw | Should Be $true
            }
            finally { Remove-SupplyChainSandbox $s }
        }

        It '已有二进制哈希不匹配时拒绝使用（可被 -ForceDownload 覆盖）' {
            $s = New-SupplyChainSandbox
            try {
                $bin = Join-Path $s.Bin 'matlab-mcp-server-windows-x64.exe'
                [IO.File]::WriteAllBytes($bin, [Text.Encoding]::ASCII.GetBytes('tampered-not-the-real-binary'))
                Write-TestManifest -Sandbox $s -Sha ('B' * 64) -Bytes 12345
                $threw = $false
                try { Resolve-McpServerExecutable -ScriptRoot $s.ScriptRoot -NoDownload | Out-Null } catch { $threw = $true }
                $threw | Should Be $true
            }
            finally { Remove-SupplyChainSandbox $s }
        }

        It '完整性与来源验证是两个不同状态' {
            $s = New-SupplyChainSandbox
            try {
                $bin = Join-Path $s.Bin 'matlab-mcp-server-windows-x64.exe'
                [IO.File]::WriteAllBytes($bin, [Text.Encoding]::ASCII.GetBytes('payload-for-integrity-test'))
                $sha = (Get-FileSha256 -Path $bin).ToUpperInvariant()
                $asset = [pscustomobject]@{ Name = 'x'; Url = 'https://example.invalid/x'; Sha256 = $sha; Bytes = (Get-Item $bin).Length; ReleaseTag = 'v0.15.0' }
                $ok = Get-McpServerIntegrity -Path $bin -Asset $asset
                $ok.Hashed | Should Be $true
                $ok.Verified | Should Be $true
                $ok.IntegrityStatus | Should Be 'VERIFIED_AGAINST_MANIFEST'
                $other = [pscustomobject]@{ Name = 'x'; Url = 'https://example.invalid/x'; Sha256 = ('C' * 64); Bytes = 1; ReleaseTag = 'v0.15.0' }
                $bad = Get-McpServerIntegrity -Path $bin -Asset $other
                $bad.Hashed | Should Be $true
                $bad.Verified | Should Be $false
                $bad.IntegrityStatus | Should Be 'HASH_MISMATCH'
            }
            finally { Remove-SupplyChainSandbox $s }
        }

        It '显式 -AllowUnverifiedServer 才放行，且状态必须记为未验证' {
            $s = New-SupplyChainSandbox
            try {
                $bin = Join-Path $s.Bin 'matlab-mcp-server-windows-x64.exe'
                [IO.File]::WriteAllBytes($bin, [Text.Encoding]::ASCII.GetBytes('not-the-official-binary'))
                Write-TestManifest -Sandbox $s -Sha ('D' * 64) -Bytes 12345
                $server = Resolve-McpServerExecutable -ScriptRoot $s.ScriptRoot -NoDownload -AllowUnverifiedServer
                $server.Verified | Should Be $false
                $server.IntegrityStatus | Should Be 'UNVERIFIED_ACCEPTED_BY_OPERATOR'
                $server.Hashed | Should Be $true
            }
            finally { Remove-SupplyChainSandbox $s }
        }

        It 'Verified=false 时 Assert-McpServerTrusted 拒绝继续' {
            $fake = [pscustomobject]@{ Path = 'x'; Sha256 = ('E' * 64); Verified = $false }
            $threw = $false
            try { Assert-McpServerTrusted -Server $fake 3>$null } catch { $threw = $true }
            $threw | Should Be $true
            $threwWithFlag = $false
            try { Assert-McpServerTrusted -Server $fake -AllowUnverifiedServer 3>$null } catch { $threwWithFlag = $true }
            $threwWithFlag | Should Be $false
        }

        It 'Test-DownloadIntegrity 覆盖截断/大小/哈希/无摘要四种拒绝' {
            (Test-DownloadIntegrity -Bytes 10 -Sha256 ('A' * 64) -MinimumBytes 1024).Reason | Should Be 'TOO_SMALL'
            (Test-DownloadIntegrity -Bytes 2048 -Sha256 ('A' * 64) -ExpectedBytes 4096 -ExpectedSha256 ('A' * 64)).Reason | Should Be 'SIZE_MISMATCH'
            (Test-DownloadIntegrity -Bytes 2048 -Sha256 ('A' * 64) -ExpectedSha256 ('B' * 64)).Reason | Should Be 'HASH_MISMATCH'
            (Test-DownloadIntegrity -Bytes 2048 -Sha256 ('A' * 64)).Reason | Should Be 'NO_EXPECTED_DIGEST'
            (Test-DownloadIntegrity -Bytes 2048 -Sha256 ('A' * 64) -ExpectedSha256 ('A' * 64)).Ok | Should Be $true
        }

        It '下载被截断（声明长度大于实际）时 Test-DownloadIntegrity 判为 SIZE_MISMATCH' {
            # 截断下载在 Save-VerifiedDownload 里由同一判据拦截：字节数不符即拒绝并丢弃。
            (Test-DownloadIntegrity -Bytes 2048 -Sha256 ('A' * 64) -ExpectedBytes 999999 -ExpectedSha256 ('A' * 64)).Reason | Should Be 'SIZE_MISMATCH'
        }

        It '文件被篡改（哈希不符）时判为 HASH_MISMATCH' {
            (Test-DownloadIntegrity -Bytes 2048 -Sha256 ('A' * 64) -ExpectedBytes 2048 -ExpectedSha256 ('B' * 64)).Reason | Should Be 'HASH_MISMATCH'
        }
        It '网络不可用时报错且不产生目标文件' {
            $dest = Join-Path ([IO.Path]::GetTempPath()) ('mas-dl-' + [guid]::NewGuid().ToString('N') + '.bin')
            $threw = $false
            try { Save-VerifiedDownload -Uri 'https://127.0.0.1:1/matlab-mcp-server-windows-x64.exe' -Destination $dest -ExpectedSha256 ('F' * 64) | Out-Null }
            catch { $threw = $true }
            $threw | Should Be $true
            (Test-Path -LiteralPath $dest) | Should Be $false
        }
    }
}
