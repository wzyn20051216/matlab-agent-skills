param(
    [string]$RepositoryRoot = "E:\desktop\MATLAB",
    [string]$ClassificationPath = "E:\desktop\MATLAB\artifacts\s2\evidence\task7\s2-file-classification.json",
    [string]$OutputPath = "E:\desktop\MATLAB\artifacts\s2\evidence\task6\s2-drive-path-scan.json"
)

$ErrorActionPreference = 'Stop'
$classification = Get-Content -LiteralPath $ClassificationPath -Raw | ConvertFrom-Json
$paths = @()
foreach ($name in @('layered_on_s1', 'head_based', 'docs', 'new_files')) {
    $paths += @($classification.$name)
}
$paths = $paths | Sort-Object -Unique

# Same predicate as tests/MatlabAgentSkills.Core.Tests.ps1; built dynamically so this
# script cannot count as a hit itself.
$drivePattern = "(?<![A-Za-z0-9_])[" + [char]69 + [char]68 + "]:[\\/](?![A-Za-z]:)"

$hits = @()
$scanned = 0
foreach ($relative in $paths) {
    $path = Join-Path $RepositoryRoot ($relative -replace '/', [string][char]92)
    if (-not (Test-Path -LiteralPath $path)) {
        $hits += [pscustomobject]@{ path = $relative; line = $null; text = 'MISSING' }
        continue
    }
    $scanned++
    $matches = Select-String -LiteralPath $path -Pattern $drivePattern -AllMatches -ErrorAction SilentlyContinue
    foreach ($match in $matches) {
        $hits += [pscustomobject]@{ path = $relative; line = $match.LineNumber; text = $match.Line.Trim() }
    }
}

$result = [ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToString('o')
    pattern = 'drive-letter E: or D: followed by slash (case-insensitive, path-start context)'
    files = $paths.Count
    scanned = $scanned
    hitCount = $hits.Count
    hits = $hits
}
$json = $result | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($OutputPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "scanned=$scanned files=$($paths.Count) hits=$($hits.Count) output=$OutputPath"
if ($hits.Count -ne 0) { exit 1 }
