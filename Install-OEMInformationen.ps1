function Set-OEMInformation {
    param (
        [boolean]$SetInfo = $true
    )

    if (-not $SetInfo) {
        Write-Host "Die OEM-Informationen wurden nicht gesetzt."
        return
    }

    $KeyNames = ("Manufacturer","SupportHours","SupportPhone","SupportURL","Line1","Logo")
    $KeyValues = @(
        "helpme!group - PC Help IT GmbH & Co. KG",
        "Montag bis Freitag, 08:00 - 17:00 Uhr",
        "+49 831 960 787 0",
        "http://www.helpme.de",
        "",
        "" # Logo gibts ab Win11 nicht mehr, daher nicht mehr implementiert
    )

    for ($i = 0; $i -lt $KeyNames.Count; $i++) {
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation" -Name $KeyNames[$i] -Value $KeyValues[$i]
    }

    Write-Host "Die OEM-Informationen wurden erfolgreich gesetzt."
}

Set-OEMInformation -SetOEMInformation $true
