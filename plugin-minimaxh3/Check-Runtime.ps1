#requires -version 5.1

[CmdletBinding()]
param(
    [string]$TargetRoot = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifestPath = Join-Path $scriptRoot "plugin-manifest.json"
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Plugin manifest is missing: $manifestPath"
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$target = $manifest.target

function Test-MiniMaxRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return (
        (Test-Path -LiteralPath (Join-Path $Path "ComfyUI\main.py") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Path "ComfyUI\custom_nodes") -PathType Container) -and
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
    foreach ($drive in Get-PSDrive -PSProvider FileSystem) {
        $candidates += (Join-Path $drive.Root "MiniMaxH3")
    }

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try {
            $full = [IO.Path]::GetFullPath($candidate)
            if (Test-MiniMaxRoot $full) { return $full }
        } catch { }
    }
    throw "Could not find the MiniMaxH3-Installer installation. Set MINIMAX_H3_ROOT to the installation folder and retry."
}

function Invoke-PythonProbe {
    param([string]$Python, [string[]]$Arguments)
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $raw = @(& $Python @Arguments 2>&1)
        $exitCode = [int]$LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output = @($raw | ForEach-Object { [string]$_ })
    }
}

try {
    $root = Resolve-MiniMaxRoot -RequestedRoot $TargetRoot
    $python = Join-Path $root "runtime\venv\Scripts\python.exe"

    # Only torch needs to be imported for the CUDA runtime check. Read the
    # torchvision/torchaudio versions from installed distribution metadata so
    # optional DLL/image/audio initialization cannot make the guard fail before
    # we can explain the real problem.
    $code = @'
import json, platform, importlib.metadata as md
import torch

def dist_version(name):
    try:
        return md.version(name)
    except Exception:
        return ""

print(json.dumps({
  "python": platform.python_version(),
  "torch": torch.__version__,
  "torchvision": dist_version("torchvision"),
  "torchaudio": dist_version("torchaudio"),
  "cuda": str(torch.version.cuda or ""),
  "cuda_available": bool(torch.cuda.is_available())
}))
'@
    $probe = Invoke-PythonProbe -Python $python -Arguments @("-c", $code)
    if ($probe.ExitCode -ne 0) {
        $details = @($probe.Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $tail = if ($details.Count -gt 8) { @($details | Select-Object -Last 8) } else { $details }
        $detailText = ($tail -join " | ").Trim()
        if ([string]::IsNullOrWhiteSpace($detailText)) { $detailText = "Python exited with code $($probe.ExitCode) and produced no diagnostic output." }
        throw "Could not inspect the installed Python/PyTorch runtime. Python error: $detailText"
    }

    $json = $probe.Output | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1
    if (-not $json) {
        $detailText = (@($probe.Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join " | ").Trim()
        throw "Runtime probe returned no JSON data. Output: $detailText"
    }
    $runtime = $json | ConvertFrom-Json

    $failures = @()
    if ([string]$runtime.python -ne [string]$target.python) { $failures += "Python $($runtime.python) != $($target.python)" }
    if ([string]$runtime.torch -ne [string]$target.torch) { $failures += "torch $($runtime.torch) != $($target.torch)" }
    if ([string]$runtime.torchvision -ne [string]$target.torchvision) { $failures += "torchvision $($runtime.torchvision) != $($target.torchvision)" }
    if ([string]$runtime.torchaudio -ne [string]$target.torchaudio) { $failures += "torchaudio $($runtime.torchaudio) != $($target.torchaudio)" }
    if ([string]$runtime.cuda -notlike (([string]$target.cuda_prefix) + "*")) { $failures += "CUDA $($runtime.cuda) != $($target.cuda_prefix)x" }
    if (-not [bool]$runtime.cuda_available) { $failures += "torch.cuda.is_available() is false" }

    $installManifest = Join-Path $root ".minimax-h3-install.json"
    if (Test-Path -LiteralPath $installManifest -PathType Leaf) {
        try {
            $installed = Get-Content -LiteralPath $installManifest -Raw | ConvertFrom-Json
            if ($installed.PSObject.Properties.Name -contains "comfyui_commit") {
                if ([string]$installed.comfyui_commit -ne [string]$target.comfyui_commit) {
                    $failures += "ComfyUI commit $($installed.comfyui_commit) != $($target.comfyui_commit)"
                }
            }
        } catch {
            $failures += "Could not read .minimax-h3-install.json"
        }
    }

    foreach ($requiredPath in @(
        "ComfyUI\comfy_api\latest",
        "ComfyUI\comfy\patcher_extension.py",
        "ComfyUI\comfy\model_prefetch.py",
        "ComfyUI\comfy\ldm\minimax\model.py"
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $requiredPath))) {
            $failures += "Required ComfyUI API is missing: $requiredPath"
        }
    }

    if ($failures.Count -gt 0) {
        throw ("This plugin pack is locked to the current MiniMaxH3-Installer CUDA13 mainline. " + ($failures -join "; "))
    }

    Write-Host "Runtime check passed."
    Write-Host "Root: $root"
    Write-Host "Python: $($runtime.python)"
    Write-Host "torch: $($runtime.torch)"
    Write-Host "torchvision: $($runtime.torchvision)"
    Write-Host "torchaudio: $($runtime.torchaudio)"
    Write-Host "CUDA: $($runtime.cuda)"
    Write-Output $root
    exit 0
} catch {
    Write-Host ""
    Write-Host ("Runtime check failed: " + $_.Exception.Message) -ForegroundColor Red
    Write-Host ""
    exit 1
}
