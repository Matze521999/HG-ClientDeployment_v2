# Zweistufiger Ablauf: Vorbereitung darf parallel zur Installation laufen.
function Assert-HGAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Bitte als Administrator ausfuehren.' }
}

function Remove-HGPreparedSoftware {
    param($Preparation)
    if ($Preparation.InstallerPath -and (Test-Path -LiteralPath $Preparation.InstallerPath)) { Remove-Item -LiteralPath $Preparation.InstallerPath -Force -ErrorAction SilentlyContinue }
    if ($Preparation.WorkDirectory -and (Test-Path -LiteralPath $Preparation.WorkDirectory)) { Remove-Item -LiteralPath $Preparation.WorkDirectory -Force -ErrorAction SilentlyContinue }
}

function New-HGPreparedSoftware {
    [CmdletBinding()]
    param(
        [ValidateSet('7Zip','Chrome','Firefox','OpenVPN','AdobeReaderDC','HGFernwartung','ServerEye')][string]$Software,
        [string]$WorkRoot = $env:TEMP
    )
    $ErrorActionPreference = 'Stop'
    $prepared = [pscustomobject]@{
        Kind = 'HGPreparedSoftware'; Software = $Software; Status = 'Bereit'; DownloadOnly = ($Software -in @('HGFernwartung','ServerEye'))
        BeforeVersion = ''; TargetVersion = ''; Package = $null; InstallerPath = ''; WorkDirectory = ''
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        if ($prepared.DownloadOnly) {
            $state = Get-HGSoftwareState $Software
            $prepared.BeforeVersion = [string]$state.Version
            $fileName = if ($Software -eq 'HGFernwartung') { 'HG-Fernwartung.exe' } else { 'ServerEyeSetup.exe' }
            $url = if ($Software -eq 'HGFernwartung') { 'https://www.helpme.de/fileadmin/fernwartung/HG-Fernwartung.exe' } else { 'https://update.server-eye.de/download/se/ServerEyeSetup.exe' }
            $signer = if ($Software -eq 'HGFernwartung') { 'TeamViewer Germany GmbH' } else { '(?:servereye GmbH|Kraemer IT Solutions GmbH)' }
            $package = [pscustomobject]@{ Url = $url; Hash = $null; Signer = $signer; Extension = 'exe'; Version = $null; RelativePath = ''; FileName = $fileName }
            $present = if ($state.Found) { if ($state.Version) { "Vorhandene Version: $($state.Version)" } else { 'Software vorhanden; Version unbekannt' } } else { 'Keine installierte Software erkannt' }
            Write-HGSoftwareLog -Software $Software -Message "$present; nur Download-Bereitstellung."
        }
        else {
            $definition = Get-HGSoftwareDefinition $Software
            $before = Get-HGInstalledVersion -RelativePath $definition.RelativePaths[0]
            $prepared.BeforeVersion = [string]$before
            Write-HGSoftwareLog -Software $Software -Message "Versionspruefung vor Download; vorhanden: $before"
            $package = Get-HGPackage -Software $Software -Architecture (Get-HGArchitecture)
            if ($Software -eq 'OpenVPN' -and $before -and $before -gt $package.Version) { throw "OpenVPN $before ist neuer als 2.6.9. Versionskonflikt; kein automatisches Downgrade." }
            if ($package.Version -and $before -and $before -ge $package.Version) {
                $prepared.Status = 'BereitsAktuell'
                $prepared.TargetVersion = [string]$package.Version
                return $prepared
            }
            $fileName = 'Installer.' + $package.Extension
        }
        $prepared.WorkDirectory = Join-Path $WorkRoot ('HG-' + $Software + '-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $prepared.WorkDirectory
        $prepared.InstallerPath = Join-Path $prepared.WorkDirectory $fileName
        $prepared.Package = $package
        Write-HGSoftwareLog -Software $Software -Message "Download: $($package.Url)"
        Invoke-HGDownload $package.Url $prepared.InstallerPath
        Test-HGInstaller -Path $prepared.InstallerPath -Package $package
        if ($prepared.DownloadOnly) { $prepared.TargetVersion = [string](Get-HGFileVersion $prepared.InstallerPath) }
        else {
            if ($package.Extension -eq 'msi') {
                $msiVersion = Get-HGMsiVersion $prepared.InstallerPath
                if ($Software -eq 'OpenVPN') {
                    if ($msiVersion -ne $package.MsiVersion) { throw "Unerwartete OpenVPN-MSI-Version: $msiVersion" }
                }
                else { $package.Version = $msiVersion }
            }
            $prepared.TargetVersion = [string]$package.Version
            if ($before -and $before -ge $package.Version) { $prepared.Status = 'BereitsAktuell' }
        }
        # Strings bleiben beim Transport durch Start-Job eindeutig konvertierbar.
        if ($package.Version) { $package.Version = [string]$package.Version }
        Write-HGSoftwareLog -Software $Software -Message "Download geprueft und bereit; Zielversion: $($prepared.TargetVersion)"
        return $prepared
    }
    catch { Remove-HGPreparedSoftware $prepared; throw }
}

function Complete-HGPreparedDownload {
    param($Preparation, [string]$DestinationDirectory)
    $ErrorActionPreference = 'Stop'
    $software = $Preparation.Software
    if (-not $DestinationDirectory -or -not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) { throw 'Der Zielordner fuer den Download ist nicht vorhanden.' }
    Test-HGInstaller -Path $Preparation.InstallerPath -Package $Preparation.Package
    $target = Join-Path $DestinationDirectory $Preparation.Package.FileName
    $version = if ($Preparation.TargetVersion) { [version]$Preparation.TargetVersion } else { $null }
    $status = 'Heruntergeladen'
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $newHash = (Get-FileHash -LiteralPath $Preparation.InstallerPath -Algorithm SHA256).Hash
        $oldHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        if ($newHash -eq $oldHash) { $status = 'BereitsHeruntergeladen' }
        elseif ($version) {
            $oldVersion = Get-HGFileVersion $target
            if ($oldVersion -and $oldVersion -gt $version) {
                Test-HGInstaller -Path $target -Package $Preparation.Package
                $version = $oldVersion; $status = 'BereitsHeruntergeladen'
            }
        }
    }
    if ($status -eq 'Heruntergeladen') { Copy-Item -LiteralPath $Preparation.InstallerPath -Destination $target -Force }
    $detail = if ($software -eq 'HGFernwartung') {
        'Signiertes TeamViewer-Modul bereitgestellt. Vergleich ohne Versionsmetadaten per SHA-256; keine Softwareinstallation.'
    } else { 'Setup bereitgestellt; Setup- und Agentversion sind getrennt. Keine automatische Installation oder Aktualisierung des Agents.' }
    Write-HGSoftwareLog -Software $software -Message "$status : $target; $detail"
    [pscustomobject]@{ Software = $software; Status = $status; Version = $Preparation.BeforeVersion; PackageVersion = $version; Path = $target; RebootRequired = $false; Details = $detail }
}

