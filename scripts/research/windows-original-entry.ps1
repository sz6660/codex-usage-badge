param([ValidateSet('x64','arm64')][string]$Architecture='x64')
$ErrorActionPreference='Stop'
# This script must never be used to test a developer's real desktop/profile.
if($env:GITHUB_ACTIONS -ne 'true' -or !$env:RUNNER_TEMP -or !$env:GITHUB_WORKSPACE) { throw 'GitHub-hosted Actions VM only' }
$root=Join-Path $env:RUNNER_TEMP ('codex-entry-research-'+[guid]::NewGuid().ToString('N'))
$output=Join-Path $env:GITHUB_WORKSPACE 'research-output'
[void][IO.Directory]::CreateDirectory($root)
[void][IO.Directory]::CreateDirectory($output)
$report=[ordered]@{version='26.1013.4894.0';architecture=$Architecture;os=(Get-CimInstance Win32_OperatingSystem).Caption;sessionId=(Get-Process -Id $PID).SessionId;installed=$false;entry='IApplicationActivationManager.ActivateApplication, empty arguments, AO_NONE';cases=@();errors=@()}
function Save-Report { $report | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $output 'report.json') -Encoding UTF8 }
$keys=@('BUILD_FLAVOR','CODEX_ELECTRON_CHROMIUM_SWITCHES','CODEX_ELECTRON_USER_DATA_PATH','CODEX_HOME')
$saved=@{}
foreach($key in $keys){$saved[$key]=[Environment]::GetEnvironmentVariable($key,'User')}
$eventNames=@()
$appInstall=$null
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class ResearchWindow { public uint Pid; public long Handle; public string Class; }
[ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IResearchActivationManager {
 [PreserveSig] int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string id, [MarshalAs(UnmanagedType.LPWStr)] string args, uint flags, out uint pid);
}
[ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")] class ResearchActivationManager {}
public static class EntryResearch {
 delegate bool EnumProc(IntPtr hwnd, IntPtr lparam);
 [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr param);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd,StringBuilder text,int count);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr SendMessageTimeout(IntPtr hwnd,uint msg,UIntPtr wparam,string lparam,uint flags,uint timeout,out UIntPtr result);
 public static void NotifyEnvironment(){UIntPtr result;SendMessageTimeout(new IntPtr(0xffff),0x1a,UIntPtr.Zero,"Environment",2,3000,out result);}
 public static uint Activate(string id){uint pid;var manager=(IResearchActivationManager)new ResearchActivationManager();int hr=manager.ActivateApplication(id,"",0,out pid);Marshal.ThrowExceptionForHR(hr);return pid;}
 public static ResearchWindow[] Windows(uint[] ids){var found=new List<ResearchWindow>();var wanted=new HashSet<uint>(ids);EnumWindows((h,p)=>{uint id;GetWindowThreadProcessId(h,out id);if(wanted.Contains(id)&&IsWindowVisible(h)){var text=new StringBuilder(256);GetClassName(h,text,256);found.Add(new ResearchWindow{Pid=id,Handle=h.ToInt64(),Class=text.ToString()});}return true;},IntPtr.Zero);return found.ToArray();}
}
'@
function Set-TestEnvironment($values){
    foreach($key in $keys){$value=$values[$key];[Environment]::SetEnvironmentVariable($key,$value,'User');[Environment]::SetEnvironmentVariable($key,$value,'Process')}
    [EntryResearch]::NotifyEnvironment()
}
function Get-TestProcesses {
    @(Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($appInstall,[StringComparison]::OrdinalIgnoreCase) })
}
function Stop-TestProcesses {
    if(!$appInstall){return}
    foreach($p in @(Get-TestProcesses)){Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue}
    Start-Sleep -Seconds 2
}
try {
    Save-Report
    $url="https://persistent.oaistatic.com/codex-app-prod/releases/26.1013.4894.0/ChatGPT-$Architecture.msix"
    $package=Join-Path $root 'Codex.msix'
    Write-Host "Downloading official $Architecture package $($report.version)"
    $ProgressPreference='SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $package -UseBasicParsing
    $report.packageSha256=(Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead($package)
    try{$reader=New-Object IO.StreamReader($zip.GetEntry('AppxManifest.xml').Open());try{$manifestText=$reader.ReadToEnd()}finally{$reader.Dispose()}}finally{$zip.Dispose()}
    $manifestText | Set-Content -LiteralPath (Join-Path $output 'official-AppxManifest.xml') -Encoding UTF8
    [xml]$manifest=$manifestText
    $report.dependencies=@($manifest.Package.Dependencies.ChildNodes | ForEach-Object {$_.OuterXml})
    Save-Report
    Add-AppxPackage -Path $package -ErrorAction Stop
    $installed=Get-AppxPackage -Name OpenAI.Codex | Select-Object -First 1
    if(!$installed){throw 'Official package did not register'}
    $appInstall=$installed.InstallLocation
    $appId=@($manifest.Package.Applications.Application)[0].Id
    $aumid=$installed.PackageFamilyName+'!'+$appId
    $report.installed=$true;$report.packageFamily=$installed.PackageFamilyName;$report.aumid=$aumid
    $asar=Join-Path $appInstall 'app/resources/app.asar'
    $beforeHash=(Get-FileHash -LiteralPath $asar -Algorithm SHA256).Hash
    $report.originalAsarSha256=$beforeHash
    Save-Report
    $port=49327
    $switches=@{'remote-debugging-address'='127.0.0.1';'remote-debugging-port'=[string]$port}|ConvertTo-Json -Compress
    foreach($name in @('baseline','switches-only','dev-override','dev-override-repeat')){
        Stop-TestProcesses
        $caseRoot=Join-Path $root $name
        [void][IO.Directory]::CreateDirectory($caseRoot)
        $values=@{CODEX_HOME=(Join-Path $caseRoot 'codex-home');CODEX_ELECTRON_USER_DATA_PATH=(Join-Path $caseRoot 'electron-data')}
        if($name -ne 'baseline'){$values.CODEX_ELECTRON_CHROMIUM_SWITCHES=$switches}
        if($name -like 'dev-override*'){$values.BUILD_FLAVOR='dev'}
        Set-TestEnvironment $values
        $case=[ordered]@{name=$name;activationCalls=1;arguments='';startedAt=[DateTime]::UtcNow.ToString('o');processes=@();windows=@();trace=@();firstVisibleMs=$null;debugPortReadyMs=$null;agentInjectedMs=$null;visiblePidChanged=$false;errors=@()}
        $report.cases+=,$case
        $seen=@{};$known=@{};$firstVisiblePid=$null
        $agent=$null
        $agentStop=Join-Path $caseRoot 'agent-stop.request'
        $agentOut=Join-Path $output ($name+'-agent.out.log')
        $eventNames=@(('research-start-'+$name),('research-stop-'+$name))
        try {
            Register-WmiEvent -Query "SELECT * FROM Win32_ProcessStartTrace WHERE ProcessName='ChatGPT.exe'" -SourceIdentifier $eventNames[0] | Out-Null
            Register-WmiEvent -Query "SELECT * FROM Win32_ProcessStopTrace WHERE ProcessName='ChatGPT.exe'" -SourceIdentifier $eventNames[1] | Out-Null
            if($name -like 'dev-override*'){
                $appExe=Join-Path $appInstall 'app/ChatGPT.exe'
                $codexBin=& node -e "process.stdout.write(require('./agent.cjs').resolveCodexBin('',process.argv[1]))" $appExe
                if($LASTEXITCODE -ne 0 -or !$codexBin){throw 'Cannot resolve isolated official CLI for real badge agent'}
                $env:CODEX_BADGE_STOP_FILE=$agentStop
                $agentPath=Join-Path $env:GITHUB_WORKSPACE 'agent.cjs'
                $agentArgs=@(('"'+$agentPath+'"'),'--port',[string]$port,'--app',('"'+$appExe+'"'),'--codex-bin',('"'+$codexBin+'"'))
                $agent=Start-Process -FilePath (Get-Command node).Source -ArgumentList $agentArgs -PassThru -WindowStyle Hidden -RedirectStandardOutput $agentOut -RedirectStandardError (Join-Path $output ($name+'-agent.err.log'))
                Start-Sleep -Seconds 1
                if($agent.HasExited){throw 'Isolated real badge agent exited before activation'}
                $case.agentStartedBeforeActivation=$true
            }
            $timer=[Diagnostics.Stopwatch]::StartNew()
            $case.activationPid=[EntryResearch]::Activate($aumid)
            $case.activationReturnedMs=$timer.ElapsedMilliseconds
            while($timer.Elapsed.TotalSeconds -lt 65){
                $processes=@(Get-TestProcesses)
                foreach($p in $processes){
                    $id=[string]$p.ProcessId;$known[$id]=$true
                    if(!$seen.ContainsKey($id)){
                        $row=[ordered]@{pid=$p.ProcessId;parent=$p.ParentProcessId;firstSeenMs=$timer.ElapsedMilliseconds;commandLine=$p.CommandLine}
                        $seen[$id]=$row;$case.processes+=,$row
                    }
                }
                $ids=@($processes|ForEach-Object {[uint32]$_.ProcessId})
                if($ids.Count){
                    foreach($w in @([EntryResearch]::Windows([uint32[]]$ids))){
                        if(!@($case.windows|Where-Object {$_.handle -eq $w.Handle}).Count){$case.windows+=,[ordered]@{pid=$w.Pid;handle=$w.Handle;class=$w.Class;firstSeenMs=$timer.ElapsedMilliseconds}}
                        if($w.Class -like 'Chrome_WidgetWin*'){
                            if($null -eq $case.firstVisibleMs){$case.firstVisibleMs=$timer.ElapsedMilliseconds;$firstVisiblePid=$w.Pid}
                            elseif($firstVisiblePid -ne $w.Pid){$case.visiblePidChanged=$true}
                        }
                    }
                }
                foreach($eventName in $eventNames){
                    foreach($event in @(Get-Event -SourceIdentifier $eventName -ErrorAction SilentlyContinue)){
                        $data=$event.SourceEventArgs.NewEvent
                        $case.trace+=,[ordered]@{kind=($eventName.Split('-')[1]);pid=$data.ProcessID;parent=$data.ParentProcessID;elapsedMs=$timer.ElapsedMilliseconds}
                        Remove-Event -EventIdentifier $event.EventIdentifier
                    }
                }
                if($null -eq $case.debugPortReadyMs){
                    try{$targets=Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -TimeoutSec 1;$case.debugPortReadyMs=$timer.ElapsedMilliseconds}catch{}
                }
                if($agent -and $null -eq $case.agentInjectedMs -and (Test-Path -LiteralPath $agentOut)){
                    $agentLog=Get-Content -LiteralPath $agentOut -Raw -Encoding UTF8
                    # Match the fixed log suffix emitted only after a successful scan.
                    if($agentLog -and $agentLog.Contains(([char]0x5df2).ToString()+([char]0x6ce8).ToString()+([char]0x5165).ToString())){$case.agentInjectedMs=$timer.ElapsedMilliseconds}
                }
                if($name -like 'dev-override*' -and $null -ne $case.debugPortReadyMs -and $timer.Elapsed.TotalSeconds -ge 30){break}
                if($name -notlike 'dev-override*' -and $timer.Elapsed.TotalSeconds -ge 40){break}
                Start-Sleep -Milliseconds 500
            }
            $case.beforeInjectionPids=@(Get-TestProcesses|Where-Object {$_.CommandLine -notmatch '--type='}|ForEach-Object {$_.ProcessId})
            $probeArgs=@((Join-Path $PSScriptRoot 'probe-renderer.cjs'),[string]$port,(Join-Path $output ($name+'-renderer.json')))
            if($agent){$probeArgs+='--observe-only'}
            & node @probeArgs
            if($LASTEXITCODE -ne 0){$case.errors+='Renderer probe process failed'}
            Start-Sleep -Seconds 15
            $case.afterInjectionPids=@(Get-TestProcesses|Where-Object {$_.CommandLine -notmatch '--type='}|ForEach-Object {$_.ProcessId})
            $case.sameMainProcessAcrossInjection=($case.beforeInjectionPids.Count -gt 0 -and $case.afterInjectionPids.Count -gt 0 -and @(Compare-Object $case.beforeInjectionPids $case.afterInjectionPids).Count -eq 0)
        } catch {$case.errors+=$_.Exception.Message}
        finally {
            if($agent){
                [IO.File]::WriteAllText($agentStop,'stop')
                if(!$agent.WaitForExit(5000)){Stop-Process -Id $agent.Id -Force -ErrorAction SilentlyContinue}
            }
            foreach($eventName in $eventNames){Unregister-Event -SourceIdentifier $eventName -ErrorAction SilentlyContinue;Get-Event -SourceIdentifier $eventName -ErrorAction SilentlyContinue|Remove-Event}
            $eventNames=@()
            Save-Report
            Write-Host (@{name=$case.name;firstVisibleMs=$case.firstVisibleMs;debugPortReadyMs=$case.debugPortReadyMs;agentInjectedMs=$case.agentInjectedMs;sameMainProcess=$case.sameMainProcessAcrossInjection;errors=$case.errors}|ConvertTo-Json -Depth 5 -Compress)
        }
    }
    $report.asarUnchanged=((Get-FileHash -LiteralPath $asar -Algorithm SHA256).Hash -eq $beforeHash)
} catch {
    $report.errors+=$_.Exception.ToString()
    Write-Warning $_.Exception.Message
} finally {
    Stop-TestProcesses
    foreach($key in $keys){[Environment]::SetEnvironmentVariable($key,$saved[$key],'User')}
    [EntryResearch]::NotifyEnvironment()
    Save-Report
}
if(!$report.installed -or $report.errors.Count -or @($report.cases|Where-Object {$_.errors.Count}).Count){throw 'Research environment or case execution failed; see report.json'}
