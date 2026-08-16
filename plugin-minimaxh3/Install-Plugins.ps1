#requires -version 5.1

[CmdletBinding()]
param([string]$TargetRoot = "")

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifestPath = Join-Path $scriptRoot "plugin-manifest.json"
$runtimeGuard = Join-Path $scriptRoot "Check-Runtime.ps1"
$wheelhouse = Join-Path $scriptRoot "wheels\dependencies"

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Missing plugin manifest: $manifestPath" }
if (-not (Test-Path -LiteralPath $runtimeGuard -PathType Leaf)) { throw "Missing runtime guard: $runtimeGuard" }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$target = $manifest.target

function Test-MiniMaxRoot([string]$Path) {
    return (
        -not [string]::IsNullOrWhiteSpace($Path) -and
        (Test-Path -LiteralPath (Join-Path $Path "ComfyUI\main.py") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Path "runtime\venv\Scripts\python.exe") -PathType Leaf)
    )
}

function Resolve-MiniMaxRoot([string]$RequestedRoot) {
    if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
        $full = [IO.Path]::GetFullPath($RequestedRoot)
        if (-not (Test-MiniMaxRoot $full)) { throw "MiniMax H3 installation was not found at: $full" }
        return $full
    }
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:MINIMAX_H3_ROOT)) { $candidates += $env:MINIMAX_H3_ROOT }
    $candidates += "D:\MiniMaxH3"
    foreach ($drive in Get-PSDrive -PSProvider FileSystem) { $candidates += (Join-Path $drive.Root "MiniMaxH3") }
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        try {
            $full = [IO.Path]::GetFullPath($candidate)
            if (Test-MiniMaxRoot $full) { return $full }
        } catch { }
    }
    throw "Could not find the MiniMaxH3-Installer installation."
}

function Write-InstallLog([string]$Message, [string]$Level = "INFO") {
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "HH:mm:ss"), $Level, $Message
    Write-Host $line
    try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 } catch { }
}

function Invoke-Native([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory) {
    Push-Location $WorkingDirectory
    try {
        $old = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $output = @(& $FilePath @Arguments 2>&1)
        $code = [int]$LASTEXITCODE
        $ErrorActionPreference = $old
    } finally {
        Pop-Location
    }
    foreach ($line in $output) {
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) { Write-InstallLog ([string]$line) "PIP" }
    }
    return $code
}

function Assert-Runtime([string]$Root) {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $runtimeGuard -TargetRoot $Root
    if ($LASTEXITCODE -ne 0) { throw "Current MiniMaxH3-Installer CUDA13 runtime check failed." }
}

function Assert-ComfyStopped([string]$Root) {
    $matches = @()
    $pidFile = Join-Path $Root "runtime\comfyui.pid"
    if (Test-Path -LiteralPath $pidFile) {
        $raw = (Get-Content -LiteralPath $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
        $pidValue = 0
        if ([int]::TryParse($raw, [ref]$pidValue) -and $pidValue -gt 0) {
            $p = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
            if ($p) {
                try { if ($p.Path -and $p.Path.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) { $matches += $p } } catch { }
            }
        }
    }
    foreach ($p in @(Get-Process python,pythonw -ErrorAction SilentlyContinue)) {
        try {
            if ($p.Path -and $p.Path.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) {
                if (-not ($matches | Where-Object { $_.Id -eq $p.Id })) { $matches += $p }
            }
        } catch { }
    }
    if ($matches.Count -gt 0) {
        $ids = ($matches | ForEach-Object { $_.Id }) -join ", "
        throw "MiniMax H3 / ComfyUI is still running from this installation (PID: $ids). Run 'Stop MiniMax H3.bat' first."
    }
}

function Get-BundledSourceArchive {
    $source = $manifest.source
    if ([string]$source.mode -ne "bundled_resource") { throw "Unsupported plugin source mode: $($source.mode)" }
    $archive = Join-Path $scriptRoot ([string]$source.resource)
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
        throw "Bundled plugin source resource is missing: $archive. Re-download the complete plugin-minimaxh3 package."
    }
    $item = Get-Item -LiteralPath $archive
    if ($source.PSObject.Properties.Name -contains "size") {
        if ([int64]$item.Length -ne [int64]$source.size) {
            throw "Bundled plugin source resource size is invalid: $($item.Length) bytes; expected $($source.size)."
        }
    }
    Write-InstallLog "Using bundled plugin source resource: $archive ($([Math]::Round($item.Length / 1MB, 2)) MiB)."
    return $archive
}

