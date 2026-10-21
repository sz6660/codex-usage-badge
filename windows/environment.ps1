$ErrorActionPreference='Stop'
function Get-TrialUserValue([string]$Name){[Environment]::GetEnvironmentVariable($Name,'User')}
function Set-TrialUserValue([string]$Name,$Value){[Environment]::SetEnvironmentVariable($Name,$Value,'User')}
function Notify-TrialEnvironment {
    if(!('BadgeEnvironmentNotification' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BadgeEnvironmentNotification {
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr SendMessageTimeout(IntPtr h,uint m,UIntPtr w,string l,uint f,uint t,out UIntPtr r);
 public static void Send(){UIntPtr r;SendMessageTimeout(new IntPtr(0xffff),0x1a,UIntPtr.Zero,"Environment",2,3000,out r);}
}
'@
    }
    [BadgeEnvironmentNotification]::Send()
}
function Invoke-TrialEnvironment([string]$Mode,[string]$BackupRoot,[string]$ProfilePath){
    $owner='local.codexusagebadge.environment-trial'
    $marker=Join-Path $BackupRoot '.owner'
    $backup=Join-Path $BackupRoot 'environment-backup.json'
    if(Test-Path -LiteralPath $BackupRoot){
        $item=Get-Item -LiteralPath $BackupRoot -Force
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or !(Test-Path -LiteralPath $marker) -or ([IO.File]::ReadAllText($marker) -ne $owner)){throw 'Backup directory is not owned by this experiment; nothing changed.'}
    }
    if($Mode -eq 'Prepare'){
        if(!(Test-Path -LiteralPath $ProfilePath -PathType Container)){throw 'Existing Codex profile not found; nothing changed.'}
        if(Test-Path -LiteralPath $backup){
            Assert-BadgeEnvironmentBackup $backup
            Write-Host 'Environment already prepared; original backup retained.'
            return $false
        }
        $desired=[ordered]@{BUILD_FLAVOR='dev';CODEX_ELECTRON_CHROMIUM_SWITCHES='{"remote-debugging-address":"127.0.0.1","remote-debugging-port":"39222"}';CODEX_ELECTRON_USER_DATA_PATH=$ProfilePath}
        $original=[ordered]@{}
        foreach($key in $desired.Keys){$original[$key]=Get-TrialUserValue $key}
        [void][IO.Directory]::CreateDirectory($BackupRoot)
        [IO.File]::WriteAllText($marker,$owner)
        $state=[ordered]@{owner=$owner;createdAt=[DateTime]::UtcNow.ToString('o');original=$original;applied=$desired}
        [IO.File]::WriteAllText($backup,($state|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
        try{foreach($key in $desired.Keys){Set-TrialUserValue $key $desired[$key]};Notify-TrialEnvironment}
        catch{
            $failure=$_
            foreach($key in $original.Keys){Set-TrialUserValue $key $original[$key]}
            Notify-TrialEnvironment
            Remove-Item -LiteralPath $backup -Force
            throw $failure
        }
        Write-Host 'Prepared 3 USER environment variables. Existing Codex profile path is pinned.'
        Write-Host 'No Codex process was started or stopped. No account or chat files were read or modified.'
        Write-Host ('Backup: '+$backup)
        return $true
    } else {
        if(!(Test-Path -LiteralPath $backup)){Write-Host 'No active environment backup. Nothing changed.';return}
        $state=Get-Content -LiteralPath $backup -Raw -Encoding UTF8|ConvertFrom-Json
        if($state.owner -ne $owner){throw 'Invalid backup owner'}
        $expected=@('BUILD_FLAVOR','CODEX_ELECTRON_CHROMIUM_SWITCHES','CODEX_ELECTRON_USER_DATA_PATH')
        if(@($state.applied.PSObject.Properties).Count -ne 3 -or @($state.original.PSObject.Properties).Count -ne 3){throw 'Invalid backup keys'}
        foreach($key in $expected){
            if(!$state.applied.PSObject.Properties[$key] -or !$state.original.PSObject.Properties[$key]){throw 'Missing backup key'}
            $current=Get-TrialUserValue $key
            if($current -cne $state.applied.$key -and $current -cne $state.original.$key){throw ('Environment changed after installation; refusing to overwrite: '+$key)}
        }
        $before=@{}
        foreach($key in $expected){$before[$key]=Get-TrialUserValue $key}
        $restored=Join-Path $BackupRoot ('environment-restored-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N')+'.json')
        try{
            foreach($key in $expected){Set-TrialUserValue $key $state.original.$key}
            Notify-TrialEnvironment
            [IO.File]::Move($backup,$restored)
        }catch{
            $failure=$_
            foreach($key in $expected){Set-TrialUserValue $key $before[$key]}
            Notify-TrialEnvironment
            throw $failure
        }
        Write-Host 'Original USER environment variables restored. Restart Codex yourself when ready.'
    }
}

function Get-BadgeEnvironmentRoot {
    $legacy=Join-Path $env:LOCALAPPDATA 'CodexUsageBadge-EnvironmentTrial'
    $current=Join-Path $env:LOCALAPPDATA 'CodexUsageBadge-Environment'
    if(Test-Path -LiteralPath (Join-Path $legacy 'environment-backup.json')){
        if(Test-Path -LiteralPath (Join-Path $current 'environment-backup.json')){throw 'Two environment backups exist; refusing to replace either.'}
        return $legacy
    }
    return $current
}
function Get-BadgeProfilePath {
    $existing=Get-TrialUserValue 'CODEX_ELECTRON_USER_DATA_PATH'
    if($existing){return $existing}
    return Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Codex'
}
function Assert-BadgeEnvironmentBackup([string]$Backup,[switch]$AllowOriginal) {
    $directory=Split-Path -Parent $Backup
    if(((Get-Item -LiteralPath $Backup -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -or
       ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -or
       [IO.File]::ReadAllText((Join-Path $directory '.owner')) -ne 'local.codexusagebadge.environment-trial'){throw 'Invalid environment backup directory'}
    $state=Get-Content -LiteralPath $Backup -Raw -Encoding UTF8 | ConvertFrom-Json
    if($state.owner -ne 'local.codexusagebadge.environment-trial'){throw 'Invalid environment backup owner'}
    $keys=@('BUILD_FLAVOR','CODEX_ELECTRON_CHROMIUM_SWITCHES','CODEX_ELECTRON_USER_DATA_PATH')
    if(@($state.original.PSObject.Properties).Count -ne 3 -or @($state.applied.PSObject.Properties).Count -ne 3){throw 'Invalid environment backup keys'}
    foreach($key in $keys){
        if(!$state.applied.PSObject.Properties[$key] -or !$state.original.PSObject.Properties[$key]){throw 'Missing environment backup key'}
        $current=Get-TrialUserValue $key
        if($current -cne $state.applied.$key -and !($AllowOriginal -and $current -ceq $state.original.$key)){throw ('Environment changed after installation; refusing to overwrite: '+$key)}
    }
}
function Prepare-BadgeEnvironment {
    Invoke-TrialEnvironment Prepare (Get-BadgeEnvironmentRoot) (Get-BadgeProfilePath)
}
function Assert-BadgeEnvironmentRestore {
    $root=Get-BadgeEnvironmentRoot
    $backup=Join-Path $root 'environment-backup.json'
    if(Test-Path -LiteralPath $backup){Assert-BadgeEnvironmentBackup $backup -AllowOriginal}
}
function Restore-BadgeEnvironment {
    Invoke-TrialEnvironment Restore (Get-BadgeEnvironmentRoot) ''
}
function Show-BadgeEnvironment {
    $backup=Join-Path (Get-BadgeEnvironmentRoot) 'environment-backup.json'
    Write-Host ('Environment backup: '+(Test-Path -LiteralPath $backup))
    if(Test-Path -LiteralPath $backup){
        try{Assert-BadgeEnvironmentBackup $backup;Write-Host 'Environment: ready (original entry, plugin never restarts Codex)'}
        catch{Write-Host ('Environment: conflict - '+$_.Exception.Message)}
    }else{Write-Host 'Environment: not installed'}
}
