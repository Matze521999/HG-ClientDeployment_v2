# Bootstrap mit lokalen ZIP-Testdaten pruefen; kein Netzwerk und keine Installer.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'deploy_client.ps1'),[ref]$null,[ref]$null)
foreach($definition in $ast.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst]}){. ([scriptblock]::Create($definition.Extent.Text))}
function Assert {param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}
$fixture=Join-Path $PSScriptRoot ('bootstrap-fixture-'+[guid]::NewGuid().ToString('N'))
$project=Join-Path $fixture 'repo'
$single=Join-Path $fixture 'only launcher'
$null=New-Item -ItemType Directory -Path (Join-Path $project 'lib') -Force
$null=New-Item -ItemType Directory -Path $single
$savedTemp=$env:TEMP;$env:TEMP=$fixture
$script:admin=$true;$script:downloads=0;$script:downloadFails=$false;$script:uacFails=$false;$script:childCode=0
function Test-HGBootstrapAdministrator {$script:admin}
function Invoke-WebRequest {
 param($Uri,$OutFile,[switch]$UseBasicParsing,$TimeoutSec,$ErrorAction)
 $script:downloads++
 if($script:downloadFails){throw 'Test-Netzwerkfehler'}
 Assert ($Uri -eq 'https://codeload.github.com/Matze521999/HG-ClientDeployment_v2/zip/refs/heads/main') 'Falsches Repository'
 Copy-Item -LiteralPath $script:downloadFixture -Destination $OutFile
}
function Start-Sleep {param($Seconds)}
function Start-Process {
 param($FilePath,$ArgumentList,$WorkingDirectory,$Verb,[switch]$Wait,[switch]$PassThru,$ErrorAction)
 $script:uacArguments=$ArgumentList;$script:uacDirectory=$WorkingDirectory
 if($script:uacFails){throw 'Test-UAC-Abbruch'}
 @{ExitCode=$script:childCode}
}
$global:HGBootstrapTestRuns=0
try {
 $required=@('main.ps1','Install-7Zip.ps1','Install-AdobeReaderDC.ps1','Install-GoogleChrome.ps1','Install-MozillaFirefox.ps1','Install-OpenVPN.ps1','Install-HGFernwartung.ps1','Install-ServerEye.ps1','Install-OEMInformationen.ps1','Install-WindowsUpdates.ps1','lib\LatestSoftware.ps1','lib\SoftwareInventory.ps1','lib\SoftwareStages.ps1','lib\DeploymentPipeline.ps1')
 foreach($file in $required){Set-Content -LiteralPath (Join-Path $project $file) -Value '# Testdatei'}
 Set-Content -LiteralPath (Join-Path $project 'main.ps1') -Value '$global:HGBootstrapTestRuns++'
 $launcher=Join-Path $single 'deploy_client.ps1'
 Copy-Item (Join-Path $root 'deploy_client.ps1') $launcher
 $script:downloadFixture=Join-Path $fixture 'valid.zip'
 Compress-Archive -LiteralPath $project -DestinationPath $script:downloadFixture
 Invoke-HGClientBootstrap -SourceRoot $single -LauncherPath $launcher
 Assert ($global:HGBootstrapTestRuns -eq 1 -and $script:downloads -eq 1) 'Einzelner Starter muss das Archiv laden und das entpackte Menue starten'
 Assert (@(Get-ChildItem $fixture -Directory | Where-Object Name -like 'HG-Bootstrap-*').Count -eq 0) 'Bootstrap-Tempordner nicht entfernt'
 Assert ((Test-Path $launcher) -and -not (Test-Path (Join-Path $single 'main.ps1'))) 'Launcher oder Downloads-Ordner wurde veraendert'
 Write-Host 'PASS: Einzeldatei startet vollstaendiges Download-Deployment und raeumt auf'

 Invoke-HGClientBootstrap -UseLocal -SourceRoot $project -LauncherPath $launcher
 Assert ($global:HGBootstrapTestRuns -eq 2 -and $script:downloads -eq 1) 'Lokaler Modus darf nichts herunterladen'
 $caught='';try{Invoke-HGClientBootstrap -UseLocal -SourceRoot $single -LauncherPath $launcher}catch{$caught=$_.Exception.Message}
 Assert ($caught -match 'Deployment-Dateien fehlen') 'Unvollstaendige lokale Arbeitskopie muss klar abgewiesen werden'
 Write-Host 'PASS: Lokaler Modus und fehlende Dateien'

 $script:downloadFails=$true;$caught=''
 try{Invoke-HGClientBootstrap -SourceRoot $single -LauncherPath $launcher}catch{$caught=$_.Exception.Message}
 Assert ($caught -match 'GitHub-Repository konnte nicht heruntergeladen' -and $script:downloads -eq 4) 'Downloadfehler oder Wiederholungen nicht korrekt'
 Assert (@(Get-ChildItem $fixture -Directory | Where-Object Name -like 'HG-Bootstrap-*').Count -eq 0) 'Downloadfehler hinterlaesst Tempordner'
 $script:downloadFails=$false
 Write-Host 'PASS: Downloadfehler, Wiederholungen und Fehlerbereinigung'

 $badArchive=Join-Path $fixture 'bad.zip'
 Set-Content $badArchive 'Kein ZIP'
 $script:downloadFixture=$badArchive;$caught=''
 try{Invoke-HGClientBootstrap -SourceRoot $single -LauncherPath $launcher}catch{$caught=$_.Exception.Message}
 Assert ([bool]$caught -and $global:HGBootstrapTestRuns -eq 2) 'Ungueltiges Archiv darf kein Menue starten'
 Assert (@(Get-ChildItem $fixture -Directory | Where-Object Name -like 'HG-Bootstrap-*').Count -eq 0) 'Ungueltiges ZIP hinterlaesst Tempordner'

 Add-Type -AssemblyName System.IO.Compression.FileSystem
 $slip=Join-Path $fixture 'slip.zip'
 $zip=[IO.Compression.ZipFile]::Open($slip,[IO.Compression.ZipArchiveMode]::Create)
 $entry=$zip.CreateEntry('../outside.txt');$writer=[IO.StreamWriter]::new($entry.Open());$writer.Write('Test');$writer.Dispose();$zip.Dispose()
 $caught='';try{Expand-HGDeploymentArchive $slip (Join-Path $fixture 'extract')}catch{$caught=$_.Exception.Message}
 Assert ($caught -match 'ausserhalb' -and -not (Test-Path (Join-Path $fixture 'outside.txt'))) 'ZIP-Pfadpruefung fehlt'
 Write-Host 'PASS: Ungueltige Archive und Pfade ausserhalb des Zielordners'

 $script:admin=$false
 Invoke-HGClientBootstrap -UseLocal -SourceRoot $project -LauncherPath $launcher
 Assert (($script:uacArguments -join ' ') -match '-UseLocal' -and ($script:uacArguments -join ' ').Contains('"'+$launcher+'"')) 'UAC muss lokale Option und Pfad mit Leerzeichen weitergeben'
 Assert ($global:HGBootstrapTestRuns -eq 2) 'UAC-Elternprozess darf das Deployment nicht zusaetzlich starten'
 $script:uacFails=$true;$caught=''
 try{Invoke-HGClientBootstrap -SourceRoot $single -LauncherPath $launcher}catch{$caught=$_.Exception.Message}
 Assert ($caught -match 'UAC-Anfrage') 'UAC-Abbruch braucht eine klare Meldung'
 $script:uacFails=$false;$script:childCode=1;$caught=''
 try{Invoke-HGClientBootstrap -SourceRoot $single -LauncherPath $launcher}catch{$caught=$_.Exception.Message}
 Assert ($caught -match 'Exitcode 1') 'Fehler des erhoehten Prozesses muss weitergegeben werden'
 Write-Host 'PASS: UAC, Leerzeichen im Dateipfad, Abbruch und Kindprozess-Exitcode'
}
finally {
 $env:TEMP=$savedTemp
 Remove-Variable HGBootstrapTestRuns -Scope Global -ErrorAction SilentlyContinue
 $resolved=[IO.Path]::GetFullPath($fixture);$allowed=[IO.Path]::GetFullPath($PSScriptRoot)+'\'
 if(-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)){throw 'Ungueltiger Testpfad'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}