function Resolve-SourcePluginRoot([string]$Archive, [string]$StageRoot) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($Archive, $StageRoot)
    $candidate = Join-Path $StageRoot ([string]$manifest.source.archive_root)
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
        throw "Bundled plugin source resource does not contain root '$($manifest.source.archive_root)'."
    }
    return $candidate
}

function Write-RuntimeConstraints([string]$Path) {
    @"
torch==$($target.torch)
torchvision==$($target.torchvision)
torchaudio==$($target.torchaudio)
comfyui-frontend-package==$($target.frontend)
comfyui-workflow-templates==$($target.workflow_templates)
comfyui-embedded-docs==$($target.embedded_docs)
comfy-kitchen==$($target.comfy_kitchen)
comfy-aimdo==$($target.comfy_aimdo)
"@ | Set-Content -LiteralPath $Path -Encoding ASCII
}

function Install-RequirementsSafe([string]$Python, [string]$Requirements, [string]$Constraints, [string]$Label, [string]$Root) {
    if (-not (Test-Path -LiteralPath $Requirements -PathType Leaf)) {
        Write-InstallLog "No requirements.txt for $Label; dependency step skipped."
        return
    }

    $localWheels = @()
    if (Test-Path -LiteralPath $wheelhouse -PathType Container) {
        $localWheels = @(Get-ChildItem -LiteralPath $wheelhouse -Filter "*.whl" -File -ErrorAction SilentlyContinue)
    }

    if ($localWheels.Count -gt 0) {
        Write-InstallLog "Trying local dependency wheelhouse first for $Label ($($localWheels.Count) wheels)."
        $localArgs = @(
            "-m", "pip", "install", "-r", $Requirements, "-c", $Constraints,
            "--no-index", "--find-links", $wheelhouse,
            "--upgrade-strategy", "only-if-needed", "--prefer-binary", "--disable-pip-version-check"
        )
        $localCode = Invoke-Native $Python $localArgs $Root
        if ($localCode -eq 0) {
            Write-InstallLog "Local wheelhouse satisfied $Label without network access."
            return
        }
        Write-InstallLog "Local wheelhouse is incomplete for $Label; using network fallback." "WARN"
    }

    foreach ($index in @("https://pypi.tuna.tsinghua.edu.cn/simple", "https://pypi.org/simple")) {
        Write-InstallLog "Installing dependencies for $Label from $index"
        $args = @(
            "-m", "pip", "install", "-r", $Requirements, "-c", $Constraints,
            "--index-url", $index,
            "--extra-index-url", "https://download.pytorch.org/whl/cu130",
            "--upgrade-strategy", "only-if-needed", "--prefer-binary",
            "--timeout", "120", "--retries", "3", "--disable-pip-version-check"
        )
        $code = Invoke-Native $Python $args $Root
        if ($code -eq 0) { return }
        Write-InstallLog "Dependency source failed for ${Label}: $index" "WARN"
    }
    throw "Dependency installation failed for $Label."
}

$root = Resolve-MiniMaxRoot $TargetRoot
$logDir = Join-Path $root "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$script:LogPath = Join-Path $logDir ("plugin-minimaxh3-" + $stamp + ".log")
$stageRoot = Join-Path $root ("runtime\plugin-minimaxh3-stage-" + [Guid]::NewGuid().ToString("N"))
$constraints = Join-Path $root ("runtime\plugin-minimaxh3-constraints-" + [Guid]::NewGuid().ToString("N") + ".txt")
$backupRoot = Join-Path $root ("plugin-backups\plugin-minimaxh3-" + $stamp)
$targetNodes = Join-Path $root "ComfyUI\custom_nodes"
$python = Join-Path $root "runtime\venv\Scripts\python.exe"
$copied = @()

