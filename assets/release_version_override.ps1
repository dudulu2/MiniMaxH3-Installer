if (-not $script:InstallerReleaseVersion) {
    $script:InstallerReleaseVersion = "1.0.0"
}

$script:InstallWorkflowAndLauncherBase = ${function:Install-WorkflowAndLauncher}
if (-not $script:InstallWorkflowAndLauncherBase) {
    throw "Install-WorkflowAndLauncher is not available for release version wrapping."
}

function Install-WorkflowAndLauncher {
    param(
        [string]$InstallRoot,
        [string]$ComfyRoot,
        [string]$VenvPython,
        $Profile,
        $Runtime,
        [int]$GpuIndex
    )

    & $script:InstallWorkflowAndLauncherBase @PSBoundParameters

    $manifestPath = Join-Path $InstallRoot ".minimax-h3-install.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Installation manifest was not created: $manifestPath"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.installer_version = [string]$script:InstallerReleaseVersion
    $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Add-Log "Installer release version recorded: $($script:InstallerReleaseVersion)"
}
