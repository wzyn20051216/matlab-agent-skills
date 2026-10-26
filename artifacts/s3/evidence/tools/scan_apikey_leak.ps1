$ErrorActionPreference = 'Stop'
# Scan repo for apiKey field VALUES; report only path/line/field/length/sha256 prefix, never the value.
$exposedShaPrefix = '852b6e6d822c1bd9'
$sep = [string][char]92
$sha = [System.Security.Cryptography.SHA256]::Create()
$root = (Resolve-Path 'E:\desktop\MATLAB').Path
$pattern = '"?(apiKey|api_key|apikey|x-api-key)"?\s*[:=]\s*"?([A-Za-z0-9+/_\-\.=]{8,200})"?'
$hits = @()
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -Include *.json,*.jsonl,*.md,*.txt,*.ps1,*.psm1,*.m,*.yaml,*.yml,*.log -ErrorAction SilentlyContinue |
    Where-Object { -not $_.FullName.Contains($sep + '.git' + $sep) })
foreach ($f in $files) {
    try { $lines = [System.IO.File]::ReadAllLines($f.FullName) } catch { continue }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($m in [regex]::Matches($lines[$i], $pattern, 'IgnoreCase')) {
            $value = $m.Groups[2].Value
            if ($value -match 'REDACTED|redacted|\*{3,}|placeholder') { continue }
            $hashPrefix = (-join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($value)) | ForEach-Object { $_.ToString('x2') })).Substring(0, 16)
            $hits += [pscustomobject]@{
                path      = $f.FullName.Substring($root.Length + 1)
                line      = ($i + 1)
                field     = $m.Groups[1].Value
                length    = $value.Length
                sha256_16 = $hashPrefix
                matchesExposed = ($hashPrefix -eq $exposedShaPrefix)
            }
        }
    }
}
$result = [ordered]@{
    schemaVersion    = 'mas-s3-apikey-scan/1'
    createdAt        = (Get-Date).ToString('o')
    repositoryRoot   = $root
    exposedKeySha16  = $exposedShaPrefix
    scannedFiles     = $files.Count
    credentialHits   = $hits.Count
    exposedKeyCopies = @($hits | Where-Object { $_.matchesExposed }).Count
    note             = 'Hashes and lengths only. A hit with matchesExposed=true means the previously exposed value is still stored verbatim somewhere.'
    hits             = @($hits | Select-Object -First 40)
}
New-Item -ItemType Directory -Force -Path (Join-Path $root 'artifacts\s3\evidence') | Out-Null
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'artifacts\s3\evidence\apikey_leak_scan.json') -Encoding UTF8
"scannedFiles=$($result.scannedFiles) credentialHits=$($result.credentialHits) exposedKeyCopies=$($result.exposedKeyCopies)"
foreach ($h in @($hits | Select-Object -First 20)) { "  $($h.path):$($h.line) field=$($h.field) len=$($h.length) sha=$($h.sha256_16) exposed=$($h.matchesExposed)" }
