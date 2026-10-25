#Requires -Version 5.1
<#
.SYNOPSIS
Startet das HG-ClientDeployment; auf dem Client wird nur diese Datei benoetigt.
.DESCRIPTION
Laedt den vollstaendigen main-Stand des oeffentlichen GitHub-Repositories als
ZIP in einen eigenen Tempordner. Menue, Installer und lib bleiben zusammen.
Nach Ende des Deployments wird dieser Ordner entfernt; Protokolle bleiben erhalten.
Mit -UseLocal wird stattdessen eine vollstaendige lokale Arbeitskopie verwendet.
.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\deploy_client.ps1
.EXAMPLE
.\deploy_client.ps1 -UseLocal
#>
[CmdletBinding()]
param([switch]$UseLocal)

function Test-HGBootstrapAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-HGDeploymentFiles {
    param([Parameter(Mandatory)][string]$Path)
    $required = @(
        'main.ps1', 'Install-7Zip.ps1', 'Install-AdobeReaderDC.ps1',
        'Install-GoogleChrome.ps1', 'Install-MozillaFirefox.ps1', 'Install-OpenVPN.ps1',
        'Install-HGFernwartung.ps1', 'Install-ServerEye.ps1', 'Install-OEMInformationen.ps1',
        'Install-WindowsUpdates.ps1', 'lib\LatestSoftware.ps1', 'lib\SoftwareInventory.ps1',
        'lib\SoftwareStages.ps1', 'lib\DeploymentPipeline.ps1'
    )
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Path $_) -PathType Leaf) })
    if ($missing.Count -gt 0) { throw "Deployment-Dateien fehlen: $($missing -join ', '). Bitte den vollstaendigen Stand auf GitHub bereitstellen oder die lokale Arbeitskopie vervollstaendigen." }
}

function Expand-HGDeploymentArchive {
    param([Parameter(Mandatory)][string]$ArchivePath, [Parameter(Mandatory)][string]$Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        if ($archive.Entries.Count -eq 0) { throw 'Das heruntergeladene ZIP-Archiv ist leer.' }
        $allowed = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
        foreach ($entry in $archive.Entries) {
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName.Replace('/', '\')))
            if (-not $target.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Das ZIP-Archiv enthaelt einen Pfad ausserhalb des Zielordners.' }
        }
    }
    finally { $archive.Dispose() }
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $Destination -ErrorAction Stop
    $roots = @(Get-ChildItem -LiteralPath $Destination -Directory)
    if ($roots.Count -ne 1) { throw 'Das Repository-Archiv enthaelt keinen eindeutigen Projektordner.' }
    Assert-HGDeploymentFiles -Path $roots[0].FullName
    return $roots[0].FullName
}

function Invoke-HGClientBootstrap {
    [CmdletBinding()]
    param(
        [switch]$UseLocal,
        [string]$SourceRoot = $PSScriptRoot,
        [string]$LauncherPath = $PSCommandPath
    )
    $ErrorActionPreference = 'Stop'
    if (-not (Test-HGBootstrapAdministrator)) {
        Write-Host 'Fordere Administratorrechte fuer das Client-Deployment an...' -ForegroundColor Cyan
        $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$LauncherPath`"")
        if ($UseLocal) { $arguments += '-UseLocal' }
        try {
            $process = Start-Process -FilePath $powershellPath -ArgumentList $arguments -WorkingDirectory $SourceRoot -Verb RunAs -Wait -PassThru -ErrorAction Stop
        }
        catch { throw "Das Deployment konnte nicht mit Administratorrechten gestartet werden. Die UAC-Anfrage wurde moeglicherweise abgebrochen. Details: $($_.Exception.Message)" }
        if ($process.ExitCode -ne 0) { throw "Das Deployment wurde mit Exitcode $($process.ExitCode) beendet." }
        return
    }

    $workRoot = $null
    try {
        if ($UseLocal) {
            Assert-HGDeploymentFiles -Path $SourceRoot
            $projectPath = $SourceRoot
            Write-Host "Verwende lokale Arbeitskopie: $projectPath" -ForegroundColor Cyan
        }
        else {
            $workRoot = Join-Path $env:TEMP ('HG-Bootstrap-' + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $workRoot
            $archivePath = Join-Path $workRoot 'deployment.zip'
            $destination = Join-Path $workRoot 'repository'
            $url = 'https://codeload.github.com/Matze521999/HG-ClientDeployment_v2/zip/refs/heads/main'
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            Write-Host 'Lade das Client-Deployment von GitHub herunter...' -ForegroundColor Cyan
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                try {
                    Invoke-WebRequest -Uri $url -OutFile $archivePath -UseBasicParsing -TimeoutSec 180 -ErrorAction Stop
                    if ((Get-Item -LiteralPath $archivePath).Length -eq 0) { throw 'Leerer Download.' }
                    break
                }
                catch {
                    if ($attempt -eq 3) { throw "Das oeffentliche GitHub-Repository konnte nicht heruntergeladen werden. Bitte Internetverbindung und Zugriff auf codeload.github.com pruefen. Details: $($_.Exception.Message)" }
                    Start-Sleep -Seconds 2
                }
            }
            Write-Host 'Entpacke und pruefe Menue, Installer und Hilfsdateien...' -ForegroundColor Cyan
            $projectPath = Expand-HGDeploymentArchive -ArchivePath $archivePath -Destination $destination
        }
        Write-Host 'Starte das Deployment-Menue...' -ForegroundColor Cyan
        & (Join-Path $projectPath 'main.ps1')
    }
    finally {
        if ($workRoot -and (Test-Path -LiteralPath $workRoot)) {
            $resolved = [IO.Path]::GetFullPath($workRoot)
            $allowed = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
            if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^HG-Bootstrap-[a-f0-9]{32}$') { throw 'Ungueltiger temporaerer Bootstrap-Pfad.' }
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}

Invoke-HGClientBootstrap -UseLocal:$UseLocal
