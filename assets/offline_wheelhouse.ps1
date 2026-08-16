#requires -version 5.1

# Offline-first dependency layer for the stable MiniMax H3 installer.
# This file intentionally does not change Python / PyTorch / CUDA / ComfyUI versions.
# It only changes source priority:
#   local portable Python + local wheelhouse -> configured network mirrors -> official sources.

function Get-LocalWheelhouseDirectories {
    $candidates = @(
        (Join-Path $script:InstallerRoot "wheels"),
        (Join-Path $script:AssetsRoot "wheels"),
        (Join-Path $script:AssetsRoot "wheels\dependencies")
    )
    return @($candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -Unique)
}

function Find-LocalInstallerAsset {
    param([string]$FileName)

    $candidates = @(
        (Join-Path $script:InstallerRoot $FileName),
        (Join-Path $script:AssetsRoot $FileName),
        (Join-Path $script:AssetsRoot ("wheels\" + $FileName))
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Get-Item -LiteralPath $candidate).FullName }
    }

    foreach ($root in @($script:InstallerRoot, $script:AssetsRoot)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $match = Get-ChildItem -LiteralPath $root -Filter $FileName -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($match) { return $match.FullName }
    }
    return $null
}

function Invoke-LocalWheelhousePip {
    param(
        [string]$Python,
        [string]$PackageArguments,
        [switch]$AllowFailure
    )

    $wheelDirs = @(Get-LocalWheelhouseDirectories)
    if ($wheelDirs.Count -eq 0) {
        Add-Log "Local wheelhouse not found; network fallback may be used." "WARN"
        if ($AllowFailure) { return 1 }
        throw "Local wheelhouse is not available."
    }

    $findLinks = ($wheelDirs | ForEach-Object { "--find-links `"$_`"" }) -join " "
    Add-Log ("Trying local wheelhouse first: {0}" -f ($wheelDirs -join "; "))
    $args = "-m pip $PackageArguments --no-index $findLinks --disable-pip-version-check"
    $exit = Invoke-ProcessChecked $Python $args $script:InstallerRoot -AllowFailure
    if ($exit -eq 0) {
        Add-Log "Local wheelhouse satisfied this dependency transaction; no network source was used."
        return 0
    }

    Add-Log "Local wheelhouse is incomplete for this transaction; falling back to configured network sources." "WARN"
    if ($AllowFailure) { return [int]$exit }
    throw "Local wheelhouse could not satisfy the requested packages."
}

# Override the ordinary PyPI helper from local_torch_wheels.ps1.
function Invoke-BasePyPiWithFallback {
    param([string]$Python, [string]$PackageArguments)

    $localExit = Invoke-LocalWheelhousePip -Python $Python -PackageArguments $PackageArguments -AllowFailure
    if ($localExit -eq 0) { return }

    if (Test-ChinaMirrorPriority) {
        $sources = @(
            [PSCustomObject]@{ Label="Tsinghua PyPI mirror"; Url="https://pypi.tuna.tsinghua.edu.cn/simple" },
            [PSCustomObject]@{ Label="Aliyun PyPI mirror"; Url="https://mirrors.aliyun.com/pypi/simple" },
            [PSCustomObject]@{ Label="official PyPI"; Url="https://pypi.org/simple" }
        )
    } else {
        $sources = @(
            [PSCustomObject]@{ Label="official PyPI"; Url="https://pypi.org/simple" },
            [PSCustomObject]@{ Label="Tsinghua PyPI mirror"; Url="https://pypi.tuna.tsinghua.edu.cn/simple" },
            [PSCustomObject]@{ Label="Aliyun PyPI mirror"; Url="https://mirrors.aliyun.com/pypi/simple" }
        )
    }

    foreach ($source in $sources) {
        Add-Log "Python package source: $($source.Label)"
        $args = "-m pip $PackageArguments --index-url $($source.Url) --timeout 60 --retries 3 --disable-pip-version-check"
        $exit = Invoke-ProcessChecked $Python $args $script:InstallerRoot -AllowFailure
        if ($exit -eq 0) { return }
        Add-Log "$($source.Label) failed; trying the next Python package source." "WARN"
    }
    throw "Local wheelhouse and all configured Python package sources failed."
}

# Override the generic pip fallback used by the bundled ComfyUI requirements.
function Invoke-PipWithFallback {
    param(
        [string]$Python,
        [string]$PackageArguments,
        $Runtime,
        [switch]$NeedsTorchIndex
    )

    $localExit = Invoke-LocalWheelhousePip -Python $Python -PackageArguments $PackageArguments -AllowFailure
    if ($localExit -eq 0) { return }

    if ($NeedsTorchIndex) {
        $officialArgs = "$PackageArguments --index-url $($Runtime.index_url)"
        $mirrorArgs = if ($Runtime.mirror_index_url) { "$PackageArguments --index-url $($Runtime.mirror_index_url)" } else { $null }
        $officialLabel = "PyTorch official source"
        $mirrorLabel = "Aliyun PyTorch mirror"
    } else {
        $mirrorTorchIndex = if ($Runtime.mirror_index_url) { $Runtime.mirror_index_url } else { $Runtime.index_url }
        $officialArgs = "$PackageArguments --index-url https://pypi.org/simple --extra-index-url $($Runtime.index_url)"
        $mirrorArgs = "$PackageArguments --index-url https://pypi.tuna.tsinghua.edu.cn/simple --extra-index-url $mirrorTorchIndex"
        $officialLabel = "official PyPI"
        $mirrorLabel = "Tsinghua PyPI mirror"
    }

    $preferMirror = Test-ChinaMirrorPriority
    if ($preferMirror -and $mirrorArgs) {
        $primaryArgs = $mirrorArgs
        $primaryLabel = $mirrorLabel
        $fallbackArgs = $officialArgs
        $fallbackLabel = $officialLabel
    } else {
        $primaryArgs = $officialArgs
        $primaryLabel = $officialLabel
        $fallbackArgs = $mirrorArgs
        $fallbackLabel = $mirrorLabel
    }

    Add-Log "Python package source: $primaryLabel"
    $exit = Invoke-ProcessChecked $Python ("-m pip {0} --timeout 30 --retries 2 --no-cache-dir --disable-pip-version-check" -f $primaryArgs) $script:InstallerRoot -AllowFailure
    if ($exit -eq 0) { return }

    if (-not $fallbackArgs) { throw "$primaryLabel failed and no fallback source is configured for $($Runtime.label)." }
    Add-Log "$primaryLabel failed; switching to $fallbackLabel." "WARN"
    $null = Invoke-ProcessChecked $Python ("-m pip {0} --timeout 30 --retries 3 --no-cache-dir --disable-pip-version-check" -f $fallbackArgs) $script:InstallerRoot
}

function Install-PythonFromNuGetPackage {
    param(
        [string]$PackagePath,
        [string]$PythonRoot,
        [string]$InstallRoot
    )

    if (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
        throw "Portable Python package is missing: $PackagePath"
    }

    $runtimeRoot = Split-Path -Parent $PythonRoot
    New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
    $staging = Join-Path $runtimeRoot ("python-nuget-staging-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $staging | Out-Null

    try {
        Set-Stage "Extracting portable Python 3.10.11 runtime" -1
        Add-Log "Portable Python package: $PackagePath"
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($PackagePath, $staging)

        $toolsRoot = Join-Path $staging "tools"
        $stagedPython = Join-Path $toolsRoot "python.exe"
        if (-not (Test-Path -LiteralPath $stagedPython -PathType Leaf)) {
            throw "The NuGet package did not contain tools\python.exe."
        }

        if (Test-Path -LiteralPath $PythonRoot) {
            Remove-Item -LiteralPath $PythonRoot -Recurse -Force
        }
        Move-Item -LiteralPath $toolsRoot -Destination $PythonRoot
    } finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }

    $python = Join-Path $PythonRoot "python.exe"
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
        throw "Portable Python extraction did not create $python"
    }

    $version = (& $python -c "import sys; print('.'.join(map(str, sys.version_info[:3])))" 2>$null | Select-Object -Last 1)
    if ($LASTEXITCODE -ne 0 -or $version -ne "3.10.11") {
        throw "Portable Python runtime version check failed. Expected 3.10.11, got '$version'."
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $python
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or -not $signature.SignerCertificate.Subject.Contains("Python Software Foundation")) {
        throw "Portable python.exe signature is not valid. Status: $($signature.Status)"
    }

    $featureCheck = (& $python -c "import venv, ensurepip; print('portable-runtime-ok')" 2>$null | Select-Object -Last 1)
    if ($LASTEXITCODE -ne 0 -or $featureCheck -ne "portable-runtime-ok") {
        throw "Portable Python runtime is missing venv/ensurepip support."
    }

    Add-Log "Portable Python 3.10.11 runtime extracted successfully; no Windows Python installation was registered."
    return $python
}

# Use the official CPython NuGet runtime as the primary private runtime.
# Unlike python.org's registered EXE installer, this package can coexist with
# another Python 3.10.11 installation and does not create an Apps & Features entry.
function Install-PythonRuntime {
    param([string]$InstallRoot)

    $pythonRoot = Join-Path $InstallRoot "runtime\python"
    $python = Join-Path $pythonRoot "python.exe"
    if (Test-Path -LiteralPath $python) {
        $version = (& $python -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null | Select-Object -Last 1)
        if ($version -eq "3.10") {
            Add-Log "Existing private Python 3.10 runtime found."
            return $python
        }
        throw "The private Python runtime exists but is not Python 3.10: $python"
    }

    $packageName = "python.3.10.11.nupkg"
    $localPackage = Find-LocalInstallerAsset -FileName $packageName
    if ($localPackage) {
        Add-Log "Local portable Python package found: $localPackage"
        return (Install-PythonFromNuGetPackage -PackagePath $localPackage -PythonRoot $pythonRoot -InstallRoot $InstallRoot)
    }

    $cache = Join-Path $InstallRoot "downloads"
    New-Item -ItemType Directory -Force -Path $cache | Out-Null
    $package = Join-Path $cache $packageName
    Set-Stage "Downloading portable Python 3.10.11 runtime" -1
    Add-Log "Local portable Python package not found; trying official NuGet package." "WARN"

    try {
        $null = Invoke-SimpleDownload "portable Python 3.10.11" @(
            "https://api.nuget.org/v3-flatcontainer/python/3.10.11/python.3.10.11.nupkg",
            "https://www.nuget.org/api/v2/package/python/3.10.11"
        ) $package
        return (Install-PythonFromNuGetPackage -PackagePath $package -PythonRoot $pythonRoot -InstallRoot $InstallRoot)
    } catch {
        Add-Log ("Portable Python package path failed: {0}" -f $_.Exception.Message) "WARN"
    }

    # Compatibility fallback for older offline bundles that only contain the
    # python.org EXE. This can fail when the same Python version is already
    # registered on Windows, which is why NuGet is preferred above.
    $installerName = "python-3.10.11-amd64.exe"
    $localInstaller = Find-LocalInstallerAsset -FileName $installerName
    if (-not $localInstaller) {
        throw "Portable Python package was unavailable, and no local $installerName fallback was found."
    }

    $installer = $localInstaller
    Add-Log "Falling back to registered Python EXE installer: $installer" "WARN"
    $signature = Get-AuthenticodeSignature -LiteralPath $installer
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or -not $signature.SignerCertificate.Subject.Contains("Python Software Foundation")) {
        throw "The Python installer signature is not valid. File was not executed. Status: $($signature.Status)"
    }

    Set-Stage "Installing Python 3.10.11 compatibility fallback" -1
    $arguments = "/quiet InstallAllUsers=0 Include_launcher=0 Include_test=0 Include_doc=0 AssociateFiles=0 Shortcuts=0 PrependPath=0 Include_pip=1 TargetDir=`"$pythonRoot`""
    $null = Invoke-ProcessChecked $installer $arguments $InstallRoot
    if (-not (Test-Path -LiteralPath $python)) {
        throw "The registered Python EXE installer did not create $python. This usually means another Python 3.10.11 installation is already registered. Add python.3.10.11.nupkg beside the installer and retry."
    }
    return $python
}
