<#
.SYNOPSIS
Installiert ausstehende Windows-Softwareupdates ueber den Windows Update Agent.
.DESCRIPTION
Als Administrator ausfuehren. Verwendet die konfigurierte Updatequelle (auch WSUS),
benoetigt weder winget noch PowerShell-Gallery-Module. Treiber und ausgeblendete
Updates bleiben ausgeschlossen. Kein automatischer Neustart; nach einem Neustart
erneut ausfuehren, um gegebenenfalls weitere Updates zu installieren.
.EXAMPLE
.\Install-WindowsUpdates.ps1
#>
function Test-WindowsUpdateAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-WindowsUpdates {
    [CmdletBinding()]
    param (
        [string]$LogPath = (Join-Path $env:TEMP 'log.txt')
    )

    function Write-UpdateLog {
        param([string]$Message)
        Write-Host $Message
        Add-Content -LiteralPath $LogPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Windows Update - $Message" -ErrorAction Stop
    }

    try {
        if (-not (Test-WindowsUpdateAdministrator)) {
            throw 'Bitte das Skript in einer PowerShell als Administrator ausfuehren.'
        }
        Write-UpdateLog 'Starte Windows-Updates. Es erfolgt kein automatischer Neustart.'
        Start-Service -Name wuauserv -ErrorAction Stop
        $systemInfo = New-Object -ComObject Microsoft.Update.SystemInfo -ErrorAction Stop
        if ($systemInfo.RebootRequired) {
            Write-UpdateLog 'Ein Neustart steht bereits aus. Bitte Windows neu starten und das Skript danach erneut ausfuehren.'
            return
        }

        $session = New-Object -ComObject Microsoft.Update.Session -ErrorAction Stop
        $session.ClientApplicationID = 'HG-ClientDeployment'
        $searcher = $session.CreateUpdateSearcher()
        Write-UpdateLog 'Suche nach fehlenden Softwareupdates ueber die konfigurierte Updatequelle...'
        $search = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
        if ($search.ResultCode -ne 2) {
            throw "Die Updatesuche war nicht vollstaendig erfolgreich (ResultCode $($search.ResultCode))."
        }
        if ($search.Updates.Count -eq 0) {
            Write-UpdateLog 'Keine ausstehenden Softwareupdates gefunden.'
            return
        }

        Write-UpdateLog "$($search.Updates.Count) Update(s) gefunden."
        $failed = 0
        $installed = 0
        $skipped = 0
        $rebootRequired = $false
        # Einzeln installieren: Auch Updates, die eine exklusive Installation
        # benoetigen, koennen so verarbeitet werden.
        for ($i = 0; $i -lt $search.Updates.Count; $i++) {
            $update = $search.Updates.Item($i)
            try {
                if ($update.InstallationBehavior.CanRequestUserInput) {
                    $skipped++
                    Write-UpdateLog "Manuelle Installation erforderlich, uebersprungen: $($update.Title)"
                    continue
                }
                if (-not $update.EulaAccepted) { $update.AcceptEula() }
                $collection = New-Object -ComObject Microsoft.Update.UpdateColl -ErrorAction Stop
                $null = $collection.Add($update)
                if (-not $update.IsDownloaded) {
                    Write-UpdateLog "Lade herunter: $($update.Title)"
                    $downloader = $session.CreateUpdateDownloader()
                    $downloader.Updates = $collection
                    $download = $downloader.Download()
                    if ($download.ResultCode -ne 2 -or -not $update.IsDownloaded) {
                        throw "Download fehlgeschlagen (ResultCode $($download.ResultCode), HRESULT $($download.GetUpdateResult(0).HResult))."
                    }
                }
                $installer = $session.CreateUpdateInstaller()
                if ($installer.RebootRequiredBeforeInstallation) {
                    $rebootRequired = $true
                    break
                }
                $installer.Updates = $collection
                $installer.AllowSourcePrompts = $false
                Write-UpdateLog "Installiere: $($update.Title)"
                $result = $installer.Install()
                $detail = $result.GetUpdateResult(0)
                $rebootRequired = $result.RebootRequired -or $systemInfo.RebootRequired
                if ($result.ResultCode -ne 2 -or $detail.ResultCode -ne 2) {
                    throw "Installation nicht erfolgreich (ResultCode $($result.ResultCode)/$($detail.ResultCode), HRESULT $($detail.HResult))."
                }
                $installed++
                Write-UpdateLog "Erfolgreich installiert: $($update.Title)"
            }
            catch {
                $failed++
                Write-UpdateLog "Fehler bei '$($update.Title)': $($_.Exception.Message)"
            }
            if ($rebootRequired) { break }
        }

        Write-UpdateLog "Ergebnis: $installed installiert, $failed fehlgeschlagen, $skipped manuell zu installieren."
        if ($rebootRequired) {
            Write-UpdateLog 'Neustart erforderlich. Bitte Windows neu starten und das Skript erneut ausfuehren; weitere Updates koennen noch ausstehen.'
        }
        if ($failed -gt 0) { throw "$failed Update(s) konnten nicht erfolgreich verarbeitet werden. Details: $LogPath" }
    }
    catch {
        Write-Error "Windows-Updates fehlgeschlagen: $($_.Exception.Message)"
    }
}

Install-WindowsUpdates
