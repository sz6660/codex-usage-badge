$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../windows/environment.ps1')
$script:store=@{BUILD_FLAVOR=$null;CODEX_ELECTRON_CHROMIUM_SWITCHES='previous';CODEX_ELECTRON_USER_DATA_PATH=$null}
$script:failKey=''
function Get-TrialUserValue([string]$Name){$script:store[$Name]}
function Set-TrialUserValue([string]$Name,$Value){if($script:failKey -eq $Name){$script:failKey='';throw 'injected write failure'};$script:store[$Name]=$Value}
function Notify-TrialEnvironment {}
function Assert($Value,[string]$Message){if(!$Value){throw $Message}}
function Reject([scriptblock]$Body){$failed=$false;try{& $Body}catch{$failed=$true};Assert $failed 'Expected rejection'}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('badge-env-test-'+[guid]::NewGuid().ToString('N'))
$oldLocal=$env:LOCALAPPDATA
try{
    [void][IO.Directory]::CreateDirectory($temp);$env:LOCALAPPDATA=$temp
    $profile=Join-Path $temp 'profile';[void][IO.Directory]::CreateDirectory($profile)
    $root=Get-BadgeEnvironmentRoot;$backup=Join-Path $root 'environment-backup.json'
    $script:failKey='CODEX_ELECTRON_CHROMIUM_SWITCHES'
    Reject {Invoke-TrialEnvironment Prepare $root $profile}
    Assert ($null -eq $script:store.BUILD_FLAVOR -and $script:store.CODEX_ELECTRON_CHROMIUM_SWITCHES -eq 'previous') 'Failed prepare changed original values'
    Assert (!(Test-Path -LiteralPath $backup)) 'Failed prepare retained active backup'
    Assert (Invoke-TrialEnvironment Prepare $root $profile) 'First prepare not marked new'
    $before=[IO.File]::ReadAllText($backup)
    Assert (!(Invoke-TrialEnvironment Prepare $root $profile)) 'Repeat prepare not idempotent'
    Assert ([IO.File]::ReadAllText($backup) -ceq $before) 'Original backup replaced'
    $script:store.BUILD_FLAVOR='external'
    Reject {Assert-BadgeEnvironmentRestore}
    Assert ($script:store.BUILD_FLAVOR -eq 'external') 'External edit overwritten'
    $script:store.BUILD_FLAVOR='dev';$script:failKey='CODEX_ELECTRON_CHROMIUM_SWITCHES'
    Reject {Restore-BadgeEnvironment}
    Assert ($script:store.BUILD_FLAVOR -eq 'dev' -and (Test-Path -LiteralPath $backup)) 'Failed restore not rolled back'
    Restore-BadgeEnvironment
    Assert ($null -eq $script:store.BUILD_FLAVOR -and $script:store.CODEX_ELECTRON_CHROMIUM_SWITCHES -eq 'previous') 'Original values not restored'
    Restore-BadgeEnvironment
    $legacy=Join-Path $temp 'CodexUsageBadge-EnvironmentTrial'
    [void](Invoke-TrialEnvironment Prepare $legacy $profile)
    Assert ((Get-BadgeEnvironmentRoot) -eq $legacy) 'Legacy trial not adopted'
    Restore-BadgeEnvironment
    Write-Host 'PASS isolated Windows environment transaction, retry, repeat install, conflict protection, partial restore rollback and trial adoption (registry APIs mocked)'
}finally{
    $env:LOCALAPPDATA=$oldLocal
    $resolved=[IO.Path]::GetFullPath($temp)
    if(!$resolved.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'badge-env-test-*'){throw 'Unsafe fixture path'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
