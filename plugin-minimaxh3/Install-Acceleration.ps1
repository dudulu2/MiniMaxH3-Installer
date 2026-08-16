#requires -version 5.1

[CmdletBinding()]
param([string]$TargetRoot = "")

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifestPath = Join-Path $scriptRoot "plugin-manifest.json"
$runtimeGuard = Join-Path $scriptRoot "Check-Runtime.ps1"
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$accel = $manifest.validated_acceleration

function Test-MiniMaxRoot([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $Path "ComfyUI\main.py") -PathType Leaf) -and
           (Test-Path -LiteralPath (Join-Path $Path "runtime\venv\Scripts\python.exe") -PathType Leaf)
}

function Resolve-MiniMaxRoot([string]$Requested) {
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        $full = [IO.Path]::GetFullPath($Requested)
        if (-not (Test-MiniMaxRoot $full)) { throw "MiniMax H3 installation not found: $full" }
        return $full
    }
    $candidates = @()
    if ($env:MINIMAX_H3_ROOT) { $candidates += $env:MINIMAX_H3_ROOT }
    $candidates += "D:\MiniMaxH3"
    foreach ($drive in Get-PSDrive -PSProvider FileSystem) { $candidates += (Join-Path $drive.Root "MiniMaxH3") }
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        try {
            $full = [IO.Path]::GetFullPath($candidate)
            if (Test-MiniMaxRoot $full) { return $full }
        } catch { }
    }
    throw "Could not locate the MiniMaxH3-Installer installation."
}

function Write-Log([string]$Message, [string]$Level = "INFO") {
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "HH:mm:ss"), $Level, $Message
    Write-Host $line
    try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 } catch { }
}

function Invoke-Native([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory, [switch]$AllowFailure) {
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
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) { Write-Log ([string]$line) "RUN" }
    }
    if ($code -ne 0 -and -not $AllowFailure) { throw "Command failed with exit code ${code}: $FilePath $($Arguments -join ' ')" }
    return $code
}

function Assert-Runtime([string]$Root) {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $runtimeGuard -TargetRoot $Root
    if ($LASTEXITCODE -ne 0) { throw "Protected CUDA13 runtime check failed." }
}

function Assert-ComfyStopped([string]$Root) {
    $found = @()
    foreach ($p in @(Get-Process python,pythonw -ErrorAction SilentlyContinue)) {
        try {
            if ($p.Path -and $p.Path.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) { $found += $p }
        } catch { }
    }
    if ($found.Count -gt 0) { throw "MiniMax H3 / ComfyUI is running. Stop it before installing acceleration." }
    try {
        $tcp = New-Object Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect("127.0.0.1", 8188, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(250) -and $tcp.Connected) {
            $tcp.Close()
            throw "Port 8188 is active. Stop ComfyUI before installing acceleration."
        }
        $tcp.Close()
    } catch {
        if ($_.Exception.Message -like "Port 8188*") { throw }
    }
}

function Get-FileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-ValidatedWheel([string]$Path, $Spec) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Path
    if ([int64]$item.Length -ne [int64]$Spec.size) { return $false }
    return (Get-FileSha256 $Path) -eq ([string]$Spec.sha256).ToLowerInvariant()
}

function Find-LocalWheel($Spec, [string]$Root) {
    foreach ($dir in @(
        (Join-Path $scriptRoot "wheels\acceleration"),
        (Join-Path $scriptRoot "wheels"),
        (Join-Path $Root "downloads\sageattention-safe"),
        (Join-Path $Root "downloads\plugin-minimaxh3")
    )) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        $candidate = Join-Path $dir ([string]$Spec.filename)
        if (Test-ValidatedWheel $candidate $Spec) { return $candidate }
    }
    return $null
}

function Download-ValidatedWheel($Spec, [string]$Root) {
    $cache = Join-Path $Root "downloads\sageattention-safe"
    New-Item -ItemType Directory -Force -Path $cache | Out-Null
    $dest = Join-Path $cache ([string]$Spec.filename)
    if (Test-ValidatedWheel $dest $Spec) { return $dest }
    Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
    $partial = $dest + ".partial"
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue

    $urls = New-Object System.Collections.Generic.List[string]
    [void]$urls.Add([string]$Spec.url)
    if ([string]$Spec.url -like "https://github.com/*") {
        [void]$urls.Add("https://gh-proxy.com/" + [string]$Spec.url)
        [void]$urls.Add("https://ghfast.top/" + [string]$Spec.url)
        [void]$urls.Add("https://ghproxy.net/" + [string]$Spec.url)
    }

    foreach ($url in $urls) {
        try {
            Write-Log "Downloading validated acceleration wheel: $url"
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $partial -TimeoutSec 180
            if (-not (Test-ValidatedWheel $partial $Spec)) { throw "size/SHA256 verification failed" }
            Move-Item -LiteralPath $partial -Destination $dest -Force
            return $dest
        } catch {
            Write-Log "Acceleration wheel source failed: $($_.Exception.Message)" "WARN"
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        }
    }
    throw "Could not obtain validated wheel: $($Spec.filename)"
}

