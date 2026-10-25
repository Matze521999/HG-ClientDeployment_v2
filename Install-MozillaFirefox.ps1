#Requires -Version 5.1
# Neueste stabile Herstellerversion; Installation fuer den Computer.
[CmdletBinding()]
param([Alias('InstallFirefox')][bool]$Install = $true)

if (-not $Install) { Write-Host 'Firefox: Installation nicht ausgewaehlt.'; return }
. (Join-Path $PSScriptRoot 'lib\LatestSoftware.ps1')
Invoke-HGLatestSoftware -Software 'Firefox'
