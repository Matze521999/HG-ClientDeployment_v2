#Requires -Version 5.1
# Aktueller Adobe Reader; vorhandene Version pruefen und nur bei Bedarf installieren.
[CmdletBinding()]
param([Alias('InstallAdobeReader', 'InstallAdobeReaderDC')][bool]$Install = $true)

if (-not $Install) { Write-Host 'Adobe Reader: Installation nicht ausgewaehlt.'; return }
. (Join-Path $PSScriptRoot 'lib\LatestSoftware.ps1')
Invoke-HGLatestSoftware -Software AdobeReaderDC
