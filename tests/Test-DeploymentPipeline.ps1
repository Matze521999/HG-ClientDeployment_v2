[CmdletBinding()]
param()
# Echte Background-Jobs mit Testdateien; kein Netzwerk, keine Installer.
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'lib\LatestSoftware.ps1')
. (Join-Path $root 'lib\DeploymentPipeline.ps1')
function Assert {param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}
$fixture=Join-Path $PSScriptRoot ('pipeline-fixture-'+[guid]::NewGuid().ToString('N'))
$lib=Join-Path $fixture 'lib'
$null=New-Item -ItemType Directory -Path $lib -Force
$savedTemp=$env:TEMP;$env:TEMP=$fixture
try {
 @'
$script:fixtureRoot=Split-Path $PSScriptRoot -Parent
function Set-TestEvent {param($Name) [IO.File]::WriteAllText((Join-Path $script:fixtureRoot $Name),[string][DateTime]::UtcNow.Ticks)}
function New-HGPreparedSoftware {
 param($Software,$WorkRoot)
 $number=switch($Software){'7Zip'{1};'Chrome'{2};'Firefox'{3}}
 Set-TestEvent ('D'+$number+'start')
 if($number -eq 2){
  $deadline=[DateTime]::UtcNow.AddSeconds(15)
  while(-not (Test-Path (Join-Path $script:fixtureRoot 'I1start'))){
   if([DateTime]::UtcNow -gt $deadline){throw 'Installation 1 hat nicht waehrend Download 2 begonnen'}
   Start-Sleep -Milliseconds 20
  }
 }
 $case=(Get-Content (Join-Path $script:fixtureRoot 'test-case') -Raw).Trim()
 if($case -eq 'DownloadFailure' -and $number -eq 2){Set-TestEvent ('D'+$number+'failed');throw 'Test-Downloadfehler'}
 Start-Sleep -Milliseconds 40
 $work=Join-Path $WorkRoot ('HG-'+$Software+'-fixture')
 $null=New-Item -ItemType Directory -Path $work
 $file=Join-Path $work 'test.bin';Set-Content $file 'Nicht ausfuehren'
 Set-TestEvent ('D'+$number+'end')
 [pscustomobject]@{Kind='HGPreparedSoftware';Software=$Software;Status='Bereit';DownloadOnly=$false;InstallerPath=$file;WorkDirectory=$work;Number=$number}
}
function Complete-HGPreparedSoftware {
 param($Preparation,$OnWaiting,$DestinationDirectory)
 $number=$Preparation.Number
 Set-TestEvent ('I'+$number+'start')
 $case=(Get-Content (Join-Path $script:fixtureRoot 'test-case') -Raw).Trim()
 if($number -eq 1 -and $case -eq 'InstallFailure'){Set-TestEvent ('I'+$number+'end');throw 'Test-Installationsfehler'}
 if($number -eq 1 -and $case -ne 'Single'){
  $deadline=[DateTime]::UtcNow.AddSeconds(15)
  while(-not (Test-Path (Join-Path $script:fixtureRoot 'D3end'))){
   if([DateTime]::UtcNow -gt $deadline){throw 'Weitere Downloads laufen nicht waehrend Installation 1'}
   if($OnWaiting){& $OnWaiting}
   Start-Sleep -Milliseconds 20
  }
 }
 Start-Sleep -Milliseconds 40
 Set-TestEvent ('I'+$number+'end')
 [pscustomobject]@{Software=$Preparation.Software;Status='Installiert';Version='1.0.0.0';RebootRequired=$false}
}
'@ | Set-Content (Join-Path $lib 'LatestSoftware.ps1') -Encoding utf8
 . (Join-Path $lib 'LatestSoftware.ps1')
 foreach($name in @('7Zip','GoogleChrome','MozillaFirefox')){ 'throw "Wrapper darf im Pipelinebetrieb nicht gestartet werden"' | Set-Content (Join-Path $fixture ('Install-'+$name+'.ps1')) }
 $options=@(
  [pscustomobject]@{Name='7Zip';Label='Datei 1';Selected=$true},
  [pscustomobject]@{Name='GoogleChrome';Label='Datei 2';Selected=$true},
  [pscustomobject]@{Name='MozillaFirefox';Label='Datei 3';Selected=$true}
 )
 function Tick {param($Name) [long](Get-Content (Join-Path $fixture $Name) -Raw)}
 foreach($case in @('Success','DownloadFailure','InstallFailure')) {
  foreach($file in Get-ChildItem $fixture -File | Where-Object Name -match '^[DI][123](start|end|failed)$'){Remove-Item -LiteralPath $file.FullName}
  Set-Content (Join-Path $fixture 'test-case') $case
  $result=@(Invoke-HGDeploymentPipeline -Options $options -ScriptDirectory $fixture)
  Assert ($result.Count -eq 3) 'Hintergrundausgaben verunreinigen die Ergebnisliste'
  Assert ((Tick D2start) -ge (Tick D1end)) 'Downloads laufen nicht einzeln'
  if($case -eq 'Success'){
   Assert (($result.Status -join ',') -eq 'Installiert,Installiert,Installiert') 'Erfolgsstatus falsch'
   Assert ((Tick I1start) -lt (Tick D2end)) 'Installation 1 wartet auf Download 2'
   Assert ((Tick D3end) -le (Tick I1end)) 'Downloads laufen nicht waehrend Installation 1'
   Assert ((Tick I2start) -ge (Tick I1end) -and (Tick I3start) -ge (Tick I2end)) 'Installationen ueberlappen'
   Assert ((Tick D3start) -ge (Tick D2end)) 'Downloads 2 und 3 ueberlappen'
  }
  elseif($case -eq 'DownloadFailure'){
   Assert (($result.Status -join ',') -eq 'Installiert,Fehlgeschlagen,Installiert') 'Downloadfehler verhindert weitere Aufgaben'
   Assert (-not (Test-Path (Join-Path $fixture 'I2start'))) 'Fehlgeschlagener Download wurde installiert'
  }
  else { Assert (($result.Status -join ',') -eq 'Fehlgeschlagen,Installiert,Installiert') 'Installationsfehler verhindert weitere Aufgaben' }
  Assert (@(Get-Job).Count -eq 0) 'Hintergrundjob wurde nicht entfernt'
  Assert (@(Get-ChildItem $fixture -Directory | Where-Object Name -like 'HG-Pipeline-*').Count -eq 0) 'Pipeline-Dateien nicht aufgeraeumt'
  Write-Host "PASS: Pipeline $case - Downloads ueberlappen Installation, Installer laufen einzeln"
 }
 Set-Content (Join-Path $fixture 'test-case') 'Single'
 $single=@(Invoke-HGDeploymentPipeline -Options @($options[0]) -ScriptDirectory $fixture)
 Assert ($single.Count -eq 1 -and $single[0].Status -eq 'Installiert') 'Auswahl mit genau einem Paket funktioniert nicht'
 Assert (@(Get-Job).Count -eq 0) 'Hintergrundjob der Einzelauswahl nicht entfernt'
 Write-Host 'PASS: Pipeline mit genau einem ausgewaehlten Paket'
}
finally {
 $env:TEMP=$savedTemp
 $resolved=[IO.Path]::GetFullPath($fixture);$allowed=[IO.Path]::GetFullPath($PSScriptRoot)+'\'
 if(-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Ungueltiger Testpfad'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}


