param([string]$AppExe,[string]$StopFile,[int]$ParentId,[switch]$Functions,[switch]$Recover)
$ErrorActionPreference='Stop'
function Get-ActivationMainPids {
    @(Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe' OR Name='Codex.exe'" -ErrorAction Stop |
      Where-Object {($_.ExecutablePath -eq $AppExe -or !$_.ExecutablePath) -and (!$_.CommandLine -or $_.CommandLine -notmatch '--type=')} |
      ForEach-Object {[int]$_.ProcessId})
}
function Test-ActivationPort {
    try {
        $response=Invoke-RestMethod -Uri 'http://127.0.0.1:39222/json/list' -TimeoutSec 1 -UseBasicParsing
        return @($response | Where-Object {$_.type -eq 'page' -and $_.url -match '^app://-/index\.html(?:[?#]|$)' -and $_.url -notmatch '(?i)overlay'}).Count -gt 0
    } catch {return $false}
}
function Get-ActivationEvents([long]$After) {
    $query="*[System[(EventID=210 or EventID=211 or EventID=217) and EventRecordID > $After]]"
    $events=@(Get-WinEvent -LogName 'Microsoft-Windows-AppModel-Runtime/Admin' -FilterXPath $query -MaxEvents 257 -ErrorAction SilentlyContinue)
    $script:ObservedCursor=$After
    foreach($entry in $events){$script:ObservedCursor=[Math]::Max($script:ObservedCursor,[long]$entry.RecordId)}
    if($events.Count -gt 256){throw 'Activation event backlog; collector must restart without replay'}
    @($events | Sort-Object RecordId | ForEach-Object {
        $x=[xml]$_.ToXml();$fields=@{}
        foreach($item in $x.Event.EventData.Data){$fields[$item.Name]=$item.'#text'}
        if($fields.PackageName -eq $script:ActivationPackage){
            @{id=$_.Id;recordId=$_.RecordId;time=([DateTimeOffset]$_.TimeCreated).ToUnixTimeMilliseconds();
              container=$fields.ContainerId;pid=if($fields.ProcessID){[int]$fields.ProcessID}else{0}}
        }
    })
}
function Start-OriginalActivation {
    if((Get-ActivationMainPids).Count -gt 0 -or (Test-ActivationPort)){return @{launched=$false;reason='client-already-running'}}
    if((Test-Path -LiteralPath $StopFile) -or !(Get-Process -Id $ParentId -ErrorAction SilentlyContinue)){return @{launched=$false;reason='watcher-stopped'}}
    # Never invoke a stale executable path or replace the user's shortcut.
    $pkg=Get-AppxPackage | Where-Object {$_.PackageFullName -eq $script:ActivationPackage} | Select-Object -First 1
    if(!$pkg){return @{launched=$false;reason='package-not-found'}}
    $manifest=Get-AppxPackageManifest -Package $pkg.PackageFullName
    $app=@($manifest.Package.Applications.Application | Where-Object {
        (Join-Path $pkg.InstallLocation ([string]$_.Executable).Replace('/', '\')) -eq $AppExe
    })
    if($app.Count -ne 1){return @{launched=$false;reason='ambiguous-original-entry'}}
    $entry='shell:AppsFolder\'+$pkg.PackageFamilyName+'!'+[string]$app[0].Id
    if((Get-ActivationMainPids).Count -gt 0 -or (Test-ActivationPort) -or (Test-Path -LiteralPath $StopFile)){
        return @{launched=$false;reason='client-started-during-validation'}
    }
    Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList $entry -WindowStyle Hidden | Out-Null
    return @{launched=$true}
}
if($Functions){return}
try {
    $package=Get-AppxPackage | Where-Object {
        $_.InstallLocation -and $AppExe.StartsWith($_.InstallLocation+'\',[StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1
    if(!$package){throw 'Original Store package not found; lost-launch recovery unavailable'}
    $script:ActivationPackage=$package.PackageFullName
    if($Recover){Start-OriginalActivation | ConvertTo-Json -Compress | Write-Output;exit 0}
    # Historical records establish container identity only; they are never candidates.
    $latest=Get-WinEvent -LogName 'Microsoft-Windows-AppModel-Runtime/Admin' -MaxEvents 1 -ErrorAction Stop
    $cursor=[long]$latest.RecordId
    $history=@(Get-ActivationEvents ([Math]::Max(0,$cursor-256)))
    $startTime=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    foreach($item in $history){$item.fresh=$false}
    $seenPort=Test-ActivationPort
    @{kind='snapshot';events=$history;mainPids=@(Get-ActivationMainPids);portReady=$seenPort;observedAt=$startTime} | ConvertTo-Json -Depth 6 -Compress | Write-Output
    [Console]::Out.Flush()
    while(!(Test-Path -LiteralPath $StopFile) -and (Get-Process -Id $ParentId -ErrorAction SilentlyContinue)){
        $ready=Test-ActivationPort
        $events=@(Get-ActivationEvents $cursor)
        $cursor=$script:ObservedCursor
        foreach($item in $events){
            $item.fresh=$item.time -ge $startTime
            $item.portWasUnavailable=(!$seenPort -and !$ready)
            $cursor=[Math]::Max($cursor,[long]$item.recordId)
        }
        @{kind='snapshot';events=$events;mainPids=@(Get-ActivationMainPids);portReady=$ready;observedAt=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()} | ConvertTo-Json -Depth 6 -Compress | Write-Output
        [Console]::Out.Flush();$seenPort=$ready
        Start-Sleep -Milliseconds 350
    }
}catch{
    @{kind='unavailable';reason=$_.Exception.Message} | ConvertTo-Json -Compress | Write-Output
    [Console]::Out.Flush();exit 1
}
