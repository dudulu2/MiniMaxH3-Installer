from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"missing patch anchor: {label}")
    return text.replace(old, new, 1)


core_path = Path("assets/hardware_profiles_core.ps1")
core = core_path.read_text(encoding="utf-8-sig")

core = replace_once(
    core,
    '$script:chkChinaMirror = $null\n',
    '''$script:chkChinaMirror = $null
$script:DownloadModeLabel = $null
$script:DownloadModeCombo = $null

function Get-ModelDownloadMode {
    try {
        if ($script:DownloadModeCombo -and $script:DownloadModeCombo.SelectedItem) {
            $property = $script:DownloadModeCombo.SelectedItem.PSObject.Properties["Id"]
            if ($property) {
                $value = [string]$property.Value
                if ($value -in @("auto", "stable", "accelerated")) { return $value }
            }
        }
    } catch { }
    return "auto"
}

function Get-ModelDownloadModeLabel {
    switch (Get-ModelDownloadMode) {
        "stable" { return "Stable - 1 connection" }
        "accelerated" { return "Accelerated - up to 4 connections" }
        default { return "Auto - up to 4 connections" }
    }
}
''',
    "download mode state",
)

mode_ui = '''    if (-not $script:DownloadModeCombo) {
        $script:DownloadModeLabel = New-Object Windows.Forms.Label
        $script:DownloadModeLabel.Text = "Model download:"
        $script:DownloadModeLabel.AutoSize = $true
        $script:DownloadModeLabel.Location = New-Object Drawing.Point(500, 421)
        $script:DownloadModeLabel.Anchor = "Top,Right"
        $form.Controls.Add($script:DownloadModeLabel)

        $script:DownloadModeCombo = New-Object Windows.Forms.ComboBox
        $script:DownloadModeCombo.DropDownStyle = "DropDownList"
        $script:DownloadModeCombo.DisplayMember = "Label"
        $script:DownloadModeCombo.Location = New-Object Drawing.Point(615, 415)
        $script:DownloadModeCombo.Size = New-Object Drawing.Size(285, 28)
        $script:DownloadModeCombo.Anchor = "Top,Right"
        [void]$script:DownloadModeCombo.Items.Add([PSCustomObject]@{ Id="auto"; Label="Auto (recommended, max 4 connections)" })
        [void]$script:DownloadModeCombo.Items.Add([PSCustomObject]@{ Id="stable"; Label="Stable (1 connection)" })
        [void]$script:DownloadModeCombo.Items.Add([PSCustomObject]@{ Id="accelerated"; Label="Accelerated (4 connections)" })
        $script:DownloadModeCombo.SelectedIndex = 0
        $script:DownloadModeCombo.Add_SelectedIndexChanged({ Show-HardwareReport | Out-Null })
        $form.Controls.Add($script:DownloadModeCombo)
        $script:DownloadModeLabel.BringToFront()
        $script:DownloadModeCombo.BringToFront()
    }
'''
core = replace_once(
    core,
    '    if (-not $script:ProfileButton) {\n',
    mode_ui + '    if (-not $script:ProfileButton) {\n',
    "download mode UI",
)

core = replace_once(
    core,
    '    & $add "Download route" (Get-DownloadRouteLabel) "PASS" $routeDetail\n',
    '''    & $add "Download route" (Get-DownloadRouteLabel) "PASS" $routeDetail
    $modeDetail = switch (Get-ModelDownloadMode) {
        "stable" { "Uses one resumable connection for maximum compatibility." }
        "accelerated" { "Uses four independent range parts and automatically falls back to two or one connection after repeated failures." }
        default { "Automatically uses up to four independent range parts, switches slow sources, and falls back to safer connection counts." }
    }
    & $add "Model download" (Get-ModelDownloadModeLabel) "PASS" $modeDetail
''',
    "download mode report",
)

core = replace_once(
    core,
    '        ChinaMirrorPriority = (Test-ChinaMirrorPriority)\n',
    '        ChinaMirrorPriority = (Test-ChinaMirrorPriority)\n        DownloadMode = (Get-ModelDownloadMode)\n',
    "download mode result",
)
core_path.write_text(core, encoding="utf-8")


install_path = Path("assets/hardware_profiles_install.ps1")
install = install_path.read_text(encoding="utf-8-sig")

