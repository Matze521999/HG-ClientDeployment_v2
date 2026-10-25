#Requires -Version 5.1
# OpenVPN bleibt gezielt auf 2.6.9-I001 festgelegt, unabhaengig von neuen Releases.
[CmdletBinding()]
param([Alias('InstallOpenVPN')][bool]$Install = $true)

if (-not $Install) { Write-Host 'OpenVPN: Installation nicht ausgewaehlt.'; return }
. (Join-Path $PSScriptRoot 'lib\LatestSoftware.ps1')
Invoke-HGLatestSoftware -Software 'OpenVPN'
