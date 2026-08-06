#requires -version 5.1

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$source = Join-Path $root "Install-MiniMaxH3.ps1"
$override = Join-Path $root "assets\local_torch_wheels.ps1"
$patched = Join-Path $root ".Install-MiniMaxH3.runtime.ps1"

if (-not (Test-Path -LiteralPath $source)) { throw "Installer script is missing: $source" }
if (-not (Test-Path -LiteralPath $override)) { throw "Local wheel support script is missing: $override" }

$text = Get-Content -LiteralPath $source -Raw
$needle = '. (Join-Path $script:AssetsRoot "hardware_profiles_install.ps1")'
$replacement = $needle + [Environment]::NewLine + '. (Join-Path $script:AssetsRoot "local_torch_wheels.ps1")'
if (-not $text.Contains($needle)) { throw "Could not locate the installer extension point." }
$text.Replace($needle, $replacement) | Set-Content -LiteralPath $patched -Encoding UTF8

try {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File $patched
    exit $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $patched -Force -ErrorAction SilentlyContinue
}
