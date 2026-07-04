param(
    [string]$MatlabPath = $env:MATLAB_EXE,
    [string]$Root
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Root) {
    $Root = Split-Path -Parent $scriptDir
}

$invoke = Join-Path $scriptDir "Invoke-MatlabBatch.ps1"
$smoke = Join-Path $Root "matlab\validation\matlab_skill_smoke.m"
$inventory = Join-Path $Root "matlab\validation\matlab_toolbox_inventory.m"

& $invoke -MatlabPath $MatlabPath -Script $inventory -WorkingDirectory $Root -Label "toolbox_inventory"
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $invoke -MatlabPath $MatlabPath -Script $smoke -WorkingDirectory $Root -Label "skill_smoke"
exit $LASTEXITCODE
