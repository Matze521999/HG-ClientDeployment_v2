#Requires -Version 5.1
<#
.SYNOPSIS
Startet das lokale Client-Deployment mit Administratorrechten.
.DESCRIPTION
Die vollstaendige Arbeitskopie muss vorliegen. main.ps1 wird aus demselben
Ordner gestartet; es werden keine Skripte aus GitHub heruntergeladen.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$mainScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'main.ps1'
if (-not (Test-Path -LiteralPath $mainScriptPath -PathType Leaf)) {
    throw "main.ps1 fehlt im Projektordner '$PSScriptRoot'. Bitte die vollstaendige Arbeitskopie verwenden."
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Fordere Administratorrechte fuer das Client-Deployment an...'
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    try {
        $process = Start-Process -FilePath $powershellPath -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
        ) -WorkingDirectory $PSScriptRoot -Verb RunAs -Wait -PassThru -ErrorAction Stop
    }
    catch {
        throw "Das Deployment konnte nicht mit Administratorrechten gestartet werden. Die UAC-Anfrage wurde moeglicherweise abgebrochen. Details: $($_.Exception.Message)"
    }
    if ($process.ExitCode -ne 0) {
        throw "Das Deployment wurde mit Exitcode $($process.ExitCode) beendet."
    }
    return
}

Write-Host "Starte das lokale Deployment: $mainScriptPath"
& $mainScriptPath
