<#
.SYNOPSIS
可见 MATLAB 桌面的自动启动与保守复用；不会终止 MATLAB 或改写共享凭据。
#>
Import-Module (Join-Path $PSScriptRoot 'MatlabAgentSkills.Execution.psm1') -DisableNameChecking

function Get-MasMatlabDesktopProcesses {
    <# .SYNOPSIS 返回 MATLAB 实际进程及窗口归属，不把启动器退出当成运行时退出。 #>
    $result = @()
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='MATLAB.exe'" -ErrorAction Stop)) {
        $native = Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue
        if (-not $native) { continue }
        $result += [pscustomobject]@{
            pid = [int]$process.ProcessId; parentPid = [int]$process.ParentProcessId
            path = [string]$process.ExecutablePath
            hasWindow = ($native.MainWindowHandle -ne [IntPtr]::Zero)
            startedAt = $process.CreationDate.ToString('o')
        }
    }
    return $result
}

function Read-MasDesktopSession {
    <# .SYNOPSIS 只返回共享会话的非敏感元数据；读失败或半写入时返回空。 #>
    param([Parameter(Mandatory)][string]$SessionFile)
    if (-not (Test-Path -LiteralPath $SessionFile)) { return $null }
    try {
        $SessionFile = (Resolve-Path -LiteralPath $SessionFile).Path
        $data = [IO.File]::ReadAllText($SessionFile) | ConvertFrom-Json
        $processNumber = 0; $portNumber = 0
        if (-not [int]::TryParse([string]$data.pid, [ref]$processNumber) -or $processNumber -le 0 -or
            -not [int]::TryParse([string]$data.port, [ref]$portNumber) -or $portNumber -le 0 -or $portNumber -gt 65535) { return $null }
        return [pscustomobject]@{
            pid = $processNumber; port = $portNumber; sessionFile = $SessionFile
            updatedAt = (Get-Item -LiteralPath $SessionFile).LastWriteTimeUtc.ToString('o')
        }
    } catch { return $null }
}

function Get-MasDesktopWindowPid {
    <# .SYNOPSIS 从运行时沿父链查桌面窗口；新版桌面窗口可能属于父启动器。 #>
    param([int]$RuntimePid, [object[]]$Processes)
    $current = $RuntimePid
    for ($depth = 0; $depth -lt 8 -and $current -gt 0; $depth++) {
        $entry = @($Processes | Where-Object { $_.pid -eq $current })
        if ($entry.Count -ne 1) { return $null }
        if ($entry[0].hasWindow) { return [int]$entry[0].pid }
        if ($entry[0].parentPid -eq $current) { return $null }
        $parent = @($Processes | Where-Object { $_.pid -eq $entry[0].parentPid })
        if ($parent.Count -eq 1) {
            $parentStamp = [DateTimeOffset]::MinValue; $childStamp = [DateTimeOffset]::MinValue
            if (-not [DateTimeOffset]::TryParse([string]$parent[0].startedAt, [ref]$parentStamp) -or
                -not [DateTimeOffset]::TryParse([string]$entry[0].startedAt, [ref]$childStamp) -or $parentStamp -gt $childStamp) { return $null }
        }
        $current = [int]$entry[0].parentPid
    }
    return $null
}

function Get-MasDesktopStartupAssessment {
    <# .SYNOPSIS 按本次启动标记、实际 PID、桌面窗口及共享会话共同判定就绪。 #>
    param([string]$LaunchId, $Receipt, $Session, [int[]]$BeforePids = @(), [object[]]$Processes = @(),
        [datetime]$NotBefore = [datetime]::MinValue, [string]$ExpectedMatlabRoot)
    $r = [ordered]@{ ready = $false; reason = 'BOOTSTRAP_NOT_OBSERVED'; runtimePid = $null; desktopPid = $null; coldStartVerified = $false }
    if (-not $Receipt) { return [pscustomobject]$r }
    if ($Receipt.launchId -ne $LaunchId) { $r.reason = 'STALE_LAUNCH_RECEIPT'; return [pscustomobject]$r }
    $runtimeNumber = 0
    if (-not [int]::TryParse([string]$Receipt.pid, [ref]$runtimeNumber) -or $runtimeNumber -le 0) {
        $r.reason = 'INVALID_RUNTIME_PID'; return [pscustomobject]$r
    }
    $r.runtimePid = $runtimeNumber
    if ($BeforePids -contains $runtimeNumber) { $r.reason = 'PREEXISTING_RUNTIME'; return [pscustomobject]$r }
    $runtime = @($Processes | Where-Object { $_.pid -eq $runtimeNumber })
    if ($runtime.Count -ne 1) {
        $r.reason = 'RUNTIME_EXITED'; return [pscustomobject]$r
    }
    if ($NotBefore -ne [datetime]::MinValue -and -not (Test-MasDesktopTimestamp -Text $runtime[0].startedAt -NotBefore $NotBefore)) {
        $r.reason = 'RUNTIME_PREDATES_LAUNCH'; return [pscustomobject]$r
    }
    if ($ExpectedMatlabRoot -and -not (Test-MasDesktopInstallation -ExecutablePath $runtime[0].path -ExpectedRoot $ExpectedMatlabRoot)) {
        $r.reason = 'MATLAB_INSTALLATION_MISMATCH'; return [pscustomobject]$r
    }
    if ($Receipt.desktop -isnot [bool] -or -not $Receipt.desktop) {
        $r.reason = 'DESKTOP_NOT_IN_USE'; return [pscustomobject]$r
    }
    $r.desktopPid = Get-MasDesktopWindowPid -RuntimePid $runtimeNumber -Processes $Processes
    if (-not $r.desktopPid) { $r.reason = 'DESKTOP_WINDOW_NOT_OBSERVED'; return [pscustomobject]$r }
    if ($Receipt.shareStatus -ne 'SHARED') { $r.reason = 'SHARING_FAILED'; return [pscustomobject]$r }
    if (-not $Session -or $Session.pid -ne $runtimeNumber) {
        $r.reason = 'SHARED_SESSION_PID_MISMATCH'; return [pscustomobject]$r
    }
    if ($NotBefore -ne [datetime]::MinValue -and -not (Test-MasDesktopTimestamp -Text $Session.updatedAt -NotBefore $NotBefore)) {
        $r.reason = 'STALE_SHARED_SESSION'; return [pscustomobject]$r
    }
    $r.ready = $true; $r.reason = 'READY'; $r.coldStartVerified = ($BeforePids.Count -eq 0)
    return [pscustomobject]$r
}

