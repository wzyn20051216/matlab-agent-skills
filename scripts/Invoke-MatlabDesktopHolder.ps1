<#
.SYNOPSIS
内部入口：在独立 STA 中强持 MATLAB 桌面 COM 引用，直到对应运行时由用户关闭。
.DESCRIPTION
只激活 COM、核对身份及执行本次启动回执；不计算用户任务，不调用 Quit 或终止 MATLAB。
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigFile)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MatlabAgentSkills.Desktop.psm1') -Force -DisableNameChecking
Invoke-MasDesktopComHolder -ConfigFile $ConfigFile
