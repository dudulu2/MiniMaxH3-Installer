#requires -version 5.1

[CmdletBinding()]
param(
    [string]$Python = "",
    [switch]$ChinaMirror
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$assets = Join-Path $root "assets"
$wheelhouse = Join-Path $assets "wheels"
$profilesPath = Join-Path $assets "install_profiles.json"
$sourceZip = Join-Path $assets "ComfyUI-source.zip"
$tempRoot = Join-Path $env:TEMP ("minimax-wheelhouse-" + [Guid]::NewGuid().ToString("N"))
$tempComfy = Join-Path $tempRoot "ComfyUI"

function Find-Python310 {
    if ($Python) {
        if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) { throw "Python path does not exist: $Python" }
        return (Resolve-Path -LiteralPath $Python).Path
    }

    $commands = @("py.exe", "python.exe")
    foreach ($name in $commands) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        if ($name -eq "py.exe") {
            $candidate = (& $cmd.Source -3.10 -c "import sys; print(sys.executable)" 2>$null | Select-Object -Last 1)
            if ($LASTEXITCODE -eq 0 -and $candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
        } else {
            $version = (& $cmd.Source -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null | Select-Object -Last 1)
            if ($LASTEXITCODE -eq 0 -and $version -eq "3.10") { return $cmd.Source }
        }
    }
    throw "Python 3.10 was not found. Install Python 3.10.11 first, or rerun with -Python C:\path\to\python.exe."
}

if (-not (Test-Path -LiteralPath $profilesPath)) { throw "Missing $profilesPath" }
if (-not (Test-Path -LiteralPath $sourceZip)) { throw "Missing $sourceZip" }

$py = Find-Python310
Write-Host "Python 3.10: $py" -ForegroundColor Green
New-Item -ItemType Directory -Force -Path $wheelhouse | Out-Null
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
    Expand-Archive -LiteralPath $sourceZip -DestinationPath $tempRoot -Force
    $requirements = Join-Path $tempComfy "requirements.txt"
    if (-not (Test-Path -LiteralPath $requirements)) { throw "Could not extract bundled ComfyUI requirements.txt" }

    $profiles = Get-Content -LiteralPath $profilesPath -Raw | ConvertFrom-Json
    $runtime = $profiles.runtimes.cuda130
    $constraints = Join-Path $tempRoot "constraints-cu130.txt"
    @"
torch==$($runtime.torch)
torchvision==$($runtime.torchvision)
torchaudio==$($runtime.torchaudio)
comfyui-frontend-package==1.47.12
comfyui-workflow-templates==0.11.27
"@ | Set-Content -LiteralPath $constraints -Encoding ASCII

    $baseIndex = if ($ChinaMirror) { "https://pypi.tuna.tsinghua.edu.cn/simple" } else { "https://pypi.org/simple" }
    $torchIndex = if ($ChinaMirror -and $runtime.mirror_index_url) { [string]$runtime.mirror_index_url } else { [string]$runtime.index_url }

    Write-Host "Downloading Python toolchain wheels..." -ForegroundColor Cyan
    & $py -m pip download `
        "pip==25.1.1" setuptools wheel packaging `
        --dest $wheelhouse `
        --index-url $baseIndex `
        --disable-pip-version-check
    if ($LASTEXITCODE -ne 0) { throw "Toolchain wheel download failed." }

    Write-Host "Downloading fixed CUDA 13 PyTorch wheels..." -ForegroundColor Cyan
    & $py -m pip download `
        "torch==$($runtime.torch)" "torchvision==$($runtime.torchvision)" "torchaudio==$($runtime.torchaudio)" `
        --dest $wheelhouse `
        --index-url $torchIndex `
        --no-deps `
        --disable-pip-version-check
    if ($LASTEXITCODE -ne 0) { throw "PyTorch wheel download failed." }

    Write-Host "Downloading PyTorch ordinary dependencies..." -ForegroundColor Cyan
    & $py -m pip download `
        filelock "typing-extensions>=4.10.0" "sympy>=1.13.3" "networkx>=2.5.1" jinja2 "fsspec>=0.8.5" numpy "pillow!=8.3.*,>=5.3.0" `
        --dest $wheelhouse `
        --index-url $baseIndex `
        --disable-pip-version-check
    if ($LASTEXITCODE -ne 0) { throw "PyTorch dependency wheel download failed." }

    Write-Host "Downloading bundled ComfyUI requirements and transitive dependencies..." -ForegroundColor Cyan
    & $py -m pip download `
        -r $requirements `
        -c $constraints `
        --dest $wheelhouse `
        --index-url $baseIndex `
        --extra-index-url $torchIndex `
        --prefer-binary `
        --disable-pip-version-check
    if ($LASTEXITCODE -ne 0) { throw "ComfyUI wheelhouse download failed." }

    Write-Host "" 
    Write-Host "Offline wheelhouse ready:" -ForegroundColor Green
    Write-Host "  $wheelhouse"
    $files = @(Get-ChildItem -LiteralPath $wheelhouse -File)
    $bytes = ($files | Measure-Object Length -Sum).Sum
    Write-Host ("  {0} files, {1:N2} GiB" -f $files.Count, ($bytes / 1GB))
    Write-Host "Copy/download python-3.10.11-amd64.exe into the repository root or assets folder too."
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