function Get-MasDesktopMatlabRoot {
    <# .SYNOPSIS 同时支持 bin/matlab.exe 和 bin/win64/MATLAB.exe 的安装根解析。 #>
    param([string]$ExecutablePath)
    if ([string]::IsNullOrWhiteSpace($ExecutablePath)) { return $null }
    $directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ExecutablePath))
    if ((Split-Path -Leaf $directory) -ieq 'win64') { $directory = Split-Path -Parent $directory }
    if ((Split-Path -Leaf $directory) -ieq 'bin') { return Split-Path -Parent $directory }
    return $directory
}

function Test-MasDesktopInstallation {
    <# .SYNOPSIS 不把其他安装版本的现有/新运行时冒充显式请求的 MATLAB。 #>
    param([string]$ExecutablePath, [string]$ExpectedRoot)
    $actual = Get-MasDesktopMatlabRoot -ExecutablePath $ExecutablePath
    if (-not $actual -or -not $ExpectedRoot) { return $false }
    return [string]::Equals($actual.TrimEnd([char[]]'\/'), $ExpectedRoot.TrimEnd([char[]]'\/'), [StringComparison]::OrdinalIgnoreCase)
}

function Test-MasDesktopTimestamp {
    <# .SYNOPSIS 缺少或无效时间戳不作为本次启动证据。 #>
    param([string]$Text, [datetime]$NotBefore)
    $stamp = [DateTimeOffset]::MinValue
    if (-not $Text -or -not [DateTimeOffset]::TryParse($Text, [ref]$stamp)) { return $false }
    return $stamp.UtcDateTime -ge $NotBefore.ToUniversalTime()
}

function Get-MasDesktopSharedCandidate {
    <# .SYNOPSIS 纯快捷方式启动后的候选必须新建、同安装、带窗口且共享文件新鲜。 #>
    param($Session, [int[]]$BeforePids = @(), [object[]]$Processes = @(),
        [datetime]$NotBefore, [string]$ExpectedMatlabRoot)
    if (-not $Session -or $BeforePids -contains $Session.pid) { return $null }
    $runtime = @($Processes | Where-Object { $_.pid -eq $Session.pid })
    if ($runtime.Count -ne 1 -or
        -not (Test-MasDesktopTimestamp -Text $runtime[0].startedAt -NotBefore $NotBefore) -or
        -not (Test-MasDesktopTimestamp -Text $Session.updatedAt -NotBefore $NotBefore) -or
        -not (Test-MasDesktopInstallation -ExecutablePath $runtime[0].path -ExpectedRoot $ExpectedMatlabRoot)) { return $null }
    $windowPid = Get-MasDesktopWindowPid -RuntimePid $Session.pid -Processes $Processes
    if (-not $windowPid) { return $null }
    return [pscustomobject]@{ runtimePid = [int]$Session.pid; desktopPid = [int]$windowPid; launcherPid = [int]$runtime[0].parentPid; sessionPort = [int]$Session.port }
}

function Get-MasDesktopShortcut {
    <# .SYNOPSIS 仅读桌面和开始菜单的 MATLAB 快捷方式，不扫描用户工程。 #>
    param([string]$ShortcutPath)
    if ($ShortcutPath -and (-not (Test-Path -LiteralPath $ShortcutPath -PathType Leaf) -or [IO.Path]::GetExtension($ShortcutPath) -ine '.lnk')) {
        throw 'ShortcutPath 必须是已存在的 Windows .lnk 文件。'
    }
    $roots = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory'))
    $programRoots = @([Environment]::GetFolderPath('StartMenu'), [Environment]::GetFolderPath('CommonStartMenu'))
    foreach ($programRoot in $programRoots) {
        $programs = Join-Path $programRoot 'Programs'
        if (Test-Path -LiteralPath $programs) {
            $roots += @(Get-ChildItem -LiteralPath $programs -Directory -Filter 'MATLAB*' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        }
    }
    $wsh = $null
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $links = if ($ShortcutPath) { @(Get-Item -LiteralPath $ShortcutPath) } else {
            @($roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | ForEach-Object {
                Get-ChildItem -LiteralPath $_ -File -Filter '*MATLAB*.lnk' -ErrorAction SilentlyContinue
            })
        }
        foreach ($link in $links) {
                $shortcut = $wsh.CreateShortcut($link.FullName)
                if ((Split-Path -Leaf $shortcut.TargetPath) -ieq 'matlab.exe' -and
                    (Test-Path -LiteralPath $shortcut.TargetPath) -and [string]::IsNullOrWhiteSpace($shortcut.Arguments)) {
                    return [pscustomobject]@{ path = $link.FullName; target = $shortcut.TargetPath; windowStyle = $shortcut.WindowStyle }
                }
        }
    } finally {
        if ($wsh) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($wsh) }
    }
    if ($ShortcutPath) { throw '指定快捷方式不是无参数的有效 MATLAB 启动入口。' }
    return $null
}

function ConvertFrom-MasDesktopComRegistration {
    <# .SYNOPSIS 仅接受官方桌面 COM 启动参数，解析已注册安装而不执行注册命令。 #>
    param([string]$Command, [string]$Clsid, [string]$ExpectedMatlabRoot)
    if ($Command -notmatch '^\s*(?:"(?<exe>[^"]+\.exe)"|(?<exe>.+?\.exe))\s+-desktop\s+-MLAutomation\s*$') { return $null }
    $executable = $Matches.exe
    if ((Split-Path -Leaf $executable) -ine 'matlab.exe' -or -not (Test-Path -LiteralPath $executable -PathType Leaf)) { return $null }
    if ($ExpectedMatlabRoot -and -not (Test-MasDesktopInstallation -ExecutablePath $executable -ExpectedRoot $ExpectedMatlabRoot)) { return $null }
    [pscustomobject]@{ progId = 'Matlab.Desktop.Application'; clsid = $Clsid; executable = $executable;
        matlabRoot = (Get-MasDesktopMatlabRoot -ExecutablePath $executable); arguments = @('-desktop','-MLAutomation') }
}

