#requires -version 5.1

[CmdletBinding()]
param([string]$TargetRoot = "")

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# This installer intentionally contains code only.
# No plugin ZIP, wheelhouse, OneClick runtime, or bundled binary resources are shipped with it.

$ExpectedPython = "3.10.11"
$ExpectedTorch = "2.10.0+cu130"
$ExpectedTorchVision = "0.25.0+cu130"
$ExpectedTorchAudio = "2.10.0+cu130"
$ExpectedCuda = "13.0"
$ExpectedUrllib3 = "2.7.0"
$ValidatedSourceCommit = "2f6e2b4ae45852d2f8355bfea338e1ab80676964"

$RepoPlugins = @(
    [pscustomobject]@{ Name = "comfyui_essentials"; Repo = "cubiq/ComfyUI_essentials"; Commit = "9d9f4bedfc9f0321c19faf71855e228c93bd0dc9" },
    [pscustomobject]@{ Name = "comfyui-crystools"; Repo = "crystian/ComfyUI-Crystools"; Commit = "2f18256c5b5063937106f29a8e0a7db3ae3869b7" },
    [pscustomobject]@{ Name = "comfyui-custom-scripts"; Repo = "pythongosssss/ComfyUI-Custom-Scripts"; Commit = "609f3afaa74b2f88ef9ce8d939626065e3247469" },
    [pscustomobject]@{ Name = "comfyui-manager"; Repo = "Comfy-Org/ComfyUI-Manager"; Commit = "fe1193c0c8168904e32d814190ba7f2ba2ad7581" },
    [pscustomobject]@{ Name = "comfyui-VideoHelperSuite"; Repo = "Kosinkadink/ComfyUI-VideoHelperSuite"; Commit = "4ee72c065db22c9d96c2427954dc69e7b908444b" },
    [pscustomobject]@{ Name = "rgthree-comfy"; Repo = "rgthree/rgthree-comfy"; Commit = "6b76ee6f2c5a007710b5a16f97c94330d6ecc871" },
    [pscustomobject]@{ Name = "comfyui-minimax-h3-audio-T8"; Repo = "T8mars/comfyui-minimax-h3-audio-T8"; Commit = "4174fd49e3e37e6787d1505749dc44a8be309209" },
    [pscustomobject]@{ Name = "comfyui-minimax-h3-blockcache-T8"; Repo = "T8mars/comfyui-minimax-h3-blockcache-T8"; Commit = "3cd968f11a0b717683b6abb0477c43fe175cb608" }
)

$CustomSources = @(
    [pscustomobject]@{
        Name = "ComfyUI-MiniMaxH3-AVCache-CN"
        Repo = "dudulu2/MiniMax-H3-OneClick"
        Commit = $ValidatedSourceCommit
        Prefix = "step2-plugin-pack/ComfyUI-MiniMaxH3-AVCache-CN"
        Files = @("LICENSE", "NOTICE", "README.md", "__init__.py", "nodes.py")
    },
    [pscustomobject]@{
        Name = "TE-Speed-MiniMaxH3-OSS"
        Repo = "dudulu2/MiniMax-H3-OneClick"
        Commit = $ValidatedSourceCommit
        Prefix = "step2-plugin-pack/TE-Speed-MiniMaxH3-OSS"
        Files = @("Example_Workflow.json", "__init__.py", "nodes.py", "patch_model.py", "tespeed_workflow_patch.py")
    },
    [pscustomobject]@{
        Name = "SageAttention-MiniMaxH3-Safe"
        Repo = "dudulu2/MiniMax-H3-OneClick"
        Commit = $ValidatedSourceCommit
        Prefix = "step2-plugin-pack/SageAttention-MiniMaxH3-Safe"
        Files = @("INSTALLER-MANIFEST.json", "__init__.py", "nodes.py")
    }
)

