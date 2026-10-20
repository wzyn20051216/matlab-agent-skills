<#
.SYNOPSIS
自动打开 Windows MATLAB 可见桌面，默认安全复用已有共享桌面。
.DESCRIPTION
以唯一启动回执核对运行时 PID；等待有超时且保留日志。复用不记为新启动，
已有 MATLAB 时不会默认创建重复实例。此脚本不关闭 MATLAB、不清工作区、不输出共享密钥。
.PARAMETER NewSession
明确请求新实例；已有实例保持运行，报告不将其当成冷启动。
.PARAMETER DryRun
只显示计划，不启动 MATLAB、不创建日志目录。
.PARAMETER LaunchMode
StartupCommand 注入启动回执；Shortcut 直接启动真实 .lnk；ComDesktop 使用独立 STA 持有官方桌面 COM 引用。
.PARAMETER ConfirmReport
仅复核已有启动报告及 MATLAB 回执，不启动 MATLAB。
#>
[CmdletBinding(DefaultParameterSetName='Start')]
param(
    [Parameter(ParameterSetName='Start')][string]$MatlabExe,
    [Parameter(ParameterSetName='Start')][string]$WorkingDirectory,
    [Parameter(ParameterSetName='Start')][string]$OutputDirectory,
    [Parameter(ParameterSetName='Start')][string]$SessionFile,
    [Parameter(ParameterSetName='Start')][ValidateSet('StartupCommand','Shortcut','ComDesktop')][string]$LaunchMode='StartupCommand',
    [Parameter(ParameterSetName='Start')][string]$ShortcutPath,
    [Parameter(ParameterSetName='Start')]
    [ValidateRange(1, 900)][int]$TimeoutSeconds = 180,
    [Parameter(ParameterSetName='Start')][switch]$NewSession,
    [Parameter(ParameterSetName='Start')][switch]$DryRun,
    [Parameter(Mandatory,ParameterSetName='Confirm')][string]$ConfirmReport
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MatlabAgentSkills.Desktop.psm1') -Force -DisableNameChecking
$result = if ($PSCmdlet.ParameterSetName -eq 'Confirm') {
    Confirm-MasDesktopStartupReceipt -ReportPath $ConfirmReport
} else { Start-MasMatlabDesktop @PSBoundParameters }
$result | ConvertTo-Json -Depth 10
if ($result.status -in @('START_FAILED', 'TIMEOUT', 'EXISTING_NOT_READY', 'NOT_NEW')) { exit 1 }
