#Requires -Version 5.1
# Neueste stabile Herstellerversion; Installation fuer den Computer.
[CmdletBinding()]
param([Alias('Install7Zip')][bool]$Install = $true)

if (-not $Install) { Write-Host '7Zip: Installation nicht ausgewaehlt.'; return }
. (Join-Path $PSScriptRoot 'lib\LatestSoftware.ps1')
Invoke-HGLatestSoftware -Software '7Zip'
