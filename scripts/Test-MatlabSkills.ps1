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
$featureProbe = Join-Path $Root "matlab\validation\matlab_feature_probe.m"
$codegenSmoke = Join-Path $Root "matlab\validation\matlab_codegen_smoke.m"
$simulinkCoderSmoke = Join-Path $Root "matlab\validation\simulink_coder_smoke.m"

& $invoke -MatlabPath $MatlabPath -Script $inventory -WorkingDirectory $Root -Label "toolbox_inventory"
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $invoke -MatlabPath $MatlabPath -Script $featureProbe -WorkingDirectory $Root -Label "feature_probe"
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $invoke -MatlabPath $MatlabPath -Script $smoke -WorkingDirectory $Root -Label "skill_smoke"
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $invoke -MatlabPath $MatlabPath -Script $codegenSmoke -WorkingDirectory $Root -Label "matlab_codegen_smoke"
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $invoke -MatlabPath $MatlabPath -Script $simulinkCoderSmoke -WorkingDirectory $Root -Label "simulink_coder_smoke"
exit $LASTEXITCODE
