#Requires -Version 5.1
# Neueste stabile Herstellerversion; Installation fuer den Computer.
[CmdletBinding()]
param([Alias('InstallChrome')][bool]$Install = $true)

if (-not $Install) { Write-Host 'Chrome: Installation nicht ausgewaehlt.'; return }
. (Join-Path $PSScriptRoot 'lib\LatestSoftware.ps1')
Invoke-HGLatestSoftware -Software 'Chrome'
