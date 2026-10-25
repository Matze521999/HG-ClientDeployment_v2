. (Join-Path $PSScriptRoot 'SoftwareInventory.ps1')

# Gemeinsamer Ablauf fuer die aktuellen Herstellerpakete (PowerShell 5.1+).
function ConvertTo-HGVersion {
    param([string]$Text)
    $match = [regex]::Match($Text, '\d+(?:\.\d+){1,3}')
    if (-not $match.Success) { throw "Ungueltige Versionsangabe: $Text" }
    $parts = @($match.Value.Split('.') | ForEach-Object { [int]$_ })
    while ($parts.Count -lt 4) { $parts += 0 }
    return [version]($parts -join '.')
}

function Get-HGInstalledVersion {
    param([string]$RelativePath)
    $software = switch -Regex ($RelativePath) {
        '^7-Zip\\' { '7Zip'; break }
        '^Google\\' { 'Chrome'; break }
        '^Mozilla Firefox\\' { 'Firefox'; break }
        '^OpenVPN\\' { 'OpenVPN'; break }
        '^Adobe\\' { 'AdobeReaderDC'; break }
        default { throw "Keine Softwarezuordnung fuer $RelativePath" }
    }
    $state = Get-HGSoftwareState $software
    if ($state.Found -and -not $state.Version) { throw "$software ist vorhanden, aber die Version ist unbekannt. Keine ungepruefte Neuinstallation." }
    if ($software -eq 'Firefox' -and @($state.Entries | Where-Object { $_.DisplayName -match '\bESR\b' }).Count -gt 0) {
        throw 'Firefox ESR ist installiert. Kein automatischer Wechsel auf Firefox Release.'
    }
    return $state.Version
}
function Get-HGArchitecture {
    $architecture = $env:PROCESSOR_ARCHITEW6432
    if (-not $architecture) { $architecture = $env:PROCESSOR_ARCHITECTURE }
    switch ($architecture) {
        'AMD64' { 'x64' }
        'ARM64' { 'arm64' }
        'x86' { 'x86' }
        default { throw "Nicht unterstuetzte Windows-Architektur: $architecture" }
    }
}

function Invoke-HGDownload {
    param([string]$Uri, [string]$OutFile)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
            if ((Get-Item -LiteralPath $OutFile).Length -eq 0) { throw 'Leerer Download.' }
            return
        }
        catch {
            if ($attempt -eq 3) { throw }
            Start-Sleep -Seconds 2
        }
    }
}

function Get-HGPackage {
    param([ValidateSet('7Zip', 'Chrome', 'Firefox', 'OpenVPN', 'AdobeReaderDC')][string]$Software, [string]$Architecture)
    $request = @{ UseBasicParsing = $true; TimeoutSec = 60; ErrorAction = 'Stop' }
    switch ($Software) {
        '7Zip' {
            $page = (Invoke-WebRequest -Uri 'https://www.7-zip.org/download.html' @request).Content
            $versionText = [regex]::Match($page, 'Download 7-Zip (\d+\.\d+)').Groups[1].Value
            $version = ConvertTo-HGVersion $versionText
            $suffix = switch ($Architecture) { 'x64' { '-x64' }; 'arm64' { '-arm64' }; 'x86' { '' } }
            $fileName = '7z' + $versionText.Replace('.', '') + $suffix + '.exe'
            $pattern = '(?i)href\s*=\s*["''](?<url>[^"'']*/' + [regex]::Escape($fileName) + ')["'']'
            $link = [regex]::Match($page, $pattern).Groups['url'].Value
            if (-not $link) { throw "Kein aktueller 7-Zip-Download fuer $Architecture gefunden." }
            $uri = [uri]::new([uri]'https://www.7-zip.org/download.html', $link)
            if ($uri.Scheme -ne 'https' -or $uri.Host -notin @('7-zip.org', 'www.7-zip.org', 'github.com')) { throw 'Unerwartete 7-Zip-Downloadadresse.' }
            # Der Hersteller veroeffentlicht seine Pakete auch unter ip7z/7zip.
            # GitHub liefert zu neueren Release-Assets den SHA-256-Digest.
            $release = Invoke-RestMethod -Uri "https://api.github.com/repos/ip7z/7zip/releases/tags/$versionText" @request
            $asset = @($release.assets | Where-Object { $_.name -eq $fileName })
            if ($asset.Count -ne 1 -or $asset[0].digest -notmatch '^sha256:([a-fA-F0-9]{64})$') {
                throw 'Kein eindeutiger 7-Zip-Download mit SHA-256-Pruefsumme verfuegbar.'
            }
            $hash = $matches[1]
            $assetUri = [uri]$asset[0].browser_download_url
            if ($assetUri.Scheme -ne 'https' -or $assetUri.Host -ne 'github.com' -or -not $assetUri.AbsolutePath.StartsWith('/ip7z/7zip/releases/download/')) { throw 'Unerwartete 7-Zip-Releaseadresse.' }
            return [pscustomobject]@{ Url = $assetUri.AbsoluteUri; Version = $version; Hash = $hash; Signer = $null; Extension = 'exe'; RelativePath = '7-Zip\7zFM.exe' }
        }
        'AdobeReaderDC' { return Get-HGAdobePackage -Architecture $Architecture }
        'Chrome' {
            $file = switch ($Architecture) { 'x64' { 'googlechromestandaloneenterprise64.msi' }; 'arm64' { 'googlechromestandaloneenterprise_arm64.msi' }; 'x86' { 'googlechromestandaloneenterprise.msi' } }
            # Die Zielversion wird direkt aus dem frisch geladenen MSI gelesen.
            return [pscustomobject]@{ Url = "https://dl.google.com/dl/chrome/install/$file"; Version = $null; Hash = $null; Signer = 'Google (LLC|Inc\.)'; Extension = 'msi'; RelativePath = 'Google\Chrome\Application\chrome.exe' }
        }
        'OpenVPN' {
            # Bewusst festgeschrieben: keine automatische Auswahl neuer Releases.
            $platform = switch ($Architecture) { 'x64' { 'amd64' }; 'arm64' { 'arm64' }; 'x86' { 'x86' } }
            return [pscustomobject]@{
                Url = "https://build.openvpn.net/downloads/releases/OpenVPN-2.6.9-I001-$platform.msi"
                Version = [version]'2.6.9.0'
                MsiVersion = [version]'2.6.901.0'
                Hash = $null
                Signer = 'OpenVPN Inc\.'
                Extension = 'msi'
                RelativePath = 'OpenVPN\bin\openvpn.exe'
            }
        }
        'Firefox' {
            $metadata = Invoke-RestMethod -Uri 'https://product-details.mozilla.org/1.0/firefox_versions.json' @request
            $versionText = [string]$metadata.LATEST_FIREFOX_VERSION
            if ($versionText -notmatch '^\d+\.\d+(?:\.\d+)?$') { throw 'Keine stabile Firefox-Version gefunden.' }
            $platform = switch ($Architecture) { 'x64' { 'win64' }; 'arm64' { 'win64-aarch64' }; 'x86' { 'win32' } }
            # Versionsgebundener Download verhindert einen Versionswechsel zwischen
            # Metadatenabruf und Download, bleibt bei jedem Skriptstart aktuell.
            $url = "https://archive.mozilla.org/pub/firefox/releases/$versionText/$platform/de/Firefox%20Setup%20$versionText.exe"
            return [pscustomobject]@{ Url = $url; Version = (ConvertTo-HGVersion $versionText); Hash = $null; Signer = 'Mozilla Corporation'; Extension = 'exe'; RelativePath = 'Mozilla Firefox\firefox.exe' }
        }
    }
}

