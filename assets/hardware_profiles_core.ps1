$script:ProfilesPath = Join-Path $script:AssetsRoot "install_profiles.json"
$script:CatalogPath = Join-Path $script:AssetsRoot "hf_model_inventory.json"
if (-not (Test-Path -LiteralPath $script:ProfilesPath)) { throw "Installer asset is missing: $script:ProfilesPath" }
if (-not (Test-Path -LiteralPath $script:CatalogPath)) { throw "Installer asset is missing: $script:CatalogPath" }
$script:ProfileConfig = Get-Content -LiteralPath $script:ProfilesPath -Raw | ConvertFrom-Json
$script:ModelCatalog = @(Get-Content -LiteralPath $script:CatalogPath -Raw | ConvertFrom-Json)
$script:Profiles = @($script:ProfileConfig.profiles)
$script:SelectedProfileId = "auto"
$script:ProfileConfirmed = $false
$script:LastHardwareReport = $null
$script:ProfileButton = $null

function Get-ProfileById {
    param([string]$Id)
    $profile = $script:Profiles | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $profile) { throw "Unknown installation profile: $Id" }
    return $profile
}

function Get-RuntimeById {
    param([string]$Id)
    $property = $script:ProfileConfig.runtimes.PSObject.Properties[$Id]
    if (-not $property) { throw "Unknown PyTorch runtime: $Id" }
    return $property.Value
}

function Test-IsBlackwellGpu {
    param([string]$GpuName)
    return [bool]($GpuName -match '(?i)RTX\s*50\d{2}|RTX\s+PRO.*Blackwell')
}

function Get-RuntimeIdForGpu {
    param([string]$GpuName)
    if (Test-IsBlackwellGpu $GpuName) { return "cuda128" }
    return "cuda126"
}

function Get-RecommendProfileId {
    param([double]$VramMiB, [int64]$RamBytes, [string]$GpuName)
    if ($VramMiB -ge 22000 -and $RamBytes -ge [int64](60GB)) { return "quality_64gb" }
    $fp8Preferred = ($GpuName -match '(?i)RTX\s*40\d{2}') -or (Test-IsBlackwellGpu $GpuName)
    if ($fp8Preferred -and $VramMiB -ge 22000 -and $RamBytes -ge [int64](30GB)) { return "balanced_4090_32gb" }
    return "compatibility"
}

function Get-ProfileRequiredRamBytes {
    param($Profile)
    # Windows can report slightly less usable RAM than the installed module capacity.
    # Keep the displayed profile requirement unchanged while allowing normal 16/32/64 GB systems.
    return [int64]([double]$Profile.min_ram_gib * 0.94 * 1GB)
}

function Get-ProfileModelBytes {
    param($Profile)
    $paths = @($Profile.diffusion_model, $Profile.text_encoder, $Profile.video_vae, $Profile.audio_vae)
    $total = [int64]0
    foreach ($path in $paths) {
        $item = $script:ModelCatalog | Where-Object { $_.path -eq $path } | Select-Object -First 1
        if (-not $item) { throw "Profile $($Profile.id) references a model absent from the catalog: $path" }
        $total += [int64]$item.size
    }
    return $total
}

function Get-HardwareSnapshot {
    $ramBytes = [int64]0
    try { $ramBytes = Get-TotalRamBytes } catch { $ramBytes = 0 }

    $gpuName = ""
    $gpuIndex = 0
    $vramMiB = [double]0
    $driver = ""
    $smi = Get-NvidiaSmiPath
    if ($smi) {
        $gpuRows = @(& $smi --query-gpu=index,name,memory.total,driver_version --format=csv,noheader,nounits 2>$null)
        $gpus = foreach ($line in $gpuRows) {
            if (-not $line) { continue }
            $parts = $line -split ",\s*"
            if ($parts.Count -lt 4) { continue }
            [PSCustomObject]@{
                Index = [int]$parts[0]
                Name = $parts[1]
                VramMiB = [double]$parts[2]
                Driver = $parts[3]
            }
        }
        $gpu = $gpus | Sort-Object VramMiB -Descending | Select-Object -First 1
        if ($gpu) {
            $gpuName = $gpu.Name
            $gpuIndex = $gpu.Index
            $vramMiB = $gpu.VramMiB
            $driver = $gpu.Driver
        }
    }

    return [PSCustomObject]@{
        RamBytes = $ramBytes
        GpuName = $gpuName
        GpuIndex = $gpuIndex
        VramMiB = $vramMiB
        Driver = $driver
        NvidiaSmiFound = [bool]$smi
        RecommendedProfileId = (Get-RecommendProfileId -VramMiB $vramMiB -RamBytes $ramBytes -GpuName $gpuName)
        RuntimeId = (Get-RuntimeIdForGpu -GpuName $gpuName)
    }
}

