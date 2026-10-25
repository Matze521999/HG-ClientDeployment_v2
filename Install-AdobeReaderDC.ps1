function Install-AdobeReaderDC {
    [CmdletBinding()]
    param (
        [Alias('InstallAdobeReaderDC')]
        [boolean]$InstallAdobeReader = $true
    )

    if (-not $InstallAdobeReader) {
        Write-Host 'Die Installation von Adobe Reader DC wurde nicht gewuenscht.'
        return
    }

    $installerDirectory = $null
    try {
        $installed = $false
        $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($winget) {
            Write-Host 'Starte die Installation von Adobe Reader DC mit winget...'
            & $winget.Source install -e --id Adobe.Acrobat.Reader.64-bit --silent --accept-package-agreements --accept-source-agreements
            $exitCode = $LASTEXITCODE
            # 0x8A15002B: Die installierte Version ist bereits aktuell.
            $installed = $exitCode -in @(0, 1641, 3010, -1978335189)
            if (-not $installed) {
                Write-Warning "winget ist mit Exitcode $exitCode fehlgeschlagen. Verwende den direkten Adobe-Installer."
            }
        }

        if (-not $installed) {
            Write-Host 'Lade Adobe Reader DC direkt herunter (ohne winget)...'
            # Das offizielle Microsoft-Paketverzeichnis liefert URL und SHA-256.
            $manifestRoot = 'https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/a/Adobe/Acrobat/Reader/64-bit'
            $request = @{ UseBasicParsing = $true; ErrorAction = 'Stop' }
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $versions = Invoke-RestMethod -Uri $manifestRoot @request
            $latest = $versions | Where-Object { $_.type -eq 'dir' -and $_.name -match '^\d+(\.\d+)+$' } |
                Sort-Object { [version]$_.name } -Descending | Select-Object -First 1
            if (-not $latest) { throw 'Keine Adobe-Reader-Version im Paketverzeichnis gefunden.' }
            $manifestUrl = "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/a/Adobe/Acrobat/Reader/64-bit/$($latest.name)/Adobe.Acrobat.Reader.64-bit.installer.yaml"
            $manifest = (Invoke-WebRequest -Uri $manifestUrl @request).Content
            # Nur das x64-Paket auswerten; andere Architekturen nicht versehentlich verwenden.
            $package = [regex]::Match($manifest, '(?ms)^- Architecture: x64\s*\r?\n(?<body>.*?)(?=^- Architecture:|\z)').Groups['body'].Value
            $downloadUrl = [regex]::Match($package, '(?m)^\s*InstallerUrl:\s*(https://\S+)\s*$').Groups[1].Value.Trim()
            $expectedHash = [regex]::Match($package, '(?m)^\s*InstallerSha256:\s*([A-Fa-f0-9]{64})\s*$').Groups[1].Value
            if (-not $downloadUrl -or -not $expectedHash) { throw 'Download-URL oder SHA-256 fehlt im Adobe-Paketmanifest.' }
            $uri = [uri]$downloadUrl
            if ($uri.Scheme -ne 'https' -or $uri.Host -notmatch '^ardownload[0-9]*\.adobe\.com$') {
                throw 'Das Paketmanifest verweist nicht auf einen Adobe-Downloadserver.'
            }
            if (-not [Environment]::Is64BitOperatingSystem) { throw 'Dieses Adobe-Reader-Paket erfordert ein 64-Bit-Windows.' }
            $installerDirectory = Join-Path $env:TEMP ('HG-AdobeReader-' + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $installerDirectory -ErrorAction Stop
            $installerPath = Join-Path $installerDirectory 'AdobeReader.exe'
            Invoke-WebRequest -Uri $downloadUrl -OutFile $installerPath @request
            if ((Get-FileHash -LiteralPath $installerPath -Algorithm SHA256 -ErrorAction Stop).Hash -ne $expectedHash) {
                throw 'Die SHA-256-Pruefsumme des Adobe-Installers stimmt nicht ueberein.'
            }
            $process = Start-Process -FilePath $installerPath -ArgumentList '/sAll /rs /rps /l /re' -Wait -PassThru -ErrorAction Stop
            $exitCode = $process.ExitCode
            if ($exitCode -notin @(0, 1641, 3010)) { throw "Adobe-Installation fehlgeschlagen (Exitcode $exitCode)." }
        }

        $message = 'Adobe Reader DC ist installiert bzw. bereits aktuell.'
        if ($exitCode -in @(1641, 3010)) { $message += ' Ein Neustart ist erforderlich.' }
        Write-Host $message
        "$(Get-Date) - $message" | Out-File -Append -FilePath (Join-Path $env:TEMP 'log.txt')
    }
    catch {
        Write-Error "Adobe Reader DC konnte nicht installiert werden: $($_.Exception.Message)"
    }
    finally {
        if ($installerDirectory -and (Test-Path -LiteralPath $installerDirectory)) {
            Remove-Item -LiteralPath (Join-Path $installerDirectory 'AdobeReader.exe') -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $installerDirectory -Force -ErrorAction SilentlyContinue
        }
    }
}

Install-AdobeReaderDC -InstallAdobeReader $true

