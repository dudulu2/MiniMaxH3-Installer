#requires -version 5.1

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:InstallerReleaseVersion = "1.0.0"
$source = Join-Path $root "Install-MiniMaxH3.ps1"
$torchOverride = Join-Path $root "assets\local_torch_wheels.ps1"
$runtimeSelector = Join-Path $root "assets\runtime_channel_selector.ps1"
$workflowOverride = Join-Path $root "assets\workflow_profile_fix.ps1"
$releaseVersionOverride = Join-Path $root "assets\release_version_override.ps1"
$patched = Join-Path $root ".Install-MiniMaxH3.runtime.ps1"

if (-not (Test-Path -LiteralPath $source)) { throw "Installer script is missing: $source" }
if (-not (Test-Path -LiteralPath $torchOverride)) { throw "Local wheel support script is missing: $torchOverride" }
if (-not (Test-Path -LiteralPath $runtimeSelector)) { throw "Runtime channel selector script is missing: $runtimeSelector" }
if (-not (Test-Path -LiteralPath $workflowOverride)) { throw "Workflow profile fix script is missing: $workflowOverride" }
if (-not (Test-Path -LiteralPath $releaseVersionOverride)) { throw "Release version override script is missing: $releaseVersionOverride" }

$text = Get-Content -LiteralPath $source -Raw
$needle = '. (Join-Path $script:AssetsRoot "hardware_profiles_install.ps1")'
$replacement = $needle + [Environment]::NewLine +
    '. (Join-Path $script:AssetsRoot "local_torch_wheels.ps1")' + [Environment]::NewLine +
    '. (Join-Path $script:AssetsRoot "runtime_channel_selector.ps1")' + [Environment]::NewLine +
    '. (Join-Path $script:AssetsRoot "workflow_profile_fix.ps1")' + [Environment]::NewLine +
    '. (Join-Path $script:AssetsRoot "release_version_override.ps1")'
if (-not $text.Contains($needle)) { throw "Could not locate the installer extension point." }
$text = $text.Replace($needle, $replacement)

# Force one new first-run load after this workflow metadata correction. The key
# remains profile-specific, so Compatibility, Balanced, and Quality do not share
# browser state.
$text = $text.Replace('minimax-h3-workflow-$($Profile.id)-v1', 'minimax-h3-workflow-$($Profile.id)-v2')
$text | Set-Content -LiteralPath $patched -Encoding UTF8

try {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File $patched
    exit $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $patched -Force -ErrorAction SilentlyContinue
}
