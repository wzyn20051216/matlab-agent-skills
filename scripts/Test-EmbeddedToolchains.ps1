<#
.SYNOPSIS
嵌入式外部工具链一键探测脚本。

.DESCRIPTION
面向 MATLAB + STM32 / Raspberry Pi 工程链，检测 VS Code、STM32CubeMX、Keil、
以及本地关键 VS Code 扩展的安装与可用状态，输出统一 JSON 验收结果。
#>

param(
    [string]$Root,
    [string]$MatlabPath = $env:MATLAB_EXE,
    [string]$VSCodePath,
    [string]$CubeMXPath,
    [string]$KeilPath
)

$ErrorActionPreference = "Stop"

if (-not $Root) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $Root = Split-Path -Parent $scriptDir
}

$validationDir = Join-Path $Root "artifacts\validation"
New-Item -ItemType Directory -Force -Path $validationDir | Out-Null

function Get-RegistryApp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplayNamePattern
    )

    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like $DisplayNamePattern } |
        Select-Object -First 1
}

function Resolve-FirstExistingPath {
    param(
        [string[]]$Candidates
    )

    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Get-DrivePathCandidates {
    param(
        [string[]]$RelativePaths
    )

    $candidates = @()
    $drives = Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Root
    foreach ($drive in $drives) {
        foreach ($relativePath in $RelativePaths) {
            $candidates += (Join-Path $drive $relativePath)
        }
    }

    return $candidates
}

function Join-PathIfPresent {
    param(
        [string]$BasePath,
        [string]$ChildPath
    )

    if ([string]::IsNullOrWhiteSpace($BasePath)) {
        return $null
    }

    return (Join-Path $BasePath $ChildPath)
}

function Get-ParentPathIfPresent {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    return (Split-Path -Parent $Path)
}

function Get-FileVersionSummary {
    param(
        [string]$Path
    )

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $versionInfo = (Get-Item -LiteralPath $Path).VersionInfo
    return [ordered]@{
        fileVersion = $versionInfo.FileVersion
        productVersion = $versionInfo.ProductVersion
        fileDescription = $versionInfo.FileDescription
    }
}

function Invoke-ToolCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$Arguments = @()
    )

    try {
        $output = & $FilePath @Arguments 2>&1 | Out-String
        return [ordered]@{
            exitCode = $LASTEXITCODE
            output = $output.Trim()
        }
    }
    catch {
        return [ordered]@{
            exitCode = -1
            output = $_.Exception.Message
        }
    }
}

$vsCodeRegistry = Get-RegistryApp -DisplayNamePattern 'Microsoft Visual Studio Code*'
$cubeMxRegistry = Get-RegistryApp -DisplayNamePattern 'STM32CubeMX*'
$keilRegistry = Get-RegistryApp -DisplayNamePattern 'Keil*'
$codeCommand = Get-Command code.cmd -ErrorAction SilentlyContinue

