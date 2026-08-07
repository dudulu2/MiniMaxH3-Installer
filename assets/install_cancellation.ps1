$script:CancelRequested = $false
$script:ActiveInstallerProcess = $null
$script:ActiveInstallerProcessProtected = $false
$script:ActiveInstallerProcessLabel = ""
$script:btnStopInstall = $null

function New-InstallCancelledException {
    return (New-Object System.OperationCanceledException -ArgumentList "Installation stopped by user.")
}

function Assert-InstallNotCancelled {
    if ($script:CancelRequested) {
        throw (New-InstallCancelledException)
    }
}

function Set-ActiveInstallerProcess {
    param(
        $Process,
        [string]$Label,
        [bool]$Protected = $false
    )
    $script:ActiveInstallerProcess = $Process
    $script:ActiveInstallerProcessProtected = $Protected
    $script:ActiveInstallerProcessLabel = $Label
}

function Clear-ActiveInstallerProcess {
    param($Process)
    try {
        if ($script:ActiveInstallerProcess -and $Process -and $script:ActiveInstallerProcess.Id -eq $Process.Id) {
            $script:ActiveInstallerProcess = $null
            $script:ActiveInstallerProcessProtected = $false
            $script:ActiveInstallerProcessLabel = ""
        }
    } catch {
        $script:ActiveInstallerProcess = $null
        $script:ActiveInstallerProcessProtected = $false
        $script:ActiveInstallerProcessLabel = ""
    }
}

function Stop-ActiveInstallerProcess {
    $process = $script:ActiveInstallerProcess
    if (-not $process) { return }

    try {
        if ($process.HasExited) { return }
    } catch { return }

    if ($script:ActiveInstallerProcessProtected) {
        try { Add-Log "Stop requested. Waiting for the current protected setup step to finish safely: $($script:ActiveInstallerProcessLabel)" "WARN" } catch { }
        return
    }

    try {
        $pid = [int]$process.Id
        Add-Log "Stopping current installer process tree (PID $pid): $($script:ActiveInstallerProcessLabel)" "WARN"
        & taskkill.exe /PID $pid /T /F *> $null
    } catch {
        try { $process.Kill() } catch { }
    }
}

function Request-InstallCancellation {
    if (-not $script:IsInstalling -or $script:CancelRequested) { return }

    $answer = [Windows.Forms.MessageBox]::Show(
        "Stop the installation now?`n`nModel download parts already written to disk will be kept and can resume on the next Install / Repair.`n`nIf a protected Python setup step is running, the installer will stop immediately after that short step finishes.",
        "Stop installation",
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }

    $script:CancelRequested = $true
    if ($script:btnStopInstall) {
        $script:btnStopInstall.Enabled = $false
        $script:btnStopInstall.Text = "Stopping..."
    }
    if ($lblStage) { $lblStage.Text = "Stopping installation..." }
    if ($progress) { $progress.Style = [Windows.Forms.ProgressBarStyle]::Marquee }
    try { Add-Log "User requested installation stop. Existing files and resumable model parts will be kept." "WARN" } catch { }
    Stop-ActiveInstallerProcess
}

function Begin-InstallCancellationUI {
    $script:CancelRequested = $false
    $script:ActiveInstallerProcess = $null
    $script:ActiveInstallerProcessProtected = $false
    $script:ActiveInstallerProcessLabel = ""
    if ($script:btnStopInstall) {
        $script:btnStopInstall.Text = "Stop installation"
        $script:btnStopInstall.Enabled = $true
    }
}

function Complete-InstallCancellationUI {
    if ($script:btnStopInstall) {
        $script:btnStopInstall.Text = "Stop installation"
        $script:btnStopInstall.Enabled = $false
    }
    $script:ActiveInstallerProcess = $null
    $script:ActiveInstallerProcessProtected = $false
    $script:ActiveInstallerProcessLabel = ""
    if ($form) { $form.ControlBox = $true }
}

function Initialize-InstallCancellationUI {
    if ($script:btnStopInstall) { return }

    $script:btnStopInstall = New-Object Windows.Forms.Button
    $script:btnStopInstall.Text = "Stop installation"
    $script:btnStopInstall.Location = New-Object Drawing.Point(212, 451)
    $script:btnStopInstall.Size = New-Object Drawing.Size(145, 40)
    $script:btnStopInstall.Enabled = $false
    $script:btnStopInstall.BackColor = [Drawing.Color]::FromArgb(184, 55, 55)
    $script:btnStopInstall.ForeColor = [Drawing.Color]::White
    $script:btnStopInstall.FlatStyle = "Flat"
    $script:btnStopInstall.Add_Click({ Request-InstallCancellation })
    $form.Controls.Add($script:btnStopInstall)
    $script:btnStopInstall.BringToFront()

    $btnLaunch.Location = New-Object Drawing.Point(369, 451)
    $lblStage.Location = New-Object Drawing.Point(560, 463)
}