$TritonSpec = [pscustomobject]@{
    Distribution = "triton-windows"
    Version = "3.6.0.post25"
    FileName = "triton_windows-3.6.0.post25-cp310-cp310-win_amd64.whl"
    Size = [int64]47380144
    Sha256 = "8c45b7f83eecb71c3aeded1da7914af0050bddda710f47a2cfae936d55fae0ca"
    Urls = @(
        "https://files.pythonhosted.org/packages/ba/ca/6d38c374a427a360dc4c7687f15fdb217dd4ca3bf87d0ad31f9818e22188/triton_windows-3.6.0.post25-cp310-cp310-win_amd64.whl"
    )
}

$SageSpec = [pscustomobject]@{
    Distribution = "sageattention"
    Version = "2.2.0+cu130torch2.10.0andhigher.post6"
    FileName = "sageattention-2.2.0+cu130torch2.10.0andhigher.post6-cp310-abi3-win_amd64.whl"
    Size = [int64]16656067
    Sha256 = "1635283f5c01ec3cda58a784d0d7eabbcaffaf9511d1b263db4750e1ed7958bb"
    Urls = @(
        "https://github.com/woct0rdho/SageAttention/releases/download/v2.2.0-windows.post6/sageattention-2.2.0%2Bcu130torch2.10.0andhigher.post6-cp310-abi3-win_amd64.whl",
        "https://gh-proxy.com/https://github.com/woct0rdho/SageAttention/releases/download/v2.2.0-windows.post6/sageattention-2.2.0%2Bcu130torch2.10.0andhigher.post6-cp310-abi3-win_amd64.whl",
        "https://ghfast.top/https://github.com/woct0rdho/SageAttention/releases/download/v2.2.0-windows.post6/sageattention-2.2.0%2Bcu130torch2.10.0andhigher.post6-cp310-abi3-win_amd64.whl"
    )
}

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
    foreach ($drive in Get-PSDrive -PSProvider FileSystem) {
        $candidates += (Join-Path $drive.Root "MiniMaxH3")
    }

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
    if ($script:LogPath) {
        try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 } catch { }
    }
}

function Invoke-Native(
    [string]$FilePath,
    [string[]]$Arguments,
    [string]$WorkingDirectory,
    [switch]$AllowFailure,
    [switch]$Quiet
) {
    Push-Location $WorkingDirectory
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = @(& $FilePath @Arguments 2>&1)
        $code = [int]$LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
        Pop-Location
    }

    if (-not $Quiet) {
        foreach ($line in $output) {
            if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
                Write-Log ([string]$line) "RUN"
            }
        }
    }

    if ($code -ne 0 -and -not $AllowFailure) {
        $details = (@($output | ForEach-Object { [string]$_ }) -join " | ").Trim()
        throw "Command failed with exit code ${code}: $FilePath $($Arguments -join ' '). $details"
    }
    return $code
}

function Assert-ComfyStopped([string]$Root) {
    $running = @()
    foreach ($p in @(Get-Process python,pythonw -ErrorAction SilentlyContinue)) {
        try {
            if ($p.Path -and $p.Path.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) {
                $running += $p
            }
        } catch { }
    }
    if ($running.Count -gt 0) {
        throw "MiniMax H3 / ComfyUI is running from $Root. Close it before installing plugins."
    }

    try {
        $tcp = New-Object Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect("127.0.0.1", 8188, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(250) -and $tcp.Connected) {
            $tcp.Close()
            throw "Port 8188 is active. Close ComfyUI before installing plugins."
        }
        $tcp.Close()
    } catch {
        if ($_.Exception.Message -like "Port 8188*") { throw }
    }
}

