$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $repo 'scripts\MatlabAgentSkills.McpProbe.psm1') -Force -DisableNameChecking

$anchor = @(Get-ChildItem -LiteralPath 'Cert:\LocalMachine\Root' -ErrorAction SilentlyContinue | Select-Object -First 1)
Write-Host ('anchor_count=' + $anchor.Count)
if ($anchor.Count -eq 0) { return }

$der = $anchor[0].Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
Write-Host ('der_bytes=' + $der.Length)
$b64 = [convert]::ToBase64String($der)
$pem = '-----BEGIN CERTIFICATE-----' + "`r`n" + ($b64 -replace '(.{64})', ('$1' + "`r`n")) + "`r`n" + '-----END CERTIFICATE-----' + "`r`n"
$dir = Join-Path $env:TEMP ('pin-repro-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$certPath = Join-Path $dir 'anchor.pem'
[System.IO.File]::WriteAllText($certPath, $pem, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('pem_chars=' + (Get-Item -LiteralPath $certPath).Length)

$thumbprint = Get-McpCertificateThumbprint -CertificatePath $certPath
Write-Host ('expected=' + $anchor[0].Thumbprint)
Write-Host ('actual  =' + $thumbprint)
Write-Host ('equal=' + ($thumbprint -eq $anchor[0].Thumbprint))
Remove-Item -LiteralPath $dir -Recurse -Force
