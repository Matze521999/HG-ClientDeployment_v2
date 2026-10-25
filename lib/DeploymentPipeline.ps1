# Ein Download-Worker; der aufrufende Prozess installiert in fester Reihenfolge.
function Get-HGPipelineSoftware {
    param([string]$Name)
    switch ($Name) {
        '7Zip' { '7Zip' }; 'AdobeReaderDC' { 'AdobeReaderDC' }; 'GoogleChrome' { 'Chrome' }
        'MozillaFirefox' { 'Firefox' }; 'OpenVPN' { 'OpenVPN' }; 'HGFernwartung' { 'HGFernwartung' }; 'ServerEye' { 'ServerEye' }
    }
}

function Start-HGDownloadWorker {
    param([string]$LibraryPath, [object[]]$Plan, [string]$WorkRoot, [string]$LogPath)
    $planJson = ConvertTo-Json -InputObject @($Plan) -Depth 4 -Compress
    Start-Job -ArgumentList $LibraryPath,$WorkRoot,$LogPath,$planJson -ScriptBlock {
        param($LibraryPath,$WorkRoot,$LogPath,$PlanJson)
        $ErrorActionPreference = 'Stop'
        $env:HG_DEPLOYMENT_LOG = $LogPath
        . $LibraryPath
        $tasks = ConvertFrom-Json -InputObject $PlanJson
        foreach ($task in $tasks) {
            [pscustomobject]@{ Event = 'DownloadStart'; Index = $task.Index; Label = $task.Label }
            try {
                # Nur Download/Pruefung; niemals einen Installer im Worker starten.
                $prepared = New-HGPreparedSoftware -Software $task.Software -WorkRoot $WorkRoot 6>$null
                [pscustomobject]@{ Event = 'Ready'; Index = $task.Index; Label = $task.Label; Preparation = $prepared }
            }
            catch { [pscustomobject]@{ Event = 'Failed'; Index = $task.Index; Label = $task.Label; Error = $_.Exception.Message; Diagnostics = ($_ | Out-String) } }
        }
    }
}

function Receive-HGDownloadMessages {
    param([hashtable]$State)
    if (-not $State.Job) { return }
    foreach ($message in @(Receive-Job -Job $State.Job -ErrorAction SilentlyContinue -InformationAction SilentlyContinue)) {
        if ($message.Event -eq 'DownloadStart') { $State.DownloadLabel = $message.Label }
        elseif ($message.Event -in @('Ready','Failed')) {
            $State.Pending[[string]$message.Index] = $message
            $State.ReadyCount++
        }
    }
    $percent = if ($State.Total -gt 0) { [int](100 * $State.ReadyCount / $State.Total) } else { 100 }
    $status = if ($State.ReadyCount -eq $State.Total) { 'Alle Downloads verarbeitet' } else { "$($State.ReadyCount)/$($State.Total) bereit | $($State.DownloadLabel)" }
    Write-Progress -Id 10 -Activity 'DOWNLOADS - nacheinander im Hintergrund' -Status $status -PercentComplete $percent
}