# Cancellation-aware replacement for the installer's generic subprocess runner.
# Long pip/PyTorch/model-helper processes can be terminated immediately. The
# standalone Python installer and venv creation are treated as protected atomic
# steps and are allowed to finish before cancellation is raised.
function Invoke-ProcessChecked {
    param(
        [string]$FilePath,
        [string]$Arguments,
        [string]$WorkingDirectory = $script:InstallerRoot,
        [switch]$AllowFailure
    )

    Assert-InstallNotCancelled
    Add-Log ("Run: {0} {1}" -f $FilePath, $Arguments)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    if (-not $process.Start()) { throw "Could not start: $FilePath" }

    $protected = ([IO.Path]::GetFileName($FilePath) -match '(?i)^python-3\.10\.11-amd64\.exe$') -or ($Arguments -match '(?i)(^|\s)-m\s+venv(\s|$)')
    $label = if ($protected) { "protected setup step" } else { [IO.Path]::GetFileName($FilePath) }
    Set-ActiveInstallerProcess -Process $process -Label $label -Protected $protected

    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    try {
        while (-not $process.WaitForExit(250)) {
            Pump-UI
            if ($script:CancelRequested -and -not $protected) {
                Stop-ActiveInstallerProcess
            }
        }

        if ($script:CancelRequested) {
            throw (New-InstallCancelledException)
        }

        $outText = $stdout.Result
        $errText = $stderr.Result
        if ($outText) {
            foreach ($line in ($outText -split "`r?`n")) { if ($line.Trim()) { Add-Log $line.Trim() "CMD" } }
        }
        if ($errText) {
            foreach ($line in ($errText -split "`r?`n")) { if ($line.Trim()) { Add-Log $line.Trim() "CMD" } }
        }
        if ($process.ExitCode -ne 0 -and -not $AllowFailure) {
            throw "Command failed with exit code $($process.ExitCode): $FilePath"
        }
        if ($AllowFailure) { return [int]$process.ExitCode }
    } finally {
        Clear-ActiveInstallerProcess -Process $process
    }
}

# Small bootstrap downloads (for example the Python installer) also remain
# cancellable. A cancelled bootstrap file may be incomplete; the next run opens
# it with FileMode.Create and downloads it again from the beginning.
function Invoke-SimpleDownload {
    param([string]$Name, [string[]]$Urls, [string]$Destination)

    Assert-InstallNotCancelled
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    $lastError = $null
    foreach ($url in $Urls) {
        Assert-InstallNotCancelled
        $client = New-HttpClient
        try {
            Add-Log "Downloading $Name from $url"
            $responseTask = $client.GetAsync($url, [Net.Http.HttpCompletionOption]::ResponseHeadersRead)
            while (-not $responseTask.Wait(200)) {
                Pump-UI
                Assert-InstallNotCancelled
            }
            $response = $responseTask.Result
            [void]$response.EnsureSuccessStatusCode()
            $input = $response.Content.ReadAsStreamAsync().Result
            $output = New-Object IO.FileStream($Destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $buffer = New-Object byte[] (1MB)
                $total = [int64]0
                $length = $response.Content.Headers.ContentLength
                while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    Assert-InstallNotCancelled
                    $output.Write($buffer, 0, $read)
                    $total += $read
                    if ($length -and $length -gt 0) {
                        Set-Stage ("Downloading {0}: {1:N1}/{2:N1} MiB" -f $Name, ($total/1MB), ($length/1MB)) ([int](100*$total/$length))
                    } else {
                        Pump-UI
                    }
                }
            } finally {
                if ($output) { $output.Dispose() }
                if ($input) { $input.Dispose() }
                if ($response) { $response.Dispose() }
            }
            Assert-InstallNotCancelled
            Add-Log "$Name downloaded."
            return
        } catch {
            if ($script:CancelRequested -or $_.Exception -is [System.OperationCanceledException]) { throw }
            $lastError = $_.Exception
            Add-Log ("Source failed: {0}" -f $_.Exception.Message) "WARN"
        } finally {
            $client.Dispose()
        }
    }
    throw "All download sources failed for $Name. Last error: $($lastError.Message)"
}

