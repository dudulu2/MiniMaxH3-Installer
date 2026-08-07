$script:SelectedRuntimeChannel = ""

function Get-RecommendedRuntimeChannel {
    param([string]$GpuName)
    if (Test-IsBlackwellGpu $GpuName) { return "new" }
    return "stable"
}

function Get-SelectedRuntimeChannel {
    param([string]$GpuName)
    $selected = [string]$script:SelectedRuntimeChannel
    if ($selected -in @("stable", "new")) { return $selected }
    return (Get-RecommendedRuntimeChannel -GpuName $GpuName)
}

function Get-RuntimeIdForGpu {
    param([string]$GpuName)
    switch (Get-SelectedRuntimeChannel -GpuName $GpuName) {
        "new" { return "cuda130" }
        default { return "cuda126" }
    }
}

function Get-RuntimeChannelLabel {
    param([string]$Channel)
    if ($Channel -eq "new") { return "New version - PyTorch 2.10 / CUDA 13.0" }
    return "Stable version - PyTorch 2.8 / CUDA 12.6"
}

function Show-HardwareProfileDialog {
    $snapshot = Get-HardwareSnapshot
    Initialize-MainModelSelectionFromExistingInstall -InstallPath $txtPath.Text.Trim()

    $recommendedBase = Get-BaseProfileById $snapshot.RecommendedProfileId
    $recommendedRuntimeChannel = Get-RecommendedRuntimeChannel -GpuName $snapshot.GpuName
    $initialRuntimeChannel = Get-SelectedRuntimeChannel -GpuName $snapshot.GpuName
    $dialogState = [PSCustomObject]@{
        MainModelSelection = [string]$script:SelectedMainModelPath
    }

    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = "Choose MiniMax H3 configuration"
    $dialog.StartPosition = "CenterParent"
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ClientSize = New-Object Drawing.Size(720, 610)
    $dialog.Font = New-Object Drawing.Font("Segoe UI", 9)

    $heading = New-Object Windows.Forms.Label
    $heading.Text = "Select the model profile, main model, and runtime version"
    $heading.Font = New-Object Drawing.Font("Segoe UI Semibold", 15)
    $heading.AutoSize = $true
    $heading.Location = New-Object Drawing.Point(20, 18)
    $dialog.Controls.Add($heading)

    $hardware = New-Object Windows.Forms.Label
    $gpuText = if ($snapshot.GpuName) { "GPU $($snapshot.GpuIndex): $($snapshot.GpuName) ($([Math]::Round($snapshot.VramMiB/1024,1)) GB VRAM)" } else { "NVIDIA GPU: not detected" }
    $ramText = if ($snapshot.RamBytes -gt 0) { "RAM: $([Math]::Round($snapshot.RamBytes/1GB,1)) GiB" } else { "RAM: unknown" }
    $runtimeRecommendation = if ($recommendedRuntimeChannel -eq "new") { "New version (RTX 50 series preferred)" } else { "Stable version" }
    $hardware.Text = "$gpuText`n$ramText`nRecommended profile: $($recommendedBase.label)`nRecommended runtime: $runtimeRecommendation"
    $hardware.Location = New-Object Drawing.Point(22, 58)
    $hardware.Size = New-Object Drawing.Size(675, 80)
    $dialog.Controls.Add($hardware)

    $profileLabel = New-Object Windows.Forms.Label
    $profileLabel.Text = "Model configuration:"
    $profileLabel.AutoSize = $true
    $profileLabel.Location = New-Object Drawing.Point(22, 147)
    $dialog.Controls.Add($profileLabel)

    $combo = New-Object Windows.Forms.ComboBox
    $combo.DropDownStyle = "DropDownList"
    $combo.Location = New-Object Drawing.Point(22, 169)
    $combo.Size = New-Object Drawing.Size(660, 28)
    $choices = New-Object System.Collections.ArrayList
    [void]$choices.Add([PSCustomObject]@{ Id="auto"; Label="Auto - $($recommendedBase.label)" })
    foreach ($profile in $script:Profiles) {
        [void]$choices.Add([PSCustomObject]@{ Id=[string]$profile.id; Label=[string]$profile.label })
    }
    $combo.DisplayMember = "Label"
    $dialog.Controls.Add($combo)
    Initialize-ProfileComboBox -Combo $combo -Choices $choices -SelectedId $script:SelectedProfileId

    $mainModelLabel = New-Object Windows.Forms.Label
    $mainModelLabel.Text = "Main model:"
    $mainModelLabel.AutoSize = $true
    $mainModelLabel.Location = New-Object Drawing.Point(22, 211)
    $dialog.Controls.Add($mainModelLabel)

    $mainModelValue = New-Object Windows.Forms.Label
    $mainModelValue.Location = New-Object Drawing.Point(22, 235)
    $mainModelValue.Size = New-Object Drawing.Size(490, 42)
    $mainModelValue.BorderStyle = "FixedSingle"
    $mainModelValue.Padding = New-Object Windows.Forms.Padding(8)
    $dialog.Controls.Add($mainModelValue)

    $adjustMainModel = New-Object Windows.Forms.Button
    $adjustMainModel.Text = "Adjust main model..."
    $adjustMainModel.Location = New-Object Drawing.Point(524, 235)
    $adjustMainModel.Size = New-Object Drawing.Size(158, 42)
    $dialog.Controls.Add($adjustMainModel)

    $runtimeLabel = New-Object Windows.Forms.Label
    $runtimeLabel.Text = "Runtime version:"
    $runtimeLabel.AutoSize = $true
    $runtimeLabel.Location = New-Object Drawing.Point(22, 292)
    $dialog.Controls.Add($runtimeLabel)

    $stableRadio = New-Object Windows.Forms.RadioButton
    $stableRadio.Text = "Stable version - PyTorch 2.8 / CUDA 12.6"
    $stableRadio.AutoSize = $true
    $stableRadio.Location = New-Object Drawing.Point(24, 316)
    $dialog.Controls.Add($stableRadio)

    $newRadio = New-Object Windows.Forms.RadioButton
    $newRadio.Text = "New version - PyTorch 2.10 / CUDA 13.0 (RTX 50 series preferred)"
    $newRadio.AutoSize = $true
    $newRadio.Location = New-Object Drawing.Point(24, 342)
    $dialog.Controls.Add($newRadio)

    if ($initialRuntimeChannel -eq "new") { $newRadio.Checked = $true } else { $stableRadio.Checked = $true }

    $runtimeHint = New-Object Windows.Forms.Label
    $runtimeHint.Text = "RTX 50-series GPUs default to New; RTX 30/40-series GPUs default to Stable. Both runtime and main model can be changed manually for testing."
    $runtimeHint.Location = New-Object Drawing.Point(44, 368)
    $runtimeHint.Size = New-Object Drawing.Size(638, 36)
    $runtimeHint.ForeColor = [Drawing.Color]::FromArgb(90, 90, 90)
    $dialog.Controls.Add($runtimeHint)

    $details = New-Object Windows.Forms.Label
    $details.Location = New-Object Drawing.Point(22, 414)
    $details.Size = New-Object Drawing.Size(660, 120)
    $details.BorderStyle = "FixedSingle"
    $details.Padding = New-Object Windows.Forms.Padding(10)
    $dialog.Controls.Add($details)

    $ok = New-Object Windows.Forms.Button
    $ok.Text = "Use this configuration"
    $ok.DialogResult = [Windows.Forms.DialogResult]::OK
    $ok.Location = New-Object Drawing.Point(474, 552)
    $ok.Size = New-Object Drawing.Size(208, 38)
    $dialog.Controls.Add($ok)
    $dialog.AcceptButton = $ok

    $getSelectedBaseProfile = {
        $choiceId = Get-ProfileChoiceId $combo
        $resolvedId = if ($choiceId -eq "auto") { $snapshot.RecommendedProfileId } else { $choiceId }
        return (Get-BaseProfileById $resolvedId)
    }

    $updateDetails = {
        try {
            $baseProfile = & $getSelectedBaseProfile
            $profile = Get-EffectiveProfileForSelection -Profile $baseProfile -Selection ([string]$dialogState.MainModelSelection)
            $runtimeChannel = if ($newRadio.Checked) { "new" } else { "stable" }
            $runtimeId = if ($runtimeChannel -eq "new") { "cuda130" } else { "cuda126" }
            $runtime = Get-RuntimeById $runtimeId
            $meets = ($snapshot.VramMiB -ge [double]$profile.min_vram_mib) -and ($snapshot.RamBytes -ge (Get-ProfileRequiredRamBytes $profile))
            $state = if ($meets) { "Hardware check: compatible" } else { "Hardware check: below this profile's minimum; installation will be blocked" }

            $mainModelValue.Text = Get-MainModelSelectionDisplayText -BaseProfile $baseProfile -Selection ([string]$dialogState.MainModelSelection)
            $mainSize = Get-MainModelSizeGiB ([string]$profile.diffusion_model)
            $selectionMode = if ([string]$dialogState.MainModelSelection -eq "auto") { "profile default" } else { "manual override" }

            $runtimeWarning = ""
            if ((Test-IsBlackwellGpu $snapshot.GpuName) -and $runtimeChannel -eq "stable") {
                $runtimeWarning = " | New runtime is recommended for RTX 50 series."
            } elseif (-not (Test-IsBlackwellGpu $snapshot.GpuName) -and $runtimeChannel -eq "new") {
                $runtimeWarning = " | Manual runtime test mode; driver 580+ is recommended."
            }

            $modelWarning = if ([string]$dialogState.MainModelSelection -eq "auto") {
                ""
            } else {
                " | Main model is manually selected; lower-VRAM GPUs may rely more heavily on RAM/offload."
            }

            $details.Text = "$(Get-ProfileSummaryText $profile)`nMain model: $(Split-Path -Leaf $profile.diffusion_model) ($([Math]::Round($mainSize,1)) GiB, $selectionMode)`nRuntime: $($runtime.label)$runtimeWarning`n$state$modelWarning"
            $ok.Enabled = $true
        } catch {
            $details.Text = "Could not load the selected configuration.`n$($_.Exception.Message)"
            $ok.Enabled = $false
        }
    }

    $adjustMainModel.Add_Click({
        try {
            $baseProfile = & $getSelectedBaseProfile
            $choice = Show-MainModelSelectionDialog -Owner $dialog -BaseProfile $baseProfile -CurrentSelection ([string]$dialogState.MainModelSelection)
            if ($choice.Accepted) {
                $dialogState.MainModelSelection = [string]$choice.Selection
                & $updateDetails
            }
        } catch {
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, "Main model selection failed", "OK", "Error") | Out-Null
        }
    })

    $combo.Add_SelectedIndexChanged($updateDetails)
    $stableRadio.Add_CheckedChanged($updateDetails)
    $newRadio.Add_CheckedChanged($updateDetails)
    & $updateDetails

    $result = $dialog.ShowDialog($form)
    if ($result -eq [Windows.Forms.DialogResult]::OK) {
        $script:SelectedProfileId = Get-ProfileChoiceId $combo
        $script:SelectedMainModelPath = [string]$dialogState.MainModelSelection
        $script:SelectedRuntimeChannel = if ($newRadio.Checked) { "new" } else { "stable" }
        $script:ProfileConfirmed = $true
    }
    $dialog.Dispose()
}
