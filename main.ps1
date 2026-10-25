#Requires -Version 5.1
<#
.SYNOPSIS
Lokales Auswahlmenue fuer das HG-ClientDeployment.
.DESCRIPTION
Am besten ueber deploy_client.ps1 starten. Nur Skripte aus diesem Projektordner
werden ausgefuehrt. Das Sitzungsprotokoll liegt unter %TEMP%\HG-ClientDeployment.
#>
. (Join-Path $PSScriptRoot 'lib\LatestSoftware.ps1')
. (Join-Path $PSScriptRoot 'lib\DeploymentPipeline.ps1')

function Get-DeploymentOptions {
    # Diese Reihenfolge gilt fuer Anzeige und Ausfuehrung; Updates zuletzt.
    [pscustomobject]@{ Name = '7Zip'; Label = '7-Zip'; Selected = $true }
    [pscustomobject]@{ Name = 'AdobeReaderDC'; Label = 'Adobe Reader'; Selected = $true }
    [pscustomobject]@{ Name = 'GoogleChrome'; Label = 'Google Chrome'; Selected = $true }
    [pscustomobject]@{ Name = 'MozillaFirefox'; Label = 'Mozilla Firefox'; Selected = $false }
    [pscustomobject]@{ Name = 'OpenVPN'; Label = 'OpenVPN'; Selected = $false }
    [pscustomobject]@{ Name = 'HGFernwartung'; Label = 'HG-Fernwartung (Download)'; Selected = $true }
    [pscustomobject]@{ Name = 'ServerEye'; Label = 'ServerEye (Download)'; Selected = $false }
    [pscustomobject]@{ Name = 'OEMInformationen'; Label = 'OEM-Informationen'; Selected = $true }
    [pscustomobject]@{ Name = 'WindowsUpdates'; Label = 'Windows-Updates'; Selected = $false }
}

function Test-DeploymentAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-HGConsoleKey {
    try { return $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }
    catch { throw 'Die direkte Tastenauswahl benoetigt eine interaktive PowerShell-Konsole. Bitte deploy_client.ps1 in powershell.exe starten.' }
}

function Read-HGMenuKey {
    param([string]$Prompt)
    Write-Host "  $Prompt " -NoNewline -ForegroundColor Cyan
    while ($true) {
        $key = Get-HGConsoleKey
        # Modifier-Tasten und Kombinationen wie Alt+A nicht als Menuebefehl werten.
        if (([int]$key.ControlKeyState -band 15) -ne 0) { continue }
        if ($key.VirtualKeyCode -eq 27) { Write-Host 'Esc'; return 'q' }
        # Zahlenblock unterstuetzen, auch wenn der Host kein Zeichen liefert.
        if ($key.VirtualKeyCode -ge 96 -and $key.VirtualKeyCode -le 105) {
            $choice = [string]($key.VirtualKeyCode - 96)
        }
        elseif ([string]$key.Character -match '^[a-zA-Z0-9]$') {
            $choice = ([string]$key.Character).ToLowerInvariant()
        }
        else { continue } # Enter, Pfeil- und reine Umschalttasten ignorieren.
        Write-Host $choice
        return $choice
    }
}