function Get-DistributionVersion([string]$Python, [string]$Distribution, [string]$Root) {
    # Missing Triton/Sage is the normal first-install state. Do not use
    # importlib.metadata.version(), because PackageNotFoundError can become
    # a terminating NativeCommandError under Windows PowerShell 5.1.
    $safeName = $Distribution.Replace("'", "")
    $code = "import importlib.metadata as m; n='" + $safeName + "'.lower().replace('_','-'); print(next((d.version for d in m.distributions() if ((d.metadata.get('Name') or '').lower().replace('_','-') == n)), ''))"
    Push-Location $Root
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $out = @(& $Python -c $code 2>&1)
        $exitCode = [int]$LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
        Pop-Location
    }
    if ($exitCode -ne 0) {
        $details = (@($out | ForEach-Object { [string]$_ }) -join " | ").Trim()
        throw "Could not inspect installed distribution '$Distribution'. Python output: $details"
    }
    $value = ([string]($out | Select-Object -Last 1)).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    return $value
}
function Install-ExactNoDeps([string]$Python, [string]$Distribution, $Spec, [string]$Root) {
    $current = Get-DistributionVersion $Python $Distribution $Root
    if ($current) {
        if ($current -eq [string]$Spec.version) {
            Write-Log "$Distribution $current already installed; keeping it."
            return
        }
        throw "$Distribution $current is already installed; refusing to replace it with validated $($Spec.version)."
    }
    $wheel = Find-LocalWheel $Spec $Root
    if (-not $wheel) { $wheel = Download-ValidatedWheel $Spec $Root }
    Write-Log "Installing $Distribution $($Spec.version) from validated wheel with --no-deps."
    $null = Invoke-Native $Python @("-m","pip","install","--no-deps","--no-index","--disable-pip-version-check",$wheel) $Root
    $after = Get-DistributionVersion $Python $Distribution $Root
    if ($after -ne [string]$Spec.version) { throw "$Distribution version verification failed; expected $($Spec.version), found '$after'." }
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
    Write-Log "Using bundled acceleration/plugin source resource: $archive ($([Math]::Round($item.Length / 1MB, 2)) MiB)."
    return $archive
}

function Expand-BundledSource([string]$Archive, [string]$StageRoot) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($Archive, $StageRoot)
    $dir = Join-Path $StageRoot ([string]$manifest.source.archive_root)
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        throw "Bundled plugin source resource does not contain root '$($manifest.source.archive_root)'."
    }
    return $dir
}

function Backup-And-CopyNode([string]$Source, [string]$Destination, [string]$BackupRoot) {
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw "Missing acceleration node source: $Source" }
    if (Test-Path -LiteralPath $Destination) {
        New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
        $backup = Join-Path $BackupRoot (Split-Path -Leaf $Destination)
        Move-Item -LiteralPath $Destination -Destination $backup -Force
        Write-Log "Backed up existing acceleration node: $Destination"
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
    Write-Log "Installed acceleration node: $(Split-Path -Leaf $Destination)"
}