function Resolve-SelectedProfileId {
    param($Snapshot)
    $selected = [string]$script:SelectedProfileId
    if ([string]::IsNullOrWhiteSpace($selected) -or $selected -eq "auto") {
        return $Snapshot.RecommendedProfileId
    }
    $known = $script:Profiles | Where-Object { $_.id -eq $selected } | Select-Object -First 1
    if (-not $known) { return $Snapshot.RecommendedProfileId }
    return $selected
}

function Get-ProfileChoiceId {
    param($Combo)
    $id = ""
    if ($Combo -and $Combo.SelectedItem) {
        $idProperty = $Combo.SelectedItem.PSObject.Properties["Id"]
        if ($idProperty) { $id = [string]$idProperty.Value }
    }
    if ([string]::IsNullOrWhiteSpace($id) -and $Combo) {
        $id = [string]$Combo.SelectedValue
    }
    if ([string]::IsNullOrWhiteSpace($id) -or $id -eq "auto") { return "auto" }
    $known = $script:Profiles | Where-Object { $_.id -eq $id } | Select-Object -First 1
    if (-not $known) { return "auto" }
    return $id
}

function Initialize-ProfileComboBox {
    param($Combo, $Choices, [string]$SelectedId)
    if (-not $Combo) { throw "Profile ComboBox is missing." }

    $Combo.BeginUpdate()
    try {
        $Combo.DataSource = $null
        $Combo.Items.Clear()
        $Combo.DisplayMember = "Label"
        foreach ($choice in @($Choices)) {
            if ($choice) { [void]$Combo.Items.Add($choice) }
        }
        if ($Combo.Items.Count -eq 0) {
            throw "No installation profiles are available."
        }

        $selectedIndex = 0
        for ($i = 0; $i -lt $Combo.Items.Count; $i++) {
            $item = $Combo.Items[$i]
            $idProperty = $item.PSObject.Properties["Id"]
            if ($idProperty -and [string]$idProperty.Value -eq [string]$SelectedId) {
                $selectedIndex = $i
                break
            }
        }
        $Combo.SelectedIndex = $selectedIndex
    } finally {
        $Combo.EndUpdate()
    }
}

function Get-ProfileSummaryText {
    param($Profile)
    $bytes = Get-ProfileModelBytes $Profile
    return "Models {0:N1} GiB | default {1}, {2}s. {3}" -f ($bytes/1GB), $Profile.resolution, $Profile.duration_seconds, $Profile.summary
}

function Show-HardwareProfileDialog {
    $snapshot = Get-HardwareSnapshot
    $recommended = Get-ProfileById $snapshot.RecommendedProfileId

    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = "Choose MiniMax H3 configuration"
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ClientSize = New-Object Drawing.Size(720, 360)
    $dialog.Font = New-Object Drawing.Font("Segoe UI", 9)

    $heading = New-Object Windows.Forms.Label
    $heading.Text = "Select the model profile before installation"
    $heading.Font = New-Object Drawing.Font("Segoe UI Semibold", 15)
    $heading.AutoSize = $true
    $heading.Location = New-Object Drawing.Point(20, 18)
    $dialog.Controls.Add($heading)

    $hardware = New-Object Windows.Forms.Label
    $gpuText = if ($snapshot.GpuName) { "GPU $($snapshot.GpuIndex): $($snapshot.GpuName) ($([Math]::Round($snapshot.VramMiB/1024,1)) GB VRAM)" } else { "NVIDIA GPU: not detected" }
    $ramText = if ($snapshot.RamBytes -gt 0) { "RAM: $([Math]::Round($snapshot.RamBytes/1GB,1)) GiB" } else { "RAM: unknown" }
    $hardware.Text = "$gpuText`n$ramText`nRecommended: $($recommended.label)"
    $hardware.Location = New-Object Drawing.Point(22, 58)
    $hardware.Size = New-Object Drawing.Size(675, 62)
    $dialog.Controls.Add($hardware)

    $combo = New-Object Windows.Forms.ComboBox
    $combo.DropDownStyle = "DropDownList"
    $combo.Location = New-Object Drawing.Point(22, 132)
    $combo.Size = New-Object Drawing.Size(660, 28)
    $choices = New-Object System.Collections.ArrayList
    [void]$choices.Add([PSCustomObject]@{ Id="auto"; Label="Auto - $($recommended.label)" })
    foreach ($profile in $script:Profiles) {
        [void]$choices.Add([PSCustomObject]@{ Id=[string]$profile.id; Label=[string]$profile.label })
    }
    $combo.DisplayMember = "Label"
    $dialog.Controls.Add($combo)
    Initialize-ProfileComboBox -Combo $combo -Choices $choices -SelectedId $script:SelectedProfileId

    $details = New-Object Windows.Forms.Label
    $details.Location = New-Object Drawing.Point(22, 176)
    $details.Size = New-Object Drawing.Size(660, 92)
    $details.BorderStyle = "FixedSingle"
    $details.Padding = New-Object Windows.Forms.Padding(10)
    $dialog.Controls.Add($details)

    $ok = New-Object Windows.Forms.Button
    $ok.Text = "Use this configuration"
    $ok.DialogResult = [Windows.Forms.DialogResult]::OK
    $ok.Location = New-Object Drawing.Point(474, 300)
    $ok.Size = New-Object Drawing.Size(208, 38)
    $dialog.Controls.Add($ok)
    $dialog.AcceptButton = $ok

    $updateDetails = {
        try {
            $choiceId = Get-ProfileChoiceId $combo
            $resolvedId = if ($choiceId -eq "auto") { $snapshot.RecommendedProfileId } else { $choiceId }
            $profile = Get-ProfileById $resolvedId
            $runtime = Get-RuntimeById $snapshot.RuntimeId
            $meets = ($snapshot.VramMiB -ge [double]$profile.min_vram_mib) -and ($snapshot.RamBytes -ge (Get-ProfileRequiredRamBytes $profile))
            $state = if ($meets) { "Hardware check: compatible" } else { "Hardware check: below this profile's minimum; installation will be blocked" }
            $details.Text = "$(Get-ProfileSummaryText $profile)`nRuntime: $($runtime.label)`n$state"
            $ok.Enabled = $true
        } catch {
            $details.Text = "Could not load the selected profile.`n$($_.Exception.Message)"
            $ok.Enabled = $false
        }
    }
    $combo.Add_SelectedIndexChanged($updateDetails)
    & $updateDetails

    $result = $dialog.ShowDialog($form)
    if ($result -eq [Windows.Forms.DialogResult]::OK) {
        $script:SelectedProfileId = Get-ProfileChoiceId $combo
        $script:ProfileConfirmed = $true
    }
    $dialog.Dispose()
}

