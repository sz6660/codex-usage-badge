$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../startup/activation-watch.ps1') -Functions
function Assert($Value,$Message){if(!$Value){throw $Message}}
# All OS launch operations are mocked; no desktop client or user environment is touched.
$script:ActivationPackage='fixture-package'
$script:AppExe=Join-Path ([IO.Path]::GetTempPath()) 'badge-fixture/app/ChatGPT.exe'
$script:StopFile=Join-Path ([IO.Path]::GetTempPath()) ('badge-never-created-'+[guid]::NewGuid().ToString('N'))
$script:ParentId=$PID
$script:mains=@();$script:port=$false;$script:launches=0;$script:checks=0;$script:arrive=$false
function Get-ActivationMainPids {$script:checks++;if($script:arrive -and $script:checks -gt 1){return @(123)};return $script:mains}
function Test-ActivationPort {$script:port}
function Get-AppxPackage {return [pscustomobject]@{PackageFullName='fixture-package';PackageFamilyName='fixture-family';InstallLocation=(Join-Path ([IO.Path]::GetTempPath()) 'badge-fixture')}}
function Get-AppxPackageManifest {return [pscustomobject]@{Package=[pscustomobject]@{Applications=[pscustomobject]@{Application=@([pscustomobject]@{Id='App';Executable='app/ChatGPT.exe'})}}}}
function Start-Process {param($FilePath,$ArgumentList,$WindowStyle);Assert ($FilePath -like '*explorer.exe') 'Must use original system entry';Assert ($ArgumentList -eq 'shell:AppsFolder\fixture-family!App') 'Wrong AUMID';Assert ($WindowStyle -eq 'Hidden') 'Launcher helper must be hidden';$script:launches++}
$result=Start-OriginalActivation;Assert $result.launched 'Valid request was not submitted';Assert ($script:launches -eq 1) 'Expected one OS activation'
$script:mains=@(42);$result=Start-OriginalActivation;Assert (!$result.launched) 'Existing client activated'
$script:mains=@();$script:port=$true;$result=Start-OriginalActivation;Assert (!$result.launched) 'Existing port activated'
$script:port=$false;$script:checks=0;$script:arrive=$true;$result=Start-OriginalActivation;Assert (!$result.launched) 'Manual retry race not cancelled'
Assert ($script:launches -eq 1) 'Unexpected extra launch'
Write-Host 'PASS isolated original Windows entry activation, running/port guards, final race recheck and no native file changes (OS calls mocked)'
