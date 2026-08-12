#requires -version 5.1

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$source = Join-Path $root "Install-MiniMaxH3.ps1"
$torchOverride = Join-Path $root "assets\local_torch_wheels.ps1"
$downloadRouteFix = Join-Path $root "assets\download_route_fix.ps1"
$cancellationOverride = Join-Path $root "assets\install_cancellation.ps1"
$mainModelSelector = Join-Path $root "assets\main_model_selector.ps1"
$runtimeSelector = Join-Path $root "assets\runtime_channel_selector.ps1"
$workflowOverride = Join-Path $root "assets\workflow_profile_fix.ps1"
$releaseVersionOverride = Join-Path $root "assets\release_version_override.ps1"
$patched = Join-Path $root ".Install-MiniMaxH3.runtime.ps1"

if (-not (Test-Path -LiteralPath $source)) { throw "Installer script is missing: $source" }
if (-not (Test-Path -LiteralPath $torchOverride)) { throw "Local wheel support script is missing: $torchOverride" }
if (-not (Test-Path -LiteralPath $downloadRouteFix)) { throw "Download route hardening script is missing: $downloadRouteFix" }
if (-not (Test-Path -LiteralPath $cancellationOverride)) { throw "Installation cancellation script is missing: $cancellationOverride" }
if (-not (Test-Path -LiteralPath $mainModelSelector)) { throw "Main model selector script is missing: $mainModelSelector" }
if (-not (Test-Path -LiteralPath $runtimeSelector)) { throw "Runtime channel selector script is missing: $runtimeSelector" }
if (-not (Test-Path -LiteralPath $workflowOverride)) { throw "Workflow profile fix script is missing: $workflowOverride" }

$text = Get-Content -LiteralPath $source -Raw
$needle = '. (Join-Path $script:AssetsRoot "hardware_profiles_install.ps1")'
$replacementLines = @(
    $needle,
    '. (Join-Path $script:AssetsRoot "local_torch_wheels.ps1")',
    '. (Join-Path $script:AssetsRoot "download_route_fix.ps1")',
    '. (Join-Path $script:AssetsRoot "install_cancellation.ps1")',
    '. (Join-Path $script:AssetsRoot "main_model_selector.ps1")',
    '. (Join-Path $script:AssetsRoot "runtime_channel_selector.ps1")',
    '. (Join-Path $script:AssetsRoot "workflow_profile_fix.ps1")'
)
if (Test-Path -LiteralPath $releaseVersionOverride) {
    $replacementLines += '. (Join-Path $script:AssetsRoot "release_version_override.ps1")'
}
$replacement = $replacementLines -join [Environment]::NewLine
if (-not $text.Contains($needle)) { throw "Could not locate the installer extension point." }
$text = $text.Replace($needle, $replacement)

# Add the stop button only after the stage label exists, then wrap the normal
# Install / Repair click so cancellation state is reset before every run and the
# title-bar close button is guaranteed to return after the run finishes/stops.
$uiNeedle = '$form.Controls.Add($lblStage)'
$uiReplacement = $uiNeedle + [Environment]::NewLine + 'Initialize-InstallCancellationUI'
if (-not $text.Contains($uiNeedle)) { throw "Could not locate the installer status UI extension point." }
$text = $text.Replace($uiNeedle, $uiReplacement)

$clickNeedle = '$btnInstall.Add_Click({ Invoke-Install })'
$clickReplacement = '$btnInstall.Add_Click({ Begin-InstallCancellationUI; try { Invoke-Install } finally { Complete-InstallCancellationUI } })'
if (-not $text.Contains($clickNeedle)) { throw "Could not locate the Install / Repair click handler." }
$text = $text.Replace($clickNeedle, $clickReplacement)

# Older installs used a profile-only browser key. The main-model layer now
# rewrites the generated key to include the exact diffusion model, so this
# compatibility replacement is harmless and still refreshes older profile keys.
$text = $text.Replace('minimax-h3-workflow-$($Profile.id)-v1', 'minimax-h3-workflow-$($Profile.id)-v2')
$text | Set-Content -LiteralPath $patched -Encoding UTF8

try {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File $patched
    exit $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $patched -Force -ErrorAction SilentlyContinue
}
