# Isolierte Ablaufpruefung; installiert keine Updates und startet keine Dienste.
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Install-WindowsUpdates.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
foreach ($definition in $ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] }) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Test-WindowsUpdateAdministrator { $script:isAdmin }
function Start-Service { $script:serviceStarted = $true }
function Add-Content { param($LiteralPath, $Value, $ErrorAction) $script:messages.Add($Value) }
function New-Object {
    param($ComObject, $ErrorAction)
    switch ($ComObject) {
        'Microsoft.Update.SystemInfo' { return $script:systemInfo }
        'Microsoft.Update.Session' { return $script:session }
        'Microsoft.Update.UpdateColl' { return ,([Collections.ArrayList]::new()) }
        default { throw "Unerwartetes COM-Objekt: $ComObject" }
    }
}
function Run-Scenario {
    param([string]$Name, [int]$UpdateCount = 1, [int]$DownloadCode = 2, [int]$InstallCode = 2,
          [bool]$PendingReboot = $false, [bool]$ResultReboot = $false, [bool]$Admin = $true,
          [bool]$Interactive = $false, [int]$SearchCode = 2, [string]$ExpectedError = '')
    $script:isAdmin = $Admin
    $script:serviceStarted = $false
    $script:installCalls = 0
    $script:messages = [Collections.Generic.List[string]]::new()
    $script:downloadCode = $DownloadCode
    $script:installCode = $InstallCode
    $script:resultReboot = $ResultReboot
    $script:systemInfo = [pscustomobject]@{ RebootRequired = $PendingReboot }
    $script:update = [pscustomobject]@{ Title = 'Testupdate'; IsDownloaded = $false; EulaAccepted = $false; InstallationBehavior = @{ CanRequestUserInput = $Interactive } }
    $script:update | Add-Member ScriptMethod AcceptEula { $this.EulaAccepted = $true }
    $updates = [Collections.ArrayList]::new()
    for ($i = 0; $i -lt $UpdateCount; $i++) { $null = $updates.Add($script:update) }
    $script:search = [pscustomobject]@{ Updates = $updates; ResultCode = $SearchCode }
    $script:session = [pscustomobject]@{ ClientApplicationID = '' }
    $script:session | Add-Member ScriptMethod CreateUpdateSearcher {
        $obj = [pscustomobject]@{}
        $obj | Add-Member ScriptMethod Search { param($criteria) if ($criteria -notmatch "IsInstalled=0") { throw 'Suchfilter fehlt' }; return $script:search }
        return $obj
    }
    $script:session | Add-Member ScriptMethod CreateUpdateDownloader {
        $obj = [pscustomobject]@{ Updates = $null }
        $obj | Add-Member ScriptMethod Download {
            $script:update.IsDownloaded = ($script:downloadCode -eq 2)
            $result = [pscustomobject]@{ ResultCode = $script:downloadCode }
            $result | Add-Member ScriptMethod GetUpdateResult { param($index) return @{ HResult = -1 } }
            return $result
        }
        return $obj
    }
    $script:session | Add-Member ScriptMethod CreateUpdateInstaller {
        $obj = [pscustomobject]@{ Updates = $null; RebootRequiredBeforeInstallation = $false; AllowSourcePrompts = $true }
        $obj | Add-Member ScriptMethod Install {
            $script:installCalls++
            $result = [pscustomobject]@{ ResultCode = $script:installCode; RebootRequired = $script:resultReboot }
            $result | Add-Member ScriptMethod GetUpdateResult { param($index) return @{ ResultCode = $script:installCode; HResult = -1 } }
            return $result
        }
        return $obj
    }
    $caught = ''
    try { Install-WindowsUpdates -ErrorAction Stop } catch { $caught = $_.Exception.Message }
    if ($ExpectedError) {
        if ($caught -notmatch $ExpectedError) { throw "$Name : Erwarteter Fehler fehlt: $caught" }
    } elseif ($caught) { throw "$Name : $caught" }
    if (($PendingReboot -or -not $Admin -or $Interactive -or $UpdateCount -eq 0 -or $DownloadCode -ne 2 -or $SearchCode -ne 2) -and $script:installCalls -ne 0) { throw "$Name : Unerwartete Installation" }
    if ($Name -eq 'Erfolg' -and ($script:installCalls -ne 1 -or -not $script:update.EulaAccepted)) { throw 'Installation oder EULA-Behandlung fehlt' }
    if ($ResultReboot -and ($script:installCalls -ne 1 -or -not ($script:messages -match 'Neustart erforderlich'))) { throw 'Neustart wird nicht korrekt behandelt' }
    if (-not $Admin -and $script:serviceStarted) { throw 'Dienst ohne Adminrechte gestartet' }
    Write-Host "PASS: $Name"
}
Run-Scenario -Name 'Erfolg'
Run-Scenario -Name 'Keine Updates' -UpdateCount 0
Run-Scenario -Name 'Neustart steht aus' -PendingReboot $true
Run-Scenario -Name 'Nach Installation stoppen' -UpdateCount 2 -ResultReboot $true
Run-Scenario -Name 'Downloadfehler' -DownloadCode 4 -ExpectedError '1 Update'
Run-Scenario -Name 'Installationsfehler' -InstallCode 4 -ExpectedError '1 Update'
Run-Scenario -Name 'Teilweise Suche' -SearchCode 3 -ExpectedError 'Updatesuche'
Run-Scenario -Name 'Fehlende Adminrechte' -Admin $false -ExpectedError 'Administrator'
Run-Scenario -Name 'Interaktive Updates' -Interactive $true