function Assert-Runtime([string]$Root) {
    $python = Join-Path $Root "runtime\venv\Scripts\python.exe"
    $probe = Join-Path $Root ("runtime\plugin-clean-probe-" + [Guid]::NewGuid().ToString("N") + ".py")
    $result = $probe + ".json"
    $code = @'
import json, sys
import torch, torchvision, torchaudio
payload = {
    "python": sys.version.split()[0],
    "torch": torch.__version__,
    "torchvision": torchvision.__version__,
    "torchaudio": torchaudio.__version__,
    "cuda": torch.version.cuda or "",
    "cuda_available": bool(torch.cuda.is_available()),
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(payload, f)
'@
    try {
        $code | Set-Content -LiteralPath $probe -Encoding UTF8
        $null = Invoke-Native $python @($probe, $result) $Root -Quiet
        if (-not (Test-Path -LiteralPath $result -PathType Leaf)) {
            throw "Runtime probe did not produce a result file."
        }
        $r = Get-Content -LiteralPath $result -Raw | ConvertFrom-Json
        if ([string]$r.python -ne $ExpectedPython) { throw "Unsupported Python: $($r.python); expected $ExpectedPython." }
        if ([string]$r.torch -ne $ExpectedTorch) { throw "Unsupported torch: $($r.torch); expected $ExpectedTorch." }
        if ([string]$r.torchvision -ne $ExpectedTorchVision) { throw "Unsupported torchvision: $($r.torchvision); expected $ExpectedTorchVision." }
        if ([string]$r.torchaudio -ne $ExpectedTorchAudio) { throw "Unsupported torchaudio: $($r.torchaudio); expected $ExpectedTorchAudio." }
        if ([string]$r.cuda -ne $ExpectedCuda) { throw "Unsupported CUDA runtime: $($r.cuda); expected $ExpectedCuda." }
        if (-not [bool]$r.cuda_available) { throw "CUDA is not available in the protected MiniMax H3 runtime." }
        Write-Log "Runtime OK: Python $($r.python), torch $($r.torch), CUDA $($r.cuda)."
    } finally {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $result -Force -ErrorAction SilentlyContinue
    }
}

function Get-DistributionVersion([string]$Python, [string]$Distribution, [string]$Root) {
    $probe = Join-Path $Root ("runtime\plugin-clean-dist-" + [Guid]::NewGuid().ToString("N") + ".py")
    $result = $probe + ".txt"
    $code = @'
import importlib.metadata as m, sys
wanted = sys.argv[1].lower().replace("_", "-")
value = next((d.version for d in m.distributions() if (d.metadata.get("Name") or "").lower().replace("_", "-") == wanted), "")
with open(sys.argv[2], "w", encoding="utf-8") as f:
    f.write(value)
'@
    try {
        $code | Set-Content -LiteralPath $probe -Encoding UTF8
        $null = Invoke-Native $Python @($probe, $Distribution, $result) $Root -Quiet
        if (-not (Test-Path -LiteralPath $result -PathType Leaf)) { return $null }
        $value = (Get-Content -LiteralPath $result -Raw).Trim()
        if ([string]::IsNullOrWhiteSpace($value)) { return $null }
        return $value
    } finally {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $result -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-DownloadOne([string]$Url, [string]$Destination, [string]$WorkingDirectory) {
    Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        $args = @("-L", "--fail", "--silent", "--show-error", "--retry", "3", "--retry-delay", "2", "--connect-timeout", "20", "--max-time", "300", "-o", $Destination, $Url)
        $code = Invoke-Native $curl.Source $args $WorkingDirectory -AllowFailure
        if ($code -eq 0 -and (Test-Path -LiteralPath $Destination -PathType Leaf) -and (Get-Item -LiteralPath $Destination).Length -gt 0) {
            return
        }
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    }

    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Destination -TimeoutSec 300
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf) -or (Get-Item -LiteralPath $Destination).Length -le 0) {
        throw "Downloaded file is empty: $Url"
    }
}

