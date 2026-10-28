<#
.SYNOPSIS
凭据脱敏的形状回归：真实泄露发生在“转义 JSON / 请求头 / argv / 裸令牌”这些形态上。

.DESCRIPTION
Phase 5.8 的泄露不是明文 JSON 字段，而是客户端事件流里被再次转义的
`\"apiKey\": \"...\"`，以及 agent 自己的命令行（`Get-Content sessionDetails.json`）。
旧实现只覆盖 `"apiKey": "..."` 与 `apiKey=...`，因此这里把六种形态钉成回归：

1. 普通 JSON 字段；
2. 转义 / 嵌套 JSON（一层或多层反斜杠）；
3. `x-api-key:` 请求头；
4. `Authorization: Bearer ...`；
5. `--api-key <v>` / `--api-key=<v>` 命令行；
6. 裸 UUID 或 >=32 位十六进制令牌。

同时验证：已知密钥字面值替换保持有效、无敏感文本逐字节不变、二次脱敏幂等。
#>

. (Join-Path $PSScriptRoot 'helpers/Assertions.ps1')

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $script:RepoRoot 'scripts/MatlabAgentSkills.Core.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $script:RepoRoot 'scripts/MatlabAgentSkills.McpStdio.psm1') -Force -DisableNameChecking
. (Join-Path $script:RepoRoot 'scripts/Start-MatlabSharedSession.ps1')

$script:FakeUuid = '11111111-2222-3333-4444-555555555555'
$script:FakeHex = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
$script:FakeBearer = 'FAKEBEARERTOKEN0123456789'
$script:FakeArgv = 'FAKEARGVTOKEN0123456789'
$script:FakeHeader = 'FAKEXAPIKEY0123456789'
$script:FakeJson = 'FAKEJSONVALUE0123456789'

function Get-SanitizedText {
    param([string]$Text)
    return (Protect-MasText -Text $Text)
}

Describe '统一脱敏函数覆盖真实泄露形态' {
    It '普通 JSON 字段值被替换' {
        $safe = Get-SanitizedText ('{"apiKey":"' + $script:FakeJson + '","port":47823}')
        $safe | Should Not Match ([regex]::Escape($script:FakeJson))
        $safe | Should Match '\[REDACTED'
        $safe | Should Match '47823'
    }

    It '转义 / 嵌套 JSON 字段值被替换（Phase 5.8 的泄露形状）' {
        $escaped = '{\"type\":\"item.completed\",\"aggregated_output\":\"{\\\"apiKey\\\": \\\"' + $script:FakeJson + '\\\"}\"}'
        $safe = Get-SanitizedText $escaped
        $safe | Should Not Match ([regex]::Escape($script:FakeJson))
        $safe | Should Match '\[REDACTED'

        $single = '{"output":"{\"apiKey\":\"' + $script:FakeJson + '\"}"}'
        $singleSafe = Get-SanitizedText $single
        $singleSafe | Should Not Match ([regex]::Escape($script:FakeJson))
    }

    It 'x-api-key 请求头被替换' {
        $safe = Get-SanitizedText ('x-api-key: ' + $script:FakeHeader)
        $safe | Should Not Match ([regex]::Escape($script:FakeHeader))
        $safe | Should Match '\[REDACTED'
    }

    It 'Authorization Bearer 与 Basic 被替换' {
        $safe = Get-SanitizedText ('Authorization: Bearer ' + $script:FakeBearer + "`nAuthorization: Basic " + $script:FakeBearer)
        $safe | Should Not Match ([regex]::Escape($script:FakeBearer))
        $safe | Should Match '\[REDACTED'
    }

    It '--api-key 的两种命令行写法都被替换' {
        $safe = Get-SanitizedText ('tool --api-key ' + $script:FakeArgv + ' --api-key=' + $script:FakeArgv + ' --other=ok')
        $safe | Should Not Match ([regex]::Escape($script:FakeArgv))
        $safe | Should Match '\[REDACTED'
        $safe | Should Match '--other=ok'
    }

    It '裸 UUID 与长十六进制令牌被替换' {
        $safe = Get-SanitizedText ('session=' + $script:FakeUuid + ' digest=' + $script:FakeHex)
        $safe | Should Not Match ([regex]::Escape($script:FakeUuid))
        $safe | Should Not Match ([regex]::Escape($script:FakeHex))
        $safe | Should Match '\[REDACTED'
    }

    It '已知密钥字面值（含短值）仍被替换' {
        $text = 'token value SECRET-LITERAL-123 appears here'
        $safe = Protect-MasText -Text $text -Secrets @('SECRET-LITERAL-123')
        $safe | Should Not Match 'SECRET-LITERAL-123'
        $safe | Should Match '\[REDACTED'
    }

    It '无敏感内容的文本逐字节不变' {
        $control = 'MATLAB R2026a determinant=-4.0 eigenvalue=3.414214 elapsed=1.25s'
        $safe = Get-SanitizedText $control
        ([string]::Equals($safe, $control, [System.StringComparison]::Ordinal)) | Should Be $true
    }

    It '二次脱敏幂等' {
        $text = 'Authorization: Bearer ' + $script:FakeBearer + '; apiKey=' + $script:FakeJson + '; id=' + $script:FakeUuid
        $once = Get-SanitizedText $text
        $twice = Get-SanitizedText $once
        ([string]::Equals($once, $twice, [System.StringComparison]::Ordinal)) | Should Be $true
    }
}

