$script:SelectedMainModelPath = "auto"
$script:MainModelSelectionInitialized = $false

$script:AllowedMainModels = @(
    [PSCustomObject]@{
        Path = "diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors"
        Name = "Pruned INT8 ConvRot"
        Note = "Lowest-memory FL2VA choice."
    },
    [PSCustomObject]@{
        Path = "diffusion_models/minimax_h3_fl2va_pruned_fp8_scaled.safetensors"
        Name = "Pruned FP8 Scaled"
        Note = "Pruned FP8 FL2VA choice."
    },
    [PSCustomObject]@{
        Path = "diffusion_models/minimax_h3_fl2va_int8_convrot.safetensors"
        Name = "Full INT8 ConvRot"
        Note = "Full FL2VA INT8 model; useful for manual testing on lower-VRAM cards with offload."
    },
    [PSCustomObject]@{
        Path = "diffusion_models/minimax_h3_fl2va_pruned_bf16.safetensors"
        Name = "Pruned BF16"
        Note = "Higher-precision pruned FL2VA model."
    },
    [PSCustomObject]@{
        Path = "diffusion_models/minimax_h3_fl2va_bf16.safetensors"
        Name = "Full BF16"
        Note = "Largest full-precision FL2VA model."
    }
)

$script:GetProfileByIdBeforeMainModel = ${function:Get-ProfileById}
$script:GetHardwareReportBeforeMainModel = ${function:Get-HardwareReport}
$script:InstallH3ModelsBeforeMainModel = ${function:Install-H3Models}
$script:InstallWorkflowAndLauncherBeforeMainModel = ${function:Install-WorkflowAndLauncher}

if (-not $script:GetProfileByIdBeforeMainModel) { throw "Get-ProfileById is not available for main model selection." }
if (-not $script:GetHardwareReportBeforeMainModel) { throw "Get-HardwareReport is not available for main model selection." }
if (-not $script:InstallH3ModelsBeforeMainModel) { throw "Install-H3Models is not available for main model selection." }
if (-not $script:InstallWorkflowAndLauncherBeforeMainModel) { throw "Install-WorkflowAndLauncher is not available for main model selection." }

function Get-BaseProfileById {
    param([string]$Id)
    return (& $script:GetProfileByIdBeforeMainModel -Id $Id)
}

function Test-IsAllowedMainModelPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return [bool]($script:AllowedMainModels | Where-Object { [string]$_.Path -eq $Path } | Select-Object -First 1)
}

function Get-MainModelInfo {
    param([string]$Path)
    return ($script:AllowedMainModels | Where-Object { [string]$_.Path -eq $Path } | Select-Object -First 1)
}

function Get-MainModelSizeGiB {
    param([string]$Path)
    $item = Get-ModelCatalogItem -Path $Path
    return [double]$item.Size / 1GB
}

function Get-EffectiveMainModelPath {
    param($Profile, [string]$Selection = "")
    $selected = if ([string]::IsNullOrWhiteSpace($Selection)) { [string]$script:SelectedMainModelPath } else { $Selection }
    if ($selected -eq "auto" -or [string]::IsNullOrWhiteSpace($selected)) {
        return [string]$Profile.diffusion_model
    }
    if (-not (Test-IsAllowedMainModelPath $selected)) {
        Add-Log "Ignoring unsupported main model override: $selected" "WARN"
        return [string]$Profile.diffusion_model
    }
    return $selected
}

function Get-EffectiveProfileForSelection {
    param($Profile, [string]$Selection = "")

    $properties = [ordered]@{}
    foreach ($property in $Profile.PSObject.Properties) {
        $properties[$property.Name] = $property.Value
    }

    $effectivePath = Get-EffectiveMainModelPath -Profile $Profile -Selection $Selection
    $properties["diffusion_model"] = $effectivePath
    $effective = [PSCustomObject]$properties

    # Reserve enough disk for all selected model files plus working/download headroom.
    # This does not impose a new VRAM limit: users may intentionally test larger
    # FL2VA models with CPU/RAM offload on lower-VRAM GPUs.
    $modelBytes = Get-ProfileModelBytes $effective
    $dynamicRequiredGiB = [int][Math]::Ceiling(($modelBytes / 1GB) + 8)
    $baseRequiredGiB = [int]$Profile.required_free_gib
    $effective.required_free_gib = [int][Math]::Max($baseRequiredGiB, $dynamicRequiredGiB)
    return $effective
}

function Get-ProfileById {
    param([string]$Id)
    $base = Get-BaseProfileById -Id $Id
    return (Get-EffectiveProfileForSelection -Profile $base -Selection ([string]$script:SelectedMainModelPath))
}

function Get-MainModelSelectionDisplayText {
    param($BaseProfile, [string]$Selection = "")
    $effectivePath = Get-EffectiveMainModelPath -Profile $BaseProfile -Selection $Selection
    $info = Get-MainModelInfo $effectivePath
    $name = if ($info) { [string]$info.Name } else { Split-Path -Leaf $effectivePath }
    $size = Get-MainModelSizeGiB $effectivePath
    $mode = if ([string]::IsNullOrWhiteSpace($Selection) -or $Selection -eq "auto") { "Auto" } else { "Manual" }
    return ("{0}: {1} ({2:N1} GiB)" -f $mode, $name, $size)
}

