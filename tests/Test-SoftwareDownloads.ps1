# Download-/Metadatentests ohne echte Programme oder Installer zu starten.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'lib\LatestSoftware.ps1')
function Assert {param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}
$script:manifestHost='ardownload3.adobe.com';$script:manifestHash='a'*64
function Invoke-RestMethod {param($Uri,$UseBasicParsing,$TimeoutSec,$ErrorAction) @(@{type='dir';name='26.001.10000'},@{type='dir';name='26.002.22031'},@{type='file';name='readme'})}
function Invoke-WebRequest {
 param($Uri,$UseBasicParsing,$TimeoutSec,$ErrorAction)
 @{Content="- Architecture: x64`n  InstallerUrl: https://$script:manifestHost/reader.exe`n  InstallerSha256: $script:manifestHash`nManifestType: installer"}
}
$adobe=Get-HGPackage AdobeReaderDC x64
Assert ($adobe.Version -eq [version]'26.2.22031.0' -and $adobe.Hash -eq ('a'*64)) 'Adobe-Version / Hash'
$script:manifestHost='other.invalid';$caught=''
try{Get-HGPackage AdobeReaderDC x64}catch{$caught=$_.Exception.Message}
Assert ($caught -match 'Downloadserver') 'Fremder Adobe-Downloadserver darf nicht akzeptiert werden'
$script:manifestHost='ardownload3.adobe.com';$script:manifestHash='';$caught=''
try{Get-HGPackage AdobeReaderDC x64}catch{$caught=$_.Exception.Message}
Assert ($caught -match 'SHA-256') 'Adobe-Paket ohne Hash darf nicht akzeptiert werden'
Write-Host 'PASS: Adobe-Metadaten, Versionsauswahl, Downloadserver und fehlender Hash'

$fixture=Join-Path $PSScriptRoot ('download-fixture-'+[guid]::NewGuid().ToString('N'))
$destination=Join-Path $fixture 'desktop'
$null=New-Item -ItemType Directory -Path $destination -Force
$savedTemp=$env:TEMP;$env:TEMP=$fixture
$script:payload='A';$script:signatureStatus='Valid';$script:publisher='TeamViewer Germany GmbH'
$script:installed=$false;$script:inventoryCalls=0
function Get-HGSoftwareState {param($Software)$script:inventoryCalls++;[pscustomobject]@{Found=$script:installed;Version=$(if($script:installed){[version]'15.1.0.0'}else{$null})}}
function Invoke-HGDownload {param($Uri,$OutFile) Set-Content -LiteralPath $OutFile -Value $script:payload}
function Get-HGFileVersion {param($Path) if($script:publisher -eq 'servereye GmbH'){[version]'20.16.0.0'}else{$null}}
function Get-AuthenticodeSignature {param($LiteralPath,$ErrorAction)@{Status=$script:signatureStatus;SignerCertificate=@{Subject="CN=$script:publisher, O=$script:publisher, C=DE"}}}
function Start-Process {throw 'Ein Download-Skript darf keinen Prozess starten'}
try {
 $result=Invoke-HGSoftwareDownload HGFernwartung $destination
 Assert ($result.Status -eq 'Heruntergeladen' -and -not $result.PackageVersion) 'HG-Download ohne Versionsmetadaten'
 Assert ($script:inventoryCalls -eq 1) 'Vor dem Download muss die Software erkannt werden'
 $result=Invoke-HGSoftwareDownload HGFernwartung $destination
 Assert ($result.Status -eq 'BereitsHeruntergeladen') 'Identischer HG-Download muss uebersprungen werden'
 $script:payload='B'
 $result=Invoke-HGSoftwareDownload HGFernwartung $destination
 Assert ($result.Status -eq 'Heruntergeladen' -and (Get-Content $result.Path -Raw).Trim() -eq 'B') 'Geaenderte HG-Datei muss ersetzt werden'
 $script:signatureStatus='NotTrusted';$script:payload='C';$caught=''
 try{Invoke-HGSoftwareDownload HGFernwartung $destination}catch{$caught=$_.Exception.Message}
 Assert ($caught -match 'Signatur') 'Ungueltige Signatur muss abgewiesen werden'
 Assert ((Get-Content (Join-Path $destination 'HG-Fernwartung.exe') -Raw).Trim() -eq 'B') 'Vorhandene Datei wurde trotz ungueltigem Download ersetzt'
 $script:signatureStatus='Valid';$script:publisher='servereye GmbH';$script:installed=$true
 $result=Invoke-HGSoftwareDownload ServerEye $destination
 Assert ($result.Status -eq 'Heruntergeladen' -and $result.Version -eq [version]'15.1.0.0' -and $result.PackageVersion -eq [version]'20.16.0.0') 'Agent- und Setupversion muessen getrennt bleiben'
 Assert ($result.Details -match 'keine automatische Installation') 'Download darf keine Agent-Aktualisierung behaupten'
 Assert (@(Get-ChildItem $fixture -Directory | Where-Object Name -ne 'desktop').Count -eq 0) 'Temporare Downloads nicht geloescht'
 & (Join-Path $root 'Install-HGFernwartung.ps1') -InstallHGFernwartung $false
 & (Join-Path $root 'Install-ServerEye.ps1') -InstallServerEye $false
 Write-Host 'PASS: HG-Hashvergleich, ersetzte Downloads, Signaturfehler, Agent-/Setupversion, kein Prozessstart, Aufraeumen und Parameter'
}
finally {
 $env:TEMP=$savedTemp
 $resolved=[IO.Path]::GetFullPath($fixture);$allowed=[IO.Path]::GetFullPath($PSScriptRoot)+[IO.Path]::DirectorySeparatorChar
 if(-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Ungueltiger Testpfad'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