function Invoke-SageSmoke([string]$Python, [string]$Root) {
    $code = @'
import importlib.metadata, torch
import triton
from sageattention import sageattn
assert torch.__version__ == "2.10.0+cu130"
assert torch.version.cuda == "13.0"
assert importlib.metadata.version("triton-windows") == "3.6.0.post25"
assert importlib.metadata.version("sageattention") == "2.2.0+cu130torch2.10.0andhigher.post6"
assert torch.cuda.is_available()
for dtype in (torch.float16, torch.bfloat16):
    q = torch.randn(1, 56, 32, 128, device="cuda", dtype=dtype)
    k = torch.randn_like(q)
    v = torch.randn_like(q)
    out = sageattn(q, k, v, tensor_layout="HND", is_causal=False, smooth_k=False)
    assert torch.isfinite(out).all().item()
torch.cuda.synchronize()
print("SAGE_ACCEL_SMOKE_OK")
'@
    $tmp = Join-Path $Root ("runtime\sage-smoke-" + [Guid]::NewGuid().ToString("N") + ".py")
    try {
        $code | Set-Content -LiteralPath $tmp -Encoding UTF8
        $null = Invoke-Native $Python @($tmp) $Root
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

$root = Resolve-MiniMaxRoot $TargetRoot
$python = Join-Path $root "runtime\venv\Scripts\python.exe"
$comfy = Join-Path $root "ComfyUI"
$workflows = Join-Path $comfy "user\default\workflows"
$customNodes = Join-Path $comfy "custom_nodes"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logDir = Join-Path $root "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$script:LogPath = Join-Path $logDir ("plugin-minimaxh3-acceleration-" + $stamp + ".log")
$stage = Join-Path $root ("runtime\plugin-minimaxh3-accel-stage-" + [Guid]::NewGuid().ToString("N"))
$backup = Join-Path $root ("plugin-backups\plugin-minimaxh3-acceleration-" + $stamp)

try {
    Write-Log "Installing validated TE-Speed + Sage acceleration for the current MiniMaxH3-Installer CUDA13 runtime."
    Assert-ComfyStopped $root
    Assert-Runtime $root

    $archive = Get-BundledSourceArchive
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $sourceRoot = Expand-BundledSource $archive $stage
    $teSource = Join-Path $sourceRoot "TE-Speed-MiniMaxH3-OSS"
    $sageSource = Join-Path $sourceRoot "SageAttention-MiniMaxH3-Safe"
    $tePatch = Join-Path $teSource "patch_model.py"
    $teWorkflow = Join-Path $teSource "tespeed_workflow_patch.py"

    if (-not (Test-Path -LiteralPath $tePatch -PathType Leaf)) { throw "Validated TE-Speed V3 patch_model.py is missing from bundled source." }
    if (-not (Test-Path -LiteralPath $teWorkflow -PathType Leaf)) { throw "Validated TE-Speed workflow patcher is missing from bundled source." }

    Write-Log "Running TE-Speed V3 core preflight before modifying anything."
    $null = Invoke-Native $python @($tePatch,"--preflight","--comfy-ui",$comfy) $root

    Install-ExactNoDeps $python "triton-windows" $accel.sageattention.triton_windows $root
    Install-ExactNoDeps $python "sageattention" $accel.sageattention.sageattention $root
    Assert-Runtime $root

    Backup-And-CopyNode $teSource (Join-Path $customNodes "TE-Speed-MiniMaxH3-OSS") $backup
    Backup-And-CopyNode $sageSource (Join-Path $customNodes "SageAttention-MiniMaxH3-Safe") $backup

    Write-Log "Applying validated TE-Speed V3 safe block_loop patch."
    $null = Invoke-Native $python @($tePatch,"--comfy-ui",$comfy) $root
    $null = Invoke-Native $python @($tePatch,"--check","--comfy-ui",$comfy) $root

    if (Test-Path -LiteralPath $workflows -PathType Container) {
        Write-Log "Applying validated TE-Speed safe workflow wiring to current H3 workflows."
        $workflowCode = Invoke-Native $python @($teWorkflow,"--add",$workflows) $root -AllowFailure
        if ($workflowCode -ne 0) {
            Write-Log "TE-Speed workflow patcher left one or more ambiguous workflows untouched." "WARN"
        }
    } else {
        Write-Log "Workflow directory not found; TE-Speed core/node installed without workflow wiring." "WARN"
    }

    Assert-Runtime $root
    Write-Log "Running real CUDA SageAttention FP16/BF16 smoke test."
    Invoke-SageSmoke $python $root
    Assert-Runtime $root

    $state = [ordered]@{
        installed_at = (Get-Date).ToString("o")
        te_speed = [ordered]@{ plugin = "TE-Speed-MiniMaxH3-OSS"; patch_version = 3 }
        sageattention = [ordered]@{
            plugin = "SageAttention-MiniMaxH3-Safe"
            triton_windows = [string]$accel.sageattention.triton_windows.version
            sageattention = [string]$accel.sageattention.sageattention.version
        }
        source_mode = [string]$manifest.source.mode
        source_resource = [string]$manifest.source.resource
        backup = $backup
        log = $script:LogPath
    }
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $root "runtime\plugin-minimaxh3-acceleration.json") -Encoding UTF8

    Write-Log "Validated TE-Speed + Sage acceleration installation completed successfully."
    Write-Host ""
    Write-Host "TE-Speed + Sage acceleration installation complete." -ForegroundColor Green
    Write-Host "Log: $script:LogPath"
    exit 0
} catch {
    Write-Log $_.Exception.Message "ERROR"
    Write-Host ""
    Write-Host ("Acceleration installation failed: " + $_.Exception.Message) -ForegroundColor Red
    Write-Host "Log: $script:LogPath"
    exit 1
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