function Initialize-MainModelSelectionFromExistingInstall {
    param([string]$InstallPath)
    if ($script:MainModelSelectionInitialized) { return }
    $script:MainModelSelectionInitialized = $true
    if ([string]::IsNullOrWhiteSpace($InstallPath)) { return }

    try {
        $manifestPath = Join-Path ([IO.Path]::GetFullPath($InstallPath)) ".minimax-h3-install.json"
        if (-not (Test-Path -LiteralPath $manifestPath)) { return }
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $existingPath = [string]$manifest.diffusion_model
        if (-not (Test-IsAllowedMainModelPath $existingPath)) { return }

        $base = $null
        try { $base = Get-BaseProfileById -Id ([string]$manifest.profile) } catch { $base = $null }
        if ($base -and [string]$base.diffusion_model -eq $existingPath) {
            $script:SelectedMainModelPath = "auto"
        } else {
            $script:SelectedMainModelPath = $existingPath
            Add-Log "Preserving main model from existing installation: $(Split-Path -Leaf $existingPath)"
        }
    } catch {
        Add-Log "Could not restore the previous main model selection: $($_.Exception.Message)" "WARN"
    }
}

function Show-MainModelSelectionDialog {
    param(
        [Windows.Forms.IWin32Window]$Owner,
        $BaseProfile,
        [string]$CurrentSelection
    )

    $picker = New-Object Windows.Forms.Form
    $picker.Text = "Adjust MiniMax H3 main model"
    $picker.StartPosition = "CenterParent"
    $picker.FormBorderStyle = "FixedDialog"
    $picker.MaximizeBox = $false
    $picker.MinimizeBox = $false
    $picker.ClientSize = New-Object Drawing.Size(690, 360)
    $picker.Font = New-Object Drawing.Font("Segoe UI", 9)

    $title = New-Object Windows.Forms.Label
    $title.Text = "Choose the FL2VA diffusion model"
    $title.Font = New-Object Drawing.Font("Segoe UI Semibold", 14)
    $title.AutoSize = $true
    $title.Location = New-Object Drawing.Point(20, 18)
    $picker.Controls.Add($title)

    $hint = New-Object Windows.Forms.Label
    $hint.Text = "Auto is safest for most users. Manual choices stay within the FL2VA model family so the bundled workflow remains compatible."
    $hint.Location = New-Object Drawing.Point(22, 52)
    $hint.Size = New-Object Drawing.Size(640, 40)
    $picker.Controls.Add($hint)

    $combo = New-Object Windows.Forms.ComboBox
    $combo.DropDownStyle = "DropDownList"
    $combo.DisplayMember = "Label"
    $combo.Location = New-Object Drawing.Point(22, 100)
    $combo.Size = New-Object Drawing.Size(640, 28)

    $defaultPath = [string]$BaseProfile.diffusion_model
    $defaultInfo = Get-MainModelInfo $defaultPath
    $defaultName = if ($defaultInfo) { [string]$defaultInfo.Name } else { Split-Path -Leaf $defaultPath }
    $defaultSize = Get-MainModelSizeGiB $defaultPath
    [void]$combo.Items.Add([PSCustomObject]@{
        Id = "auto"
        Label = ("Auto - profile default: {0} ({1:N1} GiB)" -f $defaultName, $defaultSize)
    })
    foreach ($model in $script:AllowedMainModels) {
        $size = Get-MainModelSizeGiB ([string]$model.Path)
        [void]$combo.Items.Add([PSCustomObject]@{
            Id = [string]$model.Path
            Label = ("{0} ({1:N1} GiB)" -f [string]$model.Name, $size)
        })
    }
    $picker.Controls.Add($combo)

    $selectedIndex = 0
    for ($i = 0; $i -lt $combo.Items.Count; $i++) {
        if ([string]$combo.Items[$i].Id -eq [string]$CurrentSelection) { $selectedIndex = $i; break }
    }
    $combo.SelectedIndex = $selectedIndex

    $details = New-Object Windows.Forms.Label
    $details.Location = New-Object Drawing.Point(22, 145)
    $details.Size = New-Object Drawing.Size(640, 125)
    $details.BorderStyle = "FixedSingle"
    $details.Padding = New-Object Windows.Forms.Padding(10)
    $picker.Controls.Add($details)

    $update = {
        $selection = [string]$combo.SelectedItem.Id
        $effectivePath = Get-EffectiveMainModelPath -Profile $BaseProfile -Selection $selection
        $info = Get-MainModelInfo $effectivePath
        $size = Get-MainModelSizeGiB $effectivePath
        $note = if ($info) { [string]$info.Note } else { "FL2VA diffusion model." }
        $modeNote = if ($selection -eq "auto") {
            "The selected profile controls the main model automatically."
        } else {
            "Manual override: installation is allowed even on lower-VRAM GPUs. Runtime success and speed depend on available VRAM/RAM and offload behavior."
        }
        $details.Text = "File: $(Split-Path -Leaf $effectivePath)`nSize: $([Math]::Round($size,1)) GiB`n$note`n$modeNote"
    }
    $combo.Add_SelectedIndexChanged($update)
    & $update

    $ok = New-Object Windows.Forms.Button
    $ok.Text = "Use this main model"
    $ok.DialogResult = [Windows.Forms.DialogResult]::OK
    $ok.Location = New-Object Drawing.Point(454, 300)
    $ok.Size = New-Object Drawing.Size(208, 38)
    $picker.Controls.Add($ok)
    $picker.AcceptButton = $ok

    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = "Cancel"
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $cancel.Location = New-Object Drawing.Point(338, 300)
    $cancel.Size = New-Object Drawing.Size(104, 38)
    $picker.Controls.Add($cancel)
    $picker.CancelButton = $cancel

    $result = $picker.ShowDialog($Owner)
    $selectionResult = if ($result -eq [Windows.Forms.DialogResult]::OK) {
        [PSCustomObject]@{ Accepted = $true; Selection = [string]$combo.SelectedItem.Id }
    } else {
        [PSCustomObject]@{ Accepted = $false; Selection = [string]$CurrentSelection }
    }
    $picker.Dispose()
    return $selectionResult
}

