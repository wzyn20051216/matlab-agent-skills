$ErrorActionPreference = 'Stop'
$sha = [System.Security.Cryptography.SHA256]::Create()
function Sha16([string]$s) { (-join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)) | ForEach-Object { $_.ToString('x2') })).Substring(0,16) }
$sessionFile = Join-Path $env:APPDATA 'MathWorks\MATLAB MCP Server\v1\sessionDetails.json'
$live = Get-Content -Raw -LiteralPath $sessionFile | ConvertFrom-Json
function PortOwner([int]$port) {
    $c = @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
    if ($c.Count -eq 0) { return [ordered]@{ listening = $false; ownerPid = $null; ownerName = $null } }
    $op = [int]$c[0].OwningProcess
    $pp = Get-Process -Id $op -ErrorAction SilentlyContinue
    [ordered]@{ listening = $true; ownerPid = $op; ownerName = $(if ($pp) { $pp.ProcessName } else { $null }) }
}
function ProcAlive([int]$p) { $x = Get-Process -Id $p -ErrorAction SilentlyContinue; [bool]$x }

$previouslyExposed = [ordered]@{
    source = 'sessionDetails.json snapshot observed at 2026-10-26T13:49:09 (S1 audit exposure; value never printed)'
    sha256_16 = '852b6e6d822c1bd9'
    length = 48
    port = 31519
    pid = 7008
    pidAliveNow = (ProcAlive 7008)
    portOwnerNow = (PortOwner 31519)
    stillPresentInSessionFile = ((Sha16 "$($live.apiKey)") -eq '852b6e6d822c1bd9')
}
$staleCopy = [ordered]@{
    path = 'artifacts\tmp_probe\session_ready.json'
    lastWrite = (Get-Item -LiteralPath 'E:\desktop\MATLAB\artifacts\tmp_probe\session_ready.json').LastWriteTime.ToString('o')
    tracked = (& git -C 'E:\desktop\MATLAB' ls-files -- 'artifacts/tmp_probe' | Out-String).Trim().Length -gt 0
    ignored = ((& git -C 'E:\desktop\MATLAB' check-ignore -v -- 'artifacts/tmp_probe/session_ready.json' | Out-String).Trim())
    sha256_16 = 'e87d592931843721'
    length = 16
    recordedPort = 31516
    recordedPid = 38668
    recordedPidAliveNow = (ProcAlive 38668)
    portOwnerNow = (PortOwner 31516)
    matchesCurrentLiveSession = ((Sha16 "$($live.apiKey)") -eq 'e87d592931843721')
}
$current = [ordered]@{
    sessionFileLastWrite = (Get-Item -LiteralPath $sessionFile).LastWriteTime.ToString('o')
    sha256_16 = Sha16 "$($live.apiKey)"
    length = "$($live.apiKey)".Length
    port = [int]$live.port
    pid = [int]$live.pid
    pidAlive = (ProcAlive ([int]$live.pid))
    portOwner = (PortOwner ([int]$live.port))
    rotatedAwayFromExposedValue = ((Sha16 "$($live.apiKey)") -ne '852b6e6d822c1bd9')
}
$scan = Get-Content -Raw -LiteralPath 'E:\desktop\MATLAB\artifacts\s3\evidence\apikey_leak_scan.json' | ConvertFrom-Json
$result = [ordered]@{
    schema = 'mas-s3-credential-rotation/1'
    createdAt = (Get-Date).ToString('o')
    head = ((& git -C 'E:\desktop\MATLAB' rev-parse HEAD | Out-String).Trim())
    principle = 'Evidence never contains a credential value: only SHA-256 prefixes, lengths, PIDs and port ownership. Invalidity is proven by process teardown + file replacement, not by redaction.'
    previouslyExposed = $previouslyExposed
    currentSession = $current
    staleUntrackedCopy = $staleCopy
    repositoryScan = [ordered]@{
        scannedFiles = [int]$scan.scannedFiles
        credentialHits = [int]$scan.credentialHits
        copiesMatchingExposedValue = [int]$scan.exposedKeyCopies
        evidence = 'artifacts/s3/evidence/apikey_leak_scan.json'
    }
    conclusion = [ordered]@{
        exposedCredentialRevoked = ((-not $previouslyExposed.pidAliveNow) -and (-not $previouslyExposed.stillPresentInSessionFile))
        revocationBasis = @('The MATLAB process that minted the exposed key (pid 7008) has exited; the connector credential lives only in that process, so it cannot authenticate any current server.', 'The session descriptor no longer carries that value (SHA-256 prefix 852b6e6d... absent; replacement hash differs and has a different length), so no client reading the descriptor can obtain it.')
        revocationLimits = @('No positive replay test was possible: the original value was never copied by this project and is no longer readable from disk, so it could not be presented to a live server. Port 31519 is now reused by an unrelated MATLAB process, which is consistent with the old session being gone but is not by itself proof of server-side invalidation.')
        portReuseObserved = [ordered]@{ port = 31519; previousOwnerPid = 7008; currentOwnerPid = $previouslyExposed.portOwnerNow.ownerPid; currentOwnerName = $previouslyExposed.portOwnerNow.ownerName }
        replacementCredentialIssued = $current.rotatedAwayFromExposedValue
        staleCopyInert = ((-not $staleCopy.recordedPidAliveNow) -and (-not $staleCopy.matchesCurrentLiveSession))
        actionTakenByAgent = 'Rotated by starting a session this run owns (shareMATLABSession rewrote sessionDetails.json at 19:14:53). No external service was called and no credential value was printed or copied.'
        stillNeedsHumanReview = @('The 2026-10-17 untracked snapshot artifacts/tmp_probe/session_ready.json still stores a stale apiKey/certificate copy; it is outside git (ignored by .gitignore:1) and provably inert, but was kept rather than deleted because history is not destroyed without approval.', 'Earlier S1 traces that carried the exposed value remain in history; if that value was ever valid outside loopback, MathWorks-side revocation is not observable from this machine.')
    }
}
$dir = 'E:\desktop\MATLAB\artifacts\s3\evidence'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $dir 'credential_rotation.json') -Encoding UTF8
($result | ConvertTo-Json -Depth 8)
