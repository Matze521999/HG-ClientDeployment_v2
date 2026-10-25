# Ablaufpruefung mit harmlosen Testskripten; keine echten Installer ausfuehren.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'lib\LatestSoftware.ps1')
. (Join-Path $root 'lib\DeploymentPipeline.ps1')
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'main.ps1'), [ref]$null, [ref]$null)
foreach ($definition in $ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] }) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Assert { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
$options = @(Get-DeploymentOptions)
Assert ($options.Count -eq 9) 'Neun Optionen erwartet'
Assert ($options[-1].Name -eq 'WindowsUpdates') 'Updates muessen zuletzt laufen'
Assert ((@($options | Where-Object Selected).Name -join ',') -eq '7Zip,AdobeReaderDC,GoogleChrome,HGFernwartung,OEMInformationen') 'Standardauswahl stimmt nicht'
Write-Host 'PASS: Reihenfolge und Standardauswahl'
$menu=@(Show-DeploymentMenu -Options $options -NoClear 6>&1 | ForEach-Object { [string]$_ })
Assert (($menu -join "`n") -match 'SUPPORT-DOWNLOADS' -and ($menu -join "`n") -match 'WINDOWS & EINRICHTUNG') 'Menuegruppen fehlen'
Assert (@($menu | Where-Object { $_ -match '^\s+\d+\s+\[[x ]\]' }).Count -eq 9) 'Menue muss neun ausgerichtete Auswahlzeilen enthalten'
Assert (@($menu | Where-Object { $_.Length -gt 80 }).Count -eq 0) 'Menue passt nicht in ein 80-Zeichen-Fenster'
Write-Host 'PASS: Menuegruppen, Auswahlzeilen und Breite'

$fixture = Join-Path $PSScriptRoot ('fixture-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixture
$fixtureNames = @('Install-First.ps1', 'Install-Fail.ps1', 'Install-Last.ps1', 'Install-Off.ps1')
try {
    '$global:DeploymentTestOrder += "First"; Write-Output "Testausgabe"' | Set-Content (Join-Path $fixture $fixtureNames[0])
    'Write-Error "Absichtlicher Testfehler"' | Set-Content (Join-Path $fixture $fixtureNames[1])
    '$global:DeploymentTestOrder += "Last"' | Set-Content (Join-Path $fixture $fixtureNames[2])
    'throw "Darf nicht gestartet werden"' | Set-Content (Join-Path $fixture $fixtureNames[3])
    $global:DeploymentTestOrder = @()
    $testOptions = @(
        [pscustomobject]@{ Name = 'First'; Label = 'Erste'; Selected = $true }
        [pscustomobject]@{ Name = 'Fail'; Label = 'Fehler'; Selected = $true }
        [pscustomobject]@{ Name = 'Missing'; Label = 'Fehlende Datei'; Selected = $true }
        [pscustomobject]@{ Name = 'Last'; Label = 'Letzte'; Selected = $true }
        [pscustomobject]@{ Name = 'Off'; Label = 'Abgewaehlt'; Selected = $false }
    )
    $results = @(Invoke-DeploymentScripts -Options $testOptions -ScriptDirectory $fixture)
    Assert ($results.Count -eq 5) 'Skriptausgabe verunreinigt Ergebnisliste'
    Assert (($results.Status -join ',') -eq 'Durchgelaufen,Fehlgeschlagen,Fehlgeschlagen,Durchgelaufen,Uebersprungen') 'Fehler-/Erfolgsstatus stimmt nicht'
    Assert (($global:DeploymentTestOrder -join ',') -eq 'First,Last') 'Weiterarbeit nach Fehler oder Reihenfolge falsch'
    Assert ($results[1].Details -match 'Absichtlicher Testfehler') 'Fehlerdetails fehlen'
    Write-Host 'PASS: Ausfuehrung, Fehlerfortsetzung, fehlende Dateien, Abwahl und getrennte Ausgabe'

    function Test-DeploymentAdministrator { $script:testAdmin }
    function Start-Transcript { param($LiteralPath, $ErrorAction) $script:transcriptStarts++; $script:capturedLogPath = $LiteralPath }
    function Stop-Transcript { $script:transcriptStops++ }
    function Show-DeploymentMenu { param($Options) }
    function Read-Host { param($Prompt) if ($script:answers.Count -eq 0) { throw "Unerwartete Abfrage: $Prompt" }; $script:answers.Dequeue() }
    function Invoke-DeploymentScripts { param($Options, $ScriptDirectory) $script:runCount++; $script:chosen = @($Options | Where-Object Selected) }
    function Run-Menu {
        param([string[]]$Answers, [bool]$Admin = $true)
        $script:answers = [Collections.Generic.Queue[string]]::new()
        foreach ($answer in $Answers) { $script:answers.Enqueue($answer) }
        $script:testAdmin = $Admin
        $script:runCount = 0; $script:transcriptStarts = 0; $script:transcriptStops = 0
        Start-ClientDeployment -ScriptDirectory $fixture -LogDirectory $fixture
        Assert ($script:answers.Count -eq 0) 'Nicht alle Eingaben verarbeitet'
        Assert ($script:transcriptStarts -eq 1 -and $script:transcriptStops -eq 1) 'Protokoll nicht korrekt geschlossen'
        Assert ($script:capturedLogPath.StartsWith($fixture)) 'Falscher Protokollpfad'
    }
    Run-Menu -Answers @('a', 'n', 'q')
    Assert ($script:runCount -eq 0) 'Alle/Keine duerfen keine Installation starten'
    Run-Menu -Answers @('q')
    Assert ($script:runCount -eq 0) 'Abbruch hat Installer gestartet'
    Run-Menu -Answers @('y', 'nein', 'q')
    Assert ($script:runCount -eq 0) 'Ohne Bestaetigung gestartet'
    Run-Menu -Answers @('0', '10', 'abc', '9', 'y', 'j', '')
    Assert ($script:runCount -eq 1) 'Bestaetigte Auswahl nicht gestartet'
    Assert ($script:chosen[-1].Name -eq 'WindowsUpdates') 'Nummer 9 wurde nicht aktiviert'
    Run-Menu -Answers @('1', '2', '3', '6', '8', 'y', 'q')
    Assert ($script:runCount -eq 0) 'Leere Auswahl gestartet'
    $script:testAdmin = $false; $script:transcriptStarts = 0
    $caught = ''
    try { Start-ClientDeployment -ScriptDirectory $fixture -LogDirectory $fixture } catch { $caught = $_.Exception.Message }
    Assert ($caught -match 'Administratorrechte') 'Adminpruefung fehlt'
    Assert ($script:transcriptStarts -eq 0) 'Sitzung ohne Admin gestartet'
    Write-Host 'PASS: Abbruch, Bestaetigung, ungueltige Eingaben, Auswahl, leere Auswahl und Adminpruefung'
}
finally {
    foreach ($name in $fixtureNames) {
        $file = Join-Path $fixture $name
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
    Remove-Item -LiteralPath $fixture -Force
    Remove-Variable -Name DeploymentTestOrder -Scope Global -ErrorAction SilentlyContinue
}