function Show-DeploymentMenu {
    param([object[]]$Options, [string]$Notice, [switch]$NoClear)
    if (-not $NoClear -and -not [Console]::IsOutputRedirected) { Clear-Host }
    Write-Host ''
    Write-Host '  HG  /  CLIENT DEPLOYMENT' -ForegroundColor Cyan
    Write-Host '  Software auswaehlen und den Arbeitsplatz einrichten.' -ForegroundColor DarkGray
    Write-Host ('  ' + ('-' * 76)) -ForegroundColor DarkGray
    Write-Host '       AUSWAHL   PROGRAMM                         VERSION / AUFGABE' -ForegroundColor DarkGray
    $group = ''
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $option = $Options[$i]
        $nextGroup = switch ($option.Name) {
            { $_ -in @('HGFernwartung','ServerEye') } { 'SUPPORT-DOWNLOADS'; break }
            { $_ -in @('OEMInformationen','WindowsUpdates') } { 'WINDOWS & EINRICHTUNG'; break }
            default { 'SOFTWARE' }
        }
        if ($nextGroup -ne $group) {
            Write-Host "`n  $nextGroup" -ForegroundColor White
            $group = $nextGroup
        }
        $description = switch ($option.Name) {
            'OpenVPN' { 'Fest: 2.6.9' }
            'HGFernwartung' { 'Nur bereitstellen' }
            'ServerEye' { 'Nur Setup bereitstellen' }
            'OEMInformationen' { 'Hersteller & Support' }
            'WindowsUpdates' { 'Zum Schluss ausfuehren' }
            default { 'Neueste stabile Version' }
        }
        $label = $option.Label -replace ' \(Download\)$',''
        $mark = if ($option.Selected) { '[x]' } else { '[ ]' }
        $color = if ($option.Selected) { 'Green' } else { 'DarkGray' }
        Write-Host ('  {0,2}   {1}       {2,-31} {3}' -f ($i + 1),$mark,$label,$description) -ForegroundColor $color
    }
    $count = @($Options | Where-Object Selected).Count
    Write-Host "`n  $count von $($Options.Count) Aufgaben ausgewaehlt" -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 76)) -ForegroundColor DarkGray
    Write-Host '  1-9     Sofort umschalten     A  Alle     N  Keine' -ForegroundColor Gray
    Write-Host '  Y       Jetzt starten        Q / Esc  Beenden' -ForegroundColor White
    Write-Host "`n  Direkt per Tastendruck bedienen - kein Enter erforderlich."
    Write-Host '  Downloads laufen fortlaufend. Installationen laufen einzeln.' -ForegroundColor DarkGray
    if ($Notice) { Write-Host "`n  $Notice" -ForegroundColor Yellow }
    Write-Host ''
}
function Invoke-DeploymentScripts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Options, [Parameter(Mandatory)][string]$ScriptDirectory)
    Invoke-HGDeploymentPipeline -Options $Options -ScriptDirectory $ScriptDirectory
}
function Start-ClientDeployment {
    [CmdletBinding()]
    param(
        [string]$ScriptDirectory = $PSScriptRoot,
        [string]$LogDirectory = (Join-Path $env:TEMP 'HG-ClientDeployment')
    )
    $ErrorActionPreference = 'Stop'
    $transcriptStarted = $false
    try {
        if (-not (Test-DeploymentAdministrator)) {
            throw 'Administratorrechte fehlen. Bitte deploy_client.ps1 starten oder PowerShell als Administrator oeffnen.'
        }
        $null = New-Item -ItemType Directory -Path $LogDirectory -Force
        $logPath = Join-Path $LogDirectory ('Deployment-{0}-{1}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N'))
        $null = Start-Transcript -LiteralPath $logPath -ErrorAction Stop
        $transcriptStarted = $true
        Write-Host "Sitzungsprotokoll: $logPath"
        $options = @(Get-DeploymentOptions)
        $notice = ''
        while ($true) {
            Show-DeploymentMenu -Options $options -Notice $notice
            $notice = ''
            $choice = Read-HGMenuKey -Prompt 'Auswahl:'
            if ($choice -in @('q', 'abbrechen')) {
                Write-Host 'Deployment abgebrochen. Es wurden keine Installationsskripte gestartet.'
                return
            }
            if ($choice -in @('a','n')) {
                foreach ($option in $options) { $option.Selected = ($choice -eq 'a') }
                continue
            }
            if ($choice -eq 'y') {
                $selected = @($options | Where-Object { $_.Selected })
                if ($selected.Count -eq 0) {
                    $notice = 'Bitte mindestens eine Aufgabe auswaehlen.'
                    continue
                }
                $results = @(Invoke-DeploymentScripts -Options $options -ScriptDirectory $ScriptDirectory)
                Write-Host "`nAbschlussuebersicht" -ForegroundColor Cyan
                $results | Format-Table Aufgabe, @{Label='Ergebnis';Expression={
                    switch ($_.Status) {
                        'BereitsAktuell' { 'Bereits aktuell' }
                        'BereitsHeruntergeladen' { 'Datei vorhanden' }
                        'Heruntergeladen' { 'Datei bereit' }
                        'NeustartAusstehend' { 'Neustart offen' }
                        'Uebersprungen' { 'Nicht ausgewaehlt' }
                        default { $_.Status }
                    }
                }}, Version, Sekunden -AutoSize | Out-Host
                foreach ($result in $results | Where-Object { $_.Status -eq 'Fehlgeschlagen' }) {
                    Write-Host "$($result.Aufgabe): $($result.Details)" -ForegroundColor Red
                }
                if (@($results | Where-Object RebootRequired).Count -gt 0) { Write-Host '  Ein Neustart ist erforderlich. Bitte nach Abschluss neu starten.' -ForegroundColor Yellow }
                if (@($results | Where-Object { $_.Status -eq 'Durchgelaufen' }).Count -gt 0) { Write-Host '  Durchgelaufen: Skript ohne gemeldeten Fehler; keine zentrale Erfolgskontrolle.' -ForegroundColor DarkGray }
                Write-Host "Vollstaendiges Sitzungsprotokoll: $logPath"
                $null = Read-Host 'Enter zum Beenden'
                return
            }
            $index = 0
            if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $options.Count) {
                $options[$index - 1].Selected = -not $options[$index - 1].Selected
            }
            else {
                $notice = "Bitte eine Nummer von 1 bis $($options.Count), A, N, Y oder Q eingeben."
            }
        }
    }
    finally {
        if ($transcriptStarted) { $null = Stop-Transcript }
    }
}

Start-ClientDeployment
