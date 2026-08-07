$script:InstallerReleaseVersion = "1.0.0"

$baseCommand = Get-Command Install-WorkflowAndLauncher -CommandType Function -ErrorAction SilentlyContinue
if (-not $baseCommand) {
    try { Add-Log "Release version metadata hook was skipped because Install-WorkflowAndLauncher is unavailable." "WARN" } catch { }
    return
}
$script:InstallWorkflowAndLauncherBase = $baseCommand.ScriptBlock

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

    try {
        $manifestPath = Join-Path $InstallRoot ".minimax-h3-install.json"
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            Add-Log "Release version metadata was not written because the installation manifest is missing." "WARN"
            return
        }

        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $manifest.installer_version = [string]$script:InstallerReleaseVersion
        $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        Add-Log "Installer release version recorded: $($script:InstallerReleaseVersion)"
    } catch {
        Add-Log ("Could not record installer release version; installation remains usable. " + $_.Exception.Message) "WARN"
    }
}