function Complete-HGPreparedSoftware {
    [CmdletBinding()]
    param($Preparation, [scriptblock]$OnWaiting, [string]$DestinationDirectory)
    $ErrorActionPreference = 'Stop'
    $software = $Preparation.Software
    if ($Preparation.DownloadOnly) {
        if (-not $DestinationDirectory) {
            $folder = if ($software -eq 'HGFernwartung') { [Environment+SpecialFolder]::CommonDesktopDirectory } else { [Environment+SpecialFolder]::DesktopDirectory }
            $DestinationDirectory = [Environment]::GetFolderPath($folder)
        }
        return Complete-HGPreparedDownload $Preparation $DestinationDirectory
    }
    Assert-HGAdministrator
    $targetVersion = [version]$Preparation.TargetVersion
    if ($Preparation.Status -eq 'BereitsAktuell') {
        Write-HGSoftwareLog -Software $software -Message "Bereits aktuell: $($Preparation.BeforeVersion)"
        return [pscustomobject]@{ Software = $software; Status = 'BereitsAktuell'; Version = $Preparation.BeforeVersion; RebootRequired = $false }
    }
    # Noch einmal direkt vor dem Start pruefen: Ein Auto-Updater kann waehrend
    # der Downloads die installierte Version bereits angehoben haben.
    $before = Get-HGInstalledVersion $Preparation.Package.RelativePath
    if ($software -eq 'OpenVPN' -and $before -and $before -gt $targetVersion) { throw 'OpenVPN-Versionskonflikt; kein automatisches Downgrade.' }
    if ($before -and $before -ge $targetVersion) {
        return [pscustomobject]@{ Software = $software; Status = 'BereitsAktuell'; Version = $before; RebootRequired = $false }
    }
    Test-HGInstaller -Path $Preparation.InstallerPath -Package $Preparation.Package
    $executable = $Preparation.InstallerPath
    $arguments = '/S'
    if ($software -eq 'Firefox') { $arguments = '/S /PreventRebootRequired=true /RemoveDistributionDir=false' }
    if ($software -eq 'AdobeReaderDC') { $arguments = '/sAll /rs /rps /l /re' }
    if ($Preparation.Package.Extension -eq 'msi') {
        $executable = Join-Path $env:SystemRoot 'System32\msiexec.exe'
        $arguments = "/i `"$($Preparation.InstallerPath)`" /qn /norestart"
    }
    Write-HGSoftwareLog -Software $software -Message "Installation startet; Zielversion: $targetVersion"
    if ($OnWaiting) {
        $process = Start-Process -FilePath $executable -ArgumentList $arguments -PassThru -ErrorAction Stop
        # Erst nach Ende des Installers weitergehen, auch wenn die Anzeige scheitert.
        try {
            while (-not $process.HasExited) { & $OnWaiting; Start-Sleep -Milliseconds 150; $process.Refresh() }
        }
        finally { $process.WaitForExit(); $process.Refresh() }
    }
    else { $process = Start-Process -FilePath $executable -ArgumentList $arguments -Wait -PassThru -ErrorAction Stop }
    $code = $process.ExitCode
    Write-HGSoftwareLog -Software $software -Message "Installer-Exitcode: $code"
    if ($code -notin @(0,3010)) { throw "Installation fehlgeschlagen (Exitcode $code)." }
    $after = Get-HGInstalledVersion $Preparation.Package.RelativePath
    $reboot = $code -eq 3010
    if (-not $after -or $after -lt $targetVersion -or ($software -eq 'OpenVPN' -and $after -ne $targetVersion)) {
        if (-not $reboot) { throw "Zielversion nach Installation nicht nachweisbar (gefunden: $after)." }
        return [pscustomobject]@{ Software = $software; Status = 'NeustartAusstehend'; Version = $after; RebootRequired = $true }
    }
    Write-HGSoftwareLog -Software $software -Message "Installiert und geprueft: $after; Neustart erforderlich: $reboot"
    [pscustomobject]@{ Software = $software; Status = 'Installiert'; Version = $after; RebootRequired = $reboot }
}

function Invoke-HGLatestSoftware {
    [CmdletBinding()]
    param([ValidateSet('7Zip','Chrome','Firefox','OpenVPN','AdobeReaderDC')][string]$Software)
    $ErrorActionPreference = 'Stop'; $preparation = $null
    try { Assert-HGAdministrator; $preparation = New-HGPreparedSoftware $Software; Complete-HGPreparedSoftware $preparation }
    catch { Write-HGSoftwareLog -Software $Software -Message "Fehlgeschlagen: $($_.Exception.Message)"; throw }
    finally { if ($preparation) { Remove-HGPreparedSoftware $preparation } }
}

function Invoke-HGSoftwareDownload {
    [CmdletBinding()]
    param([ValidateSet('HGFernwartung','ServerEye')][string]$Software, [Parameter(Mandatory)][string]$DestinationDirectory)
    $ErrorActionPreference = 'Stop'; $preparation = $null
    try { $preparation = New-HGPreparedSoftware $Software; Complete-HGPreparedSoftware $preparation -DestinationDirectory $DestinationDirectory }
    catch { Write-HGSoftwareLog -Software $Software -Message "Fehlgeschlagen: $($_.Exception.Message)"; throw }
    finally { if ($preparation) { Remove-HGPreparedSoftware $preparation } }
}

