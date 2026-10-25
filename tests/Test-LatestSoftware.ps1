# Keine echten Downloads/Installationen: Herstellerdaten und Prozesse simulieren.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'lib\LatestSoftware.ps1')
function Assert { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
Assert ((ConvertTo-HGVersion '26.05') -eq (ConvertTo-HGVersion '26.5.0.0')) 'Versionsnormalisierung'
function Invoke-WebRequest { param($Uri,$UseBasicParsing,$TimeoutSec,$ErrorAction) @{ Content = '<a href="https://github.com/ip7z/7zip/releases/download/26.05/7z2605-x64.exe">Download</a> Download 7-Zip 26.05' } }
function Invoke-RestMethod {
 param($Uri,$UseBasicParsing,$TimeoutSec,$ErrorAction)
 if ($Uri -match 'mozilla') { return @{LATEST_FIREFOX_VERSION='158.0.1'} }
 return @{ assets = @(@{name='7z2605-x64.exe';digest=('sha256:' + ('a'*64));browser_download_url='https://github.com/ip7z/7zip/releases/download/26.05/7z2605-x64.exe'}) }
}
$zip = Get-HGPackage 7Zip x64
Assert ($zip.Hash -eq ('a'*64) -and $zip.Version -eq [version]'26.5.0.0') '7-Zip-Metadaten'
$firefox = Get-HGPackage Firefox x64
Assert ($firefox.Url -match '/158.0.1/win64/de/' -and $firefox.Version -eq [version]'158.0.1.0') 'Firefox-Stable-Metadaten'
foreach ($architecture in @('x86','x64','arm64')) {
 $chrome = Get-HGPackage Chrome $architecture
 Assert ($chrome.Url -match '^https://dl.google.com/' -and $chrome.Extension -eq 'msi') 'Chrome-MSI'
}
foreach ($architecture in @('x86','x64','arm64')) {
 $vpn = Get-HGPackage OpenVPN $architecture
 Assert ($vpn.Url -match 'OpenVPN-2\.6\.9-I001-' -and $vpn.Version -eq [version]'2.6.9.0' -and $vpn.MsiVersion -eq [version]'2.6.901.0') 'OpenVPN-Version muss fest auf 2.6.9-I001 stehen'
}
Write-Host 'PASS: OpenVPN-Version und Architekturpakete festgeschrieben'
Write-Host 'PASS: Versionsnormalisierung und aktuelle Paketaufloesung'

$fixture = Join-Path $PSScriptRoot ('software-fixture-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixture
$savedTemp = $env:TEMP
$env:TEMP = $fixture
try {
 $msiPath = Join-Path $fixture 'fixture.msi'
 $msiEngine = $msiDb = $msiView = $null
 try {
  $msiEngine = New-Object -ComObject WindowsInstaller.Installer
  $msiDb = $msiEngine.OpenDatabase($msiPath, 3)
  $msiView = $msiDb.OpenView('CREATE TABLE `Property` (`Property` CHAR(72) NOT NULL, `Value` CHAR(0) LOCALIZABLE PRIMARY KEY `Property`)')
  $null = $msiView.Execute(); $null = $msiView.Close()
  $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($msiView)
  $msiView = $msiDb.OpenView("INSERT INTO ``Property`` (``Property``, ``Value``) VALUES ('ProductVersion', '2.3.4.5')")
  $null = $msiView.Execute(); $null = $msiView.Close()
  $null = $msiDb.Commit()
 }
 finally {
  foreach ($obj in @($msiView, $msiDb, $msiEngine)) { if ($obj) { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($obj) } }
 }
 $msiVersion = Get-HGMsiVersion -Path $msiPath
 Assert ($msiVersion -is [version] -and $msiVersion -eq [version]'2.3.4.5') 'MSI-Version muss ein einzelnes Versionsobjekt sein'
 Write-Host 'PASS: Echte MSI-Metadaten ohne Installation lesen'
 $file = Join-Path $fixture 'test.exe'
 Set-Content -LiteralPath $file -Value 'Testdaten'
 $hash = (Get-FileHash $file -Algorithm SHA256).Hash
 Test-HGInstaller $file ([pscustomobject]@{Hash=$hash;Signer=$null})
 $caught=''; try { Test-HGInstaller $file ([pscustomobject]@{Hash=('b'*64);Signer=$null}) } catch { $caught=$_.Exception.Message }
 Assert ($caught -match 'SHA-256') 'Falscher Hash muss abgewiesen werden'
 function Get-AuthenticodeSignature { param($LiteralPath,$ErrorAction) @{ Status=$script:signatureStatus;SignerCertificate=@{Subject=$script:subject} } }
 $script:signatureStatus='Valid'; $script:subject='CN=Google LLC, O=Google LLC, L=Mountain View, C=US'
 Test-HGInstaller $file ([pscustomobject]@{Hash=$null;Signer='Google (LLC|Inc\.)'})
 $script:subject='CN=Fremder Anbieter, O=Other Company, C=US'
 $caught=''; try { Test-HGInstaller $file ([pscustomobject]@{Hash=$null;Signer='Google (LLC|Inc\.)'}) } catch { $caught=$_.Exception.Message }
 Assert ($caught -match 'Signatur') 'Falscher Herausgeber muss abgewiesen werden'
 $script:signatureStatus='NotTrusted'; $script:subject='O=Mozilla Corporation, C=US'
 $caught=''; try { Test-HGInstaller $file ([pscustomobject]@{Hash=$null;Signer='Mozilla Corporation'}) } catch { $caught=$_.Exception.Message }
 Assert ($caught -match 'Signatur') 'Nicht vertrauenswuerdige Signatur muss abgewiesen werden'
 Write-Host 'PASS: Hash, Herausgeber und Signaturstatus'

 function New-Object { param($TypeName,$ErrorAction) $obj=[pscustomobject]@{}; $obj | Add-Member ScriptMethod IsInRole {param($role) $script:isAdmin}; return $obj }
 function Get-HGArchitecture { 'x64' }
 function Get-HGPackage {
  param($Software,$Architecture)
  $script:events.Add('Paket')
  if ($Software -eq 'OpenVPN') { return [pscustomobject]@{Url='https://example.invalid/fixture';Version=[version]'2.6.9.0';MsiVersion=[version]'2.6.901.0';Extension='msi';RelativePath='OpenVPN\bin\openvpn.exe'} }
  [pscustomobject]@{Url='https://example.invalid/fixture';Version=$(if ($Software -eq 'Chrome') {$null} else {[version]'2.0.0.0'});Extension=$(if ($Software -eq 'Chrome') {'msi'} else {'exe'});RelativePath='Fixture\app.exe'}
 }
 function Get-HGInstalledVersion { param($RelativePath) $script:events.Add('Inventar'); if ($script:versions.Count) { $script:versions.Dequeue() } }
 function Invoke-HGDownload { param($Uri,$OutFile) $script:downloads++; Set-Content -LiteralPath $OutFile -Value 'Testinstaller' }
 function Test-HGInstaller { param($Path,$Package) if ($script:badSignature) {throw 'Test-Signaturfehler'} }
 function Get-HGMsiVersion { param($Path) $script:testMsiVersion }
 function Start-Process { param($FilePath,$ArgumentList,[switch]$Wait,[switch]$PassThru,$ErrorAction) $script:starts++; $script:arguments=$ArgumentList; @{ExitCode=$script:exitCode} }
 function Run-Case {
  param($Software='7Zip',$Before='1.0.0.0',$After='2.0.0.0',$Code=0,$Expected='Installiert',$ErrorPattern='', [bool]$BadSignature=$false,[bool]$Admin=$true, [string]$MsiVersion='')
  $script:events=[Collections.Generic.List[string]]::new()
  $script:versions=[Collections.Generic.Queue[object]]::new()
  $script:versions.Enqueue($(if ($Before) {[version]$Before} else {$null}))
  $script:versions.Enqueue($(if ($Before) {[version]$Before} else {$null}))
  $script:versions.Enqueue($(if ($After) {[version]$After} else {$null}))
  $script:testMsiVersion = if ($MsiVersion) { [version]$MsiVersion } elseif ($Software -eq 'OpenVPN') { [version]'2.6.901.0' } else { [version]'2.0.0.0' }
  $script:downloads=0; $script:starts=0; $script:exitCode=$Code; $script:badSignature=$BadSignature; $script:isAdmin=$Admin
  $caught=''; $result=$null
  try { $result=Invoke-HGLatestSoftware $Software } catch {$caught=$_.Exception.Message}
  if ($Admin) { Assert ($script:events[0] -eq 'Inventar') 'Software muss vor dem Paketabruf geprueft werden' }
  if ($ErrorPattern) { Assert ($caught -match $ErrorPattern) "Erwarteter Fehler fehlt: $caught" }
  else { Assert (-not $caught -and $result.Status -eq $Expected) "Ergebnis falsch: $caught / $($result.Status)" }
  if ($Before -eq '3.0.0.0') { Assert ($script:starts -eq 0) 'Downgrade wurde gestartet' }
  if ($BadSignature -or -not $Admin) { Assert ($script:starts -eq 0) 'Unzulaessiger Installerstart' }
  Assert (@(Get-ChildItem -LiteralPath $fixture -Directory).Count -eq 0) 'Tempordner nicht bereinigt'
 }
 Run-Case
 Run-Case -Software Firefox
 Assert ($script:arguments -match 'PreventRebootRequired=true' -and $script:arguments -match 'RemoveDistributionDir=false') 'Firefox-Argumente'
 Run-Case -Software Chrome
 Assert ($script:arguments -match '/qn /norestart') 'MSI-Argumente'
 Run-Case -Before '3.0.0.0' -Expected 'BereitsAktuell'
 Run-Case -Software Chrome -Before '3.0.0.0' -Expected 'BereitsAktuell'
 Run-Case -Code 1603 -ErrorPattern '1603'
 Run-Case -After '1.0.0.0' -ErrorPattern 'nicht nachweisbar'
 Run-Case -Code 3010
 Run-Case -Code 3010 -After '1.0.0.0' -Expected 'NeustartAusstehend'
 Run-Case -BadSignature $true -ErrorPattern 'Signatur'
 Run-Case -Admin $false -ErrorPattern 'Administrator'
 Write-Host 'PASS: Installation, Versionserkennung, kein Downgrade, Exitcodes, Neustart, Fehler und Aufraeumen'
 & (Join-Path $root 'Install-7Zip.ps1') -Install7Zip $false
 & (Join-Path $root 'Install-GoogleChrome.ps1') -InstallChrome $false
 & (Join-Path $root 'Install-MozillaFirefox.ps1') -InstallFirefox $false
 Run-Case -Software OpenVPN -Before '' -After '2.6.9.0'
 Run-Case -Software OpenVPN -Before '2.6.8.0' -After '2.6.9.0'
 Run-Case -Software OpenVPN -Before '2.6.9.0' -Expected 'BereitsAktuell'
 Run-Case -Software OpenVPN -Before '2.6.10.0' -ErrorPattern 'Versionskonflikt'
 Assert ($script:starts -eq 0 -and $script:downloads -eq 0) 'Neueres OpenVPN darf nicht automatisch heruntergestuft werden'
 Run-Case -Software OpenVPN -Before '' -After '2.6.10.0' -ErrorPattern 'nicht nachweisbar'
 Run-Case -Software OpenVPN -Before '' -MsiVersion '2.6.1001.0' -ErrorPattern 'MSI-Version'
 Assert ($script:starts -eq 0) 'Falsches OpenVPN-Paket darf nicht gestartet werden'
 Run-Case -Software OpenVPN -Before '' -After '' -Code 3010 -Expected 'NeustartAusstehend'
 Write-Host 'PASS: OpenVPN 2.6.9 Installation, Upgrade, exakte Version, MSI-Pruefung und Versionskonflikt'
 & (Join-Path $root 'Install-OpenVPN.ps1') -InstallOpenVPN $false
 Run-Case -Software AdobeReaderDC -Before '' -After '2.0.0.0'
 Assert ($script:arguments -match '/sAll /rs') 'Adobe muss still und ohne automatischen Neustart installiert werden'
 Run-Case -Software AdobeReaderDC -Before '1.0.0.0' -After '2.0.0.0'
 Run-Case -Software AdobeReaderDC -Before '2.0.0.0' -Expected 'BereitsAktuell'
 Run-Case -Software AdobeReaderDC -Before '3.0.0.0' -Expected 'BereitsAktuell'
 & (Join-Path $root 'Install-AdobeReaderDC.ps1') -InstallAdobeReaderDC $false
 Write-Host 'PASS: Adobe Erstinstallation, Update, aktuelle/neue Version, Parameter und Reihenfolge der Versionspruefung'
 # Ein vorbereiteter Datensatz muss auch nach dem Job-Transport funktionieren.
 $script:isAdmin=$true; $script:badSignature=$false; $script:exitCode=0
 $script:events=[Collections.Generic.List[string]]::new()
 $script:versions=[Collections.Generic.Queue[object]]::new()
 foreach ($version in @('1.0.0.0','1.0.0.0','2.0.0.0')) { $script:versions.Enqueue([version]$version) }
 $prepared=New-HGPreparedSoftware Firefox
 try {
  $transported=[Management.Automation.PSSerializer]::Deserialize([Management.Automation.PSSerializer]::Serialize($prepared,10))
  $transportResult=Complete-HGPreparedSoftware $transported
  Assert ($transportResult.Status -eq 'Installiert') 'Vorbereiteter Installer funktioniert nach Job-Transport nicht'
 }
 finally { Remove-HGPreparedSoftware $prepared }
 Write-Host 'PASS: Vorbereitete Pakete ueberstehen Job-Serialisierung'

 # Polling und WaitForExit mit einem harmlosen echten Kindprozess pruefen.
 function Start-Process {
  param($FilePath,$ArgumentList,[switch]$Wait,[switch]$PassThru,$ErrorAction)
  $info=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path, '-NoProfile -Command "Start-Sleep -Milliseconds 250; exit 0"')
  $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
  $script:testChild=[Diagnostics.Process]::Start($info)
  return $script:testChild
 }
 foreach ($failCallback in @($false,$true)) {
  $script:versions=[Collections.Generic.Queue[object]]::new()
  foreach ($version in @('1.0.0.0','1.0.0.0','2.0.0.0')) { $script:versions.Enqueue([version]$version) }
  $prepared=New-HGPreparedSoftware Firefox; $script:pollCount=0; $caught=''
  try {
   $result=Complete-HGPreparedSoftware $prepared -OnWaiting { $script:pollCount++; if($failCallback){throw 'Test-Anzeigefehler'} }
  }
  catch { $caught=$_.Exception.Message }
  finally { Remove-HGPreparedSoftware $prepared }
  Assert ($script:testChild.HasExited -and $script:pollCount -gt 0) 'Kindprozess muss beendet sein, bevor die naechste Installation beginnen darf'
  if($failCallback){ Assert ($caught -match 'Test-Anzeigefehler') 'Anzeigefehler fehlt' }
  else { Assert (-not $caught -and $result.Status -eq 'Installiert') "Polling fehlgeschlagen: $caught" }
  $script:testChild.Dispose()
 }
 Write-Host 'PASS: Installationsprozess abwarten, Hintergrundanzeige aktualisieren, auch bei Anzeigefehlern nicht ueberlappen'
 Write-Host 'PASS: Bisherige Auswahlparameter bleiben verwendbar'
}
finally {
 $env:TEMP = $savedTemp
 $resolved = [IO.Path]::GetFullPath($fixture)
 $allowed = [IO.Path]::GetFullPath($PSScriptRoot) + [IO.Path]::DirectorySeparatorChar
 if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Ungueltiger Testpfad' }
 Remove-Item -LiteralPath $resolved -Recurse -Force
}