function Get-HardwareReport {
    param([string]$InstallPath)
    $report = & $script:GetHardwareReportBeforeMainModel -InstallPath $InstallPath
    if (-not $report) { return $report }

    try {
        $profile = Get-ProfileById -Id ([string]$report.ProfileId)
        $path = [string]$profile.diffusion_model
        $size = Get-MainModelSizeGiB $path
        $manual = -not ([string]::IsNullOrWhiteSpace($script:SelectedMainModelPath) -or $script:SelectedMainModelPath -eq "auto")
        $status = if ($manual) { "WARN" } else { "PASS" }
        $detail = if ($manual) {
            "Manual FL2VA override. File size and SHA-256 are still verified; the generated workflow is updated to this exact model."
        } else {
            "Automatically follows the selected installation profile."
        }
        $report.Items.Add([PSCustomObject]@{
            Name = "Main model"
            Value = ("{0} ({1:N1} GiB)" -f (Split-Path -Leaf $path), $size)
            Status = $status
            Detail = $detail
        })
        $report | Add-Member -NotePropertyName MainModelPath -NotePropertyValue $path -Force
        $report | Add-Member -NotePropertyName MainModelSelection -NotePropertyValue ([string]$script:SelectedMainModelPath) -Force
    } catch {
        Add-Log "Could not append main model information to hardware report: $($_.Exception.Message)" "WARN"
    }
    return $report
}

function Install-H3Models {
    param([string]$ComfyRoot, [string]$Python, [string]$InstallRoot, $Profile)

    $originalProfilesPath = $script:ProfilesPath
    $selectedProfilesPath = Join-Path $InstallRoot "runtime\profiles-selected.json"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $selectedProfilesPath) | Out-Null

    $payload = Get-Content -LiteralPath $originalProfilesPath -Raw | ConvertFrom-Json
    $target = $payload.profiles | Where-Object { [string]$_.id -eq [string]$Profile.id } | Select-Object -First 1
    if (-not $target) { throw "Could not build selected model profile for $($Profile.id)." }
    $target.diffusion_model = [string]$Profile.diffusion_model
    $payload | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $selectedProfilesPath -Encoding UTF8

    Add-Log "Selected FL2VA main model: $($Profile.diffusion_model)"
    try {
        $script:ProfilesPath = $selectedProfilesPath
        & $script:InstallH3ModelsBeforeMainModel @PSBoundParameters
    } finally {
        $script:ProfilesPath = $originalProfilesPath
    }
}

function Install-WorkflowAndLauncher {
    param([string]$InstallRoot, [string]$ComfyRoot, [string]$VenvPython, $Profile, $Runtime, [int]$GpuIndex)

    & $script:InstallWorkflowAndLauncherBeforeMainModel @PSBoundParameters

    # The browser autoload key includes the selected main model. Changing only the
    # diffusion model therefore triggers one fresh load of the newly generated
    # workflow instead of leaving a stale canvas that points to the old model.
    try {
        $autoloadPath = Join-Path $ComfyRoot "custom_nodes\minimax_h3_workflow_autoload\web\autoload.js"
        if (Test-Path -LiteralPath $autoloadPath) {
            $autoload = Get-Content -LiteralPath $autoloadPath -Raw
            $modelToken = [IO.Path]::GetFileNameWithoutExtension((Split-Path -Leaf ([string]$Profile.diffusion_model))) -replace '[^A-Za-z0-9_.-]', '-'
            $newKey = "minimax-h3-workflow-$($Profile.id)-$modelToken-v3"
            $autoload = [regex]::Replace($autoload, 'minimax-h3-workflow-[^"'']+', $newKey, 1)
            $autoload | Set-Content -LiteralPath $autoloadPath -Encoding UTF8
            Add-Log "Workflow autoload key updated for selected main model: $newKey"
        }
    } catch {
        Add-Log "Could not refresh the model-specific workflow autoload key: $($_.Exception.Message)" "WARN"
    }
}