# Cancellation-aware copy of the hardware-profile model downloader. It keeps the
# existing Python downloader format and therefore preserves its resumable part
# files exactly as before.
function Install-H3Models {
    param([string]$ComfyRoot, [string]$Python, [string]$InstallRoot, $Profile)

    Assert-InstallNotCancelled
    $downloader = Join-Path $script:AssetsRoot "download_models.py"
    if (-not (Test-Path -LiteralPath $downloader)) { throw "Installer asset is missing: $downloader" }
    $statusPath = Join-Path $InstallRoot "downloads\model-progress.json"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $statusPath) | Out-Null
    Remove-Item -LiteralPath $statusPath -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath (Split-Path -Parent $statusPath) -Filter "model-progress.json*.tmp" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $sourceOrder = if (Test-ChinaMirrorPriority) { "mirror-first" } else { "official-first" }
    $downloadMode = Get-ModelDownloadMode
    Add-Log "Model download route: $sourceOrder"
    Add-Log "Model download mode: $downloadMode"

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Python
    $psi.Arguments = "`"$downloader`" --comfy-root `"$ComfyRoot`" --status `"$statusPath`" --catalog `"$script:CatalogPath`" --profiles `"$script:ProfilesPath`" --profile `"$($Profile.id)`" --source-order $sourceOrder --download-mode $downloadMode"
    $psi.WorkingDirectory = $InstallRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    if (-not $process.Start()) { throw "Could not start the model downloader." }
    Set-ActiveInstallerProcess -Process $process -Label "MiniMax H3 model downloader" -Protected $false

    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $lastRouteSummary = ""
    try {
        while (-not $process.WaitForExit(500)) {
            Pump-UI
            if ($script:CancelRequested) {
                Stop-ActiveInstallerProcess
                continue
            }

            if (Test-Path -LiteralPath $statusPath) {
                try {
                    $state = Read-SharedJsonFile -Path $statusPath
                    if (-not $state) { continue }
                    $overall = if ($state.total_bytes -gt 0) { [int](100 * $state.completed_bytes / $state.total_bytes) } else { 0 }
                    if ($state.phase -eq "verify") {
                        $label = "Verifying $($state.name)"
                    } elseif ($state.phase -eq "merge") {
                        $label = "Merging downloaded parts: $($state.name)"
                    } else {
                        $details = @()
                        if ($state.PSObject.Properties["source"] -and $state.source) { $details += [string]$state.source }
                        if ($state.PSObject.Properties["connections"] -and [int]$state.connections -gt 0) { $details += ("{0} conn" -f [int]$state.connections) }
                        if ($state.PSObject.Properties["speed_bps"] -and [double]$state.speed_bps -gt 0) { $details += (Format-DownloadSpeed ([double]$state.speed_bps)) }
                        if ($state.PSObject.Properties["eta_seconds"]) { $details += (Format-DownloadEta ([int64]$state.eta_seconds)) }
                        $suffix = if ($details.Count -gt 0) { " | " + ($details -join " | ") } else { "" }
                        $label = "Model $($state.index)/$($state.count): $($state.name) - $([Math]::Round($state.file_bytes/1GB, 2))/$([Math]::Round($state.file_size/1GB, 2)) GiB$suffix"
                        $routeSummary = "{0}|{1}|{2}" -f $state.source, $state.connections, $state.download_mode
                        if ($state.source -and $routeSummary -ne $lastRouteSummary) {
                            Add-Log ("Active model source: {0}; connections: {1}; mode: {2}" -f $state.source, $state.connections, $state.download_mode) "MODEL"
                            $lastRouteSummary = $routeSummary
                        }
                    }
                    Set-Stage $label $overall
                } catch {
                    if ($script:CancelRequested) { throw (New-InstallCancelledException) }
                    Pump-UI
                }
            }
        }

        if ($script:CancelRequested) {
            throw (New-InstallCancelledException)
        }

        $outText = $stdout.Result
        $errText = $stderr.Result
        foreach ($line in (($outText + "`n" + $errText) -split "`r?`n")) {
            if ($line.Trim()) { Add-Log $line.Trim() "MODEL" }
        }
        if ($process.ExitCode -ne 0) { throw "Model downloader failed with exit code $($process.ExitCode). See the installer log." }
    } finally {
        Clear-ActiveInstallerProcess -Process $process
    }
}