function Initialize-HardwareProfileUI {
    if (-not $script:ProfileButton) {
        $script:ProfileButton = New-Object Windows.Forms.Button
        $script:ProfileButton.Text = "Change configuration"
        $script:ProfileButton.Location = New-Object Drawing.Point(760, 50)
        $script:ProfileButton.Size = New-Object Drawing.Size(180, 32)
        $script:ProfileButton.Anchor = "Top,Right"
        $script:ProfileButton.Add_Click({
            Show-HardwareProfileDialog
            Show-HardwareReport | Out-Null
        })
        $form.Controls.Add($script:ProfileButton)
        $script:ProfileButton.BringToFront()
    }
    if (-not $script:ProfileConfirmed) { Show-HardwareProfileDialog }
}

function Get-HardwareReport {
    param([string]$InstallPath)

    $snapshot = Get-HardwareSnapshot
    $profileId = Resolve-SelectedProfileId $snapshot
    $profile = Get-ProfileById $profileId
    $runtime = Get-RuntimeById $snapshot.RuntimeId
    $result = New-Object System.Collections.Generic.List[object]
    $script:checkBlocking = $false
    $add = {
        param($Name, $Value, $Status, $Detail)
        $result.Add([PSCustomObject]@{ Name=$Name; Value=$Value; Status=$Status; Detail=$Detail })
        if ($Status -eq "FAIL") { $script:checkBlocking = $true }
    }

    $is64 = [Environment]::Is64BitOperatingSystem
    & $add "Windows" ($(if ($is64) { "64-bit" } else { "32-bit" })) ($(if ($is64) { "PASS" } else { "FAIL" })) "Windows 10/11 x64 with a desktop session is required."

    if ($snapshot.RamBytes -gt 0) {
        $requiredRam = Get-ProfileRequiredRamBytes $profile
        $ramOk = $snapshot.RamBytes -ge $requiredRam
        & $add "System RAM" (Format-GiB $snapshot.RamBytes) ($(if ($ramOk) { "PASS" } else { "FAIL" })) ("Selected profile requires at least {0} GiB RAM." -f $profile.min_ram_gib)
    } else {
        & $add "System RAM" "Unknown" "WARN" "Could not read total physical memory."
    }

    if (-not $snapshot.NvidiaSmiFound) {
        & $add "NVIDIA GPU" "Not found" "FAIL" "Install an NVIDIA display driver first."
    } elseif (-not $snapshot.GpuName) {
        & $add "NVIDIA GPU" "Query failed" "FAIL" "nvidia-smi could not read a usable NVIDIA GPU."
    } else {
        $vramOk = $snapshot.VramMiB -ge [double]$profile.min_vram_mib
        & $add "NVIDIA GPU" ("GPU {0}: {1}" -f $snapshot.GpuIndex, $snapshot.GpuName) ($(if ($vramOk) { "PASS" } else { "FAIL" })) ("VRAM {0:N0} MiB; selected profile requires {1:N0} MiB." -f $snapshot.VramMiB, [double]$profile.min_vram_mib)
        $driverMajor = 0
        [void][int]::TryParse(($snapshot.Driver -split '\.')[0], [ref]$driverMajor)
        $driverStatus = if ($driverMajor -ge [int]$runtime.minimum_driver_major) { "PASS" } else { "WARN" }
        & $add "NVIDIA driver" $snapshot.Driver $driverStatus ("{0} or newer is recommended for {1}." -f $runtime.minimum_driver_major, $runtime.label)
    }

    $selectionText = if ($script:SelectedProfileId -eq "auto") { "Automatically recommended." } else { "Manually selected." }
    & $add "Install profile" $profile.label "PASS" ("{0} Default {1}, {2} seconds." -f $selectionText, $profile.resolution, $profile.duration_seconds)
    & $add "PyTorch runtime" $runtime.label "PASS" ($(if ($snapshot.RuntimeId -eq "cuda128") { "RTX 50-series / Blackwell runtime selected." } else { "RTX 30/40-series runtime selected." }))

    try {
        $free = Get-DriveFreeBytes $InstallPath
        $required = [int64]$profile.required_free_gib * 1GB
        $freeOk = $free -ge $required
        & $add "Disk space" (Format-GiB $free) ($(if ($freeOk) { "PASS" } else { "FAIL" })) ("Selected profile requires at least {0} GiB free." -f $profile.required_free_gib)
    } catch {
        & $add "Disk space" "Unknown" "FAIL" $_.Exception.Message
    }

    try { $port = Get-NetTCPConnection -LocalPort 8188 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1 } catch { $port = $null }
    if ($port) {
        & $add "Port 8188" ("In use by PID {0}" -f $port.OwningProcess) "WARN" "The launcher will not replace another program using this port."
    } else {
        & $add "Port 8188" "Available" "PASS" "ComfyUI will listen only on 127.0.0.1."
    }

    $fullPath = [IO.Path]::GetFullPath($InstallPath)
    $pathStatus = "PASS"
    $pathDetail = "A self-contained environment will be created here."
    if ($fullPath.StartsWith("\\")) {
        $pathStatus = "FAIL"
        $pathDetail = "Network paths are not supported."
    } elseif ($fullPath.Length -gt 100) {
        $pathStatus = "WARN"
        $pathDetail = "A shorter path reduces Python package path-length problems."
    }
    & $add "Install path" $fullPath $pathStatus $pathDetail

    return [PSCustomObject]@{
        Items = $result
        Blocking = $script:checkBlocking
        RamBytes = $snapshot.RamBytes
        GpuName = $snapshot.GpuName
        GpuIndex = $snapshot.GpuIndex
        VramMiB = $snapshot.VramMiB
        Driver = $snapshot.Driver
        ProfileId = $profileId
        RuntimeId = $snapshot.RuntimeId
        RecommendedProfileId = $snapshot.RecommendedProfileId
    }
}

