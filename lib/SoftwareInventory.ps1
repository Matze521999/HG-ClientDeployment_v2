# Erkennung ueber Uninstall-Registry (beide Ansichten) und bekannte Programmdateien.
# Win32_Product wird bewusst nicht verwendet: Die Abfrage kann MSI-Reparaturen ausloesen.
function Get-HGUninstallEntries {
    foreach ($scope in @('Machine', 'CurrentUser')) {
        $hive = if ($scope -eq 'Machine') { [Microsoft.Win32.RegistryHive]::LocalMachine } else { [Microsoft.Win32.RegistryHive]::CurrentUser }
        foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
            $base = $uninstall = $null
            try {
                $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
                $uninstall = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
                if (-not $uninstall) { continue }
                foreach ($name in $uninstall.GetSubKeyNames()) {
                    $key = $null
                    try {
                        $key = $uninstall.OpenSubKey($name)
                        if (-not $key) { continue }
                        $displayName = [string]$key.GetValue('DisplayName')
                        if (-not $displayName -or $key.GetValue('SystemComponent') -eq 1) { continue }
                        [pscustomobject]@{
                            DisplayName = $displayName; DisplayVersion = [string]$key.GetValue('DisplayVersion')
                            InstallLocation = [string]$key.GetValue('InstallLocation'); DisplayIcon = [string]$key.GetValue('DisplayIcon')
                            Publisher = [string]$key.GetValue('Publisher'); Scope = $scope
                        }
                    }
                    catch {
                        if ($_.Exception -is [Security.SecurityException] -or $_.Exception -is [UnauthorizedAccessException] -or $_.Exception.InnerException -is [Security.SecurityException] -or $_.Exception.InnerException -is [UnauthorizedAccessException]) {
                            Write-Verbose "Ein geschuetzter Uninstall-Eintrag ist nicht lesbar ($scope/$view)."
                        }
                        else { throw }
                    }
                    finally { if ($key) { $key.Dispose() } }
                }
            }
            finally { if ($uninstall) { $uninstall.Dispose() }; if ($base) { $base.Dispose() } }
        }
    }
}

function Get-HGSoftwareDefinition {
    param([string]$Software)
    switch ($Software) {
        '7Zip' { @{ Pattern = '^7-Zip(?: |$)'; RelativePaths = @('7-Zip\7zFM.exe'); Executables = @('7zFM.exe') } }
        'Chrome' { @{ Pattern = '^Google Chrome$'; RelativePaths = @('Google\Chrome\Application\chrome.exe'); Executables = @('chrome.exe') } }
        'Firefox' { @{ Pattern = '^Mozilla Firefox(?: |$)'; RelativePaths = @('Mozilla Firefox\firefox.exe'); Executables = @('firefox.exe') } }
        'OpenVPN' { @{ Pattern = '^OpenVPN(?: |$)'; RelativePaths = @('OpenVPN\bin\openvpn.exe'); Executables = @('openvpn.exe') } }
        'AdobeReaderDC' { @{ Pattern = '^Adobe (?:Acrobat(?: Reader| DC)?|Reader)(?: \((?:32|64)-bit\))?$'; RelativePaths = @('Adobe\Acrobat DC\Acrobat\Acrobat.exe', 'Adobe\Acrobat Reader DC\Reader\AcroRd32.exe'); Executables = @('Acrobat.exe','AcroRd32.exe') } }
        'HGFernwartung' { @{ Pattern = '^(?:HG[- ]Fernwartung|TeamViewer)(?: |$)'; RelativePaths = @('TeamViewer\TeamViewer.exe'); Executables = @('TeamViewer.exe') } }
        'ServerEye' { @{ Pattern = '^Server[- ]?Eye(?: |$)'; RelativePaths = @('Server-Eye\ServerEye.Service.exe'); Executables = @('ServerEye.Service.exe') } }
        default { throw "Unbekannte Software: $Software" }
    }
}

function Get-HGFileVersion {
    param([string]$Path)
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    if ($info.ProductVersion) { return ConvertTo-HGVersion $info.ProductVersion }
    if ($info.FileVersion) { return ConvertTo-HGVersion $info.FileVersion }
    return $null
}

function Get-HGSoftwareState {
    param([string]$Software)
    $definition = Get-HGSoftwareDefinition $Software
    $entries = @(Get-HGUninstallEntries | Where-Object { $_.DisplayName -match $definition.Pattern })
    $versions = @(); $unknown = $false; $fileFound = $false
    $roots = @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | Select-Object -Unique
    $paths = @()
    foreach ($root in $roots) { foreach ($relative in $definition.RelativePaths) { $paths += Join-Path $root $relative } }
    if ($Software -eq 'Chrome' -and $env:LOCALAPPDATA) { $paths += Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe' }
    foreach ($entry in $entries) {
        $entryVersion = $null
        try { if ($entry.DisplayVersion) { $entryVersion = ConvertTo-HGVersion $entry.DisplayVersion } } catch { }
        if ($entry.InstallLocation) {
            foreach ($exe in $definition.Executables) { $paths += Join-Path ([Environment]::ExpandEnvironmentVariables($entry.InstallLocation.Trim('"'))) $exe }
            # OpenVPN und Adobe enthalten ein weiteres Unterverzeichnis.
            foreach ($relative in $definition.RelativePaths) {
                $relativeParts = $relative -split '\\', 2
                if ($relativeParts.Count -eq 2) { $paths += Join-Path $entry.InstallLocation $relativeParts[1] }
            }
        }
        if ($entry.DisplayIcon -match '^"?(.+?\.exe)(?:"|,|$)') {
            $iconPath = [Environment]::ExpandEnvironmentVariables($matches[1])
            if ([IO.Path]::GetFileName($iconPath) -in $definition.Executables) { $paths += $iconPath }
        }
        if ($entryVersion) { $versions += $entryVersion } else { $unknown = $true }
    }
    foreach ($path in $paths | Select-Object -Unique) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $fileFound = $true
            try { $fileVersion = Get-HGFileVersion $path; if ($fileVersion) { $versions += $fileVersion } else { $unknown = $true } }
            catch { $unknown = $true }
        }
    }
    # Die OpenVPN-MSI-Buildversion 2.6.901 ist nicht die Softwareversion.
    if ($Software -eq 'OpenVPN') {
        $versions = @($versions | ForEach-Object {
            if ($_.Major -eq 2 -and $_.Minor -eq 6 -and $_.Build -ge 100) {
                [version]("2.6.{0}.0" -f [math]::Floor($_.Build / 100))
            } else { $_ }
        })
    }
    [pscustomobject]@{
        Found = ($entries.Count -gt 0 -or $fileFound)
        Version = ($versions | Sort-Object -Descending | Select-Object -First 1)
        VersionUnknown = ($unknown -and $versions.Count -eq 0)
        Entries = $entries
    }
}

function Write-HGSoftwareLog {
    param([string]$Message, [string]$Software)
    Write-Host "${Software}: $Message"
    $softwareLogPath = if ($env:HG_DEPLOYMENT_LOG) { $env:HG_DEPLOYMENT_LOG } else { Join-Path $env:TEMP 'log.txt' }
    Add-Content -LiteralPath $softwareLogPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - ${Software}: $Message" -ErrorAction Stop
}