function Invoke-HGDeploymentPipeline {
    [CmdletBinding()]
    param([object[]]$Options, [string]$ScriptDirectory)
    $ErrorActionPreference = 'Stop'
    $job = $null; $workRoot = $null
    $previousLog = $env:HG_DEPLOYMENT_LOG
    $state = @{ Job = $null; Pending = @{}; Total = 0; ReadyCount = 0; DownloadLabel = 'Wird gestartet' }
    try {
        $plan = @()
        for ($i = 0; $i -lt $Options.Count; $i++) {
            $software = Get-HGPipelineSoftware $Options[$i].Name
            $scriptPath = Join-Path $ScriptDirectory ('Install-' + $Options[$i].Name + '.ps1')
            if ($Options[$i].Selected -and $software -and (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
                $plan += [pscustomobject]@{ Index = $i; Software = $software; Label = $Options[$i].Label }
            }
        }
        if ($plan.Count -gt 0) {
            $token = [guid]::NewGuid().ToString('N')
            $workRoot = Join-Path $env:TEMP ('HG-Pipeline-' + $token)
            $null = New-Item -ItemType Directory -Path $workRoot
            $logRoot = Join-Path $env:TEMP 'HG-ClientDeployment'
            $null = New-Item -ItemType Directory -Path $logRoot -Force
            $env:HG_DEPLOYMENT_LOG = Join-Path $logRoot ("Deployment-$token-install.log")
            $downloadLog = Join-Path $logRoot ("Deployment-$token-download.log")
            Write-Host "Downloadprotokoll: $downloadLog" -ForegroundColor DarkGray
            Write-Host "Installationsprotokoll: $env:HG_DEPLOYMENT_LOG" -ForegroundColor DarkGray
            $job = Start-HGDownloadWorker -LibraryPath (Join-Path $ScriptDirectory 'lib\LatestSoftware.ps1') -Plan $plan -WorkRoot $workRoot -LogPath $downloadLog
            $state.Job = $job; $state.Total = $plan.Count
        }
        for ($i = 0; $i -lt $Options.Count; $i++) {
            $option = $Options[$i]; $status = 'Uebersprungen'; $detail = 'Nicht ausgewaehlt'; $version = ''; $reboot = $false
            $preparation = $null
            $timer = [Diagnostics.Stopwatch]::StartNew()
            if ($option.Selected) {
                try {
                    $scriptPath = Join-Path $ScriptDirectory ('Install-' + $option.Name + '.ps1')
                    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Lokales Skript fehlt: $scriptPath. Bitte die Arbeitskopie vervollstaendigen." }
                    if (Get-HGPipelineSoftware $option.Name) {
                        while (-not $state.Pending.ContainsKey([string]$i)) {
                            Receive-HGDownloadMessages $state
                            if ($state.Pending.ContainsKey([string]$i)) { break }
                            if ($job.State -in @('Completed','Failed','Stopped')) { throw "Download-Worker beendet, aber $($option.Label) nicht bereit: $($job.ChildJobs[0].JobStateInfo.Reason)" }
                            Write-Progress -Id 20 -Activity 'INSTALLATION - jeweils ein Programm' -Status "Warte auf Download: $($option.Label)"
                            Start-Sleep -Milliseconds 100
                        }
                        $message = $state.Pending[[string]$i]
                        $state.Pending.Remove([string]$i)
                        if ($message.Event -eq 'Failed') { Write-Verbose $message.Diagnostics; throw $message.Error }
                        $preparation = $message.Preparation
                        Write-Host "`n  > $($option.Label)" -ForegroundColor Cyan
                        Write-Progress -Id 20 -Activity 'INSTALLATION - jeweils ein Programm' -Status $option.Label
                        $onWaiting = { Receive-HGDownloadMessages $state }
                        $result = Complete-HGPreparedSoftware -Preparation $preparation -OnWaiting $onWaiting
                        $status = $result.Status; $version = [string]$result.Version; $reboot = $result.RebootRequired
                        $detail = if ($result.Details) { $result.Details } else { "Version: $version; Neustart erforderlich: $reboot" }
                    }
                    else {
                        Write-Host "`n  > $($option.Label)" -ForegroundColor Cyan
                        & $scriptPath | Out-Host
                        $status = 'Durchgelaufen'; $detail = 'Skript ohne gemeldeten Fehler beendet.'
                    }
                    Write-Host "    $status $version" -ForegroundColor Green
                }
                catch {
                    $status = 'Fehlgeschlagen'; $detail = $_.Exception.Message
                    Write-Verbose ($_ | Out-String)
                    Write-Host "    Fehler: $detail" -ForegroundColor Red
                }
                finally {
                    if ($preparation) { Remove-HGPreparedSoftware $preparation }
                    Receive-HGDownloadMessages $state
                }
            }
            $timer.Stop()
            [pscustomobject]@{ Aufgabe = $option.Label; Status = $status; Version = $version; Sekunden = [math]::Round($timer.Elapsed.TotalSeconds,1); Details = $detail; RebootRequired = $reboot }
        }
    }
    finally {
        if ($job) {
            if ($job.State -notin @('Completed','Failed','Stopped')) { Stop-Job -Job $job }
            Remove-Job -Job $job -Force
        }
        Write-Progress -Id 10 -Activity 'Downloads' -Completed
        Write-Progress -Id 20 -Activity 'Installation' -Completed
        $env:HG_DEPLOYMENT_LOG = $previousLog
        if ($workRoot -and (Test-Path -LiteralPath $workRoot)) {
            # Nur den fuer diese Sitzung erzeugten Tempordner rekursiv entfernen.
            $resolved = [IO.Path]::GetFullPath($workRoot)
            $allowed = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
            if (-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^HG-Pipeline-[a-f0-9]{32}$') { throw 'Ungueltiger temporaerer Pipeline-Pfad.' }
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}