function Get-MasDesktopComRegistration {
    <# .SYNOPSIS 仅读取 64 位桌面 COM 注册，不注册或改变 MATLAB 安装。 #>
    param([string]$ExpectedMatlabRoot)
    $base = $null; $idKey = $null; $serverKey = $null
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::ClassesRoot, [Microsoft.Win32.RegistryView]::Registry64)
        $idKey = $base.OpenSubKey('Matlab.Desktop.Application\CLSID')
        if (-not $idKey) { return $null }
        $id = [string]$idKey.GetValue('')
        if ($id -notmatch '^\{[a-fA-F0-9-]{36}\}$') { return $null }
        $serverKey = $base.OpenSubKey("CLSID\$id\LocalServer32")
        if (-not $serverKey) { return $null }
        return ConvertFrom-MasDesktopComRegistration -Command ([string]$serverKey.GetValue('')) -Clsid $id -ExpectedMatlabRoot $ExpectedMatlabRoot
    } finally {
        if ($serverKey) { $serverKey.Dispose() }; if ($idKey) { $idKey.Dispose() }; if ($base) { $base.Dispose() }
    }
}

function Get-MasDesktopComIdentity {
    <# .SYNOPSIS 只解析带本次标记的只读身份输出，未确认新 PID 前不得执行启动回执。 #>
    param([string]$Output, [string]$LaunchId, [int[]]$BeforePids = @(), [string]$ExpectedMatlabRoot)
    $pattern = '(?m)^MAS_COM_ID_' + [regex]::Escape($LaunchId) + ' (?<pid>[1-9][0-9]*) (?<root>[^\r\n]+)\r?$'
    $identities = [regex]::Matches($Output, $pattern)
    if ($identities.Count -ne 1) { throw 'COM_IDENTITY_NOT_UNIQUE' }
    $identity = $identities[0]
    $runtimeNumber = [int]$identity.Groups['pid'].Value
    $root = $identity.Groups['root'].Value.Trim()
    if ($BeforePids -contains $runtimeNumber) { return [pscustomobject]@{ runtimePid=$runtimeNumber; isNew=$false; reason='NOT_NEW_COM_SHARED_SERVER' } }
    if (-not [string]::Equals($root.TrimEnd([char[]]'\/'), $ExpectedMatlabRoot.TrimEnd([char[]]'\/'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'COM_INSTALLATION_MISMATCH'
    }
    [pscustomobject]@{ runtimePid=$runtimeNumber; isNew=$true; reason='NEW_COM_RUNTIME' }
}

function Write-MasDesktopHolderState {
    <# .SYNOPSIS 持有进程只写白名单元数据，以临时文件原子替换防止父进程读到半 JSON。 #>
    param([string]$StateFile, $State)
    $temporary = $StateFile + '.tmp'
    $State.updatedAt = [datetime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText($temporary, ($State | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $StateFile -Force
}

function New-MasDesktopComObject {
    <# .SYNOPSIS COM 激活仅在 STA 执行；单独封装便于不启动 MATLAB 的保护边界测试。 #>
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'COM_HOLDER_REQUIRES_STA' }
    return New-Object -ComObject Matlab.Desktop.Application
}

function Invoke-MasDesktopComHolder {
    <# .SYNOPSIS 持有新桌面 COM 引用；主脚本超时不使桌面退出，用户关闭运行时才自然结束。 #>
    param([Parameter(Mandatory)][string]$ConfigFile)
    $config = [IO.File]::ReadAllText($ConfigFile) | ConvertFrom-Json
    if ($config.launchId -notmatch '^[a-f0-9]{32}$' -or -not $config.expectedMatlabRoot -or -not $config.stateFile) { throw '无效的 COM holder 配置。' }
    $state = [ordered]@{ schema='mas-desktop-holder/1'; launchId=$config.launchId; holderPid=$PID;
        status='ACTIVATING'; runtimePid=$null; runtimeStartedAt=$null; reason=$null; updatedAt=$null }
    $matlab = $null; $runtime = $null; $hold = $false; $unbound = @()
    try {
        Write-MasDesktopHolderState -StateFile $config.stateFile -State $state
        $matlab = New-MasDesktopComObject
        $query = "fprintf('MAS_COM_ID_$($config.launchId) %d %s\n',feature('getpid'),matlabroot);"
        $identity = Get-MasDesktopComIdentity -Output ([string]$matlab.Execute($query)) -LaunchId $config.launchId `
            -BeforePids ([int[]]@($config.beforePids)) -ExpectedMatlabRoot $config.expectedMatlabRoot
        $state.runtimePid = $identity.runtimePid
        if (-not $identity.isNew) {
            $state.status='NOT_NEW'; $state.reason=$identity.reason
            Write-MasDesktopHolderState -StateFile $config.stateFile -State $state
            return # 共享 COM 返回已有实例时不执行 bootstrap、不重写共享文件。
        }
        $runtime = Get-Process -Id $identity.runtimePid -ErrorAction Stop
        $runtimeStart = $runtime.StartTime.ToUniversalTime()
        if ($runtime.ProcessName -ine 'MATLAB' -or $runtimeStart -lt ([datetime]$config.launchRequestedAt).ToUniversalTime()) { throw 'COM_RUNTIME_PREDATES_LAUNCH' }
        $state.runtimeStartedAt = $runtimeStart.ToString('o'); $hold = $true
        $state.status='IDENTIFIED'
        Write-MasDesktopHolderState -StateFile $config.stateFile -State $state
        $matlab.Visible = 1
        $bootstrap = $config.scriptFile.Replace('\','/').Replace("'","''")
        # 仅写启动回执与共享会话；后续用户计算仍经官方 MCP。
        $executionOutput = [string]$matlab.Execute("run('$bootstrap');")
        $state.status='HOLDING'; $state.reason='COM_REFERENCE_HELD_UNTIL_RUNTIME_EXIT'
        Write-MasDesktopHolderState -StateFile $config.stateFile -State $state
    } catch {
        $state.status='FAILED'; $state.reason=Protect-MasDesktopDiagnosticText -Text $_.Exception.Message
        if ($matlab -and -not $hold) {
            # COM 已激活但身份输出失败时，保守持有本次新建同安装进程；绝不将候选升级为已绑定运行时。
            try {
                $candidates = @(Get-MasMatlabDesktopProcesses | Where-Object {
                    @($config.beforePids) -notcontains $_.pid -and
                    (Test-MasDesktopTimestamp -Text $_.startedAt -NotBefore ([datetime]$config.launchRequestedAt)) -and
                    (Test-MasDesktopInstallation -ExecutablePath $_.path -ExpectedRoot $config.expectedMatlabRoot)
                })
                foreach ($candidate in $candidates) {
                    $observed = Get-Process -Id $candidate.pid -ErrorAction SilentlyContinue
                    if ($observed) { $unbound += $observed }
                }
                if ($unbound.Count -gt 0) { $state.preservation='UNBOUND_NEW_PROCESSES'; $state.unboundProcessPids=@($unbound | ForEach-Object { $_.Id }) }
            } catch { $state.preservation='UNBOUND_OBSERVATION_FAILED' }
        }
        Write-MasDesktopHolderState -StateFile $config.stateFile -State $state
    }
    if ($hold) {
        # 强引用保持在此作用域；只轮询已绑定的 OS 进程，不向 MATLAB 注入 pause/timer/Quit。
        while (-not $runtime.HasExited) {
            Start-Sleep -Milliseconds 1000
            [GC]::KeepAlive($matlab)
        }
        $state.status='EXITED'; $state.reason='BOUND_RUNTIME_EXITED'
        Write-MasDesktopHolderState -StateFile $config.stateFile -State $state
        $runtime.Dispose()
    }
    if ($unbound.Count -gt 0) {
        while (@($unbound | Where-Object { -not $_.HasExited }).Count -gt 0) {
            Start-Sleep -Milliseconds 1000
            [GC]::KeepAlive($matlab)
        }
        $state.status='EXITED'; $state.reason='UNBOUND_NEW_PROCESSES_EXITED'
        Write-MasDesktopHolderState -StateFile $config.stateFile -State $state
        foreach ($observed in $unbound) { $observed.Dispose() }
    }
    [GC]::KeepAlive($matlab)
}

function Start-MasDesktopComHolder {
    <# .SYNOPSIS 原生创建脱离工具 Job 的隐藏 STA holder，不继承工具管道；失败不降级重复启动。 #>
    param($Plan, [int[]]$BeforePids, [string]$ExpectedMatlabRoot, [datetime]$LaunchRequestedAt)
    $configFile = Join-Path (Split-Path -Parent $Plan.scriptFile) 'desktop_holder_config.json'
    $stateFile = Join-Path (Split-Path -Parent $Plan.scriptFile) 'desktop_holder_state.json'
    $config = [ordered]@{ launchId=$Plan.launchId; scriptFile=$Plan.scriptFile; stateFile=$stateFile;
        beforePids=@($BeforePids); expectedMatlabRoot=$ExpectedMatlabRoot; launchRequestedAt=$LaunchRequestedAt.ToUniversalTime().ToString('o') }
    [IO.File]::WriteAllText($configFile, ($config | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    if (-not ('MasDesktop.NativeProcess' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'DesktopProcessNative.cs') }
    $helperExe = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell/v1.0/powershell.exe'
    $helperScript = Join-Path $PSScriptRoot 'Invoke-MatlabDesktopHolder.ps1'
    $argv = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-STA','-File',$helperScript,'-ConfigFile',$configFile)
    $arguments = ($argv | ForEach-Object { Format-ProcessArgument -Argument $_ }) -join ' '
    $holderNumber = [MasDesktop.NativeProcess]::StartDetached($helperExe, $arguments, $PSScriptRoot)
    [pscustomobject]@{ holderPid=$holderNumber; stateFile=$stateFile; configFile=$configFile;
        creationFlags='CREATE_BREAKAWAY_FROM_JOB|CREATE_NO_WINDOW'; inheritHandles=$false; apartment='STA' }
}

function Read-MasDesktopHolderState {
    <# .SYNOPSIS 不返回任意 holder JSON 字段，只接受同次启动和同一持有进程的状态。 #>
    param($Holder, [string]$LaunchId)
    if (-not (Test-Path -LiteralPath $Holder.stateFile)) { return $null }
    try {
        $state = [IO.File]::ReadAllText($Holder.stateFile) | ConvertFrom-Json
        if ($state.schema -ne 'mas-desktop-holder/1' -or $state.launchId -ne $LaunchId -or $state.holderPid -ne $Holder.holderPid) { return $null }
        [pscustomobject]@{status=[string]$state.status; runtimePid=$state.runtimePid; runtimeStartedAt=$state.runtimeStartedAt;
            reason=(Protect-MasDesktopDiagnosticText -Text ([string]$state.reason)); updatedAt=$state.updatedAt;
            preservation=[string]$state.preservation; unboundProcessPids=@($state.unboundProcessPids | Where-Object { $_ -is [int] -or $_ -is [long] }) }
    } catch { return $null }
}

function Test-MasDesktopHolderAlive {
    <# .SYNOPSIS 持有进程必须仍存在；创建进程成功本身不构成 MATLAB 就绪证据。 #>
    param([int]$HolderPid)
    return [bool](Get-Process -Id $HolderPid -ErrorAction SilentlyContinue)
}

function New-MasDesktopStartupPlan {
    <# .SYNOPSIS 构造交互启动命令与仅在局部函数内执行的就绪回执代码。 #>
    param([string]$MatlabExe, [string]$WorkingDirectory, [string]$OutputDirectory, [string]$LaunchId,
        [ValidateSet('StartupCommand','Shortcut','ComDesktop')][string]$LaunchMode = 'StartupCommand', [string]$ShortcutPath)
    $scriptFile = Join-Path $OutputDirectory 'desktop_bootstrap.m'
    $receiptFile = Join-Path $OutputDirectory 'desktop_ready.json'
    $logFile = Join-Path $OutputDirectory 'matlab_startup.log'
    $receiptLiteral = $receiptFile.Replace('\', '/').Replace("'", "''")
    $code = @'
% 本文件只用于本次新桌面启动；不清理工作区、不退出、不阻塞事件循环。
mas_desktop_bootstrap_local();
function mas_desktop_bootstrap_local()
r = struct('schema','mas-desktop-ready/1','launchId','__LAUNCH_ID__', ...
    'pid',feature('getpid'),'desktop',false,'desktopProbe','usejava','shareStatus','PENDING', ...
    'version',version,'matlabRoot',matlabroot,'errorId','');
try
    r.desktop = logical(usejava('desktop'));
catch
    r.desktop = false;
end
if ~r.desktop
    try
        r.desktop = logical(desktop('-inuse'));
        r.desktopProbe = 'desktop(-inuse)';
    catch
        try
            r.desktop = logical(desktop('inuse'));
            r.desktopProbe = 'desktop(inuse)';
        catch
            r.desktop = false;
        end
    end
end
try
    shareMATLABSession();
    r.shareStatus = 'SHARED';
catch me
    r.shareStatus = 'ERROR';
    r.errorId = me.identifier;
end
filename = '__RECEIPT_FILE__';
temporary = [filename '.tmp'];
fid = fopen(temporary,'w','n','UTF-8');
if fid < 0, error('MAS:DesktopReceipt','Cannot write desktop receipt'); end
try
    fprintf(fid,'%s',jsonencode(r));
catch me
    fclose(fid);
    rethrow(me);
end
fclose(fid);
movefile(temporary,filename,'f');
fprintf('MAS_DESKTOP_START runtime=%d shared=%s\n',r.pid,r.shareStatus);
end
'@
    $code = $code.Replace('__LAUNCH_ID__', $LaunchId).Replace('__RECEIPT_FILE__', $receiptLiteral)
    $command = "run('" + $scriptFile.Replace('\', '/').Replace("'", "''") + "')"
    $argv = @('-sd', $WorkingDirectory, '-logfile', $logFile, '-r', $command)
    if ($LaunchMode -eq 'Shortcut') {
        if (-not $ShortcutPath) { throw 'Shortcut 模式需要真实快捷方式。' }
        $argv = @()
    }
    if ($LaunchMode -eq 'ComDesktop') { $argv = @() }
    [pscustomobject]@{
        executable = $MatlabExe; arguments = $argv; launchId = $LaunchId
        launchMode = $LaunchMode; shellTarget = if ($LaunchMode -eq 'Shortcut') { $ShortcutPath } elseif ($LaunchMode -eq 'ComDesktop') { $null } else { $MatlabExe }
        argumentLine = (($argv | ForEach-Object { Format-ProcessArgument -Argument $_ }) -join ' ')
        workingDirectory = if ($LaunchMode -in @('Shortcut','ComDesktop')) { $null } else { $WorkingDirectory }
        scriptFile = $scriptFile; scriptText = $code
        receiptFile = $receiptFile; logFile = if ($LaunchMode -in @('Shortcut','ComDesktop')) { $null } else { $logFile }
    }
}

function Protect-MasDesktopDiagnosticText {
    <# .SYNOPSIS 启动诊断只保留有界非敏感行，不回显凭据字段或认证头。 #>
    param([string]$Text)
    $safe = @($Text -split '\r?\n' | ForEach-Object {
        if ($_ -match '(?i)api[-_]?key|x-api-key|authorization|bearer\s') { '[已省略敏感诊断行]' } else { $_ }
    }) -join "`n"
    if ($safe.Length -gt 2048) { return $safe.Substring($safe.Length - 2048) }
    return $safe
}

function New-MasDesktopShellCommand {
    <# .SYNOPSIS 生成 Shell 调用；Shortcut 模式只传 .lnk 路径，不覆盖参数或启动目录。 #>
    param($Plan)
    $exeLiteral = $Plan.shellTarget.Replace("'", "''")
    $invoke = if ($Plan.launchMode -eq 'Shortcut') {
        "`$s.ShellExecute('$exeLiteral');"
    } else {
        $argsLiteral = $Plan.argumentLine.Replace("'", "''")
        $directoryLiteral = $Plan.workingDirectory.Replace("'", "''")
        "`$s.ShellExecute('$exeLiteral','$argsLiteral','$directoryLiteral','open',1);"
    }
    return "`$ErrorActionPreference='Stop'; try { `$s=New-Object -ComObject Shell.Application; " +
        "$invoke exit 0 } " +
        "catch { [Console]::Error.WriteLine(`$_.Exception.Message); exit 1 }"
}

function Start-MasDesktopViaShell {
    <# .SYNOPSIS 在有界的 STA 辅助进程中调用 Windows Shell，保存有界脱敏诊断。 #>
    param($Plan, [int]$TimeoutSeconds = 20)
    # 仅设置本脚本的辅助进程输出编码，确保中文异常可由父进程可靠解码。
    $command = '[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false); ' + (New-MasDesktopShellCommand -Plan $Plan)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $helper = New-Object Diagnostics.ProcessStartInfo
    $helper.FileName = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell/v1.0/powershell.exe'
    $helper.Arguments = '-NoProfile -STA -EncodedCommand ' + $encoded
    $helper.UseShellExecute = $false; $helper.CreateNoWindow = $true
    $helper.RedirectStandardError = $true; $helper.RedirectStandardOutput = $true
    $helper.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $helper.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $helper
    try {
        [void]$process.Start()
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill() # 只结束本脚本自己的 Shell 辅助进程，绝不结束 MATLAB。
            throw 'Windows Shell 启动请求超时；可能已经创建的 MATLAB 保持运行。'
        }
        $detail = if ($errTask.Wait(1000)) { Protect-MasDesktopDiagnosticText -Text $errTask.Result } else { '未取得辅助进程错误正文。' }
        $standardOutput = if ($outTask.Wait(1000)) { Protect-MasDesktopDiagnosticText -Text $outTask.Result } else { '辅助进程输出流未关闭。' }
        $observation = [pscustomobject]@{
            helperPid = $process.Id; helperExitCode = $process.ExitCode; stdout = $standardOutput; stderr = $detail
        }
        if ($process.ExitCode -ne 0) {
            $failure = New-Object InvalidOperationException "Windows Shell 启动失败（exit=$($process.ExitCode)）：$detail"
            $failure.Data['desktopHelper'] = $observation
            throw $failure
        }
        return $observation
    } finally { $process.Dispose() }
}

function Start-MasMatlabDesktop {
    <# .SYNOPSIS 启动或复用桌面，等待实际运行时回执；失败也保留用户进程和会话。 #>
    [CmdletBinding()]
    param(
        [string]$MatlabExe, [string]$WorkingDirectory, [string]$OutputDirectory, [string]$SessionFile,
        [ValidateSet('StartupCommand','Shortcut','ComDesktop')][string]$LaunchMode = 'StartupCommand', [string]$ShortcutPath,
        [ValidateRange(1, 900)][int]$TimeoutSeconds = 180,
        [switch]$NewSession, [switch]$DryRun
    )
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw '此脚本用于 Windows 可见桌面。' }
    if ($ShortcutPath -and $LaunchMode -ne 'Shortcut') { throw 'ShortcutPath 需要配合 -LaunchMode Shortcut。' }
    if ($MatlabExe) {
        $MatlabExe = Resolve-MatlabExecutable -ExplicitPath $MatlabExe
        if (-not $MatlabExe) { throw '显式指定的 MATLAB 可执行文件不存在。' }
    }
    $expectedRoot = if ($MatlabExe) { Get-MasDesktopMatlabRoot -ExecutablePath $MatlabExe } else { $null }
    if (-not $WorkingDirectory) { $WorkingDirectory = Split-Path -Parent $PSScriptRoot }
    $WorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory -ErrorAction Stop).Path
    if (-not $OutputDirectory) { $OutputDirectory = Join-Path $WorkingDirectory 'artifacts/validation/matlab_desktop' }
    $OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
    if (-not $SessionFile) { $SessionFile = Join-Path $env:APPDATA 'MathWorks/MATLAB MCP Server/v1/sessionDetails.json' }
    $SessionFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SessionFile)
    $launchId = [guid]::NewGuid().ToString('N')
    $runDir = Join-Path $OutputDirectory ((Get-Date -Format 'yyyyMMdd-HHmmss') + '_' + $launchId.Substring(0,8))
    $before = @(Get-MasMatlabDesktopProcesses)
    $beforePids = [int[]]@($before | ForEach-Object { $_.pid })
    $session = Read-MasDesktopSession -SessionFile $SessionFile
    $existingDesktop = if ($session) { Get-MasDesktopWindowPid -RuntimePid $session.pid -Processes $before } else { $null }
    if ($existingDesktop) {
        $existingRuntime = @($before | Where-Object { $_.pid -eq $session.pid })[0]
        $runtimeStamp = [datetime]::MinValue
        if (-not [datetime]::TryParse([string]$existingRuntime.startedAt, [ref]$runtimeStamp) -or
            -not (Test-MasDesktopTimestamp -Text $session.updatedAt -NotBefore $runtimeStamp)) { $existingDesktop = $null }
        if ($expectedRoot -and -not (Test-MasDesktopInstallation -ExecutablePath $existingRuntime.path -ExpectedRoot $expectedRoot)) { $existingDesktop = $null }
    }
    $report = [ordered]@{
        schema = 'mas-matlab-desktop-start/1'; launchId = $launchId; startedAt = (Get-Date).ToString('o')
        status = 'PENDING'; reason = $null; launchMethod = 'WindowsShell'; launchMode = $LaunchMode; beforeProcesses = $before
        sessionFile = $SessionFile; readyForMcp = $false; requiresMcpReceipt = $false
        launchContext = [pscustomobject]@{ callerPid = $PID; windowsSessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId;
            userInteractive = [Environment]::UserInteractive; powerShellVersion = $PSVersionTable.PSVersion.ToString(); helperApartment = 'STA';
            condaPrefixSet = [bool]$env:CONDA_PREFIX; condaShlvl = [string]$env:CONDA_SHLVL }
        runtimePid = $null; desktopPid = $null; launcherPid = $null; sessionPort = $null
        reused = $false; newSessionVerified = $false; coldStartVerified = $false
        bootstrapReached = $false; desktopObserved = $false; mcpExecutionVerified = $false
        outputDirectory = $runDir; reportPath = (Join-Path $runDir 'startup_report.json')
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    if (-not $NewSession -and $existingDesktop) {
        $report.status = 'REUSED_EXISTING'; $report.reused = $true
        $report.runtimePid = $session.pid; $report.desktopPid = $existingDesktop; $report.sessionPort = $session.port
        $report.desktopObserved = $true; $report.reason = '已有共享运行时和桌面窗口；执行能力须由官方 MCP 验证。'
    } else {
        if ($before.Count -gt 0 -and -not $NewSession) {
            $report.status = 'EXISTING_NOT_READY'
            $report.reason = '已有 MATLAB 但尚无匹配共享桌面；保留现状，未自动创建重复实例。'
        } else {
            $registration = if ($LaunchMode -eq 'ComDesktop') { Get-MasDesktopComRegistration -ExpectedMatlabRoot $expectedRoot } else { $null }
            if ($LaunchMode -eq 'ComDesktop' -and -not $registration) { throw '未找到与目标安装匹配的官方桌面 COM 注册；未启动任何实例。' }
            if ($registration) { $MatlabExe = $registration.executable; $report.comRegistration = $registration; $report.launchMethod = 'RegisteredComDesktopHolder' }
            $shortcut = if ($LaunchMode -eq 'Shortcut' -or (-not $MatlabExe -and $LaunchMode -ne 'ComDesktop')) { Get-MasDesktopShortcut -ShortcutPath $ShortcutPath } else { $null }
            if ($LaunchMode -eq 'Shortcut' -and -not $shortcut) { throw '未发现可用的无参数 MATLAB .lnk；请显式传入 -ShortcutPath。' }
            if ($shortcut -and $expectedRoot -and -not (Test-MasDesktopInstallation -ExecutablePath $shortcut.target -ExpectedRoot $expectedRoot)) {
                throw '快捷方式目标与显式 MATLAB 安装不一致。'
            }
            if ($shortcut) { $MatlabExe = $shortcut.target; $report.shortcut = $shortcut.path }
            $MatlabExe = Resolve-MatlabExecutable -ExplicitPath $MatlabExe
            if (-not $MatlabExe) { throw '找不到 MATLAB；请传入 -MatlabExe。' }
            $expectedRoot = Get-MasDesktopMatlabRoot -ExecutablePath $MatlabExe
            $plan = New-MasDesktopStartupPlan -MatlabExe $MatlabExe -WorkingDirectory $WorkingDirectory -OutputDirectory $runDir -LaunchId $launchId `
                -LaunchMode $LaunchMode -ShortcutPath $(if ($shortcut) { $shortcut.path } else { $null })
            $report.executable = $plan.executable; $report.arguments = $plan.arguments
            $report.shellTarget = $plan.shellTarget; $report.shellWorkingDirectory = $plan.workingDirectory
            $report.expectedMatlabRoot = $expectedRoot
            $report.startupLog = $plan.logFile; $report.receiptFile = $plan.receiptFile
            if ($DryRun) { $report.status = 'DRY_RUN'; $report.reportPath = $null; return [pscustomobject]$report }
            New-Item -ItemType Directory -Path $runDir -Force | Out-Null
            [IO.File]::WriteAllText($plan.scriptFile, $plan.scriptText, (New-Object Text.UTF8Encoding($false)))
            $report.status = 'STARTING'
            [IO.File]::WriteAllText($report.reportPath, ($report | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
            try {
                $report.launchRequestedAt = [datetime]::UtcNow.ToString('o')
                $launchRequestedAt = [datetime]::Parse($report.launchRequestedAt).ToUniversalTime()
                if ($LaunchMode -eq 'ComDesktop') {
                    $report.holder = Start-MasDesktopComHolder -Plan $plan -BeforePids $beforePids -ExpectedMatlabRoot $expectedRoot -LaunchRequestedAt $launchRequestedAt
                } else { $report.shell = Start-MasDesktopViaShell -Plan $plan -TimeoutSeconds ([Math]::Min(20, $TimeoutSeconds)) }
                $report.status = 'WAITING_FOR_RECEIPT'
                [IO.File]::WriteAllText($report.reportPath, ($report | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
                $assessment = $null; $candidate = $null; $receipt = $null; $after = @(); $holderState = $null
                while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
                    if ($LaunchMode -eq 'ComDesktop') {
                        $holderState = Read-MasDesktopHolderState -Holder $report.holder -LaunchId $launchId
                        if ($holderState -and $holderState.status -in @('NOT_NEW','FAILED','EXITED')) { break }
                        if (-not (Test-MasDesktopHolderAlive -HolderPid $report.holder.holderPid)) { break }
                    }
                    $receipt = $null
                    if (Test-Path -LiteralPath $plan.receiptFile) {
                        try { $receipt = [IO.File]::ReadAllText($plan.receiptFile) | ConvertFrom-Json } catch { }
                    }
                    $after = @(Get-MasMatlabDesktopProcesses)
                    $session = Read-MasDesktopSession -SessionFile $SessionFile
                    $assessment = Get-MasDesktopStartupAssessment -LaunchId $launchId -Receipt $receipt -Session $session -BeforePids $beforePids -Processes $after `
                        -NotBefore $launchRequestedAt -ExpectedMatlabRoot $expectedRoot
                    if ($assessment.ready -and ($LaunchMode -ne 'ComDesktop' -or ($holderState -and $holderState.status -eq 'HOLDING' -and $holderState.runtimePid -eq $assessment.runtimePid))) { break }
                    if ($assessment.ready -and $LaunchMode -eq 'ComDesktop') { $assessment.ready=$false; $assessment.reason='COM_HOLDER_NOT_BOUND' }
                    if ($LaunchMode -eq 'Shortcut' -and -not $receipt) {
                        $candidate = Get-MasDesktopSharedCandidate -Session $session -BeforePids $beforePids -Processes $after `
                            -NotBefore $launchRequestedAt -ExpectedMatlabRoot $expectedRoot
                        if ($candidate) { break }
                    }
                    if ($receipt -and $receipt.launchId -eq $launchId -and $receipt.shareStatus -eq 'ERROR') { break }
                    Start-Sleep -Milliseconds 250
                }
                $report.bootstrapReached = [bool]($receipt -and $receipt.launchId -eq $launchId)
                $report.afterProcesses = $after
                if ($LaunchMode -eq 'ComDesktop') { $report.holderState = $holderState }
                if ($LaunchMode -eq 'ComDesktop' -and $holderState -and $holderState.status -eq 'NOT_NEW') {
                    $report.status='NOT_NEW'; $report.reason='NOT_NEW_COM_SHARED_SERVER'; $report.reused=$true; $report.runtimePid=$holderState.runtimePid
                } elseif ($LaunchMode -eq 'ComDesktop' -and $holderState -and $holderState.status -eq 'FAILED') {
                    $report.status='START_FAILED'; $report.reason=$holderState.reason; $report.runtimePid=$holderState.runtimePid
                } elseif ($LaunchMode -eq 'ComDesktop' -and (-not (Test-MasDesktopHolderAlive -HolderPid $report.holder.holderPid) -or ($holderState -and $holderState.status -eq 'EXITED'))) {
                    $report.status='START_FAILED'; $report.reason='COM_HOLDER_OR_RUNTIME_EXITED'
                } elseif ($LaunchMode -eq 'Shortcut' -and $candidate -and -not $assessment.ready) {
                    $report.status = 'SHARED_DESKTOP_CANDIDATE'; $report.reason = '已发现新共享桌面；待官方 MCP 执行本次回执后再确认新启动。'
                    $report.runtimePid = $candidate.runtimePid; $report.desktopPid = $candidate.desktopPid
                    $report.launcherPid = $candidate.launcherPid; $report.sessionPort = $candidate.sessionPort
                    $report.desktopObserved = $true; $report.readyForMcp = $true; $report.requiresMcpReceipt = $true
                    $report.mcpCodeFile = Join-Path $runDir 'verify_desktop_receipt.m'
                    $bootstrapPath = $plan.scriptFile.Replace('\','/').Replace("'","''")
                    $verifyCode = "assert(feature('getpid') == $($candidate.runtimePid), 'MAS:DesktopPidMismatch', 'Wrong MATLAB session'); run('$bootstrapPath');"
                    [IO.File]::WriteAllText($report.mcpCodeFile, $verifyCode, (New-Object Text.UTF8Encoding($false)))
                } elseif ($assessment -and $assessment.ready) {
                    $report.status = 'READY'; $report.reason = '本次启动回执、实际运行时、桌面窗口和共享会话一致。'
                    $report.runtimePid = $assessment.runtimePid; $report.desktopPid = $assessment.desktopPid
                    $runtime = @($after | Where-Object { $_.pid -eq $assessment.runtimePid })[0]
                    $report.launcherPid = $runtime.parentPid; $report.sessionPort = $session.port
                    $report.desktopObserved = $true; $report.newSessionVerified = $true
                    $report.readyForMcp = $true
                    $report.coldStartVerified = $assessment.coldStartVerified; $report.matlabVersion = $receipt.version
                    $report.desktopProbe = $receipt.desktopProbe
                } else {
                    $report.status = if ($receipt -and $receipt.launchId -eq $launchId -and $receipt.shareStatus -eq 'ERROR') {
                        'START_FAILED'
                    } else { 'TIMEOUT' }
                    $report.reason = if ($assessment) { $assessment.reason } else { 'BOOTSTRAP_NOT_OBSERVED' }
                    if ($LaunchMode -eq 'Shortcut' -and -not $receipt) { $report.reason = 'SHARED_DESKTOP_NOT_OBSERVED' }
                    if ($report.status -eq 'START_FAILED') { $report.bootstrapErrorId = [string]$receipt.errorId }
                }
            } catch {
                $report.status = 'START_FAILED'; $report.reason = Protect-MasDesktopDiagnosticText -Text $_.Exception.Message
                if ($_.Exception.Data.Contains('desktopHelper')) { $report.shell = $_.Exception.Data['desktopHelper'] }
            }
        }
    }
    $report.finishedAt = (Get-Date).ToString('o'); $report.durationMs = $clock.ElapsedMilliseconds
    if ($DryRun) { $report.reportPath = $null; return [pscustomobject]$report }
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    [IO.File]::WriteAllText($report.reportPath, ($report | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
    return [pscustomobject]$report
}

function Confirm-MasDesktopStartupReceipt {
    <# .SYNOPSIS 在调用者用官方 MCP 执行回执文件后，只读复核并更新本次启动报告。 #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ReportPath)
    $ReportPath = (Resolve-Path -LiteralPath $ReportPath -ErrorAction Stop).Path
    $report = [IO.File]::ReadAllText($ReportPath) | ConvertFrom-Json
    if ($report.schema -ne 'mas-matlab-desktop-start/1' -or $report.launchId -notmatch '^[a-f0-9]{32}$' -or
        -not $report.launchRequestedAt -or -not $report.expectedMatlabRoot -or -not $report.receiptFile) {
        throw '启动报告缺少本次启动绑定信息。'
    }
    if ($report.reused) { throw '复用的会话不能确认成新启动。' }
    $receiptFile = Join-Path (Split-Path -Parent $ReportPath) 'desktop_ready.json'
    if (-not [string]::Equals([IO.Path]::GetFullPath($report.receiptFile), $receiptFile, [StringComparison]::OrdinalIgnoreCase)) {
        throw '回执路径不属于本次启动目录。'
    }
    $receipt = if (Test-Path -LiteralPath $receiptFile) { [IO.File]::ReadAllText($receiptFile) | ConvertFrom-Json } else { $null }
    $processes = @(Get-MasMatlabDesktopProcesses)
    $session = Read-MasDesktopSession -SessionFile $report.sessionFile
    $beforePids = [int[]]@($report.beforeProcesses | ForEach-Object { $_.pid })
    $assessment = Get-MasDesktopStartupAssessment -LaunchId $report.launchId -Receipt $receipt -Session $session `
        -BeforePids $beforePids -Processes $processes -NotBefore ([datetime]$report.launchRequestedAt) -ExpectedMatlabRoot $report.expectedMatlabRoot
    if (-not $assessment.ready) { throw "启动回执确认失败：$($assessment.reason)" }
    if ($report.launchMode -eq 'ComDesktop') {
        $state = if ($report.holder) { Read-MasDesktopHolderState -Holder $report.holder -LaunchId $report.launchId } else { $null }
        if (-not $state -or $state.status -ne 'HOLDING' -or $state.runtimePid -ne $assessment.runtimePid -or
            -not (Test-MasDesktopHolderAlive -HolderPid $report.holder.holderPid)) { throw '启动回执确认失败：COM_HOLDER_NOT_BOUND' }
    }
    $snapshot = Join-Path (Split-Path -Parent $ReportPath) 'startup_report.before_confirmation.json'
    if (-not (Test-Path -LiteralPath $snapshot)) { [IO.File]::WriteAllText($snapshot, [IO.File]::ReadAllText($ReportPath), (New-Object Text.UTF8Encoding($false))) }
    $updates = [ordered]@{
        initialStatus = if ($report.PSObject.Properties.Name -contains 'initialStatus') { $report.initialStatus } else { $report.status }
        initialReason = if ($report.PSObject.Properties.Name -contains 'initialReason') { $report.initialReason } else { $report.reason }
        confirmedAt = [datetime]::UtcNow.ToString('o')
        status = 'READY'; reason = '新桌面候选已取得本次运行时回执；进程、窗口、安装及共享会话匹配。'
        runtimePid = $assessment.runtimePid; desktopPid = $assessment.desktopPid; sessionPort = $session.port
        newSessionVerified = $true; coldStartVerified = $assessment.coldStartVerified; bootstrapReached = $true
        desktopObserved = $true; requiresMcpReceipt = $false; readyForMcp = $true; afterProcesses = $processes
        matlabVersion = $receipt.version; desktopProbe = $receipt.desktopProbe; mcpExecutionVerified = $false
    }
    foreach ($name in $updates.Keys) { $report | Add-Member -MemberType NoteProperty -Name $name -Value $updates[$name] -Force }
    [IO.File]::WriteAllText($ReportPath, ($report | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
    return $report
}

Export-ModuleMember -Function Start-MasMatlabDesktop, Confirm-MasDesktopStartupReceipt, Read-MasDesktopSession, Get-MasDesktopStartupAssessment, New-MasDesktopStartupPlan, Invoke-MasDesktopComHolder