helpers = '''function Format-DownloadSpeed {
    param([double]$BytesPerSecond)
    if ($BytesPerSecond -ge 1MB) { return ("{0:N2} MB/s" -f ($BytesPerSecond / 1MB)) }
    if ($BytesPerSecond -ge 1KB) { return ("{0:N0} KB/s" -f ($BytesPerSecond / 1KB)) }
    return "0 KB/s"
}

function Format-DownloadEta {
    param([int64]$Seconds)
    if ($Seconds -lt 0) { return "ETA --" }
    if ($Seconds -ge 3600) {
        $hours = [Math]::Floor($Seconds / 3600)
        $minutes = [Math]::Floor(($Seconds % 3600) / 60)
        return ("ETA {0}h {1}m" -f $hours, $minutes)
    }
    if ($Seconds -ge 60) { return ("ETA {0}m" -f [Math]::Ceiling($Seconds / 60)) }
    return ("ETA {0}s" -f $Seconds)
}

'''
install = replace_once(
    install,
    'function Install-H3Models {\n',
    helpers + 'function Install-H3Models {\n',
    "download status helpers",
)

install = replace_once(
    install,
    '''    $sourceOrder = if (Test-ChinaMirrorPriority) { "mirror-first" } else { "official-first" }
    Add-Log "Model download route: $sourceOrder"
''',
    '''    $sourceOrder = if (Test-ChinaMirrorPriority) { "mirror-first" } else { "official-first" }
    $downloadMode = Get-ModelDownloadMode
    Add-Log "Model download route: $sourceOrder"
    Add-Log "Model download mode: $downloadMode"
''',
    "download mode arguments",
)

old_args = '$psi.Arguments = "`"$downloader`" --comfy-root `"$ComfyRoot`" --status `"$statusPath`" --catalog `"$script:CatalogPath`" --profiles `"$script:ProfilesPath`" --profile `"$($Profile.id)`" --source-order $sourceOrder"'
new_args = '$psi.Arguments = "`"$downloader`" --comfy-root `"$ComfyRoot`" --status `"$statusPath`" --catalog `"$script:CatalogPath`" --profiles `"$script:ProfilesPath`" --profile `"$($Profile.id)`" --source-order $sourceOrder --download-mode $downloadMode"'
install = replace_once(install, old_args, new_args, "downloader command line")

old_loop = '''    while (-not $process.WaitForExit(500)) {
        if (Test-Path -LiteralPath $statusPath) {
            try {
                $state = Read-SharedJsonFile -Path $statusPath
                $overall = if ($state.total_bytes -gt 0) { [int](100 * $state.completed_bytes / $state.total_bytes) } else { 0 }
                $label = if ($state.phase -eq "verify") {
                    "Verifying $($state.name)"
                } else {
                    "Model $($state.index)/$($state.count): $($state.name) - $([Math]::Round($state.file_bytes/1GB, 2))/$([Math]::Round($state.file_size/1GB, 2)) GiB"
                }
                Set-Stage $label $overall
            } catch { Pump-UI }
        } else { Pump-UI }
    }
'''
new_loop = '''    $lastRouteSummary = ""
    while (-not $process.WaitForExit(500)) {
        if (Test-Path -LiteralPath $statusPath) {
            try {
                $state = Read-SharedJsonFile -Path $statusPath
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
            } catch { Pump-UI }
        } else { Pump-UI }
    }
'''
install = replace_once(install, old_loop, new_loop, "live download status")

install = replace_once(
    install,
    '        download_route = $(if (Test-ChinaMirrorPriority) { "china-mirror-first" } else { "official-first" })\n',
    '        download_route = $(if (Test-ChinaMirrorPriority) { "china-mirror-first" } else { "official-first" })\n        model_download_mode = (Get-ModelDownloadMode)\n',
    "manifest mode",
)

install = replace_once(
    install,
    '    if ($script:chkChinaMirror) { $script:chkChinaMirror.Enabled = $false }\n',
    '    if ($script:chkChinaMirror) { $script:chkChinaMirror.Enabled = $false }\n    if ($script:DownloadModeCombo) { $script:DownloadModeCombo.Enabled = $false }\n',
    "disable mode selector",
)
install = replace_once(
    install,
    '        Add-Log "Download route: $(Get-DownloadRouteLabel)"\n',
    '        Add-Log "Download route: $(Get-DownloadRouteLabel)"\n        Add-Log "Model download mode: $(Get-ModelDownloadModeLabel)"\n',
    "install log mode",
)
install = replace_once(
    install,
    '        if ($script:chkChinaMirror) { $script:chkChinaMirror.Enabled = $true }\n',
    '        if ($script:chkChinaMirror) { $script:chkChinaMirror.Enabled = $true }\n        if ($script:DownloadModeCombo) { $script:DownloadModeCombo.Enabled = $true }\n',
    "enable mode selector",
)
install_path.write_text(install, encoding="utf-8")