try {
    Write-InstallLog "Target root: $root"
    Write-InstallLog "Target runtime: Python $($target.python); torch $($target.torch); CUDA $($target.cuda_prefix)."
    Assert-ComfyStopped $root
    Assert-Runtime $root

    Write-RuntimeConstraints $constraints
    $archive = Get-BundledSourceArchive
    New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null
    $sourceRoot = Resolve-SourcePluginRoot $archive $stageRoot
    Write-InstallLog "Bundled plugin source root: $sourceRoot"

    # Resolve dependencies before changing custom_nodes.
    foreach ($pluginName in @($manifest.managed_plugins)) {
        $sourcePlugin = Join-Path $sourceRoot ([string]$pluginName)
        if (-not (Test-Path -LiteralPath $sourcePlugin -PathType Container)) { throw "Bundled source is missing plugin: $pluginName" }
        Install-RequirementsSafe $python (Join-Path $sourcePlugin "requirements.txt") $constraints ([string]$pluginName) $root
    }

    Assert-Runtime $root

    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    foreach ($pluginName in @($manifest.managed_plugins)) {
        $name = [string]$pluginName
        $sourcePlugin = Join-Path $sourceRoot $name
        $destination = Join-Path $targetNodes $name
        $backup = Join-Path $backupRoot $name

        if (Test-Path -LiteralPath $destination) {
            Move-Item -LiteralPath $destination -Destination $backup -Force
            Write-InstallLog "Backed up existing plugin: $name"
        }
        try {
            Copy-Item -LiteralPath $sourcePlugin -Destination $destination -Recurse -Force
            $copied += $name
            Write-InstallLog "Installed plugin: $name"
        } catch {
            Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $backup) { Move-Item -LiteralPath $backup -Destination $destination -Force }
            throw "Failed to install plugin $name`: $($_.Exception.Message)"
        }
    }

    foreach ($name in $copied) {
        $pluginPath = Join-Path $targetNodes $name
        $compileCode = Invoke-Native $python @("-m", "compileall", "-q", $pluginPath) $root
        if ($compileCode -ne 0) { throw "Python compile check failed for plugin: $name" }
    }

    Assert-Runtime $root
    $pipCheck = Invoke-Native $python @("-m", "pip", "check") $root
    if ($pipCheck -ne 0) { throw "pip check failed after plugin installation." }

    $state = [ordered]@{
        installed_at = (Get-Date).ToString("o")
        target_root = $root
        source_mode = [string]$manifest.source.mode
        source_resource = [string]$manifest.source.resource
        snapshot_commit = [string]$manifest.source.snapshot_provenance.commit
        plugins = @($manifest.managed_plugins)
        protected_runtime = [ordered]@{
            python = [string]$target.python
            torch = [string]$target.torch
            torchvision = [string]$target.torchvision
            torchaudio = [string]$target.torchaudio
            cuda = [string]$target.cuda_prefix
        }
        backup = $backupRoot
        log = $script:LogPath
    }
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $root "runtime\plugin-minimaxh3.json") -Encoding UTF8

    Write-InstallLog "Base plugin installation completed successfully. Protected runtime is unchanged."
    Write-Host ""
    Write-Host "Base plugin installation complete." -ForegroundColor Green
    Write-Host "Installed plugins: $($copied -join ', ')"
    Write-Host "Log: $script:LogPath"
    exit 0
} catch {
    Write-InstallLog $_.Exception.Message "ERROR"
    Write-Host ""
    Write-Host ("Plugin installation failed: " + $_.Exception.Message) -ForegroundColor Red
    Write-Host "Log: $script:LogPath"
    exit 1
} finally {
    Remove-Item -LiteralPath $constraints -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
}
