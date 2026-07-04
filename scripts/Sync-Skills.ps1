param(
    [string]$RepositoryRoot,
    [string]$SkillRoot = "E:\desktop\CAD\.agents\skills"
)

$ErrorActionPreference = "Stop"

if (-not $RepositoryRoot) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$sourceRoot = Join-Path $RepositoryRoot "skills"
if (-not (Test-Path -LiteralPath $sourceRoot)) {
    throw "Skills source folder not found: $sourceRoot"
}

New-Item -ItemType Directory -Force -Path $SkillRoot | Out-Null

Get-ChildItem -Path $sourceRoot -Directory -Filter "matlab-*" | ForEach-Object {
    $destination = Join-Path $SkillRoot $_.Name
    if (Test-Path -LiteralPath $destination) {
        Remove-Item -LiteralPath $destination -Recurse -Force
    }
    Copy-Item -LiteralPath $_.FullName -Destination $destination -Recurse -Force
    Write-Host "Deployed $($_.Name) -> $destination"
}
