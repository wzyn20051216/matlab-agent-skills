<#
.SYNOPSIS
桌面启动回执、PID 分层、复用、超时和凭据隔离；不启动真实 MATLAB。
#>
. (Join-Path $PSScriptRoot 'helpers/Assertions.ps1')
$desktopModule = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/MatlabAgentSkills.Desktop.psm1'
Import-Module $desktopModule -Force -DisableNameChecking

InModuleScope MatlabAgentSkills.Desktop {
    function New-DesktopStartupSandbox {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('mas-desktop-start-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'matlab.exe'), 'test-double-only')
        [IO.File]::WriteAllText((Join-Path $root 'matlab.lnk'), 'not-a-real-shortcut-test-double')
        [pscustomobject]@{ Root=$root; Exe=(Join-Path $root 'matlab.exe'); Output=(Join-Path $root 'reports'); Session=(Join-Path $root 'session.json') }
    }
    function Remove-DesktopStartupSandbox {
        param($Sandbox)
        $root = [IO.Path]::GetFullPath($Sandbox.Root)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
        if (-not $root.StartsWith($temp) -or (Split-Path -Leaf $root) -notlike 'mas-desktop-start-*') {
            throw '桌面测试清理路径越界。'
        }
        Remove-Item -LiteralPath $root -Recurse -Force
    }
    function New-DesktopTestProcesses {
        param([int]$RuntimeNumber=202, [int]$DesktopNumber=201)
        @(
            [pscustomobject]@{pid=$DesktopNumber;parentPid=100;hasWindow=$true;path='C:\MATLAB\bin\win64\MATLAB.exe';startedAt='2026-10-20T08:00:00Z'},
            [pscustomobject]@{pid=$RuntimeNumber;parentPid=$DesktopNumber;hasWindow=$false;path='C:\MATLAB\bin\win64\MATLAB.exe';startedAt='2026-10-20T08:00:01Z'}
        )
    }
    function New-DesktopTestReceipt {
        param([string]$LaunchId='current', [int]$RuntimeNumber=202)
        [pscustomobject]@{ launchId=$LaunchId;pid=$RuntimeNumber;desktop=$true;shareStatus='SHARED';version='test-version' }
    }

    Describe '桌面就绪必须匹配本次运行时' {
        It '桌面窗口在父进程且启动器与运行时 PID 不同时能正确识别' {
            $r = Get-MasDesktopStartupAssessment -LaunchId current -Receipt (New-DesktopTestReceipt) `
                -Session ([pscustomobject]@{pid=202}) -Processes (New-DesktopTestProcesses)
            $r.ready | Should Be $true
            $r.runtimePid | Should Be 202
            $r.desktopPid | Should Be 201
            $r.coldStartVerified | Should Be $true
        }
        It '旧 launchId 即使 PID 和共享文件一致也不能通过' {
            $r = Get-MasDesktopStartupAssessment -LaunchId current -Receipt (New-DesktopTestReceipt -LaunchId old) `
                -Session ([pscustomobject]@{pid=202}) -Processes (New-DesktopTestProcesses)
            $r.ready | Should Be $false
            $r.reason | Should Be STALE_LAUNCH_RECEIPT
        }
        It '启动前就存在的运行时不能计作新启动' {
            $r = Get-MasDesktopStartupAssessment -LaunchId current -Receipt (New-DesktopTestReceipt) `
                -BeforePids @(202) -Session ([pscustomobject]@{pid=202}) -Processes (New-DesktopTestProcesses)
            $r.ready | Should Be $false
            $r.reason | Should Be PREEXISTING_RUNTIME
        }
        It '只有 launcher 活着而实际 runtime 消失时不能通过' {
            $r = Get-MasDesktopStartupAssessment -LaunchId current -Receipt (New-DesktopTestReceipt) `
                -Session ([pscustomobject]@{pid=202}) -Processes @((New-DesktopTestProcesses)[0])
            $r.ready | Should Be $false
            $r.reason | Should Be RUNTIME_EXITED
        }
        It '共享文件被另一 MATLAB 会话覆盖时不能通过' {
            $r = Get-MasDesktopStartupAssessment -LaunchId current -Receipt (New-DesktopTestReceipt) `
                -Session ([pscustomobject]@{pid=999}) -Processes (New-DesktopTestProcesses)
            $r.ready | Should Be $false
            $r.reason | Should Be SHARED_SESSION_PID_MISMATCH
        }
        It '有主线程回执但没有桌面窗口时不能通过' {
            $processes = New-DesktopTestProcesses
            $processes[0].hasWindow = $false
            $r = Get-MasDesktopStartupAssessment -LaunchId current -Receipt (New-DesktopTestReceipt) `
                -Session ([pscustomobject]@{pid=202}) -Processes $processes
            $r.ready | Should Be $false
            $r.reason | Should Be DESKTOP_WINDOW_NOT_OBSERVED
        }
        It '较晚创建的无关窗口父 PID 不能冒充原桌面进程' {
            $processes = New-DesktopTestProcesses
            $processes[0].startedAt = '2026-10-20T08:01:00Z'
            $r = Get-MasDesktopStartupAssessment -LaunchId current -Receipt (New-DesktopTestReceipt) `
                -Session ([pscustomobject]@{pid=202}) -Processes $processes
            $r.ready | Should Be $false
            $r.reason | Should Be DESKTOP_WINDOW_NOT_OBSERVED
        }
        It '已有另一个 MATLAB 时新实例通过但不算冷启动' {
            $r = Get-MasDesktopStartupAssessment -LaunchId current -Receipt (New-DesktopTestReceipt) `
                -BeforePids @(88,89) -Session ([pscustomobject]@{pid=202}) -Processes (New-DesktopTestProcesses)
            $r.ready | Should Be $true
            $r.coldStartVerified | Should Be $false
        }
        It '共享函数报错的回执不能当成已就绪' {
            $receipt = New-DesktopTestReceipt
            $receipt.shareStatus = 'ERROR'
            $r = Get-MasDesktopStartupAssessment -LaunchId current -Receipt $receipt `
                -Session ([pscustomobject]@{pid=202}) -Processes (New-DesktopTestProcesses)
            $r.ready | Should Be $false
            $r.reason | Should Be SHARING_FAILED
        }
        It '桌面标志必须是布尔值，文本 true 不能冒充探针结果' {
            $receipt = New-DesktopTestReceipt
            $receipt.desktop = 'true'
            $r = Get-MasDesktopStartupAssessment -LaunchId current -Receipt $receipt `
                -Session ([pscustomobject]@{pid=202}) -Processes (New-DesktopTestProcesses)
            $r.ready | Should Be $false
            $r.reason | Should Be DESKTOP_NOT_IN_USE
        }
        It '新鲜共享文件、实际新进程和指定安装匹配时才通过' {
            $r = Get-MasDesktopStartupAssessment -LaunchId current -Receipt (New-DesktopTestReceipt) `
                -Session ([pscustomobject]@{pid=202;updatedAt='2026-10-20T08:00:03Z'}) -Processes (New-DesktopTestProcesses) `
                -NotBefore ([datetime]'2026-10-20T08:00:00Z') -ExpectedMatlabRoot 'C:\MATLAB'
            $r.ready | Should Be $true
        }
        It 'PID 相同但共享文件早于本次请求时不能通过' {
            $r = Get-MasDesktopStartupAssessment -LaunchId current -Receipt (New-DesktopTestReceipt) `
                -Session ([pscustomobject]@{pid=202;updatedAt='2026-10-20T07:59:00Z'}) -Processes (New-DesktopTestProcesses) `
                -NotBefore ([datetime]'2026-10-20T08:00:00Z') -ExpectedMatlabRoot 'C:\MATLAB'
            $r.ready | Should Be $false
            $r.reason | Should Be STALE_SHARED_SESSION
        }
        It '新鲜回执不能掩盖进程早于启动请求的事实' {
            $r = Get-MasDesktopStartupAssessment -LaunchId current -Receipt (New-DesktopTestReceipt) `
                -Session ([pscustomobject]@{pid=202;updatedAt='2026-10-20T08:00:03Z'}) -Processes (New-DesktopTestProcesses) `
                -NotBefore ([datetime]'2026-10-20T08:00:02Z') -ExpectedMatlabRoot 'C:\MATLAB'
            $r.ready | Should Be $false
            $r.reason | Should Be RUNTIME_PREDATES_LAUNCH
        }
        It '其他 MATLAB 安装的新 PID 不能冒充指定安装' {
            $r = Get-MasDesktopStartupAssessment -LaunchId current -Receipt (New-DesktopTestReceipt) `
                -Session ([pscustomobject]@{pid=202;updatedAt='2026-10-20T08:00:03Z'}) -Processes (New-DesktopTestProcesses) `
                -NotBefore ([datetime]'2026-10-20T08:00:00Z') -ExpectedMatlabRoot 'C:\OtherMATLAB'
            $r.ready | Should Be $false
            $r.reason | Should Be MATLAB_INSTALLATION_MISMATCH
        }
    }

    Describe '桌面启动计划与非敏感会话读取' {
        It 'COM 注册只接受官方桌面参数并匹配目标安装，拒绝附加命令' {
            $s = New-DesktopStartupSandbox
            try {
                $r = ConvertFrom-MasDesktopComRegistration -Command ('"' + $s.Exe + '" -desktop -MLAutomation') -ExpectedMatlabRoot $s.Root
                $r.progId | Should Be Matlab.Desktop.Application
                $r.executable | Should Be $s.Exe
                $null -eq (ConvertFrom-MasDesktopComRegistration -Command ($s.Exe + ' -desktop -MLAutomation -r unexpected')) | Should Be $true
                $null -eq (ConvertFrom-MasDesktopComRegistration -Command ($s.Exe + ' -desktop -MLAutomation') -ExpectedMatlabRoot 'C:\OtherMATLAB') | Should Be $true
            } finally { Remove-DesktopStartupSandbox $s }
        }
        It 'COM 新身份必须有唯一标记和匹配安装；已有 PID 明确返回非新实例' {
            $r = Get-MasDesktopComIdentity -Output "MAS_COM_ID_current 202 C:\MATLAB`r`n" -LaunchId current -ExpectedMatlabRoot 'C:\MATLAB' -BeforePids @(202)
            $r.isNew | Should Be $false
            $r.reason | Should Be NOT_NEW_COM_SHARED_SERVER
            $oldRejected=$false; $otherRejected=$false
            try { Get-MasDesktopComIdentity -Output 'MAS_COM_ID_old 202 C:\MATLAB' -LaunchId current -ExpectedMatlabRoot 'C:\MATLAB' | Out-Null } catch { $oldRejected=$true }
            try { Get-MasDesktopComIdentity -Output 'MAS_COM_ID_current 202 C:\Other' -LaunchId current -ExpectedMatlabRoot 'C:\MATLAB' | Out-Null } catch { $otherRejected=$true }
            $oldRejected | Should Be $true
            $otherRejected | Should Be $true
            $duplicateRejected=$false
            try { Get-MasDesktopComIdentity -Output "MAS_COM_ID_current 202 C:\MATLAB`nMAS_COM_ID_current 303 C:\MATLAB" -LaunchId current -ExpectedMatlabRoot 'C:\MATLAB' | Out-Null } catch { $duplicateRejected=$true }
            $duplicateRejected | Should Be $true
        }
        It '原生持有进程创建标志脱离 Job、无窗口且不继承标准句柄，测试只编译不启动' {
            $sourceFile = Join-Path $PSScriptRoot '../scripts/DesktopProcessNative.cs'
            if (-not ('MasDesktop.NativeProcess' -as [type])) { Add-Type -Path $sourceFile }
            [MasDesktop.NativeProcess]::CreationFlags | Should Be 150994944
            $source = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $sourceFile))
            $source | Should Match 'threadAttributes, \[MarshalAs\(UnmanagedType.Bool\)\] bool inheritHandles'
            $source | Should Match 'IntPtr.Zero, IntPtr.Zero, false,'
            $source | Should Not Match 'TerminateProcess\(|STARTF_USESTDHANDLES\s*='
        }
        It 'COM 共享已有实例时真实执行 holder 逻辑只发只读身份查询且不碰进程或回执' {
            $s = New-DesktopStartupSandbox
            try {
                $launch = [guid]::NewGuid().ToString('N')
                $configFile = Join-Path $s.Root 'holder.json'; $stateFile = Join-Path $s.Root 'state.json'
                $config = @{launchId=$launch;expectedMatlabRoot=$s.Root;beforePids=@(202);stateFile=$stateFile;scriptFile=(Join-Path $s.Root 'never-run.m')}
                [IO.File]::WriteAllText($configFile, ($config | ConvertTo-Json))
                $script:ComCommands = New-Object Collections.Generic.List[string]
                $script:ComIdentityResponse = "MAS_COM_ID_$launch 202 $($s.Root)`n"
                $script:FakeCom = [pscustomobject]@{Visible=0}
                $script:FakeCom | Add-Member -MemberType ScriptMethod -Name Execute -Value {
                    param($Command)
                    $script:ComCommands.Add($Command)
                    return $script:ComIdentityResponse
                }
                Mock New-MasDesktopComObject { return $script:FakeCom }
                Mock Get-Process { throw '已有实例不得进入新进程验证或持有循环' }
                Invoke-MasDesktopComHolder -ConfigFile $configFile
                $state = [IO.File]::ReadAllText($stateFile) | ConvertFrom-Json
                $state.status | Should Be NOT_NEW
                $state.reason | Should Be NOT_NEW_COM_SHARED_SERVER
                $script:ComCommands.Count | Should Be 1
                $script:ComCommands[0] | Should Match '^fprintf\('
                $script:ComCommands[0] | Should Not Match 'shareMATLABSession|run\(|clear|quit'
                $script:FakeCom.Visible | Should Be 0
                Assert-MockCalled Get-Process -Exactly 0 -Scope It
            } finally { Remove-DesktopStartupSandbox $s }
        }
        It '新 COM holder 保持强引用直到绑定运行时退出，轮询不向 MATLAB 注入等待或 Quit' {
            $s = New-DesktopStartupSandbox
            try {
                $launch=[guid]::NewGuid().ToString('N'); $stateFile=Join-Path $s.Root 'state.json'; $configFile=Join-Path $s.Root 'holder.json'
                $config=@{launchId=$launch;expectedMatlabRoot=$s.Root;beforePids=@();stateFile=$stateFile;scriptFile=(Join-Path $s.Root 'bootstrap.m');launchRequestedAt=[datetime]::UtcNow.AddMinutes(-1).ToString('o')}
                [IO.File]::WriteAllText($configFile,($config|ConvertTo-Json))
                $script:ComCommands=New-Object Collections.Generic.List[string]; $script:ComIdentityResponse="MAS_COM_ID_$launch 202 $($s.Root)`n"
                $script:FakeCom=[pscustomobject]@{Visible=0}
                $script:FakeCom | Add-Member ScriptMethod Execute { param($Command) $script:ComCommands.Add($Command); if($Command -like 'fprintf*'){return $script:ComIdentityResponse} }
                $script:RuntimePolls=0; $script:RuntimeDisposed=$false
                $script:FakeRuntime=[pscustomobject]@{ProcessName='MATLAB';StartTime=[datetime]::UtcNow}
                $script:FakeRuntime | Add-Member ScriptProperty HasExited { $script:RuntimePolls++; return ($script:RuntimePolls -gt 1) }
                $script:FakeRuntime | Add-Member ScriptMethod Dispose { $script:RuntimeDisposed=$true }
                Mock New-MasDesktopComObject { return $script:FakeCom }
                Mock Get-Process { return $script:FakeRuntime }
                Mock Start-Sleep { }
                Invoke-MasDesktopComHolder -ConfigFile $configFile
                $state=[IO.File]::ReadAllText($stateFile)|ConvertFrom-Json
                $state.status | Should Be EXITED
                $state.reason | Should Be BOUND_RUNTIME_EXITED
                $script:ComCommands.Count | Should Be 2
                $script:ComCommands[1] | Should Match '^run\('
                ($script:ComCommands -join ' ') | Should Not Match 'pause\(|timer\(|Quit\(|quit;|exit;'
                $script:FakeCom.Visible | Should Be 1
                $script:RuntimeDisposed | Should Be $true
                Assert-MockCalled Start-Sleep -Exactly 1 -Scope It
            } finally { Remove-DesktopStartupSandbox $s }
        }
        It 'COM 已激活但身份失败时保活本次新候选，报告仍为失败，不执行 bootstrap' {
            $s=New-DesktopStartupSandbox
            try {
                $launch=[guid]::NewGuid().ToString('N'); $configFile=Join-Path $s.Root 'holder.json'
                $config=@{launchId=$launch;expectedMatlabRoot=$s.Root;beforePids=@(99);stateFile=(Join-Path $s.Root 'state.json');scriptFile=(Join-Path $s.Root 'bootstrap.m');launchRequestedAt=[datetime]::UtcNow.AddMinutes(-1).ToString('o')}
                [IO.File]::WriteAllText($configFile,($config|ConvertTo-Json))
                $script:ComCommands=New-Object Collections.Generic.List[string]
                $script:StateSnapshots=New-Object Collections.Generic.List[string]
                $script:FakeCom=[pscustomobject]@{Visible=0}
                $script:FakeCom | Add-Member ScriptMethod Execute {param($Command) $script:ComCommands.Add($Command); return 'identity failed'}
                $script:RuntimePolls=0
                $script:FakeRuntime=[pscustomobject]@{Id=202;ProcessName='MATLAB';StartTime=[datetime]::UtcNow}
                $script:FakeRuntime | Add-Member ScriptProperty HasExited {$script:RuntimePolls++;return($script:RuntimePolls -gt 1)}
                $script:FakeRuntime | Add-Member ScriptMethod Dispose {}
                Mock New-MasDesktopComObject {return $script:FakeCom}
                Mock Get-MasMatlabDesktopProcesses { [pscustomobject]@{pid=202;path=$s.Exe;startedAt=[datetime]::UtcNow.ToString('o')} }
                Mock Get-Process {return $script:FakeRuntime}
                Mock Start-Sleep {}
                Mock Write-MasDesktopHolderState {param($StateFile,$State) $script:StateSnapshots.Add(($State|ConvertTo-Json -Depth 5))}
                Invoke-MasDesktopComHolder -ConfigFile $configFile
                $failed=$script:StateSnapshots[1]|ConvertFrom-Json
                $failed.status | Should Be FAILED
                $failed.reason | Should Be COM_IDENTITY_NOT_UNIQUE
                $failed.preservation | Should Be UNBOUND_NEW_PROCESSES
                $failed.unboundProcessPids[0] | Should Be 202
                ($script:StateSnapshots[2]|ConvertFrom-Json).status | Should Be EXITED
                $script:ComCommands.Count | Should Be 1
                Assert-MockCalled Start-Sleep -Exactly 1 -Scope It
            } finally {Remove-DesktopStartupSandbox $s}
        }
        It 'Shell 异常诊断有界且不会回显密钥和认证行' {
            $text = "Shell rejected path`napiKey=DO_NOT_LOG_THIS`nAuthorization: Bearer PRIVATE`n" + ('x' * 3000)
            $safe = Protect-MasDesktopDiagnosticText -Text $text
            ($safe.Length -le 2048) | Should Be $true
            $safe | Should Not Match 'DO_NOT_LOG_THIS|PRIVATE|apiKey|Bearer'
        }
        It '含空格和单引号路径的 MATLAB 命令有正确边界' {
            $plan = New-MasDesktopStartupPlan -MatlabExe 'C:\MATLAB\bin\matlab.exe' -WorkingDirectory "C:\Task's Folder" `
                -OutputDirectory "C:\Task's Folder\reports" -LaunchId sample
            $plan.argumentLine | Should Match '-sd "C:\\Task''s Folder"'
            $plan.argumentLine | Should Match "run\('C:/Task''s Folder/reports/desktop_bootstrap.m'\)"
            $plan.arguments -contains '-nodesktop' | Should Be $false
            $plan.arguments -contains '-batch' | Should Be $false
            $plan.scriptText | Should Not Match 'pause\(|timer\(|quit\(|exit\('
        }
        It 'Shortcut 模式实际 ShellExecute 只有真实 lnk 参数，不注入目录和命令' {
            $plan = New-MasDesktopStartupPlan -MatlabExe 'C:\MATLAB\bin\matlab.exe' -WorkingDirectory 'C:\task' `
                -OutputDirectory 'C:\task\logs' -LaunchId sample -LaunchMode Shortcut -ShortcutPath "C:\Desktop\MATLAB's shortcut.lnk"
            $plan.shellTarget | Should Be "C:\Desktop\MATLAB's shortcut.lnk"
            @($plan.arguments).Count | Should Be 0
            $null -eq $plan.workingDirectory | Should Be $true
            $null -eq $plan.logFile | Should Be $true
            $command = New-MasDesktopShellCommand -Plan $plan
            $command | Should Match "ShellExecute\('C:\\Desktop\\MATLAB''s shortcut.lnk'\);"
            $command | Should Not Match '-sd|-logfile|-r |open.*,1'
        }
        It '共享文件中的密钥和其他未知字段不进入结果对象' {
            $s = New-DesktopStartupSandbox
            try {
                [IO.File]::WriteAllText($s.Session, '{"pid":202,"port":12345,"apiKey":"DO_NOT_LOG_THIS","unknown":"PRIVATE"}')
                $r = Read-MasDesktopSession -SessionFile $s.Session
                $r.pid | Should Be 202
                $serialized = $r | ConvertTo-Json
                $serialized | Should Not Match 'apiKey|DO_NOT_LOG_THIS|PRIVATE'
            } finally { Remove-DesktopStartupSandbox $s }
        }
        It '半写入 JSON 或非法端口不返回候选共享会话' {
            $s = New-DesktopStartupSandbox
            try {
                [IO.File]::WriteAllText($s.Session, '{"pid":202,')
                $null -eq (Read-MasDesktopSession -SessionFile $s.Session) | Should Be $true
                [IO.File]::WriteAllText($s.Session, '{"pid":202,"port":65536}')
                $null -eq (Read-MasDesktopSession -SessionFile $s.Session) | Should Be $true
            } finally { Remove-DesktopStartupSandbox $s }
        }
        It '真实 PowerShell 辅助进程失败时保留脱敏 stderr 和退出码，不运行 Shell 或 MATLAB' {
            Mock New-MasDesktopShellCommand { "[Console]::Error.WriteLine('中文 diagnostic-failure'); [Console]::Error.WriteLine('apiKey=DO_NOT_LOG_THIS'); exit 7" }
            $observed = $null
            try { Start-MasDesktopViaShell -Plan ([pscustomobject]@{}) -TimeoutSeconds 5 | Out-Null }
            catch { $observed = $_.Exception.Data['desktopHelper'] }
            $null -ne $observed | Should Be $true
            $observed.helperExitCode | Should Be 7
            $observed.stderr | Should Match diagnostic-failure
            $observed.stderr | Should Match 中文
            $observed.stderr | Should Not Match 'apiKey|DO_NOT_LOG_THIS'
        }
        It '真实 PowerShell 辅助进程退出零也保留 stdout 和 stderr，不运行 Shell 或 MATLAB' {
            Mock New-MasDesktopShellCommand { "[Console]::Out.WriteLine('request-accepted'); [Console]::Error.WriteLine('diagnostic-warning'); exit 0" }
            $observed = Start-MasDesktopViaShell -Plan ([pscustomobject]@{}) -TimeoutSeconds 5
            $observed.helperExitCode | Should Be 0
            $observed.stdout | Should Match request-accepted
            $observed.stderr | Should Match diagnostic-warning
        }
    }

    Describe '启动器集成控制：所有进程均为模拟' {
        BeforeEach {
            $script:DesktopSandbox = New-DesktopStartupSandbox
            $script:SimulatedBefore = @()
            $script:SimulatedAfter = New-DesktopTestProcesses
            $script:SimulatedSessionBefore = $null
            $script:SimulatedSessionAfter = [pscustomobject]@{pid=202;port=12345}
            $script:SimulatedLaunched = $false
            $script:SimulatedWriteReceipt = $true
            $script:SimulatedShellError = $false
            $script:SimulatedComStatus = 'HOLDING'
            $script:SimulatedHolderAlive = $true
            $script:SimulatedComRuntime = 202
            Mock Get-MasDesktopComRegistration {
                [pscustomobject]@{progId='Matlab.Desktop.Application';executable=$script:DesktopSandbox.Exe;matlabRoot=$script:DesktopSandbox.Root}
            }
            Mock Test-MasDesktopHolderAlive { return $script:SimulatedHolderAlive }
            Mock Read-MasDesktopHolderState {
                [pscustomobject]@{status=$script:SimulatedComStatus;runtimePid=$script:SimulatedComRuntime;reason='simulated-com-state'}
            }
            Mock Start-MasDesktopComHolder {
                param($Plan)
                $script:SimulatedLaunched=$true
                $script:SimulatedSessionAfter | Add-Member -MemberType NoteProperty -Name updatedAt -Value ([datetime]::UtcNow.ToString('o')) -Force
                foreach ($entry in $script:SimulatedAfter) { $entry.path=$script:DesktopSandbox.Exe; $entry.startedAt=[datetime]::UtcNow.ToString('o') }
                if ($script:SimulatedWriteReceipt) {
                    [IO.File]::WriteAllText($Plan.receiptFile, ((New-DesktopTestReceipt -LaunchId $Plan.launchId) | ConvertTo-Json))
                }
                [pscustomobject]@{holderPid=999;stateFile=(Join-Path $script:DesktopSandbox.Root 'holder-state.json');creationFlags='CREATE_BREAKAWAY_FROM_JOB|CREATE_NO_WINDOW';inheritHandles=$false}
            }
            Mock Get-MasDesktopShortcut {
                [pscustomobject]@{path=(Join-Path $script:DesktopSandbox.Root 'matlab.lnk');target=$script:DesktopSandbox.Exe}
            }
            Mock Get-MasMatlabDesktopProcesses {
                if ($script:SimulatedLaunched) { return $script:SimulatedAfter }
                return $script:SimulatedBefore
            }
            Mock Read-MasDesktopSession {
                if ($script:SimulatedLaunched) { return $script:SimulatedSessionAfter }
                return $script:SimulatedSessionBefore
            }
            Mock Start-MasDesktopViaShell {
                param($Plan, $TimeoutSeconds)
                if ($script:SimulatedShellError) { throw 'simulated shell launch failure' }
                $script:SimulatedLaunched = $true
                $script:SimulatedSessionAfter | Add-Member -MemberType NoteProperty -Name updatedAt -Value ([datetime]::UtcNow.ToString('o')) -Force
                foreach ($entry in $script:SimulatedAfter) {
                    $entry.path = $script:DesktopSandbox.Exe
                    $entry.startedAt = [datetime]::UtcNow.ToString('o')
                }
                if ($script:SimulatedWriteReceipt) {
                    $launchMarker = [regex]::Match($Plan.scriptText, "'launchId','([a-f0-9]+)'").Groups[1].Value
                    $receipt = New-DesktopTestReceipt -LaunchId $launchMarker
                    [IO.File]::WriteAllText($Plan.receiptFile, ($receipt | ConvertTo-Json))
                }
                return [pscustomobject]@{helperPid=999;helperExitCode=0}
            }
        }
        AfterEach { Remove-DesktopStartupSandbox $script:DesktopSandbox }

        It 'COM 新回执须与存活 holder 的 HOLDING 运行时绑定，且不调用 Shell' {
            $s = $script:DesktopSandbox
            $r = Start-MasMatlabDesktop -MatlabExe $s.Exe -WorkingDirectory $s.Root -OutputDirectory $s.Output -SessionFile $s.Session -LaunchMode ComDesktop -TimeoutSeconds 2
            $r.status | Should Be READY
            $r.launchMethod | Should Be RegisteredComDesktopHolder
            $r.runtimePid | Should Be 202
            $r.holder.holderPid | Should Be 999
            $r.newSessionVerified | Should Be $true
            $r.coldStartVerified | Should Be $true
            $r.mcpExecutionVerified | Should Be $false
            Assert-MockCalled Start-MasDesktopViaShell -Exactly 0 -Scope It
            Assert-MockCalled Start-MasDesktopComHolder -Exactly 1 -Scope It
        }
        It 'COM 共享实例返回已有 PID 时明确 NOT_NEW，不能算另开或冷启动' {
            $s = $script:DesktopSandbox
            $script:SimulatedBefore = New-DesktopTestProcesses -RuntimeNumber 89 -DesktopNumber 88
            $script:SimulatedComStatus='NOT_NEW'; $script:SimulatedComRuntime=89; $script:SimulatedWriteReceipt=$false
            $r = Start-MasMatlabDesktop -MatlabExe $s.Exe -WorkingDirectory $s.Root -OutputDirectory $s.Output -SessionFile $s.Session -LaunchMode ComDesktop -TimeoutSeconds 2 -NewSession
            $r.status | Should Be NOT_NEW
            $r.reason | Should Be NOT_NEW_COM_SHARED_SERVER
            $r.runtimePid | Should Be 89
            $r.bootstrapReached | Should Be $false
            $r.newSessionVerified | Should Be $false
            $r.coldStartVerified | Should Be $false
            Assert-MockCalled Start-MasDesktopViaShell -Exactly 0 -Scope It
        }
        It 'COM holder 已退出时即使存在正确回执也不能报就绪' {
            $s = $script:DesktopSandbox
            $script:SimulatedHolderAlive=$false
            $r = Start-MasMatlabDesktop -MatlabExe $s.Exe -WorkingDirectory $s.Root -OutputDirectory $s.Output -SessionFile $s.Session -LaunchMode ComDesktop -TimeoutSeconds 2
            $r.status | Should Be START_FAILED
            $r.reason | Should Be COM_HOLDER_OR_RUNTIME_EXITED
            $r.newSessionVerified | Should Be $false
        }
        It 'COM holder 绑定其他运行时不能用正确回执掩盖，超时保留进程' {
            $s = $script:DesktopSandbox
            $script:SimulatedComRuntime=909
            Mock Stop-Process { throw '不能结束 holder 或 MATLAB' }
            $r = Start-MasMatlabDesktop -MatlabExe $s.Exe -WorkingDirectory $s.Root -OutputDirectory $s.Output -SessionFile $s.Session -LaunchMode ComDesktop -TimeoutSeconds 1
            $r.status | Should Be TIMEOUT
            $r.reason | Should Be COM_HOLDER_NOT_BOUND
            $r.newSessionVerified | Should Be $false
            Assert-MockCalled Stop-Process -Exactly 0 -Scope It
        }
        It 'COM 激活后失败不得自动降级 Shell 再开一个实例' {
            $s = $script:DesktopSandbox
            $script:SimulatedComStatus='FAILED'
            $r = Start-MasMatlabDesktop -MatlabExe $s.Exe -WorkingDirectory $s.Root -OutputDirectory $s.Output -SessionFile $s.Session -LaunchMode ComDesktop -TimeoutSeconds 2
            $r.status | Should Be START_FAILED
            $r.reason | Should Be simulated-com-state
            Assert-MockCalled Start-MasDesktopViaShell -Exactly 0 -Scope It
        }
        It 'COM 确认也要求 holder 存活且 HOLDING，不能绕过主流程保护' {
            $s=$script:DesktopSandbox
            $r=Start-MasMatlabDesktop -MatlabExe $s.Exe -WorkingDirectory $s.Root -OutputDirectory $s.Output -SessionFile $s.Session -LaunchMode ComDesktop -TimeoutSeconds 2
            $r.status | Should Be READY
            foreach($badState in @('FAILED','EXITED')) {
                $script:SimulatedComStatus=$badState
                $rejected=$false
                try { Confirm-MasDesktopStartupReceipt -ReportPath $r.reportPath | Out-Null } catch { $rejected=$true }
                $rejected | Should Be $true
            }
            $script:SimulatedComStatus='HOLDING'; $script:SimulatedHolderAlive=$false
            $rejected=$false
            try { Confirm-MasDesktopStartupReceipt -ReportPath $r.reportPath | Out-Null } catch { $rejected=$true }
            $rejected | Should Be $true
            ([IO.File]::ReadAllText($r.reportPath)|ConvertFrom-Json).confirmedAt | Should Be $null
        }
        It 'COM DryRun 仅检查注册并显示计划，不创建 holder 或文件' {
            $s = $script:DesktopSandbox
            $r = Start-MasMatlabDesktop -MatlabExe $s.Exe -WorkingDirectory $s.Root -OutputDirectory $s.Output -SessionFile $s.Session -LaunchMode ComDesktop -DryRun
            $r.status | Should Be DRY_RUN
            (Test-Path -LiteralPath $s.Output) | Should Be $false
            Assert-MockCalled Start-MasDesktopComHolder -Exactly 0 -Scope It
        }
        It '模拟新启动记录 runtime、父窗口、launcher，并与 MCP 执行证明分开' {
            $s = $script:DesktopSandbox
            $r = Start-MasMatlabDesktop -MatlabExe $s.Exe -WorkingDirectory $s.Root -OutputDirectory $s.Output -SessionFile $s.Session -TimeoutSeconds 2
            $r.status | Should Be READY
            $r.runtimePid | Should Be 202
            $r.launcherPid | Should Be 201
            $r.newSessionVerified | Should Be $true
            $r.coldStartVerified | Should Be $true
            $r.mcpExecutionVerified | Should Be $false
            (Test-Path -LiteralPath $r.reportPath) | Should Be $true
            Assert-MockCalled Start-MasDesktopViaShell -Exactly 1 -Scope It
        }
        It '已有共享桌面时复用且从不调用启动器' {
            $s = $script:DesktopSandbox
            $script:SimulatedBefore = New-DesktopTestProcesses
            $script:SimulatedSessionBefore = [pscustomobject]@{pid=202;port=12345;updatedAt='2026-10-20T08:00:02Z'}
            $r = Start-MasMatlabDesktop -WorkingDirectory $s.Root -OutputDirectory $s.Output -SessionFile $s.Session
            $r.status | Should Be REUSED_EXISTING
            $r.reused | Should Be $true
            $r.coldStartVerified | Should Be $false
            $r.newSessionVerified | Should Be $false
            Assert-MockCalled Start-MasDesktopViaShell -Exactly 0 -Scope It
        }
        It '已有未共享的 MATLAB 时默认保留并不创建重复实例' {
            $s = $script:DesktopSandbox
            $script:SimulatedBefore = New-DesktopTestProcesses
            $r = Start-MasMatlabDesktop -WorkingDirectory $s.Root -OutputDirectory $s.Output -SessionFile $s.Session
            $r.status | Should Be EXISTING_NOT_READY
            Assert-MockCalled Start-MasDesktopViaShell -Exactly 0 -Scope It
        }
        It '显式要求另一套 MATLAB 时不会复用错误安装的已有会话' {
            $s = $script:DesktopSandbox
            $script:SimulatedBefore = New-DesktopTestProcesses
            $script:SimulatedSessionBefore = [pscustomobject]@{pid=202;port=12345;updatedAt='2026-10-20T08:00:02Z'}
            $r = Start-MasMatlabDesktop -MatlabExe $s.Exe -WorkingDirectory $s.Root -OutputDirectory $s.Output -SessionFile $s.Session
            $r.status | Should Be EXISTING_NOT_READY
            $r.reused | Should Be $false
            Assert-MockCalled Start-MasDesktopViaShell -Exactly 0 -Scope It
        }
        It '明确另开实例时保留已有 PID，报告不记冷启动' {
            $s = $script:DesktopSandbox
            $script:SimulatedBefore = New-DesktopTestProcesses -RuntimeNumber 89 -DesktopNumber 88
            $r = Start-MasMatlabDesktop -MatlabExe $s.Exe -WorkingDirectory $s.Root -OutputDirectory $s.Output `
                -SessionFile $s.Session -TimeoutSeconds 2 -NewSession
            $r.status | Should Be READY
            $r.beforeProcesses.pid -contains 89 | Should Be $true
            $r.coldStartVerified | Should Be $false
        }
        It '复用路径也拒绝早于当前进程创建时间的旧共享文件' {
            $s = $script:DesktopSandbox
            $script:SimulatedBefore = New-DesktopTestProcesses
            $script:SimulatedSessionBefore = [pscustomobject]@{pid=202;port=12345;updatedAt='2026-10-20T07:59:00Z'}
            $r = Start-MasMatlabDesktop -WorkingDirectory $s.Root -OutputDirectory $s.Output -SessionFile $s.Session
            $r.status | Should Be EXISTING_NOT_READY
            $r.reused | Should Be $false
            Assert-MockCalled Start-MasDesktopViaShell -Exactly 0 -Scope It
        }
        It 'DryRun 不启动进程，也不创建目录' {
            $s = $script:DesktopSandbox
            $r = Start-MasMatlabDesktop -MatlabExe $s.Exe -WorkingDirectory $s.Root -OutputDirectory $s.Output -SessionFile $s.Session -DryRun
            $r.status | Should Be DRY_RUN
            (Test-Path -LiteralPath $s.Output) | Should Be $false
            Assert-MockCalled Start-MasDesktopViaShell -Exactly 0 -Scope It
        }
        It '等待超时写可审查报告，不结束任何 MATLAB' {
            $s = $script:DesktopSandbox
            $script:SimulatedWriteReceipt = $false
            Mock Stop-Process { throw '不得终止用户进程' }
            $r = Start-MasMatlabDesktop -MatlabExe $s.Exe -WorkingDirectory $s.Root -OutputDirectory $s.Output -SessionFile $s.Session -TimeoutSeconds 1
            $r.status | Should Be TIMEOUT
            $r.bootstrapReached | Should Be $false
            $r.reason | Should Be BOOTSTRAP_NOT_OBSERVED
            (Test-Path -LiteralPath $r.reportPath) | Should Be $true
            Assert-MockCalled Stop-Process -Exactly 0 -Scope It
        }
        It 'Shell 启动失败保留诊断报告' {
            $s = $script:DesktopSandbox
            $script:SimulatedShellError = $true
            $r = Start-MasMatlabDesktop -MatlabExe $s.Exe -WorkingDirectory $s.Root -OutputDirectory $s.Output -SessionFile $s.Session -TimeoutSeconds 2
            $r.status | Should Be START_FAILED
            (Get-Content -LiteralPath $r.reportPath -Raw) | Should Match 'simulated shell launch failure'
        }
        It 'Shortcut 新共享桌面只记候选，不能提前报新启动或冷启动通过' {
            $s = $script:DesktopSandbox
            $script:SimulatedWriteReceipt = $false
            $r = Start-MasMatlabDesktop -MatlabExe $s.Exe -WorkingDirectory $s.Root -OutputDirectory $s.Output `
                -SessionFile $s.Session -LaunchMode Shortcut -ShortcutPath (Join-Path $s.Root 'matlab.lnk') -TimeoutSeconds 2
            $r.status | Should Be SHARED_DESKTOP_CANDIDATE
            $r.readyForMcp | Should Be $true
            $r.newSessionVerified | Should Be $false
            $r.coldStartVerified | Should Be $false
            (Get-Content -LiteralPath $r.mcpCodeFile -Raw) | Should Match "feature\('getpid'\) == 202"
        }
        It '快捷方式候选取得绑定回执后可确认，确认动作不再调用启动器' {
            $s = $script:DesktopSandbox
            $script:SimulatedWriteReceipt = $false
            $r = Start-MasMatlabDesktop -MatlabExe $s.Exe -WorkingDirectory $s.Root -OutputDirectory $s.Output `
                -SessionFile $s.Session -LaunchMode Shortcut -TimeoutSeconds 2
            [IO.File]::WriteAllText($r.receiptFile, ((New-DesktopTestReceipt -LaunchId $r.launchId) | ConvertTo-Json))
            $confirmed = Confirm-MasDesktopStartupReceipt -ReportPath $r.reportPath
            $confirmed.status | Should Be READY
            $confirmed.initialStatus | Should Be SHARED_DESKTOP_CANDIDATE
            $confirmed.newSessionVerified | Should Be $true
            $confirmed.coldStartVerified | Should Be $true
            $confirmed.mcpExecutionVerified | Should Be $false
            $reconfirmed = Confirm-MasDesktopStartupReceipt -ReportPath $r.reportPath
            $reconfirmed.initialStatus | Should Be SHARED_DESKTOP_CANDIDATE
            (Test-Path -LiteralPath (Join-Path $r.outputDirectory 'startup_report.before_confirmation.json')) | Should Be $true
            Assert-MockCalled Start-MasDesktopViaShell -Exactly 1 -Scope It
        }
        It '快捷方式候选的共享文件过期时确认失败，原候选报告保持未通过' {
            $s = $script:DesktopSandbox
            $script:SimulatedWriteReceipt = $false
            $r = Start-MasMatlabDesktop -MatlabExe $s.Exe -WorkingDirectory $s.Root -OutputDirectory $s.Output `
                -SessionFile $s.Session -LaunchMode Shortcut -TimeoutSeconds 2
            [IO.File]::WriteAllText($r.receiptFile, ((New-DesktopTestReceipt -LaunchId $r.launchId) | ConvertTo-Json))
            $script:SimulatedSessionAfter.updatedAt = ([datetime]$r.launchRequestedAt).ToUniversalTime().AddMinutes(-1).ToString('o')
            $caught = $false
            try { Confirm-MasDesktopStartupReceipt -ReportPath $r.reportPath | Out-Null } catch { $caught = $true }
            $caught | Should Be $true
            ([IO.File]::ReadAllText($r.reportPath) | ConvertFrom-Json).status | Should Be SHARED_DESKTOP_CANDIDATE
        }
    }
}
