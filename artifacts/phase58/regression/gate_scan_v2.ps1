# Rebuild the repository-hygiene predicate from character codes so the scan
# cannot be mangled by shell quoting (a collapsed backslash pair silently stops
# matching "E:\..." paths, which is how an earlier scan reported a false "clean").
$root = 'E:' + [string][char]92 + 'desktop' + [string][char]92 + 'MATLAB'
$colon = [string][char]58
$bs1 = [string][char]92
$cls = '[' + $bs1 + $bs1 + [string][char]47 + ']'
$pat = '(?<![A-Za-z0-9_])[' + [char]69 + [char]68 + ']' + $colon + $cls + '(?![A-Za-z]' + $colon + ')'

Set-Location -LiteralPath $root
$listing = & git ls-files -z
$tracked = @{}
foreach ($rp in (($listing -join "") -split [string][char]0)) {
    if ($rp) { $tracked[$rp.Replace($bs1, '/')] = $true }
}
$files = Get-ChildItem -LiteralPath $root -Recurse -File |
    Where-Object { $_.FullName -notmatch ($cls + '\.(git|workbuddy|codex|vscode)' + $cls) } |
    Where-Object { $_.Name -ne '.mcp.json' -and
                   $_.FullName -notmatch ($cls + 'artifacts' + $cls) -and
                   $_.FullName -notmatch ($cls + 'bin' + $cls) } |
    Where-Object { $_.Extension -in @('.ps1', '.psm1', '.m', '.md', '.json', '.yml', '.yaml') } |
    Where-Object { $tracked.ContainsKey($_.FullName.Substring($root.Length + 1).Replace($bs1, '/')) }

# predicate self-check: the gate must catch both separator spellings and must
# not catch escape sequences or prose drive markers.
$E = [string][char]69; $D = [string][char]68; $C = [string][char]67
$fs = [string][char]47
# One assignment per sample: inside @(...) the comma operator binds looser than
# "+", so a literal list of concatenations silently becomes one element.
$p1 = $E + $colon + $bs1 + 'desktop'
$p2 = 'e' + $colon + $fs + 'desktop'
$p3 = $D + $colon + $bs1 + 'Temp'
$n1 = 'name' + $colon + $bs1 + 's*(matlab-'
$n2 = $E + $colon + $fs + $D + $colon
$n3 = $C + $colon + $bs1 + 'Windows'
$posSamples = @($p1, $p2, $p3)
$negSamples = @($n1, $n2, $n3)
$posOk = 0; foreach ($s in $posSamples) { if ($s -match $pat) { $posOk++ } }
$negOk = 0; foreach ($s in $negSamples) { if ($s -notmatch $pat) { $negOk++ } }
Write-Output ('PREDICATE SELF-CHECK positives=' + $posOk + '/3 negatives=' + $negOk + '/3')

$n = 0
$perFile = @{}
foreach ($f in $files) {
    $m = @(Select-String -LiteralPath $f.FullName -Pattern $pat -ErrorAction SilentlyContinue)
    if ($m.Count -eq 0) { continue }
    $rel = $f.FullName.Substring($root.Length + 1).Replace($bs1, '/')
    $perFile[$rel] = $m.Count
    foreach ($hit in $m) {
        $n++
        $t = $hit.Line.Trim()
        if ($t.Length -gt 96) { $t = $t.Substring(0, 96) }
        Write-Output ('{0:d3} {1}:{2}: {3}' -f $n, $rel, $hit.LineNumber, $t)
    }
}
Write-Output ('---- tracked files scanned: ' + @($files).Count)
foreach ($k in ($perFile.Keys | Sort-Object)) { Write-Output ('   ' + $perFile[$k].ToString().PadLeft(3) + '  ' + $k) }
Write-Output ('GATE-SCOPED HIT LINES: ' + $n)
