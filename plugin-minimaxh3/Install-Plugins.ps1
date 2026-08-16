#requires -version 5.1

[CmdletBinding()]
param(
    [string]$TargetRoot = ""
)

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

function Test-MiniMaxRoot {
    param([string]$Path)
    return (
        -not [string]::IsNullOrWhiteSpace($Path) -and
        (Test-Path -LiteralPath (Join-Path $Path "ComfyUI\main.py") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Path "runtime\venv\Scripts\python.exe") -PathType Leaf)
    )
}

function Resolve-MiniMaxRoot {
    param([string]$RequestedRoot)
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

function Write-InstallLog {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "HH:mm:ss"), $Level, $Message
    Write-Host $line
    try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 } catch { }
}

function Invoke-Native {
    param([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory)
    $old = $ErrorActionPreference
    Push-Location $WorkingDirectory
    try {
        $ErrorActionPreference = "Continue"
        $output = @(& $FilePath @Arguments 2>&1)
        $code = [int]$LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
        Pop-Location
    }
    foreach ($line in $output) {
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) { Write-InstallLog ([string]$line) "PIP" }
    }
    return $code
}

function Assert-Runtime {
    param([string]$Root)
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $runtimeGuard -TargetRoot $Root
    if ($LASTEXITCODE -ne 0) { throw "Current MiniMaxH3-Installer CUDA13 runtime check failed." }
}

function Assert-ComfyStopped {
    param([string]$Root)
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

function Get-SourceArchive {
    param([string]$Root)
    $source = $manifest.source
    $cacheDir = Join-Path $Root "downloads\plugin-minimaxh3"
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    $cacheFile = Join-Path $cacheDir ("MiniMax-H3-OneClick-" + [string]$source.commit + ".zip")

    $localCandidates = @(
        (Join-Path $scriptRoot "plugin-source.zip"),
        (Join-Path $scriptRoot "source\plugin-source.zip"),
        $cacheFile
    )
    foreach ($candidate in $localCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            Write-InstallLog "Using local plugin source archive: $candidate"
            return $candidate
        }
    }

    Write-InstallLog "Local plugin source archive not found; downloading pinned source commit $($source.commit)." "WARN"
    $partial = $cacheFile + ".partial"
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest -UseBasicParsing -Uri ([string]$source.archive_url) -OutFile $partial -TimeoutSec 120
    Move-Item -LiteralPath $partial -Destination $cacheFile -Force
    return $cacheFile
}

function Resolve-SourcePluginRoot {
    param([string]$Archive, [string]$StageRoot)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($Archive, $StageRoot)
    $candidate = Get-ChildItem -LiteralPath $StageRoot -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq ([string]$manifest.source.subdirectory) } |
        Select-Object -First 1
    if (-not $candidate) { throw "Pinned source archive does not contain $($manifest.source.subdirectory)." }
    return $candidate.FullName
}

function Write-RuntimeConstraints {
    param([string]$Path)
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

function Install-RequirementsSafe {
    param([string]$Python, [string]$Requirements, [string]$Constraints, [string]$Label, [string]$Root)
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
        $localCode = Invoke-Native -FilePath $Python -Arguments $localArgs -WorkingDirectory $Root
        if ($localCode -eq 0) {
            Write-InstallLog "Local wheelhouse satisfied $Label without network access."
            return
        }
        Write-InstallLog "Local wheelhouse is incomplete for $Label; using network fallback." "WARN"
    }

    $sources = @(
        "https://pypi.tuna.tsinghua.edu.cn/simple",
        "https://pypi.org/simple"
    )
    foreach ($index in $sources) {
        Write-InstallLog "Installing dependencies for $Label from $index"
        $args = @(
            "-m", "pip", "install", "-r", $Requirements, "-c", $Constraints,
            "--index-url", $index,
            "--extra-index-url", "https://download.pytorch.org/whl/cu130",
            "--upgrade-strategy", "only-if-needed", "--prefer-binary",
            "--timeout", "120", "--retries", "3", "--disable-pip-version-check"
        )
        $code = Invoke-Native -FilePath $Python -Arguments $args -WorkingDirectory $Root
        if ($code -eq 0) { return }
        Write-InstallLog "Dependency source failed for $Label: $index" "WARN"
    }
    throw "Dependency installation failed for $Label."
}

$root = Resolve-MiniMaxRoot -RequestedRoot $TargetRoot
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
    Assert-ComfyStopped -Root $root
    Assert-Runtime -Root $root

    Write-RuntimeConstraints -Path $constraints
    $archive = Get-SourceArchive -Root $root
    New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null
    $sourceRoot = Resolve-SourcePluginRoot -Archive $archive -StageRoot $stageRoot
    Write-InstallLog "Pinned plugin source root: $sourceRoot"

    # Dependency phase first. If resolution fails, custom_nodes has not been changed yet.
    foreach ($pluginName in @($manifest.managed_plugins)) {
        $sourcePlugin = Join-Path $sourceRoot ([string]$pluginName)
        if (-not (Test-Path -LiteralPath $sourcePlugin -PathType Container)) { throw "Pinned source is missing plugin: $pluginName" }
        Install-RequirementsSafe -Python $python -Requirements (Join-Path $sourcePlugin "requirements.txt") -Constraints $constraints -Label ([string]$pluginName) -Root $root
    }

    # Prove plugin dependencies did not change the protected CUDA runtime.
    Assert-Runtime -Root $root

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
        $compileCode = Invoke-Native -FilePath $python -Arguments @("-m", "compileall", "-q", $pluginPath) -WorkingDirectory $root
        if ($compileCode -ne 0) { throw "Python compile check failed for plugin: $name" }
    }

    Assert-Runtime -Root $root
    $pipCheck = Invoke-Native -FilePath $python -Arguments @("-m", "pip", "check") -WorkingDirectory $root
    if ($pipCheck -ne 0) { throw "pip check failed after plugin installation." }

    $state = [ordered]@{
        installed_at = (Get-Date).ToString("o")
        target_root = $root
        source_commit = [string]$manifest.source.commit
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

    Write-InstallLog "Plugin installation completed successfully. Protected runtime is unchanged."
    Write-Host ""
    Write-Host "plugin-minimaxh3 installation complete." -ForegroundColor Green
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