function Get-HGMsiVersion {
    param([string]$Path)
    $installer = $database = $view = $record = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer -ErrorAction Stop
        $database = $installer.OpenDatabase($Path, 0)
        $view = $database.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='ProductVersion'")
        $null = $view.Execute()
        $record = $view.Fetch()
        if (-not $record) { throw 'MSI-Produktversion fehlt.' }
        ConvertTo-HGVersion $record.StringData(1)
    }
    finally {
        if ($view) { $null = $view.Close() }
        foreach ($obj in @($record, $view, $database, $installer)) {
            if ($obj) { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($obj) }
        }
    }
}

function Test-HGInstaller {
    param([string]$Path, [object]$Package)
    if ($Package.Hash) {
        if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash -ne $Package.Hash) { throw 'SHA-256-Pruefsumme stimmt nicht ueberein.' }
    }
    else {
        $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch ('(?:^|,\s*)O="?' + $Package.Signer + '"?(?:,|$)')) {
            throw 'Der Installer hat keine gueltige Signatur des erwarteten Herstellers.'
        }
    }
}

function Get-HGAdobePackage {
    param([string]$Architecture)
    if ($Architecture -eq 'x86') { throw 'Das konfigurierte Adobe-Paket erfordert ein 64-Bit-Windows.' }
    $request = @{ UseBasicParsing = $true; TimeoutSec = 60; ErrorAction = 'Stop' }
    $root = 'https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/a/Adobe/Acrobat/Reader/64-bit'
    $versions = Invoke-RestMethod -Uri $root @request
    $latest = $versions | Where-Object { $_.type -eq 'dir' -and $_.name -match '^\d+(\.\d+)+$' } |
        Sort-Object { [version]$_.name } -Descending | Select-Object -First 1
    if (-not $latest) { throw 'Keine Adobe-Reader-Version im Paketverzeichnis gefunden.' }
    $manifestUrl = "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/a/Adobe/Acrobat/Reader/64-bit/$($latest.name)/Adobe.Acrobat.Reader.64-bit.installer.yaml"
    $manifest = (Invoke-WebRequest -Uri $manifestUrl @request).Content
    $body = [regex]::Match($manifest, '(?ms)^- Architecture: x64\s*\r?\n(?<body>.*?)(?=^- Architecture:|\z)').Groups['body'].Value
    $url = [regex]::Match($body, '(?m)^\s*InstallerUrl:\s*(https://\S+)\s*$').Groups[1].Value.Trim()
    $hash = [regex]::Match($body, '(?m)^\s*InstallerSha256:\s*([A-Fa-f0-9]{64})\s*$').Groups[1].Value
    if (-not $url -or -not $hash) { throw 'Adobe-Downloadadresse oder SHA-256 fehlt im Paketmanifest.' }
    $uri = [uri]$url
    if ($uri.Scheme -ne 'https' -or $uri.Host -notmatch '^ardownload[0-9]*\.adobe\.com$') { throw 'Unerwarteter Adobe-Downloadserver.' }
    [pscustomobject]@{
        Url = $url; Version = (ConvertTo-HGVersion $latest.name); Hash = $hash; Signer = $null
        Extension = 'exe'; RelativePath = 'Adobe\Acrobat DC\Acrobat\Acrobat.exe'
    }
}

. (Join-Path $PSScriptRoot 'SoftwareStages.ps1')

