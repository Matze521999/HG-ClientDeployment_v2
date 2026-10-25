#Requires -Version 5.1
# Nur Setup-Download: keine Neukonfiguration eines vorhandenen ServerEye-Agents.
[CmdletBinding()]
param(
    [Alias('InstallServerEye')][bool]$Install = $true,
    [string]$DestinationDirectory = ([Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory))
)

if (-not $Install) { Write-Host 'ServerEye: Download nicht ausgewaehlt.'; return }
. (Join-Path $PSScriptRoot 'lib\LatestSoftware.ps1')
Invoke-HGSoftwareDownload -Software ServerEye -DestinationDirectory $DestinationDirectory