function Show-HardwareReport {
    $path = $txtPath.Text.Trim()
    if (-not $path) { return $null }
    $grid.Rows.Clear()
    try {
        $report = Get-HardwareReport $path
        $script:LastHardwareReport = $report
        foreach ($item in $report.Items) {
            $index = $grid.Rows.Add($item.Name, $item.Value, $item.Status, $item.Detail)
            $color = switch ($item.Status) {
                "PASS" { [Drawing.Color]::FromArgb(27, 122, 78) }
                "WARN" { [Drawing.Color]::FromArgb(174, 102, 0) }
                default { [Drawing.Color]::FromArgb(185, 28, 28) }
            }
            $grid.Rows[$index].Cells[2].Style.ForeColor = $color
        }
        $profile = Get-ProfileById $report.ProfileId
        $runtime = Get-RuntimeById $report.RuntimeId
        $subtitle.Text = "Profile: $($profile.id) | CUDA $($runtime.cuda_version) | GPU $($report.GpuIndex) | DynamicVRAM"
        if ($report.Blocking) {
            $lblCheck.Text = "Hardware/profile check failed. See the red rows below."
            $lblCheck.ForeColor = [Drawing.Color]::FromArgb(185, 28, 28)
        } else {
            $lblCheck.Text = "Ready to install. Warnings do not block installation."
            $lblCheck.ForeColor = [Drawing.Color]::FromArgb(27, 122, 78)
        }
        return $report
    } catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Check failed", "OK", "Error") | Out-Null
        return $null
    }
}