function Test-ZipFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $stream = $null
    try {
        $stream = [IO.File]::OpenRead($Path)
        if ($stream.Length -lt 4) { return $false }
        $b1 = $stream.ReadByte()
        $b2 = $stream.ReadByte()
        return ($b1 -eq 0x50 -and $b2 -eq 0x4B)
    } catch {
        return $false
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Download-RepoArchive($Spec, [string]$StageRoot) {
    $safe = ($Spec.Repo -replace "[^A-Za-z0-9_.-]", "-")
    $zip = Join-Path $StageRoot ($safe + ".zip")
    $extract = Join-Path $StageRoot ($safe + "-extract")
    $githubUrl = "https://github.com/$($Spec.Repo)/archive/$($Spec.Commit).zip"
    $urls = @(
        $githubUrl,
        "https://codeload.github.com/$($Spec.Repo)/zip/$($Spec.Commit)",
        "https://gh-proxy.com/$githubUrl",
        "https://ghfast.top/$githubUrl"
    )

    $ok = $false
    foreach ($url in $urls) {
        try {
            Write-Log "Downloading $($Spec.Name): $url"
            Invoke-DownloadOne $url $zip $StageRoot
            if (-not (Test-ZipFile $zip)) { throw "response is not a ZIP archive" }
            $ok = $true
            break
        } catch {
            Write-Log "Download source failed: $($_.Exception.Message)" "WARN"
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $ok) { throw "Could not download plugin source: $($Spec.Name)" }

    Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $extract | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
    $rootDir = Get-ChildItem -LiteralPath $extract -Directory | Select-Object -First 1
    if (-not $rootDir) { throw "Plugin archive has no source directory: $($Spec.Name)" }
    return $rootDir.FullName
}

function Download-RawSource($Spec, [string]$StageRoot) {
    $dest = Join-Path $StageRoot $Spec.Name
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    foreach ($file in $Spec.Files) {
        $relative = "$($Spec.Prefix)/$file"
        $raw = "https://raw.githubusercontent.com/$($Spec.Repo)/$($Spec.Commit)/$relative"
        $urls = @(
            $raw,
            "https://gh-proxy.com/$raw",
            "https://ghfast.top/$raw"
        )
        $target = Join-Path $dest $file
        $ok = $false
        foreach ($url in $urls) {
            try {
                Write-Log "Downloading $($Spec.Name)/$file"
                Invoke-DownloadOne $url $target $StageRoot
                $ok = $true
                break
            } catch {
                Write-Log "Raw source failed: $($_.Exception.Message)" "WARN"
                Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not $ok) { throw "Could not download $($Spec.Name)/$file" }
    }
    return $dest
}

function Install-Requirements([string]$Python, [string]$PluginDir, [string]$Name, [string]$Constraints, [string]$Root) {
    $req = Join-Path $PluginDir "requirements.txt"
    if (-not (Test-Path -LiteralPath $req -PathType Leaf)) {
        Write-Log "No requirements.txt for $Name; dependency step skipped."
        return
    }

    $indexes = @(
        "https://pypi.tuna.tsinghua.edu.cn/simple",
        "https://pypi.org/simple"
    )
    foreach ($index in $indexes) {
        Write-Log "Installing dependencies for $Name from $index"
        $args = @("-m", "pip", "install", "--disable-pip-version-check", "--prefer-binary", "-i", $index, "-c", $Constraints, "-r", $req)
        $code = Invoke-Native $Python $args $Root -AllowFailure
        if ($code -eq 0) {
            Assert-Runtime $Root
            return
        }
        Write-Log "Dependency source failed for $Name; trying next index." "WARN"
    }
    throw "Could not install dependencies for $Name."
}

function Ensure-CleanDependencyBaseline([string]$Python, [string]$Root, [string]$Constraints) {
    $matrixClient = Get-DistributionVersion $Python "matrix-client" $Root
    if ($matrixClient) {
        Write-Log "Removing stale matrix-client $matrixClient left by the old test installer." "WARN"
        $null = Invoke-Native $Python @("-m", "pip", "uninstall", "-y", "matrix-client") $Root
    }

    $urllib = Get-DistributionVersion $Python "urllib3" $Root
    if ($urllib -ne $ExpectedUrllib3) {
        Write-Log "Restoring urllib3 to protected baseline $ExpectedUrllib3 (found '$urllib')." "WARN"
        $indexes = @("https://pypi.tuna.tsinghua.edu.cn/simple", "https://pypi.org/simple")
        $installed = $false
        foreach ($index in $indexes) {
            $code = Invoke-Native $Python @("-m", "pip", "install", "--disable-pip-version-check", "-i", $index, "-c", $Constraints, "urllib3==$ExpectedUrllib3") $Root -AllowFailure
            if ($code -eq 0) { $installed = $true; break }
        }
        if (-not $installed) { throw "Could not restore urllib3 $ExpectedUrllib3." }
    }
}

function Backup-And-CopyPlugin([string]$Source, [string]$Destination, [string]$BackupRoot) {
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Plugin source directory missing: $Source"
    }
    if (Test-Path -LiteralPath $Destination) {
        New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
        $backup = Join-Path $BackupRoot (Split-Path -Leaf $Destination)
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
        Move-Item -LiteralPath $Destination -Destination $backup -Force
        Write-Log "Backed up existing plugin: $Destination"
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
    Write-Log "Installed plugin: $(Split-Path -Leaf $Destination)"
}

function Test-ValidatedWheel([string]$Path, $Spec) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Path
    if ([int64]$item.Length -ne [int64]$Spec.Size) { return $false }
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    return $hash -eq ([string]$Spec.Sha256).ToLowerInvariant()
}

function Download-ValidatedWheel($Spec, [string]$WheelDir) {
    New-Item -ItemType Directory -Force -Path $WheelDir | Out-Null
    $dest = Join-Path $WheelDir $Spec.FileName
    foreach ($url in $Spec.Urls) {
        try {
            Write-Log "Downloading validated $($Spec.Distribution) wheel: $url"
            Invoke-DownloadOne $url $dest $WheelDir
            if (-not (Test-ValidatedWheel $dest $Spec)) { throw "size/SHA256 verification failed" }
            return $dest
        } catch {
            Write-Log "Wheel source failed: $($_.Exception.Message)" "WARN"
            Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        }
    }
    throw "Could not download validated wheel: $($Spec.FileName)"
}

function Install-ExactWheel([string]$Python, $Spec, [string]$WheelDir, [string]$Root) {
    $current = Get-DistributionVersion $Python $Spec.Distribution $Root
    if ($current -eq [string]$Spec.Version) {
        Write-Log "$($Spec.Distribution) $current already installed; keeping it."
        return
    }
    if ($current) {
        Write-Log "Replacing $($Spec.Distribution) $current with validated $($Spec.Version)." "WARN"
        $null = Invoke-Native $Python @("-m", "pip", "uninstall", "-y", $Spec.Distribution) $Root
    }
    $wheel = Download-ValidatedWheel $Spec $WheelDir
    $null = Invoke-Native $Python @("-m", "pip", "install", "--no-deps", "--no-index", "--disable-pip-version-check", $wheel) $Root
    $after = Get-DistributionVersion $Python $Spec.Distribution $Root
    if ($after -ne [string]$Spec.Version) {
        throw "$($Spec.Distribution) version verification failed; expected $($Spec.Version), found '$after'."
    }
    Assert-Runtime $Root
}

function Invoke-SageSmoke([string]$Python, [string]$Root) {
    $probe = Join-Path $Root ("runtime\plugin-clean-sage-smoke-" + [Guid]::NewGuid().ToString("N") + ".py")
    $code = @'
import importlib.metadata, torch
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
    try {
        $code | Set-Content -LiteralPath $probe -Encoding UTF8
        $null = Invoke-Native $Python @($probe) $Root
    } finally {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    }
}

$root = Resolve-MiniMaxRoot $TargetRoot
$python = Join-Path $root "runtime\venv\Scripts\python.exe"
$comfy = Join-Path $root "ComfyUI"
$customNodes = Join-Path $comfy "custom_nodes"
$workflows = Join-Path $comfy "user\default\workflows"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$stage = Join-Path $root ("runtime\plugin-minimaxh3-clean-stage-" + [Guid]::NewGuid().ToString("N"))
$backup = Join-Path $root ("plugin-backups\plugin-minimaxh3-clean-" + $stamp)
$logDir = Join-Path $root "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$script:LogPath = Join-Path $logDir ("plugin-minimaxh3-clean-" + $stamp + ".log")

try {
    Write-Log "MiniMax H3 clean plugin installer started. No bundled plugin resources are used."
    Write-Log "Target root: $root"
    Assert-ComfyStopped $root
    Assert-Runtime $root

    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $constraints = Join-Path $stage "protected-constraints.txt"
    @(
        "torch==$ExpectedTorch",
        "torchvision==$ExpectedTorchVision",
        "torchaudio==$ExpectedTorchAudio",
        "urllib3==$ExpectedUrllib3"
    ) | Set-Content -LiteralPath $constraints -Encoding ASCII

    $sources = @{}
    foreach ($spec in $RepoPlugins) {
        $sources[$spec.Name] = Download-RepoArchive $spec $stage
    }
    foreach ($spec in $CustomSources) {
        $sources[$spec.Name] = Download-RawSource $spec $stage
    }

    $teSource = [string]$sources["TE-Speed-MiniMaxH3-OSS"]
    $tePatch = Join-Path $teSource "patch_model.py"
    $teWorkflow = Join-Path $teSource "tespeed_workflow_patch.py"
    Write-Log "Running TE-Speed V3 preflight before changing the environment."
    $null = Invoke-Native $python @($tePatch, "--preflight", "--comfy-ui", $comfy) $root

    Ensure-CleanDependencyBaseline $python $root $constraints
    Assert-Runtime $root

    foreach ($spec in $RepoPlugins) {
        Install-Requirements $python ([string]$sources[$spec.Name]) $spec.Name $constraints $root
    }

    $wheelDir = Join-Path $stage "wheels"
    Install-ExactWheel $python $TritonSpec $wheelDir $root
    Install-ExactWheel $python $SageSpec $wheelDir $root
    Assert-Runtime $root

    $installOrder = @(
        "comfyui_essentials",
        "comfyui-crystools",
        "comfyui-custom-scripts",
        "comfyui-manager",
        "comfyui-VideoHelperSuite",
        "rgthree-comfy",
        "comfyui-minimax-h3-audio-T8",
        "comfyui-minimax-h3-blockcache-T8",
        "ComfyUI-MiniMaxH3-AVCache-CN",
        "TE-Speed-MiniMaxH3-OSS",
        "SageAttention-MiniMaxH3-Safe"
    )

    foreach ($name in $installOrder) {
        Backup-And-CopyPlugin ([string]$sources[$name]) (Join-Path $customNodes $name) $backup
    }

    Write-Log "Applying validated TE-Speed V3 core patch."
    $null = Invoke-Native $python @($tePatch, "--comfy-ui", $comfy) $root
    $null = Invoke-Native $python @($tePatch, "--check", "--comfy-ui", $comfy) $root

    if (Test-Path -LiteralPath $workflows -PathType Container) {
        Write-Log "Applying TE-Speed workflow wiring where the workflow structure is unambiguous."
        $workflowCode = Invoke-Native $python @($teWorkflow, "--add", $workflows) $root -AllowFailure
        if ($workflowCode -ne 0) {
            Write-Log "One or more ambiguous workflows were intentionally left unchanged by the TE patcher." "WARN"
        }
    }

    foreach ($name in $installOrder) {
        $dest = Join-Path $customNodes $name
        if (-not (Test-Path -LiteralPath $dest -PathType Container)) { throw "Installed plugin folder missing: $name" }
    }

    Write-Log "Compiling installed Python plugin code."
    foreach ($name in $installOrder) {
        $null = Invoke-Native $python @("-m", "compileall", "-q", (Join-Path $customNodes $name)) $root
    }

    Write-Log "Running SageAttention CUDA FP16/BF16 smoke test."
    Invoke-SageSmoke $python $root

    Assert-Runtime $root
    $null = Invoke-Native $python @("-m", "pip", "check") $root

    Write-Log "Clean plugin installation completed. Protected Python/Torch/CUDA runtime is unchanged."
    Write-Host ""
    Write-Host "Installed:" -ForegroundColor Green
    foreach ($name in $installOrder) { Write-Host "  - $name" }
    Write-Host "  - triton-windows $($TritonSpec.Version)"
    Write-Host "  - sageattention $($SageSpec.Version)"
    Write-Host ""
    Write-Host "Backup: $backup"
    Write-Host "Log: $script:LogPath"
    exit 0
} catch {
    Write-Log $_.Exception.Message "ERROR"
    Write-Host ""
    Write-Host ("Plugin installation failed: " + $_.Exception.Message) -ForegroundColor Red
    Write-Host "Log: $script:LogPath"
    exit 1
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
