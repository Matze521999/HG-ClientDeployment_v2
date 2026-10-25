#Requires -Version 5.1
# Nur Download: Die HG-Fernwartung wird nicht gestartet oder installiert.
[CmdletBinding()]
param(
    [Alias('InstallHGFernwartung')][bool]$Install = $true,
    [string]$DestinationDirectory = ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonDesktopDirectory))
)

if (-not $Install) { Write-Host 'HG-Fernwartung: Download nicht ausgewaehlt.'; return }
. (Join-Path $PSScriptRoot 'lib\LatestSoftware.ps1')
Invoke-HGSoftwareDownload -Software HGFernwartung -DestinationDirectory $DestinationDirectory
