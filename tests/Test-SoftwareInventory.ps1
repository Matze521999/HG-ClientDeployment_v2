# Isolierte Erkennungstests: keine Registry-Aenderungen, keine Installer.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'lib\LatestSoftware.ps1')
function Assert { param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message} }
$fixture = Join-Path $PSScriptRoot ('inventory-fixture-' + [guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $fixture
$savedRoots=@($env:ProgramW6432,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:LOCALAPPDATA)
$env:ProgramW6432=$fixture;$env:ProgramFiles=$fixture;${env:ProgramFiles(x86)}=$fixture;$env:LOCALAPPDATA=$fixture
function Get-HGUninstallEntries { $script:entries }
function Get-HGFileVersion { param($Path) $script:fileVersions[$Path] }
function Entry {
 param($Name,$Version,$Location='',$Icon='',$Scope='Machine')
 [pscustomobject]@{DisplayName=$Name;DisplayVersion=$Version;InstallLocation=$Location;DisplayIcon=$Icon;Scope=$Scope;Publisher='Fixture'}
}
try {
 $script:entries=@();$script:fileVersions=@{}
 $state=Get-HGSoftwareState Chrome
 Assert (-not $state.Found -and -not $state.Version) 'Abwesende Software falsch erkannt'
 $script:entries=@((Entry 'Google Chrome' '156.0.8078.47'),(Entry 'Unrelated' '999.0'))
 $version=Get-HGInstalledVersion 'Google\Chrome\Application\chrome.exe'
 Assert ($version -eq [version]'156.0.8078.47') 'Registry-Version nicht erkannt'
 $script:entries=@((Entry 'Mozilla Firefox (x64 de)' '158.0.1'))
 Assert ((Get-HGInstalledVersion 'Mozilla Firefox\firefox.exe') -eq [version]'158.0.1.0') 'Firefox-Registry-Erkennung'
 $script:entries=@((Entry 'Adobe Acrobat (64-bit)' '26.002.22031'))
 Assert ((Get-HGInstalledVersion 'Adobe\Acrobat DC\Acrobat\Acrobat.exe') -eq [version]'26.2.22031.0') 'Adobe-Version'
 $script:entries=@((Entry 'OpenVPN 2.6.9-I001' '2.6.901'))
 Assert ((Get-HGInstalledVersion 'OpenVPN\bin\openvpn.exe') -eq [version]'2.6.9.0') 'OpenVPN-MSI-Buildnummer'
 $script:entries=@((Entry 'Google Chrome' 'unbekannt'))
 $caught='';try{Get-HGInstalledVersion 'Google\Chrome\Application\chrome.exe'}catch{$caught=$_.Exception.Message}
 Assert ($caught -match 'Version ist unbekannt') 'Unbekannte Version darf nicht als fehlende Software behandelt werden'
 $script:entries=@((Entry 'Mozilla Firefox ESR (x64 de)' '153.5.1'))
 $caught='';try{Get-HGInstalledVersion 'Mozilla Firefox\firefox.exe'}catch{$caught=$_.Exception.Message}
 Assert ($caught -match 'ESR') 'ESR darf nicht unbemerkt auf Release umgestellt werden'

 $custom=Join-Path $fixture 'custom'
 $null=New-Item -ItemType Directory -Path $custom
 $file=Join-Path $custom 'chrome.exe'
 Set-Content -LiteralPath $file -Value 'Testdatei'
 $script:fileVersions[$file]=[version]'156.0.8078.48'
 $script:entries=@((Entry 'Google Chrome' '' $custom))
 Assert ((Get-HGInstalledVersion 'Google\Chrome\Application\chrome.exe') -eq [version]'156.0.8078.48') 'Benutzerdefinierter Installationspfad'
 $script:entries=@((Entry 'Google Chrome' '' '' ('"'+$file+'",0') 'CurrentUser'))
 $state=Get-HGSoftwareState Chrome
 Assert ($state.Version -eq [version]'156.0.8078.48' -and $state.Entries[0].Scope -eq 'CurrentUser') 'DisplayIcon / benutzerbezogene Installation'

 $normal=Join-Path $fixture '7-Zip'
 $null=New-Item -ItemType Directory -Path $normal
 $normalFile=Join-Path $normal '7zFM.exe'
 Set-Content -LiteralPath $normalFile -Value 'Testdatei'
 $script:fileVersions[$normalFile]=[version]'26.5.0.0';$script:entries=@()
 Assert ((Get-HGInstalledVersion '7-Zip\7zFM.exe') -eq [version]'26.5.0.0') 'Dateierkennung ohne Registry-Eintrag'
 Write-Host 'PASS: Registry, Programmdateien, eigene Pfade, Benutzerinstallation, unbekannte Version, Adobe, OpenVPN und ESR'
}
finally {
 $env:ProgramW6432=$savedRoots[0];$env:ProgramFiles=$savedRoots[1];${env:ProgramFiles(x86)}=$savedRoots[2];$env:LOCALAPPDATA=$savedRoots[3]
 $resolved=[IO.Path]::GetFullPath($fixture);$allowed=[IO.Path]::GetFullPath($PSScriptRoot)+[IO.Path]::DirectorySeparatorChar
 if(-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Ungueltiger Testpfad'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