Describe '安全输出保留 JSON 结构与正常数据' {
    It '同一结构中先出现的普通诊断不能回显后出现的凭据值' {
        $source = '{"diagnostic":"repeated SYNTHETIC-REPEATED-KEY","nested":{"apiKey":"SYNTHETIC-REPEATED-KEY"},"value":1.25}'
        $safe = Protect-MasText -Text $source
        $safe | Should Not Match 'SYNTHETIC-REPEATED-KEY'
        ($safe | ConvertFrom-Json).value | Should Be 1.25
    }

    It '常见大小写、分隔符及环境变量字段使用同一规则' {
        foreach ($key in @('API_KEY', 'Api-Key', 'X_MCP_API_KEY', 'xMcpApiKey', 'PASSWD', 'GH_TOKEN', 'AWS_SECRET_ACCESS_KEY', 'MATLAB_MCP_API_KEY')) {
            $value = @{}; $value[$key] = 'SYNTHETIC-ALIAS-CREDENTIAL'
            (Protect-MasText -Text ($value | ConvertTo-Json -Compress)) | Should Not Match 'SYNTHETIC-ALIAS-CREDENTIAL'
        }
    }

    It '普通输出中的独立令牌仍受保护，协议 id 采用独立上下文' {
        $value = @{ output = $script:FakeHex; id = $script:FakeUuid }
        $safe = Protect-MasValue -Value $value
        $safe.output | Should Not Match ([regex]::Escape($script:FakeHex))
        $safe.id | Should Be $script:FakeUuid
    }

    It '嵌套对象、数组和非字符串敏感值不泄漏且仍是合法 JSON' {
        $payload = [ordered]@{
            jsonrpc = '2.0'; id = 7
            result = [ordered]@{
                matrix = @(@(1, 2), @(3, 4)); path = 'C:/models/normal.slx'
                nested = @(@{ 'X-MCP-API-KEY' = 'SYNTHETIC-NESTED-CREDENTIAL-A'; secret = @{ value = 'SYNTHETIC-NESTED-CREDENTIAL-B' } })
            }
        }
        $safe = Protect-MasText -Text ($payload | ConvertTo-Json -Depth 12 -Compress)
        $safe | Should Not Match 'SYNTHETIC-NESTED-CREDENTIAL'
        $parsed = $safe | ConvertFrom-Json
        $parsed.jsonrpc | Should Be '2.0'
        $parsed.id | Should Be 7
        $parsed.result.matrix[1][0] | Should Be 3
        $parsed.result.path | Should Be 'C:/models/normal.slx'
    }

    It 'Unicode 转义字段名和值在结构化边界被识别' {
        $safe = Protect-MasText -Text '{"\u0061piKey":"SYNTHETIC-UNICODE-CREDENTIAL","value":3.14159}'
        $safe | Should Not Match 'SYNTHETIC-UNICODE-CREDENTIAL'
        ($safe | ConvertFrom-Json).value | Should Be 3.14159
    }

    It '已知短秘密及其 URL 编码不通过普通诊断泄漏' {
        $safe = Protect-MasText -Text 'detail p4! encoded=p4%21' -Secrets @('p4!')
        $safe | Should Not Match 'p4!|p4%21'
    }

    It '协议 JSON 中的请求标识、摘要和空数组保持不变' {
        $source = '{"jsonrpc":"2.0","id":"11111111-2222-3333-4444-555555555555","result":{"sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","values":[],"optional":null}}'
        $safe = Protect-MasText -Text $source
        ([string]::Equals($safe, $source, [StringComparison]::Ordinal)) | Should Be $true
    }

    It '明确保留标识的诊断模式仍移除敏感字段' {
        $safe = Protect-MasText -Text ('matrix=[1 2;3 4] sha256=' + $script:FakeHex + '; password=SYNTHETIC-PASSWORD') -PreserveIdentifiers
        $safe | Should Match ([regex]::Escape($script:FakeHex))
        $safe | Should Match 'matrix=\[1 2;3 4\]'
        $safe | Should Not Match 'SYNTHETIC-PASSWORD'
    }

    It '嵌套异常保持可诊断且秘密不进入序列化结果' {
        $inner = New-Object System.Exception('password=SYNTHETIC-INNER-PASSWORD')
        $outer = New-Object System.Exception('request failed', $inner)
        $safe = Protect-MasValue -Value $outer
        $json = $safe | ConvertTo-Json -Depth 12
        $json | Should Not Match 'SYNTHETIC-INNER-PASSWORD'
        $json | Should Match 'request failed'
    }
}

Describe '既有入口委托到统一实现后不再漏' {
    It 'Protect-McpSensitiveText 覆盖转义 JSON / Bearer / argv / 裸 UUID' {
        $text = '{\"apiKey\":\"' + $script:FakeJson + '\"}; Authorization: Bearer ' + $script:FakeBearer + '; --api-key ' + $script:FakeArgv + '; ' + $script:FakeUuid
        $safe = Protect-McpSensitiveText -Text $text
        foreach ($secret in @($script:FakeJson, $script:FakeBearer, $script:FakeArgv, $script:FakeUuid)) {
            $safe | Should Not Match ([regex]::Escape($secret))
        }
    }

    It 'Protect-MasSecretText 覆盖转义 JSON / Bearer / argv / 裸 UUID' {
        $text = '{\"apiKey\":\"' + $script:FakeJson + '\"}; Authorization: Bearer ' + $script:FakeBearer + '; --api-key=' + $script:FakeArgv + '; ' + $script:FakeUuid
        $safe = Protect-MasSecretText -Text $text
        foreach ($secret in @($script:FakeJson, $script:FakeBearer, $script:FakeArgv, $script:FakeUuid)) {
            $safe | Should Not Match ([regex]::Escape($secret))
        }
        $safe | Should Match '\[REDACTED'
    }
}