$resolvedMatlabPath = Resolve-FirstExistingPath @(
    $MatlabPath,
    (Get-Command matlab -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
    (Get-DrivePathCandidates @('MATLAB\bin\matlab.exe'))
)

$resolvedVSCodePath = Resolve-FirstExistingPath @(
    $VSCodePath,
    (Join-PathIfPresent $vsCodeRegistry.InstallLocation 'Code.exe'),
    'C:\Program Files\Microsoft VS Code\Code.exe',
    (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe'),
    (Get-DrivePathCandidates @('Microsoft VS Code\Code.exe'))
)

$resolvedCubeMXPath = Resolve-FirstExistingPath @(
    $CubeMXPath,
    $cubeMxRegistry.DisplayIcon,
    (Join-PathIfPresent $cubeMxRegistry.InstallLocation 'STM32CubeMX.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\STM32CubeMX\STM32CubeMX.exe'),
    'C:\Program Files\STMicroelectronics\STM32Cube\STM32CubeMX\STM32CubeMX.exe',
    'C:\ST\STM32CubeMX\STM32CubeMX.exe'
)

$resolvedKeilPath = Resolve-FirstExistingPath @(
    $KeilPath,
    $keilRegistry.DisplayIcon,
    (Join-PathIfPresent $keilRegistry.LastInstallDir 'UV4\UV4.exe'),
    'C:\Keil_v5\UV4\UV4.exe',
    (Get-DrivePathCandidates @('Keil_v5\UV4\UV4.exe', 'keil5\UV4\UV4.exe'))
)

$vsCodeCliPath = Resolve-FirstExistingPath @(
    $codeCommand.Source,
    (Join-PathIfPresent (Get-ParentPathIfPresent $resolvedVSCodePath) 'bin\code.cmd'),
    (Get-DrivePathCandidates @('Microsoft VS Code\bin\code.cmd'))
)

$requiredExtensions = @(
    'stmicroelectronics.stm32-vscode-extension',
    'marus25.cortex-debug',
    'ms-vscode.cpptools',
    'cl.keil-assistant'
)

$report = [ordered]@{
    generatedAt = (Get-Date).ToString('s')
    paths = [ordered]@{
        root = $Root
        matlab = $resolvedMatlabPath
        vscode = $resolvedVSCodePath
        vscodeCli = $vsCodeCliPath
        stm32CubeMx = $resolvedCubeMXPath
        keilUv4 = $resolvedKeilPath
    }
    toolchains = [ordered]@{}
}

$report.toolchains.matlab = [ordered]@{
    status = if ($resolvedMatlabPath) { 'installed' } else { 'missing' }
    path = $resolvedMatlabPath
    version = Get-FileVersionSummary -Path $resolvedMatlabPath
}

$report.toolchains.vscode = [ordered]@{
    status = if ($resolvedVSCodePath) { 'installed' } else { 'missing' }
    path = $resolvedVSCodePath
    version = Get-FileVersionSummary -Path $resolvedVSCodePath
    cli = [ordered]@{
        path = $vsCodeCliPath
        available = [bool]$vsCodeCliPath
    }
    extensions = @{}
}

if ($vsCodeCliPath) {
    $versionCheck = Invoke-ToolCommand -FilePath $vsCodeCliPath -Arguments @('--version')
    $extensionCheck = Invoke-ToolCommand -FilePath $vsCodeCliPath -Arguments @('--list-extensions', '--show-versions')
    $extensionLines = @()
    if ($extensionCheck.exitCode -eq 0 -and $extensionCheck.output) {
        $extensionLines = $extensionCheck.output -split "`r?`n" | Where-Object { $_.Trim() }
    }

    $report.toolchains.vscode.cli.versionCheck = $versionCheck
    $report.toolchains.vscode.cli.extensionListCheck = [ordered]@{
        exitCode = $extensionCheck.exitCode
        extensionCount = $extensionLines.Count
    }

    foreach ($extension in $requiredExtensions) {
        $match = $extensionLines | Where-Object { $_ -match "^$([regex]::Escape($extension))@" } | Select-Object -First 1
        $report.toolchains.vscode.extensions[$extension] = [ordered]@{
            installed = [bool]$match
            version = if ($match) { ($match -split '@', 2)[1] } else { $null }
        }
    }
}
else {
    foreach ($extension in $requiredExtensions) {
        $report.toolchains.vscode.extensions[$extension] = [ordered]@{
            installed = $false
            version = $null
        }
    }
}

$cubeMxDir = if ($resolvedCubeMXPath) { Split-Path -Parent $resolvedCubeMXPath } else { $null }
$report.toolchains.stm32CubeMx = [ordered]@{
    status = if ($resolvedCubeMXPath) { 'installed' } else { 'missing' }
    path = $resolvedCubeMXPath
    version = Get-FileVersionSummary -Path $resolvedCubeMXPath
    dbFolderPresent = if ($cubeMxDir) { Test-Path -LiteralPath (Join-Path $cubeMxDir 'db') } else { $false }
    pluginsFolderPresent = if ($cubeMxDir) { Test-Path -LiteralPath (Join-Path $cubeMxDir 'plugins') } else { $false }
}

$keilDir = if ($resolvedKeilPath) { Split-Path -Parent $resolvedKeilPath } else { $null }
$report.toolchains.keil = [ordered]@{
    status = if ($resolvedKeilPath) { 'installed' } else { 'missing' }
    path = $resolvedKeilPath
    version = Get-FileVersionSummary -Path $resolvedKeilPath
    uvisionComPresent = if ($keilDir) { Test-Path -LiteralPath (Join-Path $keilDir 'uVision.com') } else { $false }
    packInstallerPresent = if ($keilDir) { Test-Path -LiteralPath (Join-Path $keilDir 'PackInstaller.exe') } else { $false }
}

$baseReady = ($report.toolchains.matlab.status -eq 'installed') -and
    ($report.toolchains.vscode.status -eq 'installed') -and
    [bool]$report.toolchains.vscode.cli.available -and
    ($report.toolchains.stm32CubeMx.status -eq 'installed') -and
    ($report.toolchains.keil.status -eq 'installed')

$extensionsReady = $true
foreach ($extension in $requiredExtensions) {
    if (-not [bool]$report.toolchains.vscode.extensions[$extension].installed) {
        $extensionsReady = $false
        break
    }
}

$report.overall = [ordered]@{
    baseReady = $baseReady
    extensionsReady = $extensionsReady
    ready = $baseReady -and $extensionsReady
    status = if ($baseReady -and $extensionsReady) { 'ready' } elseif ($baseReady) { 'partial' } else { 'incomplete' }
}

$jsonPath = Join-Path $validationDir 'embedded_toolchain_probe.json'
$report | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8

Write-Host "EMBEDDED_TOOLCHAIN_PROBE=$jsonPath"
Write-Host "TOOLCHAIN_READY=$($report.overall.ready)"
Write-Host "VSCODE_EXTENSIONS_READY=$extensionsReady"

if (-not $report.overall.ready) {
    exit 1
}
